@testable import EdgeRum
import XCTest

final class LaunchTests: XCTestCase {
    static let t0: Int64 = 1_793_008_800_000 // 2026-10-26T10:00:00.000Z, process start
    let launch = Launch(processStart: LaunchTests.t0, webViewCreated: LaunchTests.t0 + 120)
    var defaults: UserDefaults!
    let suite = "edge_rum_tests_\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func attrs(_ e: [String: Any]?) -> [String: Any] {
        e?["attributes"] as? [String: Any] ?? [:]
    }

    func pagePhases() {
        XCTAssertNil(launch.mark("responseEnd", Self.t0 + 300))
        XCTAssertNil(launch.mark("DOMContentLoaded", Self.t0 + 450))
        XCTAssertNil(launch.mark("load", Self.t0 + 600))
    }

    func testDevicereadyAloneWaitsForTheWindow() {
        pagePhases()
        XCTAssertNil(launch.mark("deviceready", Self.t0 + 700), "markReady may still come")
        XCTAssertTrue(launch.devicereadySeen)
        let a = attrs(launch.finish())
        XCTAssertEqual(a["app.start.duration_ms"] as? Int64, 700)
        XCTAssertEqual(a["app.start.webview_created_ms"] as? Int64, 120)
        XCTAssertNil(a["app.start.mark_ready_ms"])
        XCTAssertNil(launch.finish(), "once per launch")
    }

    func testMarkReadyInsideWindowCompletesIt() {
        pagePhases()
        _ = launch.mark("deviceready", Self.t0 + 700)
        let e = launch.mark("markReady", Self.t0 + 2000)
        XCTAssertEqual(attrs(e)["app.start.duration_ms"] as? Int64, 2000)
        XCTAssertEqual(e?["timestamp"] as? String, Sender.rfc3339(Self.t0 + 2000))
        XCTAssertNil(launch.finish())
    }

    func testMarkReadyBeforeDevicereadyCountsAtDeviceready() {
        XCTAssertNil(launch.mark("markReady", Self.t0 + 500))
        XCTAssertNotNil(launch.mark("deviceready", Self.t0 + 700))
    }

    func testLateMarkReadyIgnored() {
        _ = launch.mark("deviceready", Self.t0 + 700)
        XCTAssertNil(launch.mark("markReady", Self.t0 + 700 + Launch.readyWindowMs + 1))
        XCTAssertNil(attrs(launch.finish())["app.start.mark_ready_ms"])
    }

    func testReloadAndUnknownPhasesIgnored() {
        _ = launch.mark("load", Self.t0 + 600)
        _ = launch.mark("load", Self.t0 + 9000)
        _ = launch.mark("bogus", Self.t0 + 1)
        XCTAssertNil(launch.finish(), "no deviceready, no app.start")
        _ = launch.mark("deviceready", Self.t0 + 700)
        let a = attrs(launch.finish())
        XCTAssertEqual(a["app.start.load_ms"] as? Int64, 600)
        XCTAssertNil(a["bogus"])
    }

    func testTimeoutMarkerReportedOnceNextLaunch() {
        XCTAssertNil(Launch.takeTimeout(defaults))
        Launch.timedOut(defaults, timeoutMs: 10_000, now: Self.t0 + 10_000)
        let e = Launch.takeTimeout(defaults)
        XCTAssertEqual(e?["eventName"] as? String, "cordova.deviceready_timeout")
        XCTAssertEqual(attrs(e)["cordova.deviceready_timeout_ms"] as? Int64, 10_000)
        XCTAssertNil(Launch.takeTimeout(defaults))
    }

    func testCorruptMarkerDropped() {
        defaults.set("garbage", forKey: Launch.timeoutKey)
        XCTAssertNil(Launch.takeTimeout(defaults))
        XCTAssertNil(defaults.string(forKey: Launch.timeoutKey))
    }

    func testGoldenBatches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge_rum_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let health = Health(dir: dir)
        // S2: both exempt, so they survive a sampled-out session.
        let session = Session(defaults: defaults, health: health, clock: { Self.t0 + 2000 }, sampleRate: 0,
                              roll: { 0.9 }, newId: { "session_1" }, userId: { nil })
        _ = session.begin()
        pagePhases()
        _ = launch.mark("deviceready", Self.t0 + 700)
        Launch.timedOut(defaults, timeoutMs: 10_000, now: Self.t0 - 50_000)
        let start = try XCTUnwrap(launch.mark("markReady", Self.t0 + 1500))
        try SignalsTests.assertGolden("app-start.json", dir, health, session.admit([start]))
        let timeout = try XCTUnwrap(Launch.takeTimeout(defaults))
        try SignalsTests.assertGolden("cordova-deviceready-timeout.json", dir, health, session.admit([timeout]))
    }
}
