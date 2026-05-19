import Foundation
import Security

/// Minimal, dependency-free Keychain wrapper for opaque sync secrets
/// (static token, OAuth access/refresh tokens, client registration).
///
/// Protocol §10: tokens live in the iOS Keychain, never in plist-backed
/// preferences. Every accessor swallows failure — a Keychain hiccup must
/// never affect recording (CLAUDE.md hard constraint), it only degrades
/// sync to "signed out", surfaced later in `sync.lastResult`.
enum Keychain {

    /// Stable account names for each stored secret.
    enum Key: String {
        case staticToken      = "com.hrmrecorder.sync.staticToken"
        case oauthAccess      = "com.hrmrecorder.sync.oauthAccessToken"
        case oauthRefresh     = "com.hrmrecorder.sync.oauthRefreshToken"
        case oauthClient      = "com.hrmrecorder.sync.oauthClientRegistration"
    }

    private static func query(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "HRMRecorderSync",
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    @discardableResult
    static func set(_ value: String?, for key: Key) -> Bool {
        guard let value, !value.isEmpty else { return delete(key) }
        guard let data = value.data(using: .utf8) else { return false }
        var q = query(key)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: Key) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let status = SecItemDelete(query(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
