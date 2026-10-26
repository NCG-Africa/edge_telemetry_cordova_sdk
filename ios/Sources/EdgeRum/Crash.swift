import EdgeRumCrash
import Foundation

/// Spec A3, E12, E15, Y3: the native breadcrumb mirror and the `app.crash` / `app.hang` records
/// built from it. A crash can't run Swift: the C handlers (`edge_rum_crash.c`) leave a plain-text
/// report that `takeReport()` turns into an event next launch, under the identity, session and
/// breadcrumbs `saveContext` saved before it died.
final class Crash {
    static let breadcrumbs = 50
    /// Sibling `CrashReportingService` cap; whole frames are kept.
    private static let maxStack = 2000
    private static let signalNames = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 10: "SIGBUS", 11: "SIGSEGV"]
    private static let exceptionNames = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC",
                                         6: "EXC_BREAKPOINT"]

    /// A record ready for `Outbox.writeSolo`.
    struct Pending {
        let identity: String
        let event: String
    }

    /// Y3: one frame in the iOS sibling's `StackFrames` format, `image +0x<offset> <dladdr hint>`.
    struct Frame {
        let pc: UInt
        /// Image load base; 0 when no image holds `pc`.
        let base: UInt
        let uuid: String
        let path: String
        let symbol: String?

        var name: String { (path as NSString).lastPathComponent }

        /// `image +0x<offset>`; the absolute address when unresolved.
        var location: String {
            base == 0 ? "0x" + String(pc, radix: 16) : name + " +0x" + String(pc &- base, radix: 16)
        }

        var text: String { location + (base == 0 ? "" : symbol.map { " " + $0 } ?? "") }
    }

    let reportPath: String
    private let context: URL
    private let clock: () -> Int64
    private let lock = NSLock()
    private var crumbs: [Any] = []
    private var screen: String?

    init(dir: URL, clock: @escaping () -> Int64 = Outbox.now) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reportPath = dir.appendingPathComponent("crash_report.txt").path
        context = dir.appendingPathComponent("crash_context.json")
        self.clock = clock
    }

    /// A3: mirrors an `enqueue` hand-off's breadcrumbs (last 50) and its last screen.
    func mirror(_ payload: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        crumbs += payload["breadcrumbs"] as? [Any] ?? []
        if crumbs.count > Self.breadcrumbs { crumbs.removeFirst(crumbs.count - Self.breadcrumbs) }
        for case let e as [String: Any] in payload["events"] as? [Any] ?? [] {
            if let to = (e["attributes"] as? [String: Any])?["navigation.to_screen"] as? String, !to.isEmpty { screen = to }
        }
    }

    /// E15: main-thread stall at or past the line. Not fatal, not handled; main stack only.
    func hang(durationMs: Int64, frames: [Frame]) -> [String: Any] {
        var a: [String: Any] = [
            "message": "Main thread blocked for \(durationMs) ms",
            "crash_thread": "main",
            "crash_is_main_thread": true,
            "is_fatal": false,
            "handled": false,
            "hang_duration_ms": durationMs,
        ]
        Self.stack(frames, into: &a)
        lock.lock()
        a["screen_name"] = screen
        lock.unlock()
        return Self.record("app.hang", clock(), a)
    }

    /// What a crash report can't know: the identity, session, user and breadcrumbs of the moment.
    /// Saved after every hand-off; best effort.
    func saveContext(identity: String, sessionId: String?, userId: String?) {
        var a: [String: Any] = [:]
        a["session.id"] = sessionId
        a["user.id"] = userId
        lock.lock()
        a["crash.breadcrumbs"] = Self.json(crumbs)
        a["screen_name"] = screen
        lock.unlock()
        guard let line = Session.line(["identity": identity, "attributes": a]) else { return }
        try? Data(line.utf8).write(to: context, options: .atomic)
    }

    /// Last launch's crash, if any, as a solo-segment record under the crashed build's identity
    /// (T4); the report is deleted either way. One without a usable context (or torn) is dropped.
    func takeReport() -> Pending? {
        guard let report = try? String(contentsOfFile: reportPath, encoding: .utf8) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: reportPath) }
        guard let data = try? Data(contentsOf: context),
              let ctx = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let identity = ctx["identity"] as? String,
              let event = Self.native(report, ctx["attributes"] as? [String: Any] ?? [:]),
              let line = Session.line(event) else { return nil }
        return Pending(identity: identity, event: line)
    }

    /// P7 `disable()` / `reset()`: nothing from before survives.
    func clear() {
        try? FileManager.default.removeItem(atPath: reportPath)
        try? FileManager.default.removeItem(at: context)
        lock.lock()
        crumbs = []
        screen = nil
        lock.unlock()
    }

    /// E12: the record for a C handler's report, `context` merged in; nil when torn.
    static func native(_ report: String, _ context: [String: Any]) -> [String: Any]? {
        var fields: [String: String] = [:]
        var frames: [Frame] = []
        for line in report.split(separator: "\n") {
            let kv = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let value = kv.count > 1 ? String(kv[1]) : ""
            if kv[0] == "frame" {
                if let f = frame(value) { frames.append(f) }
            } else {
                fields[String(kv[0])] = value
            }
        }
        guard let at = fields["time_ms"].flatMap({ Int64($0) }) else { return nil }
        var a: [String: Any]
        if let exc = fields["exception"].flatMap({ Int($0) }) {
            let name = exceptionNames[exc] ?? "EXC_\(exc)"
            a = ["message": "\(name), code 0x\(fields["mach_code"] ?? "0"), subcode 0x\(fields["mach_subcode"] ?? "0")",
                 "exception_type": name, "cause": "mach exception \(exc)"]
        } else if let sig = fields["signal"].flatMap({ Int($0) }) {
            let name = signalNames[sig] ?? "SIG\(sig)"
            a = ["message": "\(name), code \(fields["code"] ?? "0"), fault addr 0x\(fields["fault_addr"] ?? "0")",
                 "exception_type": name, "cause": "signal \(sig)"]
        } else {
            return nil
        }
        let main = fields["main"] == "1"
        let thread = fields["thread"] ?? ""
        if !thread.isEmpty || main { a["crash_thread"] = thread.isEmpty ? "main" : thread }
        a["crash_is_main_thread"] = main
        a["error_context"] = frames.first?.location ?? "unknown"
        stack(frames, into: &a)
        a["is_fatal"] = true
        a["handled"] = false
        a.merge(context) { _, saved in saved }
        return record("app.crash", at, a)
    }

    /// `<pc>\t<base>\t<uuid>\t<path>\t<symbol>`, hex, `-` = none.
    private static func frame(_ value: String) -> Frame? {
        let f = value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, let pc = UInt(f[0], radix: 16) else { return nil }
        func opt(_ s: String) -> String? { s == "-" ? nil : s }
        return Frame(pc: pc, base: opt(f[1]).flatMap { UInt($0, radix: 16) } ?? 0, uuid: opt(f[2]) ?? "",
                     path: opt(f[3]) ?? "", symbol: opt(f[4]))
    }

    /// Y3: frames for return addresses of this process.
    static func frames(_ pcs: [UInt]) -> [Frame] {
        pcs.map { pc in
            var base: UInt = 0
            var uuid = [CChar](repeating: 0, count: 33)
            var path: UnsafePointer<CChar>?
            var symbol: UnsafePointer<CChar>?
            guard edge_rum_image(pc, &base, &uuid, &path, &symbol) != 0 else {
                return Frame(pc: pc, base: 0, uuid: "", path: "", symbol: nil)
            }
            return Frame(pc: pc, base: base, uuid: String(cString: uuid), path: path.map { String(cString: $0) } ?? "",
                         symbol: symbol.map { String(cString: $0) })
        }
    }

    /// E15: the main thread's frames, read from another thread; empty on main itself.
    static func mainStack() -> [Frame] {
        var pcs = [UInt](repeating: 0, count: 64)
        let n = Int(edge_rum_main_stack(&pcs, Int32(pcs.count)))
        return frames(Array(pcs.prefix(n)))
    }

    /// `stacktrace` (whole frames up to `maxStack` bytes, as the sibling's `StackFrames.capped`) and
    /// `crash.binary_images`, the images those frames reference (Y3 symbolication keys).
    private static func stack(_ frames: [Frame], into a: inout [String: Any]) {
        var kept: [Frame] = []
        var size = -1 // no separator before the first frame
        for f in frames {
            size += f.text.utf8.count + 1
            if size > maxStack { break }
            kept.append(f)
        }
        guard !kept.isEmpty else { return }
        a["stacktrace"] = kept.map(\.text).joined(separator: "\n")
        var seen = Set<UInt>()
        var images: [[String: String]] = []
        for f in kept where f.base != 0 && seen.insert(f.base).inserted {
            var image = ["name": f.name, "base": "0x" + String(f.base, radix: 16)]
            if !f.uuid.isEmpty { image["uuid"] = f.uuid }
            images.append(image)
        }
        if !images.isEmpty { a["crash.binary_images"] = json(images) }
    }

    private static func record(_ name: String, _ at: Int64, _ attrs: [String: Any]) -> [String: Any] {
        ["type": "event", "eventName": name, "timestamp": Sender.rfc3339(at), "attributes": attrs]
    }

    /// Compact, sorted keys: the wire string is stable.
    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
