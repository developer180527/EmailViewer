import AppKit
import AuthenticationServices

final class MailViewController: NSViewController {

    /// Called when the user taps an email; the container handles navigation.
    var onSelectEmail: ((Email) -> Void)?

    private var focusedRow = -1             // keyboard-navigation focus
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

    private lazy var headerBackground: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.material = .headerView           // subtle toolbar depth above the list
        v.blendingMode = .withinWindow
        v.state = .followsWindowActiveState
        return v
    }()

    private lazy var skeletonView: SkeletonView = {
        let s = SkeletonView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.isHidden = true
        return s
    }()

    private lazy var tableView: NSTableView = {
        let tv = HoverTableView()
        tv.dataSource  = self
        tv.delegate    = self
        tv.rowHeight   = 72
        tv.headerView  = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.style = .plain                 // edge-to-edge rows (no inset margins)
        tv.intercellSpacing = NSSize(width: 0, height: 0)
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

        [headerBackground, searchField, refreshButton, spinner, filterBar, topDivider,
         scrollView, skeletonView, emptyStack].forEach(view.addSubview)

        NSLayoutConstraint.activate([
            headerBackground.topAnchor.constraint(equalTo: view.topAnchor),
            headerBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBackground.bottomAnchor.constraint(equalTo: topDivider.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            refreshButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            refreshButton.widthAnchor.constraint(equalToConstant: 26),
            refreshButton.heightAnchor.constraint(equalToConstant: 26),

            spinner.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: refreshButton.centerXAnchor),

            filterBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 11),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),

            topDivider.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 11),
            topDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            skeletonView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 4),
            skeletonView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            skeletonView.bottomAnchor.constraint(lessThanOrEqualTo: scrollView.bottomAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30),
        ])
    }

    // MARK: - Skeleton

    private func updateSkeleton() {
        let show = isLoading && allEmails.isEmpty && GmailAuthManager.shared.isAuthenticated()
        guard show != !skeletonView.isHidden else { return }
        skeletonView.isHidden = !show
        if show { skeletonView.startAnimating() } else { skeletonView.stopAnimating() }
    }

    // MARK: - Data & search

    private func setEmails(_ list: [Email]) {
        allEmails = list
        applyFilter()
        updateSkeleton()
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
        focusedRow = -1
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
            if (error as? URLError)?.isOffline == true {
                showStatus("You're offline.\nConnect to the internet to load your inbox.")
            } else {
                showStatus((error as? LocalizedError)?.errorDescription ?? "Couldn't load your inbox.")
            }
        }
        // If we already have cached emails on screen, keep showing them silently.
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
        updateSkeleton()
        // The skeleton already signals the first load; only spin for refreshes
        // when there's existing content on screen.
        let spin = on && !allEmails.isEmpty
        if spin {
            spinner.isHidden = false; spinner.startAnimation(nil)
            refreshButton.isHidden = true
        } else {
            spinner.stopAnimation(nil); spinner.isHidden = true
            refreshButton.isHidden = !GmailAuthManager.shared.isAuthenticated() || on
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

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 72 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = EmailCellView()
        cell.configure(with: emails[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = MailRowView()
        v.isFocused = (row == focusedRow)   // keep keyboard focus visible across scroll/reload
        return v
    }

    // Hand selection to the container, which navigates to the detail view.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < emails.count else { return }
        let email = emails[row]
        tableView.deselectAll(nil)
        markReadLocally(email)
        onSelectEmail?(email)
    }

    // MARK: - Keyboard navigation (driven by RootViewController's key monitor)

    /// Returns true if the key was handled.
    func handleListKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let searching = (searchField.currentEditor() != nil)   // actively typing a query?

        if cmd && chars == "r" { loadEmails(forceRefresh: true); return true }
        if cmd && chars == "f" { focusSearch(); return true }

        // While typing in the search box, only ↓ (into list) and Esc are special.
        if searching {
            switch event.keyCode {
            case 125:   // ↓ : move from search into the list
                view.window?.makeFirstResponder(tableView)
                moveFocus(by: focusedRow < 0 ? 0 : 1)
                if focusedRow < 0 { setFocus(0) }
                return true
            case 53:    // esc : clear, then blur
                if !searchField.stringValue.isEmpty {
                    searchField.stringValue = ""; searchQuery = ""; applyFilter()
                } else {
                    view.window?.makeFirstResponder(tableView)
                }
                return true
            default:
                return false   // let the field handle typing/←→/return
            }
        }

        // List has focus → full navigation.
        switch event.keyCode {
        case 126: moveFocus(by: -1); return true            // ↑
        case 125: moveFocus(by: 1);  return true            // ↓
        case 36, 76: openFocused(); return true             // return / enter
        case 53:                                            // esc → clear search if any
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""; searchQuery = ""; applyFilter(); return true
            }
            return false
        default: break
        }
        if chars == "j" { moveFocus(by: 1);  return true }
        if chars == "k" { moveFocus(by: -1); return true }
        return false
    }

    func focusSearch() { view.window?.makeFirstResponder(searchField) }

    func selectFilter(_ filter: InboxFilter) { filterBar.select(filter) }

    private func moveFocus(by delta: Int) {
        guard !emails.isEmpty else { return }
        let start = focusedRow < 0 ? (delta > 0 ? -1 : emails.count) : focusedRow
        setFocus(max(0, min(emails.count - 1, start + delta)))
        if focusedRow >= 0 { tableView.scrollRowToVisible(focusedRow) }
    }

    private func setFocus(_ row: Int) {
        guard row != focusedRow else { return }
        focusRowView(focusedRow)?.isFocused = false
        focusedRow = row
        focusRowView(row)?.isFocused = true
    }

    private func focusRowView(_ row: Int) -> MailRowView? {
        guard row >= 0, row < emails.count else { return nil }
        return tableView.rowView(atRow: row, makeIfNecessary: false) as? MailRowView
    }

    private func openFocused() {
        guard focusedRow >= 0, focusedRow < emails.count else {
            if !emails.isEmpty { setFocus(0) }
            return
        }
        let email = emails[focusedRow]
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

// MARK: - Row View (hover highlight)

final class MailRowView: NSTableRowView {
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }  // keyboard nav
    override var isEmphasized: Bool { get { false } set {} }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered || isFocused else { return }
        let rect = bounds.insetBy(dx: 7, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let alpha: CGFloat = isFocused ? 0.11 : 0.07
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        path.fill()
    }
}

/// NSTableView that tracks the mouse and highlights the hovered row.
final class HoverTableView: NSTableView {
    private var hoverRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(to: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHover(to: -1)
    }

    private func updateHover(to newRow: Int) {
        guard newRow != hoverRow else { return }
        setHover(hoverRow, false)   // clear previous (may be -1, handled below)
        hoverRow = newRow
        setHover(newRow, true)
    }

    /// `rowView(atRow:)` raises an exception for out-of-range indices (e.g. -1
    /// when the cursor is below the last row), so bounds-check first.
    private func setHover(_ row: Int, _ hovered: Bool) {
        guard row >= 0, row < numberOfRows else { return }
        (rowView(atRow: row, makeIfNecessary: false) as? MailRowView)?.isHovered = hovered
    }
}

// MARK: - Cell

final class EmailCellView: NSView {

    private let avatar = AvatarView()

    // Accent dot in the left gutter for unread messages.
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

    private let attachClip: NSImageView = {
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Has attachment")
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        iv.contentTintColor = .secondaryLabelColor
        iv.isHidden = true
        return iv
    }()

    private let senderLabel  = EmailCellView.label(size: 13,   bold: true)
    private let dateLabel    = EmailCellView.label(size: 11,   color: .secondaryLabelColor)
    private let subjectLabel = EmailCellView.label(size: 12)
    private let snippetLabel = EmailCellView.label(size: 11.5, color: .tertiaryLabelColor)

    private var starWidth: NSLayoutConstraint!
    private var attachWidth: NSLayoutConstraint!

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
        [avatar, unreadDot, senderLabel, starIcon, attachClip, dateLabel, subjectLabel, snippetLabel, separator]
            .forEach { addSubview($0) }
        dateLabel.alignment = .right
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        starWidth   = starIcon.widthAnchor.constraint(equalToConstant: 0)
        attachWidth = attachClip.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            unreadDot.widthAnchor.constraint(equalToConstant: 7),
            unreadDot.heightAnchor.constraint(equalToConstant: 7),
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),

            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            senderLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            senderLabel.trailingAnchor.constraint(equalTo: starIcon.leadingAnchor, constant: -4),

            starWidth,
            starIcon.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            starIcon.trailingAnchor.constraint(equalTo: attachClip.leadingAnchor, constant: -4),

            attachWidth,
            attachClip.centerYAnchor.constraint(equalTo: dateLabel.centerYAnchor),
            attachClip.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -3),

            dateLabel.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 3),
            subjectLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            snippetLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 2),
            snippetLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with email: Email) {
        avatar.configure(email: email.senderEmail,
                         initials: email.initials,
                         color: EmailCellView.avatarColor(for: email.senderEmail))
        senderLabel.stringValue  = email.senderName
        // Bullet sits between the attachment paperclip and the time: "📎 • 5h ago".
        dateLabel.stringValue    = email.hasAttachments ? "• \(email.relativeDate)" : email.relativeDate
        subjectLabel.stringValue = email.subject
        snippetLabel.stringValue = email.snippet
        senderLabel.font = email.isRead ? .systemFont(ofSize: 13, weight: .medium)
                                        : .boldSystemFont(ofSize: 13)
        unreadDot.isHidden  = email.isRead
        starIcon.isHidden   = !email.isStarred
        starWidth.constant  = email.isStarred ? 11 : 0
        attachClip.isHidden  = !email.hasAttachments
        attachWidth.constant = email.hasAttachments ? 13 : 0
    }

    private static func avatarColor(for seed: String) -> NSColor {
        // Curated, slightly-muted palette (white initials read well on all of them).
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.31, green: 0.47, blue: 0.66, alpha: 1),  // blue
            NSColor(srgbRed: 0.35, green: 0.63, blue: 0.39, alpha: 1),  // green
            NSColor(srgbRed: 0.88, green: 0.41, blue: 0.38, alpha: 1),  // coral
            NSColor(srgbRed: 0.61, green: 0.47, blue: 0.71, alpha: 1),  // purple
            NSColor(srgbRed: 0.91, green: 0.59, blue: 0.27, alpha: 1),  // amber
            NSColor(srgbRed: 0.30, green: 0.62, blue: 0.62, alpha: 1),  // teal
            NSColor(srgbRed: 0.62, green: 0.46, blue: 0.38, alpha: 1),  // brown
            NSColor(srgbRed: 0.78, green: 0.40, blue: 0.55, alpha: 1),  // pink
        ]
        // Deterministic (process-stable) hash so a sender keeps the same color.
        let h = seed.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(h) % palette.count]
    }
}

// MARK: - Avatar

final class AvatarView: NSView {

    private let label = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private var currentEmail: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true

        addSubview(label)
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows initials immediately, then swaps in a real avatar if one loads.
    func configure(email: String, initials: String, color: NSColor) {
        currentEmail = email
        label.stringValue = initials
        label.isHidden = false
        imageView.isHidden = true
        imageView.image = nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }

        Task { [weak self] in
            let data = await AvatarProvider.shared.avatarData(for: email)
            guard let self, self.currentEmail == email,
                  let data, let image = NSImage(data: data) else { return }
            self.apply(image)
        }
    }

    private func apply(_ image: NSImage) {
        imageView.image = image
        imageView.isHidden = false
        label.isHidden = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.white.cgColor
        }
    }
}
