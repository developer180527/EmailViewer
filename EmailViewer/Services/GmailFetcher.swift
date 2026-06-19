import Foundation

/// Thread-safe Gmail client. Being an `actor` makes the in-memory cache and
/// retry logic safe to touch from any task without data races.
actor GmailFetcher {

    static let shared = GmailFetcher()
    private init() {}

    private var cachedEmails: [Email] = []
    private var cachedEmailAddress: String?
    private var contentCache: [String: EmailContent] = [:]
    private var contentOrder: [String] = []           // FIFO eviction order
    private let maxCachedBodies = 12                   // cap memory used by parsed bodies
    private var lastListFetch: Date?
    private var lastHistoryId: String?     // baseline for incremental (delta) sync
    private var didHydrate = false

    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    private let maxRetries     = 4
    private let listPageSize   = 25
    private let maxConcurrency = 6     // cap parallel metadata requests
    private let maxInlineImages = 30
    private let maxCachedEmails = 50   // cap the cache so deltas don't grow it forever

    /// IDs we've already accounted for, so notifications fire once per message
    /// regardless of whether a full fetch or a delta sync discovered it.
    private var seenIDs: Set<String> = []

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
        lastHistoryId = try? await fetchProfileHistoryId()   // baseline for future deltas
        saveToDisk()
        return cachedEmails
    }

    // MARK: - Incremental (delta) sync

    /// Syncs the inbox (incrementally when possible) and returns the messages
    /// that are genuinely new since we last looked — i.e. worth a notification.
    func checkForNewMail() async throws -> [Email] {
        hydrateIfNeeded()

        if let baseline = lastHistoryId {
            do {
                let changes = try await fetchHistory(since: baseline)
                await applyDelta(changes)
            } catch let error as GmailError {
                if case .http(404, _) = error {
                    _ = try await fetchEmails(forceRefresh: true)   // history window expired
                } else {
                    throw error
                }
            }
        } else {
            _ = try await fetchEmails(forceRefresh: true)           // no baseline yet
        }

        // New = unread messages now in the cache that we hadn't seen before.
        // The first sync just seeds `seenIDs` (so we don't notify the whole inbox).
        let firstSync = seenIDs.isEmpty
        let newMail   = firstSync ? [] : cachedEmails.filter { !$0.isRead && !seenIDs.contains($0.id) }
        seenIDs = Set(cachedEmails.map(\.id))
        saveToDisk()
        return newMail.sorted { $0.date > $1.date }
    }

    /// Marks a message read in the local cache only (we hold read-only scope, so
    /// this doesn't change Gmail — it just clears the unread state in the UI).
    func markRead(_ id: String) {
        guard let i = cachedEmails.firstIndex(where: { $0.id == id }), !cachedEmails[i].isRead else { return }
        cachedEmails[i].isRead = true
        saveToDisk()
    }

    /// Unread messages currently in the cache (drives the menu-bar dot).
    func unreadCount() -> Int {
        hydrateIfNeeded()
        return cachedEmails.filter { !$0.isRead }.count
    }

    private func applyDelta(_ changes: HistoryChanges) async {
        let knownIDs = Set(cachedEmails.map(\.id))
        let toFetch  = changes.addedIDs.filter { !knownIDs.contains($0) }
        let added    = await boundedMap(toFetch, maxConcurrent: maxConcurrency) { id in
            try? await self.fetchMessageMetadata(id: id)
        }

        for i in cachedEmails.indices {
            if changes.markedRead.contains(cachedEmails[i].id)   { cachedEmails[i].isRead = true }
            if changes.markedUnread.contains(cachedEmails[i].id) { cachedEmails[i].isRead = false }
        }
        if !changes.removedIDs.isEmpty {
            cachedEmails.removeAll { changes.removedIDs.contains($0.id) }
        }
        if !added.isEmpty {
            cachedEmails.append(contentsOf: added)
        }
        cachedEmails.sort { $0.date > $1.date }
        if cachedEmails.count > maxCachedEmails {
            cachedEmails = Array(cachedEmails.prefix(maxCachedEmails))
        }
        lastHistoryId = changes.newHistoryId ?? lastHistoryId
        lastListFetch = Date()
        saveToDisk()
    }

    private struct HistoryChanges {
        var addedIDs:     [String] = []
        var removedIDs:   Set<String> = []
        var markedRead:   Set<String> = []
        var markedUnread: Set<String> = []
        var newHistoryId: String?
    }

    private func fetchHistory(since startHistoryId: String) async throws -> HistoryChanges {
        var changes = HistoryChanges()
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "\(baseURL)/history")!
            components.queryItems = [
                .init(name: "startHistoryId", value: startHistoryId),
                .init(name: "labelId",        value: "INBOX"),
                .init(name: "historyTypes",   value: "messageAdded"),
                .init(name: "historyTypes",   value: "messageDeleted"),
                .init(name: "historyTypes",   value: "labelAdded"),
                .init(name: "historyTypes",   value: "labelRemoved"),
            ]
            if let pageToken { components.queryItems?.append(.init(name: "pageToken", value: pageToken)) }

            let data     = try await authorizedData(url: components.url!)
            let response = try JSONDecoder().decode(HistoryListResponse.self, from: data)
            changes.newHistoryId = response.historyId

            for record in response.history ?? [] {
                for added in record.messagesAdded ?? [] where added.message.labelIds?.contains("INBOX") == true {
                    changes.addedIDs.append(added.message.id)
                }
                for deleted in record.messagesDeleted ?? [] {
                    changes.removedIDs.insert(deleted.message.id)
                }
                for change in record.labelsRemoved ?? [] where change.labelIds?.contains("UNREAD") == true {
                    changes.markedRead.insert(change.message.id)
                }
                for change in record.labelsAdded ?? [] where change.labelIds?.contains("UNREAD") == true {
                    changes.markedUnread.insert(change.message.id)
                }
            }
            pageToken = response.nextPageToken
        } while pageToken != nil

        return changes
    }

    private func fetchProfileHistoryId() async throws -> String? {
        let data = try await authorizedData(url: URL(string: "\(baseURL)/profile")!)
        return try JSONDecoder().decode(ProfileResponse.self, from: data).historyId
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
        cachedEmailAddress = nil
        contentCache  = [:]
        contentOrder  = []
        lastListFetch = nil
        lastHistoryId = nil
        seenIDs       = []
        didHydrate    = true   // don't re-read the just-deleted disk cache
        clearDisk()
    }

    // MARK: - Fetch full body for a single email

    func content(for emailID: String) async throws -> EmailContent {
        // Memory cache, then disk cache — a previously-opened email never re-hits the API.
        if let cached = contentCache[emailID] { return cached }
        if let onDisk = loadContentFromDisk(emailID) {
            rememberContent(onDisk, for: emailID)
            return onDisk
        }

        let url  = URL(string: "\(baseURL)/messages/\(emailID)?format=full")!
        let data = try await authorizedData(url: url)
        let msg  = try JSONDecoder().decode(FullMessage.self, from: data)

        let body = await buildBody(from: msg, emailID: emailID)
        var attachments: [EmailAttachment] = []
        collectAttachments(msg.payload, into: &attachments)

        let content = EmailContent(body: body, attachments: attachments)
        rememberContent(content, for: emailID)
        saveContentToDisk(content, for: emailID)
        return content
    }

    private func rememberContent(_ content: EmailContent, for emailID: String) {
        contentCache[emailID] = content
        contentOrder.removeAll { $0 == emailID }
        contentOrder.append(emailID)
        if contentOrder.count > maxCachedBodies {
            contentCache[contentOrder.removeFirst()] = nil
        }
    }

    /// Downloads a single attachment's bytes (used when the user saves it).
    func attachmentData(emailID: String, attachmentId: String) async -> Data? {
        await fetchAttachment(emailID: emailID, attachmentId: attachmentId)
    }

    // MARK: - Trash (move to Gmail Trash — reversible; needs gmail.modify scope)

    func trash(_ emailID: String) async throws {
        let url = URL(string: "\(baseURL)/messages/\(emailID)/trash")!
        do {
            _ = try await authorizedData(url: url, method: "POST")
        } catch let GmailError.http(403, body) {
            let text = (body ?? "").lowercased()
            if text.contains("insufficient") || text.contains("scope") {
                throw GmailError.insufficientScope
            }
            throw GmailError.http(403, body)
        }
        cachedEmails.removeAll { $0.id == emailID }
        contentCache[emailID] = nil
        contentOrder.removeAll { $0 == emailID }
        deleteContentFromDisk(emailID)
        saveToDisk()
    }

    // MARK: - Account

    /// The connected Gmail address (cached for the session).
    func accountEmail() async -> String? {
        if let cached = cachedEmailAddress { return cached }
        guard let data = try? await authorizedData(url: URL(string: "\(baseURL)/profile")!),
              let resp = try? JSONDecoder().decode(ProfileResponse.self, from: data) else { return nil }
        cachedEmailAddress = resp.emailAddress
        return resp.emailAddress
    }

    private func collectAttachments(_ payload: FullMessage.Payload, into list: inout [EmailAttachment]) {
        if let filename = payload.filename, !filename.isEmpty,
           let attachmentId = payload.body?.attachmentId {
            list.append(EmailAttachment(
                id:       attachmentId,
                filename: filename,
                mimeType: payload.mimeType ?? "application/octet-stream",
                size:     payload.body?.size ?? 0
            ))
        }
        for part in payload.parts ?? [] {
            collectAttachments(part, into: &list)
        }
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
            .init(name: "metadataHeaders", value: "Content-Type"),
        ]
        let data    = try await authorizedData(url: components.url!)
        let msg     = try JSONDecoder().decode(MessageDetail.self, from: data)
        let headers = msg.payload.headers

        // Heuristic from the top-level Content-Type: a multipart/mixed message
        // carries file attachments (alternative/related do not).
        let contentType = header("Content-Type", in: headers)?.lowercased() ?? ""

        return Email(
            id:             msg.id,
            subject:        header("Subject", in: headers) ?? "(no subject)",
            sender:         header("From",    in: headers) ?? "Unknown",
            snippet:        msg.snippet.htmlUnescaped,
            date:           parseDate(header("Date", in: headers) ?? "") ?? Date(),
            isRead:         !msg.labelIds.contains("UNREAD"),
            isStarred:      msg.labelIds.contains("STARRED"),
            hasAttachments: contentType.contains("multipart/mixed")
        )
    }

    private func header(_ name: String, in headers: [MessageDetail.Header]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - Disk cache (survives app relaunch)

    private struct DiskPayload: Codable {
        let emails:    [Email]
        let savedAt:   Date
        var historyId: String?
        var seenIDs:   [String]?
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
        lastHistoryId = payload.historyId
        seenIDs       = Set(payload.seenIDs ?? [])
    }

    private func saveToDisk() {
        guard let url = diskURL() else { return }
        let payload = DiskPayload(emails: cachedEmails, savedAt: lastListFetch ?? Date(),
                                  historyId: lastHistoryId, seenIDs: Array(seenIDs))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearDisk() {
        if let url = diskURL() { try? FileManager.default.removeItem(at: url) }
        if let dir = bodiesDir() { try? FileManager.default.removeItem(at: dir) }
    }

    private func diskURL() -> URL? {
        appSupportDir()?.appendingPathComponent("inbox.json")
    }

    private func appSupportDir() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) else { return nil }
        let dir = base.appendingPathComponent("EmailViewer", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Persistent body cache (opened emails survive relaunch, never re-hit the API)

    private let maxDiskBodies = 40

    private func bodiesDir() -> URL? {
        guard let dir = appSupportDir()?.appendingPathComponent("bodies", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bodyFile(_ emailID: String) -> URL? {
        // Message IDs are hex/url-safe, fine as a filename.
        bodiesDir()?.appendingPathComponent("\(emailID).json")
    }

    private func loadContentFromDisk(_ emailID: String) -> EmailContent? {
        guard let url = bodyFile(emailID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EmailContent.self, from: data)
    }

    private func saveContentToDisk(_ content: EmailContent, for emailID: String) {
        guard let url = bodyFile(emailID), let data = try? JSONEncoder().encode(content) else { return }
        try? data.write(to: url, options: .atomic)
        pruneDiskBodies()
    }

    private func deleteContentFromDisk(_ emailID: String) {
        if let url = bodyFile(emailID) { try? FileManager.default.removeItem(at: url) }
    }

    /// Keep only the most-recently-modified body files.
    private func pruneDiskBodies() {
        guard let dir = bodiesDir() else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxDiskBodies else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(maxDiskBodies) { try? fm.removeItem(at: file) }
    }

    // MARK: - Authorized request with retry / backoff

    /// Performs an authenticated GET, transparently handling token refresh on
    /// 401, and rate-limit (429 / quota-403) and transient 5xx errors with
    /// exponential backoff. Non-recoverable statuses throw a typed error.
    private func authorizedData(url: URL, method: String = "GET", attempt: Int = 0) async throws -> Data {
        let token = try await GmailAuthManager.shared.validToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Transient transport error (timeout, connection drop): retry a few times.
            guard attempt < maxRetries, (error as? URLError)?.isTransient == true else { throw error }
            try await backoff(attempt: attempt, retryAfter: nil)
            return try await authorizedData(url: url, method: method, attempt: attempt + 1)
        }

        guard let http = response as? HTTPURLResponse else { return data }

        switch http.statusCode {
        case 200...299:
            return data

        case 401:
            // Refresh once (coalesced across callers) then retry a single time.
            guard attempt == 0 else { throw GmailError.unauthorized }
            _ = try await GmailTokenStore.shared.refresh()
            return try await authorizedData(url: url, method: method, attempt: attempt + 1)

        case 429:
            guard attempt < maxRetries else { throw GmailError.rateLimited }
            try await backoff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            return try await authorizedData(url: url, method: method, attempt: attempt + 1)

        case 403:
            // 403 is overloaded: retry only when it's a rate/quota reason.
            if isRateLimitError(data), attempt < maxRetries {
                try await backoff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                return try await authorizedData(url: url, method: method, attempt: attempt + 1)
            }
            throw GmailError.http(403, String(data: data, encoding: .utf8))

        case 500...599:
            guard attempt < maxRetries else { throw GmailError.server(http.statusCode) }
            try await backoff(attempt: attempt, retryAfter: nil)
            return try await authorizedData(url: url, method: method, attempt: attempt + 1)

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
        case insufficientScope

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Your Gmail session expired. Please reconnect."
            case .rateLimited:  return "Gmail is rate-limiting requests. Try again shortly."
            case .server(let c): return "Gmail had a server error (\(c)). Try again shortly."
            case .http(let c, _): return "Gmail request failed (HTTP \(c))."
            case .insufficientScope:
                return "Reconnect Gmail to enable delete (it needs broader permission)."
            }
        }

        var requiresReauth: Bool {
            switch self {
            case .unauthorized, .insufficientScope: return true
            default: return false
            }
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

    private struct ProfileResponse: Decodable { let historyId: String?; let emailAddress: String? }

    private struct HistoryListResponse: Decodable {
        let history:       [Record]?
        let historyId:     String?
        let nextPageToken: String?

        struct Record: Decodable {
            let messagesAdded:   [MessageEvent]?
            let messagesDeleted: [MessageEvent]?
            let labelsAdded:     [LabelEvent]?
            let labelsRemoved:   [LabelEvent]?
        }
        struct MessageEvent: Decodable { let message: HistoryMessage }
        struct LabelEvent: Decodable { let message: HistoryMessage; let labelIds: [String]? }
        struct HistoryMessage: Decodable { let id: String; let labelIds: [String]? }
    }

    struct FullMessage: Decodable {
        let snippet: String
        let payload: Payload
        struct Payload: Decodable {
            let mimeType: String?
            let filename: String?
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
            let size:         Int?
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
