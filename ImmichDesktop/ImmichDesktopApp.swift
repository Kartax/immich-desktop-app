import SwiftUI

@main
struct ImmichDesktopApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 480, minHeight: 340)
        }
        .windowResizability(.contentSize)
    }
}
