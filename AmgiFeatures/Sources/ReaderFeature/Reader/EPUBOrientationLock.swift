#if os(iOS)
import UIKit

/// Sends the reader's temporary orientation lock to the app delegate, which
/// owns the UIKit-supported-orientation callback for the whole application.
enum EPUBOrientationLock {
    static let notificationName = Notification.Name("amgi.epub.orientationLockChanged")

    @MainActor
    static func setLocked(_ locked: Bool) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let orientation = scenes.first?.interfaceOrientation ?? .portrait
        let mask: UIInterfaceOrientationMask
        if !locked {
            mask = .allButUpsideDown
        } else {
            switch orientation {
            case .landscapeLeft: mask = .landscapeLeft
            case .landscapeRight: mask = .landscapeRight
            case .portraitUpsideDown: mask = .portraitUpsideDown
            default: mask = .portrait
            }
        }
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: ["orientationMask": mask.rawValue]
        )
    }

    @MainActor
    static func restoreAppOrientation() {
        let mask: UIInterfaceOrientationMask =
            UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: ["orientationMask": mask.rawValue]
        )
    }
}
#endif
