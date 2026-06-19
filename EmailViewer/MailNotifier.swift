import Foundation
import UserNotifications

/// Local desktop notifications for newly-arrived mail (native UserNotifications).
enum MailNotifier {

    private static let enabledKey = "notificationsEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Requests permission if not yet decided, and logs the resulting state so a
    /// missing notification can be diagnosed (denied vs. not-firing).
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    print("🔔 notification auth: granted=\(granted)\(error.map { ", error=\($0)" } ?? "")")
                }
            case .denied:
                print("🔕 notifications DENIED — enable in System Settings ▸ Notifications ▸ EmailViewer")
            case .authorized, .provisional, .ephemeral:
                print("🔔 notifications authorized")
            @unknown default:
                break
            }
        }
    }

    static func notify(newEmails: [Email]) {
        guard isEnabled, !newEmails.isEmpty else { return }
        let center = UNUserNotificationCenter.current()

        // A large batch becomes one summary banner instead of a storm.
        if newEmails.count > 3 {
            let anyAttachment = newEmails.contains(where: \.hasAttachments)
            let content = UNMutableNotificationContent()
            content.title = "\(newEmails.count) new emails"
            content.body  = (anyAttachment ? "📎 " : "") + newEmails.prefix(3).map(\.senderName).joined(separator: ", ") + "…"
            content.sound = .default
            post(content, id: "batch-\(UUID().uuidString)", via: center)
            return
        }

        for email in newEmails {
            let content = UNMutableNotificationContent()
            content.title = email.senderName                                   // sender
            content.body  = (email.hasAttachments ? "📎 " : "") + email.subject // 📎 + subject
            content.sound = .default
            content.userInfo = ["emailID": email.id]
            post(content, id: email.id, via: center)
        }
    }

    private static func post(_ content: UNNotificationContent, id: String, via center: UNUserNotificationCenter) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { error in
            if let error { print("⚠️ notification post failed: \(error)") }
        }
    }
}
