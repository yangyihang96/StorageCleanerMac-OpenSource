import Foundation

/// Immutable scan-version index. All expensive work runs on a detached task;
/// the main actor only publishes an already-built snapshot.
struct BrowserPrivacyResultIndex: Sendable {
    let version: Int
    let records: [BrowserPrivacyRecord]
    let byID: [UUID: BrowserPrivacyRecord]
    let search: [UUID: String]
    let domains: [UUID: String]
    let keywords: [UUID: String]
    let sensitiveSites: Set<BrowserPrivacySiteID>
    let browsers: [BrowserPrivacyBrowser]
    let concealedBulk: BrowserPrivacyBulkSelectionPresentation
    let allProfiles: [BrowserPrivacyProfileOption]
    let profilesByBrowser: [String: [BrowserPrivacyProfileOption]]

    init(records: [BrowserPrivacyRecord], version: Int) throws {
        self.version = version; self.records = records
        var byID: [UUID: BrowserPrivacyRecord] = [:], search: [UUID: String] = [:]
        var domains: [UUID: String] = [:], keywords: [UUID: String] = [:]
        var sensitive: Set<BrowserPrivacySiteID> = [], browsers: [String: BrowserPrivacyBrowser] = [:]
        for (offset, record) in records.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            byID[record.id] = record
            search[record.id] = BrowserPrivacySearchText.normalized(record.searchableFields.joined(separator: "\u{1F}"))
            domains[record.id] = BrowserPrivacySearchText.normalized(record.domain ?? "")
            keywords[record.id] = BrowserPrivacySearchText.normalized(record.searchKeyword ?? "")
            if BrowserPrivacyLightfieldPresentation.isSensitive(record.category) {
                sensitive.insert(BrowserPrivacyDisclosurePolicy.siteID(record))
            }
            browsers[record.browser.id] = record.browser
        }
        self.byID = byID; self.search = search; self.domains = domains; self.keywords = keywords
        sensitiveSites = sensitive
        concealedBulk = .init(records: records, disclosure: .init(sensitiveSites: sensitive))
        let order = ["safari", "chrome", "edge", "firefox"]
        self.browsers = browsers.values.sorted {
            let a = order.firstIndex(of: $0.id) ?? order.count, b = order.firstIndex(of: $1.id) ?? order.count
            return a == b ? $0.displayName < $1.displayName : a < b
        }
        allProfiles = BrowserPrivacyRecordResultsView.profileOptions(from: records, browserID: nil)
        profilesByBrowser = Dictionary(uniqueKeysWithValues: self.browsers.map { browser in
            (browser.id, BrowserPrivacyRecordResultsView.profileOptions(from: records, browserID: browser.id))
        })
    }

    func snapshot(filters: BrowserPrivacyFilters, sort: BrowserPrivacyResultSort,
                  revealedSites: Set<BrowserPrivacySiteID>, retainedSensitiveSites: Set<BrowserPrivacySiteID>) throws -> BrowserPrivacyResultSnapshot {
        let allSensitiveSites = sensitiveSites.union(retainedSensitiveSites)
        let policy = BrowserPrivacyDisclosurePolicy(sensitiveSites: allSensitiveSites, revealedSites: revealedSites)
        let query = BrowserPrivacySearchText.normalized(filters.query)
        let domain = BrowserPrivacySearchText.normalized(filters.domain)
        let keyword = BrowserPrivacySearchText.normalized(filters.keyword)
        let hasText = !query.isEmpty || !domain.isEmpty || !keyword.isEmpty
        let calendar = Calendar.current
        let start = filters.startDate.map { calendar.startOfDay(for: $0) }
        let end = filters.endDate.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        var matched: [BrowserPrivacyRecord] = [], concealed: [BrowserPrivacyRecord] = []
        for (offset, record) in records.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            guard (filters.browserID == nil || record.browser.id == filters.browserID),
                  (filters.profileID == nil || record.profileID == filters.profileID),
                  (filters.category == nil || record.category == filters.category),
                  (filters.source == nil || record.source == filters.source),
                  (filters.confidence == nil || record.selectionConfidence == filters.confidence) else { continue }
            if let start, (record.visitedAt ?? .distantPast) < start { continue }
            if let end, record.visitedAt == nil || record.visitedAt! >= end { continue }
            if policy.isConcealed(record) {
                // The masked aggregate is independent of every text query.
                // Hidden visits are not added to a query's selection scope.
                concealed.append(record)
                if !hasText { matched.append(record) }
                continue
            }
            guard query.isEmpty || search[record.id, default: ""].contains(query),
                  domain.isEmpty || domains[record.id, default: ""].contains(domain),
                  keyword.isEmpty || keywords[record.id, default: ""].contains(keyword) else { continue }
            matched.append(record)
        }
        matched.sort {
            if $0.visitedAt != $1.visitedAt { return ($0.visitedAt ?? .distantPast) > ($1.visitedAt ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
        let displayItems = BrowserPrivacyDisplayItem.aggregate(matched, sort: sort)
        // Concealed placeholders retain their non-text-filtered counts, but
        // are not selection candidates while a text query is active.
        let shown = hasText ? matched + concealed : matched
        let groups = BrowserPrivacyLightfieldPresentation.groups(hasText ? BrowserPrivacyDisplayItem.aggregate(shown, sort: sort) : displayItems, sensitiveIDs: allSensitiveSites)
        let browserGroups = browsers.compactMap { browser -> BrowserPrivacyBrowserGroup? in
            let profiles = groups.filter { $0.browser.id == browser.id }
            return profiles.isEmpty ? nil : .init(profiles: profiles)
        }
        return .init(version: version, records: matched, items: displayItems, groups: groups,
                     browsers: browsers, concealedCount: concealed.count,
                     visibleCount: matched.count - (hasText ? 0 : concealed.count),
                     hasTextQuery: hasText, policy: policy,
                     bulk: revealedSites.isEmpty && allSensitiveSites == sensitiveSites ? concealedBulk : .init(records: records, disclosure: policy), browserGroups: browserGroups,
                     siteCount: groups.reduce(0) { $0 + $1.sites.count },
                     recordIDs: Set(matched.map(\.id)), allProfiles: allProfiles, profilesByBrowser: profilesByBrowser)
    }
}

struct BrowserPrivacyResultSnapshot: Sendable {
    let version: Int
    let records: [BrowserPrivacyRecord]
    let items: [BrowserPrivacyDisplayItem]
    let groups: [BrowserPrivacyProfileGroup]
    let browsers: [BrowserPrivacyBrowser]
    let concealedCount: Int
    let visibleCount: Int
    let hasTextQuery: Bool
    let policy: BrowserPrivacyDisclosurePolicy
    let bulk: BrowserPrivacyBulkSelectionPresentation
    let browserGroups: [BrowserPrivacyBrowserGroup]
    let siteCount: Int
    let recordIDs: Set<UUID>
    let allProfiles: [BrowserPrivacyProfileOption]
    let profilesByBrowser: [String: [BrowserPrivacyProfileOption]]
}
