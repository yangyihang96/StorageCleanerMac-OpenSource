import Foundation

/// D70② changes the display hierarchy only. These identities never become
/// deletion identities; selection still passes exact scan-time UUIDs to Store.
struct BrowserPrivacySiteID: Hashable, Sendable {
    let profile: BrowserPrivacyProfileIdentity
    let domain: String
}

struct BrowserPrivacySiteGroup: Identifiable, Sendable {
    let id: BrowserPrivacySiteID
    let pages: [BrowserPrivacyDisplayItem]
    let isSensitive: Bool
    let records: [BrowserPrivacyRecord]
    let latestVisit: Date?
    init(id: BrowserPrivacySiteID, pages: [BrowserPrivacyDisplayItem], isSensitive: Bool) {
        self.id = id; self.pages = pages; self.isSensitive = isSensitive
        records = pages.flatMap(\.records)
        latestVisit = pages.compactMap(\.latestVisitedAt).max()
    }
    var title: String {
        BrowserPrivacyDisplayText.sanitized(id.domain, maximumLength: 253)
            ?? L10n.text("无网站信息", "No website")
    }
    /// Neither AX nor a help tooltip receives the original until this site's
    /// own disclosure is explicitly pressed, even after opening its bucket.
    var concealedTitle: String {
        let parts = title.split(separator: ".")
        guard parts.count > 1, let suffix = parts.last else { return "••••" }
        return String(title.prefix(1)) + "•••." + suffix
    }
}

struct BrowserPrivacyProfileGroup: Identifiable, Sendable {
    let id: BrowserPrivacyProfileIdentity
    let browser: BrowserPrivacyBrowser
    let profileName: String
    let sites: [BrowserPrivacySiteGroup]
    var title: String {
        (BrowserPrivacyDisplayText.sanitized(browser.displayName, maximumLength: 80) ?? "")
            + (profileName.isEmpty ? "" : " · " + (BrowserPrivacyDisplayText.sanitized(profileName, maximumLength: 120) ?? ""))
    }
    let records: [BrowserPrivacyRecord]
    let sensitiveSites: [BrowserPrivacySiteGroup]
    let regularSites: [BrowserPrivacySiteGroup]
    init(id: BrowserPrivacyProfileIdentity, browser: BrowserPrivacyBrowser, profileName: String, sites: [BrowserPrivacySiteGroup]) {
        self.id = id; self.browser = browser; self.profileName = profileName; self.sites = sites
        records = sites.flatMap(\.records)
        sensitiveSites = sites.filter(\.isSensitive)
        regularSites = sites.filter { !$0.isSensitive }
    }
}

struct BrowserPrivacyBrowserGroup: Identifiable, Sendable {
    let browser: BrowserPrivacyBrowser
    let profiles: [BrowserPrivacyProfileGroup]
    let sensitiveGroup: BrowserPrivacyProfileGroup
    var id: String { browser.id }
    init(profiles: [BrowserPrivacyProfileGroup]) {
        browser = profiles[0].browser
        self.profiles = profiles
        sensitiveGroup = .init(id: .init(browserID: browser.id, profileID: "sensitive:" + browser.id),
            browser: browser, profileName: "", sites: profiles.flatMap(\.sensitiveSites))
    }
}

enum BrowserPrivacyLightfieldPresentation {
    static let datePresets: [BrowserPrivacyDatePreset] = [.today, .week, .all]

    static func isSensitive(_ category: BrowserPrivacyCategory) -> Bool {
        category == .adult || category == .finance
    }

    static func siteKey(_ item: BrowserPrivacyDisplayItem) -> String {
        let domain = item.domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let domain, !domain.isEmpty { return domain }
        // Internal/local addresses stay in a neutral bucket. Default rows must
        // not expose local paths, queries or browser-internal page names.
        return ""
    }

    static func groups(_ items: [BrowserPrivacyDisplayItem],
                       sensitivityItems: [BrowserPrivacyDisplayItem]? = nil) -> [BrowserPrivacyProfileGroup] {
        // Use the full scan for sensitivity, so a title/date query cannot
        // expose an otherwise sensitive site by hiding its sensitive pages.
        let sensitiveIDs = Set((sensitivityItems ?? items).filter { page in
            page.records.contains { isSensitive($0.category) }
        }.map { BrowserPrivacySiteID(profile: .init(browserID: $0.browser.id, profileID: $0.profileID), domain: siteKey($0)) })
        return groups(items, sensitiveIDs: sensitiveIDs)
    }

    static func groups(_ items: [BrowserPrivacyDisplayItem], sensitiveIDs: Set<BrowserPrivacySiteID>) -> [BrowserPrivacyProfileGroup] {
        return Dictionary(grouping: items) {
            BrowserPrivacyProfileIdentity(browserID: $0.browser.id, profileID: $0.profileID)
        }.map { identity, pages in
            let first = pages[0]
            let sites = Dictionary(grouping: pages, by: siteKey).map { domain, pages in
                let id = BrowserPrivacySiteID(profile: identity, domain: domain)
                return BrowserPrivacySiteGroup(id: id, pages: pages, isSensitive: sensitiveIDs.contains(id))
            }.sorted { $0.id.domain < $1.id.domain }
            return BrowserPrivacyProfileGroup(id: identity, browser: first.browser,
                profileName: first.profileDisplayName, sites: sites)
        }.sorted {
            if $0.browser.id != $1.browser.id {
                let order = ["safari", "chrome", "edge", "firefox"]
                let lhs = order.firstIndex(of: $0.browser.id) ?? order.count
                let rhs = order.firstIndex(of: $1.browser.id) ?? order.count
                if lhs != rhs { return lhs < rhs }
                return $0.browser.displayName < $1.browser.displayName
            }
            return $0.profileName == $1.profileName ? $0.id.profileID < $1.id.profileID : $0.profileName < $1.profileName
        }
    }

    static func deletableIDs(_ records: [BrowserPrivacyRecord]) -> Set<UUID> {
        Set(records.filter { $0.locator != nil && $0.selectionEligibility.canSelect }.map(\.id))
    }

    static func selectionState(ids: Set<UUID>, selected: Set<UUID>) -> BrowserPrivacySelectionState {
        let count = ids.intersection(selected).count
        if count == 0 { return .unchecked }
        return count == ids.count ? .checked : .mixed
    }

    static func invertedIDs(records: [BrowserPrivacyRecord], selected: Set<UUID>) -> Set<UUID> {
        deletableIDs(records).subtracting(selected)
    }

    static func counts(sites: Int, records: Int) -> String {
        L10n.text("\(ByteFormat.count(sites)) 个站点 · \(ByteFormat.count(records)) 条", "\(ByteFormat.count(sites)) sites · \(ByteFormat.count(records)) records")
    }

    static func recordCount(_ count: Int) -> String {
        L10n.text("\(ByteFormat.count(count)) 条", "\(ByteFormat.count(count)) records")
    }
}
