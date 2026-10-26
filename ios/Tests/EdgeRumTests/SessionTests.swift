@testable import EdgeRum
import XCTest

final class SessionTests: XCTestCase {
    var defaults: UserDefaults!
    let suite = "edge_rum_tests_\(UUID().uuidString)"
    var dir: URL!
    var health: Health!
    var now: Int64 = 1_793_008_800_000 // 2026-10-26T10:00:00.000Z
    var roll = 0.0
    var ids = 0
    var userId: String?

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge_rum_\(UUID().uuidString)")
        health = Health(dir: dir)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    func session(_ rate: Double) -> Session {
        Session(defaults: defaults, health: health, clock: { [unowned self] in now }, sampleRate: rate,
                roll: { [unowned self] in roll }, newId: { [unowned self] in ids += 1; return "session_\(ids)" },
                userId: { [unowned self] in userId })
    }

    static func event(_ name: String, _ attrs: [String: Any] = [:]) -> [String: Any] {
        ["type": "event", "eventName": name, "timestamp": "t", "attributes": attrs]
    }

    static func metric(_ name: String) -> [String: Any] {
        ["type": "metric", "metricName": name, "value": 1, "attributes": [String: Any]()]
    }

    static func crash(_ type: String, _ stack: String) -> [String: Any] {
        event("app.crash", ["is_fatal": false, "handled": true, "exception_type": type, "stacktrace": stack])
    }

    static func bridge(_ service: String, _ action: String) -> [String: Any] {
        event("bridge.call", ["bridge.service": service, "bridge.action": action])
    }

    static func names(_ lines: [String]) -> [String] {
        lines.map { l in let e = json(l); return (e["eventName"] ?? e["metricName"]) as? String ?? "" }
    }

    static func attrs(_ line: String) -> [String: Any] {
        json(line)["attributes"] as? [String: Any] ?? [:]
    }

    static func repeated(_ e: [String: Any], _ n: Int) -> [[String: Any]] {
        Array(repeating: e, count: n)
    }

    func testFirstBeginStartsFirstSession() {
        let lines = session(1).begin()
        XCTAssertEqual(Self.names(lines), ["session.started"])
        let a = Self.attrs(lines[0])
        XCTAssertEqual(a["session.id"] as? String, "session_1")
        XCTAssertEqual(a["session.start_time"] as? String, "2026-10-26T10:00:00.000Z")
        XCTAssertEqual(a["session.is_first_session"] as? Bool, true)
        XCTAssertEqual(a["session.total_sessions"] as? Int, 1)
        XCTAssertNil(a["session.sampled"], "S3: absent at rate 1")
    }

    func testStampsSessionAndUserOnEveryEvent() {
        let s = session(1)
        _ = s.begin()
        userId = "u1"
        let a = Self.attrs(s.admit([Self.event("navigation")])[0])
        XCTAssertEqual(a["session.id"] as? String, "session_1")
        XCTAssertEqual(a["user.id"] as? String, "u1")
    }

    func testIdleTimeoutRotatesWithBackdatedFinalizeAndFreshCounters() {
        let s = session(1)
        _ = s.begin()
        _ = s.admit([Self.event("navigation", ["navigation.to_screen": "/home"]), Self.metric("LCP")])
        now += 60_000
        _ = s.admit([Self.event("navigation", ["navigation.to_screen": "/cart"])])
        now += Session.idleMs + 1

        let out = s.admit([Self.event("custom_event")])
        XCTAssertEqual(Self.names(out), ["session.finalized", "session.started", "custom_event"])
        let fin = Self.attrs(out[0])
        XCTAssertEqual(fin["session.id"] as? String, "session_1")
        XCTAssertEqual(fin["session.duration_ms"] as? Int, 60_000)
        XCTAssertEqual(fin["session.event_count"] as? Int, 2)
        XCTAssertEqual(fin["session.metric_count"] as? Int, 1)
        XCTAssertEqual(fin["session.screen_count"] as? Int, 2)
        XCTAssertEqual(fin["session.visited_screens"] as? String, "/home,/cart")
        let started = Self.attrs(out[1])
        XCTAssertEqual(started["session.id"] as? String, "session_2")
        XCTAssertEqual(started["session.is_first_session"] as? Bool, false)
        XCTAssertEqual(started["session.total_sessions"] as? Int, 2)
        XCTAssertEqual(Self.attrs(out[2])["session.id"] as? String, "session_2")
        XCTAssertEqual(s.id, "session_2")
    }

    func testRotateIfIdleOnlyRotatesPastTheTimeout() {
        let s = session(1)
        _ = s.begin()
        now += Session.idleMs
        XCTAssertTrue(s.rotateIfIdle().isEmpty)
        now += 1
        XCTAssertEqual(Self.names(s.rotateIfIdle()), ["session.finalized", "session.started"])
    }

    func testSessionAndRollSurviveWebViewReloadAndRelaunchWithinTimeout() {
        roll = 0.9
        let s = session(0.5)
        _ = s.begin()
        XCTAssertFalse(s.sampled)
        _ = s.admit([Self.event("navigation")])

        now += 1_000
        roll = 0 // a fresh roll would keep the session; the persisted one must win
        let again = session(0.5)
        XCTAssertTrue(again.begin().isEmpty, "resumed, no bookends")
        XCTAssertEqual(again.id, "session_1")
        XCTAssertFalse(again.sampled)
    }

    func testRelaunchAfterTimeoutFinalizesRecordedSession() {
        let s = session(1)
        _ = s.begin()
        _ = s.admit([Self.event("navigation")])
        now += Session.idleMs + 1

        let out = session(1).begin()
        XCTAssertEqual(Self.names(out), ["session.finalized", "session.started"])
        XCTAssertEqual(Self.attrs(out[0])["session.event_count"] as? Int, 1)
    }

    func testSampledOutKeepsOnlyExemptAndCountsEverythingUncounted() {
        roll = 0.9
        let s = session(0.5)
        XCTAssertEqual(Self.attrs(s.begin()[0])["session.sampled"] as? Bool, false)

        let input = [
            Self.event("navigation"), Self.metric("LCP"), Self.event("app.hang"),
            Self.event("app.crash", ["is_fatal": false]),
            Self.event("app.crash", ["is_fatal": true]), Self.event("app.anr"), Self.event("app.exit"),
            Self.event("app.start"), Self.event("cordova.deviceready_timeout"), Self.event("sdk.health"),
        ]
        XCTAssertEqual(Self.names(s.admit(input)),
                       ["app.crash", "app.anr", "app.exit", "app.start", "cordova.deviceready_timeout", "sdk.health"])
        XCTAssertEqual(health.snapshot(), [:], "S7: sampled-out drops not counted")

        now += Session.idleMs + 1
        let fin = Self.attrs(s.rotateIfIdle()[0])
        XCTAssertEqual(fin["session.event_count"] as? Int, 9, "S6: counted before gates")
        XCTAssertEqual(fin["session.metric_count"] as? Int, 1)
        XCTAssertEqual(fin["session.sampled"] as? Bool, false)
    }

    func testSampledInAtFractionalRateSaysSo() {
        roll = 0.1
        let s = session(0.5)
        XCTAssertEqual(Self.attrs(s.begin()[0])["session.sampled"] as? Bool, true)
        XCTAssertEqual(s.admit([Self.event("navigation")]).count, 1)
    }

    func testSampleRateIsClampedAndUnparseableKeepsAll() {
        roll = 0
        let none = session(-1)
        _ = none.begin()
        XCTAssertFalse(none.sampled)
        defaults.removePersistentDomain(forName: suite)
        roll = 0.999
        let all = session(7)
        XCTAssertNil(Self.attrs(all.begin()[0])["session.sampled"], "clamped to 1: no session.sampled")
        XCTAssertTrue(all.sampled)
        XCTAssertEqual(Session.sampleRate("0.25"), 0.25)
        XCTAssertEqual(Session.sampleRate(" abc "), 1)
        XCTAssertEqual(Session.sampleRate(nil), 1)
    }

    func testSecureRollIsInUnitInterval() {
        for _ in 0..<100 {
            let r = Session.secureRoll()
            XCTAssertTrue(r >= 0 && r < 1, "\(r)")
        }
    }

    func testInteractionCap() {
        let s = session(1)
        _ = s.begin()
        XCTAssertEqual(s.admit(Self.repeated(Self.event("ui.interaction"), 202)).count, 200)
        XCTAssertEqual(health.snapshot(), ["events_dropped.cap.interaction": 2])
    }

    func testCustomCapIsCombinedAcrossCustomHostMetricsAndTasks() {
        let s = session(1)
        _ = s.begin()
        XCTAssertEqual(s.admit(Self.repeated(Self.event("custom_event"), 300)).count
            + s.admit(Self.repeated(Self.metric("checkout_ms"), 150)).count
            + s.admit(Self.repeated(Self.event("task.complete"), 50)).count, 500)
        XCTAssertEqual(s.admit([Self.event("custom_event"), Self.metric("cart"), Self.event("task.complete")]).count, 0)
        XCTAssertEqual(s.admit([Self.metric("LCP")]).count, 1)
        XCTAssertEqual(health.snapshot(), ["events_dropped.cap.custom": 3])
    }

    func testErrorCapPerDedupKeyThenTotal() {
        let s = session(1)
        _ = s.begin()
        XCTAssertEqual(s.admit(Self.repeated(Self.crash("TypeError", "TypeError: x\n    at f (app:///main.js:1:2)"), 6)).count, 5)
        // Same type, different top frame → own key.
        XCTAssertEqual(s.admit(Self.repeated(Self.crash("TypeError", "TypeError: x\n    at g (app:///main.js:9:9)"), 5)).count, 5)
        for i in 0..<8 { _ = s.admit(Self.repeated(Self.crash("E\(i)", ""), 5)) }
        XCTAssertEqual(s.admit([Self.crash("New", "")]).count, 0, "50 total")
        XCTAssertEqual(s.admit([Self.event("app.crash", ["is_fatal": true])]).count, 1, "fatal never capped")
        XCTAssertEqual(health.snapshot(), ["events_dropped.cap.error": 2])
    }

    func testBridgeCapPerServiceActionThenTotal() {
        let s = session(1)
        _ = s.begin()
        XCTAssertEqual(s.admit(Self.repeated(Self.bridge("Camera", "take"), 7)).count, 5)
        XCTAssertEqual(s.admit(Self.repeated(Self.bridge("Camera", "pick"), 5)).count, 5)
        for i in 0..<8 { _ = s.admit(Self.repeated(Self.bridge("S\(i)", "a"), 5)) }
        XCTAssertEqual(s.admit([Self.bridge("Other", "a")]).count, 0)
        XCTAssertEqual(health.snapshot(), ["events_dropped.cap.bridge": 3])
    }

    func testScreenCountKeepsCountingPastTheVisitedList() {
        let s = session(1)
        _ = s.begin()
        _ = s.admit(Self.repeated(Self.event("navigation", ["navigation.to_screen": "/a"]), 60))
        now += Session.idleMs + 1
        let fin = Self.attrs(s.rotateIfIdle()[0])
        XCTAssertEqual(fin["session.screen_count"] as? Int, 60)
        XCTAssertEqual((fin["session.visited_screens"] as? String)?.split(separator: ",").count, 50)
    }

    func testAnAtSignInTheMessageIsNotTheTopFrame() {
        let s = session(1)
        _ = s.begin()
        let f = Self.crash("E", "Error: bad a@b.io\n    at f (app:///x.js:1:1)")
        let g = Self.crash("E", "Error: bad a@b.io\n    at g (app:///x.js:2:1)")
        XCTAssertEqual(s.admit(Self.repeated(f, 5) + Self.repeated(g, 4) + [Self.crash("E", "g@app:///x.js:2:1")]).count,
                       10, "distinct frames under one message → distinct keys")
    }

    func testUncappedEventsPassFreely() {
        let s = session(1)
        _ = s.begin()
        XCTAssertEqual(s.admit(Self.repeated(Self.event("http.request"), 1000)).count, 1000)
    }

    func testCapsSurviveReloadAndResetOnRotation() {
        let s = session(1)
        _ = s.begin()
        _ = s.admit(Self.repeated(Self.event("ui.interaction"), 200))
        let reloaded = session(1)
        _ = reloaded.begin()
        XCTAssertEqual(reloaded.admit([Self.event("ui.interaction")]).count, 0)
        now += Session.idleMs + 1
        XCTAssertEqual(reloaded.admit([Self.event("ui.interaction")]).count, 3)
    }

    func testRestartStartsFreshWithoutFinalizingAndEndForgets() {
        let s = session(1)
        _ = s.begin()
        XCTAssertEqual(Self.names(s.restart()), ["session.started"])
        XCTAssertEqual(s.id, "session_2")
        s.end()
        XCTAssertNil(s.id)
        XCTAssertTrue(s.admit([Self.event("navigation")]).isEmpty)
        XCTAssertEqual(Self.names(session(1).begin()), ["session.started"], "ended session not finalized on relaunch")
    }

    func testCorruptRecordStartsANewSession() {
        defaults.set("{not json", forKey: Session.recordKey)
        XCTAssertEqual(Self.names(session(1).begin()), ["session.started"])
    }

    func testBookendsMatchGoldenBatch() throws {
        try assertBookendsGolden(rate: 1, roll: 0, golden: "session.json")
    }

    func testSampledBookendsMatchGoldenBatch() throws {
        try assertBookendsGolden(rate: 0.5, roll: 0.9, golden: "session-sampled.json")
    }

    func assertBookendsGolden(rate: Double, roll r: Double, golden name: String) throws {
        roll = r
        userId = "u1"
        let s = session(rate)
        var lines = s.begin()
        lines += s.admit([Self.event("navigation", ["navigation.to_screen": "/home"])])
        now += 5_000
        lines += s.admit([Self.metric("LCP")])
        now += Session.idleMs + 1
        lines += s.rotateIfIdle()

        StubProtocol.reset()
        let outbox = Outbox(dir: dir, clock: { [unowned self] in now }, health: health)
        try outbox.append(SenderTests.identity, lines)
        outbox.seal()
        let sender = Sender(outbox: outbox, health: health, sdkVersion: "1.0.0", session: StubProtocol.session(),
                            clock: { [unowned self] in now }, sleep: { _ in }, retryMs: [1])
        sender.configure(apiKey: "k", url: SenderTests.endpoint)
        StubProtocol.replies = [.status(200)]
        sender.drain()
        // Event dictionaries are unordered: compare parsed, not byte for byte.
        XCTAssertEqual(json(gunzip(StubProtocol.requests[0].body)) as NSDictionary, json(golden(name)) as NSDictionary)
    }

    func testPassiveSignalsNeitherRotateNorKeepTheSessionAlive() {
        let s = session(1)
        _ = s.begin()
        now += Session.idleMs / 2
        XCTAssertEqual(Self.names(s.admitPassive([Self.event("network_change")])), ["network_change"])
        now += Session.idleMs / 2 + 1
        let late = s.admitPassive([Self.event("memory_pressure")])
        XCTAssertEqual(Self.names(late), ["memory_pressure"], "no rotation from the background")
        XCTAssertEqual(Self.attrs(late[0])["session.id"] as? String, "session_1")
        XCTAssertEqual(Self.names(s.admit([Self.event("custom_event")])), ["session.finalized", "session.started", "custom_event"])
    }
}
