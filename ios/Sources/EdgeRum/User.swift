import Foundation

/// Spec P6: `identify()` traits, persisted until `clearUser()`.
final class User {
    static let key = "edge_rum_cordova.user"
    private static let traits = ["name", "email", "phone"]

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var user: [String: String]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        user = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    var id: String? {
        lock.lock(); defer { lock.unlock() }
        return user["id"]
    }

    /// Merges the given non-blank string keys. Returns one `user.profile.update` event when name,
    /// email or phone changed, else nil.
    func identify(_ given: [String: Any]) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for k in ["id"] + Self.traits {
            guard let v = given[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if k != "id" && user[k] != v { changed = true }
            user[k] = v
        }
        defaults.set(user, forKey: Self.key)
        guard changed else { return nil }
        var attrs: [String: String] = [:]
        for k in ["id"] + Self.traits { attrs["user." + k] = user[k] }
        return ["type": "event", "eventName": "user.profile.update", "timestamp": Sender.rfc3339(Outbox.now()),
                "attributes": attrs]
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        user = [:]
        defaults.removeObject(forKey: Self.key)
    }
}
