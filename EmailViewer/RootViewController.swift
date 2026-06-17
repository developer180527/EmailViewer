import AppKit

/// Stable container for the popover. It owns the inbox list and swaps child
/// views in place (list ⇆ detail) above a persistent bottom toolbar. Swapping
/// views (rather than the popover's `contentViewController`) keeps the popover a
/// constant size and keeps both child controllers alive.
final class RootViewController: NSViewController {

    static let contentSize = NSSize(width: 440, height: 600)
    private static let toolbarHeight: CGFloat = 26

    private let listVC = MailViewController()
    private weak var currentChild: NSViewController?

    private let contentContainer = NSView()

    private lazy var toolbar: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var settingsButton = Self.toolButton(symbol: "gearshape",
                                                      tooltip: "Settings",
                                                      action: #selector(openSettings))
    private lazy var quitButton = Self.toolButton(symbol: "power",
                                                  tooltip: "Quit EmailViewer",
                                                  action: #selector(quit))

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()

        listVC.onSelectEmail = { [weak self] email in self?.pushDetail(for: email) }
        show(listVC)
    }

    // MARK: - Layout

    private func buildLayout() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)
        view.addSubview(toolbar)

        let topDivider = NSBox()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topDivider.boxType = .separator

        settingsButton.target = self
        quitButton.target = self
        [settingsButton, quitButton, topDivider].forEach { toolbar.addSubview($0) }

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            topDivider.topAnchor.constraint(equalTo: toolbar.topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),

            // Both on the far right: power at the edge, settings to its left.
            quitButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            quitButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            quitButton.widthAnchor.constraint(equalToConstant: 18),
            quitButton.heightAnchor.constraint(equalToConstant: 18),

            settingsButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -4),
            settingsButton.widthAnchor.constraint(equalToConstant: 18),
            settingsButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    // MARK: - Navigation

    private func pushDetail(for email: Email) {
        let detail = EmailDetailViewController(email: email)
        detail.onBack = { [weak self] in self?.popToList() }
        show(detail)
    }

    func popToList() { show(listVC) }

    func handleSignInCompleted() {
        popToList()
        listVC.updateUI()
        listVC.loadEmails(forceRefresh: true)
    }

    private func show(_ child: NSViewController) {
        guard currentChild !== child else { return }
        currentChild?.view.removeFromSuperview()
        currentChild?.removeFromParent()

        addChild(child)
        child.view.frame = contentContainer.bounds
        child.view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(child.view)
        currentChild = child
    }

    // MARK: - Toolbar actions

    @objc private func openSettings() {
        // The transient popover closes itself once the settings window takes focus.
        SettingsWindowController.shared.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private static func toolButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let b = NSButton(image: image ?? NSImage(), target: nil, action: action)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tooltip
        b.imageScaling = .scaleProportionallyUpOrDown
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        return b
    }
}
