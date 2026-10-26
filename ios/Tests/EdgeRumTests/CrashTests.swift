@testable import EdgeRum
import EdgeRumCrash
import XCTest

final class CrashTests: XCTestCase {
    /// The build that crashed; the relaunch runs `SenderTests.identity` (1.4.2).
    static let crashedIdentity = SenderTests.identity.replacingOccurrences(of: "1.4.2", with: "1.4.1")
        .replacingOccurrences(of: #""142""#, with: #""141""#)
    static let app = "/private/var/containers/Bundle/Application/0A1B/Fixture.app/Fixture"
    static let machReport = "exception 1\nmach_code 1\nmach_subcode 0\ntime_ms 1793008801500\nthread \nmain 1\n"
        + "frame 102a41a2c\t102a40000\t4f6e8a0b1c2d3e4f5a6b7c8d9e0f1a2b\t\(app)\t-[Cart total]\n"
        + "frame 1a0f39f10\t1a0f00000\t9a8b7c6d5e4f30211203f4e5d6c7b8a9\t/usr/lib/system/libsystem_c.dylib\t-\n"
        + "frame dead\t-\t-\t-\t-\n"
    static let frames = [
        Crash.Frame(pc: 0x102a41a2c, base: 0x102a40000, uuid: "4f6e8a0b1c2d3e4f5a6b7c8d9e0f1a2b", path: app,
                    symbol: "-[Cart total]"),
        Crash.Frame(pc: 0x1a0f39f10, base: 0x1a0f00000, uuid: "9a8b7c6d5e4f30211203f4e5d6c7b8a9",
                    path: "/usr/lib/system/libsystem_c.dylib", symbol: nil),
    ]

    var defaults: UserDefaults!
    let suite = "edge_rum_tests_\(UUID().uuidString)"
    var now: Int64 = 1_793_008_802_000 // 2026-10-26T10:00:02.000Z
    var dir: URL!
    var health: Health!
    var session: Session!
    var crash: Crash!
    var outbox: Outbox!

    override func setUp() {
        StubProtocol.reset()
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge_rum_\(UUID().uuidString)")
        health = Health(dir: dir)
        session = makeSession(rate: 1, roll: 0)
        _ = session.begin()
        crash = Crash(dir: dir, clock: { [unowned self] in now })
        outbox = Outbox(dir: dir, clock: { [unowned self] in now }, health: health)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    func makeSession(rate: Double, roll: Double) -> Session {
        Session(defaults: defaults, health: health, clock: { [unowned self] in now }, sampleRate: rate,
                roll: { roll }, newId: { "session_1" }, userId: { "u1" })
    }

    static func payload(_ crumbs: Int, _ screen: String?) -> [String: Any] {
        let b = (0..<crumbs).map { ["category": "navigation", "message": "crumb \($0)"] }
        let events = screen.map { [SessionTests.event("navigation", ["navigation.to_screen": $0])] } ?? []
        return ["events": events, "breadcrumbs": b]
    }

    /// The plugin's `solo()`: session gate, then a segment of its own.
    func solo(_ event: [String: Any], _ identity: String = SenderTests.identity) throws {
        for line in session.admit([event]) { try outbox.writeSolo(identity, line) }
    }

    /// Next launch: a fresh outbox seals leftovers; drains everything; one body per batch.
    func relaunchAndSend() -> [String] {
        now += 1_000
        let outbox = Outbox(dir: dir, clock: { [unowned self] in now }, health: health)
        let sender = Sender(outbox: outbox, health: health, sdkVersion: "1.0.0", session: StubProtocol.session(),
                            clock: { [unowned self] in now }, sleep: { _ in }, retryMs: [1])
        sender.configure(apiKey: "k", url: SenderTests.endpoint)
        StubProtocol.replies = Array(repeating: .status(200), count: outbox.sealed().count)
        sender.drain()
        return StubProtocol.requests.map { gunzip($0.body) }
    }

    func assertGolden(_ name: String, _ body: String, file: StaticString = #filePath, line: UInt = #line) {
        // Event dictionaries are unordered: compare parsed, not byte for byte.
        XCTAssertEqual(json(body) as NSDictionary, json(golden(name)) as NSDictionary, file: file, line: line)
    }

    func attrs(_ e: [String: Any]?) -> [String: Any] {
        e?["attributes"] as? [String: Any] ?? [:]
    }

    func testNativeCrashReplaysNextLaunchInItsOwnBatchUnderTheCrashedBuild() throws {
        crash.mirror(Self.payload(1, "/checkout"))
        crash.saveContext(identity: Self.crashedIdentity, sessionId: "session_1", userId: "u1")
        try outbox.append(SenderTests.identity, session.admit([SessionTests.event("navigation")]))
        health.count("outbox_full", 3)
        try Self.machReport.write(toFile: crash.reportPath, atomically: true, encoding: .utf8)

        let next = Crash(dir: dir, clock: { [unowned self] in now })
        let p = try XCTUnwrap(next.takeReport())
        XCTAssertEqual(p.identity, Self.crashedIdentity)
        XCTAssertNil(next.takeReport(), "report consumed")
        try outbox.writeSolo(p.identity, p.event)
        let bodies = relaunchAndSend()

        XCTAssertEqual(bodies.count, 2, "crash batch + the open segment sealed at relaunch")
        assertGolden("app-crash-native.json", bodies[0])
        let events = json(bodies[1])["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(events.last?["eventName"] as? String, "sdk.health", "sdk.health rides the normal batch")
    }

    func testSignalReportNamesTheSignal() throws {
        let report = Self.machReport.replacingOccurrences(of: "exception 1\nmach_code 1\nmach_subcode 0\n",
                                                          with: "signal 6\ncode 0\nfault_addr 0\n")
            .replacingOccurrences(of: "thread \nmain 1", with: "thread worker\nmain 0")
        let a = attrs(Crash.native(report, [:]))
        XCTAssertEqual(a["message"] as? String, "SIGABRT, code 0, fault addr 0x0")
        XCTAssertEqual(a["exception_type"] as? String, "SIGABRT")
        XCTAssertEqual(a["cause"] as? String, "signal 6")
        XCTAssertEqual(a["crash_thread"] as? String, "worker")
        XCTAssertEqual(a["crash_is_main_thread"] as? Bool, false)
    }

    func testTornReportOrMissingContextIsDropped() throws {
        crash.saveContext(identity: Self.crashedIdentity, sessionId: "session_1", userId: nil)
        try "frame 1".write(toFile: crash.reportPath, atomically: true, encoding: .utf8)
        XCTAssertNil(crash.takeReport())
        XCTAssertFalse(FileManager.default.fileExists(atPath: crash.reportPath))

        crash.clear()
        try Self.machReport.write(toFile: crash.reportPath, atomically: true, encoding: .utf8)
        XCTAssertNil(crash.takeReport(), "no context to replay under")
    }

    func testBreadcrumbRingKeepsLastFifty() throws {
        crash.mirror(Self.payload(40, "/a"))
        crash.mirror(Self.payload(30, nil))
        crash.saveContext(identity: Self.crashedIdentity, sessionId: "session_1", userId: nil)
        try Self.machReport.write(toFile: crash.reportPath, atomically: true, encoding: .utf8)
        let a = attrs(json(try XCTUnwrap(crash.takeReport()).event))
        let crumbs = try JSONSerialization.jsonObject(with: Data((a["crash.breadcrumbs"] as? String ?? "").utf8)) as? [[String: Any]]
        XCTAssertEqual(crumbs?.count, Crash.breadcrumbs)
        XCTAssertEqual(crumbs?.first?["message"] as? String, "crumb 20")
        XCTAssertEqual(crumbs?.last?["message"] as? String, "crumb 29")
        XCTAssertEqual(a["screen_name"] as? String, "/a")
    }

    func testClearForgetsEverything() throws {
        crash.mirror(Self.payload(3, "/a"))
        crash.clear()
        let a = attrs(crash.hang(durationMs: 2_000, frames: []))
        XCTAssertNil(a["screen_name"])
    }

    func testHangGoldenBatch() throws {
        crash.mirror(Self.payload(0, "/cart"))
        try solo(crash.hang(durationMs: 2_100, frames: Self.frames))
        assertGolden("app-hang.json", relaunchAndSend()[0])
    }

    func testSampledOutSessionDropsHang() throws {
        defaults.removePersistentDomain(forName: suite)
        session = makeSession(rate: 0.5, roll: 0.9)
        _ = session.begin()
        try solo(crash.hang(durationMs: 2_000, frames: []))
        XCTAssertTrue(outbox.sealed().isEmpty, "app.hang follows the roll (S2)")
    }

    func testFramesResolveThisImageWithUUID() throws {
        let pc = UInt(bitPattern: #dsohandle) + 0x10 // inside this image's header
        let f = try XCTUnwrap(Crash.frames([pc]).first)
        XCTAssertTrue(f.text.hasPrefix("EdgeRumTests +0x10"), f.text)
        XCTAssertEqual(f.uuid.count, 32)
        XCTAssertEqual(Crash.frames([0x10])[0].text, "0x10", "unresolved: absolute address")
    }

    func testMainStackFromAnotherThread() {
        var n = 0
        let done = expectation(description: "walked")
        DispatchQueue.global().async {
            n = Crash.mainStack().count
            done.fulfill()
        }
        wait(for: [done], timeout: 5) // main is parked in the run loop meanwhile
        XCTAssertGreaterThan(n, 1)
        XCTAssertEqual(Crash.mainStack().count, 0, "never walks itself")
    }

    // MARK: - The real handlers, in a forked child that dies

    func testMachHandlerWritesReportForBadAccess() throws {
        let (sig, a) = try crashChild { UnsafeMutablePointer<Int>(bitPattern: 8)!.pointee = 1 }
        XCTAssertTrue(sig == SIGSEGV || sig == SIGBUS, "died of \(sig)")
        XCTAssertEqual(a["exception_type"] as? String, "EXC_BAD_ACCESS")
        XCTAssertTrue((a["stacktrace"] as? String ?? "").contains("EdgeRumTests +0x"), a["stacktrace"] as? String ?? "")
    }

    func testSignalHandlerWritesReportForAbortAndWalksToTheCaller() throws {
        let (sig, a) = try crashChild { abort() }
        XCTAssertEqual(sig, SIGABRT)
        XCTAssertEqual(a["exception_type"] as? String, "SIGABRT")
        let stack = a["stacktrace"] as? String ?? ""
        XCTAssertTrue(stack.contains("EdgeRumTests +0x"), stack)
        XCTAssertNotNil(a["crash.binary_images"])
    }

    /// Forks; the child installs the handlers and runs `body`, which must kill it.
    /// - Returns: the child's terminating signal and the parsed record's attributes.
    func crashChild(_ body: () -> Void) throws -> (Int32, [String: Any]) {
        // Swift marks fork() unavailable; the child only touches the C handlers before it dies.
        typealias Fork = @convention(c) () -> pid_t
        let fork = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork"), to: Fork.self)
        let path = crash.reportPath
        let pid = fork()
        if pid == 0 {
            for s in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE] { signal(s, SIG_DFL) }
            edge_rum_crash_install(path)
            body()
            _exit(0)
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        crash.saveContext(identity: Self.crashedIdentity, sessionId: "session_1", userId: nil)
        let pending = try XCTUnwrap(crash.takeReport(), "no report written")
        return (status & 0x7f, attrs(json(pending.event)))
    }
}
