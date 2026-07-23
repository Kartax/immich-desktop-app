import FileProvider
import Foundation

/// Persistent metadata snapshots shared by folder enumeration, item lookup and
/// change enumeration. Files live in the App Group container so a short-lived
/// File Provider process can still answer warm requests without another API call.
actor AssetMetadataCache {
    static let shared = AssetMetadataCache()

    struct CachedSnapshot {
        let generation: String
        let createdAt: Date
        let assets: [ImmichAsset]
    }

    struct CachedUpdate {
        let parent: NSFileProviderItemIdentifier
        let asset: ImmichAsset
    }

    struct ChangeBatch {
        let updates: [CachedUpdate]
        let deletedIdentifiers: [NSFileProviderItemIdentifier]
        let anchor: Int64
        let moreComing: Bool
        let anchorExpired: Bool
    }

    private struct StoredSnapshot: Codable {
        let schemaVersion: Int
        let configurationVersion: Int
        let containerRawValue: String
        let generation: String
        let createdAt: Date
        var assets: [ImmichAsset]
    }

    private struct StoredDraft: Codable {
        let schemaVersion: Int
        let configurationVersion: Int
        let containerRawValue: String
        let generation: String
        var assets: [ImmichAsset]
    }

    private struct StoredChange: Codable {
        let sequence: Int64
        let parentRawValue: String
        let updatedAsset: ImmichAsset?
        let deletedIdentifierRawValue: String?
    }

    private struct StoredChangeState: Codable {
        let schemaVersion: Int
        let configurationVersion: Int
        var lastSequence: Int64
        var minimumAvailableSequence: Int64
        var changes: [StoredChange]
    }

    private static let schemaVersion = 1
    private static let maximumStoredChanges = 200_000
    private static let retainedChangesAfterCompaction = 100_000

    private let cacheDirectory: URL?
    private var snapshots: [String: StoredSnapshot] = [:]
    private var snapshotIndexes: [String: [String: ImmichAsset]] = [:]
    private var drafts: [String: StoredDraft] = [:]
    private var changeState: StoredChangeState?

    private init() {
        cacheDirectory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroup)?
            .appendingPathComponent("file-provider-metadata-v1", isDirectory: true)
        if let cacheDirectory {
            try? FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    func freshSnapshot(
        for container: NSFileProviderItemIdentifier,
        configurationVersion: Int,
        maximumAge: TimeInterval
    ) -> CachedSnapshot? {
        guard let snapshot = loadSnapshot(
            for: container.rawValue, configurationVersion: configurationVersion),
              Date().timeIntervalSince(snapshot.createdAt) <= maximumAge else {
            return nil
        }
        return CachedSnapshot(generation: snapshot.generation,
                              createdAt: snapshot.createdAt,
                              assets: snapshot.assets)
    }

    func snapshot(
        for container: NSFileProviderItemIdentifier,
        generation: String,
        configurationVersion: Int
    ) -> CachedSnapshot? {
        guard let snapshot = loadSnapshot(
            for: container.rawValue, configurationVersion: configurationVersion),
              snapshot.generation == generation else {
            return nil
        }
        return CachedSnapshot(generation: snapshot.generation,
                              createdAt: snapshot.createdAt,
                              assets: snapshot.assets)
    }

    func asset(
        id: String,
        parent: NSFileProviderItemIdentifier,
        configurationVersion: Int
    ) -> ImmichAsset? {
        let key = parent.rawValue
        guard loadSnapshot(for: key, configurationVersion: configurationVersion) != nil
        else { return nil }
        return snapshotIndexes[key]?[id]
    }

    /// Appends one server page to a generation-specific draft. A completed draft
    /// atomically replaces the published snapshot and emits its metadata delta.
    func append(
        _ assets: [ImmichAsset],
        pageNumber: Int,
        finalPage: Bool,
        for container: NSFileProviderItemIdentifier,
        generation: String,
        configurationVersion: Int
    ) {
        let key = draftKey(containerRawValue: container.rawValue, generation: generation)
        var draft: StoredDraft

        if pageNumber == 1 {
            draft = StoredDraft(
                schemaVersion: Self.schemaVersion,
                configurationVersion: configurationVersion,
                containerRawValue: container.rawValue,
                generation: generation,
                assets: [])
        } else if let existing = drafts[key] ?? loadDraft(
            containerRawValue: container.rawValue,
            generation: generation,
            configurationVersion: configurationVersion
        ) {
            draft = existing
        } else {
            fpLog.error(
                "metadata cache: missing draft for \(container.rawValue, privacy: .public) generation \(generation, privacy: .public)"
            )
            return
        }

        var known = Set(draft.assets.map(\.id))
        draft.assets.append(contentsOf: assets.filter { known.insert($0.id).inserted })
        drafts[key] = draft
        write(draft, to: draftURL(
            containerRawValue: container.rawValue, generation: generation))

        guard finalPage else { return }
        publish(draft.assets, for: container, generation: generation,
                configurationVersion: configurationVersion)
        drafts.removeValue(forKey: key)
        if let url = draftURL(containerRawValue: container.rawValue, generation: generation) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Publishes a complete bounded snapshot, used for locally name-sorted folders.
    func publish(
        _ assets: [ImmichAsset],
        for container: NSFileProviderItemIdentifier,
        generation: String,
        configurationVersion: Int
    ) {
        let oldSnapshot = loadSnapshot(
            for: container.rawValue, configurationVersion: configurationVersion)
        let snapshot = StoredSnapshot(
            schemaVersion: Self.schemaVersion,
            configurationVersion: configurationVersion,
            containerRawValue: container.rawValue,
            generation: generation,
            createdAt: Date(),
            assets: assets)

        recordChanges(from: oldSnapshot, to: snapshot)
        snapshots[container.rawValue] = snapshot
        snapshotIndexes[container.rawValue] = index(assets)
        write(snapshot, to: snapshotURL(containerRawValue: container.rawValue))
    }

    func currentChangeSequence(configurationVersion: Int) -> Int64 {
        loadChangeState(configurationVersion: configurationVersion).lastSequence
    }

    func changes(
        after anchor: Int64,
        for container: NSFileProviderItemIdentifier,
        maximumCount: Int,
        configurationVersion: Int
    ) -> ChangeBatch {
        let state = loadChangeState(configurationVersion: configurationVersion)
        if anchor < state.minimumAvailableSequence - 1 || anchor > state.lastSequence {
            return ChangeBatch(updates: [], deletedIdentifiers: [],
                               anchor: state.lastSequence, moreComing: false,
                               anchorExpired: true)
        }

        let isWorkingSet = container == .workingSet
        let limit = max(1, maximumCount)
        var selected: [StoredChange] = []

        for change in state.changes where change.sequence > anchor {
            guard isWorkingSet || change.parentRawValue == container.rawValue else { continue }
            selected.append(change)
            if selected.count == limit { break }
        }

        let lastSelectedSequence = selected.last?.sequence
        let hasMoreRelevantChanges: Bool
        if let lastSelectedSequence {
            hasMoreRelevantChanges = state.changes.contains {
                $0.sequence > lastSelectedSequence
                    && (isWorkingSet || $0.parentRawValue == container.rawValue)
            }
        } else {
            hasMoreRelevantChanges = false
        }
        let returnedAnchor = hasMoreRelevantChanges
            ? (lastSelectedSequence ?? anchor)
            : state.lastSequence

        let updates = selected.compactMap { change -> CachedUpdate? in
            guard let asset = change.updatedAsset else { return nil }
            return CachedUpdate(
                parent: NSFileProviderItemIdentifier(rawValue: change.parentRawValue),
                asset: asset)
        }
        let deleted = selected.compactMap {
            $0.deletedIdentifierRawValue.map(NSFileProviderItemIdentifier.init(rawValue:))
        }
        return ChangeBatch(updates: updates, deletedIdentifiers: deleted,
                           anchor: returnedAnchor, moreComing: hasMoreRelevantChanges,
                           anchorExpired: false)
    }

    private func loadSnapshot(
        for containerRawValue: String,
        configurationVersion: Int
    ) -> StoredSnapshot? {
        if let snapshot = snapshots[containerRawValue] {
            return snapshot.configurationVersion == configurationVersion ? snapshot : nil
        }
        guard let url = snapshotURL(containerRawValue: containerRawValue),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(StoredSnapshot.self, from: data),
              snapshot.schemaVersion == Self.schemaVersion,
              snapshot.configurationVersion == configurationVersion,
              snapshot.containerRawValue == containerRawValue else {
            return nil
        }
        snapshots[containerRawValue] = snapshot
        snapshotIndexes[containerRawValue] = index(snapshot.assets)
        return snapshot
    }

    private func loadDraft(
        containerRawValue: String,
        generation: String,
        configurationVersion: Int
    ) -> StoredDraft? {
        guard let url = draftURL(
            containerRawValue: containerRawValue, generation: generation),
              let data = try? Data(contentsOf: url),
              let draft = try? JSONDecoder().decode(StoredDraft.self, from: data),
              draft.schemaVersion == Self.schemaVersion,
              draft.configurationVersion == configurationVersion,
              draft.containerRawValue == containerRawValue,
              draft.generation == generation else {
            return nil
        }
        return draft
    }

    private func recordChanges(from old: StoredSnapshot?, to new: StoredSnapshot) {
        var state = loadChangeState(configurationVersion: new.configurationVersion)
        // The first snapshot is delivered by the simultaneous full item
        // enumeration. Recording every initial item as a later "change" would make
        // fileproviderd ingest the complete folder twice.
        guard let old else {
            changeState = state
            write(state, to: changeStateURL)
            return
        }

        let oldByID = index(old.assets)
        let newByID = index(new.assets)

        for asset in new.assets where oldByID[asset.id] != asset {
            state.lastSequence += 1
            state.changes.append(StoredChange(
                sequence: state.lastSequence,
                parentRawValue: new.containerRawValue,
                updatedAsset: asset,
                deletedIdentifierRawValue: nil))
        }
        for removed in oldByID.values where newByID[removed.id] == nil {
            state.lastSequence += 1
            let parent = NSFileProviderItemIdentifier(rawValue: new.containerRawValue)
            state.changes.append(StoredChange(
                sequence: state.lastSequence,
                parentRawValue: new.containerRawValue,
                updatedAsset: nil,
                deletedIdentifierRawValue: ItemID.asset(
                    removed.id, parent: parent).rawValue))
        }

        if state.changes.count > Self.maximumStoredChanges {
            state.changes.removeFirst(
                state.changes.count - Self.retainedChangesAfterCompaction)
        }
        state.minimumAvailableSequence =
            state.changes.first?.sequence ?? (state.lastSequence + 1)
        changeState = state
        write(state, to: changeStateURL)
    }

    private func loadChangeState(configurationVersion: Int) -> StoredChangeState {
        if let state = changeState, state.configurationVersion == configurationVersion {
            return state
        }
        if let url = changeStateURL,
           let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(StoredChangeState.self, from: data),
           state.schemaVersion == Self.schemaVersion,
           state.configurationVersion == configurationVersion {
            changeState = state
            return state
        }
        let empty = StoredChangeState(
            schemaVersion: Self.schemaVersion,
            configurationVersion: configurationVersion,
            lastSequence: 0,
            minimumAvailableSequence: 1,
            changes: [])
        changeState = empty
        return empty
    }

    private var changeStateURL: URL? {
        cacheDirectory?.appendingPathComponent("changes.json")
    }

    private func snapshotURL(containerRawValue: String) -> URL? {
        cacheDirectory?.appendingPathComponent(
            "\(encodedFileComponent(containerRawValue)).snapshot.json")
    }

    private func draftURL(containerRawValue: String, generation: String) -> URL? {
        cacheDirectory?.appendingPathComponent(
            "\(encodedFileComponent(containerRawValue)).\(generation).draft.json")
    }

    private func draftKey(containerRawValue: String, generation: String) -> String {
        "\(containerRawValue)|\(generation)"
    }

    private func encodedFileComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func index(_ assets: [ImmichAsset]) -> [String: ImmichAsset] {
        var result: [String: ImmichAsset] = [:]
        for asset in assets {
            result[asset.id] = asset
        }
        return result
    }

    private func write<T: Encodable>(_ value: T, to url: URL?) {
        guard let url,
              let data = try? JSONEncoder().encode(value) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            fpLog.error(
                "metadata cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
