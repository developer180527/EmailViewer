import Cocoa
import UserNotifications

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    var popover:    NSPopover!

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 30

    private lazy var badgeDot: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        v.wantsLayer = true
        v.layer?.cornerRadius = 3
        v.layer?.backgroundColor = NSColor.systemYellow.cgColor
        v.isHidden = true
        return v
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 launched")
        setupStatusItem()
        setupPopover()

        UNUserNotificationCenter.current().delegate = self
        MailNotifier.requestAuthorization()

        NotificationCenter.default.addObserver(self, selector: #selector(authChanged),
                                               name: .gmailAuthChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshBadge),
                                               name: .inboxDidUpdate, object: nil)
        startMonitoring()
        refreshBadge()
    }

    // Called when Google redirects back after OAuth (legacy custom-scheme path;
    // the primary flow completes inside ASWebAuthenticationSession).
    func application(_ application: NSApplication, open urls: [URL]) {
        // Don't log the full URL — it carries the one-time OAuth code.
        print("📲 Received OAuth redirect")
        guard let url = urls.first else { return }
        Task {
            do {
                try await GmailAuthManager.shared.handleRedirectURL(url)
                (self.popover.contentViewController as? RootViewController)?.handleSignInCompleted()
            } catch {
                print("❌ Auth failed: \(error)")
            }
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: "Mail")
        image?.isTemplate = true   // adapts to light/dark menu bar
        statusItem.button?.image  = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        if let button = statusItem.button { button.addSubview(badgeDot) }
        updateBadge(hasUnread: false)
        print("✅ status item ready")
    }

    /// Shows a small yellow dot on the envelope when there's unread mail.
    private func updateBadge(hasUnread: Bool) {
        badgeDot.isHidden = !hasUnread
        positionBadgeDot()
    }

    private func positionBadgeDot() {
        guard let button = statusItem.button else { return }
        let s: CGFloat = 6
        let inset: CGFloat = 2
        // The status-bar button is flipped (y grows downward), so "top" is minY.
        let x = button.bounds.maxX - s - inset
        let y = button.isFlipped ? button.bounds.minY + inset
                                 : button.bounds.maxY - s - inset
        badgeDot.frame = NSRect(x: x, y: y, width: s, height: s)
    }

    @objc private func refreshBadge() {
        Task {
            let count = await GmailFetcher.shared.unreadCount()
            await MainActor.run { self.updateBadge(hasUnread: count > 0) }
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = RootViewController.contentSize
        popover.behavior    = .transient
        popover.animates    = true
        popover.delegate    = self
        popover.contentViewController = RootViewController()
        print("✅ popover ready")
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        pollNow()   // fresh check whenever the user opens the inbox
    }

    // MARK: - Background monitoring

    @objc private func authChanged() {
        refreshBadge()
        startMonitoring()
        if GmailAuthManager.shared.isAuthenticated() { pollNow() }
    }

    private func startMonitoring() {
        pollTimer?.invalidate()
        guard GmailAuthManager.shared.isAuthenticated() else { return }

        // First check shortly after launch, then on a steady interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.pollNow() }

        // Add in `.common` mode so it keeps firing while the popover/menu is open
        // (the default mode pauses during UI tracking).
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.pollNow() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollNow() {
        guard GmailAuthManager.shared.isAuthenticated() else { return }
        Task {
            do {
                let newMail = try await GmailFetcher.shared.checkForNewMail()
                await MainActor.run {
                    if !newMail.isEmpty { print("📬 \(newMail.count) new email(s)") }
                    MailNotifier.notify(newEmails: newMail)
                    // Refresh the visible list + badge (read-state / removals included).
                    NotificationCenter.default.post(name: .inboxDidUpdate, object: nil)
                }
            } catch {
                print("⚠️ poll failed: \(error)")
            }
        }
    }
}

// MARK: - Popover lifecycle (idle resource cleanup)

extension AppDelegate: NSPopoverDelegate {
    // When the inbox closes, drop back to the list so any open email's WKWebView
    // (and its renderer process / memory) is released while idle.
    func popoverDidClose(_ notification: Notification) {
        (popover.contentViewController as? RootViewController)?.popToList()
    }
}

// MARK: - Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {

    // Show the banner even when the app is the active one.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Tapping a notification opens the popover and jumps straight to that email.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        showPopover()
        if let id = response.notification.request.content.userInfo["emailID"] as? String {
            Task {
                if let email = await GmailFetcher.shared.email(withID: id) {
                    await MainActor.run {
                        (self.popover.contentViewController as? RootViewController)?.openEmail(email)
                    }
                }
            }
        }
        completionHandler()
    }
}
