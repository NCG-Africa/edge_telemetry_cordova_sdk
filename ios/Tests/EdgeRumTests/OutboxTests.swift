@testable import EdgeRum
import XCTest

final class OutboxTests: XCTestCase {
    static let idV1 = #"{"app":{"package_name":"com.x","platform":"ios","version":"1.0"},"device_id":"d1"}"#
    static let idV2 = #"{"app":{"package_name":"com.x","platform":"ios","version":"2.0"},"device_id":"d1"}"#

    var now: Int64 = 1_700_000_000_000
    var dir: URL!
    var health: Health!
    var outbox: Outbox!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge_rum_\(UUID().uuidString)")
        health = Health(dir: dir)
        outbox = Outbox(dir: dir, clock: { [unowned self] in now }, health: health)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    static func events(_ n: Int) -> [String] {
        (0..<n).map { #"{"type":"event","eventName":"e\#($0)"}"# }
    }

    func relaunch() -> Outbox {
        Outbox(dir: dir, clock: { [unowned self] in now }, health: health)
    }

    func testSealsAtFiftyEventsSplittingLargeHandOffs() throws {
        try outbox.append(Self.idV1, Self.events(120))
        let sealed = outbox.sealed()
        XCTAssertEqual(sealed.count, 2)
        XCTAssertEqual(try outbox.read(sealed[0]).events.count, 50)
        XCTAssertEqual(try outbox.read(sealed[1]).events.count, 50)
        outbox.seal()
        XCTAssertEqual(try outbox.read(outbox.sealed()[2]).events.count, 20)
    }

    func testSealsThirtySecondsAfterFirstEvent() throws {
        try outbox.append(Self.idV1, Self.events(1))
        now += 29_999
        outbox.sealIfDue()
        XCTAssertTrue(outbox.sealed().isEmpty)
        now += 1
        outbox.sealIfDue()
        XCTAssertEqual(outbox.sealed().count, 1)
    }

    func testNextLaunchSealsLeftoversAndKeepsOrder() throws {
        try outbox.append(Self.idV1, Self.events(3))
        outbox.seal()
        now += 10
        try outbox.append(Self.idV1, Self.events(2))
        now += 1
        let relaunched = relaunch()
        let sealed = relaunched.sealed()
        XCTAssertEqual(sealed.count, 2)
        XCTAssertEqual(try relaunched.read(sealed[0]).events.count, 3)
        XCTAssertEqual(try relaunched.read(sealed[1]).events.count, 2)
    }

    func testIdentityIsFrozenInTheFirstLine() throws {
        try outbox.append(Self.idV1, Self.events(1))
        try outbox.append(Self.idV2, Self.events(1))
        outbox.seal()
        let seg = try outbox.read(outbox.sealed()[0])
        XCTAssertEqual(seg.identity, Self.idV1)
        XCTAssertEqual(seg.events.count, 2)
    }

    func testTornTrailingLineIsDiscarded() throws {
        try outbox.append(Self.idV1, Self.events(2))
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("open.ndjson.part"))
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"type":"ev"#.utf8))
        try h.close()
        let relaunched = relaunch()
        XCTAssertEqual(try relaunched.read(relaunched.sealed()[0]).events, Self.events(2))
    }

    func testDropsSegmentsOlderThanSevenDays() throws {
        try outbox.append(Self.idV1, Self.events(4))
        outbox.seal()
        now += Outbox.maxAgeMs + 1
        try outbox.append(Self.idV1, Self.events(1))
        outbox.seal()
        XCTAssertEqual(outbox.sealed().count, 1)
        XCTAssertEqual(health.snapshot(), ["events_dropped.expired": 4])
    }

    func testCapsSkipTheSegmentBeingSent() throws {
        try outbox.append(Self.idV1, Self.events(4))
        outbox.seal()
        let inFlight = outbox.sealed()[0]
        outbox.sending(inFlight)
        now += Outbox.maxAgeMs + 1
        outbox.seal()
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path))
        XCTAssertEqual(health.snapshot(), [:])
    }

    func testSegmentCountCapDropsOldest() throws {
        for i in 0..<(Outbox.maxSegments + 2) {
            now += 1
            try outbox.append(Self.idV1, [#"{"n":\#(i)}"#])
            outbox.seal()
        }
        let sealed = outbox.sealed()
        XCTAssertEqual(sealed.count, Outbox.maxSegments)
        XCTAssertEqual(try outbox.read(sealed[0]).events[0], #"{"n":2}"#)
        XCTAssertEqual(health.snapshot(), ["events_dropped.outbox_full": 2])
    }

    func testByteCapDropsOldest() throws {
        let event = #"{"pad":""# + String(repeating: "x", count: 1024 * 1024) + #""}"#
        for _ in 0..<6 {
            now += 1
            try outbox.append(Self.idV1, [event])
            outbox.seal()
        }
        XCTAssertEqual(outbox.sealed().count, 4)
        XCTAssertEqual(health.snapshot(), ["events_dropped.outbox_full": 2])
    }

    func testOutboxIsExcludedFromBackup() throws {
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testHealthSurvivesRelaunchAndSubtractsWhatWasSent() {
        health.count("expired", 3)
        let reloaded = Health(dir: dir)
        XCTAssertEqual(reloaded.snapshot(), ["events_dropped.expired": 3])
        reloaded.count("expired", 2)
        reloaded.subtract(["events_dropped.expired": 3])
        XCTAssertEqual(Health(dir: dir).snapshot(), ["events_dropped.expired": 2])
    }
}
