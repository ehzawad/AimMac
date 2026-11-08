import Foundation
import CryptoKit
import Security

/// This device's long-term pairing key, kept in the Keychain and never synced.
enum DeviceIdentity {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "orbit-pointer.identity",
            kSecAttrAccount as String: "signing-key",
        ]
    }

    static func loadOrCreate() -> Curve25519.Signing.PrivateKey {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
           let raw = item as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }

        let key = Curve25519.Signing.PrivateKey()
        var add = query
        add[kSecValueData as String] = key.rawRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Orbit Pointer: could not save the pairing key (\(status))") }
        return key
    }
}
