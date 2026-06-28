import FileProvider

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {

    required init(domain: NSFileProviderDomain) {
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
        case .album, .asset: staticFolder = nil
        }
        if let folder = staticFolder {
            completionHandler(folder, nil)
            progress.completedUnitCount = 1
            return progress
        }

        guard let client = ImmichClient() else {
            completionHandler(nil, NSFileProviderError(.notAuthenticated))
            return progress
        }

        Task {
            do {
                switch id.kind {
                case .album:
                    let detail = try await client.album(id: id.value)
                    let album = ImmichAlbum(id: detail.id,
                                            albumName: detail.albumName,
                                            assetCount: detail.assets.count)
                    completionHandler(FileProviderItem(album: album), nil)
                case .asset:
                    let asset = try await client.asset(id: id.value)
                    completionHandler(
                        FileProviderItem(asset: asset, parent: id.parent ?? .rootContainer), nil)
                default:
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
                progress.completedUnitCount = 1
            } catch {
                completionHandler(nil, error)
            }
        }
        return progress
    }

    // MARK: - Contents (on-demand download)

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let id = ItemID(itemIdentifier)

        guard id.kind == .asset, let client = ImmichClient() else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        Task {
            do {
                let url = try await client.downloadOriginal(id: id.value)
                let asset = try await client.asset(id: id.value)
                completionHandler(
                    url, FileProviderItem(asset: asset, parent: id.parent ?? .rootContainer), nil)
                progress.completedUnitCount = 1
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    // MARK: - Thumbnails (Finder preview)

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier],
                         requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        fpLog.info("fetchThumbnails: \(itemIdentifiers.count, privacy: .public) item(s)")
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        guard let client = ImmichClient() else {
            completionHandler(NSFileProviderError(.notAuthenticated))
            return progress
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for identifier in itemIdentifiers {
                    group.addTask {
                        let id = ItemID(identifier)
                        guard id.kind == .asset else {
                            perThumbnailCompletionHandler(identifier, nil, nil)
                            return
                        }
                        do {
                            let data = try await client.thumbnail(id: id.value)
                            perThumbnailCompletionHandler(identifier, data, nil)
                        } catch {
                            perThumbnailCompletionHandler(identifier, nil, error)
                        }
                    }
                }
            }
            progress.completedUnitCount = Int64(itemIdentifiers.count)
            completionHandler(nil)
        }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        fpLog.info("enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")
        guard let client = ImmichClient() else {
            fpLog.error("enumerator: notAuthenticated")
            throw NSFileProviderError(.notAuthenticated)
        }
        return ItemEnumerator(container: containerItemIdentifier, client: client)
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
