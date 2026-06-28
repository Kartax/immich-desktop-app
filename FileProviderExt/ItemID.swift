import FileProvider

/// Kodiert/dekodiert die Identitaet eines Items als NSFileProviderItemIdentifier.
///
/// Schema (Trenner "|"):
///   root                 -> NSFileProviderItemIdentifier.rootContainer
///   "Alle Fotos"         -> "timeline"
///   Jahr                 -> "year|2024"
///   Monat                -> "month|2024-03"
///   Album                -> "album|<albumId>"
///   Asset                -> "asset|<parentRaw>|<assetId>"  (Eltern-Identifier eingebettet,
///                            damit dasselbe Asset unter Album wie Monat existieren kann)
struct ItemID {
    enum Kind { case root, timeline, year, month, album, asset }

    let kind: Kind
    let value: String                              // Jahr, "YYYY-MM", albumId bzw. assetId
    let parent: NSFileProviderItemIdentifier?

    init(_ identifier: NSFileProviderItemIdentifier) {
        let raw = identifier.rawValue

        if identifier == .rootContainer || raw == "root" {
            kind = .root; value = ""; parent = nil
            return
        }

        // Asset zuerst: parentRaw kann selbst "|" enthalten, assetId (UUID) nicht.
        if raw.hasPrefix("asset|") {
            let rest = String(raw.dropFirst("asset|".count))   // "<parentRaw>|<assetId>"
            if let sep = rest.range(of: "|", options: .backwards) {
                kind = .asset
                value = String(rest[sep.upperBound...])
                let parentRaw = String(rest[rest.startIndex..<sep.lowerBound])
                parent = (parentRaw == "root")
                    ? .rootContainer
                    : NSFileProviderItemIdentifier(rawValue: parentRaw)
                return
            }
        }

        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "timeline":
            kind = .timeline; value = ""; parent = .rootContainer
        case "year" where parts.count >= 2:
            kind = .year; value = parts[1]; parent = ItemID.timeline
        case "month" where parts.count >= 2:
            kind = .month; value = parts[1]; parent = ItemID.year(String(parts[1].prefix(4)))
        case "album" where parts.count >= 2:
            kind = .album; value = parts[1]; parent = .rootContainer
        default:
            kind = .root; value = ""; parent = nil
        }
    }

    static let timeline = NSFileProviderItemIdentifier(rawValue: "timeline")

    static func year(_ year: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "year|\(year)")
    }

    static func month(_ month: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "month|\(month)")
    }

    static func album(_ id: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(rawValue: "album|\(id)")
    }

    static func asset(_ assetId: String,
                      parent: NSFileProviderItemIdentifier) -> NSFileProviderItemIdentifier {
        let parentRaw = (parent == .rootContainer) ? "root" : parent.rawValue
        return NSFileProviderItemIdentifier(rawValue: "asset|\(parentRaw)|\(assetId)")
    }
}
