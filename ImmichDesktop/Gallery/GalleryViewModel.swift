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

    private var nextPage: Int? = 1
    private var seenIds = Set<String>()
    /// Ids of the trailing assets; a cell from this window appearing means the user
    /// is near the end of the loaded data and the next page should be fetched.
    private var triggerIds = Set<String>()
    private var indexById: [String: Int] = [:]
    private var sectionIndexByKey: [String: Int] = [:]
    private var client: ImmichClient?
    /// Bumped on every reset (initial load / jump) so an in-flight load-more task
    /// can detect it became stale and must not append to the new list.
    private var generation = 0

    private static let pageSize = 200
    private static let triggerWindow = 40

    func initialLoad() async {
        guard let client = ImmichClient() else {
            phase = .notConfigured
            return
        }
        self.client = client
        anchor = nil
        resetList()
        phase = .loading
        // The buckets feed only the jump menu — fetched alongside page 1, and a
        // failure just leaves the menu empty instead of failing the gallery.
        async let buckets = client.monthBuckets()
        await loadFirstPage()
        yearGroups = Self.groupBuckets((try? await buckets) ?? [])
    }

    /// Re-anchors the timeline at the given month ("2024-03"); nil returns to the
    /// latest photos. Loads a single page starting there — nothing in between.
    func jump(toMonth month: String?) async {
        guard client != nil else { return }
        anchor = month.map { ImmichClient.monthRange($0).before }
        resetList()
        phase = .loading
        await loadFirstPage()
    }

    /// Pagination trigger, called from every cell's `.onAppear`.
    func loadMoreIfNeeded(after asset: ImmichAsset) {
        guard let page = nextPage, !isLoadingMore, triggerIds.contains(asset.id) else { return }
        isLoadingMore = true
        let gen = generation
        let anchor = anchor
        Task {
            defer { if gen == generation { isLoadingMore = false } }
            guard let client else { return }
            // Errors keep `nextPage`, so continued scrolling simply retries.
            if let result = try? await client.assetsPage(page: page, size: Self.pageSize,
                                                         takenBefore: anchor),
               gen == generation {
                append(result.assets, nextPage: result.nextPage)
            }
        }
    }

    func index(of asset: ImmichAsset) -> Int? { indexById[asset.id] }

    private func loadFirstPage() async {
        guard let client else { return }
        do {
            let page = try await client.assetsPage(page: 1, size: Self.pageSize,
                                                   takenBefore: anchor)
            append(page.assets, nextPage: page.nextPage)
            phase = assets.isEmpty ? .empty : .loaded
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func resetList() {
        generation += 1
        assets = []
        sections = []
        seenIds = []
        triggerIds = []
        indexById = [:]
        sectionIndexByKey = [:]
        nextPage = 1
        isLoadingMore = false
    }

    private func append(_ newAssets: [ImmichAsset], nextPage: Int?) {
        self.nextPage = nextPage
        for asset in newAssets {
            // A live library can shift page boundaries mid-scroll; a duplicate id
            // would crash ForEach, so drop repeats here.
            guard seenIds.insert(asset.id).inserted else { continue }
            indexById[asset.id] = assets.count
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
