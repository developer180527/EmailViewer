import Foundation
import CryptoKit

/// Best-effort sender avatars. The Gmail readonly scope exposes no sender photos,
/// so we try Gravatar (by email hash) and then a domain favicon (brand logos),
/// caching results. Returns raw image bytes; callers build the NSImage.
///
/// Privacy note: this sends an email hash to Gravatar and a sender domain to
/// Google's favicon service. Disable by not calling it if that's a concern.
actor AvatarProvider {

    static let shared = AvatarProvider()
    private init() {}

    private var cache:    [String: Data] = [:]
    private var negative: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]

    /// Consumer mail providers — their favicon is the provider logo, not the
    /// person, so we skip the favicon fallback for these.
    private static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "outlook.com",
        "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
        "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "zoho.com",
        "mail.com", "yandex.com", "fastmail.com",
    ]

    func avatarData(for email: String) async -> Data? {
        let key = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard key.contains("@") else { return nil }
        if let data = cache[key] { return data }
        if negative.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }

        let task = Task<Data?, Never> { await Self.fetch(email: key) }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil

        if let data { cache[key] = data } else { negative.insert(key) }
        return data
    }

    private static func fetch(email: String) async -> Data? {
        // 1) Gravatar — d=404 so it fails cleanly when the sender has none.
        let hash = Insecure.MD5.hash(data: Data(email.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let url = URL(string: "https://www.gravatar.com/avatar/\(hash)?s=96&d=404"),
           let data = await load(url) {
            return data
        }

        // 2) Domain favicon (brand logo) for non-consumer domains.
        let domain = String(email.split(separator: "@").last ?? "")
        if !domain.isEmpty, !consumerDomains.contains(domain),
           let url = URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(domain)"),
           let data = await load(url) {
            return data
        }
        return nil
    }

    private static func load(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count > 100 else { return nil }     // skip empty / 1px placeholders
        return data
    }
}
