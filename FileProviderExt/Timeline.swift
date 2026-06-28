import Foundation

/// Hilfsfunktionen fuer die Zeit-Ansicht (Alle Fotos -> Jahr -> Monat).
enum TimelineFormat {
    private static let monthNames = [
        "Januar", "Februar", "März", "April", "Mai", "Juni",
        "Juli", "August", "September", "Oktober", "November", "Dezember",
    ]

    /// "2024-03" -> "03 März" (fuehrende Zahl haelt die Finder-Sortierung chronologisch).
    static func monthDisplay(_ month: String) -> String {
        let mm = String(month.suffix(2))
        if let i = Int(mm), (1...12).contains(i) {
            return "\(mm) \(monthNames[i - 1])"
        }
        return month
    }

    /// Eindeutige Werte unter Beibehaltung der Eingabereihenfolge.
    static func orderedDistinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in values where seen.insert(v).inserted { out.append(v) }
        return out
    }
}
