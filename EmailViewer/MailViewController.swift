import AppKit
import AuthenticationServices

final class MailViewController: NSViewController {

    /// Called when the user taps an email; the container handles navigation.
    var onSelectEmail: ((Email) -> Void)?

    private var emails:    [Email] = []
    private var isLoading = false
    // MARK: - Views

    private lazy var headerView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return v
    }()

    private lazy var titleLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Inbox")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .boldSystemFont(ofSize: 13)
        l.textColor = .labelColor
        return l
    }()

    private lazy var refreshButton: NSButton = {
        let b = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: self, action: #selector(refresh)
        )
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        return b
    }()
    

    private lazy var connectButton: NSButton = {
        let b = NSButton(title: "Connect Gmail", target: self, action: #selector(connectGmail))
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .rounded
        return b
    }()

    private lazy var spinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.style = .spinning; p.controlSize = .small; p.isHidden = true
        return p
    }()

    private lazy var divider: NSBox = {
        let b = NSBox()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.boxType = .separator
        return b
    }()

    private lazy var scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = false
        sv.horizontalScrollElasticity = .none
        sv.borderType      = .noBorder
        sv.backgroundColor = .clear
        return sv
    }()

    private lazy var tableView: NSTableView = {
        let tv = NSTableView()
        tv.dataSource  = self
        tv.delegate    = self
        tv.rowHeight   = 70
        tv.headerView  = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let col = NSTableColumn(identifier: .init("email"))
        col.minWidth      = 240
        col.resizingMask  = .autoresizingMask  // grow/shrink with the popover width
        tv.addTableColumn(col)
        return tv
    }()

    // Doubles as empty-inbox and error/status message.
    private lazy var emptyLabel: NSTextField = {
        let l = NSTextField(wrappingLabelWithString: "No emails")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13)
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = 300
        l.isHidden = true
        return l
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 360, height: 500)))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        updateUI()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard GmailAuthManager.shared.isAuthenticated() else { updateUI(); return }
        Task {
            // Show cached emails (memory or disk) immediately, with no network hit.
            let cached = await GmailFetcher.shared.currentEmails()
            if !cached.isEmpty {
                self.emails = cached
                self.tableView.reloadData()
                self.showStatus(nil)
            }
            // Only go to the network when we have nothing, or the cache is stale —
            // not on every menu-bar click.
            let stale = await GmailFetcher.shared.isListStale(maxAge: 300)
            if cached.isEmpty || stale {
                self.loadEmails(forceRefresh: true)
            }
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.documentView = tableView

        view.addSubview(headerView)
        headerView.addSubview(titleLabel)
        headerView.addSubview(refreshButton)
        headerView.addSubview(spinner)
        headerView.addSubview(connectButton)
        view.addSubview(divider)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),

            refreshButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -10),
            refreshButton.widthAnchor.constraint(equalToConstant: 28),
            refreshButton.heightAnchor.constraint(equalToConstant: 28),

            spinner.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -10),

            connectButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            connectButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -10),

            divider.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func connectGmail() {
        if GmailAuthManager.shared.isAuthenticated() {
            GmailAuthManager.shared.signOut()
            Task { await GmailFetcher.shared.clearCache() }
            emails = []; tableView.reloadData(); updateUI()
        } else {
            Task {
                do {
                    try await GmailAuthManager.shared.startOAuthFlow()
                    self.updateUI()
                    self.loadEmails(forceRefresh: true)
                } catch {
                    self.handleAuthError(error)
                }
            }
        }
    }

    @objc private func refresh() { loadEmails(forceRefresh: true) }

    func loadEmails(forceRefresh: Bool = false) {
        guard !isLoading else { return }
        setLoading(true)

        Task {
            do {
                let fetched = try await GmailFetcher.shared.fetchEmails(forceRefresh: forceRefresh)
                await MainActor.run {
                    self.emails = fetched
                    self.tableView.reloadData()
                    self.showStatus(fetched.isEmpty ? "No emails" : nil)
                    self.setLoading(false)
                }
            } catch {
                await MainActor.run {
                    self.setLoading(false)
                    self.handleLoadError(error)
                }
            }
        }
    }

    // MARK: - Error handling

    private func handleLoadError(_ error: Error) {
        if requiresReauth(error) {
            GmailAuthManager.shared.signOut()
            Task { await GmailFetcher.shared.clearCache() }
            emails = []
            tableView.reloadData()
            updateUI()
            showStatus("Your Gmail session expired.\nPlease reconnect.")
        } else if emails.isEmpty {
            // Only replace the list with an error when we have nothing to show.
            showStatus((error as? LocalizedError)?.errorDescription ?? "Couldn't load your inbox.")
        }
    }

    private func handleAuthError(_ error: Error) {
        // User dismissing the Google sheet isn't an error worth showing.
        if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
            return
        }
        print("❌ Auth failed: \(error)")
        showStatus((error as? LocalizedError)?.errorDescription ?? "Sign-in failed. Please try again.")
    }

    private func requiresReauth(_ error: Error) -> Bool {
        (error as? GmailFetcher.GmailError)?.requiresReauth == true ||
        (error as? GmailAuthManager.AuthError)?.requiresReauth == true
    }

    private func showStatus(_ text: String?) {
        if let text {
            emptyLabel.stringValue = text
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func setLoading(_ on: Bool) {
        isLoading = on
        if on {
            spinner.isHidden = false; spinner.startAnimation(nil)
            refreshButton.isHidden = true
        } else {
            spinner.stopAnimation(nil); spinner.isHidden = true
            refreshButton.isHidden = !GmailAuthManager.shared.isAuthenticated()
        }
    }

    func updateUI() {
        let authed = GmailAuthManager.shared.isAuthenticated()
        connectButton.title    = authed ? "Sign Out" : "Connect Gmail"
        refreshButton.isHidden = !authed || isLoading
        if !authed {
            emails = []
            tableView.reloadData()
            showStatus("Connect your Gmail to get started.")
        }
    }
}

// MARK: - Table DataSource & Delegate

extension MailViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { emails.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 70 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = EmailCellView()
        cell.configure(with: emails[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MailRowView() }

    // Hand selection to the container, which navigates to the detail view.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < emails.count else { return }
        let email = emails[row]
        tableView.deselectAll(nil)
        onSelectEmail?(email)
    }
}

// MARK: - Row View

final class MailRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - Cell

final class EmailCellView: NSView {

    private let unreadDot: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        return v
    }()

    private let senderLabel  = EmailCellView.label(size: 12.5, bold: true)
    private let dateLabel    = EmailCellView.label(size: 11,   color: .secondaryLabelColor)
    private let subjectLabel = EmailCellView.label(size: 12)
    private let snippetLabel = EmailCellView.label(size: 11.5, color: .secondaryLabelColor)

    private let separator: NSBox = {
        let b = NSBox()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.boxType = .separator
        return b
    }()

    private static func label(size: CGFloat, bold: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [unreadDot, senderLabel, dateLabel, subjectLabel, snippetLabel, separator].forEach { addSubview($0) }
        dateLabel.alignment = .right

        NSLayoutConstraint.activate([
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            unreadDot.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),

            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            senderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            senderLabel.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -8),

            dateLabel.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dateLabel.widthAnchor.constraint(equalToConstant: 70),

            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 3),
            subjectLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            snippetLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 2),
            snippetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with email: Email) {
        senderLabel.stringValue  = email.senderName
        dateLabel.stringValue    = email.relativeDate
        subjectLabel.stringValue = email.subject
        snippetLabel.stringValue = email.snippet
        senderLabel.font = email.isRead ? .systemFont(ofSize: 12.5) : .boldSystemFont(ofSize: 12.5)
        unreadDot.isHidden = email.isRead
    }
}

