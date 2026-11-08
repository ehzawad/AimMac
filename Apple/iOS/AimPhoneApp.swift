import SwiftUI

@main
struct AimPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @State private var session = RemoteSession()

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environment(session)
                .preferredColorScheme(.dark)
        }
    }
}
