import Foundation
import Security

/// Spec E1, S1–S8: the native session and the gate every event passes at outbox append. One
/// record (id, roll, counters, caps) persisted per hand-off, so a WebView reload or a relaunch
/// inside the idle timeout resumes the same session.
final class Session {
    static let idleMs: Int64 = 30 * 60_000
    static let recordKey = "edge_rum_cordova.session"
    static let totalKey = "edge_rum_cordova.total_sessions"
    /// `session.visited_screens` keeps the first 50; `session.screen_count` counts them all (S6).
    private static let maxScreens = 50
    /// S4 per-session caps.
    static let capErrors = 50
    static let capErrorsPerKey = 5
    static let capInteractions = 200
    static let capBridge = 50
    static let capBridgePerCall = 5
    static let capCustom = 500
    /// A JSC frame (`fn@url:line[:col]`); a V8 message line with an `@` in it doesn't match.
    private static let jscFrame = #"^[^\s@]*@\S+:\d+(:\d+)?$"#

    /// S2: never sampled out, never capped (fatal `app.crash` checked separately).
    private static let exempt: Set<String> = ["session.started", "session.finalized", "app.anr", "app.exit",
                                              "app.start", "cordova.deviceready_timeout", "sdk.health"]
    /// E7, E21, E22: SDK metrics; any other metric name is the host's (`measure()` / `time()`).
    private static let sdkMetrics: Set<String> = ["LCP", "INP", "CLS", "FCP", "TTFB", "resource_timing", "memory_usage"]

    private let defaults: UserDefaults
    private let health: Health
    private let clock: () -> Int64
    private let rate: Double
    private let roll: () -> Double
    private let newId: () -> String
    private let userId: () -> String?
    private let lock = NSLock()

    private var current: String?
    private var startedAt: Int64 = 0
    private var lastActivityAt: Int64 = 0
    private var isSampled = true
    private var eventCount = 0
    private var metricCount = 0
    private var screenCount = 0
    private var screens: [String] = []
    private var caps: [String: Int] = [:]

    init(defaults: UserDefaults, health: Health, clock: @escaping () -> Int64 = Outbox.now, sampleRate: Double,
         roll: @escaping () -> Double = Session.secureRoll, newId: @escaping () -> String = { DeviceId.newId("session") },
         userId: @escaping () -> String?) {
        self.defaults = defaults
        self.health = health
        self.clock = clock
        // C1: clamped 0..1; NaN keeps everything.
        rate = sampleRate.isNaN ? 1 : min(1, max(0, sampleRate))
        self.roll = roll
        self.newId = newId
        self.userId = userId
    }

    /// C1 `EdgeRumSampleRate`; missing or unparseable → 1.
    static func sampleRate(_ pref: String?) -> Double {
        pref.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 1
    }

    /// S1: copy of the iOS sibling's `Sampler.secureUniformDouble`: top 53 bits of 8 secure bytes, in [0, 1).
    static func secureRoll() -> Double {
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, bytes.count)
        }
        let u64 = bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
        return Double(u64 >> 11) * (1.0 / Double(UInt64(1) << 53))
    }

    var id: String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var sampled: Bool {
        lock.lock(); defer { lock.unlock() }
        return isSampled
    }

    /// Launch / `enable()`: resumes the recorded session if still live, else finalizes it and starts one.
    func begin() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if current == nil { load() }
        var out: [String] = []
        if current != nil { rotate(&out) } else { start(&out) }
        return out
    }

    /// Rotation check without activity (foreground). Bookends to append, or none.
    func rotateIfIdle() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        rotate(&out)
        return out
    }

    /// `reset()`: a fresh session; the old one is discarded with the outbox, not finalized.
    func restart() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        start(&out)
        return out
    }

    /// `disable()`: forgets the session; nothing is finalized for it.
    func end() {
        lock.lock(); defer { lock.unlock() }
        current = nil
        defaults.removeObject(forKey: Self.recordKey)
    }

    /// The gate (S5): counts each event (S6), drops it if sampled out or capped, stamps
    /// `session.id` / `user.id` on what's kept. Returns the lines to append, bookends first.
    func admit(_ events: [[String: Any]]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard current != nil else { return [] }
        var out: [String] = []
        rotate(&out)
        gate(events, &out)
        lastActivityAt = clock()
        persist()
        return out
    }

    private func rotate(_ out: inout [String]) {
        guard current != nil, clock() - lastActivityAt > Self.idleMs else { return }
        out.append(finalized())
        start(&out)
    }

    private func gate(_ events: [[String: Any]], _ out: inout [String]) {
        for var e in events {
            let attrs = e["attributes"] as? [String: Any] ?? [:]
            let metric = e["type"] as? String == "metric"
            let name = e[metric ? "metricName" : "eventName"] as? String ?? ""
            count(metric, name, attrs)
            if !Self.isExempt(name, attrs) {
                guard isSampled else { continue }
                if let reason = capReason(metric, name, attrs) {
                    health.count(reason, 1)
                    continue
                }
            }
            e["attributes"] = stamp(attrs)
            if let line = Self.line(e) { out.append(line) }
        }
    }

    private func count(_ metric: Bool, _ name: String, _ attrs: [String: Any]) {
        if metric { metricCount += 1 } else { eventCount += 1 }
        guard name == "navigation", let screen = attrs["navigation.to_screen"] as? String, !screen.isEmpty else { return }
        screenCount += 1
        if screens.count < Self.maxScreens { screens.append(screen) }
    }

    private static func isExempt(_ name: String, _ attrs: [String: Any]) -> Bool {
        exempt.contains(name) || (name == "app.crash" && attrs["is_fatal"] as? Bool == true)
    }

    /// S4 / S7: the `sdk.health` reason when a cap is hit, else nil (and the event is counted).
    private func capReason(_ metric: Bool, _ name: String, _ attrs: [String: Any]) -> String? {
        if metric && Self.sdkMetrics.contains(name) { return nil }
        func str(_ k: String) -> String { attrs[k] as? String ?? "" }
        switch metric ? "custom_event" : name {
        case "app.crash":
            let key = "error:" + str("exception_type") + "|" + Self.topFrame(str("stacktrace"))
            return allow("error", Self.capErrors, key, Self.capErrorsPerKey) ? nil : "cap.error"
        case "ui.interaction":
            return allow("interaction", Self.capInteractions) ? nil : "cap.interaction"
        case "bridge.call":
            let call = "bridge:" + str("bridge.service") + "|" + str("bridge.action")
            return allow("bridge", Self.capBridge, call, Self.capBridgePerCall) ? nil : "cap.bridge"
        case "custom_event", "task.complete": // custom_event includes host metrics
            return allow("custom", Self.capCustom) ? nil : "cap.custom"
        default:
            return nil
        }
    }

    /// Takes a slot from the total and, if given, the per-key cap; neither is taken when either is full.
    private func allow(_ total: String, _ totalLimit: Int, _ key: String? = nil, _ keyLimit: Int = 0) -> Bool {
        let t = caps[total] ?? 0
        let k = key.flatMap { caps[$0] } ?? 0
        if t >= totalLimit || (key != nil && k >= keyLimit) { return false }
        caps[total] = t + 1
        if let key { caps[key] = k + 1 }
        return true
    }

    // ponytail: first line that looks like a frame (V8 `at …`, JSC `fn@url`); frames' parsed form is issue 11's.
    private static func topFrame(_ stack: String) -> String {
        for line in stack.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("at ") || l.range(of: jscFrame, options: .regularExpression) != nil { return l }
        }
        return ""
    }

    private func stamp(_ attrs: [String: Any]) -> [String: Any] {
        var a = attrs
        a["session.id"] = current
        if let user = userId() { a["user.id"] = user }
        return a
    }

    private func start(_ out: inout [String]) {
        let now = clock()
        current = newId()
        startedAt = now
        lastActivityAt = now
        isSampled = rate >= 1 || roll() < rate // S1
        eventCount = 0
        metricCount = 0
        screenCount = 0
        screens = []
        caps = [:]
        // Missing or unreadable count: this one counts as first.
        let total = defaults.integer(forKey: Self.totalKey) + 1
        defaults.set(total, forKey: Self.totalKey)
        persist()
        out.append(bookend("session.started", now, [
            "session.start_time": Sender.rfc3339(startedAt),
            "session.is_first_session": total == 1,
            "session.total_sessions": total,
        ]))
    }

    /// E1: backdated to the last activity, so idle time isn't session time.
    private func finalized() -> String {
        bookend("session.finalized", lastActivityAt, [
            "session.start_time": Sender.rfc3339(startedAt),
            "session.duration_ms": max(0, lastActivityAt - startedAt),
            "session.event_count": eventCount,
            "session.metric_count": metricCount,
            "session.screen_count": screenCount,
            "session.visited_screens": screens.joined(separator: ","),
        ])
    }

    private func bookend(_ name: String, _ at: Int64, _ attrs: [String: Any]) -> String {
        var a = attrs
        if rate < 1 { a["session.sampled"] = isSampled } // S3
        let e: [String: Any] = ["type": "event", "eventName": name, "timestamp": Sender.rfc3339(at), "attributes": stamp(a)]
        return Self.line(e) ?? ""
    }

    /// One NDJSON event line; nil for an event JSON can't represent.
    static func line(_ e: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(e),
              let data = try? JSONSerialization.data(withJSONObject: e, options: .withoutEscapingSlashes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func persist() {
        let record: [String: Any] = [
            "id": current ?? "", "start": startedAt, "last": lastActivityAt, "sampled": isSampled,
            "events": eventCount, "metrics": metricCount, "screen_count": screenCount, "screens": screens, "caps": caps,
        ]
        defaults.set(Self.line(record), forKey: Self.recordKey)
    }

    /// A missing or corrupt record leaves no session; the caller starts one.
    private func load() {
        guard let raw = defaults.string(forKey: Self.recordKey),
              let r = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let id = r["id"] as? String, !id.isEmpty,
              let start = (r["start"] as? NSNumber)?.int64Value, let last = (r["last"] as? NSNumber)?.int64Value,
              let sampled = r["sampled"] as? Bool, let events = r["events"] as? Int, let metrics = r["metrics"] as? Int,
              let screenCount = r["screen_count"] as? Int, let screens = r["screens"] as? [String],
              let caps = r["caps"] as? [String: Int] else { return }
        startedAt = start
        lastActivityAt = last
        isSampled = sampled
        eventCount = events
        metricCount = metrics
        self.screenCount = screenCount
        self.screens = screens
        self.caps = caps
        current = id
    }
}
