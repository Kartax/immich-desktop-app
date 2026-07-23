import FileProvider
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    private let isFolder: Bool
    private let size: Int?

    private init(identifier: NSFileProviderItemIdentifier,
                 parent: NSFileProviderItemIdentifier,
                 filename: String,
                 contentType: UTType,
                 isFolder: Bool,
                 size: Int?) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = contentType
        self.isFolder = isFolder
        self.size = size
    }

    // MARK: Folders

    static let root = FileProviderItem(
        identifier: .rootContainer, parent: .rootContainer,
        filename: "Immich", contentType: .folder, isFolder: true, size: nil)

    static func timelineFolder() -> FileProviderItem {
        FileProviderItem(identifier: ItemID.timeline, parent: .rootContainer,
                         filename: "All Photos", contentType: .folder, isFolder: true, size: nil)
    }

    static func yearFolder(_ year: String) -> FileProviderItem {
        FileProviderItem(identifier: ItemID.year(year), parent: ItemID.timeline,
                         filename: year, contentType: .folder, isFolder: true, size: nil)
    }

    static func monthFolder(value: String, display: String) -> FileProviderItem {
        FileProviderItem(identifier: ItemID.month(value),
                         parent: ItemID.year(String(value.prefix(4))),
                         filename: display, contentType: .folder, isFolder: true, size: nil)
    }

    convenience init(album: ImmichAlbum) {
        self.init(identifier: ItemID.album(album.id), parent: .rootContainer,
                  filename: FileProviderItem.sanitize(album.albumName),
                  contentType: .folder, isFolder: true, size: nil)
    }

    static func personsFolder() -> FileProviderItem {
        FileProviderItem(identifier: ItemID.persons, parent: .rootContainer,
                         filename: "Persons", contentType: .folder, isFolder: true, size: nil)
    }

    static func personFolder(id: String, name: String) -> FileProviderItem {
        FileProviderItem(identifier: ItemID.person(id), parent: ItemID.persons,
                         filename: sanitize(name), contentType: .folder, isFolder: true, size: nil)
    }

    static func placesFolder() -> FileProviderItem {
        FileProviderItem(identifier: ItemID.places, parent: .rootContainer,
                         filename: "Places", contentType: .folder, isFolder: true, size: nil)
    }

    static func countryFolder(_ country: String) -> FileProviderItem {
        FileProviderItem(identifier: ItemID.country(country), parent: ItemID.places,
                         filename: sanitize(country), contentType: .folder, isFolder: true, size: nil)
    }

    static func cityFolder(country: String, city: String) -> FileProviderItem {
        FileProviderItem(identifier: ItemID.city(country: country, city: city),
                         parent: ItemID.country(country),
                         filename: sanitize(city), contentType: .folder, isFolder: true, size: nil)
    }

    static func groupedYearFolder(
        base: NSFileProviderItemIdentifier,
        year: String
    ) -> FileProviderItem {
        FileProviderItem(
            identifier: ItemID.groupedYear(base: base, year: year),
            parent: base,
            filename: year == "unknown" ? "Unknown Date" : year,
            contentType: .folder,
            isFolder: true,
            size: nil)
    }

    static func groupedMonthFolder(
        base: NSFileProviderItemIdentifier,
        month: String
    ) -> FileProviderItem {
        let year = month == "unknown" ? "unknown" : String(month.prefix(4))
        return FileProviderItem(
            identifier: ItemID.groupedMonth(base: base, month: month),
            parent: ItemID.groupedYear(base: base, year: year),
            filename: month == "unknown"
                ? "Unknown Date"
                : TimelineFormat.monthDisplay(month),
            contentType: .folder,
            isFolder: true,
            size: nil)
    }

    // MARK: File (asset)

    convenience init(asset: ImmichAsset, parent: NSFileProviderItemIdentifier) {
        let ext = (asset.originalFileName as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        self.init(identifier: ItemID.asset(asset.id, parent: parent), parent: parent,
                  filename: FileProviderItem.sanitize(asset.originalFileName),
                  contentType: type, isFolder: false, size: asset.exifInfo?.fileSizeInByte)
    }

    // MARK: NSFileProviderItem

    var capabilities: NSFileProviderItemCapabilities {
        isFolder ? [.allowsContentEnumerating] : [.allowsReading]
    }

    var itemVersion: NSFileProviderItemVersion {
        // Tie to size + name so changes (e.g. 0 -> real size) are reliably detected
        // as an update instead of being served from the cache.
        let token = Data("\(size ?? 0)|\(filename)".utf8)
        return NSFileProviderItemVersion(contentVersion: token, metadataVersion: token)
    }

    var documentSize: NSNumber? {
        size.map { NSNumber(value: $0) }
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
    }
}
