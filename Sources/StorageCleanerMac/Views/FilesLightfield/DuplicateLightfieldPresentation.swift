import Foundation

/// One linear pass per presentation update. Lazy rows only perform dictionary
/// lookups; they never search the group again to decide which copy is kept.
struct DuplicateLightfieldPresentation {
    let keeperIDsByGroup: [String: String]
    let newestItemsByGroup: [String: StorageItem]
    let modifiedAtByItemID: [String: Date]
    let canKeepNewest: Bool

    static func make(
        groups: [DuplicateDisplayGroup], selectedIDs: Set<String>,
        preferredKeepers: [String: String] = [:], modifiedAt: [String: Date] = [:],
        now: Date = Date()
    ) -> Self {
        var keeperIDs: [String: String] = [:]
        var newestItems: [String: StorageItem] = [:]
        var dates: [String: Date] = [:]
        var allConfirmedDatesKnown = true
        for group in groups {
            var firstUnselected: String?
            var preferred: String?
            var newest: StorageItem?
            var newestDate: Date?
            for item in group.items {
                let date = modifiedAt[item.id] ?? item.modifiedAt
                if let date { dates[item.id] = date }
                guard item.status == .available else { continue }
                if !selectedIDs.contains(item.id) {
                    if firstUnselected == nil { firstUnselected = item.id }
                    if preferredKeepers[group.id] == item.id { preferred = item.id }
                }
                guard group.isContentConfirmed else { continue }
                guard let date, date.timeIntervalSinceReferenceDate.isFinite, date <= now else {
                    allConfirmedDatesKnown = false
                    continue
                }
                if let current = newest, let currentDate = newestDate {
                    if date > currentDate || (date == currentDate && item.path < current.path) {
                        newest = item; newestDate = date
                    }
                } else {
                    newest = item; newestDate = date
                }
            }
            keeperIDs[group.id] = preferred ?? firstUnselected
            if let newest { newestItems[group.id] = newest }
        }
        return Self(keeperIDsByGroup: keeperIDs, newestItemsByGroup: newestItems,
            modifiedAtByItemID: dates, canKeepNewest: allConfirmedDatesKnown && !newestItems.isEmpty)
    }
}
