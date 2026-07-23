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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var galleryWindow: NSWindow?

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

        // Begin polling server reachability and checking for newer releases, then
        // reflect both states on the status item.
        ConnectionMonitor.shared.start()
        UpdateChecker.shared.start()
        trackStatusState()
    }

    /// Keep the app alive when the settings window is closed (it's a menu bar app).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self          // rebuilt on open (menuNeedsUpdate)
        item.menu = menu
        statusItem = item
        updateIconState()
    }

    /// Dim the icon when disconnected and append a small update marker when needed.
    @MainActor private func updateIconState() {
        guard let button = statusItem?.button else { return }
        button.appearsDisabled = !ConnectionMonitor.shared.status.isConnected

        if case .updateAvailable(let latest) = UpdateChecker.shared.state {
            button.title = "!"
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize,
                                            weight: .bold)
            button.toolTip = "Immich Desktop v\(latest) is available"
        } else {
            button.title = ""
            button.toolTip = nil
        }
    }

    /// Observe connection and update state, then re-apply the status item on each change.
    /// Re-arms itself because `withObservationTracking` fires `onChange` only once.
    @MainActor private func trackStatusState() {
        withObservationTracking {
            updateIconState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackStatusState() }
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
        // Always enabled — the gallery itself renders a "not configured" state.
        let gallery = menu.addItem(withTitle: "View Gallery", action: #selector(openGallery),
                                   keyEquivalent: "")
        gallery.target = self
        gallery.image = Self.icon    // same symbol as tray + Finder sidebar
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

    @objc private func openGallery() { showGallery() }

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
                .frame(width: 500, height: 600)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "Immich Desktop"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Gallery window (AppKit-hosted SwiftUI)

    @MainActor private func showGallery() {
        NSApp.activate(ignoringOtherApps: true)
        if galleryWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: GalleryView()))
            window.title = "Immich Desktop"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.contentMinSize = NSSize(width: 640, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            // Unlike the settings window, this one is discarded on close (see
            // windowWillClose): frees the asset list + thumbnail cache and gives a
            // fresh timeline on reopen.
            window.delegate = self
            galleryWindow = window
        }
        galleryWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === galleryWindow {
            galleryWindow = nil
        }
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
