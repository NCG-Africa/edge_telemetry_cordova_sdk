import Foundation
import Security

/// The Keychain row `device.id` lives in; throws on any Keychain error.
protocol SecureStore {
    func read() throws -> String?
    func write(_ value: String) throws
}

/// Spec W4 / R9: port of `edge_telemetry_ios_sdk` `IdentityProvider` (device id only): Keychain
/// `device.id`, UserDefaults fallback when the Keychain write fails. Stored values that don't
/// match the id format are regenerated. Never throws: device_id is required on every batch.
struct DeviceId {
    static let fallbackKey = "edge_rum_cordova.device.id.fallback"
    private static let format = #"^device_\d+_[0-9a-f]{16}_ios$"#

    let keychain: SecureStore
    let defaults: UserDefaults

    init(keychain: SecureStore = Keychain(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    func resolve() -> String {
        if let id = valid(try? keychain.read()) ?? valid(defaults.string(forKey: Self.fallbackKey)) { return id }
        let id = Self.newId("device")
        do {
            try keychain.write(id)
            // The next launch picks up the Keychain copy.
            defaults.removeObject(forKey: Self.fallbackKey)
        } catch {
            defaults.set(id, forKey: Self.fallbackKey)
        }
        return id
    }

    private func valid(_ id: String?) -> String? {
        guard let id, id.range(of: Self.format, options: .regularExpression) != nil else { return nil }
        return id
    }

    /// `<kind>_<epochMs>_<16 hex>_ios`, hex from `SecRandomCopyBytes` (sibling id format).
    static func newId(_ kind: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
        return "\(kind)_\(Outbox.now())_\(bytes.map { String(format: "%02x", $0) }.joined())_ios"
    }
}

/// Generic-password row, readable after first unlock (background launches), never synced.
struct Keychain: SecureStore {
    private let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.nathanclaire.rum.cordova",
        kSecAttrAccount: "device.id",
    ]

    func read() throws -> String? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
