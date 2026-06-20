import AppKit
import ServiceManagement

/// Registers/unregisters the app as a macOS login item via the modern
/// ServiceManagement API (works for sandboxed apps; appears in
/// System Settings ▸ General ▸ Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        switch (enabled, SMAppService.mainApp.status) {
        case (true, let s) where s != .enabled:   try SMAppService.mainApp.register()
        case (false, .enabled):                    try SMAppService.mainApp.unregister()
        default:                                    break
        }
    }
}

final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private let launchSwitch  = NSSwitch()
    private let notifySwitch   = NSSwitch()
    private let imagesSwitch   = NSSwitch()
    private let accountStatus = NSTextField(labelWithString: "")
    private let accountButton = NSButton(title: "", target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "EmailViewer Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildLayout()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshState),
            name: .gmailAuthChanged, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refreshState()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let generalHeader = sectionHeader("GENERAL")
        let launchLabel   = NSTextField(labelWithString: "Launch at login")
        launchLabel.font  = .systemFont(ofSize: 13)
        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunchAtLogin)

        let launchHint = NSTextField(labelWithString: "Open EmailViewer automatically when you sign in.")
        launchHint.font = .systemFont(ofSize: 11)
        launchHint.textColor = .secondaryLabelColor

        let notifyLabel = NSTextField(labelWithString: "New mail notifications")
        notifyLabel.font = .systemFont(ofSize: 13)
        notifySwitch.target = self
        notifySwitch.action = #selector(toggleNotifications)

        let notifyHint = NSTextField(labelWithString: "Show a banner when new email arrives.")
        notifyHint.font = .systemFont(ofSize: 11)
        notifyHint.textColor = .secondaryLabelColor

        let divider = NSBox(); divider.boxType = .separator

        let privacyHeader = sectionHeader("PRIVACY")
        let imagesLabel = NSTextField(labelWithString: "Block remote images")
        imagesLabel.font = .systemFont(ofSize: 13)
        imagesSwitch.target = self
        imagesSwitch.action = #selector(toggleBlockImages)

        let imagesHint = NSTextField(labelWithString: "Stops senders from tracking when you open an email.")
        imagesHint.font = .systemFont(ofSize: 11)
        imagesHint.textColor = .secondaryLabelColor

        let divider2 = NSBox(); divider2.boxType = .separator

        let accountHeader = sectionHeader("ACCOUNT")
        accountStatus.font = .systemFont(ofSize: 13)
        accountButton.bezelStyle = .rounded
        accountButton.target = self
        accountButton.action = #selector(accountAction)

        let version = NSTextField(labelWithString: "EmailViewer \(appVersion())")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor

        let accountRow = NSStackView(views: [accountStatus, NSView(), accountButton])
        accountRow.orientation = .horizontal
        accountRow.distribution = .fill
        accountRow.alignment = .centerY

        let launchRow = NSStackView(views: [launchLabel, NSView(), launchSwitch])
        launchRow.orientation = .horizontal
        launchRow.alignment = .centerY

        let notifyRow = NSStackView(views: [notifyLabel, NSView(), notifySwitch])
        notifyRow.orientation = .horizontal
        notifyRow.alignment = .centerY

        let imagesRow = NSStackView(views: [imagesLabel, NSView(), imagesSwitch])
        imagesRow.orientation = .horizontal
        imagesRow.alignment = .centerY

        let stack = NSStackView(views: [
            generalHeader, launchRow, launchHint,
            spacer(6), notifyRow, notifyHint,
            spacer(8), divider, spacer(8),
            privacyHeader, imagesRow, imagesHint,
            spacer(8), divider2, spacer(8),
            accountHeader, accountRow,
            NSView(),
            version,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            launchRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            notifyRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            imagesRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            accountRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            divider2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
        ])
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    // MARK: - State

    @objc private func refreshState() {
        launchSwitch.state = LoginItem.isEnabled ? .on : .off
        notifySwitch.state = MailNotifier.isEnabled ? .on : .off
        imagesSwitch.state = Preferences.blockRemoteImages ? .on : .off
        let authed = GmailAuthManager.shared.isAuthenticated()
        accountButton.title     = authed ? "Sign Out" : "Connect Gmail"
        accountStatus.textColor = authed ? .labelColor : .secondaryLabelColor

        if authed {
            accountStatus.stringValue = "Gmail connected"
            // Replace with the actual address once the profile resolves.
            Task {
                if let email = await GmailFetcher.shared.accountEmail() {
                    self.accountStatus.stringValue = email
                }
            }
        } else {
            accountStatus.stringValue = "Not connected"
        }
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        let wantEnabled = launchSwitch.state == .on
        do {
            try LoginItem.setEnabled(wantEnabled)
        } catch {
            // Revert the toggle and surface the failure.
            launchSwitch.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Couldn't update Login Items"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func toggleNotifications() {
        MailNotifier.isEnabled = (notifySwitch.state == .on)
        if MailNotifier.isEnabled { MailNotifier.requestAuthorization() }
    }

    @objc private func toggleBlockImages() {
        Preferences.blockRemoteImages = (imagesSwitch.state == .on)
    }

    @objc private func accountAction() {
        if GmailAuthManager.shared.isAuthenticated() {
            GmailAuthManager.shared.signOut()   // posts .gmailAuthChanged
            refreshState()
        } else {
            Task {
                do {
                    try await GmailAuthManager.shared.startOAuthFlow()  // posts on success
                } catch {
                    print("❌ Connect failed: \(error)")
                }
                self.refreshState()
            }
        }
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(v)"
    }
}
