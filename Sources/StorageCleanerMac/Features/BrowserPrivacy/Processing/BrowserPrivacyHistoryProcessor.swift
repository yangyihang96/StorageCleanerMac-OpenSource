import AppKit
import CSQLite
import Darwin
import Foundation

protocol BrowserPrivacyHistoryProcessing: Sendable {
    func process(records: [BrowserPrivacyRecord]) async -> BrowserPrivacyProcessingReport
    func process(plan: BrowserPrivacyCleanPlan) async -> BrowserPrivacyProcessingReport
}

extension BrowserPrivacyHistoryProcessing {
    func process(plan: BrowserPrivacyCleanPlan) async -> BrowserPrivacyProcessingReport {
        await process(records: plan.records)
    }
}

protocol BrowserPrivacyRunningApplicationChecking: Sendable {
    func runningBundleIdentifiers(matching bundleIdentifiers: Set<String>) async -> Set<String>
    func requestNormalTermination(
        bundleIdentifiers: Set<String>,
        timeoutSeconds: TimeInterval
    ) async -> Set<String>
}

extension BrowserPrivacyRunningApplicationChecking {
    func requestNormalTermination(
        bundleIdentifiers: Set<String>,
        timeoutSeconds: TimeInterval
    ) async -> Set<String> {
        await runningBundleIdentifiers(matching: bundleIdentifiers)
    }
}

struct BrowserPrivacyWorkspaceRunningApplicationChecker: BrowserPrivacyRunningApplicationChecking {
    func runningBundleIdentifiers(matching bundleIdentifiers: Set<String>) async -> Set<String> {
        await MainActor.run {
            let running = Set(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            )
            return running.intersection(bundleIdentifiers)
        }
    }

    func requestNormalTermination(
        bundleIdentifiers: Set<String>,
        timeoutSeconds: TimeInterval
    ) async -> Set<String> {
        await MainActor.run {
            for application in NSWorkspace.shared.runningApplications where
                application.bundleIdentifier.map(bundleIdentifiers.contains) == true {
                _ = application.terminate()
            }
        }
        let timeout = min(max(timeoutSeconds, 0), 5)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let running = await runningBundleIdentifiers(matching: bundleIdentifiers)
            if running.isEmpty { return [] }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await runningBundleIdentifiers(matching: bundleIdentifiers)
    }
}

/// Executes the sole automatic browser-history write path. Every group is
/// bound to a scan-time file identity, changed in a BEGIN IMMEDIATE
/// transaction, then reopened read-only before a record is reported as deleted.
struct BrowserPrivacyHistoryProcessor: BrowserPrivacyHistoryProcessing, Sendable {
    private struct GroupKey: Hashable, Sendable {
        let browserID: String
        let profileID: String
    }

    private struct ChromiumFixtureVisit {
        let rowID: Int64
        let urlID: Int64
        let visitTime: Int64
        let fromVisit: Int64
        let transition: Int64
        let segmentID: Int64
        let incrementedOmniboxTypedScore: Bool
        let visitedLinkID: Int64
    }

    private struct ChromiumFixtureURLInvariant {
        let urlID: Int64
        let visitCount: Int64
        let typedCount: Int64
        let lastVisitTime: Int64
    }

    private enum MutationVerification {
        case visitRowsOnly
        case chromiumV70([ChromiumFixtureURLInvariant])
    }

    private let registry: BrowserPrivacyProviderRegistry
    private let runningApplicationChecker: any BrowserPrivacyRunningApplicationChecking
    private let backupService: any BrowserPrivacyDatabaseBackingUp
    private let homeDirectory: URL
    private let busyRetrySeconds: TimeInterval
    private let operationTimeoutSeconds: TimeInterval
    /// Test-only state injection point for exercising the committed-but-
    /// unverified branch. Production callers leave it nil.
    private let beforeReadBackHook: (@Sendable () -> Void)?

    init(
        registry: BrowserPrivacyProviderRegistry = BrowserPrivacyProviderRegistry(),
        runningApplicationChecker: any BrowserPrivacyRunningApplicationChecking = BrowserPrivacyWorkspaceRunningApplicationChecker(),
        backupService: any BrowserPrivacyDatabaseBackingUp = BrowserPrivacyRecoveryBackupService(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        busyRetrySeconds: TimeInterval = 2,
        operationTimeoutSeconds: TimeInterval = 15,
        beforeReadBackHook: (@Sendable () -> Void)? = nil
    ) {
        self.registry = registry
        self.runningApplicationChecker = runningApplicationChecker
        self.backupService = backupService
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.busyRetrySeconds = Self.clampedSeconds(busyRetrySeconds, upperBound: 2)
        self.operationTimeoutSeconds = Self.clampedSeconds(operationTimeoutSeconds, upperBound: 15)
        self.beforeReadBackHook = beforeReadBackHook
    }

    func process(records: [BrowserPrivacyRecord]) async -> BrowserPrivacyProcessingReport {
        let uniqueRecords = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
        let grouped = Dictionary(grouping: uniqueRecords) {
            GroupKey(browserID: $0.browser.id, profileID: $0.profileID)
        }
        var entries: [BrowserPrivacyProcessingEntry] = []
        entries.reserveCapacity(grouped.count)

        for (_, records) in grouped.sorted(by: Self.groupOrder) {
            if Task.isCancelled {
                entries.append(Self.entry(
                    records: records,
                    capability: .verifiedVisitDeletion,
                    outcome: .failed,
                    detail: "Processing was cancelled before this profile was changed."
                ))
                continue
            }
            entries.append(await processGroup(records))
        }

        return BrowserPrivacyProcessingReport(
            selectedRecordCount: uniqueRecords.count,
            entries: entries
        )
    }

    func process(plan: BrowserPrivacyCleanPlan) async -> BrowserPrivacyProcessingReport {
        await process(records: plan.records)
    }

    private func processGroup(_ records: [BrowserPrivacyRecord]) async -> BrowserPrivacyProcessingEntry {
        guard let first = records.first else {
            preconditionFailure("Dictionary grouping cannot produce an empty browser profile group")
        }
        guard let provider = registry.provider(id: first.browser.id) else {
            return Self.entry(
                records: records,
                capability: .unsupported,
                outcome: .unsupported,
                detail: "The scan provider is no longer registered; no database was changed."
            )
        }
        guard let adapter = provider.historyWriteAdapter else {
            return Self.entry(
                records: records,
                capability: .manualBrowserGuidance,
                outcome: .manual,
                detail: BrowserPrivacySQLiteWriteAdapter.manualGuidanceReason(
                    for: first.browser.engine
                )
            )
        }
        guard !provider.descriptor.bundleIdentifiers.isEmpty else {
            return Self.entry(
                records: records,
                capability: .unsupported,
                outcome: .unsupported,
                detail: "The browser process cannot be identified safely; no database was changed."
            )
        }
        guard records.allSatisfy({ $0.locator != nil }) else {
            return Self.entry(
                records: records,
                capability: .manualBrowserGuidance,
                outcome: .manual,
                detail: BrowserPrivacySQLiteWriteAdapter.manualGuidanceReason(
                    for: first.browser.engine
                )
            )
        }
        guard adapter.engine == first.browser.engine,
              (adapter == BrowserPrivacySQLiteWriteAdapter.verified(for: adapter.engine)
                  || adapter == .chromiumV70Fixture
                  || adapter == .chromiumProduction),
              let locators = Self.validatedLocators(
                  records,
                  descriptor: provider.descriptor,
                  adapter: adapter,
                  homeDirectory: homeDirectory
              ) else {
            return Self.entry(
                records: records,
                capability: .unsupported,
                outcome: .unsupported,
                detail: "The selected rows do not share one trusted scan-time database identity."
            )
        }

        let runningBundleIDs = await runningApplicationChecker.runningBundleIdentifiers(
            matching: Set(provider.descriptor.bundleIdentifiers)
        )
        guard runningBundleIDs.isEmpty else {
            return Self.entry(
                records: records,
                capability: .verifiedVisitDeletion,
                outcome: .failed,
                detail: "Quit \(first.browser.displayName) normally, then try again. The browser is still running."
            )
        }

        let locator = locators[0]
        let source = SQLiteSnapshotSource(
            databaseURL: locator.databaseURL,
            trustedParentURL: locator.trustedParentURL
        )
        var recoveryBackup: BrowserPrivacyRecoveryBackup?
        do {
            try Self.validateSQLiteSidecars(
                databaseURL: locator.databaseURL,
                trustedParentURL: locator.trustedParentURL,
                adapter: adapter
            )
            let backupDeadline = Self.addingClamped(
                MonotonicClock.now,
                Self.nanoseconds(seconds: operationTimeoutSeconds)
            )
            let backup = try await backupService.backup(
                source: source,
                schema: adapter.schema,
                browserID: first.browser.id,
                profileID: first.profileID,
                deadlineNanoseconds: backupDeadline
            )
            recoveryBackup = backup
            let busySeconds = busyRetrySeconds
            let timeoutSeconds = operationTimeoutSeconds
            try await Task.detached(priority: .utility) {
                try Self.deleteAndVerify(
                    locators: locators,
                    adapter: adapter,
                    busyRetrySeconds: busySeconds,
                    operationTimeoutSeconds: timeoutSeconds,
                    beforeReadBackHook: self.beforeReadBackHook
                )
            }.value
            return Self.entry(
                records: records,
                capability: .verifiedVisitDeletion,
                outcome: .deleted,
                verifiedDeletedRecordIDs: Set(records.map(\.id)),
                recoveryBackupID: backup.id,
                detail: "The selected visit rows were deleted and confirmed absent by a new read-only check."
            )
        } catch let failure as BrowserPrivacyHistoryProcessingFailure {
            if failure == .rollbackFailed, let recoveryBackup {
                do {
                    let restoreDeadline = Self.addingClamped(
                        MonotonicClock.now,
                        Self.nanoseconds(seconds: operationTimeoutSeconds)
                    )
                    try await backupService.restore(
                        recoveryBackup,
                        destination: source,
                        schema: adapter.schema,
                        deadlineNanoseconds: restoreDeadline
                    )
                    return Self.entry(
                        records: records,
                        capability: .verifiedVisitDeletion,
                        outcome: .failed,
                        recoveryBackupID: recoveryBackup.id,
                        detail: "SQLite rollback could not be confirmed, so the verified recovery backup was restored. No deletion is reported."
                    )
                } catch {
                    return Self.entry(
                        records: records,
                        capability: .verifiedVisitDeletion,
                        outcome: .indeterminate,
                        recoveryBackupID: recoveryBackup.id,
                        detail: "SQLite rollback and automatic recovery could not be confirmed. Stop processing and keep the recovery backup."
                    )
                }
            }
            let outcome: BrowserPrivacyProcessingOutcome = if failure.requiresManualHandling {
                .manual
            } else if failure.isUnsupported {
                .unsupported
            } else if failure.isIndeterminate {
                .indeterminate
            } else {
                .failed
            }
            return Self.entry(
                records: records,
                capability: failure.requiresManualHandling
                    ? .manualBrowserGuidance
                    : (failure.isUnsupported ? .unsupported : .verifiedVisitDeletion),
                outcome: outcome,
                recoveryBackupID: recoveryBackup?.id,
                detail: failure.detail
            )
        } catch let failure as SQLiteSnapshotFailure {
            return Self.entry(
                records: records,
                capability: .verifiedVisitDeletion,
                outcome: .failed,
                recoveryBackupID: recoveryBackup?.id,
                detail: Self.detail(for: failure)
            )
        } catch {
            return Self.entry(
                records: records,
                capability: .verifiedVisitDeletion,
                outcome: .failed,
                recoveryBackupID: recoveryBackup?.id,
                detail: "The transaction failed and was rolled back; no deletion was confirmed."
            )
        }
    }

    private static func validatedLocators(
        _ records: [BrowserPrivacyRecord],
        descriptor: BrowserPrivacyProviderDescriptor,
        adapter: BrowserPrivacySQLiteWriteAdapter,
        homeDirectory: URL
    ) -> [BrowserPrivacyRecordLocator]? {
        let locators = records.compactMap(\.locator)
        guard locators.count == records.count,
              let first = locators.first,
              !first.identityChain.isEmpty,
              first.visitTimestampIdentity.doubleValue.isFinite,
              !first.rawURL.isEmpty,
              first.providerID == descriptor.id,
              first.profileID == records[0].profileID,
              first.engine == adapter.engine,
              Set(locators.map(\.visitRowID)).count == locators.count,
              zip(records, locators).allSatisfy({ record, locator in
                  record.profileID == locator.profileID
                      && record.browser.id == locator.providerID
                      && record.browser.engine == locator.engine
                      && record.browser == records[0].browser
                      && locator.providerID == first.providerID
                      && locator.profileID == first.profileID
                      && locator.engine == first.engine
                      && locator.visitTimestampIdentity.doubleValue.isFinite
                      && !locator.rawURL.isEmpty
                      && record.url == locator.rawURL
                      && locator.databaseURL.standardizedFileURL == first.databaseURL.standardizedFileURL
                      && locator.trustedParentURL.standardizedFileURL == first.trustedParentURL.standardizedFileURL
                      && locator.identityChain == first.identityChain
              }) else {
            return nil
        }
        if adapter == .chromiumProduction {
            guard let registeredRoot = descriptor.productionWriteRoot(
                browser: records[0].browser,
                homeDirectory: homeDirectory,
                databaseURL: first.databaseURL
            ), first.trustedParentURL.standardizedFileURL == registeredRoot else {
                return nil
            }
        }
        return locators.sorted { $0.visitRowID < $1.visitRowID }
    }

    private static func deleteAndVerify(
        locators: [BrowserPrivacyRecordLocator],
        adapter: BrowserPrivacySQLiteWriteAdapter,
        busyRetrySeconds: TimeInterval,
        operationTimeoutSeconds: TimeInterval,
        beforeReadBackHook: (@Sendable () -> Void)?
    ) throws {
        guard let locator = locators.first else { return }
        let deadline = addingClamped(
            MonotonicClock.now,
            nanoseconds(seconds: operationTimeoutSeconds)
        )
        let busyDeadline = min(
            deadline,
            addingClamped(MonotonicClock.now, nanoseconds(seconds: busyRetrySeconds))
        )
        let control = SQLiteExecutionControl(deadlineNanoseconds: deadline)
        try control.check()

        let expectedIdentity = try secureIdentityChain(for: locator)
        guard expectedIdentity == locator.identityChain else {
            throw BrowserPrivacyHistoryProcessingFailure.identityChanged
        }
        let canonicalDatabaseURL = try SecureSourceFile.canonicalizedURL(
            for: locator.databaseURL,
            trustedParent: locator.trustedParentURL,
            expectedIdentityChain: secureSourceIdentity(expectedIdentity)
        )
        try requireFixtureMutationBoundary(
            adapter: adapter,
            canonicalDatabaseURL: canonicalDatabaseURL
        )
        try validateSQLiteSidecars(
            databaseURL: locator.databaseURL,
            trustedParentURL: locator.trustedParentURL,
            adapter: adapter
        )

        guard try secureIdentityChain(for: locator) == expectedIdentity else {
            throw BrowserPrivacyHistoryProcessingFailure.identityChanged
        }
        try validateSQLiteSidecars(
            databaseURL: locator.databaseURL,
            trustedParentURL: locator.trustedParentURL,
            adapter: adapter
        )
        let verification = try deleteRowsInTransaction(
            locators: locators,
            adapter: adapter,
            canonicalDatabaseURL: canonicalDatabaseURL,
            expectedIdentity: expectedIdentity,
            control: control,
            busyDeadline: busyDeadline
        )

        // A browser can change the file again after our commit. The hook is
        // nil in production and only lets fixture tests deterministically
        // exercise the indeterminate/read-back-failure state.
        beforeReadBackHook?()

        do {
            guard try secureIdentityChain(for: locator) == expectedIdentity else {
                throw BrowserPrivacyHistoryProcessingFailure.identityChanged
            }
            try verifyRowsAbsent(
                locators: locators,
                adapter: adapter,
                canonicalDatabaseURL: canonicalDatabaseURL,
                expectedIdentity: expectedIdentity,
                control: control,
                busyDeadline: busyDeadline,
                verification: verification
            )
        } catch {
            throw BrowserPrivacyHistoryProcessingFailure.committedButUnverified
        }
    }

    private static func deleteRowsInTransaction(
        locators: [BrowserPrivacyRecordLocator],
        adapter: BrowserPrivacySQLiteWriteAdapter,
        canonicalDatabaseURL: URL,
        expectedIdentity: [BrowserPrivacyPathIdentity],
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> MutationVerification {
        guard let locator = locators.first else { return .visitRowsOnly }
        return try SQLiteRuntime.withWritableDatabase(
            at: canonicalDatabaseURL,
            control: control,
            busyDeadlineNanoseconds: busyDeadline,
            // The source path was canonicalized and its identity chain was
            // rechecked immediately before opening. Keep the final SQLite
            // open from following a last-second symlink replacement.
            forbidSymbolicLinks: true
        ) { database in
            try requireFixtureMutationBoundary(
                adapter: adapter,
                canonicalDatabaseURL: canonicalDatabaseURL
            )
            guard try secureIdentityChain(for: locator) == expectedIdentity else {
                throw BrowserPrivacyHistoryProcessingFailure.identityChanged
            }
            try SQLiteRuntime.requireUnmoved(database: database)
            try SQLiteRuntime.validate(
                schema: adapter.schema,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadline
            )
            try requirePlainRowIDTable(
                adapter.visitTable,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            try requireNoTriggers(
                on: adapter.visitTable,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )

            var transactionOpen = false
            do {
                try execute(
                    "BEGIN IMMEDIATE",
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
                transactionOpen = true
                for rowLocator in locators {
                    guard try rowExists(
                        rowID: rowLocator.visitRowID,
                        table: adapter.visitTable,
                        database: database,
                        control: control,
                        busyDeadline: busyDeadline
                    ) else {
                        throw BrowserPrivacyHistoryProcessingFailure.missingLocator
                    }
                    guard try rowMatchesScanIdentity(
                        rowLocator,
                        adapter: adapter,
                        database: database,
                        control: control,
                        busyDeadline: busyDeadline
                    ) else {
                        throw BrowserPrivacyHistoryProcessingFailure.staleLocator
                    }
                }
                try requireSQLiteIntegrity(
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
                if adapter.mutationPlan == .chromiumV70Fixture
                    || adapter.mutationPlan == .chromiumProduction {
                    try validateChromiumV70Schema(
                        adapter: adapter,
                        database: database,
                        control: control,
                        busyDeadline: busyDeadline
                    )
                }

                let authorizer = BrowserPrivacySQLiteWriteAuthorizer(adapter: adapter)
                let retainedAuthorizer = Unmanaged.passRetained(authorizer)
                let context = retainedAuthorizer.toOpaque()
                guard sqlite3_set_authorizer(
                    database,
                    browserPrivacySQLiteAuthorizer,
                    context
                ) == SQLITE_OK else {
                    retainedAuthorizer.release()
                    throw SQLiteSnapshotFailure.unavailable
                }
                defer {
                    sqlite3_set_authorizer(database, nil, nil)
                    retainedAuthorizer.release()
                }

                let verification: MutationVerification
                switch adapter.mutationPlan {
                case .visitRowOnly:
                    for rowLocator in locators {
                        try deleteRow(
                            rowID: rowLocator.visitRowID,
                            table: adapter.visitTable,
                            database: database,
                            control: control,
                            busyDeadline: busyDeadline
                        )
                    }
                    verification = .visitRowsOnly
                case .chromiumV70Fixture:
                    verification = .chromiumV70(try mutateChromiumV70(
                        locators: locators,
                        adapter: adapter,
                        database: database,
                        control: control,
                        busyDeadline: busyDeadline
                    ))
                case .chromiumProduction:
                    verification = .chromiumV70(try mutateChromiumV70(
                        locators: locators,
                        adapter: adapter,
                        database: database,
                        control: control,
                        busyDeadline: busyDeadline
                    ))
                }
                try verifyMutation(
                    verification,
                    locators: locators,
                    adapter: adapter,
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
                try requireSQLiteIntegrity(
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
                guard try secureIdentityChain(for: locator) == expectedIdentity else {
                    throw BrowserPrivacyHistoryProcessingFailure.identityChanged
                }
                try SQLiteRuntime.requireUnmoved(database: database)
                try execute(
                    "COMMIT",
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
                transactionOpen = false
                return verification
            } catch {
                if transactionOpen {
                    do {
                        try execute(
                            "ROLLBACK",
                            database: database,
                            control: control,
                            busyDeadline: busyDeadline
                        )
                    } catch {
                        throw BrowserPrivacyHistoryProcessingFailure.rollbackFailed
                    }
                }
                throw error
            }
        }
    }

    private static func requireSQLiteIntegrity(
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        let foreignKeys = try SQLiteRuntime.prepare(
            "PRAGMA foreign_key_check",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(foreignKeys) }
        guard try SQLiteRuntime.step(
            foreignKeys,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_DONE else {
            throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
        }

        let quickCheck = try SQLiteRuntime.prepare(
            "PRAGMA quick_check(1)",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(quickCheck) }
        guard try SQLiteRuntime.step(
            quickCheck,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_ROW,
        let value = sqlite3_column_text(quickCheck, 0),
        String(cString: value) == "ok",
        try SQLiteRuntime.step(
            quickCheck,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_DONE else {
            throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
        }
    }

    private static func verifyRowsAbsent(
        locators: [BrowserPrivacyRecordLocator],
        adapter: BrowserPrivacySQLiteWriteAdapter,
        canonicalDatabaseURL: URL,
        expectedIdentity: [BrowserPrivacyPathIdentity],
        control: SQLiteExecutionControl,
        busyDeadline: UInt64,
        verification: MutationVerification
    ) throws {
        guard let locator = locators.first else { return }
        try SQLiteRuntime.withReadOnlyDatabase(
            at: canonicalDatabaseURL,
            control: control,
            busyDeadlineNanoseconds: busyDeadline,
            forbidSymbolicLinks: true
        ) { database in
            guard try secureIdentityChain(for: locator) == expectedIdentity else {
                throw BrowserPrivacyHistoryProcessingFailure.identityChanged
            }
            try SQLiteRuntime.requireUnmoved(database: database)
            try SQLiteRuntime.validate(
                schema: adapter.schema,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadline
            )
            if adapter.mutationPlan == .chromiumV70Fixture
                || adapter.mutationPlan == .chromiumProduction {
                try validateChromiumV70Schema(
                    adapter: adapter,
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
            }
            try verifyMutation(
                verification,
                locators: locators,
                adapter: adapter,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
        }
    }

    private static func requireFixtureMutationBoundary(
        adapter: BrowserPrivacySQLiteWriteAdapter,
        canonicalDatabaseURL: URL
    ) throws {
        guard adapter.mutationPlan == .chromiumV70Fixture else { return }
        guard adapter == .chromiumV70Fixture else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL
        let databaseURL = canonicalDatabaseURL.resolvingSymlinksInPath().standardizedFileURL
        guard databaseURL.path.hasPrefix(temporaryRoot.path + "/") else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
        let markerURL = databaseURL.deletingLastPathComponent().appendingPathComponent(
            BrowserPrivacySQLiteWriteAdapter.chromiumFixtureMarkerName
        )
        let expectedMarker = BrowserPrivacySQLiteWriteAdapter.chromiumFixtureMarkerContents
        var metadata = stat()
        guard lstat(markerURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_size == off_t(expectedMarker.utf8.count),
              try String(contentsOf: markerURL, encoding: .utf8)
                == expectedMarker else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
    }

    private static func mutateChromiumV70(
        locators: [BrowserPrivacyRecordLocator],
        adapter: BrowserPrivacySQLiteWriteAdapter,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> [ChromiumFixtureURLInvariant] {
        for table in adapter.schema.requiredTables.map(\.name) {
            try requireNoTriggers(
                on: table,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
        }
        let selectedIDs = Set(locators.map(\.visitRowID))
        let identifierList = selectedIDs.sorted().map(String.init).joined(separator: ",")
        if adapter.mutationPlan == .chromiumProduction {
            for sql in [
                "SELECT 1 FROM clusters_and_visits WHERE visit_id IN (\(identifierList)) LIMIT 1",
                "SELECT 1 FROM cluster_visit_duplicates WHERE visit_id IN (\(identifierList)) OR duplicate_visit_id IN (\(identifierList)) LIMIT 1",
                "SELECT 1 FROM visits WHERE rowid NOT IN (\(identifierList)) AND opener_visit IN (\(identifierList)) LIMIT 1",
                """
                SELECT 1 FROM visits WHERE rowid IN (\(identifierList)) AND (
                    is_known_to_sync != 0
                    OR COALESCE(originator_cache_guid, '') != ''
                    OR COALESCE(originator_visit_id, 0) != 0
                    OR COALESCE(originator_from_visit, 0) != 0
                    OR COALESCE(originator_opener_visit, 0) != 0
                ) LIMIT 1
                """,
            ] where try hasRows(
                sql,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            ) {
                throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
            }
        }
        let visits = try chromiumFixtureVisits(
            identifierList: identifierList,
            database: database,
            control: control,
            busyDeadline: busyDeadline
        )
        let byID = Dictionary(uniqueKeysWithValues: visits.map { ($0.rowID, $0) })
        guard visits.count == selectedIDs.count,
              visits.allSatisfy({ $0.visitedLinkID == 0 }),
              locators.allSatisfy({ locator in
                  byID[locator.visitRowID]?.urlID == locator.parentRowID
              }) else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
        for segmentID in Set(visits.map(\.segmentID)).subtracting([0]) where !(try hasRows(
            "SELECT 1 FROM segments WHERE id = \(segmentID) LIMIT 1",
            database: database,
            control: control,
            busyDeadline: busyDeadline
        )) {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }

        var repairedFromVisits: [Int64: Int64] = [:]
        for visit in visits {
            var fromVisit = visit.fromVisit
            var seen: Set<Int64> = []
            while selectedIDs.contains(fromVisit) {
                guard seen.insert(fromVisit).inserted, let parent = byID[fromVisit] else {
                    throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
                }
                fromVisit = parent.fromVisit
            }
            if fromVisit != 0 {
                guard try rowExists(
                    rowID: fromVisit,
                    table: adapter.visitTable,
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                ) else {
                    throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
                }
            }
            repairedFromVisits[visit.rowID] = fromVisit
        }

        var invariants: [ChromiumFixtureURLInvariant] = []
        for (urlID, selectedVisits) in Dictionary(grouping: visits, by: \.urlID) {
            guard let lastVisitTime = integerScalar(
                "SELECT MAX(visit_time) FROM visits WHERE url = \(urlID) AND rowid NOT IN (\(identifierList))",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            ), let current = chromiumURLInvariant(
                urlID: urlID,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            ) else {
                // A last-visit delete is intentionally outside this fixture plan.
                throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
            }
            let visitDecrement = Int64(selectedVisits.filter {
                ($0.transition & 0xff) != 8
            }.count)
            let typedDecrement = Int64(selectedVisits.filter(
                \.incrementedOmniboxTypedScore
            ).count)
            guard current.visitCount >= visitDecrement,
                  current.typedCount >= typedDecrement else {
                throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
            }
            invariants.append(ChromiumFixtureURLInvariant(
                urlID: urlID,
                visitCount: current.visitCount - visitDecrement,
                typedCount: current.typedCount - typedDecrement,
                lastVisitTime: lastVisitTime
            ))
        }

        for (rowID, fromVisit) in repairedFromVisits {
            try executeBoundUpdate(
                "UPDATE visits SET from_visit = ?1 WHERE from_visit = ?2",
                values: [fromVisit, rowID],
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
        }
        try execute("DELETE FROM visit_source WHERE id IN (\(identifierList))", database: database, control: control, busyDeadline: busyDeadline)
        try execute("DELETE FROM context_annotations WHERE visit_id IN (\(identifierList))", database: database, control: control, busyDeadline: busyDeadline)
        try execute("DELETE FROM content_annotations WHERE visit_id IN (\(identifierList))", database: database, control: control, busyDeadline: busyDeadline)
        try execute("DELETE FROM visits WHERE rowid IN (\(identifierList))", database: database, control: control, busyDeadline: busyDeadline)
        guard sqlite3_changes(database) == selectedIDs.count else {
            throw BrowserPrivacyHistoryProcessingFailure.missingLocator
        }
        for invariant in invariants {
            try executeBoundUpdate(
                "UPDATE urls SET visit_count = ?1, typed_count = ?2, last_visit_time = ?3 WHERE id = ?4",
                values: [
                    invariant.visitCount, invariant.typedCount,
                    invariant.lastVisitTime, invariant.urlID,
                ],
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            guard sqlite3_changes(database) == 1 else {
                throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
            }
        }
        return invariants
    }

    private static func verifyMutation(
        _ verification: MutationVerification,
        locators: [BrowserPrivacyRecordLocator],
        adapter: BrowserPrivacySQLiteWriteAdapter,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        for locator in locators where try rowExists(
            rowID: locator.visitRowID,
            table: adapter.visitTable,
            database: database,
            control: control,
            busyDeadline: busyDeadline
        ) {
            _ = locator
            throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
        }
        guard case let .chromiumV70(invariants) = verification else { return }
        let identifierList = locators.map(\.visitRowID).sorted().map(String.init).joined(separator: ",")
        for (table, column) in [
            ("visit_source", "id"),
            ("context_annotations", "visit_id"),
            ("content_annotations", "visit_id"),
            ("visits", "from_visit"),
        ] where try hasRows(
            "SELECT 1 FROM \(table) WHERE \(column) IN (\(identifierList)) LIMIT 1",
            database: database,
            control: control,
            busyDeadline: busyDeadline
        ) {
            throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
        }
        for expected in invariants {
            guard let actual = chromiumURLInvariant(
                urlID: expected.urlID,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            ), actual.visitCount == expected.visitCount,
               actual.typedCount == expected.typedCount,
               actual.lastVisitTime == expected.lastVisitTime else {
                throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
            }
        }
    }

    private static func validateChromiumV70Schema(
        adapter: BrowserPrivacySQLiteWriteAdapter,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        if adapter == .chromiumProduction {
            guard try adapter.matchesChromiumProductionSchema(
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadline
            ) else {
                throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
            }
            return
        }
        guard adapter == .chromiumV70Fixture else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
        for table in adapter.schema.requiredTables {
            guard try SQLiteRuntime.tableColumns(
                table.name,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadline
            ) == table.requiredColumns else {
                throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
            }
        }
        guard integerScalar(
            """
            SELECT CASE
                WHEN typeof(value) = 'integer' AND value = 70 THEN 70
                WHEN typeof(value) = 'text' AND value = '70' THEN 70
                ELSE NULL
            END
            FROM meta WHERE key = 'version' LIMIT 1
            """,
            database: database,
            control: control,
            busyDeadline: busyDeadline
        ) == 70 else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
    }

    private static func chromiumFixtureVisits(
        identifierList: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> [ChromiumFixtureVisit] {
        let statement = try SQLiteRuntime.prepare(
            """
            SELECT rowid, url, visit_time, from_visit, transition, segment_id,
                   incremented_omnibox_typed_score, visited_link_id
            FROM visits WHERE rowid IN (\(identifierList)) ORDER BY rowid
            """,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        var result: [ChromiumFixtureVisit] = []
        while try SQLiteRuntime.step(statement, control: control, busyDeadlineNanoseconds: busyDeadline) == SQLITE_ROW {
            result.append(ChromiumFixtureVisit(
                rowID: sqlite3_column_int64(statement, 0),
                urlID: sqlite3_column_int64(statement, 1),
                visitTime: sqlite3_column_int64(statement, 2),
                fromVisit: sqlite3_column_int64(statement, 3),
                transition: sqlite3_column_int64(statement, 4),
                segmentID: sqlite3_column_int64(statement, 5),
                incrementedOmniboxTypedScore: sqlite3_column_int64(statement, 6) != 0,
                visitedLinkID: sqlite3_column_int64(statement, 7)
            ))
        }
        return result
    }

    private static func chromiumURLInvariant(
        urlID: Int64,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) -> ChromiumFixtureURLInvariant? {
        guard let statement = try? SQLiteRuntime.prepare(
            "SELECT visit_count, typed_count, last_visit_time FROM urls WHERE id = \(urlID) LIMIT 1",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard (try? SQLiteRuntime.step(statement, control: control, busyDeadlineNanoseconds: busyDeadline)) == SQLITE_ROW else { return nil }
        return ChromiumFixtureURLInvariant(
            urlID: urlID,
            visitCount: sqlite3_column_int64(statement, 0),
            typedCount: sqlite3_column_int64(statement, 1),
            lastVisitTime: sqlite3_column_int64(statement, 2)
        )
    }

    private static func integerScalar(
        _ sql: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) -> Int64? {
        guard let statement = try? SQLiteRuntime.prepare(
            sql, database: database, control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard (try? SQLiteRuntime.step(statement, control: control, busyDeadlineNanoseconds: busyDeadline)) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static func hasRows(
        _ sql: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> Bool {
        let statement = try SQLiteRuntime.prepare(
            sql,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        return try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_ROW
    }

    private static func executeBoundUpdate(
        _ sql: String,
        values: [Int64],
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        let statement = try SQLiteRuntime.prepare(
            sql, database: database, control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(index + 1), value) == SQLITE_OK else {
                throw SQLiteSnapshotFailure.malformedSchema
            }
        }
        guard try SQLiteRuntime.step(statement, control: control, busyDeadlineNanoseconds: busyDeadline) == SQLITE_DONE else {
            throw SQLiteSnapshotFailure.unavailable
        }
    }

    private static func requirePlainRowIDTable(
        _ table: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        let statement = try SQLiteRuntime.prepare(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, table, -1, browserPrivacySQLiteTransient) == SQLITE_OK,
              try SQLiteRuntime.step(
                  statement,
                  control: control,
                  busyDeadlineNanoseconds: busyDeadline
              ) == SQLITE_ROW,
              let sqlText = sqlite3_column_text(statement, 0) else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
        let declaration = String(cString: sqlText).uppercased()
        guard !declaration.contains("WITHOUT ROWID"),
              !declaration.hasPrefix("CREATE VIRTUAL TABLE") else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }

        let rowIDProbe = try SQLiteRuntime.prepare(
            "SELECT rowid FROM \(table) LIMIT 0",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        sqlite3_finalize(rowIDProbe)
    }

    private static func requireNoTriggers(
        on table: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        let statement = try SQLiteRuntime.prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?1 LIMIT 1",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, table, -1, browserPrivacySQLiteTransient) == SQLITE_OK else {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
        if try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_ROW {
            throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
        }
    }

    private static func rowExists(
        rowID: Int64,
        table: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> Bool {
        let statement = try SQLiteRuntime.prepare(
            "SELECT 1 FROM \(table) WHERE rowid = ?1 LIMIT 1",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, rowID) == SQLITE_OK else {
            throw SQLiteSnapshotFailure.malformedSchema
        }
        return try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_ROW
    }

    private static func rowMatchesScanIdentity(
        _ locator: BrowserPrivacyRecordLocator,
        adapter: BrowserPrivacySQLiteWriteAdapter,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> Bool {
        let statement = try SQLiteRuntime.prepare(
            adapter.rowIdentityQuery,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, locator.visitRowID) == SQLITE_OK,
              try SQLiteRuntime.step(
                  statement,
                  control: control,
                  busyDeadlineNanoseconds: busyDeadline
              ) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let timestampIdentity = sqliteNumericIdentity(
                  statement: statement,
                  column: 2
              ),
              let rawURL = boundedText(statement: statement, column: 1, maximumBytes: 8_192) else {
            return false
        }
        return sqlite3_column_int64(statement, 0) == locator.parentRowID
            && rawURL == locator.rawURL
            && timestampIdentity == locator.visitTimestampIdentity
    }

    private static func boundedText(
        statement: OpaquePointer,
        column: Int32,
        maximumBytes: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let byteCount = sqlite3_column_bytes(statement, column)
        guard byteCount > 0,
              byteCount <= maximumBytes,
              let pointer = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: Int(byteCount)),
            as: UTF8.self
        )
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

    private static func deleteRow(
        rowID: Int64,
        table: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        let statement = try SQLiteRuntime.prepare(
            "DELETE FROM \(table) WHERE rowid = ?1",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, rowID) == SQLITE_OK,
              try SQLiteRuntime.step(
                  statement,
                  control: control,
                  busyDeadlineNanoseconds: busyDeadline
              ) == SQLITE_DONE,
              sqlite3_changes(database) == 1 else {
            throw BrowserPrivacyHistoryProcessingFailure.missingLocator
        }
    }

    private static func execute(
        _ sql: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        let statement = try SQLiteRuntime.prepare(
            sql,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        guard try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_DONE else {
            throw SQLiteSnapshotFailure.unavailable
        }
    }

    private static func secureIdentityChain(
        for locator: BrowserPrivacyRecordLocator
    ) throws -> [BrowserPrivacyPathIdentity] {
        try SecureSourceFile.identityChain(
            for: locator.databaseURL,
            trustedParent: locator.trustedParentURL,
            expectedFinalKind: .regularFile
        ).map {
            BrowserPrivacyPathIdentity(
                device: $0.device,
                inode: $0.inode,
                kind: UInt32($0.kind)
            )
        }
    }

    private static func secureSourceIdentity(
        _ chain: [BrowserPrivacyPathIdentity]
    ) -> [SecureSourceFile.Identity] {
        chain.map {
            SecureSourceFile.Identity(
                device: $0.device,
                inode: $0.inode,
                kind: mode_t($0.kind)
            )
        }
    }

    private static func validateSQLiteSidecars(
        databaseURL: URL,
        trustedParentURL: URL,
        adapter: BrowserPrivacySQLiteWriteAdapter
    ) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            var metadata = stat()
            if lstat(sidecar.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw SecureSourceFile.failure(forErrno: errno)
            }
            if adapter == .chromiumProduction {
                throw BrowserPrivacyHistoryProcessingFailure.productionSidecarPresent
            }
            _ = try SecureSourceFile.identityChain(
                for: sidecar,
                trustedParent: trustedParentURL,
                expectedFinalKind: .regularFile
            )
        }
    }

    private static func entry(
        records: [BrowserPrivacyRecord],
        capability: BrowserPrivacyWriteCapability,
        outcome: BrowserPrivacyProcessingOutcome,
        verifiedDeletedRecordIDs: Set<UUID> = [],
        recoveryBackupID: UUID? = nil,
        detail: String
    ) -> BrowserPrivacyProcessingEntry {
        BrowserPrivacyProcessingEntry(
            browser: records[0].browser,
            profileID: records[0].profileID,
            recordCount: records.count,
            capability: capability,
            outcome: outcome,
            verifiedDeletedRecordIDs: verifiedDeletedRecordIDs,
            recoveryBackupID: recoveryBackupID,
            detail: detail
        )
    }

    private static func groupOrder(
        _ lhs: (key: GroupKey, value: [BrowserPrivacyRecord]),
        _ rhs: (key: GroupKey, value: [BrowserPrivacyRecord])
    ) -> Bool {
        if lhs.value[0].browser.displayName != rhs.value[0].browser.displayName {
            return lhs.value[0].browser.displayName < rhs.value[0].browser.displayName
        }
        return lhs.key.profileID < rhs.key.profileID
    }

    private static func detail(for failure: SQLiteSnapshotFailure) -> String {
        switch failure {
        case .busy:
            "The history database stayed busy; the transaction was not committed."
        case .permissionDenied:
            "The history database is not writable with the current permission; no deletion was confirmed."
        case .malformedSchema:
            "The browser schema did not match the verified visit-row adapter."
        case .corrupt:
            "SQLite reported a corrupt or invalid history database; no deletion was confirmed."
        case .sizeLimitExceeded:
            "The database exceeded the safe operation limit; no deletion was attempted."
        case .timedOut:
            "The operation timed out and the open transaction was rolled back."
        case .cancelled:
            "Processing was cancelled and the open transaction was rolled back."
        case .unavailable:
            "The database changed identity or became unavailable; no deletion was confirmed."
        }
    }

    private static func clampedSeconds(
        _ value: TimeInterval,
        upperBound: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return upperBound }
        return min(max(value, 0.01), upperBound)
    }

    private static func nanoseconds(seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    }

    private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}

private enum BrowserPrivacyHistoryProcessingFailure: Error, Equatable, Sendable {
    case identityChanged
    case missingLocator
    case staleLocator
    case verificationFailed
    case committedButUnverified
    case unsupportedSchema
    case productionSidecarPresent
    case rollbackFailed

    var isUnsupported: Bool { self == .unsupportedSchema }
    var isIndeterminate: Bool { self == .committedButUnverified }
    var requiresManualHandling: Bool { self == .productionSidecarPresent }

    var detail: String {
        switch self {
        case .identityChanged:
            "The trusted path or database identity changed after scanning; no deletion was confirmed."
        case .missingLocator:
            "At least one selected visit row no longer exists. The profile transaction was rolled back."
        case .staleLocator:
            "A selected row was reused or changed after scanning. The profile transaction was rolled back."
        case .verificationFailed:
            "The read-only verification could not prove every selected row absent."
        case .committedButUnverified:
            "SQLite committed the profile change, but the final read-only check failed. Re-scan before taking any further action."
        case .unsupportedSchema:
            "This schema uses unsupported row or trigger semantics. Process it manually in the browser."
        case .productionSidecarPresent:
            "The production history database has an active SQLite sidecar. Process it manually in the browser after normal shutdown."
        case .rollbackFailed:
            "SQLite could not confirm rollback. The recovery backup was retained and no deletion is reported as successful."
        }
    }
}

final class BrowserPrivacySQLiteWriteAuthorizer {
    let deleteTables: Set<String>
    let updateColumns: [String: Set<String>]

    init(adapter: BrowserPrivacySQLiteWriteAdapter) {
        switch adapter.mutationPlan {
        case .visitRowOnly:
            deleteTables = [adapter.visitTable]
            updateColumns = [:]
        case .chromiumV70Fixture:
            deleteTables = [
                "visit_source", "context_annotations", "content_annotations", "visits",
            ]
            updateColumns = [
                "visits": ["from_visit"],
                "urls": ["visit_count", "typed_count", "last_visit_time"],
            ]
        case .chromiumProduction:
            deleteTables = [
                "visit_source", "context_annotations", "content_annotations", "visits",
            ]
            updateColumns = [
                "visits": ["from_visit"],
                "urls": ["visit_count", "typed_count", "last_visit_time"],
            ]
        }
    }
}

typealias BrowserPrivacySQLiteAuthorizerCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
) -> Int32

let browserPrivacySQLiteAuthorizer: BrowserPrivacySQLiteAuthorizerCallback = { context, action, argument1, argument2, _, _ in
    guard let context else { return SQLITE_DENY }
    let authorizer = Unmanaged<BrowserPrivacySQLiteWriteAuthorizer>
        .fromOpaque(context)
        .takeUnretainedValue()
    switch action {
    case SQLITE_DELETE:
        guard let argument1,
              authorizer.deleteTables.contains(String(cString: argument1)) else {
            return SQLITE_DENY
        }
        return SQLITE_OK
    case SQLITE_UPDATE:
        guard let argument1, let argument2,
              authorizer.updateColumns[String(cString: argument1)]?
                .contains(String(cString: argument2)) == true else {
            return SQLITE_DENY
        }
        return SQLITE_OK
    case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_TRANSACTION,
         SQLITE_SAVEPOINT, SQLITE_RECURSIVE:
        return SQLITE_OK
    case SQLITE_PRAGMA:
        guard let argument1,
              ["foreign_key_check", "quick_check"].contains(String(cString: argument1)) else {
            return SQLITE_DENY
        }
        return SQLITE_OK
    default:
        return SQLITE_DENY
    }
}

private let browserPrivacySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
