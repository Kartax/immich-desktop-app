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
        // Working set / trash stay empty.
        if container == .workingSet || container == .trashContainer {
            observer.finishEnumerating(upTo: nil)
            return
        }

        Task {
            do {
                let id = ItemID(container)
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
                    let assets = try await client.assets(inAlbum: id.value)
                    observer.didEnumerate(assets.map {
                        FileProviderItem(asset: $0, parent: ItemID.album(id.value))
                    })

                case .persons:
                    let people = try await client.people()
                    observer.didEnumerate(people.map {
                        FileProviderItem.personFolder(id: $0.id, name: $0.name ?? "")
                    })

                case .person:
                    let assets = try await client.assets(forPerson: id.value)
                    observer.didEnumerate(assets.map {
                        FileProviderItem(asset: $0, parent: ItemID.person(id.value))
                    })

                case .places:
                    let cs = try await client.countries()
                    observer.didEnumerate(cs.map { FileProviderItem.countryFolder($0) })

                case .country:
                    let cities = try await client.cities(inCountry: id.value)
                    observer.didEnumerate(cities.map {
                        FileProviderItem.cityFolder(country: id.value, city: $0)
                    })

                case .city:
                    guard let (country, city) = id.cityComponents else {
                        observer.finishEnumerating(upTo: nil); return
                    }
                    let assets = try await client.assets(inCity: city, country: country)
                    let parentId = ItemID.city(country: country, city: city)
                    observer.didEnumerate(assets.map {
                        FileProviderItem(asset: $0, parent: parentId)
                    })

                case .asset:
                    break   // assets have no children
                }
                fpLog.info("enumerate \(self.container.rawValue, privacy: .public): OK")
                observer.finishEnumerating(upTo: nil)
            } catch {
                fpLog.error("enumerate \(self.container.rawValue, privacy: .public) ERROR: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }
}
