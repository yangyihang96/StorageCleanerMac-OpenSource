import Foundation

/// Session-only disclosure shared by the list, search, bulk selection,
/// confirmations and report. Never a deletion identity or persisted setting.
struct BrowserPrivacyDisclosurePolicy: Equatable, Sendable {
    var sensitiveSites: Set<BrowserPrivacySiteID> = []
    var revealedSites: Set<BrowserPrivacySiteID> = []

    static func siteID(_ record: BrowserPrivacyRecord) -> BrowserPrivacySiteID {
        .init(profile: .init(browserID: record.browser.id, profileID: record.profileID),
              domain: record.domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    static func protecting(_ records: [BrowserPrivacyRecord]) -> Self {
        .init(sensitiveSites: Set(records.filter { BrowserPrivacyLightfieldPresentation.isSensitive($0.category) }.map(siteID)))
    }

    func isConcealed(_ record: BrowserPrivacyRecord) -> Bool {
        let site = Self.siteID(record)
        return (sensitiveSites.contains(site) || BrowserPrivacyLightfieldPresentation.isSensitive(record.category))
            && !revealedSites.contains(site)
    }

    func visibleRecords(_ records: [BrowserPrivacyRecord]) -> [BrowserPrivacyRecord] {
        records.filter { !isConcealed($0) }
    }

    func summary(_ records: [BrowserPrivacyRecord]) -> String {
        let concealed = records.count(where: isConcealed)
        let visible = records.count - concealed
        let parts = [visible > 0 ? BrowserPrivacyLightfieldPresentation.recordCount(visible) : nil,
                     concealed > 0 ? Self.sensitiveSummary(concealed) : nil].compactMap { $0 }
        return parts.isEmpty ? BrowserPrivacyLightfieldPresentation.recordCount(0) : parts.joined(separator: " · ")
    }

    static func sensitiveSummary(_ count: Int) -> String {
        L10n.text("敏感网站 · \(count) 条", "Sensitive websites · \(count) records")
    }
}

/// Receipts can contain legacy free-form detail. When a profile still has
/// concealed visits, use the structured reason, never that free-form text.
enum BrowserPrivacyReportDisclosurePresentation {
    static func records(_ entry: BrowserPrivacyProcessingEntry, from records: [BrowserPrivacyRecord]) -> [BrowserPrivacyRecord] {
        records.filter { $0.browser.id == entry.browser.id && $0.profileID == entry.profileID }
    }
    static func detail(_ entry: BrowserPrivacyProcessingEntry, records: [BrowserPrivacyRecord],
                       disclosure: BrowserPrivacyDisclosurePolicy) -> String {
        guard Self.records(entry, from: records).contains(where: disclosure.isConcealed) else { return entry.detail }
        return entry.reason?.detail(browserName: entry.browser.displayName)
            ?? L10n.text("敏感网站的处理详情已隐藏；展开后可审阅。", "Sensitive processing details are concealed; reveal to review.")
    }
    static func count(_ entry: BrowserPrivacyProcessingEntry, records: [BrowserPrivacyRecord],
                      disclosure: BrowserPrivacyDisclosurePolicy) -> String {
        let visits = Self.records(entry, from: records)
        return visits.contains(where: disclosure.isConcealed)
            ? BrowserPrivacyDisclosurePolicy.sensitiveSummary(entry.recordCount) : BrowserPrivacyCountText.visits(entry.recordCount)
    }
}
