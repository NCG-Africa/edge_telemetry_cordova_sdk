import Foundation

/// Spec T2–T4, T7: append-only NDJSON segments. The open segment's first line is the identity
/// frozen for the whole segment (T4, ADR 0001); every later line is one event. One sealed
/// segment = one batch.
final class Outbox {
    static let sealEvents = 50
    static let sealAgeMs: Int64 = 30_000
    static let maxBytes: Int64 = 5 * 1024 * 1024
    static let maxSegments = 200
    static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    struct Segment {
        let identity: String?
        let events: [String]
    }

    static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private let dir: URL
    private let open: URL
    private let clock: () -> Int64
    private let health: Health
    private let fm = FileManager.default
    // Recursive: append seals inline.
    private let lock = NSRecursiveLock()
    private var openCount = 0
    private var openedAt: Int64 = 0
    private var seq = 0
    private var inFlight: URL?

    init(dir: URL, clock: @escaping () -> Int64 = Outbox.now, health: Health) {
        self.dir = dir
        open = dir.appendingPathComponent("open.ndjson.part")
        self.clock = clock
        self.health = health
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // T2: no-backup storage.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dir
        try? url.setResourceValues(values)
        // A previous process's open segment is sealed now and sent this launch (T3).
        seal()
        // Seal rename failed: keep appending to it, counting what it already holds.
        if fm.fileExists(atPath: open.path) {
            openCount = (try? read(open).events.count) ?? 0
            openedAt = clock()
        }
    }

    /// Appends one hand-off; seals every `sealEvents` events.
    func append(_ identity: String, _ events: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        var i = 0
        while i < events.count {
            let n = min(events.count - i, Self.sealEvents - openCount)
            try write(identity, events[i..<(i + n)])
            i += n
            if openCount >= Self.sealEvents { seal() }
        }
    }

    private func write(_ identity: String, _ events: ArraySlice<String>) throws {
        var text = ""
        let fresh = !fm.fileExists(atPath: open.path)
        if fresh {
            text = identity + "\n"
            openCount = 0
            openedAt = clock()
        }
        for e in events { text += e + "\n" }
        if fresh {
            try Data(text.utf8).write(to: open)
            openCount += events.count
            return
        }
        let handle = try FileHandle(forWritingTo: open)
        defer { try? handle.close() }
        let before = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            // A partial write would end up mid-file once the next hand-off lands; cut it off.
            // If truncation fails too, the torn line stays trailing and is discarded on read.
            try? handle.truncate(atOffset: before)
            throw error
        }
        openCount += events.count
    }

    /// T4 / R14: a native crash or hang record as a sealed segment of one, under the identity of
    /// the build that produced it. Marked `solo` so the sender keeps `sdk.health` out of it (E31).
    func writeSolo(_ identity: String, _ event: String) throws {
        guard var id = (try? JSONSerialization.jsonObject(with: Data(identity.utf8))) as? [String: Any] else {
            throw CocoaError(.fileWriteUnknown)
        }
        id["solo"] = true
        guard let line = Session.line(id) else { throw CocoaError(.fileWriteUnknown) }
        lock.lock(); defer { lock.unlock() }
        let name = String(format: "%013lld-%06d.ndjson", clock(), seq)
        seq += 1
        let text = line + "\n" + event + "\n"
        try Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// 30 s after the open segment's first event (T3).
    func sealIfDue() {
        lock.lock(); defer { lock.unlock() }
        if fm.fileExists(atPath: open.path) && clock() - openedAt >= Self.sealAgeMs { seal() }
    }

    func seal() {
        lock.lock(); defer { lock.unlock() }
        if fm.fileExists(atPath: open.path) {
            // On failure the segment stays open and the next append retries the seal.
            let name = String(format: "%013lld-%06d.ndjson", clock(), seq)
            seq += 1
            if (try? fm.moveItem(at: open, to: dir.appendingPathComponent(name))) != nil { openCount = 0 }
        }
        enforceCaps()
    }

    /// P7 `disable()` / `reset()`: deletes every unsent event. Not counted as a drop.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: open)
        openCount = 0
        for f in sealed() { try? fm.removeItem(at: f) }
    }

    /// Sealed segments, oldest first (name = seal time + per-process sequence).
    func sealed() -> [URL] {
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { Self.sealedAt($0) != nil }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// Reads a segment; a torn trailing line (no newline, e.g. killed mid-write) is discarded.
    func read(_ url: URL) throws -> Segment {
        var lines = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast() // text after the last newline: empty, or torn
        let kept = lines.filter { !$0.isEmpty }.map(String.init)
        return Segment(identity: kept.first, events: Array(kept.dropFirst()))
    }

    /// The segment the sender is posting; caps leave it alone so it isn't counted as dropped.
    func sending(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        inFlight = url
    }

    /// T7: over 5 MB or 200 segments → drop oldest; older than 7 days → drop. Counted (T8).
    private func enforceCaps() {
        let files = sealed()
        func size(_ f: URL) -> Int64 { Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var total = files.reduce(0) { $0 + size($1) }
        var count = files.count
        let now = clock()
        for f in files {
            let expired = now - (Self.sealedAt(f.lastPathComponent) ?? now) > Self.maxAgeMs
            if !expired && total <= Self.maxBytes && count <= Self.maxSegments { break }
            if f == inFlight { continue }
            let events = (try? read(f).events.count) ?? 0
            total -= size(f)
            count -= 1
            try? fm.removeItem(at: f)
            health.count(expired ? "expired" : "outbox_full", events)
        }
    }

    /// Seal time from a sealed segment's name; nil for any other file.
    private static func sealedAt(_ name: String) -> Int64? {
        guard name.range(of: #"^\d{13}-\d{6}\.ndjson$"#, options: .regularExpression) != nil else { return nil }
        return Int64(name.prefix(13))
    }
}
