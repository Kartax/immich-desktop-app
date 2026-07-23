import FileProvider
import Foundation

final class ItemEnumerator: NSObject, NSFileProviderEnumerator {
    private static let fallbackSuggestedPageSize = 200
    private static let maximumServerPageSize = 1000
    private static let maximumLocallySortedItems = 10_000
    private static let maximumSpeculativeNamePages = 5
    private static let freshSnapshotLifetime: TimeInterval = 5 * 60

    private let container: NSFileProviderItemIdentifier
    private let client: ImmichClient
    private let cache: AssetMetadataCache
    private let taskLock = NSLock()
    private var activeTask: Task<Void, Never>?
    private var isInvalidated = false

    private enum PageSource: String {
        case server = "s"
        case cache = "c"
    }

    private enum RequestedSort: String {
        case name = "n"
        case date = "d"
    }

    private struct PageRequest {
        let source: PageSource
        let position: Int
        let size: Int
        let sort: RequestedSort
        let generation: String
    }

    /// v4 token: immich:4:<s|c>:<server-page|offset>:<size>:<n|d>:<generation>
    private struct PageToken {
        let request: PageRequest

        init(request: PageRequest) {
            self.request = request
        }

        init?(data: Data) {
            guard let value = String(data: data, encoding: .utf8) else { return nil }
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 7,
                  fields[0] == "immich", fields[1] == "4",
                  let source = PageSource(rawValue: String(fields[2])),
                  let position = Int(fields[3]), position >= 1,
                  let size = Int(fields[4]),
                  (1...ItemEnumerator.maximumServerPageSize).contains(size),
                  let sort = RequestedSort(rawValue: String(fields[5])),
                  !fields[6].isEmpty else {
                return nil
            }
            request = PageRequest(source: source, position: position, size: size,
                                  sort: sort, generation: String(fields[6]))
        }

        var fileProviderPage: NSFileProviderPage {
            let value = "immich:4:\(request.source.rawValue):\(request.position):\(request.size):\(request.sort.rawValue):\(request.generation)"
            return NSFileProviderPage(rawValue: Data(value.utf8))
        }
    }

    init(container: NSFileProviderItemIdentifier,
         client: ImmichClient,
         cache: AssetMetadataCache = .shared) {
        self.container = container
        self.client = client
        self.cache = cache
    }

    func invalidate() {
        taskLock.lock()
        isInvalidated = true
        let task = activeTask
        activeTask = nil
        taskLock.unlock()
        task?.cancel()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // The working set is driven by change enumeration below. Trash is unsupported.
        if container == .workingSet || container == .trashContainer {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let startedAt = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkCancellation()
                let id = ItemID(self.container)
                if !Self.supportsPaging(id.kind), !Self.isInitialPage(page) {
                    throw NSFileProviderError(.pageExpired)
                }

                var nextPage: NSFileProviderPage?
                switch id.kind {
                case .root:
                    var items: [FileProviderItem] = []
                    if AppConfig.showTimeline { items.append(.timelineFolder()) }
                    if AppConfig.showPersons  { items.append(.personsFolder()) }
                    if AppConfig.showPlaces   { items.append(.placesFolder()) }
                    if AppConfig.showAlbums {
                        let albums = try await self.client.albums()
                        items.append(contentsOf: albums.map { FileProviderItem(album: $0) })
                    }
                    try self.report(items, to: observer)

                case .timeline:
                    let buckets = try await self.client.monthBuckets()
                    let years = TimelineFormat.orderedDistinct(
                        buckets.map { String($0.timeBucket.prefix(4)) })
                    try self.report(
                        years.map { FileProviderItem.yearFolder($0) }, to: observer)

                case .year:
                    let buckets = try await self.client.monthBuckets()
                    let months = TimelineFormat.orderedDistinct(
                        buckets.map { String($0.timeBucket.prefix(7)) }
                            .filter { $0.hasPrefix(id.value + "-") })
                    try self.report(months.map {
                        FileProviderItem.monthFolder(
                            value: $0, display: TimelineFormat.monthDisplay($0))
                    }, to: observer)

                case .month:
                    nextPage = try await self.enumerateAssets(
                        for: observer, startingAt: page, parent: ItemID.month(id.value)
                    ) { number, size in
                        try await self.client.assets(
                            inMonth: id.value, page: number, size: size)
                    }

                case .album:
                    nextPage = try await self.enumerateAssets(
                        for: observer, startingAt: page, parent: ItemID.album(id.value)
                    ) { number, size in
                        try await self.client.assets(
                            inAlbum: id.value, page: number, size: size)
                    }

                case .persons:
                    let people = try await self.client.people()
                    try self.report(people.map {
                        FileProviderItem.personFolder(id: $0.id, name: $0.name ?? "")
                    }, to: observer)

                case .person:
                    nextPage = try await self.enumerateAssets(
                        for: observer, startingAt: page, parent: ItemID.person(id.value)
                    ) { number, size in
                        try await self.client.assets(
                            forPerson: id.value, page: number, size: size)
                    }

                case .places:
                    let countries = try await self.client.countries()
                    try self.report(
                        countries.map { FileProviderItem.countryFolder($0) }, to: observer)

                case .country:
                    let cities = try await self.client.cities(inCountry: id.value)
                    try self.report(cities.map {
                        FileProviderItem.cityFolder(country: id.value, city: $0)
                    }, to: observer)

                case .city:
                    if let (country, city) = id.cityComponents {
                        let parent = ItemID.city(country: country, city: city)
                        nextPage = try await self.enumerateAssets(
                            for: observer, startingAt: page, parent: parent
                        ) { number, size in
                            try await self.client.assets(
                                inCity: city, country: country,
                                page: number, size: size)
                        }
                    }

                case .asset:
                    break
                }

                try self.checkCancellation()
                let elapsed = Date().timeIntervalSince(startedAt) * 1000
                fpLog.info(
                    "enumerate \(self.container.rawValue, privacy: .public): OK, more=\(nextPage != nil, privacy: .public), elapsedMs=\(elapsed, format: .fixed(precision: 1), privacy: .public)"
                )
                observer.finishEnumerating(upTo: nextPage)
            } catch {
                if self.wasCancelled(error) {
                    fpLog.info(
                        "enumerate \(self.container.rawValue, privacy: .public): cancelled")
                    return
                }
                fpLog.error(
                    "enumerate \(self.container.rawValue, privacy: .public) ERROR: \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(error)
            }
        }
        setActiveTask(task)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkCancellation()
                guard let sequence = Self.sequence(from: anchor) else {
                    throw NSFileProviderError(.syncAnchorExpired)
                }
                let maximumCount = Self.batchSize(
                    forSuggestedSize: observer.suggestedBatchSize)
                let changes = await self.cache.changes(
                    after: sequence,
                    for: self.container,
                    maximumCount: maximumCount,
                    configurationVersion: self.client.configurationVersion)
                guard !changes.anchorExpired else {
                    throw NSFileProviderError(.syncAnchorExpired)
                }

                if !changes.updates.isEmpty {
                    observer.didUpdate(changes.updates.map {
                        FileProviderItem(asset: $0.asset, parent: $0.parent)
                    })
                }
                if !changes.deletedIdentifiers.isEmpty {
                    observer.didDeleteItems(
                        withIdentifiers: changes.deletedIdentifiers)
                }
                fpLog.debug(
                    "enumerateChanges \(self.container.rawValue, privacy: .public): updates=\(changes.updates.count, privacy: .public), deletes=\(changes.deletedIdentifiers.count, privacy: .public), more=\(changes.moreComing, privacy: .public)"
                )
                observer.finishEnumeratingChanges(
                    upTo: Self.syncAnchor(changes.anchor),
                    moreComing: changes.moreComing)
            } catch {
                if self.wasCancelled(error) { return }
                observer.finishEnumeratingWithError(error)
            }
        }
        setActiveTask(task)
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        Task { [cache, configurationVersion = client.configurationVersion] in
            let sequence = await cache.currentChangeSequence(
                configurationVersion: configurationVersion)
            completionHandler(Self.syncAnchor(sequence))
        }
    }

    private func enumerateAssets(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage,
        parent: NSFileProviderItemIdentifier,
        load: (Int, Int) async throws -> ImmichClient.AssetPage
    ) async throws -> NSFileProviderPage? {
        let request: PageRequest
        if Self.isInitialPage(page) {
            let sort = try Self.requestedSort(for: page)
            let size = Self.pageSize(forSuggestedSize: observer.suggestedPageSize)
            fpLog.info(
                "enumerate \(self.container.rawValue, privacy: .public): initial sort=\(sort.rawValue, privacy: .public), suggested=\(observer.suggestedPageSize ?? 0, privacy: .public), selected=\(size, privacy: .public)"
            )

            if let snapshot = await cache.freshSnapshot(
                for: parent,
                configurationVersion: client.configurationVersion,
                maximumAge: Self.freshSnapshotLifetime
            ) {
                fpLog.info(
                    "enumerate \(self.container.rawValue, privacy: .public): fresh metadata cache hit (\(snapshot.assets.count, privacy: .public) items)"
                )
                return try reportCached(
                    snapshot, offset: 0, size: size, sort: sort, to: observer)
            }

            request = PageRequest(
                source: .server, position: 1, size: size, sort: sort,
                generation: UUID().uuidString)
        } else {
            guard let token = PageToken(data: page.rawValue) else {
                throw NSFileProviderError(.pageExpired)
            }
            request = token.request
        }

        if request.source == .cache {
            guard let snapshot = await cache.snapshot(
                for: parent,
                generation: request.generation,
                configurationVersion: client.configurationVersion
            ) else {
                throw NSFileProviderError(.pageExpired)
            }
            return try reportCached(
                snapshot, offset: request.position, size: request.size,
                sort: request.sort, to: observer)
        }

        try checkCancellation()
        let result = try await load(request.position, request.size)

        if request.position == 1, request.sort == .name,
           Self.shouldBuildNameSnapshot(from: result) {
            if let snapshot = try await buildNameSortedSnapshot(
                firstPage: result, pageSize: request.size, parent: parent,
                generation: request.generation, load: load
            ) {
                return try reportCached(
                    snapshot, offset: 0, size: request.size,
                    sort: .name, to: observer)
            }
        }

        await cache.append(
            result.assets,
            pageNumber: request.position,
            finalPage: result.nextPage == nil,
            for: parent,
            generation: request.generation,
            configurationVersion: client.configurationVersion)
        let items = result.assets.map { FileProviderItem(asset: $0, parent: parent) }
        try report(items, to: observer)
        fpLog.info(
            "enumerate \(self.container.rawValue, privacy: .public) server page \(request.position, privacy: .public): \(items.count, privacy: .public) item(s)"
        )

        return result.nextPage.map {
            PageToken(request: PageRequest(
                source: .server, position: $0, size: request.size,
                sort: request.sort, generation: request.generation)).fileProviderPage
        }
    }

    private func buildNameSortedSnapshot(
        firstPage: ImmichClient.AssetPage,
        pageSize: Int,
        parent: NSFileProviderItemIdentifier,
        generation: String,
        load: (Int, Int) async throws -> ImmichClient.AssetPage
    ) async throws -> AssetMetadataCache.CachedSnapshot? {
        var allAssets: [ImmichAsset] = []
        var knownIDs = Set<String>()
        allAssets.append(contentsOf: firstPage.assets.filter {
            knownIDs.insert($0.id).inserted
        })
        var nextPage = firstPage.nextPage
        var fetchedPages = 1

        while let page = nextPage {
            if firstPage.total == nil,
               fetchedPages >= Self.maximumSpeculativeNamePages {
                fpLog.info(
                    "enumerate \(self.container.rawValue, privacy: .public): name snapshot abandoned because total is unavailable"
                )
                return nil
            }
            try checkCancellation()
            let result = try await load(page, pageSize)
            allAssets.append(contentsOf: result.assets.filter {
                knownIDs.insert($0.id).inserted
            })
            if allAssets.count > Self.maximumLocallySortedItems {
                fpLog.info(
                    "enumerate \(self.container.rawValue, privacy: .public): name snapshot exceeds \(Self.maximumLocallySortedItems, privacy: .public) items"
                )
                return nil
            }
            nextPage = result.nextPage
            fetchedPages += 1
        }

        let sorted = Self.ordered(allAssets, by: .name)
        await cache.publish(
            sorted,
            for: parent,
            generation: generation,
            configurationVersion: client.configurationVersion)
        fpLog.info(
            "enumerate \(self.container.rawValue, privacy: .public): built name-sorted snapshot with \(sorted.count, privacy: .public) items in \(fetchedPages, privacy: .public) server page(s)"
        )
        return AssetMetadataCache.CachedSnapshot(
            generation: generation, createdAt: Date(), assets: sorted)
    }

    private func reportCached(
        _ snapshot: AssetMetadataCache.CachedSnapshot,
        offset: Int,
        size: Int,
        sort: RequestedSort,
        to observer: NSFileProviderEnumerationObserver
    ) throws -> NSFileProviderPage? {
        let assets = Self.ordered(snapshot.assets, by: sort)
        guard offset >= 0, offset <= assets.count else {
            throw NSFileProviderError(.pageExpired)
        }
        let end = min(offset + size, assets.count)
        let items = assets[offset..<end].map {
            FileProviderItem(asset: $0, parent: self.container)
        }
        try report(items, to: observer)
        fpLog.info(
            "enumerate \(self.container.rawValue, privacy: .public) cache offset \(offset, privacy: .public): \(items.count, privacy: .public) item(s)"
        )

        guard end < assets.count else { return nil }
        return PageToken(request: PageRequest(
            source: .cache, position: end, size: size, sort: sort,
            generation: snapshot.generation)).fileProviderPage
    }

    private func report(_ items: [FileProviderItem],
                        to observer: NSFileProviderEnumerationObserver) throws {
        try checkCancellation()
        let startedAt = Date()
        observer.didEnumerate(items)
        let elapsed = Date().timeIntervalSince(startedAt) * 1000
        fpLog.debug(
            "didEnumerate \(items.count, privacy: .public) item(s): dispatchMs=\(elapsed, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    private func setActiveTask(_ task: Task<Void, Never>) {
        taskLock.lock()
        let previousTask = activeTask
        let shouldCancel = isInvalidated
        if !shouldCancel {
            activeTask = task
        }
        taskLock.unlock()

        previousTask?.cancel()
        if shouldCancel { task.cancel() }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        taskLock.lock()
        let invalidated = isInvalidated
        taskLock.unlock()
        if invalidated { throw CancellationError() }
    }

    private func wasCancelled(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        taskLock.lock()
        let invalidated = isInvalidated
        taskLock.unlock()
        return invalidated
    }

    private static func requestedSort(for page: NSFileProviderPage) throws -> RequestedSort {
        if page.rawValue == (NSFileProviderPage.initialPageSortedByName as Data) {
            return .name
        }
        if page.rawValue == (NSFileProviderPage.initialPageSortedByDate as Data) {
            return .date
        }
        throw NSFileProviderError(.pageExpired)
    }

    private static func pageSize(forSuggestedSize suggestedSize: Int?) -> Int {
        let suggested = max(suggestedSize ?? fallbackSuggestedPageSize, 1)
        let enforcedMaximum = suggested > Int.max / 100 ? Int.max : suggested * 100
        return min(maximumServerPageSize, enforcedMaximum)
    }

    private static func batchSize(forSuggestedSize suggestedSize: Int?) -> Int {
        let suggested = max(suggestedSize ?? fallbackSuggestedPageSize, 1)
        let enforcedMaximum = suggested > Int.max / 100 ? Int.max : suggested * 100
        return min(max(suggested, fallbackSuggestedPageSize),
                   min(maximumServerPageSize, enforcedMaximum))
    }

    private static func shouldBuildNameSnapshot(
        from page: ImmichClient.AssetPage
    ) -> Bool {
        guard let total = page.total else {
            return page.nextPage == nil || page.assets.count <= maximumLocallySortedItems
        }
        return total <= maximumLocallySortedItems
    }

    private static func ordered(
        _ assets: [ImmichAsset],
        by sort: RequestedSort
    ) -> [ImmichAsset] {
        switch sort {
        case .name:
            guard assets.count <= maximumLocallySortedItems else { return assets }
            return assets.sorted {
                let comparison = $0.originalFileName.localizedStandardCompare(
                    $1.originalFileName)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
        case .date:
            return assets.sorted {
                let lhsDate = $0.fileCreatedAt ?? ""
                let rhsDate = $1.fileCreatedAt ?? ""
                return lhsDate == rhsDate ? $0.id < $1.id : lhsDate > rhsDate
            }
        }
    }

    private static func isInitialPage(_ page: NSFileProviderPage) -> Bool {
        page.rawValue == (NSFileProviderPage.initialPageSortedByName as Data)
            || page.rawValue == (NSFileProviderPage.initialPageSortedByDate as Data)
    }

    private static func supportsPaging(_ kind: ItemID.Kind) -> Bool {
        switch kind {
        case .month, .album, .person, .city:
            return true
        default:
            return false
        }
    }

    private static func syncAnchor(_ sequence: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("immich-sync:1:\(sequence)".utf8))
    }

    private static func sequence(from anchor: NSFileProviderSyncAnchor) -> Int64? {
        guard let value = String(data: anchor.rawValue, encoding: .utf8) else {
            return nil
        }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == "immich-sync", fields[1] == "1",
              let sequence = Int64(fields[2]), sequence >= 0 else {
            return nil
        }
        return sequence
    }
}
