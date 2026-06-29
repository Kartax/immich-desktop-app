import SwiftUI
import AppKit

@main
struct ImmichDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var connection = ConnectionMonitor.shared

    var body: some Scene {
        Window("Immich Desktop", id: SettingsWindow.id) {
            ContentView()
                .frame(width: 480, height: 280)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent()
        } label: {
            // Same symbol as the Finder sidebar icon (FileProviderExt Info.plist
            // CFBundleSymbolName), so the menu bar and Finder match. When the server
            // isn't reachable the icon dims to ~50% — the macOS-standard "inactive"
            // status-item look (cf. NSStatusBarButton.appearsDisabled).
            Image(systemName: "camera.aperture")
                .opacity(connection.status.isConnected ? 1.0 : 0.5)
        }
    }
}

enum SettingsWindow {
    static let id = "settings"
}

/// Contents of the menu bar menu.
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @State private var updates = UpdateChecker.shared

    var body: some View {
        Text("Immich Desktop \(Self.versionString)")
        updateItem
        Divider()
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

    /// Update-check row: state-dependent. When a newer version exists it becomes a
    /// button that opens the download page; otherwise it offers a manual re-check.
    @ViewBuilder
    private var updateItem: some View {
        switch updates.state {
        case .idle:
            Button("Check for Updates…") { Task { await updates.check() } }
        case .checking:
            Text("Checking for updates…")
        case .upToDate:
            Text("You're up to date")
            Button("Check for Updates…") { Task { await updates.check() } }
        case .updateAvailable(let latest):
            Button("New version available (v\(latest))") {
                NSWorkspace.shared.open(UpdateChecker.downloadPageURL)
            }
        case .failed:
            Button("Update check failed — Retry") { Task { await updates.check() } }
        }
    }

    /// Marketing version + build number from the app bundle's Info.plist
    /// (CFBundleShortVersionString / CFBundleVersion, set via MARKETING_VERSION /
    /// CURRENT_PROJECT_VERSION in project.yml).
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (build #\(build))"
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

        // Begin polling server reachability so the menu bar icon reflects it.
        ConnectionMonitor.shared.start()

        // Check for a newer release in the background (report-only, no auto-update).
        Task { await UpdateChecker.shared.check() }
    }
}
