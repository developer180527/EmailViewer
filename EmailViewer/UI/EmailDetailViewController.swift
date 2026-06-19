import AppKit
import WebKit

/// Document view that lays out top-to-bottom (AppKit views are bottom-up by default).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class EmailDetailViewController: NSViewController {

    private let email: Email
    var onBack:    (() -> Void)?
    var onDeleted: (() -> Void)?

    private var attachments: [EmailAttachment] = []

    private lazy var headerView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var backButton: NSButton = {
        let b = NSButton(title: "Inbox", target: self, action: #selector(goBack))
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        let cfg     = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        b.image     = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
                          .withSymbolConfiguration(cfg)
        b.imagePosition    = .imageLeft
        b.font             = .systemFont(ofSize: 13)
        b.contentTintColor = .controlAccentColor
        return b
    }()

    private lazy var trashButton: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!,
                         target: self, action: #selector(deleteEmail))
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Move to Trash"
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.isHidden = true
        return b
    }()

    private lazy var divider: NSBox = {
        let b = NSBox()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.boxType = .separator
        return b
    }()

    private lazy var spinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.style = .spinning; p.controlSize = .small; p.isHidden = true
        return p
    }()

    private lazy var contentContainer: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// Created lazily — ONLY for HTML emails, so plain-text mail spins up no renderer process.
    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }()

    init(email: Email) {
        self.email = email
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 360, height: 500)))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(headerView)
        headerView.addSubview(backButton)
        headerView.addSubview(trashButton)
        headerView.addSubview(spinner)
        view.addSubview(divider)
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),

            backButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            backButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 6),

            trashButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            trashButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -10),
            trashButton.widthAnchor.constraint(equalToConstant: 28),
            trashButton.heightAnchor.constraint(equalToConstant: 28),

            spinner.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),

            divider.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        loadEmail()
    }

    private func loadEmail() {
        spinner.isHidden = false
        spinner.startAnimation(nil)
        trashButton.isHidden = true

        Task {
            do {
                let content = try await GmailFetcher.shared.content(for: email.id)
                await MainActor.run {
                    self.attachments = content.attachments
                    self.stopSpinner()
                    self.render(content)
                }
            } catch {
                await MainActor.run {
                    self.stopSpinner()
                    if (error as? URLError)?.isOffline == true {
                        self.installMessage(symbol: "wifi.slash",
                                            "You're offline.\nThis email hasn't been downloaded yet.")
                    } else {
                        let message = (error as? LocalizedError)?.errorDescription ?? "Could not load this email."
                        self.installMessage(symbol: "exclamationmark.triangle", message)
                    }
                }
            }
        }
    }

    /// Rich HTML → WebView. Plain text (or trivial HTML that adds no formatting)
    /// → native rendering, so no WKWebView/renderer process is created.
    private func render(_ content: EmailContent) {
        if let html = content.body.html, !html.isEmpty, Self.isRichHTML(html) {
            installWebView()
            webView.loadHTMLString(htmlDocument(html: html, attachments: content.attachments), baseURL: nil)
        } else {
            let text = content.body.plainText
                ?? content.body.html.map(Self.strippedText)
                ?? "This message has no content."
            installPlainView(text: text, attachments: content.attachments)
        }
    }

    /// True only when the HTML carries real formatting/structure worth a WebView.
    /// Gmail wraps even plain typed text as `<div dir="ltr">…</div>` (multipart
    /// alternative), which must NOT trigger the WebView.
    nonisolated private static func isRichHTML(_ html: String) -> Bool {
        let h = html.lowercased()
        let markers = ["<img", "<table", "<a ", "href=", "<ul", "<ol",
                       "<h1", "<h2", "<h3", "<h4", "<h5", "<h6", "<blockquote",
                       "<style", "style=", "<hr", "<font", "bgcolor", "background",
                       "<b>", "<strong", "<em", "<i>", "<u>", "<button", "<svg", "<video"]
        return markers.contains { h.contains($0) }
    }

    nonisolated private static func strippedText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s.htmlUnescaped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text → attributed string with clickable links/emails found by
    /// NSDataDetector. A selectable NSTextField opens `.link` attributes in the
    /// browser (or mail client for mailto:) on click — no extra handling needed.
    private static func linkified(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        let full = NSRange(location: 0, length: (text as NSString).length)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let url = match?.url, let range = match?.range else { return }
                result.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: range)
            }
        }
        return result
    }

    private func stopSpinner() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        trashButton.isHidden = false
    }

    @objc private func goBack() { onBack?() }

    // MARK: - Delete (move to Trash)

    @objc private func deleteEmail() {
        trashButton.isEnabled = false
        Task {
            do {
                try await GmailFetcher.shared.trash(email.id)
                NotificationCenter.default.post(name: .inboxDidUpdate, object: nil)
                await MainActor.run { (self.onDeleted ?? self.onBack)?() }
            } catch {
                await MainActor.run {
                    self.trashButton.isEnabled = true
                    self.presentDeleteError(error)
                }
            }
        }
    }

    private func presentDeleteError(_ error: Error) {
        let needsReauth = (error as? GmailFetcher.GmailError)?.requiresReauth == true
        let alert = NSAlert()
        alert.messageText = "Couldn't delete email"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        if needsReauth { alert.addButton(withTitle: "Reconnect") }
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        if needsReauth, alert.runModal() == .alertFirstButtonReturn {
            Task { try? await GmailAuthManager.shared.startOAuthFlow() }
        }
    }

    // MARK: - Content installation

    private func installWebView() {
        contentContainer.addSubview(webView)
        pin(webView, to: contentContainer)
    }

    private func installMessage(symbol: String? = nil, _ text: String) {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12

        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let iv = NSImageView()
            iv.image = image
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
            iv.contentTintColor = .tertiaryLabelColor
            stack.addArrangedSubview(iv)
        }
        let label = wrapLabel(text, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        label.alignment = .center
        stack.addArrangedSubview(label)

        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -24),
        ])
    }

    /// Native plain-text rendering: subject, meta, body, and attachment chips in a
    /// scrolling stack — no WKWebView, so no renderer process.
    private func installPlainView(text: String, attachments: [EmailAttachment]) {
        let pad: CGFloat = 16
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        let subject = wrapLabel(email.subject, font: .boldSystemFont(ofSize: 15), color: .labelColor)
        let meta    = wrapLabel("\(email.senderName) · \(email.relativeDate)",
                                font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        let body = wrapLabel("", font: .systemFont(ofSize: 13), color: .labelColor)
        body.isSelectable = true   // required for link clicks
        body.attributedStringValue = Self.linkified(text.isEmpty ? "This message has no content." : text)

        [subject, meta, sep, body].forEach { doc.addSubview($0) }

        NSLayoutConstraint.activate([
            subject.topAnchor.constraint(equalTo: doc.topAnchor, constant: pad),
            subject.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: pad),
            subject.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -pad),

            meta.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 4),
            meta.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: pad),
            meta.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -pad),

            sep.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: pad),
            sep.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -pad),

            body.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: pad),
            body.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -pad),
        ])

        var lastBottom = body.bottomAnchor
        if !attachments.isEmpty {
            let title = wrapLabel("ATTACHMENTS", font: .systemFont(ofSize: 10, weight: .semibold),
                                  color: .secondaryLabelColor)
            doc.addSubview(title)
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: lastBottom, constant: 20),
                title.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: pad),
                title.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -pad),
            ])
            lastBottom = title.bottomAnchor

            for (index, att) in attachments.enumerated() {
                let chip = attachmentChip(att, index: index)
                doc.addSubview(chip)
                NSLayoutConstraint.activate([
                    chip.topAnchor.constraint(equalTo: lastBottom, constant: 8),
                    chip.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: pad),
                    chip.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -pad),
                ])
                lastBottom = chip.bottomAnchor
            }
        }
        doc.bottomAnchor.constraint(equalTo: lastBottom, constant: pad).isActive = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = doc

        contentContainer.addSubview(scroll)
        pin(scroll, to: contentContainer)
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
    }

    // MARK: - Attachments

    /// Inert chip (paperclip + name) plus a dedicated download icon — only the
    /// icon triggers the save; clicking the chip body does nothing.
    private func attachmentChip(_ att: EmailAttachment, index: Int) -> NSView {
        let clip = NSImageView()
        clip.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        clip.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        clip.contentTintColor = .secondaryLabelColor
        clip.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "\(att.filename)  ·  \(att.displaySize)")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let download = NSButton(image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Download")!,
                                target: self, action: #selector(downloadAttachmentButton(_:)))
        download.translatesAutoresizingMaskIntoConstraints = false
        download.isBordered = false
        download.bezelStyle = .texturedRounded
        download.contentTintColor = .controlAccentColor
        download.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        download.tag = index
        download.toolTip = "Download \(att.filename)"
        download.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [clip, label, download])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 8
        stack.layer?.borderWidth = 0.5
        stack.effectiveAppearance.performAsCurrentDrawingAppearance {
            stack.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        return stack
    }

    @objc private func downloadAttachmentButton(_ sender: NSButton) {
        downloadAttachment(at: sender.tag)
    }

    private func downloadAttachment(at index: Int) {
        guard index >= 0, index < attachments.count else { return }
        let att = attachments[index]
        Task {
            let data = await GmailFetcher.shared.attachmentData(emailID: email.id, attachmentId: att.id)
            await MainActor.run {
                guard let data else { return }
                self.saveAttachment(data, suggestedName: att.filename)
            }
        }
    }

    private func saveAttachment(_ data: Data, suggestedName: String) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Helpers

    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    private func wrapLabel(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: string)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = font
        l.textColor = color
        l.isSelectable = false
        l.drawsBackground = false
        return l
    }

    // MARK: - HTML rendering (HTML emails only)

    private func htmlDocument(html: String, attachments: [EmailAttachment]) -> String {
        page(content: html + attachmentsHTML(attachments))
    }

    private func attachmentsHTML(_ attachments: [EmailAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        var section = "<div class='attachments'><div class='att-title'>Attachments</div>"
        for (i, att) in attachments.enumerated() {
            // The chip itself isn't a link; only the ↓ icon downloads.
            section += "<span class='att'>📎 <span class='att-name'>\(att.filename.htmlEscaped)</span> "
                     + "<span class='att-size'>· \(att.displaySize)</span>"
                     + "<a class='att-dl' href='attachment://download/\(i)' title='Download'>&#8595;</a></span>"
        }
        return section + "</div>"
    }

    private func page(content: String) -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg     = isDark ? "#1e1e1e" : "#ffffff"
        let text   = isDark ? "#e0e0e0" : "#1a1a1a"
        let sub    = isDark ? "#ffffff" : "#000000"
        let meta   = isDark ? "#999999" : "#666666"
        let border = isDark ? "#333333" : "#eeeeee"
        let chip   = isDark ? "#2b2b2b" : "#f3f3f3"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset='utf-8'>
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>
          html { -webkit-text-size-adjust: 100%; }
          body { background:\(bg); color:\(text);
                 font-family:-apple-system,sans-serif;
                 font-size:13px; line-height:1.6; padding:16px;
                 margin:0; word-wrap:break-word; overflow-wrap:break-word; }
          .subject { font-size:15px; font-weight:700; color:\(sub); margin-bottom:4px; }
          .meta    { font-size:11px; color:\(meta); margin-bottom:14px;
                     padding-bottom:12px; border-bottom:1px solid \(border); }
          img      { max-width:100%; height:auto; }
          table    { max-width:100%; }
          pre      { white-space:pre-wrap; }
          a        { color:#0a84ff; }
          .attachments { margin-top:22px; padding-top:14px; border-top:1px solid \(border); }
          .att-title { font-size:10px; font-weight:700; color:\(meta);
                       text-transform:uppercase; letter-spacing:0.05em; margin-bottom:8px; }
          .att { display:inline-flex; align-items:center; background:\(chip); color:\(text);
                 padding:6px 6px 6px 11px; border-radius:8px;
                 border:1px solid \(border); margin:0 6px 6px 0; font-size:12px; }
          .att-size { color:\(meta); margin:0 4px; }
          .att-dl { display:inline-flex; align-items:center; justify-content:center;
                    width:22px; height:22px; border-radius:50%; text-decoration:none;
                    color:#0a84ff; background:rgba(10,132,255,0.14);
                    font-size:14px; font-weight:700; line-height:1; }
        </style>
        </head>
        <body>
          <div class='subject'>\(email.subject.htmlEscaped)</div>
          <div class='meta'><b>\(email.senderName.htmlEscaped)</b> · \(email.relativeDate)</div>
          \(content)
        </body>
        </html>
        """
    }
}

// MARK: - Navigation: attachment downloads + external links

extension EmailDetailViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            if url.scheme == "attachment" {
                if let last = url.pathComponents.last, let index = Int(last) {
                    downloadAttachment(at: index)
                }
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}

private extension String {
    /// Escapes the five characters that are unsafe to interpolate into HTML.
    var htmlEscaped: String {
        var s = replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        s = s.replacingOccurrences(of: "'", with: "&#39;")
        return s
    }
}
