import Foundation

/// Shared configuration between the container app and the extension.
///
/// Deliberately NOT via UserDefaults(suiteName:) — that is unreliable for App Groups
/// on macOS (cfprefsd refuses "kCFPreferencesAnyUser with a container"). Instead a
/// JSON file directly in the App Group container that both processes can read.
enum AppConfig {
    enum FolderGroupingMode: String, Codable, CaseIterable {
        case never
        case atLeast500
        case always
    }

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
        var groupLargeFolders: Bool? // Legacy fallback for per-view grouping modes.
        var albumGroupingMode: FolderGroupingMode?
        var personGroupingMode: FolderGroupingMode?
        var placeGroupingMode: FolderGroupingMode?
        var groupingMigrationPending: Bool?
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

    static var albumGroupingMode: FolderGroupingMode {
        get {
            let s = load()
            return groupingMode(s.albumGroupingMode, legacyEnabled: s.groupLargeFolders)
        }
        set { setGroupingMode(newValue, at: \.albumGroupingMode) }
    }

    static var personGroupingMode: FolderGroupingMode {
        get {
            let s = load()
            return groupingMode(s.personGroupingMode, legacyEnabled: s.groupLargeFolders)
        }
        set { setGroupingMode(newValue, at: \.personGroupingMode) }
    }

    static var placeGroupingMode: FolderGroupingMode {
        get {
            let s = load()
            return groupingMode(s.placeGroupingMode, legacyEnabled: s.groupLargeFolders)
        }
        set { setGroupingMode(newValue, at: \.placeGroupingMode) }
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
        _ = materializeGroupingModes(in: &s)
        s.configurationVersion = (s.configurationVersion ?? 0) &+ 1
        store(s)
    }

    /// Persists legacy grouping behavior as the three independent modes. A pending
    /// reset remains recorded until Finder's domain has been rebuilt successfully.
    static func migrateGroupingModesIfNeeded() -> Bool {
        var s = load()
        guard !(s.serverURL ?? "").isEmpty, !(s.apiKey ?? "").isEmpty else {
            return false
        }

        let materialized = materializeGroupingModes(in: &s)
        if materialized {
            // Legacy false already produced a flat hierarchy, so persisting three
            // .never modes does not require throwing away Finder's backing store.
            if s.groupLargeFolders ?? true {
                s.configurationVersion = (s.configurationVersion ?? 0) &+ 1
                s.groupingMigrationPending = true
            }
            store(s)
        }
        return s.groupingMigrationPending ?? false
    }

    static func completeGroupingModeMigration() {
        var s = load()
        guard s.groupingMigrationPending == true else { return }
        s.groupingMigrationPending = false
        store(s)
    }

    private static func groupingMode(
        _ storedMode: FolderGroupingMode?,
        legacyEnabled: Bool?
    ) -> FolderGroupingMode {
        storedMode ?? ((legacyEnabled ?? true) ? .atLeast500 : .never)
    }

    private static func setGroupingMode(
        _ newValue: FolderGroupingMode,
        at keyPath: WritableKeyPath<Stored, FolderGroupingMode?>
    ) {
        var s = load()
        let current = groupingMode(s[keyPath: keyPath], legacyEnabled: s.groupLargeFolders)
        guard current != newValue else { return }
        s[keyPath: keyPath] = newValue
        // Grouping changes parent/child identifiers throughout the virtual tree.
        s.configurationVersion = (s.configurationVersion ?? 0) &+ 1
        store(s)
    }

    private static func materializeGroupingModes(in stored: inout Stored) -> Bool {
        let fallback = groupingMode(nil, legacyEnabled: stored.groupLargeFolders)
        var changed = false
        if stored.albumGroupingMode == nil {
            stored.albumGroupingMode = fallback
            changed = true
        }
        if stored.personGroupingMode == nil {
            stored.personGroupingMode = fallback
            changed = true
        }
        if stored.placeGroupingMode == nil {
            stored.placeGroupingMode = fallback
            changed = true
        }
        return changed
    }

    static func flush() { /* file write is already synchronous/atomic */ }
}
