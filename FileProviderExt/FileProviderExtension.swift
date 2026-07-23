import FileProvider

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    private static let maximumConcurrentThumbnailRequests = 8

    private let client: ImmichClient?
    private let metadataCache = AssetMetadataCache.shared

    required init(domain: NSFileProviderDomain) {
        client = ImmichClient()
        super.init()
        fpLog.info("FileProviderExtension init for domain \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {}

    // MARK: - Metadata

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let id = ItemID(identifier)

        // Answer folders directly without network access.
        let staticFolder: FileProviderItem?
        switch id.kind {
        case .root:     staticFolder = FileProviderItem.root
        case .timeline: staticFolder = FileProviderItem.timelineFolder()
        case .year:     staticFolder = FileProviderItem.yearFolder(id.value)
        case .month:    staticFolder = FileProviderItem.monthFolder(
                            value: id.value, display: TimelineFormat.monthDisplay(id.value))
        case .persons:  staticFolder = FileProviderItem.personsFolder()
        case .places:   staticFolder = FileProviderItem.placesFolder()
        case .country:  staticFolder = FileProviderItem.countryFolder(id.value)
        case .city:     staticFolder = id.cityComponents.map {
                            FileProviderItem.cityFolder(country: $0.country, city: $0.city)
                        }
        case .groupedYear:
            staticFolder = id.groupedBaseContainer.map {
                FileProviderItem.groupedYearFolder(base: $0, year: id.value)
            }
        case .groupedMonth:
            staticFolder = id.groupedBaseContainer.map {
                FileProviderItem.groupedMonthFolder(base: $0, month: id.value)
            }
        case .album, .asset, .person: staticFolder = nil
        }
        if let folder = staticFolder {
            completionHandler(folder, nil)
            progress.completedUnitCount = 1
            return progress
        }

        guard let client else {
            completionHandler(nil, NSFileProviderError(.notAuthenticated))
            return progress
        }

        let startedAt = Date()
        let task = Task {
            do {
                switch id.kind {
                case .album:
                    let album = try await client.album(id: id.value)
                    completionHandler(FileProviderItem(album: album), nil)
                case .asset:
                    let itemParent = id.parent ?? .rootContainer
                    let cacheParent =
                        ItemID(itemParent).groupedBaseContainer ?? itemParent
                    let cached = await self.metadataCache.asset(
                        id: id.value,
                        parent: cacheParent,
                        configurationVersion: client.configurationVersion)
                    let asset: ImmichAsset
                    if let cached {
                        asset = cached
                    } else {
                        asset = try await client.asset(id: id.value)
                    }
                    fpLog.debug(
                        "item(for:) asset cacheHit=\(cached != nil, privacy: .public)"
                    )
                    completionHandler(
                        FileProviderItem(asset: asset, parent: itemParent), nil)
                case .person:
                    let people = try await client.people()
                    if let match = people.first(where: { $0.id == id.value }) {
                        completionHandler(
                            FileProviderItem.personFolder(id: match.id, name: match.name ?? ""), nil)
                    } else {
                        completionHandler(nil, NSFileProviderError(.noSuchItem))
                    }
                default:
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
                progress.completedUnitCount = 1
                fpLog.debug(
                    "item(for:) \(identifier.rawValue, privacy: .public) elapsedMs=\(Date().timeIntervalSince(startedAt) * 1000, format: .fixed(precision: 1), privacy: .public)"
                )
            } catch {
                completionHandler(nil, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Contents (on-demand download)

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let id = ItemID(itemIdentifier)

        guard id.kind == .asset, let client else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let task = Task {
            do {
                let url = try await client.downloadOriginal(id: id.value)
                let itemParent = id.parent ?? .rootContainer
                let cacheParent =
                    ItemID(itemParent).groupedBaseContainer ?? itemParent
                let cached = await self.metadataCache.asset(
                    id: id.value,
                    parent: cacheParent,
                    configurationVersion: client.configurationVersion)
                let asset: ImmichAsset
                if let cached {
                    asset = cached
                } else {
                    asset = try await client.asset(id: id.value)
                }
                completionHandler(
                    url, FileProviderItem(asset: asset, parent: itemParent), nil)
                progress.completedUnitCount = 1
            } catch {
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
        guard let client else {
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
                                let data = try await client.thumbnail(id: id.value)
                                if !Task.isCancelled {
                                    perThumbnailCompletionHandler(identifier, data, nil)
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
        guard let client else {
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
