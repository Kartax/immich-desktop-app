import Foundation
import FileProvider

final class ItemEnumerator: NSObject, NSFileProviderEnumerator {
    private static let fallbackSuggestedPageSize = 200
    private static let maximumPageSize = 1000

    private let container: NSFileProviderItemIdentifier
    private let client: ImmichClient
    private let taskLock = NSLock()
    private var activeTask: Task<Void, Never>?
    private var isInvalidated = false

    private struct PageRequest {
        let number: Int
        let size: Int
    }

    private struct PageToken {
        let number: Int
        let size: Int

        init(number: Int, size: Int) {
            self.number = number
            self.size = size
        }

        init?(data: Data) {
            guard let value = String(data: data, encoding: .utf8) else { return nil }
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  fields[0] == "immich", fields[1] == "3",
                  let number = Int(fields[2]), number >= 2,
                  let size = Int(fields[3]), (1...ItemEnumerator.maximumPageSize).contains(size)
            else { return nil }
            self.number = number
            self.size = size
        }

        var fileProviderPage: NSFileProviderPage {
            let data = Data("immich:3:\(number):\(size)".utf8)
            return NSFileProviderPage(rawValue: data)
        }
    }

    init(container: NSFileProviderItemIdentifier, client: ImmichClient) {
        self.container = container
        self.client = client
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
        // Working set / trash stay empty.
        if container == .workingSet || container == .trashContainer {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkCancellation()
                let id = ItemID(container)
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
                        let albums = try await client.albums()
                        items.append(contentsOf: albums.map { FileProviderItem(album: $0) })
                    }
                    try self.report(items, to: observer)

                case .timeline:
                    let buckets = try await client.monthBuckets()
                    let years = TimelineFormat.orderedDistinct(
                        buckets.map { String($0.timeBucket.prefix(4)) })
                    try self.report(years.map { FileProviderItem.yearFolder($0) }, to: observer)

                case .year:
                    let buckets = try await client.monthBuckets()
                    let months = TimelineFormat.orderedDistinct(
                        buckets.map { String($0.timeBucket.prefix(7)) }
                            .filter { $0.hasPrefix(id.value + "-") })
                    try self.report(months.map {
                        FileProviderItem.monthFolder(value: $0,
                                                     display: TimelineFormat.monthDisplay($0))
                    }, to: observer)

                case .month:
                    nextPage = try await self.enumerateAssets(
                        for: observer, startingAt: page, parent: ItemID.month(id.value)
                    ) { number, size in
                        try await self.client.assets(inMonth: id.value, page: number, size: size)
                    }

                case .album:
                    nextPage = try await self.enumerateAssets(
                        for: observer, startingAt: page, parent: ItemID.album(id.value)
                    ) { number, size in
                        try await self.client.assets(inAlbum: id.value, page: number, size: size)
                    }

                case .persons:
                    let people = try await client.people()
                    try self.report(people.map {
                        FileProviderItem.personFolder(id: $0.id, name: $0.name ?? "")
                    }, to: observer)

                case .person:
                    nextPage = try await self.enumerateAssets(
                        for: observer, startingAt: page, parent: ItemID.person(id.value)
                    ) { number, size in
                        try await self.client.assets(forPerson: id.value, page: number, size: size)
                    }

                case .places:
                    let cs = try await client.countries()
                    try self.report(cs.map { FileProviderItem.countryFolder($0) }, to: observer)

                case .country:
                    let cities = try await client.cities(inCountry: id.value)
                    try self.report(cities.map {
                        FileProviderItem.cityFolder(country: id.value, city: $0)
                    }, to: observer)

                case .city:
                    if let (country, city) = id.cityComponents {
                        let parentId = ItemID.city(country: country, city: city)
                        nextPage = try await self.enumerateAssets(
                            for: observer, startingAt: page, parent: parentId
                        ) { number, size in
                            try await self.client.assets(inCity: city, country: country,
                                                         page: number, size: size)
                        }
                    }

                case .asset:
                    break   // assets have no children
                }

                try self.checkCancellation()
                fpLog.info("enumerate \(self.container.rawValue, privacy: .public): OK, more=\(nextPage != nil, privacy: .public)")
                observer.finishEnumerating(upTo: nextPage)
            } catch {
                if self.wasCancelled(error) {
                    fpLog.info("enumerate \(self.container.rawValue, privacy: .public): cancelled")
                    return
                }
                fpLog.error("enumerate \(self.container.rawValue, privacy: .public) ERROR: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
        setActiveTask(task)
    }

    private func enumerateAssets(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage,
        parent: NSFileProviderItemIdentifier,
        load: (Int, Int) async throws -> ImmichClient.AssetPage
    ) async throws -> NSFileProviderPage? {
        let request = try Self.pageRequest(for: page,
                                           suggestedSize: observer.suggestedPageSize)
        try checkCancellation()
        let result = try await load(request.number, request.size)
        let items = result.assets.map { FileProviderItem(asset: $0, parent: parent) }
        try report(items, to: observer)
        fpLog.info("enumerate \(self.container.rawValue, privacy: .public) page \(request.number, privacy: .public): \(items.count, privacy: .public) item(s)")

        return result.nextPage.map {
            PageToken(number: $0, size: request.size).fileProviderPage
        }
    }

    private func report(_ items: [FileProviderItem],
                        to observer: NSFileProviderEnumerationObserver) throws {
        try checkCancellation()
        observer.didEnumerate(items)
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

    private static func pageRequest(for page: NSFileProviderPage,
                                    suggestedSize: Int?) throws -> PageRequest {
        if isInitialPage(page) {
            return PageRequest(number: 1, size: pageSize(forSuggestedSize: suggestedSize))
        }

        guard let token = PageToken(data: page.rawValue) else {
            throw NSFileProviderError(.pageExpired)
        }
        return PageRequest(number: token.number, size: token.size)
    }

    private static func pageSize(forSuggestedSize suggestedSize: Int?) -> Int {
        guard let suggestedSize, suggestedSize > 0 else {
            return fallbackSuggestedPageSize
        }
        return min(suggestedSize, maximumPageSize)
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
}
