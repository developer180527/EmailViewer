import Foundation

/// The decoded content of a message body. HTML is preferred when present;
/// `plainText` is the fallback used for plain messages or when rendering fails.
struct EmailBody {
    let html:      String?
    let plainText: String?

    var isEmpty: Bool { (html?.isEmpty ?? true) && (plainText?.isEmpty ?? true) }
}

struct Email: Identifiable, Codable {
    let id:      String
    let subject: String
    let sender:  String      // raw "Name <email>" string
    let snippet: String
    let date:    Date
    var isRead:  Bool
    var body:    String?     // loaded on demand

    // Extracts "Name" from "Name <email@domain.com>"
    var senderName: String {
        if let match = sender.range(of: #"^(.+?)\s*<"#, options: .regularExpression) {
            return String(sender[match]).trimmingCharacters(in: .init(charactersIn: " <"))
        }
        return sender
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
