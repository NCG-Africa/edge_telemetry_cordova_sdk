import Foundation

/// Spec P7: the enabled state and what `enable()`, `disable()` and `reset()` do to stored data.
final class Consent {
    static let key = "edge_rum_cordova.enabled"

    private let defaults: UserDefaults
    private let session: Session
    private let user: User
    private let outbox: Outbox
    private let deviceId: DeviceId
    private let lock = NSLock()
    private var on: Bool

    /// - Parameter prefEnabled: C1 `EdgeRumEnabled`; a persisted `enable()`/`disable()` overrides it.
    init(defaults: UserDefaults, prefEnabled: Bool, session: Session, user: User, outbox: Outbox, deviceId: DeviceId) {
        self.defaults = defaults
        self.session = session
        self.user = user
        self.outbox = outbox
        self.deviceId = deviceId
        on = defaults.object(forKey: Self.key) as? Bool ?? prefEnabled
    }

    var enabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    /// Persisted. Enabling begins a session (bookends returned to append); disabling forgets the
    /// session and deletes the unsent outbox and the user's traits.
    func setEnabled(_ enable: Bool) -> [String] {
        lock.lock(); defer { lock.unlock() }
        defaults.set(enable, forKey: Self.key)
        guard enable != on else { return [] }
        on = enable
        if enable { return session.begin() }
        session.end()
        outbox.clear()
        user.clear()
        return []
    }

    /// Clears user and outbox and rotates device_id; the caller starts the new session.
    /// - Returns: the new device_id
    func reset() -> String {
        lock.lock(); defer { lock.unlock() }
        outbox.clear()
        user.clear()
        return deviceId.rotate()
    }
}
