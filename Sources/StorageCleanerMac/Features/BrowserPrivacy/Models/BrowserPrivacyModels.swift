import Foundation

/// Canonical browser identities shared with the audited cleanup router. New
/// Chromium/Firefox derivatives stay on the launch-only guidance path.
enum BrowserKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case safari
    case chrome
    case edge
    case firefox
}

/// Engine families are deliberately separate from user-facing browser names.
/// New Chromium and Firefox derivatives can reuse the correct reader without
/// pretending to be Safari, Chrome, Edge, or Firefox themselves.
enum BrowserPrivacyEngine: String, Equatable, Hashable, Sendable {
    case safari
    case chromium
    case firefox
}

enum BrowserPrivacyRecordSource: String, CaseIterable, Equatable, Hashable, Sendable {
    case history
}

enum BrowserPrivacyCategory: String, CaseIterable, Equatable, Hashable, Sendable {
    case adult
    case finance
    case social
    case shopping
    case entertainment
    case search
    case productivity
    case news
    case other
    case unknown

    var isAdultContent: Bool { self == .adult }
}

enum BrowserPrivacySelectionConfidence: String, Equatable, Hashable, Sendable {
    case high
    case medium
    case low
    case unavailable
}

/// Risk describes the consequence of handling an item. It is intentionally
/// independent from whether the current product can act on that item.
enum BrowserPrivacyRisk: String, CaseIterable, Equatable, Hashable, Sendable {
    case safe
    case review
    case protected
}

/// Eligibility describes the only action the current scan snapshot may offer.
/// A visit is directly selectable only when discovery, signing, path identity,
/// schema, sidecar, and write-capability gates all minted a locator.
enum BrowserPrivacySelectionEligibility: String, Equatable, Hashable, Sendable {
    case selectable
    case selectableWithConfirmation
    case browserActionOnly
    case forbidden

    var canSelect: Bool { self != .forbidden }
}

enum BrowserPrivacyResultSort: String, CaseIterable, Equatable, Sendable {
    case largestFirst
    case newestFirst
    case browser
}

enum BrowserPrivacySelectionState: Equatable, Sendable {
    case unchecked
    case mixed
    case checked
}

struct BrowserPrivacyBrowser: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let engine: BrowserPrivacyEngine
    /// Nil is valid when a local profile was found but the app bundle itself
    /// was not discoverable in the standard local locations.
    let bundleIdentifier: String?
    let version: String?
    /// A production locator requires this local bundle URL and complete signing
    /// evidence in addition to the provider, registered-root, and schema gates.
    let applicationURL: URL?
    let signingIdentity: StartupApplicationSigningIdentity?

    init(
        id: String,
        displayName: String,
        engine: BrowserPrivacyEngine,
        bundleIdentifier: String?,
        version: String?,
        applicationURL: URL? = nil,
        signingIdentity: StartupApplicationSigningIdentity? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.applicationURL = applicationURL
        self.signingIdentity = signingIdentity
    }
}

struct BrowserPrivacyProfile: Identifiable, Equatable, Sendable {
    let id: String
    let browser: BrowserPrivacyBrowser
    let displayName: String
    let historyDatabaseURL: URL
    let sourceTrustedParentURL: URL
}

/// A scan-time identity token for every component from the trusted profile
/// directory through the history database.  A row number alone is never an
/// authority to write: the processor must reproduce this complete chain just
/// before opening the database.
struct BrowserPrivacyPathIdentity: Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let kind: UInt32
}

/// Lossless SQLite numeric identity. Browser timestamps are commonly 64-bit
/// integers larger than Double's exact-integer range, so a Double alone cannot
/// safely prove that a visit row still represents the scanned record.
enum BrowserPrivacySQLiteNumericIdentity: Equatable, Hashable, Sendable {
    case integer(Int64)
    case real(UInt64)

    var doubleValue: Double {
        switch self {
        case let .integer(value): Double(value)
        case let .real(bitPattern): Double(bitPattern: bitPattern)
        }
    }
}

/// Opaque write locator produced only by the read-only scanner.  It binds a
/// SQLite visit row to the provider, profile, database path, trusted parent,
/// engine, the row's semantic identity, and the database's scan-time file
/// identity. Rowid alone is insufficient because SQLite may reuse it after a
/// browser changes history between scan and confirmation.
struct BrowserPrivacyRecordLocator: Equatable, Hashable, Sendable {
    let providerID: String
    let profileID: String
    let engine: BrowserPrivacyEngine
    let visitRowID: Int64
    let parentRowID: Int64
    let visitTimestampIdentity: BrowserPrivacySQLiteNumericIdentity
    let rawURL: String
    let databaseURL: URL
    let trustedParentURL: URL
    let identityChain: [BrowserPrivacyPathIdentity]
}

enum BrowserPrivacyProviderAvailability: Equatable, Sendable {
    case available
    case noProfiles
    case permissionDenied
    case partial
    case malformedSchema
    case busy
    case timedOut
    case unavailable
}

/// Coverage is intentionally payload-free: it can explain scan access without
/// leaking local profile paths, URLs, titles, or database values.
struct BrowserPrivacyProviderCoverage: Identifiable, Equatable, Sendable {
    var id: String { browser.id }

    let browser: BrowserPrivacyBrowser
    let availability: BrowserPrivacyProviderAvailability
    let profileCount: Int
    let recordCount: Int
    let detail: String?
    /// True when the scanner could not read at least one profile because the
    /// user must grant Full Disk Access.  This remains separate from
    /// `availability == .partial`: a partial result may also be caused by a
    /// safe scan limit or an unreadable/malformed profile.
    let requiresFullDiskAccess: Bool
    /// Exact profile IDs that completed a full read in this scan. Counts alone
    /// cannot prove that the same profiles were covered on a later scan.
    let fullyScannedProfileIDs: Set<String>

    init(
        browser: BrowserPrivacyBrowser,
        availability: BrowserPrivacyProviderAvailability,
        profileCount: Int,
        recordCount: Int,
        detail: String?,
        requiresFullDiskAccess: Bool = false,
        fullyScannedProfileIDs: Set<String> = []
    ) {
        self.browser = browser
        self.availability = availability
        self.profileCount = profileCount
        self.recordCount = recordCount
        self.detail = detail
        self.requiresFullDiskAccess = requiresFullDiskAccess
        self.fullyScannedProfileIDs = fullyScannedProfileIDs
    }
}

struct BrowserPrivacyRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let browser: BrowserPrivacyBrowser
    let profileID: String
    let profileDisplayName: String?
    let source: BrowserPrivacyRecordSource
    /// Raw fields are not persisted by the result store, UserDefaults,
    /// telemetry, or network requests. The scanner reads them from a private,
    /// bounded local SQLite snapshot that is removed after the scan.
    let url: String?
    let domain: String?
    let title: String?
    /// An optional search term parsed solely from an already-read URL query
    /// parameter. It is never inferred from a title or fetched from a page.
    let searchKeyword: String?
    let visitedAt: Date?
    let visitCount: Int?
    let category: BrowserPrivacyCategory
    let selectionConfidence: BrowserPrivacySelectionConfidence
    /// SQLite does not expose a stable per-history-row byte attribution. Nil
    /// means unknown; it must never be manufactured from a guessed average.
    let sizeBytes: Int64?
    /// Nil means this result can be reviewed but cannot be passed to the
    /// verified SQLite deletion path.
    let locator: BrowserPrivacyRecordLocator?

    init(
        id: UUID,
        browser: BrowserPrivacyBrowser,
        profileID: String,
        profileDisplayName: String? = nil,
        source: BrowserPrivacyRecordSource,
        url: String?,
        domain: String?,
        title: String?,
        searchKeyword: String?,
        visitedAt: Date?,
        visitCount: Int?,
        category: BrowserPrivacyCategory,
        selectionConfidence: BrowserPrivacySelectionConfidence,
        sizeBytes: Int64?,
        locator: BrowserPrivacyRecordLocator? = nil
    ) {
        self.id = id
        self.browser = browser
        self.profileID = profileID
        self.profileDisplayName = profileDisplayName
        self.source = source
        self.url = url
        self.domain = domain
        self.title = title
        self.searchKeyword = searchKeyword
        self.visitedAt = visitedAt
        self.visitCount = visitCount
        self.category = category
        self.selectionConfidence = selectionConfidence
        self.sizeBytes = sizeBytes
        self.locator = locator
    }

    var isDefaultSelected: Bool {
        // History, cookies and other session-bearing data must never become
        // selected merely because a classifier assigned a high confidence.
        false
    }

    var risk: BrowserPrivacyRisk {
        switch source {
        case .history:
            .review
        }
    }

    var selectionEligibility: BrowserPrivacySelectionEligibility {
        locator == nil ? .browserActionOnly : .selectableWithConfirmation
    }

    /// Stable for the lifetime of the underlying history visit. The scanner's
    /// display UUID is intentionally excluded because every scan creates new
    /// in-memory records.
    var reverificationFingerprint: BrowserPrivacyRecordFingerprint {
        BrowserPrivacyRecordFingerprint(
            browserID: browser.id,
            profileID: profileID,
            source: source,
            visitRowID: locator?.visitRowID,
            visitTimestampIdentity: locator?.visitTimestampIdentity,
            url: url?.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain?.lowercased(),
            visitedAt: visitedAt
        )
    }

    var selectionID: BrowserPrivacySelectionID {
        BrowserPrivacySelectionID(
            browserID: browser.id,
            profileID: profileID,
            source: source,
            visitRowID: locator?.visitRowID,
            visitTimestampIdentity: locator?.visitTimestampIdentity,
            rawURL: url?.trimmingCharacters(in: .whitespacesAndNewlines),
            visitedAt: visitedAt
        )
    }
}

/// Stable for one underlying browser visit across repeated read-only scans.
/// The random UI UUID is deliberately excluded, and URL alone is never a
/// deletion identity.
struct BrowserPrivacySelectionID: Equatable, Hashable, Sendable {
    let browserID: String
    let profileID: String
    let source: BrowserPrivacyRecordSource
    let visitRowID: Int64?
    let visitTimestampIdentity: BrowserPrivacySQLiteNumericIdentity?
    let rawURL: String?
    let visitedAt: Date?
}

struct BrowserPrivacyDisplayItemID: Equatable, Hashable, Sendable {
    let browserID: String
    let profileID: String
    let source: BrowserPrivacyRecordSource
    let normalizedURL: String
}

/// A compact UI row may aggregate many visits, while every destructive action
/// still expands back to the exact scan-time records and Visit IDs.
struct BrowserPrivacyDisplayItem: Identifiable, Equatable, Sendable {
    let id: BrowserPrivacyDisplayItemID
    let browser: BrowserPrivacyBrowser
    let profileID: String
    let profileDisplayName: String
    let domain: String?
    let category: BrowserPrivacyCategory
    let risk: BrowserPrivacyRisk
    let records: [BrowserPrivacyRecord]

    var visitCount: Int { records.count }
    var latestVisitedAt: Date? { records.compactMap(\.visitedAt).max() }
    var underlyingSelectionIDs: Set<BrowserPrivacySelectionID> {
        Set(records.map(\.selectionID))
    }
    var exactSizeBytes: Int64? {
        let values = records.compactMap(\.sizeBytes)
        return values.count == records.count ? values.reduce(0, +) : nil
    }
    var selectionEligibility: BrowserPrivacySelectionEligibility {
        records.allSatisfy { $0.locator != nil }
            ? .selectableWithConfirmation
            : .browserActionOnly
    }

    static func aggregate(_ records: [BrowserPrivacyRecord]) -> [Self] {
        Dictionary(grouping: records) { record in
            BrowserPrivacyDisplayItemID(
                browserID: record.browser.id,
                profileID: record.profileID,
                source: record.source,
                normalizedURL: normalizedGroupingURL(record.url, domain: record.domain)
            )
        }
        .map { id, rows in
            let sorted = rows.sorted {
                ($0.visitedAt ?? .distantPast) > ($1.visitedAt ?? .distantPast)
            }
            let first = sorted[0]
            return Self(
                id: id,
                browser: first.browser,
                profileID: first.profileID,
                profileDisplayName: first.profileDisplayName
                    ?? first.profileID.split(separator: ":").last.map(String.init)
                    ?? first.profileID,
                domain: first.domain,
                category: first.category,
                risk: first.risk,
                records: sorted
            )
        }
        .sorted {
            if $0.latestVisitedAt != $1.latestVisitedAt {
                return ($0.latestVisitedAt ?? .distantPast) > ($1.latestVisitedAt ?? .distantPast)
            }
            return $0.id.normalizedURL < $1.id.normalizedURL
        }
    }

    private static func normalizedGroupingURL(_ rawURL: String?, domain: String?) -> String {
        guard let rawURL, var components = URLComponents(string: rawURL) else {
            return domain?.lowercased() ?? "unparseable"
        }
        components.fragment = nil
        if let host = components.host?.lowercased() {
            components.host = host
        }
        return components.string ?? rawURL
    }
}

struct BrowserPrivacyRecordFingerprint: Equatable, Hashable, Sendable {
    let browserID: String
    let profileID: String
    let source: BrowserPrivacyRecordSource
    let visitRowID: Int64?
    let visitTimestampIdentity: BrowserPrivacySQLiteNumericIdentity?
    let url: String?
    let domain: String?
    let visitedAt: Date?
}

struct BrowserPrivacyProfileIdentity: Equatable, Hashable, Sendable {
    let browserID: String
    let profileID: String
}

struct BrowserPrivacyReverificationBaseline: Equatable, Sendable {
    let fingerprintCounts: [BrowserPrivacyRecordFingerprint: Int]
    let profileIdentities: Set<BrowserPrivacyProfileIdentity>

    var totalCount: Int {
        fingerprintCounts.values.reduce(0, +)
    }

    init(records: [BrowserPrivacyRecord]) {
        fingerprintCounts = records.reduce(into: [:]) { counts, record in
            counts[record.reverificationFingerprint, default: 0] += 1
        }
        profileIdentities = Set(records.map {
            BrowserPrivacyProfileIdentity(
                browserID: $0.browser.id,
                profileID: $0.profileID
            )
        })
    }
}

enum BrowserPrivacyReverificationStatus: Equatable, Sendable {
    case checking(totalCount: Int)
    case noLongerFound(totalCount: Int)
    case stillPresent(remainingCount: Int, totalCount: Int)
    case coverageIncomplete(totalCount: Int)
}

enum BrowserPrivacyScanState: Equatable, Sendable {
    case idle
    case scanning
    case completed
    case partial
    case permissionDenied
    case cancelled
    case failed
}

struct BrowserPrivacyScanOutcome: Equatable, Sendable {
    let state: BrowserPrivacyScanState
    let records: [BrowserPrivacyRecord]
    let coverage: [BrowserPrivacyProviderCoverage]
}

struct BrowserPrivacyScanSnapshot: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let records: [BrowserPrivacyRecord]
    let coverage: [BrowserPrivacyProviderCoverage]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        records: [BrowserPrivacyRecord],
        coverage: [BrowserPrivacyProviderCoverage]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.records = records
        self.coverage = coverage
    }
}

enum BrowserPrivacyCleanPlanError: Error, Equatable, Sendable {
    case emptySelection
    case selectionNotInSnapshot
    case duplicateVisitIdentity
    case protectedRecord
}

/// Immutable input to preflight and execution. Views never pass a mutable
/// filtered array directly into the SQLite processor.
struct BrowserPrivacyCleanPlan: Equatable, Sendable {
    let id: UUID
    let snapshotID: UUID
    let createdAt: Date
    let records: [BrowserPrivacyRecord]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        snapshot: BrowserPrivacyScanSnapshot,
        selectedIDs: Set<BrowserPrivacySelectionID>
    ) throws {
        guard !selectedIDs.isEmpty else {
            throw BrowserPrivacyCleanPlanError.emptySelection
        }
        let selected = snapshot.records.filter { selectedIDs.contains($0.selectionID) }
        guard selected.count == selectedIDs.count else {
            throw BrowserPrivacyCleanPlanError.selectionNotInSnapshot
        }
        guard selected.allSatisfy({ $0.risk != .protected }) else {
            throw BrowserPrivacyCleanPlanError.protectedRecord
        }
        let directVisitIDs = selected.compactMap { record -> String? in
            guard let locator = record.locator else { return nil }
            return "\(locator.providerID)\n\(locator.profileID)\n\(locator.visitRowID)"
        }
        guard Set(directVisitIDs).count == directVisitIDs.count else {
            throw BrowserPrivacyCleanPlanError.duplicateVisitIdentity
        }
        self.id = id
        self.snapshotID = snapshot.id
        self.createdAt = createdAt
        self.records = selected
    }
}

enum BrowserPrivacyScanError: Error, Equatable, Sendable {
    case cancelled
    case readFailed
}

struct BrowserPrivacyFilters: Equatable, Sendable {
    var query: String
    var browserID: String?
    var profileID: String?
    var category: BrowserPrivacyCategory?
    var source: BrowserPrivacyRecordSource?
    var confidence: BrowserPrivacySelectionConfidence?
    var domain: String
    var keyword: String
    var startDate: Date?
    var endDate: Date?

    static let empty = Self(
        query: "",
        browserID: nil,
        profileID: nil,
        category: nil,
        source: nil,
        confidence: nil,
        domain: "",
        keyword: "",
        startDate: nil,
        endDate: nil
    )
}

/// Calendar-day presets share the same inclusive-day contract as the record filter.
enum BrowserPrivacyDatePreset: Int, CaseIterable, Identifiable {
    case all = 0, today = 1, week = 7, month = 30
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .today: L10n.text("今天", "Today")
        case .week: L10n.text("最近7天", "7 days")
        case .month: L10n.text("最近30天", "30 days")
        }
    }
    func apply(to filters: inout BrowserPrivacyFilters, now: Date, calendar: Calendar = .current) {
        guard self != .all else {
            filters.startDate = nil
            filters.endDate = nil
            return
        }
        let today = calendar.startOfDay(for: now)
        filters.startDate = calendar.date(byAdding: .day, value: -(rawValue - 1), to: today)
        filters.endDate = today
    }
    static func matching(_ filters: BrowserPrivacyFilters, now: Date, calendar: Calendar = .current) -> Self? {
        if filters.startDate == nil && filters.endDate == nil { return .all }
        guard let start = filters.startDate, let end = filters.endDate,
              calendar.isDate(end, inSameDayAs: now) else { return nil }
        return allCases.first { preset in
            guard preset != .all,
                  let date = calendar.date(byAdding: .day, value: -(preset.rawValue - 1), to: calendar.startOfDay(for: now)) else { return false }
            return calendar.isDate(start, inSameDayAs: date)
        }
    }
}

enum BrowserPrivacyWriteCapability: Equatable, Sendable {
    /// This provider has a schema-specific visit-row adapter and can enter the
    /// transaction and read-back verification chain.
    case verifiedVisitDeletion
    /// The provider/profile is readable but does not expose a proven write
    /// adapter. Guidance is not reported as deletion.
    case manualBrowserGuidance
    /// The provider explicitly cannot process this record safely.
    case unsupported
}

enum BrowserPrivacyProcessingOutcome: Equatable, Sendable {
    case deleted
    case failed
    case indeterminate
    case manual
    case unsupported
}

struct BrowserPrivacyProcessingEntry: Identifiable, Equatable, Sendable {
    let browser: BrowserPrivacyBrowser
    let profileID: String
    let recordCount: Int
    let capability: BrowserPrivacyWriteCapability
    let outcome: BrowserPrivacyProcessingOutcome
    let verifiedDeletedRecordIDs: Set<UUID>
    let recoveryBackupID: UUID?
    let detail: String

    init(
        browser: BrowserPrivacyBrowser,
        profileID: String,
        recordCount: Int,
        capability: BrowserPrivacyWriteCapability,
        outcome: BrowserPrivacyProcessingOutcome = .manual,
        verifiedDeletedRecordIDs: Set<UUID> = [],
        recoveryBackupID: UUID? = nil,
        detail: String = ""
    ) {
        self.browser = browser
        self.profileID = profileID
        self.recordCount = recordCount
        self.capability = capability
        self.outcome = outcome
        self.verifiedDeletedRecordIDs = verifiedDeletedRecordIDs
        self.recoveryBackupID = recoveryBackupID
        self.detail = detail
    }

    var id: String { "\(browser.id):\(profileID)" }
}

struct BrowserPrivacyProcessingReport: Equatable, Sendable {
    let selectedRecordCount: Int
    let entries: [BrowserPrivacyProcessingEntry]

    var verifiedDeletedRecordIDs: Set<UUID> {
        entries.reduce(into: Set<UUID>()) { result, entry in
            result.formUnion(entry.verifiedDeletedRecordIDs)
        }
    }

    var verifiedDeletedRecordCount: Int { verifiedDeletedRecordIDs.count }

    var failedRecordCount: Int {
        entries.lazy
            .filter { $0.outcome == .failed }
            .reduce(0) { $0 + $1.recordCount }
    }

    var indeterminateRecordCount: Int {
        entries.lazy
            .filter { $0.outcome == .indeterminate }
            .reduce(0) { $0 + $1.recordCount }
    }

    var manualRecordCount: Int {
        entries.lazy
            .filter { $0.outcome == .manual || $0.outcome == .unsupported }
            .reduce(0) { $0 + $1.recordCount }
    }
}
