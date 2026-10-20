import Foundation
import Observation

/// Paged loader for the "All Photos" timeline. Unlike the File Provider path this
/// never materializes the whole library: one page up front, more on demand while
/// scrolling (`loadMoreIfNeeded`). "Jump to month" re-anchors paging with a
/// `takenBefore` date, so no intervening pages are ever fetched.
@MainActor
@Observable
final class GalleryViewModel {
    enum Phase {
        case notConfigured
        case loading
        case loaded
        case empty
        case error(String)
    }

    struct Section: Identifiable {
        let id: String       // month key "2025-06", or "unknown"
        let title: String    // "June 2025" / "Unknown Date"
        var assets: [ImmichAsset]
    }

    struct MonthEntry: Identifiable {
        let id: String       // month key "2025-06"
        let title: String    // "June"
        let count: Int
    }

    struct YearGroup: Identifiable {
        let id: String       // "2025"
        let months: [MonthEntry]
    }

    private(set) var phase: Phase = .loading
    /// Flat, newest-first list of everything loaded so far (drives detail prev/next).
    private(set) var assets: [ImmichAsset] = []
    /// The same assets grouped by month for the grid's section headers.
    private(set) var sections: [Section] = []
    private(set) var isLoadingMore = false
    /// All months with photo counts (one cheap buckets call), for the jump menu.
    private(set) var yearGroups: [YearGroup] = []
    /// Non-nil while showing a jumped-to timeline window (ISO `takenBefore` date).
    private(set) var anchor: String?
    /// Asset selection is limited to Asset IDs already loaded in this timeline window.
    private(set) var selectedAssetIDs = Set<String>()
    var selectionCount: Int { selectedAssetIDs.count }
    var selectedAssets: [ImmichAsset] {
        assets.filter { selectedAssetIDs.contains($0.id) }
    }
    private var selectionAnchorID: String?
    /// Retryable Assets not loaded yet are selected as their pages arrive.
    private var pendingSelectionIDs = Set<String>()

    private static let pageSize = 200
    private static let triggerWindow = 40

    private var nextPage: Int? = 1
    private var seenIds = Set<String>()
    /// Ids of the trailing assets; a cell from this window appearing means the user
    /// is near the end of the loaded data and the next page should be fetched.
    private var triggerIds = Set<String>()
    private var indexById: [String: Int] = [:]
    private var sectionIndexByKey: [String: Int] = [:]
    private var client: ImmichClient?
    private var consumedUploadIDs = Set<String>()
    /// Bumped on every reset so in-flight page and bucket loads can detect they
    /// became stale and must not mutate the new timeline.
    private var generation = 0

    /// Paging is paused during mutations; confirmed deletion shifts every later
    /// offset page. Restart from page one, deduplicating against surviving rows.
    private var pagingSuspended = false

    private var pagingNeedsRepair = false
    var connectionID: String? { client?.connectionID }

    func setPagingSuspended(_ suspended: Bool) {
        pagingSuspended = suspended
        guard !suspended, pagingNeedsRepair else { return }
        pagingNeedsRepair = false
        if !suspended, let last = assets.last {
            loadMoreIfNeeded(after: last)
        } else if !suspended, assets.isEmpty, nextPage != nil, client != nil {
            let gen = generation
            Task { await loadFirstPage(forGeneration: gen) }
        }
    }

    func removeConfirmedAssets(_ assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }
        let ids = Set(assetIDs)
        consumedUploadIDs.formUnion(ids)
        generation += 1
        isLoadingMore = false
        removeSelectedAssets(assetIDs)
        let survivors = assets.filter { !ids.contains($0.id) }
        assets = []
        pagingNeedsRepair = true
        sections = []
        seenIds = []
        indexById = [:]
        sectionIndexByKey = [:]
        append(survivors, nextPage: 1)
        phase = assets.isEmpty ? .empty : .loaded
        yearGroups = []
        let gen = generation
        Task {
            guard let client else { return }
            let buckets = (try? await client.monthBuckets()) ?? []
            guard gen == generation else { return }
            yearGroups = Self.groupBuckets(buckets)
        }
    }

    /// Merge exact completion metadata into the loaded date window, without
    /// fetching timeline pages or moving navigation. Offset repair stays lazy.
    func mergeUploadedAssets(_ uploaded: [ImmichAsset] = []) async {
        guard let client, !pagingSuspended else { return }
        switch phase {
        case .loaded, .empty: await mergeCompletions(uploaded, client: client)
        default: return
        }
    }

    private func mergeCompletions(_ uploaded: [ImmichAsset], client: ImmichClient) async {
        generation += 1
        let gen = generation
        isLoadingMore = false
        let windowAnchor = anchor
        let oldestDate = assets.last?.fileCreatedAt
        let candidates = (uploaded + ((try? UploadActivity.completedAssets(client: client)) ?? []))
            .filter { !consumedUploadIDs.contains($0.id) }
        guard !candidates.isEmpty else { return }
        consumedUploadIDs.formUnion(candidates.map(\.id))
        let repairPage = nextPage.map { max(1, $0 - 1) }
            ?? max(1, (assets.count + Self.pageSize - 1) / Self.pageSize)
        var merged = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for asset in candidates {
            let date = asset.fileCreatedAt
            if let windowAnchor, let date, date >= windowAnchor { continue }
            if let oldestDate, let date, date < oldestDate { continue }
            merged[asset.id] = asset
        }
        let ordered = merged.values.sorted {
            let lhs = $0.fileCreatedAt ?? ""
            let rhs = $1.fileCreatedAt ?? ""
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        assets = []
        sections = []
        seenIds = []
        indexById = [:]
        sectionIndexByKey = [:]
        append(ordered, nextPage: repairPage)
        phase = assets.isEmpty ? .empty : .loaded
        let buckets = try? await client.monthBuckets()
        guard gen == generation else { return }
        if let buckets { yearGroups = Self.groupBuckets(buckets) }
    }

    func initialLoad() async {
        let loadGeneration = resetList(to: nil)
        self.client = nil
        guard let client = ImmichClient() else {
            guard loadGeneration == generation else { return }
            phase = .notConfigured
            return
        }
        self.client = client
        // The server load is authoritative for historical handoff records.
        // Capture before suspending so uploads completed during the load remain new.
        consumedUploadIDs = Set(((try? UploadActivity.completedAssets(client: client)) ?? []).map(\.id))
        guard loadGeneration == generation else { return }
        phase = .loading
        // The buckets feed only the jump menu — fetched alongside page 1, and a
        // failure just leaves the menu empty instead of failing the gallery.
        async let buckets = client.monthBuckets()
        await loadFirstPage(forGeneration: loadGeneration)
        let groups = Self.groupBuckets((try? await buckets) ?? [])
        guard loadGeneration == generation else { return }
        yearGroups = groups
        await mergeUploadedAssets()
    }

    /// Re-anchors the timeline at the given month ("2024-03"); nil returns to the
    /// latest photos. Loads a single page starting there — nothing in between.
    func jump(toMonth month: String?) async {
        guard client != nil else { return }
        let loadGeneration = resetList(
            to: month.map { ImmichClient.monthRange($0).before }
        )
        phase = .loading
        await loadFirstPage(forGeneration: loadGeneration)
    }


    /// Pagination trigger, called from every cell's `.onAppear`.
    func loadMoreIfNeeded(after asset: ImmichAsset) {
        guard !pagingSuspended, let page = nextPage,
              !isLoadingMore, triggerIds.contains(asset.id) else { return }
        isLoadingMore = true
        let gen = generation
        let anchor = anchor
        Task {
            defer { if gen == generation { isLoadingMore = false } }
            guard let client else { return }
            var candidate: Int? = page
            // Replaying offset pages after a deletion may contain only already
            // loaded rows. Continue until reaching new rows or the actual end.
            while let page = candidate, !pagingSuspended, gen == generation {
                do {
                    let result = try await client.assetsPage(
                        page: page, size: Self.pageSize, takenBefore: anchor)
                    guard gen == generation else { return }
                    let previousCount = assets.count
                    append(result.assets, nextPage: result.nextPage)
                    if assets.count > previousCount { return }
                    candidate = result.nextPage
                } catch {
                    return // Keep this page retryable; never advance on failure.
                }
            }
        }
    }

    func index(of asset: ImmichAsset) -> Int? { indexById[asset.id] }

    func isSelected(_ assetID: String) -> Bool {
        selectedAssetIDs.contains(assetID)
    }

    /// Toggles one loaded Asset or adds the inclusive loaded range from the current
    /// anchor. Shift-range selection never clears non-contiguous existing selection.
    func toggleSelection(of assetID: String, withShift: Bool) {
        guard let targetIndex = indexById[assetID] else { return }
        pendingSelectionIDs.remove(assetID)

        if withShift,
           let anchorID = selectionAnchorID,
           let anchorIndex = indexById[anchorID] {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedAssetIDs.formUnion(assets[range].map(\.id))
            return
        }

        if !selectedAssetIDs.insert(assetID).inserted {
            selectedAssetIDs.remove(assetID)
        }
        // A regular toggle establishes the next range anchor. A valid Shift
        // range keeps its existing anchor so repeated ranges remain predictable.
        selectionAnchorID = assetID
    }


    func clearSelection() {
        selectedAssetIDs.removeAll()
        pendingSelectionIDs.removeAll()

        selectionAnchorID = nil
    }

    /// Removes Assets that completed successfully while leaving failed and unfinished
    /// Assets selected for a retry.
    func removeSelectedAssets(_ assetIDs: [String]) {
        let ids = Set(assetIDs)
        selectedAssetIDs.subtract(ids)
        if let selectionAnchorID, ids.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        pendingSelectionIDs.subtract(ids)
    }

    /// Reconnects retryable Assets from a retained operation result. Only
    /// Assets already loaded into this timeline are selected immediately; later
    /// pages select matching IDs as they arrive.
    func restoreSelection(for assetIDs: [String]) {
        pendingSelectionIDs = Set(assetIDs)
        selectedAssetIDs.formUnion(
            assets.compactMap { pendingSelectionIDs.contains($0.id) ? $0.id : nil }
        )
    }

    private func loadFirstPage(forGeneration expectedGeneration: Int) async {
        guard expectedGeneration == generation, let client else { return }
        do {
            let page = try await client.assetsPage(page: 1, size: Self.pageSize,
                                                   takenBefore: anchor)
            guard expectedGeneration == generation else { return }
            append(page.assets, nextPage: page.nextPage)
            phase = assets.isEmpty ? .empty : .loaded
        } catch {
            guard expectedGeneration == generation else { return }
            phase = .error(error.localizedDescription)
        }
    }

    @discardableResult
    private func resetList(to newAnchor: String?) -> Int {
        generation += 1
        anchor = newAnchor
        selectedAssetIDs = []
        selectionAnchorID = nil
        pendingSelectionIDs = []

        assets = []
        sections = []
        seenIds = []
        triggerIds = []
        indexById = [:]
        sectionIndexByKey = [:]
        nextPage = 1
        isLoadingMore = false
        pagingNeedsRepair = false
        return generation
    }

    private func append(_ newAssets: [ImmichAsset], nextPage: Int?) {
        self.nextPage = nextPage
        for asset in newAssets {
            // A live library can shift page boundaries mid-scroll; a duplicate id
            // would crash ForEach, so drop repeats here.
            guard seenIds.insert(asset.id).inserted else { continue }
            indexById[asset.id] = assets.count
            if pendingSelectionIDs.contains(asset.id) {
                selectedAssetIDs.insert(asset.id)
            }
            assets.append(asset)
            let key = asset.fileCreatedAt.map { String($0.prefix(7)) } ?? "unknown"
            if let i = sectionIndexByKey[key] {
                sections[i].assets.append(asset)
            } else {
                sectionIndexByKey[key] = sections.count
                sections.append(Section(id: key, title: Self.monthTitle(key), assets: [asset]))
            }
        }
        triggerIds = Set(assets.suffix(Self.triggerWindow).map(\.id))
    }

    /// Buckets → years (newest first) with their months, for the jump menu.
    private static func groupBuckets(_ buckets: [ImmichTimeBucket]) -> [YearGroup] {
        var monthsByYear: [String: [MonthEntry]] = [:]
        for bucket in buckets {
            let key = String(bucket.timeBucket.prefix(7))
            guard key.count == 7 else { continue }
            let entry = MonthEntry(id: key, title: monthName(key), count: bucket.count)
            monthsByYear[String(key.prefix(4)), default: []].append(entry)
        }
        return monthsByYear.keys.sorted(by: >).map { year in
            YearGroup(id: year, months: monthsByYear[year]!.sorted { $0.id > $1.id })
        }
    }

    private static let monthKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let monthNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM"
        return f
    }()

    private static func monthTitle(_ key: String) -> String {
        guard let date = monthKeyFormatter.date(from: key) else { return "Unknown Date" }
        return monthTitleFormatter.string(from: date)
    }

    private static func monthName(_ key: String) -> String {
        guard let date = monthKeyFormatter.date(from: key) else { return key }
        return monthNameFormatter.string(from: date)
    }
}
