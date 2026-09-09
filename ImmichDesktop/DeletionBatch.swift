import Foundation
import Observation

/// Owns confirmed, sequential deletion independently of every gallery window.
/// Stop only gates the next request; neither Stop nor Quit cancels a DELETE.
@MainActor
@Observable
final class DeletionBatch {
    enum Phase: Equatable { case idle, running, completed }

    struct Progress: Equatable {
        let completedCount: Int
        let totalCount: Int
        let currentFileName: String?
    }

    struct Failure: Identifiable, Equatable {
        let assetID: String
        let originalFileName: String
        let message: String
        var id: String { assetID }
    }

    struct UnfinishedAsset: Identifiable, Equatable {
        let assetID: String
        let originalFileName: String
        var id: String { assetID }
    }

    struct BatchResult: Equatable {
        let totalCount: Int
        let successfulAssetIDs: [String]
        let failures: [Failure]
        let unfinished: [UnfinishedAsset]
        let uncertain: [Failure]
        let stopped: Bool
        let message: String?

        var retryableAssetIDs: [String] { failures.map(\.assetID) + unfinished.map(\.assetID) }
        var isFullSuccess: Bool {
            !stopped && message == nil && failures.isEmpty && unfinished.isEmpty
                && uncertain.isEmpty && successfulAssetIDs.count == totalCount
        }
    }

    typealias DeleteOperation = (ImmichClient, String) async throws -> Void
    typealias ReadState = (ImmichClient, String) async -> ImmichClient.AssetDeletionState

    private(set) var phase: Phase = .idle
    private(set) var progress = Progress(completedCount: 0, totalCount: 0, currentFileName: nil)
    private(set) var successfulAssetIDs: [String] = []
    private(set) var result: BatchResult?
    private(set) var permission: ImmichClient.DeletionPermission = .unknown("Deletion permissions have not been checked.")
    private(set) var trashPolicy: ImmichClient.TrashPolicy = .unknown
    private(set) var connectionID: String?
    private(set) var batchConnectionID: String?
    private var optedIn = false

    var allowDeletions: Bool {
        get { optedIn }
        set {
            guard phase != .running else { return }
            writeOptIn(newValue)
            optedIn = readOptIn()
        }
    }

    var canDelete: Bool {
        optedIn && permission != .missing && phase == .idle && task == nil
            && connectionID != nil
    }

    private let journal: DeletionJournal
    private let makeClient: () -> ImmichClient?
    private let readOptIn: () -> Bool
    private let writeOptIn: (Bool) -> Void
    private let delete: DeleteOperation
    private let readState: ReadState
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var capabilityGeneration = 0
    private var retainedBatch: DeletionJournal.Batch?

    /// Inject a URLSession through clientProvider for HTTP verification, or operations
    /// for state-machine verification. Storage never falls back outside the App Group.
    init(journal: DeletionJournal = DeletionJournal(),
         clientProvider: @escaping () -> ImmichClient? = { ImmichClient() },
         readOptIn: @escaping () -> Bool = { AppConfig.allowDeletions },
         writeOptIn: @escaping (Bool) -> Void = { AppConfig.allowDeletions = $0 },
         deleteOperation: DeleteOperation? = nil,
         readState: ReadState? = nil) {
        self.journal = journal
        self.makeClient = clientProvider
        self.readOptIn = readOptIn
        self.writeOptIn = writeOptIn
        self.delete = deleteOperation ?? { try await $0.deleteAsset(id: $1) }
        self.readState = readState ?? { await $0.deletionState(id: $1) }
        optedIn = readOptIn()
        let client = clientProvider()
        connectionID = client?.connectionID
        if let client { recoverIfNeeded(client: client) }
    }

    func refreshCapabilities() async {
        guard phase != .running else { return }
        capabilityGeneration &+= 1
        let generation = capabilityGeneration
        optedIn = readOptIn()
        guard let client = makeClient() else {
            connectionID = nil
            permission = .unknown("Configure an Immich connection first.")
            trashPolicy = .unknown
            return
        }
        connectionID = client.connectionID
        permission = .unknown("Checking deletion permissions…")
        trashPolicy = .unknown
        async let loadedPermission = client.deletionPermission()
        async let loadedPolicy = client.trashPolicy()
        let loaded = await (loadedPermission, loadedPolicy)
        guard generation == capabilityGeneration,
              makeClient()?.connectionID == client.connectionID else { return }
        permission = loaded.0
        trashPolicy = loaded.1
        optedIn = readOptIn()
        if phase == .idle { recoverIfNeeded(client: client) }
    }

    @discardableResult
    func start(assets: [ImmichAsset]) -> Bool {
        guard canDelete, readOptIn(), let client = makeClient(),
              client.connectionID == connectionID else { return false }
        var seen = Set<String>()
        let snapshot = assets.filter { seen.insert($0.id).inserted }
        guard !snapshot.isEmpty else { return false }
        // Check disk again before starting, including after switching connections.
        guard !recoverIfNeeded(client: client) else { return false }
        let batch = DeletionJournal.Batch(id: UUID(), connectionID: client.connectionID,
            createdAt: Date(), assets: snapshot.map {
                DeletionJournal.Asset(id: UUID(), assetID: $0.id, originalFileName: $0.originalFileName)
            })
        batchConnectionID = client.connectionID
        retainedBatch = batch
        successfulAssetIDs = []
        result = nil
        stopRequested = false
        capabilityGeneration &+= 1
        do {
            try journal.save(batch)
        } catch {
            var failed = batch
            failed.completed = true
            failed.stopped = true
            failed.message = Self.storageMessage
            retainedBatch = failed
            publish(failed)
            return true
        }
        phase = .running
        progress = Progress(completedCount: 0, totalCount: batch.assets.count, currentFileName: nil)
        task = Task { await self.run(batch, client: client) }
        return true
    }

    func stop() {
        guard phase == .running else { return }
        stopRequested = true
    }

    func waitForCompletion() async {
        await task?.value
    }

    func consumeResult() {
        guard phase == .completed, task == nil else { return }
        if var batch = retainedBatch {
            batch.acknowledged = true
            do {
                try journal.save(batch)
            } catch {
                batch.acknowledged = false
                batch.message = Self.storageMessage
                retainedBatch = batch
                publish(batch)
                return
            }
        }
        retainedBatch = nil
        batchConnectionID = nil
        successfulAssetIDs = []
        result = nil
        phase = .idle
        progress = Progress(completedCount: 0, totalCount: 0, currentFileName: nil)
        if let client = makeClient() { recoverIfNeeded(client: client) }
    }

    private func run(_ initial: DeletionJournal.Batch, client: ImmichClient) async {
        var batch = initial
        // Permissions can change after the confirmation appeared. Never send with a
        // different key, a disabled opt-in, or a newly discovered missing permission.
        let freshPermission = await client.deletionPermission()
        permission = freshPermission
        if freshPermission == .missing || !readOptIn()
            || makeClient()?.connectionID != client.connectionID {
            batch.stopped = true
            batch.message = "Deletion access or the connection changed. No deletion requests were sent. Review Settings and confirm again."
        } else {
            for index in batch.assets.indices {
                guard !stopRequested, !batch.stopped else { break }
                progress = Progress(completedCount: index, totalCount: batch.assets.count,
                                    currentFileName: batch.assets[index].originalFileName)
                batch.assets[index].state = .inFlight
                do {
                    try journal.save(batch)
                } catch {
                    // No request was sent. Leave the on-disk intent untouched; if its
                    // flush failed after rename, recovery conservatively reads it.
                    batch.assets[index].state = .pending
                    batch.stopped = true
                    batch.message = Self.storageMessage
                    break
                }

                var uncertainResponse = false
                do {
                    try await delete(client, batch.assets[index].assetID)
                    batch.assets[index].state = .succeeded
                } catch let error as ImmichClient.DeletionError {
                    switch error {
                    case .authentication:
                        batch.assets[index].state = .failed
                        batch.stopped = true
                    case .rejected:
                        batch.assets[index].state = .failed
                    case .uncertain:
                        batch.assets[index].state = .uncertain
                        batch.stopped = true
                        uncertainResponse = true
                    }
                    batch.assets[index].message = error.errorDescription
                } catch {
                    batch.assets[index].state = .uncertain
                    batch.assets[index].message = Self.uncertainMessage
                    batch.stopped = true
                    uncertainResponse = true
                }

                if uncertainResponse {
                    // Read-only reconciliation never authorizes another write in this batch.
                    await reconcile(&batch.assets[index], client: client)
                }
                do {
                    if batch.assets[index].state == .succeeded {
                        try journal.confirm(asset: batch.assets[index], connectionID: batch.connectionID)
                    }
                    try journal.save(batch)
                } catch {
                    // The request may have changed the server, but its durable outcome
                    // is not established. Never turn this into an ordinary retryable failure.
                    batch.assets[index].state = .uncertain
                    batch.assets[index].message = Self.storageMessage
                    batch.stopped = true
                    batch.message = Self.storageMessage
                    // Best effort preserves uncertainty; the pre-request inFlight intent
                    // remains a recovery barrier even if this write also fails.
                    try? journal.save(batch)
                    break
                }
                successfulAssetIDs = batch.assets.filter { $0.state == .succeeded }.map(\.assetID)
                progress = Progress(completedCount: index + 1, totalCount: batch.assets.count,
                                    currentFileName: nil)
            }
        }
        batch.stopped = batch.stopped || stopRequested
        batch.completed = true
        do { try journal.save(batch) }
        catch { batch.message = Self.storageMessage; batch.stopped = true }
        retainedBatch = batch
        task = nil
        publish(batch)
    }

    /// Reads only the currently configured account. Other accounts' unacknowledged
    /// records stay on disk until that exact connection is selected again.
    @discardableResult
    private func recoverIfNeeded(client: ImmichClient) -> Bool {
        guard phase == .idle, task == nil else { return phase != .idle }
        do {
            guard let batch = try journal.pendingBatches(connectionID: client.connectionID).first else { return false }
            batchConnectionID = batch.connectionID
            retainedBatch = batch
            phase = .running
            progress = Progress(completedCount: 0, totalCount: batch.assets.count, currentFileName: nil)
            task = Task { await self.recover(batch, client: client) }
        } catch {
            batchConnectionID = client.connectionID
            result = BatchResult(totalCount: 0, successfulAssetIDs: [], failures: [], unfinished: [],
                                 uncertain: [], stopped: true, message: Self.storageMessage)
            phase = .completed
        }
        return true
    }

    private func recover(_ initial: DeletionJournal.Batch, client: ImmichClient) async {
        var batch = initial
        if !batch.completed {
            batch.stopped = true
            batch.message = "An interrupted deletion was recovered. No deletion requests were replayed. Review unconfirmed Assets in Immich before trying again."
        }
        do {
            let confirmed = Set(try journal.confirmedDeletions(connectionID: batch.connectionID).map(\.id))
            for index in batch.assets.indices {
                if confirmed.contains(batch.assets[index].id) {
                    batch.assets[index].state = .succeeded
                    batch.assets[index].message = nil
                } else if batch.assets[index].state == .inFlight || batch.assets[index].state == .uncertain {
                    batch.assets[index].state = .uncertain
                    batch.assets[index].message = Self.uncertainMessage
                    // Credential snapshot stays fixed. Stop read recovery when settings
                    // changed externally; never reconcile against the replacement key.
                    if makeClient()?.connectionID == client.connectionID {
                        await reconcile(&batch.assets[index], client: client)
                    }
                    if batch.assets[index].state == .succeeded {
                        do { try journal.confirm(asset: batch.assets[index], connectionID: batch.connectionID) }
                        catch {
                            batch.assets[index].state = .uncertain
                            batch.assets[index].message = Self.storageMessage
                            throw error
                        }
                    }
                }
            }
            batch.completed = true
            try journal.save(batch)
        } catch {
            batch.message = Self.storageMessage
            batch.stopped = true
        }
        retainedBatch = batch
        task = nil
        publish(batch)
    }

    private func reconcile(_ asset: inout DeletionJournal.Asset, client: ImmichClient) async {
        switch await readState(client, asset.assetID) {
        case .deleted:
            asset.state = .succeeded
            asset.message = nil
        case .active:
            asset.state = .failed
            asset.message = "The Asset is currently active in Immich. It was not automatically retried; a new attempt requires confirmation."
        case .unknown(let message):
            asset.state = .uncertain
            asset.message = message
        }
    }

    private func publish(_ batch: DeletionJournal.Batch) {
        successfulAssetIDs = batch.assets.filter { $0.state == .succeeded }.map(\.assetID)
        result = BatchResult(totalCount: batch.assets.count, successfulAssetIDs: successfulAssetIDs,
            failures: batch.assets.filter { $0.state == .failed }.map(Self.failure),
            unfinished: batch.assets.filter { $0.state == .pending }.map {
                UnfinishedAsset(assetID: $0.assetID, originalFileName: $0.originalFileName)
            },
            uncertain: batch.assets.filter { $0.state == .uncertain || $0.state == .inFlight }.map(Self.failure),
            stopped: batch.stopped, message: batch.message)
        progress = Progress(completedCount: batch.assets.filter { $0.state != .pending }.count,
                            totalCount: batch.assets.count, currentFileName: nil)
        phase = .completed
    }

    private static func failure(_ asset: DeletionJournal.Asset) -> Failure {
        Failure(assetID: asset.assetID, originalFileName: asset.originalFileName,
                message: asset.message ?? uncertainMessage)
    }

    private static let storageMessage = "The deletion safety journal could not be saved or read. No further requests were sent. Any unconfirmed Asset must be checked in Immich."
    private static let uncertainMessage = "Deletion could not be confirmed. Check the Asset and Trash in Immich; it will not be retried automatically."
}
