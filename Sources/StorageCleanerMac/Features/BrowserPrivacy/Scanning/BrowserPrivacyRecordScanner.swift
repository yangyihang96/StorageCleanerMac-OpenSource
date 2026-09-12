import CSQLite
import Darwin
import Foundation

protocol BrowserPrivacyScanning: Sendable {
    func scan() async throws -> BrowserPrivacyScanOutcome
}

struct BrowserPrivacyRecordScanLimits: Equatable, Sendable {
    let maximumProfiles: Int
    let maximumConcurrentProfiles: Int
    let maximumRecordsPerProfile: Int
    let maximumRecordsTotal: Int
    let busyRetrySeconds: TimeInterval
    let totalTimeoutSeconds: TimeInterval

    init(
        maximumProfiles: Int = 64,
        maximumConcurrentProfiles: Int = 2,
        maximumRecordsPerProfile: Int = 50_000,
        maximumRecordsTotal: Int = 100_000,
        busyRetrySeconds: TimeInterval = 2,
        totalTimeoutSeconds: TimeInterval = 15
    ) {
        self.maximumProfiles = min(max(maximumProfiles, 1), 64)
        self.maximumConcurrentProfiles = min(max(maximumConcurrentProfiles, 1), 2)
        self.maximumRecordsPerProfile = min(max(maximumRecordsPerProfile, 1), 100_000)
        self.maximumRecordsTotal = min(max(maximumRecordsTotal, 1), 100_000)
        self.busyRetrySeconds = Self.clampedSeconds(busyRetrySeconds, upperBound: 2)
        self.totalTimeoutSeconds = Self.clampedSeconds(totalTimeoutSeconds, upperBound: 15)
    }

    private static func clampedSeconds(
        _ value: TimeInterval,
        upperBound: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return upperBound }
        return min(max(value, 0.01), upperBound)
    }
}

/// Reads browser history through the existing SQLite snapshot service.  The
/// source databases are never opened for writing and records only live for the
/// current in-memory scan session.
struct BrowserPrivacyRecordScanner: BrowserPrivacyScanning, Sendable {
    private let registry: BrowserPrivacyProviderRegistry
    private let snapshotService: SQLiteSnapshotService
    private let homeDirectory: URL
    private let installedApplications: [BrowserPrivacyInstalledApplication]?
    private let limits: BrowserPrivacyRecordScanLimits
    private let classifier: BrowserPrivacyLocalClassifier

    init(
        registry: BrowserPrivacyProviderRegistry = BrowserPrivacyProviderRegistry(),
        snapshotService: SQLiteSnapshotService = SQLiteSnapshotService(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        installedApplications: [BrowserPrivacyInstalledApplication]? = nil,
        limits: BrowserPrivacyRecordScanLimits = BrowserPrivacyRecordScanLimits(),
        classifier: BrowserPrivacyLocalClassifier = BrowserPrivacyLocalClassifier()
    ) {
        self.registry = registry
        self.snapshotService = snapshotService
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.installedApplications = installedApplications
        self.limits = limits
        self.classifier = classifier
    }

    func scan() async throws -> BrowserPrivacyScanOutcome {
        try Task.checkCancellation()
        let applications: [BrowserPrivacyInstalledApplication]
        if let installedApplications {
            applications = installedApplications
        } else {
            applications = await BrowserPrivacyApplicationLocator
                .discoverWithSigningIdentity(homeDirectory: homeDirectory)
        }
        try Task.checkCancellation()

        let discoveries = registry.discover(
            homeDirectory: homeDirectory,
            installedApplications: applications
        )
        let allProfiles = discoveries.flatMap(\.profiles)
        let selectedProfiles = Array(allProfiles.prefix(limits.maximumProfiles))
        let deadline = Self.deadline(after: limits.totalTimeoutSeconds)
        snapshotService.cleanupOrphans(deadlineNanoseconds: deadline)

        let profileRecordLimit = min(
            limits.maximumRecordsPerProfile,
            max(1, limits.maximumRecordsTotal / max(selectedProfiles.count, 1))
        )
        let results = await scanProfiles(
            selectedProfiles,
            maximumRecordsPerProfile: profileRecordLimit,
            deadlineNanoseconds: deadline
        )
        if Task.isCancelled {
            throw BrowserPrivacyScanError.cancelled
        }

        let records = results
            .flatMap(\.records)
            .prefix(limits.maximumRecordsTotal)
        let sortedRecords = records.sorted { lhs, rhs in
            switch (lhs.visitedAt, rhs.visitedAt) {
            case let (left?, right?):
                if left != right { return left > right }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let coverage = Self.coverage(
            discoveries: discoveries,
            results: results,
            reachedProfileLimit: allProfiles.count > selectedProfiles.count,
            reachedRecordLimit: records.count < results.reduce(0) { $0 + $1.records.count }
        )
        return BrowserPrivacyScanOutcome(
            state: Self.outcomeState(coverage: coverage, hasRecords: !sortedRecords.isEmpty),
            records: Array(sortedRecords),
            coverage: coverage
        )
    }

    private func scanProfiles(
        _ profiles: [BrowserPrivacyProfile],
        maximumRecordsPerProfile: Int,
        deadlineNanoseconds: UInt64
    ) async -> [ProfileScanResult] {
        var indexedResults: [(Int, ProfileScanResult)] = []
        var offset = 0
        while offset < profiles.count {
            if Task.isCancelled || MonotonicClock.now >= deadlineNanoseconds { break }
            let end = min(offset + limits.maximumConcurrentProfiles, profiles.count)
            let batch = Array(profiles[offset..<end].enumerated()).map {
                (offset + $0.offset, $0.element)
            }
            await withTaskGroup(of: (Int, ProfileScanResult).self) { group in
                for (index, profile) in batch {
                    group.addTask {
                        let result = await scan(
                            profile: profile,
                            maximumRecords: maximumRecordsPerProfile,
                            deadlineNanoseconds: deadlineNanoseconds
                        )
                        return (index, result)
                    }
                }
                for await result in group {
                    indexedResults.append(result)
                }
            }
            offset = end
        }

        let completedIndices = Set(indexedResults.map(\.0))
        for index in profiles.indices where !completedIndices.contains(index) {
            indexedResults.append((
                index,
                ProfileScanResult(
                    profile: profiles[index],
                    availability: Task.isCancelled ? .unavailable : .timedOut,
                    records: [],
                    reachedRecordLimit: false
                )
            ))
        }
        return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func scan(
        profile: BrowserPrivacyProfile,
        maximumRecords: Int,
        deadlineNanoseconds: UInt64
    ) async -> ProfileScanResult {
        do {
            let provider = registry.provider(id: profile.browser.id)
            let adapter = provider?.historyWriteAdapter
            let candidateLocatorIdentity: [BrowserPrivacyPathIdentity]
            let locatorTrustedParentURL: URL?
            if let adapter,
               adapter.engine == profile.browser.engine,
               (adapter == BrowserPrivacySQLiteWriteAdapter.verified(for: profile.browser.engine)
                   || adapter == .chromiumProduction),
               Self.hasWriteAccess(profile) {
                let productionRoot = adapter == .chromiumProduction
                    ? provider?.descriptor.productionWriteRoot(
                        browser: profile.browser,
                        homeDirectory: homeDirectory,
                        databaseURL: profile.historyDatabaseURL,
                        profileParentURL: profile.sourceTrustedParentURL
                    )
                    : profile.sourceTrustedParentURL
                let locatorIdentity: [SecureSourceFile.Identity]? = productionRoot.flatMap { trustedRoot in
                    guard adapter != .chromiumProduction
                            || Self.productionSidecarsAreAbsent(
                                databaseURL: profile.historyDatabaseURL
                            ) else {
                        return nil
                    }
                    return try? SecureSourceFile.identityChain(
                        for: profile.historyDatabaseURL,
                        trustedParent: trustedRoot,
                        expectedFinalKind: .regularFile
                    )
                }
                candidateLocatorIdentity = (locatorIdentity ?? []).map {
                    BrowserPrivacyPathIdentity(
                        device: $0.device,
                        inode: $0.inode,
                        kind: UInt32($0.kind)
                    )
                }
                locatorTrustedParentURL = locatorIdentity == nil ? nil : productionRoot
            } else {
                // A non-canonical or provider-mismatched adapter is never
                // enough evidence to mint a write locator. Keep this profile
                // reviewable, but route it to the manual browser flow.
                candidateLocatorIdentity = []
                locatorTrustedParentURL = nil
            }
            let read = try await snapshotService.withSnapshot(
                source: SQLiteSnapshotSource(
                    databaseURL: profile.historyDatabaseURL,
                    trustedParentURL: profile.sourceTrustedParentURL,
                    // Chromium may keep a non-hot rollback journal beside
                    // History while running. After the normal online backup
                    // times out, immutable mode provides a bounded read-only
                    // snapshot and never creates or mutates a sidecar.
                    allowsImmutableReadFallback: profile.browser.engine == .chromium
                ),
                schema: Self.schema(for: profile.browser.engine),
                busyRetrySeconds: limits.busyRetrySeconds,
                deadlineNanoseconds: deadlineNanoseconds
            ) { snapshot in
                try Self.readSnapshot(
                    snapshot,
                    profile: profile,
                    adapter: adapter,
                    candidateLocatorIdentity: candidateLocatorIdentity,
                    locatorTrustedParentURL: locatorTrustedParentURL,
                    maximumRecords: maximumRecords,
                    classifier: classifier
                )
            }
            return ProfileScanResult(
                profile: profile,
                availability: read.reachedRecordLimit ? .partial : .available,
                records: read.records,
                reachedRecordLimit: read.reachedRecordLimit
            )
        } catch let failure as SQLiteSnapshotFailure {
            return ProfileScanResult(
                profile: profile,
                availability: Self.availability(for: failure),
                records: [],
                reachedRecordLimit: false
            )
        } catch is CancellationError {
            return ProfileScanResult(
                profile: profile,
                availability: .unavailable,
                records: [],
                reachedRecordLimit: false
            )
        } catch {
            return ProfileScanResult(
                profile: profile,
                availability: .unavailable,
                records: [],
                reachedRecordLimit: false
            )
        }
    }

    /// A read-only scan must not promise a destructive action that the
    /// current account cannot perform. This metadata check is only an early
    /// capability hint; the processor repeats the check by opening the
    /// canonical source with read-write/no-follow flags immediately before
    /// its transaction, so a permission change or TCC denial still fails
    /// closed there.
    private static func hasWriteAccess(_ profile: BrowserPrivacyProfile) -> Bool {
        FileManager.default.isWritableFile(atPath: profile.historyDatabaseURL.path)
            && FileManager.default.isWritableFile(atPath: profile.sourceTrustedParentURL.path)
    }

    private static func productionSidecarsAreAbsent(databaseURL: URL) -> Bool {
        for suffix in ["-wal", "-shm", "-journal"] {
            var metadata = stat()
            if lstat(databaseURL.path + suffix, &metadata) == 0 || errno != ENOENT {
                return false
            }
        }
        return true
    }

    private static func readSnapshot(
        _ snapshot: SQLiteSnapshotDatabase,
        profile: BrowserPrivacyProfile,
        adapter: BrowserPrivacySQLiteWriteAdapter?,
        candidateLocatorIdentity: [BrowserPrivacyPathIdentity],
        locatorTrustedParentURL: URL?,
        maximumRecords: Int,
        classifier: BrowserPrivacyLocalClassifier
    ) throws -> SnapshotRead {
        try SQLiteRuntime.withReadOnlyDatabase(
            at: snapshot.fileURL,
            control: snapshot.control,
            busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
        ) { database in
            let locatorIdentity = validatedLocatorIdentity(
                adapter: adapter,
                profile: profile,
                candidate: candidateLocatorIdentity,
                database: database,
                snapshot: snapshot
            )
            let sql = try historyQuery(
                database: database,
                engine: profile.browser.engine,
                snapshot: snapshot
            )
            var records: [BrowserPrivacyRecord] = []
            records.reserveCapacity(min(maximumRecords, 1_024))
            var reachedRecordLimit = false
            var cursor = Int64.max
            let maximumBatchSize = 2_048
            scanLoop: while records.count <= maximumRecords {
                let batchLimit = min(
                    maximumBatchSize,
                    maximumRecords + 1 - records.count
                )
                guard batchLimit > 0 else { break }
                let statement = try SQLiteRuntime.prepare(
                    sql,
                    database: database,
                    control: snapshot.control,
                    busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
                )
                guard sqlite3_bind_int64(statement, 1, cursor) == SQLITE_OK,
                      sqlite3_bind_int64(statement, 2, Int64(batchLimit)) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    throw SQLiteSnapshotFailure.malformedSchema
                }
                var rowsInBatch = 0
                var nextCursor = cursor
                defer { sqlite3_finalize(statement) }
                while true {
                    let result = try SQLiteRuntime.step(
                        statement,
                        control: snapshot.control,
                        busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
                    )
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw SQLiteSnapshotFailure.unavailable }
                    if records.count == maximumRecords {
                        reachedRecordLimit = true
                        break scanLoop
                    }

                    let url = boundedText(statement: statement, column: 0, maximumBytes: 8_192)
                    let domain = normalizedHostname(url)
                    let title = boundedText(statement: statement, column: 1, maximumBytes: 8_192)
                    let visitTimestampIdentity = sqliteNumericIdentity(
                        statement: statement,
                        column: 2
                    )
                    let visitedAt = visitTimestampIdentity.flatMap {
                        date(from: $0.doubleValue, engine: profile.browser.engine)
                    }
                    let visitCount = sqlite3_column_type(statement, 3) == SQLITE_NULL
                        ? nil
                        : Int(exactly: sqlite3_column_int64(statement, 3))
                    let visitRowID = sqlite3_column_int64(statement, 4)
                    let parentRowID = sqlite3_column_int64(statement, 5)
                    nextCursor = min(nextCursor, visitRowID)
                    rowsInBatch += 1
                    let classification = classifier.classify(
                        url: url,
                        title: title,
                        domain: domain
                    )
                    let locator: BrowserPrivacyRecordLocator?
                    if !locatorIdentity.isEmpty,
                       let locatorTrustedParentURL,
                       let visitTimestampIdentity,
                       visitTimestampIdentity.doubleValue.isFinite,
                       let url,
                       !url.isEmpty {
                        locator = BrowserPrivacyRecordLocator(
                            providerID: profile.browser.id,
                            profileID: profile.id,
                            engine: profile.browser.engine,
                            visitRowID: visitRowID,
                            parentRowID: parentRowID,
                            visitTimestampIdentity: visitTimestampIdentity,
                            rawURL: url,
                            databaseURL: profile.historyDatabaseURL,
                            trustedParentURL: locatorTrustedParentURL,
                            identityChain: locatorIdentity
                        )
                    } else {
                        locator = nil
                    }
                    records.append(BrowserPrivacyRecord(
                        id: UUID(),
                        browser: profile.browser,
                        profileID: profile.id,
                        profileDisplayName: profile.displayName,
                        source: .history,
                        url: url,
                        domain: domain,
                        title: title,
                        searchKeyword: searchKeyword(from: url),
                        visitedAt: visitedAt,
                        visitCount: visitCount,
                        category: classification.category,
                        selectionConfidence: classification.confidence,
                        sizeBytes: nil,
                        locator: locator
                    ))
                }
                guard rowsInBatch == batchLimit, nextCursor < cursor else { break }
                cursor = nextCursor
            }
            return SnapshotRead(records: records, reachedRecordLimit: reachedRecordLimit)
        }
    }

    private static func validatedLocatorIdentity(
        adapter: BrowserPrivacySQLiteWriteAdapter?,
        profile: BrowserPrivacyProfile,
        candidate: [BrowserPrivacyPathIdentity],
        database: OpaquePointer,
        snapshot: SQLiteSnapshotDatabase
    ) -> [BrowserPrivacyPathIdentity] {
        guard !candidate.isEmpty, let adapter else { return [] }
        if adapter == BrowserPrivacySQLiteWriteAdapter.verified(for: profile.browser.engine) {
            return candidate
        }
        guard adapter == .chromiumProduction,
              (try? adapter.matchesChromiumProductionSchema(
                  database: database,
                  control: snapshot.control,
                  busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
              )) == true else {
            return []
        }
        return candidate
    }

    private static func historyQuery(
        database: OpaquePointer,
        engine: BrowserPrivacyEngine,
        snapshot: SQLiteSnapshotDatabase
    ) throws -> String {
        func hasColumn(_ table: String, _ column: String) throws -> Bool {
            try SQLiteRuntime.tableColumns(
                table,
                database: database,
                control: snapshot.control,
                busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
            ).contains(column)
        }

        switch engine {
        case .chromium:
            let title = try hasColumn("urls", "title") ? "urls.title" : "NULL"
            let visitCount = try hasColumn("urls", "visit_count")
                ? "urls.visit_count"
                : "NULL"
            return """
            SELECT urls.url, \(title), visits.visit_time, \(visitCount), visits.rowid, urls.id
            FROM visits JOIN urls ON visits.url = urls.id
            WHERE visits.rowid < ?1
            ORDER BY visits.rowid DESC
            LIMIT ?2
            """
        case .safari:
            let title = try hasColumn("history_items", "title")
                ? "history_items.title"
                : "NULL"
            return """
            SELECT history_items.url, \(title), history_visits.visit_time, NULL,
                   history_visits.rowid, history_items.id
            FROM history_visits
            JOIN history_items ON history_visits.history_item = history_items.id
            WHERE history_visits.rowid < ?1
            ORDER BY history_visits.rowid DESC
            LIMIT ?2
            """
        case .firefox:
            let title = try hasColumn("moz_places", "title") ? "moz_places.title" : "NULL"
            let visitCount = try hasColumn("moz_places", "visit_count")
                ? "moz_places.visit_count"
                : "NULL"
            return """
            SELECT moz_places.url, \(title), moz_historyvisits.visit_date, \(visitCount),
                   moz_historyvisits.rowid, moz_places.id
            FROM moz_historyvisits
            JOIN moz_places ON moz_historyvisits.place_id = moz_places.id
            WHERE moz_historyvisits.rowid < ?1
            ORDER BY moz_historyvisits.rowid DESC
            LIMIT ?2
            """
        }
    }

    private static func schema(for engine: BrowserPrivacyEngine) -> SQLiteSchemaAllowlist {
        BrowserPrivacySQLiteWriteAdapter.verified(for: engine).schema
    }

    private static func coverage(
        discoveries: [BrowserPrivacyProviderDiscovery],
        results: [ProfileScanResult],
        reachedProfileLimit: Bool,
        reachedRecordLimit: Bool
    ) -> [BrowserPrivacyProviderCoverage] {
        discoveries.map { discovery in
            let profileResults = results.filter {
                $0.profile.browser.id == discovery.coverage.browser.id
            }
            guard !profileResults.isEmpty else { return discovery.coverage }

            let hasReadableProfile = profileResults.contains {
                $0.availability == .available || $0.availability == .partial
            }
            let requiresFullDiskAccess = discovery.coverage.requiresFullDiskAccess
                || profileResults.contains { $0.availability == .permissionDenied }
            let failedAvailability = profileResults
                .map(\.availability)
                .first { $0 != .available && $0 != .partial }
            let partial = reachedProfileLimit || reachedRecordLimit || profileResults.contains {
                $0.availability == .partial || $0.reachedRecordLimit
            } || failedAvailability != nil
            let availability: BrowserPrivacyProviderAvailability
            if hasReadableProfile {
                availability = partial ? .partial : .available
            } else {
                availability = failedAvailability ?? discovery.coverage.availability
            }
            let detail: String?
            if requiresFullDiskAccess {
                detail = L10n.text(
                    "部分配置文件需要“完全磁盘访问权限”；请在系统设置中检查授权。",
                    "Some profiles need Full Disk Access; check the permission in System Settings."
                )
            } else if profileResults.contains(where: { $0.reachedRecordLimit }) || reachedRecordLimit {
                detail = L10n.text(
                    "本次读取已达到安全上限。",
                    "History reading reached this session's safe limit."
                )
            } else if availability == .partial {
                detail = L10n.text(
                    "部分本地配置文件无法读取。",
                    "Some local profiles could not be read."
                )
            } else {
                detail = discovery.coverage.detail
            }
            let fullyScannedProfileIDs = Set(
                profileResults
                    .filter { $0.availability == .available && !$0.reachedRecordLimit }
                    .map { $0.profile.id }
            )
            return BrowserPrivacyProviderCoverage(
                browser: discovery.coverage.browser,
                availability: availability,
                profileCount: profileResults.count,
                recordCount: profileResults.reduce(0) { $0 + $1.records.count },
                detail: detail,
                requiresFullDiskAccess: requiresFullDiskAccess,
                fullyScannedProfileIDs: fullyScannedProfileIDs
            )
        }
    }

    private static func outcomeState(
        coverage: [BrowserPrivacyProviderCoverage],
        hasRecords: Bool
    ) -> BrowserPrivacyScanState {
        if coverage.contains(where: { $0.availability == .permissionDenied }) && !hasRecords {
            return .permissionDenied
        }
        if coverage.contains(where: { $0.availability != .available && $0.availability != .noProfiles }) {
            return .partial
        }
        return .completed
    }

    private static func availability(
        for failure: SQLiteSnapshotFailure
    ) -> BrowserPrivacyProviderAvailability {
        switch failure {
        case .busy: .busy
        case .permissionDenied: .permissionDenied
        case .malformedSchema: .malformedSchema
        case .timedOut: .timedOut
        case .cancelled: .unavailable
        case .corrupt, .sizeLimitExceeded, .unavailable: .unavailable
        }
    }

    private static func boundedText(
        statement: OpaquePointer,
        column: Int32,
        maximumBytes: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let byteCount = sqlite3_column_bytes(statement, column)
        guard byteCount > 0, byteCount <= maximumBytes,
              let pointer = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(byteCount)), as: UTF8.self)
    }

    private static func sqliteNumericIdentity(
        statement: OpaquePointer,
        column: Int32
    ) -> BrowserPrivacySQLiteNumericIdentity? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            .real(sqlite3_column_double(statement, column).bitPattern)
        default:
            nil
        }
    }

    private static func normalizedHostname(_ rawURL: String?) -> String? {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var hostname = components.host?.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostname.isEmpty else {
            return nil
        }
        while hostname.hasSuffix(".") { hostname.removeLast() }
        guard hostname.utf8.count <= 253,
              !hostname.contains("/") && !hostname.contains("@") else {
            return nil
        }
        return hostname
    }

    /// Search terms may only come from well-known query parameters in the
    /// already-read history URL.  A title is intentionally never treated as a
    /// search term because that would manufacture a value that the browser did
    /// not record as a query.
    private static func searchKeyword(from rawURL: String?) -> String? {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        let supportedNames: Set<String> = [
            "q", "query", "search", "search_query", "p", "text", "wd", "keyword",
        ]
        guard let rawValue = components.queryItems?.first(where: {
            supportedNames.contains($0.name.lowercased())
        })?.value else {
            return nil
        }
        let value = rawValue
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 512 else {
            return nil
        }
        return value
    }

    private static func date(
        from rawValue: Double,
        engine: BrowserPrivacyEngine
    ) -> Date? {
        guard rawValue.isFinite else { return nil }
        let unixSeconds: Double
        switch engine {
        case .chromium:
            unixSeconds = rawValue / 1_000_000 - 11_644_473_600
        case .safari:
            unixSeconds = rawValue + 978_307_200
        case .firefox:
            unixSeconds = rawValue / 1_000_000
        }
        guard unixSeconds.isFinite,
              unixSeconds >= -62_135_596_800,
              unixSeconds <= 253_402_300_799 else {
            return nil
        }
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private static func deadline(after seconds: TimeInterval) -> UInt64 {
        let delta = UInt64(max(0, seconds) * 1_000_000_000)
        let (deadline, overflow) = MonotonicClock.now.addingReportingOverflow(delta)
        return overflow ? .max : deadline
    }
}

private struct SnapshotRead: Sendable {
    let records: [BrowserPrivacyRecord]
    let reachedRecordLimit: Bool
}

private struct ProfileScanResult: Sendable {
    let profile: BrowserPrivacyProfile
    let availability: BrowserPrivacyProviderAvailability
    let records: [BrowserPrivacyRecord]
    let reachedRecordLimit: Bool
}
