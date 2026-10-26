@testable import EdgeRum
import XCTest

final class ConsentTests: XCTestCase {
    var defaults: UserDefaults!
    let suite = "edge_rum_tests_\(UUID().uuidString)"
    var dir: URL!
    var outbox: Outbox!
    var user: User!
    var session: Session!
    var keychain: DeviceIdTests.FakeKeychain!
    var deviceId: DeviceId!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("edge_rum_\(UUID().uuidString)")
        let health = Health(dir: dir)
        outbox = Outbox(dir: dir, health: health)
        user = User(defaults: defaults)
        keychain = DeviceIdTests.FakeKeychain()
        deviceId = DeviceId(keychain: keychain, defaults: defaults)
        var n = 0
        session = Session(defaults: defaults, health: health, sampleRate: 1, roll: { 0 },
                          newId: { n += 1; return "session_\(n)" }, userId: { [unowned self] in user.id })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    func consent(_ pref: Bool) -> Consent {
        Consent(defaults: defaults, prefEnabled: pref, session: session, user: user, outbox: outbox, deviceId: deviceId)
    }

    func testOptInModeStartsDisabledUntilEnable() {
        let c = consent(false)
        XCTAssertFalse(c.enabled)
        XCTAssertEqual(c.setEnabled(true).count, 1, "enable starts a session")
        XCTAssertTrue(c.enabled)
        XCTAssertTrue(consent(false).enabled, "persisted over the pref")
    }

    func testDisablePersistsOverPrefAndWipesOutboxTraitsAndSession() throws {
        let c = consent(true)
        _ = session.begin()
        _ = user.identify(["id": "u1"])
        try outbox.append(SenderTests.identity, ["{}"])
        outbox.seal()
        try outbox.append(SenderTests.identity, ["{}"])

        XCTAssertTrue(c.setEnabled(false).isEmpty)
        XCTAssertFalse(c.enabled)
        outbox.seal()
        XCTAssertTrue(outbox.sealed().isEmpty)
        XCTAssertNil(User(defaults: defaults).id)
        XCTAssertNil(session.id)
        XCTAssertFalse(consent(true).enabled, "persisted over EdgeRumEnabled=true")
    }

    func testRepeatedEnableIsANoOp() {
        let c = consent(true)
        _ = session.begin()
        XCTAssertTrue(c.setEnabled(true).isEmpty)
        XCTAssertEqual(session.id, "session_1")
    }

    func testResetRotatesDeviceIdAndClearsUserAndOutbox() throws {
        let c = consent(true)
        let before = deviceId.resolve()
        _ = user.identify(["id": "u1"])
        try outbox.append(SenderTests.identity, ["{}"])

        let after = c.reset()
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(DeviceId(keychain: keychain, defaults: defaults).resolve(), after)
        XCTAssertNil(user.id)
        outbox.seal()
        XCTAssertTrue(outbox.sealed().isEmpty)
        XCTAssertTrue(c.enabled, "reset leaves enabled state alone")
    }

    func testResetSticksWhenKeychainWriteFails() {
        let before = deviceId.resolve()
        keychain.failWrite = true
        let after = consent(true).reset()
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(DeviceId(keychain: keychain, defaults: defaults).resolve(), after, "stale Keychain row must not win")
    }
}
