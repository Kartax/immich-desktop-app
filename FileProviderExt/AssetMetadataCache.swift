import FileProvider
import Foundation

/// One atomic, connection-scoped transaction contains receipts, occurrences, cache
/// generations and changes. A receipt is never committed ahead of its deletions.
actor AssetMetadataCache {
    private static let registryLock = NSLock()
    private static var registry: [String: AssetMetadataCache] = [:]

    static func shared(for client: ImmichClient) -> AssetMetadataCache {
        registryLock.withLock {
            let key = "\(client.connectionID):\(client.configurationVersion)"
            if let cache = registry[key] { return cache }
            let cache = AssetMetadataCache(connectionID: client.connectionID,
                                           configurationVersion: client.configurationVersion)
            registry[key] = cache
            return cache
        }
    }

    struct CachedSnapshot: Codable {
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
        let folderUpdates: [FileProviderItem]
        let deletedIdentifiers: [NSFileProviderItemIdentifier]
        let anchor: Int64
        let moreComing: Bool
        let anchorExpired: Bool
    }

    private struct Occurrence: Codable {
        let parent: String
        let asset: ImmichAsset
    }

    private struct Change: Codable {
        let sequence: Int64
        let parent: String
        let asset: ImmichAsset?
        let deleted: String?
        var folder: String? = nil
    }

    private struct State: Codable {
        var epoch = UUID().uuidString
        var receipts: Set<UUID> = []
        var deletedAssetIDs: Set<String> = []
        var snapshots: [String: CachedSnapshot] = [:]
        var drafts: [String: [ImmichAsset]] = [:]
        var occurrences: [String: Occurrence] = [:]
        var containers: Set<String> = []
        var changes: [Change] = []
        var sequence: Int64 = 0
        var minimumSequence: Int64 = 1
        var lastDeletionSequence: Int64 = 0
        var pendingSignals: Set<String> = []
        var uploadRevision: String? = nil
        var uploadHierarchyRevision: String? = nil
        var appliedUploadAssetIDs: Set<String>? = nil
    }

    @TaskLocal private static var requestEpoch: String?
    private let connectionID: String
    private let configurationVersion: Int
    private let directory: URL?
    private let legacyDirectory: URL?
    private let isCurrentConnection: @Sendable () -> Bool
    private let signal: @Sendable (String) async throws -> Void
    private let journal: DeletionJournal
    private var state: State?

    /// Explicit storage and journal seams permit isolated crash/restart scenarios.
    init(connectionID: String, configurationVersion: Int,
         directory: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfig.appGroup),
         journal: DeletionJournal = DeletionJournal(),
         isCurrentConnection: (@Sendable () -> Bool)? = nil,
         signal: (@Sendable (String) async throws -> Void)? = nil) {
        self.connectionID = connectionID
        self.configurationVersion = configurationVersion
        self.directory = directory?.appendingPathComponent(
            "file-provider-deletions-v2/\(connectionID)/\(configurationVersion)",
            isDirectory: true)
        self.legacyDirectory = directory?.appendingPathComponent("file-provider-metadata-v1", isDirectory: true)
        self.isCurrentConnection = isCurrentConnection ?? {
            guard let client = ImmichClient() else { return false }
            return client.connectionID == connectionID && client.configurationVersion == configurationVersion
        }
        self.signal = signal ?? { raw in
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: AppConfig.domainIdentifier),
                displayName: AppConfig.domainDisplayName)
            guard let manager = NSFileProviderManager(for: domain) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try await manager.signalEnumerator(for: NSFileProviderItemIdentifier(rawValue: raw))
        }
        self.journal = journal
    }

    nonisolated func withRequest<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await signalPendingChanges()
        let epoch = try await reconcile()
        do {
            let result = try await Self.$requestEpoch.withValue(epoch, operation: operation)
            await flushSignalsAfterRequest()
            return result
        } catch {
            await flushSignalsAfterRequest()
            throw error
        }
    }

    /// Callback data was already durably recorded. A later wake/receipt failure
    /// must not invoke that callback twice; retain the pending work and log it.
    private func flushSignalsAfterRequest() async {
        guard state?.pendingSignals.isEmpty == false else { return }
        do { try await signalPendingChanges() }
        catch { fpLog.error("Finder deletion propagation remains pending: \(error.localizedDescription, privacy: .public)") }
    }

    /// Every entry point rereads the immutable app journal. Old network requests
    /// fail rather than publishing a page (or local draft) across a deletion fence.
    private func checkedState() throws -> State {
        let epoch = try reconcile()
        guard Self.requestEpoch == epoch else {
            throw NSFileProviderError(.pageExpired)
        }
        return state!
    }

    @discardableResult
    private func reconcile() throws -> String {
        guard isCurrentConnection() else {
            throw NSFileProviderError(.notAuthenticated)
        }
        if state == nil {
            guard let directory else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            } else {
                try commit(importLegacyOccurrences())
            }
        }
        let uploadRevision = UploadActivity.revision
        if state!.uploadRevision == nil && uploadRevision.isEmpty {
            var next = state!
            next.uploadRevision = uploadRevision
            try commit(next)
        } else if state!.uploadRevision != uploadRevision {
            var next = state!
            next.uploadRevision = uploadRevision
            next.snapshots.removeAll()
            next.drafts.removeAll()
            next.epoch = UUID().uuidString
            next.sequence += 1
            next.lastDeletionSequence = next.sequence
            next.pendingSignals.formUnion(next.containers)
            next.pendingSignals.formUnion([
                NSFileProviderItemIdentifier.rootContainer.rawValue,
                ItemID.timeline.rawValue,
                NSFileProviderItemIdentifier.workingSet.rawValue
            ])
            try commit(next)
        }
        let records = try journal.confirmedDeletions(connectionID: connectionID)
        let pending = records.filter { !state!.receipts.contains($0.id) }
        guard !pending.isEmpty else { return state!.epoch }
        var next = state!
        let deleted = Set(pending.map(\.assetID))
        next.changes.removeAll { $0.asset.map { deleted.contains($0.id) } ?? false }
        for (raw, occurrence) in next.occurrences where deleted.contains(occurrence.asset.id) {
            next.sequence += 1
            next.changes.append(Change(sequence: next.sequence, parent: occurrence.parent,
                                       asset: nil, deleted: raw))
            next.occurrences.removeValue(forKey: raw)
        }
        // Invalidate every generation: deletion shifts server page boundaries and
        // can change grouping at the threshold even in an unfinished enumeration.
        next.snapshots.removeAll()
        next.drafts.removeAll()
        next.epoch = UUID().uuidString
        next.receipts.formUnion(pending.map(\.id))
        next.deletedAssetIDs.formUnion(deleted)
        next.sequence += 1 // structural invalidation fence, even with no known files
        next.lastDeletionSequence = next.sequence
        next.pendingSignals.formUnion(next.containers)
        next.pendingSignals.insert(NSFileProviderItemIdentifier.workingSet.rawValue)
        next.pendingSignals.insert(NSFileProviderItemIdentifier.rootContainer.rawValue)
        try commit(next)
        return next.epoch
    }

    /// v1 had no reverse index. Import both complete snapshots and interrupted
    /// drafts, conservatively expanding every possible grouped projection.
    /// Only the current configuration may be attributed to this connection.
    private func importLegacyOccurrences() throws -> State {
        struct LegacySnapshot: Decodable {
            let configurationVersion: Int
            let containerRawValue: String
            let assets: [ImmichAsset]
        }
        var imported = State()
        guard let legacyDirectory,
              FileManager.default.fileExists(atPath: legacyDirectory.path) else { return imported }
        for url in try FileManager.default.contentsOfDirectory(
            at: legacyDirectory, includingPropertiesForKeys: nil) {
            guard url.lastPathComponent.hasSuffix(".snapshot.json")
                || url.lastPathComponent.hasSuffix(".draft.json") else { continue }
            let legacy = try JSONDecoder().decode(LegacySnapshot.self, from: Data(contentsOf: url))
            guard legacy.configurationVersion == configurationVersion else { continue }
            let base = NSFileProviderItemIdentifier(rawValue: legacy.containerRawValue)
            let kind = ItemID(base).kind
            for asset in legacy.assets {
                var parents = [base]
                if kind == .album || kind == .person || kind == .city {
                    let month = ItemEnumerator.monthKey(for: asset)
                    let year = month == "unknown" ? "unknown" : String(month.prefix(4))
                    parents.append(year == "unknown"
                        ? ItemID.groupedYear(base: base, year: year)
                        : ItemID.groupedMonth(base: base, month: month))
                }
                for parent in parents {
                    imported.occurrences[ItemID.asset(asset.id, parent: parent).rawValue] =
                        Occurrence(parent: parent.rawValue, asset: asset)
                    var ancestor: NSFileProviderItemIdentifier? = parent
                    while let container = ancestor, imported.containers.insert(container.rawValue).inserted {
                        ancestor = ItemID(container).parent
                    }
                }
            }
        }
        return imported
    }

    /// Signal receipts are independent of deletion receipts. Failed signals remain
    /// durable and are retried on the next provider entry, including after restart.
    func signalPendingChanges() async throws {
        _ = try reconcile()
        guard !state!.pendingSignals.isEmpty else { return }
        let pending = state!.pendingSignals
        let epoch = state!.epoch
        let sequence = state!.sequence
        for raw in pending {
            do {
                try await signal(raw)
            } catch {
                fpLog.error("deletion signal pending for \(raw, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            _ = try reconcile()
            // A new deletion during the await needs its own signal.
            if state!.epoch == epoch && state!.sequence == sequence {
                var next = state!
                next.pendingSignals.remove(raw)
                try commit(next)
            }
        }
    }

    func validateRequest() throws { _ = try checkedState() }

    func needsActiveVerification(assetID: String) throws -> Bool {
        try checkedState().deletedAssetIDs.contains(assetID)
    }

    func freshSnapshot(for container: NSFileProviderItemIdentifier,
                       configurationVersion: Int, maximumAge: TimeInterval) throws -> CachedSnapshot? {
        guard let snapshot = try checkedState().snapshots[container.rawValue],
              Date().timeIntervalSince(snapshot.createdAt) <= maximumAge else { return nil }
        return snapshot
    }

    func snapshot(for container: NSFileProviderItemIdentifier, generation: String,
                  configurationVersion: Int) throws -> CachedSnapshot? {
        guard let snapshot = try checkedState().snapshots[container.rawValue],
              snapshot.generation == generation else { return nil }
        return snapshot
    }

    func asset(id: String, parent: NSFileProviderItemIdentifier,
               configurationVersion: Int) throws -> ImmichAsset? {
        try checkedState().snapshots[parent.rawValue]?.assets.first { $0.id == id }
    }

    func append(_ assets: [ImmichAsset], pageNumber: Int, finalPage: Bool,
                for container: NSFileProviderItemIdentifier, generation: String,
                configurationVersion: Int) throws {
        var next = try checkedState()
        let key = "\(container.rawValue):\(generation)"
        guard pageNumber == 1 || next.drafts[key] != nil else {
            throw NSFileProviderError(.pageExpired)
        }
        var draft = pageNumber == 1 ? [] : next.drafts[key]!
        var known = Set(draft.map(\.id))
        draft.append(contentsOf: assets.filter { known.insert($0.id).inserted })
        next.drafts[key] = draft
        try commit(next)
        if finalPage {
            try publish(draft, for: container, generation: generation,
                        configurationVersion: configurationVersion)
            next = state!
            next.drafts.removeValue(forKey: key)
            try commit(next)
        }
    }

    func publish(_ assets: [ImmichAsset], for container: NSFileProviderItemIdentifier,
                 generation: String, configurationVersion: Int, emitChanges: Bool = true) throws {
        var next = try checkedState()
        if emitChanges, let old = next.snapshots[container.rawValue] {
            let newIDs = Set(assets.map(\.id))
            for asset in old.assets where !newIDs.contains(asset.id) {
                let raw = ItemID.asset(asset.id, parent: container).rawValue
                next.sequence += 1
                next.changes.append(Change(sequence: next.sequence, parent: container.rawValue,
                                           asset: nil, deleted: raw))
                next.occurrences.removeValue(forKey: raw)
            }
        }
        next.snapshots[container.rawValue] = CachedSnapshot(
            generation: generation, createdAt: Date(), assets: assets)
        try commit(next)
    }

    /// The server-confirmed identity lives in its natural timeline month. Publish
    /// ancestors before the file so the working set can materialize a new path.
    func recordUpload(_ asset: ImmichAsset) throws -> FileProviderItem {
        var next = try checkedState()
        let month = ItemEnumerator.monthKey(for: asset)
        guard month != "unknown" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let year = String(month.prefix(4))
        let folders: [FileProviderItem] = [
            .timelineFolder(), .yearFolder(year),
            .monthFolder(value: month, display: TimelineFormat.monthDisplay(month))
        ]
        for folder in folders {
            if !next.containers.contains(folder.itemIdentifier.rawValue) {
                next.sequence += 1
                next.changes.append(Change(sequence: next.sequence,
                                           parent: folder.parentItemIdentifier.rawValue,
                                           asset: nil, deleted: nil,
                                           folder: folder.itemIdentifier.rawValue))
            }
            rememberContainer(folder.itemIdentifier, in: &next)
            next.pendingSignals.insert(folder.parentItemIdentifier.rawValue)
        }
        let item = FileProviderItem(asset: asset, parent: ItemID.month(month))
        if next.occurrences[item.itemIdentifier.rawValue]?.asset != asset {
            next.sequence += 1
            next.changes.append(Change(sequence: next.sequence,
                                       parent: item.parentItemIdentifier.rawValue,
                                       asset: asset, deleted: nil))
            next.occurrences[item.itemIdentifier.rawValue] = Occurrence(
                parent: item.parentItemIdentifier.rawValue, asset: asset)
        }
        next.pendingSignals.insert(item.parentItemIdentifier.rawValue)
        next.pendingSignals.insert(NSFileProviderItemIdentifier.workingSet.rawValue)
        next.appliedUploadAssetIDs = (next.appliedUploadAssetIDs ?? []).union([asset.id])
        try commit(next)
        return item
    }

    func needsUploadHierarchyRefresh() throws -> Bool {
        let state = try checkedState()
        return !(state.uploadRevision ?? "").isEmpty
            && state.uploadHierarchyRevision != state.uploadRevision
    }

    func hasAppliedUpload(assetID: String) throws -> Bool {
        try checkedState().appliedUploadAssetIDs?.contains(assetID) == true
    }

    func finishUploadHierarchyRefresh() throws {
        var next = try checkedState()
        next.uploadHierarchyRevision = next.uploadRevision
        try commit(next)
    }

    /// Called before exposing ANY item to fileproviderd, not only on final pages.
    /// Thus grouped projections and incomplete drafts cannot lose known aliases.
    func record(_ items: [FileProviderItem], in container: NSFileProviderItemIdentifier,
                enumerating: Bool = false) throws {
        var next = try checkedState()
        let previousSequence = next.sequence
        let previousContainerCount = next.containers.count
        rememberContainer(container, in: &next)
        if enumerating && container != .workingSet {
            let folders = Set(items.filter { $0.assetMetadata == nil }.map { $0.itemIdentifier.rawValue })
            let missing = next.containers.filter {
                $0 != container.rawValue
                    && ItemID(NSFileProviderItemIdentifier(rawValue: $0)).parent == container
                    && !folders.contains($0)
            }
            var removed = Set<String>()
            for raw in next.containers {
                var ancestor: NSFileProviderItemIdentifier? = NSFileProviderItemIdentifier(rawValue: raw)
                while let current = ancestor {
                    if missing.contains(current.rawValue) {
                        removed.insert(raw)
                        break
                    }
                    ancestor = ItemID(current).parent
                }
            }
            let dropped = next.occurrences.filter { removed.contains($0.value.parent) }
            next.changes.removeAll { change in
                guard let asset = change.asset else { return false }
                return dropped[ItemID.asset(asset.id, parent: NSFileProviderItemIdentifier(rawValue: change.parent)).rawValue] != nil
            }
            for (raw, occurrence) in dropped {
                next.sequence += 1
                next.changes.append(Change(sequence: next.sequence, parent: occurrence.parent, asset: nil, deleted: raw))
                next.occurrences.removeValue(forKey: raw)
            }
            for raw in removed {
                guard let parent = ItemID(NSFileProviderItemIdentifier(rawValue: raw)).parent else { continue }
                next.sequence += 1
                next.changes.append(Change(sequence: next.sequence, parent: parent.rawValue, asset: nil, deleted: raw))
            }
            next.containers.subtract(removed)
            next.pendingSignals.subtract(removed)
            if !removed.isEmpty {
                next.pendingSignals.insert(NSFileProviderItemIdentifier.workingSet.rawValue)
                next.pendingSignals.insert(container.rawValue)
            }
        }
        for item in items {
            rememberContainer(item.parentItemIdentifier, in: &next)
            if let asset = item.assetMetadata {
                let raw = item.itemIdentifier.rawValue
                let old = next.occurrences[raw]
                if old?.asset != asset {
                    next.sequence += 1
                    next.changes.append(Change(sequence: next.sequence,
                                               parent: item.parentItemIdentifier.rawValue,
                                               asset: asset, deleted: nil))
                    next.occurrences[raw] = Occurrence(parent: item.parentItemIdentifier.rawValue, asset: asset)
                }
            } else {
                rememberContainer(item.itemIdentifier, in: &next)
            }
        }
        if next.sequence != previousSequence || next.containers.count != previousContainerCount {
            try commit(next)
        }
    }

    private func rememberContainer(_ container: NSFileProviderItemIdentifier, in state: inout State) {
        var ancestor: NSFileProviderItemIdentifier? = container
        while let current = ancestor {
            if !state.containers.insert(current.rawValue).inserted { break }
            ancestor = ItemID(current).parent
        }
    }

    func workingSetItems() throws -> [FileProviderItem] {
        let state = try checkedState()
        let folders = state.containers.compactMap(Self.uploadFolder).sorted {
            func depth(_ item: FileProviderItem) -> Int {
                switch ItemID(item.itemIdentifier).kind {
                case .timeline: return 0
                case .year: return 1
                default: return 2
                }
            }
            return depth($0) < depth($1)
        }
        return folders + state.occurrences.values.map {
            FileProviderItem(asset: $0.asset, parent: NSFileProviderItemIdentifier(rawValue: $0.parent))
        }
    }

    private static func uploadFolder(_ raw: String) -> FileProviderItem? {
        let id = ItemID(NSFileProviderItemIdentifier(rawValue: raw))
        switch id.kind {
        case .timeline: return .timelineFolder()
        case .year: return .yearFolder(id.value)
        case .month:
            return .monthFolder(value: id.value, display: TimelineFormat.monthDisplay(id.value))
        default: return nil
        }
    }

    func currentChangeSequence(configurationVersion: Int) throws -> Int64 {
        try checkedState().sequence
    }

    func changes(after anchor: Int64, for container: NSFileProviderItemIdentifier,
                 maximumCount: Int, configurationVersion: Int) throws -> ChangeBatch {
        let state = try checkedState()
        // Structural container contents must be refetched; signaling alone never
        // refreshes them. Working set retains explicit per-occurrence deletions.
        if anchor < state.minimumSequence - 1 || anchor > state.sequence
            || (container != .workingSet && anchor < state.lastDeletionSequence) {
            return ChangeBatch(updates: [], folderUpdates: [], deletedIdentifiers: [],
                               anchor: state.sequence, moreComing: false, anchorExpired: true)
        }
        let relevant = state.changes.filter {
            $0.sequence > anchor && (container == .workingSet || $0.parent == container.rawValue)
        }
        let selected = relevant.prefix(max(1, maximumCount))
        // Coalesce within a batch so an earlier update cannot override its later
        // deletion (or vice versa) when the observer receives separate callbacks.
        var latest: [String: Change] = [:]
        for change in selected {
            let raw = change.deleted ?? change.folder ?? ItemID.asset(change.asset!.id,
                parent: NSFileProviderItemIdentifier(rawValue: change.parent)).rawValue
            latest[raw] = change
        }
        let more = relevant.count > selected.count
        return ChangeBatch(updates: latest.values.compactMap { change in
            change.asset.map { CachedUpdate(parent: NSFileProviderItemIdentifier(rawValue: change.parent), asset: $0) }
        }, folderUpdates: selected.compactMap { change in
            guard let raw = change.folder, latest[raw]?.sequence == change.sequence else { return nil }
            return Self.uploadFolder(raw)
        }, deletedIdentifiers: latest.values.compactMap { $0.deleted.map(NSFileProviderItemIdentifier.init(rawValue:)) },
        anchor: more ? selected.last!.sequence : state.sequence, moreComing: more, anchorExpired: false)
    }

    private func commit(_ value: State) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        var next = value
        if next.changes.count > 200_000 {
            next.changes.removeFirst(next.changes.count - 100_000)
        }
        next.minimumSequence = next.changes.first?.sequence ?? (next.sequence + 1)
        let data = try JSONEncoder().encode(next)
        try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        state = next
    }
}
