import Foundation
import CryptoKit

/// AES-GCM encryption for the on-disk caches (inbox + bodies). The key lives in
/// the app-scoped keychain, so cached email content is protected at rest beyond
/// the sandbox container. All members are `nonisolated` so the `GmailFetcher`
/// actor can use them.
enum CacheCrypto {

    nonisolated private static let keyName = "cache_aes_key"

    nonisolated static func encrypt(_ data: Data) -> Data? {
        try? AES.GCM.seal(data, using: key()).combined
    }

    nonisolated static func decrypt(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key())
    }

    /// Loads the cache key from the keychain, generating + storing it once.
    nonisolated private static func key() -> SymmetricKey {
        if let stored = KeychainHelper.load(key: keyName), let data = Data(base64Encoded: stored) {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        KeychainHelper.save(key: keyName, value: raw.base64EncodedString())
        return fresh
    }
}
