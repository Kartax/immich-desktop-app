import FileProvider

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    private static let maximumConcurrentThumbnailRequests = 8

    private let client: ImmichClient?
    private let metadataCache: AssetMetadataCache?

    required init(domain: NSFileProviderDomain) {
        let client = ImmichClient()
        self.client = client
        metadataCache = client.map { AssetMetadataCache.shared(for: $0) }
        super.init()
        fpLog.info("FileProviderExtension init for domain \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {}

    // MARK: - Metadata

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let client, let metadataCache else {
            completionHandler(nil, NSFileProviderError(.notAuthenticated))
            return progress
        }
        let task = Task {
            do {
                try await metadataCache.withRequest {
                    let item = try await self.loadItem(identifier, client: client, cache: metadataCache)
                    try await metadataCache.record([item], in: item.parentItemIdentifier)
                    try Task.checkCancellation()
                    completionHandler(item, nil)
                    progress.completedUnitCount = 1
                }
            } catch {
                completionHandler(nil, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private func loadItem(_ identifier: NSFileProviderItemIdentifier,
                          client: ImmichClient, cache: AssetMetadataCache) async throws -> FileProviderItem {
        let id = ItemID(identifier)
        switch id.kind {
        case .root: return .root
        case .timeline: return .timelineFolder()
        case .year: return .yearFolder(id.value)
        case .month:
            return .monthFolder(value: id.value, display: TimelineFormat.monthDisplay(id.value))
        case .persons: return .personsFolder()
        case .places: return .placesFolder()
        case .country: return .countryFolder(id.value)
        case .city:
            guard let parts = id.cityComponents else { throw NSFileProviderError(.noSuchItem) }
            return .cityFolder(country: parts.country, city: parts.city)
        case .groupedYear, .groupedMonth:
            guard let base = id.groupedBaseContainer else { throw NSFileProviderError(.noSuchItem) }
            try await ItemEnumerator(container: identifier, client: client, cache: cache)
                .validateGroupedContainer()
            return id.kind == .groupedYear
                ? .groupedYearFolder(base: base, year: id.value)
                : .groupedMonthFolder(base: base, month: id.value)
        case .album:
            return FileProviderItem(album: try await client.album(id: id.value))
        case .person:
            guard let person = try await client.people().first(where: { $0.id == id.value }) else {
                throw NSFileProviderError(.noSuchItem)
            }
            return .personFolder(id: person.id, name: person.name ?? "")
        case .asset:
            let parent = id.parent ?? .rootContainer
            let cacheParent = ItemID(parent).groupedBaseContainer ?? parent
            let mustVerify = try await cache.needsActiveVerification(assetID: id.value)
            if !mustVerify, let asset = try await cache.asset(
                id: id.value, parent: cacheParent, configurationVersion: client.configurationVersion) {
                return FileProviderItem(asset: asset, parent: parent)
            }
            return FileProviderItem(asset: try await loadActiveAsset(id.value, client: client, cache: cache), parent: parent)
        }
    }

    private func loadActiveAsset(_ id: String, client: ImmichClient,
                                 cache: AssetMetadataCache) async throws -> ImmichAsset {
        do {
            return try await client.activeAsset(id: id)
        } catch {
            // A generic missing/inaccessible response is not evidence of absence.
            // Only explicit server trash/deleted state maps to noSuchItem.
            if let urlError = error as? URLError, urlError.code == .resourceUnavailable,
               try await cache.needsActiveVerification(assetID: id) {
                let state = await client.deletionState(id: id)
                try await cache.validateRequest()
                if state == .deleted { throw NSFileProviderError(.noSuchItem) }
            }
            throw error
        }
    }

    // MARK: - Contents (on-demand download)

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let id = ItemID(itemIdentifier)
        guard id.kind == .asset, let client, let metadataCache else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        let task = Task {
            var downloadedURL: URL?
            do {
                try await metadataCache.withRequest {
                    let parent = id.parent ?? .rootContainer
                    let asset = try await self.loadActiveAsset(id.value, client: client, cache: metadataCache)
                    try await metadataCache.validateRequest()
                    let url = try await client.downloadOriginal(id: id.value)
                    downloadedURL = url
                    let item = FileProviderItem(asset: asset, parent: parent)
                    try await metadataCache.record([item], in: parent)
                    try Task.checkCancellation()
                    completionHandler(url, item, nil)
                    progress.completedUnitCount = 1
                }
            } catch {
                if let downloadedURL {
                    do { try FileManager.default.removeItem(at: downloadedURL) }
                    catch { fpLog.error("Discarding stale fetched content failed: \(error.localizedDescription, privacy: .public)") }
                }
                completionHandler(nil, nil, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Thumbnails (Finder preview)

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier],
                         requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        fpLog.info("fetchThumbnails: \(itemIdentifiers.count, privacy: .public) item(s)")
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        guard let client, let metadataCache else {
            completionHandler(NSFileProviderError(.notAuthenticated))
            return progress
        }
        let startedAt = Date()
        let task = Task {
            var startIndex = 0
            while startIndex < itemIdentifiers.count, !Task.isCancelled {
                let endIndex = min(startIndex + Self.maximumConcurrentThumbnailRequests,
                                   itemIdentifiers.count)
                let batch = itemIdentifiers[startIndex..<endIndex]
                await withTaskGroup(of: Void.self) { group in
                    for identifier in batch {
                        group.addTask {
                            let id = ItemID(identifier)
                            guard id.kind == .asset else {
                                if !Task.isCancelled {
                                    perThumbnailCompletionHandler(identifier, nil, nil)
                                }
                                return
                            }
                            do {
                                try await metadataCache.withRequest {
                                    let item = try await self.loadItem(
                                        identifier, client: client, cache: metadataCache)
                                    let data = try await client.thumbnail(id: id.value)
                                    try await metadataCache.record([item], in: item.parentItemIdentifier)
                                    if !Task.isCancelled {
                                        perThumbnailCompletionHandler(identifier, data, nil)
                                    }
                                }
                            } catch {
                                if !Task.isCancelled {
                                    perThumbnailCompletionHandler(identifier, nil, error)
                                }
                            }
                        }
                    }
                }
                if !Task.isCancelled {
                    progress.completedUnitCount += Int64(batch.count)
                }
                startIndex = endIndex
            }

            if Task.isCancelled {
                completionHandler(NSError(domain: NSCocoaErrorDomain,
                                          code: NSUserCancelledError))
            } else {
                completionHandler(nil)
            }
            fpLog.info(
                "fetchThumbnails: completed \(progress.completedUnitCount, privacy: .public)/\(progress.totalUnitCount, privacy: .public) in \(Date().timeIntervalSince(startedAt) * 1000, format: .fixed(precision: 1), privacy: .public) ms"
            )
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        fpLog.info("enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")
        guard let client, let metadataCache else {
            fpLog.error("enumerator: notAuthenticated")
            throw NSFileProviderError(.notAuthenticated)
        }
        return ItemEnumerator(container: containerItemIdentifier,
                              client: client, cache: metadataCache)
    }

    // MARK: - Write operations (unsupported, read-only)

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false,
                          NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false,
                          NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }
}
