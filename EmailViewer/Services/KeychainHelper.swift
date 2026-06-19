import Security
import Foundation

enum KeychainHelper {

    nonisolated private static let service = "EmailViewer"

    nonisolated private static func baseQuery(key: String) -> [CFString: Any] {
        [
            kSecClass:                     kSecClassGenericPassword,
            kSecAttrService:               service,
            kSecAttrAccount:               key,
            // App-scoped keychain (granted by the keychain-access-groups
            // entitlement): the app reads its own items silently — no password
            // prompt, no Touch ID.
            kSecUseDataProtectionKeychain: true,
        ]
    }

    nonisolated static func save(key: String, value: String) {
        // Remove any existing entry first so we don't get errSecDuplicateItem.
        SecItemDelete(baseQuery(key: key) as CFDictionary)

        var addQuery = baseQuery(key: key)
        addQuery[kSecValueData] = Data(value.utf8)

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("❌ Keychain save failed for \(key): \(status)")
        }
    }

    nonisolated static func load(key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func delete(key: String) {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }
}
