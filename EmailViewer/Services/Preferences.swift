import Foundation

/// Small UserDefaults-backed preferences (per macOS user automatically).
enum Preferences {

    private static let blockRemoteImagesKey = "blockRemoteImages"

    /// Block remote images in HTML emails (blocks tracking pixels). Default on.
    static var blockRemoteImages: Bool {
        get { UserDefaults.standard.object(forKey: blockRemoteImagesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: blockRemoteImagesKey) }
    }
}
