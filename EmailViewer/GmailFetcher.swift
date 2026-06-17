import Foundation

/// Thread-safe Gmail client. Being an `actor` makes the in-memory cache and
/// retry logic safe to touch from any task without data races.
actor GmailFetcher {

    static let shared = GmailFetcher()
    private init() {}

    private var cachedEmails: [Email] = []
    private var bodyCache: [String: EmailBody] = [:]
    private var lastListFetch: Date?
    private var didHydrate = false

    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    private let maxRetries     = 4
    private let listPageSize   = 25
    private let maxConcurrency = 6     // cap parallel metadata requests
    private let maxInlineImages = 30

    // MARK: - Fetch list (metadata only, fast)

    func fetchEmails(forceRefresh: Bool = false) async throws -> [Email] {
        hydrateIfNeeded()
        if !forceRefresh, !cachedEmails.isEmpty { return cachedEmails }

        // Resolve a valid token up front so an expired/revoked session surfaces
        // as one clear error instead of 25 silently-dropped requests.
        _ = try await GmailTokenStore.shared.validToken()

        let ids = try await fetchMessageIDs()

        // Bounded fan-out: a single bad message is skipped rather than failing
        // the whole inbox, but auth/network failures already surfaced above.
        let emails = await boundedMap(ids, maxConcurrent: maxConcurrency) { id in
            try? await self.fetchMessageMetadata(id: id)
        }

        cachedEmails  = emails.sorted { $0.date > $1.date }
        lastListFetch = Date()
        saveToDisk()
        return cachedEmails
    }

    /// Cached emails for instant display (in-memory, falling back to disk).
    /// Never hits the network.
    func currentEmails() -> [Email] {
        hydrateIfNeeded()
        return cachedEmails
    }

    /// True when the cached list is older than `maxAge` (or absent).
    func isListStale(maxAge: TimeInterval) -> Bool {
        hydrateIfNeeded()
        guard let last = lastListFetch else { return true }
        return Date().timeIntervalSince(last) > maxAge
    }

    func clearCache() {
        cachedEmails  = []
        bodyCache     = [:]
        lastListFetch = nil
        didHydrate    = true   // don't re-read the just-deleted disk cache
        clearDisk()
    }

    // MARK: - Fetch full body for a single email

    func body(for emailID: String) async throws -> EmailBody {
        if let cached = bodyCache[emailID] { return cached }
        let url  = URL(string: "\(baseURL)/messages/\(emailID)?format=full")!
        let data = try await authorizedData(url: url)
        let msg  = try JSONDecoder().decode(FullMessage.self, from: data)
        let body = await buildBody(from: msg, emailID: emailID)
        bodyCache[emailID] = body
        return body
    }

    // MARK: - List / metadata

    private func fetchMessageIDs() async throws -> [String] {
        var components = URLComponents(string: "\(baseURL)/messages")!
        components.queryItems = [
            .init(name: "maxResults", value: String(listPageSize)),
            .init(name: "labelIds",   value: "INBOX"),
        ]
        let data     = try await authorizedData(url: components.url!)
        let response = try JSONDecoder().decode(MessageListResponse.self, from: data)
        return response.messages?.map(\.id) ?? []
    }

    private func fetchMessageMetadata(id: String) async throws -> Email? {
        var components = URLComponents(string: "\(baseURL)/messages/\(id)")!
        components.queryItems = [
            .init(name: "format",          value: "metadata"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Date"),
        ]
        let data    = try await authorizedData(url: components.url!)
        let msg     = try JSONDecoder().decode(MessageDetail.self, from: data)
        let headers = msg.payload.headers
        let isRead  = !msg.labelIds.contains("UNREAD")

        return Email(
            id:      msg.id,
            subject: header("Subject", in: headers) ?? "(no subject)",
            sender:  header("From",    in: headers) ?? "Unknown",
            snippet: msg.snippet.htmlUnescaped,
            date:    parseDate(header("Date", in: headers) ?? "") ?? Date(),
            isRead:  isRead
        )
    }

    private func header(_ name: String, in headers: [MessageDetail.Header]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - Disk cache (survives app relaunch)

    private struct DiskPayload: Codable {
        let emails:  [Email]
        let savedAt: Date
    }

    private func hydrateIfNeeded() {
        guard !didHydrate else { return }
        didHydrate = true
        guard let url = diskURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data)
        else { return }
        cachedEmails  = payload.emails
        lastListFetch = payload.savedAt
    }

    private func saveToDisk() {
        guard let url = diskURL() else { return }
        let payload = DiskPayload(emails: cachedEmails, savedAt: lastListFetch ?? Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearDisk() {
        if let url = diskURL() { try? FileManager.default.removeItem(at: url) }
    }

    private func diskURL() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) else { return nil }
        let dir = base.appendingPathComponent("EmailViewer", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("inbox.json")
    }

    // MARK: - Authorized request with retry / backoff

    /// Performs an authenticated GET, transparently handling token refresh on
    /// 401, and rate-limit (429 / quota-403) and transient 5xx errors with
    /// exponential backoff. Non-recoverable statuses throw a typed error.
    private func authorizedData(url: URL, attempt: Int = 0) async throws -> Data {
        let token = try await GmailAuthManager.shared.validToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Transient transport error (timeout, connection drop): retry a few times.
            guard attempt < maxRetries, (error as? URLError)?.isTransient == true else { throw error }
            try await backoff(attempt: attempt, retryAfter: nil)
            return try await authorizedData(url: url, attempt: attempt + 1)
        }

        guard let http = response as? HTTPURLResponse else { return data }

        switch http.statusCode {
        case 200...299:
            return data

        case 401:
            // Refresh once (coalesced across callers) then retry a single time.
            guard attempt == 0 else { throw GmailError.unauthorized }
            _ = try await GmailTokenStore.shared.refresh()
            return try await authorizedData(url: url, attempt: attempt + 1)

        case 429:
            guard attempt < maxRetries else { throw GmailError.rateLimited }
            try await backoff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            return try await authorizedData(url: url, attempt: attempt + 1)

        case 403:
            // 403 is overloaded: retry only when it's a rate/quota reason.
            if isRateLimitError(data), attempt < maxRetries {
                try await backoff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                return try await authorizedData(url: url, attempt: attempt + 1)
            }
            throw GmailError.http(403, String(data: data, encoding: .utf8))

        case 500...599:
            guard attempt < maxRetries else { throw GmailError.server(http.statusCode) }
            try await backoff(attempt: attempt, retryAfter: nil)
            return try await authorizedData(url: url, attempt: attempt + 1)

        default:
            throw GmailError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    private func isRateLimitError(_ data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return body.contains("ratelimitexceeded")
            || body.contains("userratelimitexceeded")
            || body.contains("quotaexceeded")
    }

    private func backoff(attempt: Int, retryAfter: String?) async throws {
        let seconds: Double
        if let retryAfter, let s = Double(retryAfter) {
            seconds = s
        } else {
            seconds = min(pow(2.0, Double(attempt)), 8) + Double.random(in: 0...0.5)
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Runs `transform` over `ids` keeping at most `maxConcurrent` in flight.
    private func boundedMap(_ ids: [String],
                            maxConcurrent: Int,
                            _ transform: @escaping @Sendable (String) async -> Email?) async -> [Email] {
        guard !ids.isEmpty else { return [] }
        var results: [Email] = []
        var index = 0

        await withTaskGroup(of: Email?.self) { group in
            let initial = min(maxConcurrent, ids.count)
            for _ in 0..<initial {
                let id = ids[index]; index += 1
                group.addTask { await transform(id) }
            }
            while let value = await group.next() {
                if let value { results.append(value) }
                if index < ids.count {
                    let id = ids[index]; index += 1
                    group.addTask { await transform(id) }
                }
            }
        }
        return results
    }

    // MARK: - Body extraction (HTML preferred, charset-aware)

    private func buildBody(from msg: FullMessage, emailID: String) async -> EmailBody {
        let plain = firstPart(mimeType: "text/plain", in: msg.payload).flatMap(decodedString)

        if let htmlPart = firstPart(mimeType: "text/html", in: msg.payload),
           let rawHTML  = decodedString(htmlPart), !rawHTML.isEmpty {
            let html = await inlineCIDImages(in: rawHTML, payload: msg.payload, emailID: emailID)
            return EmailBody(html: html, plainText: plain)
        }

        // No HTML part: fall back to plain text, then the snippet.
        return EmailBody(html: nil, plainText: plain ?? msg.snippet.htmlUnescaped)
    }

    private func firstPart(mimeType: String, in payload: FullMessage.Payload) -> FullMessage.Payload? {
        if (payload.mimeType ?? "").lowercased() == mimeType, payload.body?.data != nil {
            return payload
        }
        for part in payload.parts ?? [] {
            if let found = firstPart(mimeType: mimeType, in: part) { return found }
        }
        return nil
    }

    private func decodedString(_ part: FullMessage.Payload) -> String? {
        guard let raw = part.body?.data, let data = Self.base64URLData(raw) else { return nil }
        let charset  = part.headerValue("Content-Type").flatMap(Self.charset(from:))
        let encoding = Self.stringEncoding(forCharset: charset)
        return String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Inline (cid:) images

    private func inlineCIDImages(in html: String,
                                 payload: FullMessage.Payload,
                                 emailID: String) async -> String {
        var images: [(cid: String, part: FullMessage.Payload)] = []
        collectInlineImages(payload, into: &images)
        guard !images.isEmpty else { return html }

        var result = html
        var inlined = 0
        for image in images where inlined < maxInlineImages {
            let token = "cid:\(image.cid)"
            guard result.contains(token) else { continue }
            guard let dataURI = await dataURI(for: image.part, emailID: emailID) else { continue }
            result = result.replacingOccurrences(of: token, with: dataURI)
            inlined += 1
        }
        return result
    }

    private func collectInlineImages(_ payload: FullMessage.Payload,
                                     into images: inout [(cid: String, part: FullMessage.Payload)]) {
        if (payload.mimeType ?? "").lowercased().hasPrefix("image/"),
           let cidHeader = payload.headerValue("Content-ID") {
            let cid = cidHeader.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            if !cid.isEmpty { images.append((cid, payload)) }
        }
        for part in payload.parts ?? [] {
            collectInlineImages(part, into: &images)
        }
    }

    private func dataURI(for part: FullMessage.Payload, emailID: String) async -> String? {
        let mime = part.mimeType ?? "image/png"
        let bytes: Data?
        if let inlineData = part.body?.data {
            bytes = Self.base64URLData(inlineData)
        } else if let attachmentId = part.body?.attachmentId {
            bytes = await fetchAttachment(emailID: emailID, attachmentId: attachmentId)
        } else {
            bytes = nil
        }
        guard let bytes, !bytes.isEmpty else { return nil }
        return "data:\(mime);base64,\(bytes.base64EncodedString())"
    }

    private func fetchAttachment(emailID: String, attachmentId: String) async -> Data? {
        let url = URL(string: "\(baseURL)/messages/\(emailID)/attachments/\(attachmentId)")!
        guard let data = try? await authorizedData(url: url),
              let resp = try? JSONDecoder().decode(AttachmentResponse.self, from: data),
              let body = resp.data else { return nil }
        return Self.base64URLData(body)
    }

    // MARK: - Encoding utilities

    static func base64URLData(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

    private static func charset(from contentType: String) -> String? {
        guard let range = contentType.range(of: #"(?i)charset="?([^;"\s]+)"#, options: .regularExpression) else {
            return nil
        }
        return contentType[range]
            .replacingOccurrences(of: "charset=", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private static func stringEncoding(forCharset name: String?) -> String.Encoding {
        guard let name, !name.isEmpty else { return .utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private func parseDate(_ string: String) -> Date? {
        // Some senders append "(UTC)" / "(PST)" etc.
        let cleaned = string.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#,
                                                  with: "", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z",
                       "dd MMM yyyy HH:mm:ss Z",
                       "EEE, dd MMM yyyy HH:mm:ss z",
                       "EEE, d MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    // MARK: - Errors

    enum GmailError: LocalizedError {
        case unauthorized
        case rateLimited
        case server(Int)
        case http(Int, String?)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Your Gmail session expired. Please reconnect."
            case .rateLimited:  return "Gmail is rate-limiting requests. Try again shortly."
            case .server(let c): return "Gmail had a server error (\(c)). Try again shortly."
            case .http(let c, _): return "Gmail request failed (HTTP \(c))."
            }
        }

        var requiresReauth: Bool {
            if case .unauthorized = self { return true }
            return false
        }
    }

    // MARK: - Response models

    private struct MessageListResponse: Decodable {
        let messages: [MessageRef]?
        struct MessageRef: Decodable { let id: String }
    }

    private struct MessageDetail: Decodable {
        let id: String; let snippet: String; let labelIds: [String]
        let payload: Payload
        struct Payload: Decodable { let headers: [Header] }
        struct Header: Decodable { let name: String; let value: String }
    }

    struct FullMessage: Decodable {
        let snippet: String
        let payload: Payload
        struct Payload: Decodable {
            let mimeType: String?
            let headers:  [Header]?
            let body:     Body?
            let parts:    [Payload]?

            func headerValue(_ name: String) -> String? {
                headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
            }
        }
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable {
            let data:         String?
            let attachmentId: String?
        }
    }

    private struct AttachmentResponse: Decodable { let data: String? }
}

// MARK: - Helpers

private extension URLError {
    nonisolated var isTransient: Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}

extension String {
    /// Gmail snippets arrive HTML-escaped (&amp; &#39; …). Decode the common entities for display.
    nonisolated var htmlUnescaped: String {
        guard contains("&") else { return self }
        var s = self
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, value) in map { s = s.replacingOccurrences(of: entity, with: value) }
        return s
    }
}
