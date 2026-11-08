import SwiftUI

@main
struct AimPhoneApp: App {
    @State private var session = RemoteSession()

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environment(session)
                .preferredColorScheme(.dark)
        }
    }
}
