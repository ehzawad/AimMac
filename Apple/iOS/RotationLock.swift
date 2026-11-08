import UIKit

/// Holds the interface in one orientation, without the phone's own rotation lock.
@MainActor
enum RotationLock {
    /// What the app delegate reports to the system.
    private(set) static var allowed: UIInterfaceOrientationMask = .allButUpsideDown

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    /// Locks to the orientation on screen now, or back to following the phone.
    static func set(locked: Bool) {
        guard let scene else { return }
        if locked {
            switch scene.effectiveGeometry.interfaceOrientation {
            case .landscapeLeft: allowed = .landscapeLeft
            case .landscapeRight: allowed = .landscapeRight
            default: allowed = .portrait
            }
        } else {
            allowed = .allButUpsideDown
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: allowed)) { error in
            NSLog("Orbit Pointer: could not change rotation: \(error)")
        }
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        RotationLock.allowed
    }
}
