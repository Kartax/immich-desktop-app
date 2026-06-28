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

    // MARK: Ordner

    static let root = FileProviderItem(
        identifier: .rootContainer, parent: .rootContainer,
        filename: "Immich", contentType: .folder, isFolder: true, size: nil)

    static func timelineFolder() -> FileProviderItem {
        FileProviderItem(identifier: ItemID.timeline, parent: .rootContainer,
                         filename: "Alle Fotos", contentType: .folder, isFolder: true, size: nil)
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

    // MARK: Datei (Asset)

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
        // An Groesse + Name koppeln, damit Aenderungen (z. B. 0 -> echte Groesse)
        // sicher als Update erkannt werden statt aus dem Cache zu bleiben.
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
