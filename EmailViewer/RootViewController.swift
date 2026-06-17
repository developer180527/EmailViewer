import AppKit

/// Stable container for the popover. It owns the inbox list and swaps child
/// views in place (list ⇆ detail) instead of reassigning the popover's
/// `contentViewController`. This keeps the popover a constant size and keeps
/// both child controllers alive, so the "‹ Inbox" back button works.
final class RootViewController: NSViewController {

    static let contentSize = NSSize(width: 440, height: 600)

    private let listVC = MailViewController()
    private weak var currentChild: NSViewController?

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        listVC.onSelectEmail = { [weak self] email in
            self?.pushDetail(for: email)
        }
        show(listVC)
    }

    // MARK: - Navigation

    private func pushDetail(for email: Email) {
        let detail = EmailDetailViewController(email: email)
        detail.onBack = { [weak self] in self?.popToList() }
        show(detail)
    }

    func popToList() { show(listVC) }

    /// Called after a successful sign-in to refresh the inbox.
    func handleSignInCompleted() {
        popToList()
        listVC.updateUI()
        listVC.loadEmails(forceRefresh: true)
    }

    // MARK: - Child swapping

    private func show(_ child: NSViewController) {
        guard currentChild !== child else { return }

        currentChild?.view.removeFromSuperview()
        currentChild?.removeFromParent()

        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.width, .height]
        view.addSubview(child.view)
        currentChild = child
    }
}
