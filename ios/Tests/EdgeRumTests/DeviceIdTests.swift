@testable import EdgeRum
import XCTest

final class DeviceIdTests: XCTestCase {
    /// In-memory Keychain stand-in; flags simulate Keychain failures.
    final class FakeKeychain: SecureStore {
        var value: String?
        var failRead = false
        var failWrite = false

        func read() throws -> String? {
            if failRead { throw NSError(domain: "keychain", code: -25308) }
            return value
        }

        func write(_ value: String) throws {
            if failWrite { throw NSError(domain: "keychain", code: -25308) }
            self.value = value
        }
    }

    var defaults: UserDefaults!
    let suite = "edge_rum_tests_\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testGeneratesOncePersistsInKeychainAndReuses() {
        let keychain = FakeKeychain()
        let id = DeviceId(keychain: keychain, defaults: defaults).resolve()
        XCTAssertNotNil(id.range(of: #"^device_\d+_[0-9a-f]{16}_ios$"#, options: .regularExpression), id)
        XCTAssertEqual(keychain.value, id)
        XCTAssertEqual(DeviceId(keychain: keychain, defaults: defaults).resolve(), id)
    }

    func testKeychainWriteFailureFallsBackToUserDefaults() {
        let keychain = FakeKeychain()
        keychain.failWrite = true
        let id = DeviceId(keychain: keychain, defaults: defaults).resolve()
        XCTAssertNil(keychain.value)
        XCTAssertEqual(defaults.string(forKey: DeviceId.fallbackKey), id)
        XCTAssertEqual(DeviceId(keychain: keychain, defaults: defaults).resolve(), id)
    }

    func testKeychainReadFailureUsesPersistedFallback() {
        defaults.set("device_1_0123456789abcdef_ios", forKey: DeviceId.fallbackKey)
        let keychain = FakeKeychain()
        keychain.failRead = true
        XCTAssertEqual(DeviceId(keychain: keychain, defaults: defaults).resolve(), "device_1_0123456789abcdef_ios")
    }

    func testMalformedStoredIdIsRegenerated() {
        let keychain = FakeKeychain()
        keychain.value = "not-a-device-id"
        let id = DeviceId(keychain: keychain, defaults: defaults).resolve()
        XCTAssertNotEqual(id, "not-a-device-id")
        XCTAssertEqual(keychain.value, id)
    }

    func testSessionIdFormat() {
        XCTAssertNotNil(DeviceId.newId("session").range(of: #"^session_\d+_[0-9a-f]{16}_ios$"#, options: .regularExpression))
    }
}
