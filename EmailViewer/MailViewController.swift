import AppKit
import AuthenticationServices

final class MailViewController: NSViewController {

    /// Called when the user taps an email; the container handles navigation.
    var onSelectEmail: ((Email) -> Void)?

    private var allEmails: [Email] = []     // full inbox
    private var emails:    [Email] = []     // filtered/displayed
    private var searchQuery = ""
    private var currentFilter: InboxFilter = .all
    private var isLoading = false

    // MARK: - Views

    private lazy var searchField: NSSearchField = {
        let f = NSSearchField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.placeholderString = "Search mail"
        f.delegate = self
        f.focusRingType = .none
        f.sendsWholeSearchString = false
        f.sendsSearchStringImmediately = false
        return f
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
        b.toolTip = "Refresh"
        return b
    }()

    private lazy var spinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.style = .spinning; p.controlSize = .small; p.isHidden = true
        return p
    }()

    private lazy var filterBar: FilterBar = {
        let bar = FilterBar()
        bar.onChange = { [weak self] filter in
            self?.currentFilter = filter
            self?.applyFilter()
        }
        return bar
    }()

    private lazy var topDivider: NSBox = {
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
        sv.drawsBackground = false
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

    // Status text shown when the list is empty (no mail, no matches, errors).
    private lazy var emptyLabel: NSTextField = {
        let l = NSTextField(wrappingLabelWithString: "No emails")
        l.font = .systemFont(ofSize: 13)
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        l.maximumNumberOfLines = 0
        l.isHidden = true
        return l
    }()

    private lazy var connectButton: NSButton = {
        let b = NSButton(title: "Connect Gmail", target: self, action: #selector(connectGmail))
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.keyEquivalent = "\r"
        b.isHidden = true
        return b
    }()

    private lazy var emptyStack: NSStackView = {
        let s = NSStackView(views: [emptyLabel, connectButton])
        s.translatesAutoresizingMaskIntoConstraints = false
        s.orientation = .vertical
        s.alignment = .centerX
        s.spacing = 14
        return s
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 440, height: 560)))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(authChanged),
                                               name: .gmailAuthChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inboxDidUpdate),
                                               name: .inboxDidUpdate, object: nil)
        updateUI()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard GmailAuthManager.shared.isAuthenticated() else { updateUI(); return }
        Task {
            // Show cached emails (memory or disk) immediately, with no network hit.
            let cached = await GmailFetcher.shared.currentEmails()
            if !cached.isEmpty { self.setEmails(cached) }

            // Only go to the network when we have nothing, or the cache is stale.
            let stale = await GmailFetcher.shared.isListStale(maxAge: 300)
            if cached.isEmpty || stale { self.loadEmails(forceRefresh: true) }
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.documentView = tableView

        [searchField, refreshButton, spinner, filterBar, topDivider, scrollView, emptyStack].forEach(view.addSubview)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            refreshButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            refreshButton.widthAnchor.constraint(equalToConstant: 26),
            refreshButton.heightAnchor.constraint(equalToConstant: 26),

            spinner.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: refreshButton.centerXAnchor),

            filterBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 9),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),

            topDivider.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 9),
            topDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30),
        ])
    }

    // MARK: - Data & search

    private func setEmails(_ list: [Email]) {
        allEmails = list
        applyFilter()
    }

    private func applyFilter() {
        let base = allEmails.filter(currentFilter.matches)
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            emails = base
        } else {
            emails = base
                .compactMap { email -> (Email, Int)? in
                    guard let score = FuzzySearch.bestScore(
                        query: query,
                        in: [email.senderName, email.sender, email.subject, email.snippet]
                    ) else { return nil }
                    return (email, score)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard GmailAuthManager.shared.isAuthenticated() else {
            connectButton.isHidden = false
            showStatus("Connect your Gmail to view your inbox.")
            return
        }
        connectButton.isHidden = true
        if !emails.isEmpty {
            showStatus(nil)
        } else if isLoading {
            showStatus(nil)                                   // don't flash "No emails" mid-load
        } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            showStatus("No matches for “\(searchQuery)”.")
        } else {
            switch currentFilter {
            case .all:     showStatus("No emails")
            case .unread:  showStatus("No unread email")
            case .starred: showStatus("No starred email")
            }
        }
    }

    // MARK: - Actions

    @objc private func connectGmail() {
        Task {
            do {
                try await GmailAuthManager.shared.startOAuthFlow()   // posts .gmailAuthChanged on success
            } catch {
                self.handleAuthError(error)
            }
        }
    }

    @objc private func authChanged() {
        updateUI()
        if GmailAuthManager.shared.isAuthenticated() {
            loadEmails(forceRefresh: true)
        } else {
            Task { await GmailFetcher.shared.clearCache() }
            setEmails([])
        }
    }

    /// A background sync updated the cache — refresh the visible list silently.
    @objc private func inboxDidUpdate() {
        guard GmailAuthManager.shared.isAuthenticated() else { return }
        Task { self.setEmails(await GmailFetcher.shared.currentEmails()) }
    }

    @objc private func refresh() { loadEmails(forceRefresh: true) }

    func loadEmails(forceRefresh: Bool = false) {
        guard GmailAuthManager.shared.isAuthenticated(), !isLoading else { return }
        setLoading(true)

        Task {
            do {
                let fetched = try await GmailFetcher.shared.fetchEmails(forceRefresh: forceRefresh)
                await MainActor.run {
                    self.setEmails(fetched)
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
            GmailAuthManager.shared.signOut()        // posts .gmailAuthChanged → list clears
            showStatus("Your Gmail session expired.\nPlease reconnect.")
        } else if emails.isEmpty {
            showStatus((error as? LocalizedError)?.errorDescription ?? "Couldn't load your inbox.")
        }
    }

    private func handleAuthError(_ error: Error) {
        // User dismissing the Google sheet isn't an error worth showing.
        if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin { return }
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
        updateEmptyState()
    }

    func updateUI() {
        let authed = GmailAuthManager.shared.isAuthenticated()
        searchField.isHidden   = !authed
        filterBar.isHidden     = !authed
        refreshButton.isHidden = !authed || isLoading
        updateEmptyState()
    }
}

// MARK: - Search

extension MailViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchQuery = searchField.stringValue
        applyFilter()
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
        markReadLocally(email)
        onSelectEmail?(email)
    }

    /// Clears the unread state when an email is opened. Read-only scope means this
    /// is local-only (it doesn't mark the message read in Gmail).
    private func markReadLocally(_ email: Email) {
        guard !email.isRead else { return }
        if let i = allEmails.firstIndex(where: { $0.id == email.id }) {
            allEmails[i].isRead = true
        }
        applyFilter()
        Task {
            await GmailFetcher.shared.markRead(email.id)
            NotificationCenter.default.post(name: .inboxDidUpdate, object: nil)   // updates badge
        }
    }
}

// MARK: - Row View

final class MailRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - Cell

final class EmailCellView: NSView {

    private let avatar = AvatarView()

    private let unreadDot: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.cornerRadius = 3.5
        v.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        return v
    }()

    private let starIcon: NSImageView = {
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Starred")
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        iv.contentTintColor = .systemYellow
        iv.isHidden = true
        return iv
    }()

    private let senderLabel  = EmailCellView.label(size: 12.5, bold: true)
    private let dateLabel    = EmailCellView.label(size: 11,   color: .secondaryLabelColor)
    private let subjectLabel = EmailCellView.label(size: 12)
    private let snippetLabel = EmailCellView.label(size: 11.5, color: .secondaryLabelColor)

    private var starWidth: NSLayoutConstraint!

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
        [avatar, unreadDot, senderLabel, starIcon, dateLabel, subjectLabel, snippetLabel, separator]
            .forEach { addSubview($0) }
        dateLabel.alignment = .right
        starWidth = starIcon.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),

            unreadDot.widthAnchor.constraint(equalToConstant: 7),
            unreadDot.heightAnchor.constraint(equalToConstant: 7),
            unreadDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),

            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            senderLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            senderLabel.trailingAnchor.constraint(equalTo: starIcon.leadingAnchor, constant: -4),

            starWidth,
            starIcon.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            starIcon.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -4),

            dateLabel.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: unreadDot.leadingAnchor, constant: -8),
            dateLabel.widthAnchor.constraint(equalToConstant: 58),

            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 3),
            subjectLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            snippetLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 2),
            snippetLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            separator.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with email: Email) {
        avatar.configure(initials: email.initials, color: EmailCellView.avatarColor(for: email.senderEmail))
        senderLabel.stringValue  = email.senderName
        dateLabel.stringValue    = email.relativeDate
        subjectLabel.stringValue = email.subject
        snippetLabel.stringValue = email.snippet
        senderLabel.font = email.isRead ? .systemFont(ofSize: 12.5) : .boldSystemFont(ofSize: 12.5)
        unreadDot.isHidden = email.isRead
        starIcon.isHidden  = !email.isStarred
        starWidth.constant = email.isStarred ? 11 : 0
    }

    private static func avatarColor(for seed: String) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemGreen, .systemIndigo, .systemOrange,
                                  .systemPink, .systemPurple, .systemTeal, .systemRed]
        // Deterministic (process-stable) hash so a sender keeps the same color.
        let h = seed.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(h) % palette.count]
    }
}

// MARK: - Avatar

final class AvatarView: NSView {

    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 17

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(initials: String, color: NSColor) {
        label.stringValue = initials
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
