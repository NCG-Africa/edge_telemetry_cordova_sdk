import Foundation
import zlib

/// Spec T3, T5, T6 and wire rules R1–R4, R10, R12, R13: drains sealed segments oldest first, one
/// request in flight, each as a gzipped contract-4 envelope.
final class Sender {
    static let contractVersion = "4.0.0"
    /// T6: delays before the 3 retries that follow a failed first send.
    static let retryMs: [Int64] = [1_000, 4_000, 16_000]
    /// Backoff of a parked segment; matches the 30 s tick that retries it (T6).
    static let parkMs: Int64 = 30_000
    /// W3: app keys in envelope order.
    private static let appKeys = ["name", "package_name", "platform", "version", "build_number"]

    /// C1: key and URL travel together, so a send always reads a matching pair.
    private struct Target {
        var apiKey: String?
        var url: String?
    }

    private let outbox: Outbox
    private let health: Health
    private let sdkVersion: String
    private let session: URLSession
    private let clock: () -> Int64
    private let sleep: (Int64) -> Void
    private let retryMs: [Int64]
    private let queue = DispatchQueue(label: "com.nathanclaire.rum.sender")
    private let lock = NSLock()
    private var target = Target()
    private var pending = false
    private var parkedUntil: [String: Int64] = [:]

    init(outbox: Outbox, health: Health, sdkVersion: String,
         session: URLSession = URLSession(configuration: .ephemeral),
         clock: @escaping () -> Int64 = Outbox.now,
         sleep: @escaping (Int64) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000) },
         retryMs: [Int64] = Sender.retryMs) {
        self.outbox = outbox
        self.health = health
        self.sdkVersion = sdkVersion
        self.session = session
        self.clock = clock
        self.sleep = sleep
        self.retryMs = retryMs
    }

    /// Sets whichever of key / URL is non-blank; the other keeps its value. Segments stay on disk
    /// until both are known (C1).
    func configure(apiKey: String?, url: String?) {
        func trimmed(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        lock.lock(); defer { lock.unlock() }
        target = Target(apiKey: trimmed(apiKey) ?? target.apiKey, url: trimmed(url) ?? target.url)
    }

    var configured: Bool {
        lock.lock(); defer { lock.unlock() }
        return target.apiKey != nil && target.url != nil
    }

    /// W3 + T4: the identity line frozen into each segment; nil values omitted (R15).
    static func identityLine(name: String?, packageName: String?, version: String?, buildNumber: String?,
                             deviceId: String) -> String {
        let app = ["name": name, "package_name": packageName, "platform": "ios",
                   "version": version, "build_number": buildNumber].compactMapValues { $0 }
        return #"{"app":"# + appJSON(app) + #","device_id":"# + quote(deviceId) + "}"
    }

    private static func appJSON(_ app: [String: String]) -> String {
        "{" + appKeys.compactMap { k in app[k].map { quote(k) + ":" + quote($0) } }.joined(separator: ",") + "}"
    }

    /// Schedules a drain on the sender queue. Plain triggers queued meanwhile coalesce; one with
    /// `done` always runs its own drain and calls back after it (background task end, T3).
    func trigger(_ done: (() -> Void)? = nil) {
        if let done {
            queue.async { self.drain(); done() }
            return
        }
        lock.lock()
        let queued = pending
        pending = true
        lock.unlock()
        guard !queued else { return }
        queue.async {
            self.lock.lock(); self.pending = false; self.lock.unlock()
            self.drain()
        }
    }

    /// Sends every sealed segment not inside its park backoff; stops at the first one it parks.
    /// Runs on the sender queue (via `trigger`); tests call it directly, single-threaded.
    func drain() {
        lock.lock()
        let t = target
        lock.unlock()
        guard let apiKey = t.apiKey, let url = t.url else { return }
        for f in outbox.sealed() {
            if let until = parkedUntil[f.lastPathComponent], clock() < until { continue }
            outbox.sending(f)
            defer { outbox.sending(nil) }
            if !send(f, apiKey: apiKey, url: url) { return }
        }
    }

    /// - Returns: false when the segment was parked.
    private func send(_ f: URL, apiKey: String, url: String) -> Bool {
        guard let seg = try? outbox.read(f) else { return true } // vanished (capped or deleted meanwhile)
        guard let identity = seg.identity, !seg.events.isEmpty else {
            try? FileManager.default.removeItem(at: f)
            return true
        }
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(identity.utf8))) as? [String: Any],
              let deviceId = parsed["device_id"] as? String,
              let app = parsed["app"] as? [String: String] else {
            try? FileManager.default.removeItem(at: f)
            health.count("corrupt", seg.events.count)
            return true
        }
        let drops = health.snapshot()
        let queueDepth = outbox.sealed().count
        var attempt = 0
        while true {
            let body = self.body(deviceId: deviceId, app: app, events: seg.events, drops: drops,
                                 queueDepth: queueDepth, now: clock())
            // A body we can't gzip counts as a network error (retried, then parked).
            let (status, retryAfterMs) = Self.gzip(Data(body.utf8)).map { post($0, apiKey: apiKey, url: url) } ?? (-1, 0)
            let ok = (200..<300).contains(status)
            // R12: any other 4xx is never retried or queued.
            let rejected = (400..<500).contains(status) && status != 429
            if ok || rejected {
                try? FileManager.default.removeItem(at: f)
                parkedUntil[f.lastPathComponent] = nil
                if ok { health.subtract(drops) } else { health.count("rejected", seg.events.count) }
                return true
            }
            // A Retry-After beyond the in-process schedule parks instead of holding the only sender queue.
            if attempt == retryMs.count || retryAfterMs > retryMs[retryMs.count - 1] {
                parkedUntil[f.lastPathComponent] = clock() + max(Self.parkMs, retryAfterMs)
                return false
            }
            let base = retryMs[attempt]
            sleep(max(base + Int64.random(in: 0...(base / 4)), retryAfterMs))
            attempt += 1
        }
    }

    /// - Returns: HTTP status, or -1 for a network error / bad endpoint; and `Retry-After` in ms.
    private func post(_ gzipped: Data, apiKey: String, url: String) -> (Int, Int64) {
        guard let endpoint = URL(string: url) else { return (-1, 0) }
        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = gzipped
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        var result = (-1, Int64(0))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                result = (http.statusCode, Self.retryAfterMs(http.value(forHTTPHeaderField: "Retry-After")))
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    /// Contract-4 envelope, closed at 8 keys (R3). Identity is the segment's frozen first line
    /// (T4); `sdk` and `contract_version` are current; `timestamp` is this attempt's (R13).
    private func body(deviceId: String, app: [String: String], events: [String], drops: [String: Int],
                      queueDepth: Int, now: Int64) -> String {
        let timestamp = Self.quote(Self.rfc3339(now))
        var all = events
        if !drops.isEmpty {
            // R4: unprefixed counters, counted in batch_size, stamped at flush time.
            let attrs = drops.sorted { $0.key < $1.key }.map { Self.quote($0.key) + ":\($0.value)" }
                + [#""queue_depth":\#(queueDepth)"#]
            all.append(#"{"type":"event","eventName":"sdk.health","timestamp":"# + timestamp
                + #","attributes":{"# + attrs.joined(separator: ",") + "}}")
        }
        return #"{"type":"telemetry_batch","contract_version":"# + Self.quote(Self.contractVersion)
            + #","timestamp":"# + timestamp
            + #","batch_size":\#(all.count),"device_id":"# + Self.quote(deviceId)
            + #","sdk":{"name":"cordova","version":"# + Self.quote(sdkVersion)
            + #"},"app":"# + Self.appJSON(app)
            + #","events":["# + all.joined(separator: ",") + "]}"
    }

    private static let rfc3339Format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    static func rfc3339(_ ms: Int64) -> String {
        rfc3339Format.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func quote(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// `Retry-After` in delta-seconds; HTTP-date form ignored.
    private static func retryAfterMs(_ header: String?) -> Int64 {
        guard let s = header?.trimmingCharacters(in: .whitespaces), let secs = Int64(s) else { return 0 }
        return max(0, secs) * 1000
    }

    /// T5: gzip (zlib, windowBits 15 + 16 = gzip wrapper).
    static func gzip(_ data: Data) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var input = [UInt8](data)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        var status = Z_OK
        input.withUnsafeMutableBufferPointer { inp in
            stream.next_in = inp.baseAddress
            stream.avail_in = uInt(inp.count)
            while status == Z_OK {
                buf.withUnsafeMutableBufferPointer { b in
                    stream.next_out = b.baseAddress
                    stream.avail_out = uInt(b.count)
                    status = deflate(&stream, Z_FINISH)
                    out.append(b.baseAddress!, count: b.count - Int(stream.avail_out))
                }
            }
        }
        return status == Z_STREAM_END ? out : nil
    }
}
