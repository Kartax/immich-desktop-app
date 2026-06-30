import SwiftUI
import AppKit
import Observation

@main
struct ImmichDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives entirely in the AppKit status item (see AppDelegate); this app
        // has no normal window. A `Settings` scene satisfies the `App` protocol without
        // showing anything (the app is LSUIElement, so it's never surfaced).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    // Menu bar icon — same SF Symbol as the Finder sidebar (FileProviderExt Info.plist
    // CFBundleSymbolName), so menu bar and Finder match. A template image so the system
    // tints it for light/dark menu bars; dimming when disconnected is done with the
    // button's `appearsDisabled`, the standard "inactive status item" mechanism.
    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "camera.aperture",
                            accessibilityDescription: "Immich Desktop")
        image?.isTemplate = true
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // Re-mount Immich in Finder automatically if it has been configured before,
        // so launching the app brings the integration back without re-activating.
        if AppConfig.isConfigured {
            Task { try? await DomainManager.activate(reset: false) }
        } else {
            // Nothing set up yet — bring the settings window up so the app is usable.
            showSettings()
        }

        // Begin polling server reachability and reflect it on the icon.
        ConnectionMonitor.shared.start()
        trackConnection()

        // Check for a newer release now and once a day (report-only, no auto-update).
        UpdateChecker.shared.start()
    }

    /// Keep the app alive when the settings window is closed (it's a menu bar app).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon
        let menu = NSMenu()
        menu.delegate = self          // rebuilt on open (menuNeedsUpdate)
        item.menu = menu
        statusItem = item
        updateIconState()
    }

    /// Dim the icon (standard "inactive" look) whenever the server isn't reachable.
    @MainActor private func updateIconState() {
        statusItem?.button?.appearsDisabled = !ConnectionMonitor.shared.status.isConnected
    }

    /// Observe `ConnectionMonitor.status` and re-apply the icon state on every change.
    /// Re-arms itself because `withObservationTracking` fires `onChange` only once.
    @MainActor private func trackConnection() {
        withObservationTracking {
            updateIconState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackConnection() }
        }
    }

    // MARK: - Menu (rebuilt each time it opens, so the update state is current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let version = menu.addItem(withTitle: "Immich Desktop \(Self.versionString)",
                                   action: nil, keyEquivalent: "")
        version.isEnabled = false

        addUpdateItems(to: menu)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Settings…", action: #selector(openSettings), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Immich Desktop", action: #selector(quit), keyEquivalent: "")
            .target = self
    }

    /// State-dependent update row. Report-only and runs in the background, so transient
    /// states (idle/checking/failed) show nothing — nobody happens to have the menu open
    /// for those. Only the settled, meaningful outcomes get a row.
    private func addUpdateItems(to menu: NSMenu) {
        switch UpdateChecker.shared.state {
        case .upToDate:
            menu.addItem(withTitle: "You're up to date", action: nil, keyEquivalent: "")
                .isEnabled = false
        case .updateAvailable(let latest):
            menu.addItem(withTitle: "New version available (v\(latest))",
                         action: #selector(openDownloadPage), keyEquivalent: "").target = self
        case .idle, .checking, .failed:
            break
        }
    }

    // MARK: - Menu actions

    @objc private func openSettings() { showSettings() }

    @objc private func openDownloadPage() { NSWorkspace.shared.open(UpdateChecker.downloadPageURL) }

    @objc private func quit() {
        // Remove the Finder integration, then quit, so "quit" really means off.
        Task {
            await DomainManager.deactivate()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Settings window (AppKit-hosted SwiftUI)

    @MainActor private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let content = ContentView(onClose: { [weak self] in self?.settingsWindow?.close() })
                .frame(width: 480, height: 500)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "Immich Desktop"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Version

    /// Marketing version + build number (CFBundleShortVersionString / CFBundleVersion,
    /// set via MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml).
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }
}
