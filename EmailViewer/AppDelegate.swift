import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    var popover:    NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 launched")
        setupStatusItem()
        setupPopover()
    }

    // Called when Google redirects back after OAuth (legacy custom-scheme path;
    // the primary flow completes inside ASWebAuthenticationSession).
    func application(_ application: NSApplication, open urls: [URL]) {
        print("📲 Received URL: \(urls.first?.absoluteString ?? "none")")
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

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: "Mail")
        image?.isTemplate = true
        statusItem.button?.image  = image
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        print("✅ status item ready")
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = RootViewController.contentSize
        popover.behavior    = .transient
        popover.animates    = true
        popover.contentViewController = RootViewController()
        print("✅ popover ready")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
