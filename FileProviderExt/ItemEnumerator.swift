import FileProvider

final class ItemEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let client: ImmichClient

    init(container: NSFileProviderItemIdentifier, client: ImmichClient) {
        self.container = container
        self.client = client
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // Working Set / Trash bleiben leer.
        if container == .workingSet || container == .trashContainer {
            observer.finishEnumerating(upTo: nil)
            return
        }

        Task {
            do {
                let id = ItemID(container)
                switch id.kind {
                case .root:
                    var items: [FileProviderItem] = [FileProviderItem.timelineFolder()]
                    let albums = try await client.albums()
                    items.append(contentsOf: albums.map { FileProviderItem(album: $0) })
                    observer.didEnumerate(items)

                case .timeline:
                    let buckets = try await client.monthBuckets()
                    let years = TimelineFormat.orderedDistinct(
                        buckets.map { String($0.timeBucket.prefix(4)) })
                    observer.didEnumerate(years.map { FileProviderItem.yearFolder($0) })

                case .year:
                    let buckets = try await client.monthBuckets()
                    let months = TimelineFormat.orderedDistinct(
                        buckets.map { String($0.timeBucket.prefix(7)) }
                            .filter { $0.hasPrefix(id.value + "-") })
                    observer.didEnumerate(months.map {
                        FileProviderItem.monthFolder(value: $0,
                                                     display: TimelineFormat.monthDisplay($0))
                    })

                case .month:
                    let assets = try await client.assets(inMonth: id.value)
                    observer.didEnumerate(assets.map {
                        FileProviderItem(asset: $0, parent: ItemID.month(id.value))
                    })

                case .album:
                    let detail = try await client.album(id: id.value)
                    observer.didEnumerate(detail.assets.map {
                        FileProviderItem(asset: $0, parent: ItemID.album(detail.id))
                    })

                case .asset:
                    break   // Assets haben keine Kinder
                }
                fpLog.info("enumerate \(self.container.rawValue, privacy: .public): OK")
                observer.finishEnumerating(upTo: nil)
            } catch {
                fpLog.error("enumerate \(self.container.rawValue, privacy: .public) FEHLER: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }
}
