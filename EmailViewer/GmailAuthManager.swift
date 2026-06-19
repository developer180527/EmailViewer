import AuthenticationServices
import CryptoKit

extension Notification.Name {
    /// Posted (on the main thread) whenever sign-in or sign-out completes.
    static let gmailAuthChanged = Notification.Name("gmailAuthChanged")
    /// Posted after a background sync changes the cached inbox.
    static let inboxDidUpdate = Notification.Name("inboxDidUpdate")
}

// MARK: - Configuration (nonisolated: shared by the main-actor manager and the token actor)

enum GmailConfig {
    nonisolated static let clientID    = "941618878714-t4buls3u2j9mq2muinecbq0pgqg0afbt.apps.googleusercontent.com"
    nonisolated static let redirectURI = "com.googleusercontent.apps.941618878714-t4buls3u2j9mq2muinecbq0pgqg0afbt:/oauth2callback"
    nonisolated static let scope       = "https://www.googleapis.com/auth/gmail.readonly"
    nonisolated static let tokenURL    = "https://oauth2.googleapis.com/token"
    nonisolated static let authBaseURL = "https://accounts.google.com/o/oauth2/v2/auth"

    enum Keys {
        nonisolated static let accessToken  = "gmail_access_token"
        nonisolated static let refreshToken = "gmail_refresh_token"
        nonisolated static let expiry       = "gmail_token_expiry"   // epoch seconds (String)
    }
}

// MARK: - Auth manager (drives the OAuth UI; main-actor by default)

final class GmailAuthManager: NSObject {  // must inherit NSObject for ASWebAuthenticationSession

    static let shared = GmailAuthManager()
    private override init() { super.init() }

    private var authSession: ASWebAuthenticationSession?

    // True once we've authenticated this launch. Guards against the UI bouncing
    // back to "Connect" if a keychain read momentarily fails mid-session.
    private var hasSession = false

    // PKCE + CSRF values, valid only for the duration of one in-flight auth attempt.
    private var pendingVerifier: String?
    private var pendingState: String?

    // MARK: Start OAuth (PKCE, installed-app flow)

    func startOAuthFlow() async throws {
        let verifier  = Self.randomURLSafeString(byteCount: 64)
        let challenge = Self.codeChallenge(for: verifier)
        let state     = Self.randomURLSafeString(byteCount: 32)
        pendingVerifier = verifier
        pendingState    = state

        var components = URLComponents(string: GmailConfig.authBaseURL)!
        components.queryItems = [
            .init(name: "client_id",             value: GmailConfig.clientID),
            .init(name: "redirect_uri",          value: GmailConfig.redirectURI),
            .init(name: "response_type",         value: "code"),
            .init(name: "scope",                 value: GmailConfig.scope),
            .init(name: "access_type",           value: "offline"),
            .init(name: "prompt",                value: "consent"),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state",                 value: state),
        ]

        guard let authURL = components.url,
              let scheme  = URLComponents(string: GmailConfig.redirectURI)?.scheme
        else { throw AuthError.invalidConfiguration }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AuthError.missingCode)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session  // retain it
            session.start()
        }

        try await handleRedirectURL(callbackURL)
    }

    // MARK: Handle redirect

    func handleRedirectURL(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        if let oauthError = items?.first(where: { $0.name == "error" })?.value {
            cancelPending()
            throw AuthError.authorizationDenied(oauthError)
        }

        // CSRF: returned state must match what we sent.
        let returnedState = items?.first(where: { $0.name == "state" })?.value
        if let expected = pendingState, returnedState != expected {
            cancelPending()
            throw AuthError.stateMismatch
        }

        guard let code = items?.first(where: { $0.name == "code" })?.value else {
            cancelPending()
            throw AuthError.missingCode
        }
        guard let verifier = pendingVerifier else { throw AuthError.missingVerifier }

        print("🔑 Got auth code, exchanging for tokens...")
        try await GmailTokenStore.shared.exchangeCode(code: code, verifier: verifier)
        hasSession = true
        cancelPending()
        print("✅ Signed in")
        NotificationCenter.default.post(name: .gmailAuthChanged, object: nil)
    }

    private func cancelPending() {
        pendingVerifier = nil
        pendingState    = nil
        authSession     = nil
    }

    // MARK: Token access (delegated to the token actor)

    func validToken() async throws -> String { try await GmailTokenStore.shared.validToken() }

    @discardableResult
    func forceRefresh() async throws -> String { try await GmailTokenStore.shared.refresh() }

    // MARK: Session helpers

    func isAuthenticated() -> Bool {
        hasSession || KeychainHelper.load(key: GmailConfig.Keys.refreshToken) != nil
    }

    func signOut() {
        hasSession = false
        KeychainHelper.delete(key: GmailConfig.Keys.accessToken)
        KeychainHelper.delete(key: GmailConfig.Keys.refreshToken)
        KeychainHelper.delete(key: GmailConfig.Keys.expiry)
        Task { await GmailTokenStore.shared.clearMemory() }
        print("👋 Signed out")
        NotificationCenter.default.post(name: .gmailAuthChanged, object: nil)
    }

    // MARK: PKCE utilities

    nonisolated private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    nonisolated private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    nonisolated private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum AuthError: LocalizedError {
        case missingCode
        case missingVerifier
        case stateMismatch
        case authorizationDenied(String)
        case tokenExchangeFailed(String)
        case missingRefreshToken
        case notAuthenticated
        case reauthenticationRequired
        case invalidConfiguration

        var errorDescription: String? {
            switch self {
            case .missingCode:                return "No authorization code was returned."
            case .missingVerifier:            return "The sign-in attempt expired. Please try again."
            case .stateMismatch:              return "Sign-in could not be verified. Please try again."
            case .authorizationDenied(let r): return "Authorization was denied (\(r))."
            case .tokenExchangeFailed:        return "Could not complete sign-in with Google."
            case .missingRefreshToken:        return "Google did not return a refresh token."
            case .notAuthenticated:           return "You are not signed in."
            case .reauthenticationRequired:   return "Your session expired. Please reconnect Gmail."
            case .invalidConfiguration:       return "The Gmail client is misconfigured."
            }
        }

        var requiresReauth: Bool {
            switch self {
            case .reauthenticationRequired, .notAuthenticated, .missingRefreshToken: return true
            default: return false
            }
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GmailAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? NSWindow()
    }
}

// MARK: - Token store (actor: thread-safe, single-flight refresh + exchange)

actor GmailTokenStore {

    static let shared = GmailTokenStore()
    private init() {}

    private var cachedToken: String?
    private var expiresAt:   Date?
    private var refreshTask: Task<String, Error>?

    // MARK: Public surface

    func validToken() async throws -> String {
        hydrateIfNeeded()
        if let token = cachedToken, let exp = expiresAt, exp.timeIntervalSinceNow > 120 {
            return token
        }
        return try await refresh()
    }

    /// Coalesces concurrent refreshes into a single network call.
    func refresh() async throws -> String {
        if let task = refreshTask { return try await task.value }
        let task = Task<String, Error> { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func exchangeCode(code: String, verifier: String) async throws {
        let request = tokenRequest(params: [
            "code":          code,
            "client_id":     GmailConfig.clientID,
            "redirect_uri":  GmailConfig.redirectURI,
            "grant_type":    "authorization_code",
            "code_verifier": verifier,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("❌ Token exchange failed: \(body)")
            throw GmailAuthManager.AuthError.tokenExchangeFailed(body)
        }

        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refresh = json.refresh_token else {
            throw GmailAuthManager.AuthError.missingRefreshToken
        }
        store(accessToken: json.access_token, refreshToken: refresh, expiresIn: json.expires_in ?? 3600)
    }

    func clearMemory() {
        cachedToken = nil
        expiresAt   = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: Internals

    private func hydrateIfNeeded() {
        guard cachedToken == nil else { return }
        cachedToken = KeychainHelper.load(key: GmailConfig.Keys.accessToken)
        if let s = KeychainHelper.load(key: GmailConfig.Keys.expiry), let t = Double(s) {
            expiresAt = Date(timeIntervalSince1970: t)
        }
    }

    private func performRefresh() async throws -> String {
        guard let refreshToken = KeychainHelper.load(key: GmailConfig.Keys.refreshToken) else {
            throw GmailAuthManager.AuthError.notAuthenticated
        }

        let request = tokenRequest(params: [
            "client_id":     GmailConfig.clientID,
            "refresh_token": refreshToken,
            "grant_type":    "refresh_token",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 400 / 401 (invalid_grant) => the refresh token is revoked/expired.
        if status == 400 || status == 401 {
            print("❌ Refresh rejected (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
            wipe()
            throw GmailAuthManager.AuthError.reauthenticationRequired
        }
        guard status == 200 else {
            throw GmailAuthManager.AuthError.tokenExchangeFailed("HTTP \(status)")
        }

        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        // A refresh response usually omits the refresh_token; keep the existing one.
        store(accessToken: json.access_token,
              refreshToken: json.refresh_token ?? refreshToken,
              expiresIn: json.expires_in ?? 3600)
        print("🔄 Access token refreshed")
        return json.access_token
    }

    private func store(accessToken: String, refreshToken: String, expiresIn: Int) {
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        cachedToken = accessToken
        expiresAt   = expiry
        KeychainHelper.save(key: GmailConfig.Keys.accessToken,  value: accessToken)
        KeychainHelper.save(key: GmailConfig.Keys.refreshToken, value: refreshToken)
        KeychainHelper.save(key: GmailConfig.Keys.expiry,       value: String(expiry.timeIntervalSince1970))
    }

    private func wipe() {
        cachedToken = nil
        expiresAt   = nil
        KeychainHelper.delete(key: GmailConfig.Keys.accessToken)
        KeychainHelper.delete(key: GmailConfig.Keys.refreshToken)
        KeychainHelper.delete(key: GmailConfig.Keys.expiry)
    }

    private func tokenRequest(params: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: GmailConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")  // RFC 3986 unreserved
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct TokenResponse: Decodable {
        let access_token:  String
        let refresh_token: String?
        let expires_in:    Int?
    }
}
