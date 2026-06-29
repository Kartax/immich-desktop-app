import SwiftUI
import AppKit

@main
struct ImmichDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Immich Desktop", id: SettingsWindow.id) {
            ContentView()
                .frame(width: 480, height: 280)
        }
        .windowResizability(.contentSize)

        // Same symbol as the Finder sidebar icon (FileProviderExt Info.plist
        // CFBundleSymbolName), so the menu bar and Finder match.
        MenuBarExtra("Immich Desktop", systemImage: "camera.aperture") {
            MenuBarContent()
        }
    }
}

enum SettingsWindow {
    static let id = "settings"
}

/// Contents of the menu bar menu.
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SettingsWindow.id)
        }
        Divider()
        Button("Quit Immich Desktop") {
            // Remove the Finder integration, then quit, so "quit" really means off.
            Task {
                await DomainManager.deactivate()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring the app to the front on launch so the settings window is usable
        // (the app runs as a menu bar program without a Dock icon).
        NSApp.activate(ignoringOtherApps: true)

        // Re-mount Immich in Finder automatically if it has been configured before,
        // so launching the app brings the integration back without re-activating.
        if AppConfig.isConfigured {
            Task { try? await DomainManager.activate(reset: false) }
        }
    }
}
