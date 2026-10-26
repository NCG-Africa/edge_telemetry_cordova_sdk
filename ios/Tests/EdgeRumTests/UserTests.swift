@testable import EdgeRum
import XCTest

final class UserTests: XCTestCase {
    var defaults: UserDefaults!
    let suite = "edge_rum_tests_\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testIdentifyPersistsAndEmitsProfileUpdateOnlyWhenTraitsChange() throws {
        let user = User(defaults: defaults)
        let update = try XCTUnwrap(user.identify(["id": "u1", "name": "Ann", "email": "a@x.io"]))
        XCTAssertEqual(update["eventName"] as? String, "user.profile.update")
        XCTAssertEqual(update["attributes"] as? [String: String], ["user.id": "u1", "user.name": "Ann", "user.email": "a@x.io"])

        let relaunched = User(defaults: defaults)
        XCTAssertEqual(relaunched.id, "u1")
        XCTAssertNil(relaunched.identify(["id": "u1", "name": "Ann"]), "same traits: no update")
        XCTAssertNil(relaunched.identify(["id": "u2"]), "id-only change: no update")
        XCTAssertEqual(relaunched.id, "u2")
        let phone = try XCTUnwrap(relaunched.identify(["phone": "+254700000000"]))
        let a = phone["attributes"] as? [String: String]
        XCTAssertEqual(a?["user.phone"], "+254700000000")
        XCTAssertEqual(a?["user.name"], "Ann")
    }

    func testBlankAndNonStringTraitsAreIgnored() {
        let user = User(defaults: defaults)
        XCTAssertNil(user.identify(["id": " ", "name": NSNull(), "email": 5]))
        XCTAssertNil(user.id)
    }

    func testClearForgetsEverything() {
        let user = User(defaults: defaults)
        _ = user.identify(["id": "u1", "name": "Ann"])
        user.clear()
        XCTAssertNil(user.id)
        XCTAssertNil(User(defaults: defaults).id)
        let again = User(defaults: defaults).identify(["name": "Ann"])
        XCTAssertEqual((again?["attributes"] as? [String: String])?["user.name"], "Ann", "traits forgotten: same name is a change again")
    }
}
