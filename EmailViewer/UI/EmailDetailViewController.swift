import AppKit
import WebKit

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
        view.addSubview(webView)

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

            webView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
                    self.webView.loadHTMLString(self.htmlDocument(for: content), baseURL: nil)
                }
            } catch {
                await MainActor.run {
                    self.stopSpinner()
                    self.webView.loadHTMLString(self.errorDocument(for: error), baseURL: nil)
                }
            }
        }
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

    // MARK: - Attachments (downloaded via an `attachment://download/<index>` link)

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

    // MARK: - HTML rendering

    private func htmlDocument(for content: EmailContent) -> String {
        let bodyHTML: String
        if let html = content.body.html, !html.isEmpty {
            bodyHTML = html
        } else if let text = content.body.plainText, !text.isEmpty {
            bodyHTML = "<pre class='plain'>\(text.htmlEscaped)</pre>"
        } else {
            bodyHTML = "<p class='empty'>This message has no content.</p>"
        }
        return page(content: bodyHTML + attachmentsHTML(content.attachments))
    }

    private func attachmentsHTML(_ attachments: [EmailAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        var section = "<div class='attachments'><div class='att-title'>Attachments</div>"
        for (i, att) in attachments.enumerated() {
            section += "<a class='att' href='attachment://download/\(i)'>"
                     + "📎 \(att.filename.htmlEscaped) <span class='att-size'>· \(att.displaySize)</span></a>"
        }
        return section + "</div>"
    }

    private func errorDocument(for error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? "Could not load this email."
        return page(content: "<p class='empty'>\(message.htmlEscaped)</p>")
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
          .empty   { color:\(meta); }
          .plain   { white-space:pre-wrap; font-family:-apple-system,sans-serif; margin:0; }
          img      { max-width:100%; height:auto; }
          table    { max-width:100%; }
          pre      { white-space:pre-wrap; }
          a        { color:#0a84ff; }
          .attachments { margin-top:22px; padding-top:14px; border-top:1px solid \(border); }
          .att-title { font-size:10px; font-weight:700; color:\(meta);
                       text-transform:uppercase; letter-spacing:0.05em; margin-bottom:8px; }
          .att { display:inline-flex; align-items:center; background:\(chip); color:\(text);
                 text-decoration:none; padding:7px 11px; border-radius:8px;
                 border:1px solid \(border); margin:0 6px 6px 0; font-size:12px; }
          .att-size { color:\(meta); margin-left:4px; }
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
            // Our in-email attachment links: attachment://download/<index>
            if url.scheme == "attachment" {
                if let last = url.pathComponents.last, let index = Int(last) {
                    downloadAttachment(at: index)
                }
                decisionHandler(.cancel)
                return
            }
            // Real link clicks open in the browser, not inside the popover.
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
