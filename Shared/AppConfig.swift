import Foundation

/// Shared configuration between the container app and the extension.
///
/// Deliberately NOT via UserDefaults(suiteName:) — that is unreliable for App Groups
/// on macOS (cfprefsd refuses "kCFPreferencesAnyUser with a container"). Instead a
/// JSON file directly in the App Group container that both processes can read.
enum AppConfig {
    static let appGroup = "group.org.kartax.ImmichDesktop"
    // Stable, permanent domain identifier — do NOT version-bump it as a recovery trick.
    // A stuck "signed out" state is cleared by a thorough teardown in DomainManager
    // (remove with .removeAll), not by renaming the identifier.
    static let domainIdentifier = "ImmichDesktop"
    static let domainDisplayName = "ImmichDesktop"   // the label shown in Finder's sidebar

    private struct Stored: Codable {
        var serverURL: String?
        var apiKey: String?
        var configurationVersion: Int?
        var showTimeline: Bool?   // nil → true (default on, so old config files show all views)
        var showPersons: Bool?
        var showPlaces: Bool?
        var showAlbums: Bool?
        var groupLargeFolders: Bool? // nil → true for existing installations
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("config.json")
    }

    private static func load() -> Stored {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored()
        }
        return stored
    }

    private static func store(_ stored: Stored) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static var serverURL: String? {
        get { load().serverURL }
        set { var s = load(); s.serverURL = newValue; store(s) }
    }

    static var apiKey: String? {
        get { load().apiKey }
        set { var s = load(); s.apiKey = newValue; store(s) }
    }

    static var showTimeline: Bool {
        get { load().showTimeline ?? true }
        set { var s = load(); s.showTimeline = newValue; store(s) }
    }

    static var showPersons: Bool {
        get { load().showPersons ?? true }
        set { var s = load(); s.showPersons = newValue; store(s) }
    }

    static var showPlaces: Bool {
        get { load().showPlaces ?? true }
        set { var s = load(); s.showPlaces = newValue; store(s) }
    }

    static var showAlbums: Bool {
        get { load().showAlbums ?? true }
        set { var s = load(); s.showAlbums = newValue; store(s) }
    }

    static var groupLargeFolders: Bool {
        get { load().groupLargeFolders ?? true }
        set { var s = load(); s.groupLargeFolders = newValue; store(s) }
    }

    static var isConfigured: Bool {
        let s = load()
        return !(s.serverURL ?? "").isEmpty && !(s.apiKey ?? "").isEmpty
    }

    /// Reads credentials and their cache generation with one file access.
    static var connection: (serverURL: String, apiKey: String, configurationVersion: Int)? {
        let stored = load()
        guard let serverURL = stored.serverURL, !serverURL.isEmpty,
              let apiKey = stored.apiKey, !apiKey.isEmpty else {
            return nil
        }
        return (serverURL, apiKey, stored.configurationVersion ?? 0)
    }

    /// Set server credentials atomically without touching view-toggle flags.
    static func set(serverURL: String, apiKey: String) {
        var s = load()
        s.serverURL = serverURL
        s.apiKey = apiKey
        s.configurationVersion = (s.configurationVersion ?? 0) &+ 1
        store(s)
    }

    static func flush() { /* file write is already synchronous/atomic */ }
}
