import AppKit
import WebKit

final class EmailDetailViewController: NSViewController {

    private let email:    Email
    var onBack: (() -> Void)?

    private lazy var headerView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        // No custom background — let the popover material show through so it
        // stays consistent in both light and dark mode.
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
        // Don't persist cookies/storage from email content; treat each render as throwaway.
        config.websiteDataStore = .nonPersistent()
        // Email bodies must not run scripts.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")  // transparent so our CSS bg shows
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

            spinner.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),

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

        Task {
            do {
                let body = try await GmailFetcher.shared.body(for: email.id)
                await MainActor.run {
                    self.stopSpinner()
                    self.webView.loadHTMLString(self.htmlDocument(for: body), baseURL: nil)
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
    }

    @objc private func goBack() { onBack?() }

    // MARK: - HTML rendering

    private func htmlDocument(for body: EmailBody) -> String {
        let content: String
        if let html = body.html, !html.isEmpty {
            content = html
        } else if let text = body.plainText, !text.isEmpty {
            content = "<pre class='plain'>\(text.htmlEscaped)</pre>"
        } else {
            content = "<p class='empty'>This message has no content.</p>"
        }
        return page(content: content)
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

// MARK: - Navigation: open links externally, keep email content sandboxed

extension EmailDetailViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // A clicked link should open in the user's browser, not navigate inside the popover.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
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
