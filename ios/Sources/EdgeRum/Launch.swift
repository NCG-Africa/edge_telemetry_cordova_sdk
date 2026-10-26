import Foundation

/// Spec A5, A7, E3, E17: the one `app.start` per cold launch, assembled from the native process
/// start + WebView created marks and the JS `markPhase` phases; and the persisted marker a
/// launch without `deviceready` leaves for the next one. The Android `Launch`, ported.
final class Launch {
    static let timeoutKey = "edge_rum_cordova.deviceready_timeout"
    /// A5: `markReady()` counts when it lands within this long of `deviceready`.
    static let readyWindowMs: Int64 = 30_000
    static let deviceready = "deviceready"
    static let ready = "markReady"
    /// JS phases (A5) → `app.start.*` keys, in launch order.
    private static let phases = [
        ("responseEnd", "app.start.response_end_ms"),
        ("DOMContentLoaded", "app.start.dom_content_loaded_ms"),
        ("load", "app.start.load_ms"),
        (deviceready, "app.start.deviceready_ms"),
        (ready, "app.start.mark_ready_ms"),
    ]

    private let processStart: Int64
    private let webViewCreated: Int64
    private let lock = NSLock()
    private var marks: [String: Int64] = [:]
    private var emitted = false

    init(processStart: Int64, webViewCreated: Int64) {
        self.processStart = processStart
        self.webViewCreated = webViewCreated
    }

    /// Records a phase (first mark wins: a WebView reload re-sends them). Returns `app.start` when
    /// this mark completes it: `markReady` with `deviceready` seen, inside the window.
    func mark(_ phase: String, _ ts: Int64) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard !emitted, marks[phase] == nil, Self.phases.contains(where: { $0.0 == phase }) else { return nil }
        if phase == Self.ready, let d = marks[Self.deviceready], ts - d > Self.readyWindowMs { return nil }
        marks[phase] = ts
        return marks[Self.deviceready] != nil && marks[Self.ready] != nil ? emit() : nil
    }

    var devicereadySeen: Bool {
        lock.lock(); defer { lock.unlock() }
        return marks[Self.deviceready] != nil
    }

    /// Window over (or app backgrounded): `app.start` without `markReady`, if `deviceready` came and it's still owed.
    func finish() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return emitted || marks[Self.deviceready] == nil ? nil : emit()
    }

    private func emit() -> [String: Any] {
        emitted = true
        let d = marks[Self.deviceready]!
        let end = marks[Self.ready].map { max($0, d) } ?? d
        var a: [String: Any] = [
            "app.start.type": "cold",
            "app.start.duration_ms": max(0, end - processStart),
            "app.start.webview_created_ms": max(0, webViewCreated - processStart),
        ]
        for (phase, key) in Self.phases {
            if let ts = marks[phase] { a[key] = max(0, ts - processStart) }
        }
        return Crash.record("app.start", end, a)
    }

    /// A7: no `deviceready` by the timeout → a marker for the next launch to report.
    static func timedOut(_ defaults: UserDefaults, timeoutMs: Int64, now: Int64) {
        defaults.set(Session.line(["at": now, "timeout_ms": timeoutMs]), forKey: timeoutKey)
    }

    /// E17: last launch's marker as `cordova.deviceready_timeout`, or nil; the marker is gone either way.
    static func takeTimeout(_ defaults: UserDefaults) -> [String: Any]? {
        guard let raw = defaults.string(forKey: timeoutKey) else { return nil }
        defaults.removeObject(forKey: timeoutKey)
        guard let m = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let at = (m["at"] as? NSNumber)?.int64Value,
              let ms = (m["timeout_ms"] as? NSNumber)?.int64Value else { return nil }
        return Crash.record("cordova.deviceready_timeout", at, ["cordova.deviceready_timeout_ms": ms])
    }
}
