@testable import EdgeRum
import XCTest

/// A cordova-ios 8 `CDVWebViewEngine` stand-in: the selector the hook swizzles, original kept.
@objc(EdgeRumFakeEngine) final class FakeEngine: NSObject {
    var calls = 0
    @objc dynamic func webViewWebContentProcessDidTerminate(_ webView: AnyObject?) { calls += 1 }
}

@objc(EdgeRumFakeEngineTwo) final class FakeEngineTwo: NSObject {
    @objc dynamic func webViewWebContentProcessDidTerminate(_ webView: AnyObject?) {}
}

/// Same selector name, wrong shape (returns a value): the hook must not touch it.
@objc(EdgeRumOddEngine) final class OddEngine: NSObject {
    @objc dynamic func webViewWebContentProcessDidTerminate(_ webView: AnyObject?) -> Int { 1 }
}

final class SignalsTests: XCTestCase {
    var defaults: UserDefaults!
    let suite = "edge_rum_tests_\(UUID().uuidString)"
    var dir: URL!
    var health: Health!
    let now: Int64 = 1_793_008_802_000 // 2026-10-26T10:00:02.000Z

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge_rum_\(UUID().uuidString)")
        health = Health(dir: dir)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    func session() -> Session {
        let s = Session(defaults: defaults, health: health, clock: { [unowned self] in now }, sampleRate: 1,
                        roll: { 0 }, newId: { "session_1" }, userId: { nil })
        _ = s.begin()
        return s
    }

    func attrs(_ e: [String: Any]?) -> [String: Any] {
        e?["attributes"] as? [String: Any] ?? [:]
    }

    /// The lines as one sent batch (`solo`: their own segment, as a crash), compared parsed.
    static func assertGolden(_ name: String, _ dir: URL, _ health: Health, _ lines: [String], solo: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        StubProtocol.reset()
        let sendAt: Int64 = 1_793_008_803_000 // 10:00:03.000Z
        let outbox = Outbox(dir: dir, clock: { sendAt }, health: health)
        if solo {
            for l in lines { try outbox.writeSolo(SenderTests.identity, l) }
        } else {
            try outbox.append(SenderTests.identity, lines)
            outbox.seal()
        }
        let sender = Sender(outbox: outbox, health: health, sdkVersion: "1.0.0", session: StubProtocol.session(),
                            clock: { sendAt }, sleep: { _ in }, retryMs: [1])
        sender.configure(apiKey: "k", url: SenderTests.endpoint)
        StubProtocol.replies = [.status(200)]
        sender.drain()
        let body = try XCTUnwrap(StubProtocol.requests.first.map { gunzip($0.body) }, file: file, line: line)
        XCTAssertEqual(json(body) as NSDictionary, json(golden(name)) as NSDictionary, file: file, line: line)
    }

    // MARK: - E22–E24, E26, E32

    func testMemorySkipsMissingReadingsAndRoundsToTenthMB() {
        XCTAssertEqual(Signals.memory(footprint: 1 << 20, resident: 2 << 20, source: "periodic", at: now).count, 2)
        let one = Signals.memory(footprint: nil, resident: 196_608_000, source: "periodic", at: now)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0]["value"] as? Double, 187.5)
        XCTAssertEqual(attrs(one[0])["memory.type"] as? String, "rss")
    }

    func testPressureWithoutReadingOmitsUsage() {
        let a = attrs(Signals.pressure(footprint: nil, at: now))
        XCTAssertEqual(a["memory.pressure_level"] as? String, "warning")
        XCTAssertNil(a["memory.usage_mb"])
    }

    func testProcessMemoryReadsThisProcess() {
        XCTAssertGreaterThan(Signals.footprintBytes() ?? 0, 0)
        XCTAssertGreaterThan(Signals.residentBytes() ?? 0, 0)
    }

    func testContextStampedButEventKeysWin() {
        let s = session()
        s.context = { ["device.model": "iPhone16,2", "network.type": "wifi"] }
        let a = SessionTests.attrs(s.admit([Signals.network(previous: "wifi", current: "cellular", at: now)])[0])
        XCTAssertEqual(a["device.model"] as? String, "iPhone16,2")
        XCTAssertEqual(a["network.type"] as? String, "cellular")
    }

    func testPassiveAdmitNeitherRotatesNorCountsAsActivity() {
        var t = now
        let s = Session(defaults: defaults, health: health, clock: { t }, sampleRate: 1, roll: { 0 },
                        newId: { "session_1" }, userId: { nil })
        _ = s.begin()
        t += Session.idleMs + 1
        XCTAssertEqual(SessionTests.names(s.admitPassive([Signals.network(previous: "wifi", current: "none", at: t)])),
                       ["network_change"])
        XCTAssertEqual(SessionTests.names(s.rotateIfIdle()), ["session.finalized", "session.started"],
                       "a background signal doesn't keep the session alive")
    }

    /// E32: the context the plugin assembles, as one fixed device.
    static let deviceContext: [String: Any] = [
        "device.platform": "ios",
        "device.platform_version": "26.1",
        "device.model": "iPhone16,2",
        "device.manufacturer": "Apple",
        "device.brand": "Apple",
        "device.locale": "en-KE",
        "device.timezone": "Africa/Nairobi",
        "device.dark_mode": false,
        "device.cpu_abi": "arm64",
        "device.cpu_cores": 6,
        "device.screen_density": 3.0,
        "device.screen_width_px": 1290,
        "device.screen_height_px": 2796,
        "display.refresh_rate": 120,
        "network.type": "wifi",
    ]

    func testGoldenBatches() throws {
        let s = session()
        s.context = { Self.deviceContext }
        try Self.assertGolden("app-lifecycle.json", dir, health, s.admit([Signals.lifecycle("backgrounded", at: now)]))
        s.context = { [:] }
        try Self.assertGolden("memory-usage.json", dir, health,
                              s.admit(Signals.memory(footprint: 196_608_000, resident: 262_144_000, source: "session_start", at: now)))
        try Self.assertGolden("memory-pressure.json", dir, health, s.admit([Signals.pressure(footprint: 196_608_000, at: now)]))
        try Self.assertGolden("network-change.json", dir, health,
                              s.admit([Signals.network(previous: "wifi", current: "none", at: now)]))
    }

    // MARK: - A6, E13

    func testHookGatedOffLeavesTheEngineAlone() {
        var hits = 0
        XCTAssertFalse(WebViewHook.install(FakeEngineTwo.self, cordovaMajor: 8, enabled: false) { hits += 1 },
                       "EdgeRumIosWebViewHook=false")
        XCTAssertFalse(WebViewHook.install(FakeEngineTwo.self, cordovaMajor: 9, enabled: true) { hits += 1 },
                       "untested cordova-ios")
        XCTAssertFalse(WebViewHook.install(nil, cordovaMajor: 8, enabled: true) { hits += 1 }, "class renamed")
        XCTAssertFalse(WebViewHook.install(NSObject.self, cordovaMajor: 8, enabled: true) { hits += 1 }, "selector gone")
        XCTAssertFalse(WebViewHook.install(OddEngine.self, cordovaMajor: 8, enabled: true) { hits += 1 }, "signature changed")
        FakeEngineTwo().webViewWebContentProcessDidTerminate(nil)
        XCTAssertEqual(OddEngine().webViewWebContentProcessDidTerminate(nil), 1)
        XCTAssertEqual(hits, 0)
    }

    func testHookReportsThenRunsCordovasRecovery() {
        var hits = 0
        XCTAssertTrue(WebViewHook.install(FakeEngine.self, cordovaMajor: 8, enabled: true) { hits += 1 })
        XCTAssertTrue(WebViewHook.install(FakeEngine.self, cordovaMajor: 8, enabled: true) { hits += 1 },
                      "already hooked: still on")
        let engine = FakeEngine()
        engine.webViewWebContentProcessDidTerminate(nil)
        XCTAssertEqual(hits, 1, "hooked once")
        XCTAssertEqual(engine.calls, 1, "original reload still runs")
    }

    func testInferenceFlagsAPageLoadWithoutCleanShutdown() {
        var page = PageWatch()
        XCTAssertFalse(page.loaded(), "first page of the process")
        page.hidden()
        XCTAssertFalse(page.loaded(), "navigated away cleanly")
        XCTAssertTrue(page.loaded(), "reloaded with no pagehide: the content process died")
    }

    func testWebViewTerminatedGoldenBatch() throws {
        let s = session()
        let crash = Crash(dir: dir, clock: { [unowned self] in now })
        crash.mirror(CrashTests.payload(1, "/checkout"))
        let e = crash.webViewTerminated(detectedBy: "callback")
        try Self.assertGolden("app-crash-webview.json", dir, health, s.admit([e]), solo: true)
        let inferred = attrs(crash.webViewTerminated(detectedBy: "inference"))
        XCTAssertEqual(inferred["webview.detected_by"] as? String, "inference")
        XCTAssertEqual(inferred["is_fatal"] as? Bool, true, "exempt from the roll (S2)")
    }
}
