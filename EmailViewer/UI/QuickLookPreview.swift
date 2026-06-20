import AppKit
import Quartz

/// Previews an attachment's bytes (PDF / image / document) in a standalone
/// Quick Look window — owned here so it survives the transient popover closing.
final class QuickLookPreview {

    static let shared = QuickLookPreview()
    private init() {}

    private var window: NSWindow?

    func show(data: Data, filename: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(filename.isEmpty ? "attachment" : filename)
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }

        guard let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 680, height: 760), style: .normal) else { return }
        preview.autoresizingMask = [.width, .height]
        preview.previewItem = fileURL as NSURL

        let win = window ?? makeWindow()
        win.title = filename
        win.contentView = preview
        if win.isVisible == false { win.center() }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 360, height: 360)
        return w
    }
}
