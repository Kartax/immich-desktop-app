import FileProvider
import UniformTypeIdentifiers

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

    // MARK: - Uploads (All Photos only)

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        progress.kind = .file
        progress.setUserInfoObject(Progress.FileOperationKind.uploading, forKey: .fileOperationKindKey)
        guard let client, let metadataCache else {
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
            return progress
        }
        let task = Task {
            do {
                try Task.checkCancellation()
                guard itemTemplate.parentItemIdentifier == ItemID.timeline else {
                    throw Self.uploadRefusal("Files can only be added to All Photos.")
                }
                guard let url,
                      itemTemplate.contentType?.conforms(to: .folder) != true,
                      itemTemplate.contentType?.conforms(to: .symbolicLink) != true,
                      itemTemplate.contentType?.conforms(to: .aliasFile) != true,
                      itemTemplate.symlinkTargetPath == nil else {
                    throw Self.uploadRefusal("Only standalone image and video files can be uploaded; folders, aliases and symbolic links are not supported.")
                }
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey
                ])
                guard values.isRegularFile == true, values.isDirectory != true,
                      values.isSymbolicLink != true, values.isAliasFile != true else {
                    throw Self.uploadRefusal("Only standalone media files can be uploaded.")
                }
                let lease = try UploadActivity.begin(client: client)
                defer { lease.finish() }
                let result: AssetUploadResult
                var retryDelay: UInt64 = 1_000_000_000
                while true {
                    try Task.checkCancellation()
                    do {
                        result = try await metadataCache.withRequest {
                            try await metadataCache.validateRequest()
                            return try await client.uploadFile(at: url, filename: itemTemplate.filename,
                                                               progress: progress)
                        }
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard ImmichClient.isTransientUploadError(error) else { throw error }
                        // Keep both the cross-process lease and macOS-owned
                        // source until success or cancellation. Backoff is capped,
                        // not persisted; uncertain attempts deduplicate by checksum.
                        try await Task.sleep(nanoseconds: retryDelay)
                        retryDelay = min(retryDelay * 2, 30_000_000_000)
                    }
                }
                // Reconcile the cross-process revision in a new cache request;
                // publishing it inside the old request would cross its epoch.
                UploadActivity.recordCompletion(client: client, asset: result.asset)
                let item = try await metadataCache.withRequest {
                    try await metadataCache.recordUpload(result.asset)
                }
                try Task.checkCancellation()
                // The canonical name/parent replace the entry-point template.
                // Duplicate identity also replaces any existing local occurrence;
                // fetch its canonical original rather than assume local content.
                completionHandler(item, [], result.alreadyExisted, nil)
            } catch {
                completionHandler(nil, [], false, Self.nativeUploadError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private static func uploadRefusal(_ message: String) -> NSError {
        NSError(domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.Code.cannotSynchronize.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func nativeUploadError(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        }
        if ImmichClient.isTransientUploadError(error) {
            return NSError(domain: NSFileProviderErrorDomain,
                           code: NSFileProviderError.Code.serverUnreachable.rawValue,
                           userInfo: [NSLocalizedDescriptionKey: "The server is temporarily unavailable. Finder will retry the upload.",
                                      NSUnderlyingErrorKey: error])
        }
        if case AssetUploadError.rejected(let status, _) = error,
           status == 401 || status == 403 {
            return NSFileProviderError(.notAuthenticated)
        }
        let native = error as NSError
        if native.domain == NSFileProviderErrorDomain { return native }
        return uploadRefusal(error.localizedDescription)
    }

    // Existing assets remain immutable from Finder.

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
