@testable import EdgeRum
import XCTest

final class SenderTests: XCTestCase {
    static let identity = #"{"app":{"name":"Fixture","package_name":"com.nathanclaire.rum.fixture","platform":"ios","version":"1.4.2","build_number":"142"},"device_id":"device_1700000000000_0123456789abcdef_ios"}"#
    static let events = [
        #"{"type":"event","eventName":"navigation","timestamp":"2026-10-26T10:00:00.000Z","attributes":{"navigation.to_screen":"/home"}}"#,
        #"{"type":"metric","metricName":"LCP","value":812.5,"timestamp":"2026-10-26T10:00:01.000Z","attributes":{}}"#,
    ]
    static let endpoint = "https://collector.test/telemetry"

    var now: Int64 = 1_793_008_802_000 // 2026-10-26T10:00:02.000Z
    var sleeps: [Int64] = []
    var dir: URL!
    var health: Health!
    var outbox: Outbox!
    var sender: Sender!

    override func setUp() {
        StubProtocol.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge_rum_\(UUID().uuidString)")
        health = Health(dir: dir)
        outbox = Outbox(dir: dir, clock: { [unowned self] in now }, health: health)
        sender = makeSender()
        sender.configure(apiKey: "edge_key_secret", url: Self.endpoint)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeSender() -> Sender {
        Sender(outbox: outbox, health: health, sdkVersion: "1.0.0", session: StubProtocol.session(),
               clock: { [unowned self] in now },
               sleep: { [unowned self] ms in sleeps.append(ms); now += ms },
               retryMs: [1000, 4000, 16000])
    }

    func sealedBatch() throws {
        try outbox.append(Self.identity, Self.events)
        outbox.seal()
    }

    func body(_ i: Int) -> String {
        gunzip(StubProtocol.requests[i].body)
    }

    func testPostsGzippedContractFourEnvelopeMatchingGolden() throws {
        try sealedBatch()
        StubProtocol.replies = [.status(202)]
        sender.drain()

        let req = StubProtocol.requests[0].request
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, Self.endpoint)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "edge_key_secret")
        XCTAssertEqual(body(0), golden("batch.json"))
        XCTAssertTrue(outbox.sealed().isEmpty)
    }

    func testAppendsSdkHealthWithDropCountsMatchingGolden() throws {
        health.count("outbox_full", 7)
        health.count("rejected", 2)
        try sealedBatch()
        StubProtocol.replies = [.status(200)]
        sender.drain()

        XCTAssertEqual(body(0), golden("sdk-health.json"))
        XCTAssertEqual(health.snapshot(), [:])
    }

    func testRestampsTimestampPerAttempt() throws {
        try sealedBatch()
        StubProtocol.replies = [.status(503), .status(200)]
        sender.drain()

        XCTAssertEqual(json(body(0))["timestamp"] as? String, "2026-10-26T10:00:02.000Z")
        let second = json(body(1))["timestamp"] as? String ?? ""
        XCTAssertGreaterThanOrEqual(second, "2026-10-26T10:00:03.000Z")
    }

    func testRetriesThreeTimesWithBackoffThenParks() throws {
        try sealedBatch()
        StubProtocol.replies = Array(repeating: .status(500), count: 4)
        sender.drain()

        XCTAssertEqual(StubProtocol.requestCount, 4)
        XCTAssertEqual(sleeps.count, 3)
        XCTAssertTrue((1000...1250).contains(sleeps[0]), "\(sleeps)")
        XCTAssertTrue((4000...5000).contains(sleeps[1]), "\(sleeps)")
        XCTAssertTrue((16000...20000).contains(sleeps[2]), "\(sleeps)")
        XCTAssertEqual(outbox.sealed().count, 1)

        // Parked: the next trigger inside the backoff does not resend it.
        sender.drain()
        XCTAssertEqual(StubProtocol.requestCount, 4)

        now += Sender.parkMs
        StubProtocol.replies = [.status(200)]
        sender.drain()
        XCTAssertEqual(StubProtocol.requestCount, 5)
        XCTAssertTrue(outbox.sealed().isEmpty)
    }

    func testParkedSegmentDoesNotBlockNewerOnes() throws {
        try sealedBatch()
        StubProtocol.replies = Array(repeating: .status(429), count: 4)
        sender.drain()
        now += 1
        try sealedBatch()
        StubProtocol.replies = [.status(200)]
        sender.drain()

        XCTAssertEqual(StubProtocol.requestCount, 5)
        XCTAssertEqual(outbox.sealed().count, 1)
    }

    func testHonoursRetryAfter() throws {
        try sealedBatch()
        StubProtocol.replies = [.status(429, ["Retry-After": "10"]), .status(200)]
        sender.drain()
        XCTAssertEqual(sleeps, [10_000])
    }

    func testLongRetryAfterParksForThatLong() throws {
        try sealedBatch()
        StubProtocol.replies = [.status(503, ["Retry-After": "3600"])]
        sender.drain()
        XCTAssertTrue(sleeps.isEmpty)

        now += 3_599_000
        sender.drain()
        XCTAssertEqual(StubProtocol.requestCount, 1)

        now += 1_000
        StubProtocol.replies = [.status(200)]
        sender.drain()
        XCTAssertTrue(outbox.sealed().isEmpty)
    }

    func testNetworkErrorIsRetried() throws {
        try sealedBatch()
        StubProtocol.replies = [.networkError, .status(200)]
        sender.drain()
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertTrue(outbox.sealed().isEmpty)
    }

    func testOtherFourXxDeletesAndCounts() throws {
        try sealedBatch()
        StubProtocol.replies = [.status(400)]
        sender.drain()

        XCTAssertEqual(StubProtocol.requestCount, 1)
        XCTAssertTrue(sleeps.isEmpty)
        XCTAssertTrue(outbox.sealed().isEmpty)
        XCTAssertEqual(health.snapshot(), ["events_dropped.rejected": 2])
    }

    func testSendsOldestFirst() throws {
        try outbox.append(Self.identity, [#"{"n":1}"#])
        outbox.seal()
        now += 1
        try outbox.append(Self.identity, [#"{"n":2}"#])
        outbox.seal()
        StubProtocol.replies = [.status(200), .status(200)]
        sender.drain()

        XCTAssertEqual((json(body(0))["events"] as? [[String: Int]])?.first?["n"], 1)
        XCTAssertEqual((json(body(1))["events"] as? [[String: Int]])?.first?["n"], 2)
    }

    func testHoldsSegmentsUntilConfigured() throws {
        sender = makeSender()
        try sealedBatch()
        sender.configure(apiKey: nil, url: Self.endpoint)
        sender.drain()
        XCTAssertEqual(StubProtocol.requestCount, 0)
        XCTAssertEqual(outbox.sealed().count, 1)
        XCTAssertFalse(sender.configured)
    }

    func testConfigureKeepsTheValueItIsNotGiven() throws {
        sender.configure(apiKey: "  ", url: nil)
        sender.configure(apiKey: " edge_new ", url: "")
        try sealedBatch()
        StubProtocol.replies = [.status(200)]
        sender.drain()
        let req = StubProtocol.requests[0].request
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "edge_new")
        XCTAssertEqual(req.url?.absoluteString, Self.endpoint)
    }

    func testIdentityLineOmitsUnknownVersion() {
        XCTAssertEqual(
            Sender.identityLine(name: "App", packageName: "com.x", version: nil, buildNumber: nil, deviceId: "d1"),
            #"{"app":{"name":"App","package_name":"com.x","platform":"ios"},"device_id":"d1"}"#)
    }

    func testCorruptIdentityIsDroppedAndCounted() throws {
        try outbox.append("{not json", Self.events)
        outbox.seal()
        sender.drain()
        XCTAssertEqual(StubProtocol.requestCount, 0)
        XCTAssertTrue(outbox.sealed().isEmpty)
        XCTAssertEqual(health.snapshot(), ["events_dropped.corrupt": 2])
    }

    func testTriggerRunsOffTheCallerThreadAndCallsBack() throws {
        try sealedBatch()
        StubProtocol.replies = [.status(200)]
        let done = expectation(description: "drained")
        sender.trigger { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(StubProtocol.requestCount, 1)
        XCTAssertTrue(outbox.sealed().isEmpty)
    }
}
