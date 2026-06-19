import Foundation

/// The decoded content of a message body. HTML is preferred when present;
/// `plainText` is the fallback used for plain messages or when rendering fails.
struct EmailBody: Codable {
    let html:      String?
    let plainText: String?

    var isEmpty: Bool { (html?.isEmpty ?? true) && (plainText?.isEmpty ?? true) }
}

/// A downloadable file attachment on a message.
struct EmailAttachment: Identifiable, Codable {
    let id:       String   // Gmail attachmentId
    let filename: String
    let mimeType: String
    let size:     Int      // bytes

    var displaySize: String {
        let kb = Double(size) / 1024
        if kb < 1    { return "\(size) B" }
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

/// A fully-loaded message: rendered body plus its attachments.
struct EmailContent: Codable {
    let body:        EmailBody
    let attachments: [EmailAttachment]
}

struct Email: Identifiable, Codable {
    let id:        String
    let subject:   String
    let sender:    String      // raw "Name <email>" string
    let snippet:   String
    let date:      Date
    var isRead:        Bool
    var isStarred:     Bool = false
    var hasAttachments: Bool = false
    var body:          String?     // loaded on demand

    // Extracts "Name" from "Name <email@domain.com>"
    var senderName: String {
        if let match = sender.range(of: #"^(.+?)\s*<"#, options: .regularExpression) {
            return String(sender[match]).trimmingCharacters(in: .init(charactersIn: " <"))
        }
        return sender
    }

    /// The bare email address, e.g. "Maya <m@acme.com>" → "m@acme.com".
    var senderEmail: String {
        if let match = sender.range(of: #"<([^>]+)>"#, options: .regularExpression) {
            return String(sender[match]).trimmingCharacters(in: .init(charactersIn: "<> "))
        }
        return sender
    }

    /// Up to two initials for the avatar, derived from the display name.
    var initials: String {
        let name = senderName.trimmingCharacters(in: .whitespaces)
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." }).filter { !$0.isEmpty }
        if let first = words.first?.first {
            if words.count > 1, let second = words[1].first {
                return "\(first)\(second)".uppercased()
            }
            return String(first).uppercased()
        }
        return "?"
    }

    var relativeDate: String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60              { return "Just now" }
        if diff < 3600            { return "\(Int(diff/60))m ago" }
        if diff < 86400           { return "\(Int(diff/3600))h ago" }
        if diff < 86400 * 2       { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = diff < 86400 * 7 ? "EEE" : "MMM d"
        return f.string(from: date)
    }
}
