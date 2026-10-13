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
        let isDirectlyDeletable: Bool
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

    /// The state the database must be in after the transaction. It is
    /// computed before the first write, checked before COMMIT, and checked
    /// once more on a fresh read-only connection.
    private struct ChromiumMutationExpectation {
        let deletedVisitIDs: [Int64]
        /// URLs that keep at least one visit: counters follow Chromium.
        var updatedURLs: [ChromiumFixtureURLInvariant] = []
        /// URLs left without any visit: the row and its dependents go.
        var deletedURLIDs: [Int64] = []
        var deletedSegmentIDs: [Int64] = []
        var remainingVisitedLinkCounts: [Int64: Int64] = [:]
        var deletedVisitedLinkIDs: [Int64] = []
        var emptiedClusterIDs: [Int64] = []
    }

    private enum MutationVerification {
        case visitRowsOnly
        case chromiumV70(ChromiumMutationExpectation)
    }

    /// A prepared statement that is rebound for each row of a batch, so a
    /// large selection does not re-parse the same SQL thousands of times.
    private final class ReusableStatement {
        private let handle: OpaquePointer
        private let control: SQLiteExecutionControl
        private let busyDeadline: UInt64

        init(
            _ sql: String,
            database: OpaquePointer,
            control: SQLiteExecutionControl,
            busyDeadline: UInt64
        ) throws {
            handle = try SQLiteRuntime.prepare(
                sql,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadline
            )
            self.control = control
            self.busyDeadline = busyDeadline
        }

        deinit {
            sqlite3_finalize(handle)
        }

        private func bind(_ values: [Int64]) throws {
            sqlite3_reset(handle)
            for (index, value) in values.enumerated() {
                guard sqlite3_bind_int64(handle, Int32(index + 1), value) == SQLITE_OK else {
                    throw SQLiteSnapshotFailure.malformedSchema
                }
            }
        }

        /// Runs a write to completion.
        func run(_ values: [Int64]) throws {
            try bind(values)
            defer { sqlite3_reset(handle) }
            guard try SQLiteRuntime.step(
                handle,
                control: control,
                busyDeadlineNanoseconds: busyDeadline
            ) == SQLITE_DONE else {
                throw SQLiteSnapshotFailure.unavailable
            }
        }

        /// Visits result rows until `body` returns false.
        func forEachRow(
            _ values: [Int64],
            _ body: (OpaquePointer) -> Bool
        ) throws {
            try bind(values)
            defer { sqlite3_reset(handle) }
            while try SQLiteRuntime.step(
                handle,
                control: control,
                busyDeadlineNanoseconds: busyDeadline
            ) == SQLITE_ROW {
                guard body(handle) else { return }
            }
        }

        /// The first column of every result row.
        func integers(_ values: [Int64]) throws -> [Int64] {
            var result: [Int64] = []
            try forEachRow(values) { statement in
                result.append(sqlite3_column_int64(statement, 0))
                return true
            }
            return result
        }
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
    /// Test-only: runs inside the write transaction, right after BEGIN, so a
    /// test can expire the deadline or raise an unexpected error there.
    /// Production callers leave it nil.
    private let inTransactionHook: (@Sendable (SQLiteExecutionControl) throws -> Void)?

    init(
        registry: BrowserPrivacyProviderRegistry = BrowserPrivacyProviderRegistry(),
        runningApplicationChecker: any BrowserPrivacyRunningApplicationChecking = BrowserPrivacyWorkspaceRunningApplicationChecker(),
        backupService: any BrowserPrivacyDatabaseBackingUp = BrowserPrivacyRecoveryBackupService(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        busyRetrySeconds: TimeInterval = 2,
        operationTimeoutSeconds: TimeInterval = 15,
        beforeReadBackHook: (@Sendable () -> Void)? = nil,
        inTransactionHook: (@Sendable (SQLiteExecutionControl) throws -> Void)? = nil
    ) {
        self.registry = registry
        self.runningApplicationChecker = runningApplicationChecker
        self.backupService = backupService
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.busyRetrySeconds = Self.clampedSeconds(busyRetrySeconds, upperBound: 2)
        self.operationTimeoutSeconds = Self.clampedSeconds(operationTimeoutSeconds, upperBound: 15)
        self.beforeReadBackHook = beforeReadBackHook
        self.inTransactionHook = inTransactionHook
    }

    func process(records: [BrowserPrivacyRecord]) async -> BrowserPrivacyProcessingReport {
        let uniqueRecords = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
        // Records without a locator can only be handled in the browser. They
        // form their own group, so they do not hold back the records of the
        // same profile that can be deleted directly.
        let grouped = Dictionary(grouping: uniqueRecords) {
            GroupKey(
                browserID: $0.browser.id,
                profileID: $0.profileID,
                isDirectlyDeletable: $0.locator != nil
            )
        }
        var entries: [BrowserPrivacyProcessingEntry] = []
        entries.reserveCapacity(grouped.count)

        for (_, records) in grouped.sorted(by: Self.groupOrder) {
            if Task.isCancelled {
                entries.append(Self.entry(
                    records: records,
                    capability: .verifiedVisitDeletion,
                    outcome: .failed,
                    reason: .cancelled
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
                reason: .providerUnavailable
            )
        }
        guard let adapter = provider.historyWriteAdapter else {
            return Self.manualEntry(records: records)
        }
        guard !provider.descriptor.bundleIdentifiers.isEmpty else {
            return Self.entry(
                records: records,
                capability: .unsupported,
                outcome: .unsupported,
                reason: .browserProcessUnknown
            )
        }
        guard records.allSatisfy({ $0.locator != nil }) else {
            return Self.manualEntry(records: records)
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
                reason: .selectionNotTrusted
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
                reason: .browserRunning
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
                    beforeReadBackHook: self.beforeReadBackHook,
                    inTransactionHook: self.inTransactionHook
                )
            }.value
            await backupService.annotate(
                backup,
                summary: Self.recoverySummary(records: records, locators: locators, outcome: .deleted)
            )
            return Self.entry(
                records: records,
                capability: .verifiedVisitDeletion,
                outcome: .deleted,
                verifiedDeletedRecordIDs: Set(records.map(\.id)),
                recoveryBackupID: backup.id,
                reason: .deletedAndVerified
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
                    await backupService.annotate(
                        recoveryBackup,
                        summary: Self.recoverySummary(
                            records: records,
                            locators: locators,
                            outcome: .restoredAfterFailure
                        )
                    )
                    return Self.entry(
                        records: records,
                        capability: .verifiedVisitDeletion,
                        outcome: .failed,
                        recoveryBackupID: recoveryBackup.id,
                        reason: .restoredFromBackup
                    )
                } catch {
                    await backupService.annotate(
                        recoveryBackup,
                        summary: Self.recoverySummary(
                            records: records,
                            locators: locators,
                            outcome: .restoreUnconfirmed
                        )
                    )
                    return Self.entry(
                        records: records,
                        capability: .verifiedVisitDeletion,
                        outcome: .indeterminate,
                        recoveryBackupID: recoveryBackup.id,
                        reason: .restoreUnconfirmed
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
            // Only a committed change keeps its backup. Every other failure
            // here was rolled back or never started, so the copy of the
            // whole history would serve no purpose and is removed.
            var keptBackupID: UUID?
            if let recoveryBackup {
                if failure.isIndeterminate {
                    await backupService.annotate(
                        recoveryBackup,
                        summary: Self.recoverySummary(
                            records: records,
                            locators: locators,
                            outcome: .unverified
                        )
                    )
                    keptBackupID = recoveryBackup.id
                } else {
                    await backupService.discard(recoveryBackup)
                }
            }
            return Self.entry(
                records: records,
                capability: failure.requiresManualHandling
                    ? .manualBrowserGuidance
                    : (failure.isUnsupported ? .unsupported : .verifiedVisitDeletion),
                outcome: outcome,
                recoveryBackupID: keptBackupID,
                reason: failure.reason
            )
        } catch let failure as BrowserPrivacyBackupStorageFailure {
            // The backup folder could not be written; nothing is changed
            // without a backup.
            return Self.entry(
                records: records,
                capability: .verifiedVisitDeletion,
                outcome: .failed,
                reason: failure.rootIsSymbolicLink ? .backupLocationUnsafe
                    : (failure.timeMachineExclusionFailed ? .backupExclusionFailed : .backupFailed)
            )
        } catch let failure as SQLiteSnapshotFailure {
            // The transaction was rolled back or never opened.
            if let recoveryBackup {
                await backupService.discard(recoveryBackup)
            }
            return Self.entry(
                records: records,
                capability: .verifiedVisitDeletion,
                outcome: .failed,
                reason: Self.reason(for: failure)
            )
        } catch {
            // No failure this code plans for. Once the backup exists it is
            // not known whether the database changed, so the backup is kept
            // and described like any other.
            guard let recoveryBackup else {
                return Self.entry(
                    records: records,
                    capability: .verifiedVisitDeletion,
                    outcome: .failed,
                    reason: .unexpectedErrorBeforeChanges
                )
            }
            await backupService.annotate(
                recoveryBackup,
                summary: Self.recoverySummary(
                    records: records,
                    locators: locators,
                    outcome: .unexpectedError
                )
            )
            return Self.entry(
                records: records,
                capability: .verifiedVisitDeletion,
                outcome: .failed,
                recoveryBackupID: recoveryBackup.id,
                reason: .unexpectedError
            )
        }
    }

    /// Puts a browser's history database back to the state saved in
    /// `entry`. Everything visited after that backup is lost and everything
    /// deleted after it comes back, so the caller confirms with the user
    /// first. The current state is backed up before anything is written, so
    /// the restore itself can be undone from Recent Deletions.
    ///
    /// The destination is never taken from the backup's metadata: it is the
    /// profile the registry discovers now whose identifier matches the
    /// backup, under the same trust rules as a deletion. The browser must
    /// have quit and the database must have no unmerged writes.
    func restore(
        _ entry: BrowserPrivacyRecoveryEntry,
        installedApplications: [BrowserPrivacyInstalledApplication]? = nil
    ) async -> BrowserPrivacyRestoreResult {
        guard let provider = registry.provider(id: entry.browserID),
              let adapter = provider.historyWriteAdapter,
              !provider.descriptor.bundleIdentifiers.isEmpty else {
            return .init(reason: .profileUnavailable, browserName: entry.summary?.browserDisplayName)
        }
        let browserName = provider.descriptor.displayName
        let applications: [BrowserPrivacyInstalledApplication]
        if let installedApplications {
            applications = installedApplications
        } else {
            applications = await BrowserPrivacyApplicationLocator
                .discoverWithSigningIdentity(homeDirectory: homeDirectory)
        }
        let profiles = provider.discoverProfiles(
            homeDirectory: homeDirectory,
            installedApplications: applications
        ).profiles
        guard let profile = profiles.first(where: {
            BrowserPrivacyRecoveryBackupService.profileFingerprint(for: $0.id) == entry.profileFingerprint
        }) else {
            return .init(reason: .profileUnavailable, browserName: browserName)
        }
        let trustedRoot = adapter == .chromiumProduction
            ? provider.descriptor.productionWriteRoot(
                browser: profile.browser,
                homeDirectory: homeDirectory,
                databaseURL: profile.historyDatabaseURL,
                profileParentURL: profile.sourceTrustedParentURL
            )
            : profile.sourceTrustedParentURL
        guard let trustedRoot else {
            return .init(reason: .profileUnavailable, browserName: browserName)
        }

        let runningBundleIDs = await runningApplicationChecker.runningBundleIdentifiers(
            matching: Set(provider.descriptor.bundleIdentifiers)
        )
        guard runningBundleIDs.isEmpty else {
            return .init(reason: .browserRunning, browserName: browserName)
        }

        let destination = SQLiteSnapshotSource(
            databaseURL: profile.historyDatabaseURL,
            trustedParentURL: trustedRoot
        )
        let restoreLease: BrowserPrivacyRecoveryLease?
        do {
            restoreLease = try backupService.beginRestoring(entry.backup)
        } catch {
            let reason: BrowserPrivacyRestoreReason
            if error is BrowserPrivacyBackupStorageFailure {
                reason = .currentStateNotSaved
            } else {
                reason = Self.sourceBackupReason(for: error)
            }
            return .init(reason: reason, browserName: browserName)
        }
        // Keep the source protected across every suspension, undo-backup
        // annotation, and final metadata write, including failed restores.
        defer { withExtendedLifetime(restoreLease) {} }
        let undoBackup: BrowserPrivacyRecoveryBackup
        do {
            try Self.validateSQLiteSidecars(
                databaseURL: profile.historyDatabaseURL,
                trustedParentURL: trustedRoot,
                adapter: adapter
            )
            undoBackup = try await backupService.backup(
                source: destination,
                schema: adapter.schema,
                browserID: entry.browserID,
                profileID: profile.id,
                deadlineNanoseconds: Self.addingClamped(
                    MonotonicClock.now,
                    Self.nanoseconds(seconds: operationTimeoutSeconds)
                )
            )
        } catch {
            // Nothing was written. These errors concern the current database
            // or the recovery folder, never the backup being restored.
            let reason: BrowserPrivacyRestoreReason = switch error {
            case BrowserPrivacyHistoryProcessingFailure.productionSidecarPresent: .pendingWrites
            case SQLiteSnapshotFailure.busy: .databaseBusy
            case SQLiteSnapshotFailure.permissionDenied: .permissionDenied
            case SQLiteSnapshotFailure.unavailable: .databaseChanged
            case SQLiteSnapshotFailure.timedOut: .timedOut
            case SQLiteSnapshotFailure.cancelled: .cancelled
            default: .currentStateNotSaved
            }
            return .init(reason: reason, browserName: browserName)
        }
        let savedState = BrowserPrivacyRecoverySummary(
            browserDisplayName: browserName,
            profileDisplayName: profile.displayName,
            visitCount: nil,
            pageCount: nil,
            outcome: .savedBeforeRestore
        )

        let stampBefore = try? SecureSourceFile.contentStamp(at: profile.historyDatabaseURL)
        var databaseRestored = false
        do {
            try await backupService.restore(
                entry.backup,
                destination: destination,
                schema: adapter.schema,
                deadlineNanoseconds: Self.addingClamped(
                    MonotonicClock.now,
                    Self.nanoseconds(seconds: operationTimeoutSeconds)
                )
            )
            databaseRestored = true
            try backupService.finishRestoring(entry.backup)
        } catch {
            // A final marker failure happens after the database copy. It is
            // neither an undo-backup failure nor a browser write-permission error.
            let reason: BrowserPrivacyRestoreReason = databaseRestored
                ? .restoreResultNotSaved : Self.restoreReason(for: error)
            // SQLite's backup API commits the copy at once or not at all, but
            // the checks after it can still fail. If the file was touched at
            // all, keep the saved state so the user can go back to it.
            let stampAfter = try? SecureSourceFile.contentStamp(at: profile.historyDatabaseURL)
            guard stampBefore == nil || stampAfter != stampBefore else {
                await backupService.discard(undoBackup)
                return .init(reason: reason, browserName: browserName)
            }
            // Describing the saved state applies the count limit; the backup
            // being restored must not be the one that makes room for it.
            await backupService.annotate(undoBackup, summary: savedState, sparing: [entry.id])
            return .init(
                reason: reason,
                browserName: browserName,
                undoBackupID: undoBackup.id,
                historyMayHaveChanged: true
            )
        }
        await backupService.annotate(undoBackup, summary: savedState, sparing: [entry.id])
        return .init(
            reason: .restored,
            browserName: browserName,
            undoBackupID: undoBackup.id,
            historyMayHaveChanged: true
        )
    }

    private static func restoreReason(for error: any Error) -> BrowserPrivacyRestoreReason {
        switch error {
        case let SQLitePersistentBackupFailure.sourceRead(failure):
            sourceBackupReason(for: failure)
        case BrowserPrivacyHistoryProcessingFailure.identityChanged:
            .databaseChanged
        case let failure as SQLiteSnapshotFailure:
            switch failure {
            case .busy: .databaseBusy
            case .permissionDenied: .permissionDenied
            // Source validation has its own wrapper. An unclassified copy
            // failure must not claim that a validated backup is damaged.
            case .corrupt, .malformedSchema: .failed
            case .sizeLimitExceeded: .backupTooLarge
            case .timedOut: .timedOut
            case .cancelled: .cancelled
            case .unavailable: .databaseChanged
            }
        default:
            .failed
        }
    }

    private static func sourceBackupReason(for error: any Error) -> BrowserPrivacyRestoreReason {
        switch error {
        case SQLiteSnapshotFailure.busy: .backupInUse
        case SQLiteSnapshotFailure.sizeLimitExceeded: .backupTooLarge
        case SQLiteSnapshotFailure.timedOut: .timedOut
        case SQLiteSnapshotFailure.cancelled: .cancelled
        case SQLiteSnapshotFailure.unavailable, SQLiteSnapshotFailure.permissionDenied,
             SQLiteSnapshotFailure.corrupt, SQLiteSnapshotFailure.malformedSchema:
            .backupUnavailable
        default: .failed
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
        beforeReadBackHook: (@Sendable () -> Void)?,
        inTransactionHook: (@Sendable (SQLiteExecutionControl) throws -> Void)?
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
            busyDeadline: busyDeadline,
            inTransactionHook: inTransactionHook
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
        busyDeadline: UInt64,
        inTransactionHook: (@Sendable (SQLiteExecutionControl) throws -> Void)?
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
                try inTransactionHook?(control)
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
                if transactionOpen, !rollBack(database) {
                    throw BrowserPrivacyHistoryProcessingFailure.rollbackFailed
                }
                throw error
            }
        }
    }

    /// Ends the open write transaction. It runs exactly when the operation's
    /// deadline has passed or it was cancelled, so it bypasses the execution
    /// control and removes the progress handler that would interrupt it.
    private static func rollBack(_ database: OpaquePointer) -> Bool {
        sqlite3_progress_handler(database, 0, nil, nil)
        let result = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        // SQLite rolls back by itself after some I/O errors; autocommit mode
        // confirms that no transaction is left open either way.
        return result == SQLITE_OK || sqlite3_get_autocommit(database) != 0
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

    /// Removes the selected visits the way Chromium's own history deletion
    /// does (`ExpireHistoryBackend` / `VisitDatabase::DeleteVisit` /
    /// `DeleteAnnotationsForVisit` / `DeleteOneURL`):
    ///
    /// - visits that were reached from a deleted visit inherit its referrer;
    /// - the visit's source, annotation, cluster and duplicate rows go with it;
    /// - a visited-link row loses one count per deleted visit and is removed
    ///   when none is left;
    /// - a URL that keeps visits gets its counters and last-visit time
    ///   adjusted; a URL left without visits is removed together with its
    ///   search terms and segments.
    ///
    /// Everything that cannot be handled consistently is refused before the
    /// first write.
    private static func mutateChromiumV70(
        locators: [BrowserPrivacyRecordLocator],
        adapter: BrowserPrivacySQLiteWriteAdapter,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> ChromiumMutationExpectation {
        let isProduction = adapter.mutationPlan == .chromiumProduction
        let optionalTables = try existingOptionalTables(
            adapter: adapter,
            database: database,
            control: control,
            busyDeadline: busyDeadline
        )
        for table in adapter.schema.requiredTables.map(\.name) + optionalTables {
            try requireNoTriggers(
                on: table,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
        }
        let selectedIDs = Set(locators.map(\.visitRowID))
        let sortedIDs = selectedIDs.sorted()
        let chunks = identifierChunks(sortedIDs)

        if isProduction {
            // A visit that the browser has synced also exists in the account
            // and on other devices. Removing only the local row would leave
            // those copies behind, so it has to be deleted in the browser.
            for chunk in chunks where try hasRows(
                """
                SELECT 1 FROM visits WHERE rowid IN (\(chunk)) AND (
                    is_known_to_sync != 0
                    OR COALESCE(originator_cache_guid, '') != ''
                    OR COALESCE(originator_visit_id, 0) != 0
                    OR COALESCE(originator_from_visit, 0) != 0
                    OR COALESCE(originator_opener_visit, 0) != 0
                ) LIMIT 1
                """,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            ) {
                throw BrowserPrivacyHistoryProcessingFailure.syncedVisits
            }
        }

        var visits: [ChromiumFixtureVisit] = []
        visits.reserveCapacity(sortedIDs.count)
        for chunk in chunks {
            visits.append(contentsOf: try chromiumFixtureVisits(
                identifierList: chunk,
                database: database,
                control: control,
                busyDeadline: busyDeadline
            ))
        }
        let byID = Dictionary(visits.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        guard visits.count == selectedIDs.count,
              locators.allSatisfy({ locator in
                  byID[locator.visitRowID]?.urlID == locator.parentRowID
              }) else {
            throw BrowserPrivacyHistoryProcessingFailure.staleLocator
        }

        // Chromium: UPDATE visits SET from_visit = <deleted.from_visit>
        // WHERE from_visit = <deleted.id>. Walking through other selected
        // visits gives the same result as deleting them one after another.
        var repairedFromVisits: [(visitID: Int64, referrer: Int64)] = []
        repairedFromVisits.reserveCapacity(visits.count)
        for visit in visits {
            var referrer = visit.fromVisit
            var seen: Set<Int64> = [visit.rowID]
            while selectedIDs.contains(referrer) {
                guard seen.insert(referrer).inserted, let parent = byID[referrer] else {
                    throw BrowserPrivacyHistoryProcessingFailure.inconsistentDatabase
                }
                referrer = parent.fromVisit
            }
            repairedFromVisits.append((visit.rowID, referrer))
        }

        var expectation = ChromiumMutationExpectation(deletedVisitIDs: sortedIDs)

        // URLs: decide per URL whether any visit remains.
        let visitsByURL = Dictionary(grouping: visits, by: \.urlID)
        let urlVisits = try ReusableStatement(
            "SELECT rowid, visit_time FROM visits WHERE url = ?1 ORDER BY visit_time DESC, rowid DESC",
            database: database,
            control: control,
            busyDeadline: busyDeadline
        )
        let urlSegments = try ReusableStatement(
            "SELECT id FROM segments WHERE url_id = ?1",
            database: database,
            control: control,
            busyDeadline: busyDeadline
        )
        for urlID in visitsByURL.keys.sorted() {
            guard let selectedVisits = visitsByURL[urlID],
                  let current = try chromiumURLInvariant(
                      urlID: urlID,
                      database: database,
                      control: control,
                      busyDeadline: busyDeadline
                  ) else {
                throw BrowserPrivacyHistoryProcessingFailure.inconsistentDatabase
            }
            var latestRemainingVisitTime: Int64?
            try urlVisits.forEachRow([urlID]) { statement in
                if selectedIDs.contains(sqlite3_column_int64(statement, 0)) { return true }
                latestRemainingVisitTime = sqlite3_column_int64(statement, 1)
                return false
            }
            guard let latestRemainingVisitTime else {
                // No visit is left: Chromium removes the URL row itself.
                expectation.deletedURLIDs.append(urlID)
                expectation.deletedSegmentIDs.append(contentsOf: try urlSegments.integers([urlID]))
                continue
            }
            // Must stay in sync with Chromium's AddPageVisit/ExpireURLsForVisits:
            // a reload (core transition 8) never incremented visit_count, and
            // both counters are clamped at zero.
            let visitDecrement = Int64(selectedVisits.count { ($0.transition & 0xff) != 8 })
            let typedDecrement = Int64(selectedVisits.count(where: \.incrementedOmniboxTypedScore))
            expectation.updatedURLs.append(ChromiumFixtureURLInvariant(
                urlID: urlID,
                visitCount: max(0, current.visitCount - visitDecrement),
                typedCount: max(0, current.typedCount - typedDecrement),
                lastVisitTime: latestRemainingVisitTime
            ))
        }

        // Visited links: one count per deleted visit that went through the link.
        let linkedVisits = Dictionary(
            grouping: visits.filter { $0.visitedLinkID != 0 },
            by: \.visitedLinkID
        )
        if !linkedVisits.isEmpty {
            guard isProduction else {
                throw BrowserPrivacyHistoryProcessingFailure.unsupportedSchema
            }
            let linkRow = try ReusableStatement(
                "SELECT link_url_id, visit_count FROM visited_links WHERE id = ?1",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            for linkID in linkedVisits.keys.sorted() {
                guard let users = linkedVisits[linkID] else { continue }
                var row: (urlID: Int64, visitCount: Int64)?
                try linkRow.forEachRow([linkID]) { statement in
                    row = (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
                    return false
                }
                // Chromium ignores a visited-link id that has no row.
                guard let row else { continue }
                // Only touch a link row that belongs to the URL being deleted.
                guard users.allSatisfy({ $0.urlID == row.urlID }) else {
                    throw BrowserPrivacyHistoryProcessingFailure.inconsistentDatabase
                }
                let remaining = row.visitCount - Int64(users.count)
                if remaining > 0 {
                    expectation.remainingVisitedLinkCounts[linkID] = remaining
                } else {
                    expectation.deletedVisitedLinkIDs.append(linkID)
                }
            }
        }

        // Clusters: a cluster whose every member is being deleted is removed.
        if isProduction {
            var touchedClusterIDs = Set<Int64>()
            for chunk in chunks {
                touchedClusterIDs.formUnion(try integerColumn(
                    "SELECT DISTINCT cluster_id FROM clusters_and_visits WHERE visit_id IN (\(chunk))",
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                ))
            }
            if !touchedClusterIDs.isEmpty {
                let clusterMembers = try ReusableStatement(
                    "SELECT visit_id FROM clusters_and_visits WHERE cluster_id = ?1",
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
                for clusterID in touchedClusterIDs.sorted() {
                    var keepsAMember = false
                    try clusterMembers.forEachRow([clusterID]) { statement in
                        if selectedIDs.contains(sqlite3_column_int64(statement, 0)) { return true }
                        keepsAMember = true
                        return false
                    }
                    if !keepsAMember {
                        expectation.emptiedClusterIDs.append(clusterID)
                    }
                }
            }
        }

        // ---- Writes. Nothing above changed the database. ----

        let repairChain = try ReusableStatement(
            "UPDATE visits SET from_visit = ?1 WHERE from_visit = ?2",
            database: database,
            control: control,
            busyDeadline: busyDeadline
        )
        for repair in repairedFromVisits {
            try repairChain.run([repair.referrer, repair.visitID])
        }

        var deletedVisitCount = 0
        for chunk in chunks {
            var statements = [
                "DELETE FROM visit_source WHERE id IN (\(chunk))",
                "DELETE FROM context_annotations WHERE visit_id IN (\(chunk))",
                "DELETE FROM content_annotations WHERE visit_id IN (\(chunk))",
            ]
            if isProduction {
                statements.append(
                    "DELETE FROM cluster_visit_duplicates WHERE visit_id IN (\(chunk)) OR duplicate_visit_id IN (\(chunk))"
                )
                statements.append("DELETE FROM clusters_and_visits WHERE visit_id IN (\(chunk))")
            }
            for sql in statements {
                try execute(sql, database: database, control: control, busyDeadline: busyDeadline)
            }
            try execute(
                "DELETE FROM visits WHERE rowid IN (\(chunk))",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            deletedVisitCount += Int(sqlite3_changes(database))
        }
        guard deletedVisitCount == selectedIDs.count else {
            throw BrowserPrivacyHistoryProcessingFailure.missingLocator
        }

        if !expectation.emptiedClusterIDs.isEmpty {
            for table in optionalTables {
                let deleteCluster = try ReusableStatement(
                    "DELETE FROM \(table) WHERE cluster_id = ?1",
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
                for clusterID in expectation.emptiedClusterIDs {
                    try deleteCluster.run([clusterID])
                }
            }
        }

        if !expectation.remainingVisitedLinkCounts.isEmpty {
            let updateLink = try ReusableStatement(
                "UPDATE visited_links SET visit_count = ?1 WHERE id = ?2",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            for linkID in expectation.remainingVisitedLinkCounts.keys.sorted() {
                guard let remaining = expectation.remainingVisitedLinkCounts[linkID] else { continue }
                try updateLink.run([remaining, linkID])
                guard sqlite3_changes(database) == 1 else {
                    throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
                }
            }
        }
        if !expectation.deletedVisitedLinkIDs.isEmpty {
            let deleteLink = try ReusableStatement(
                "DELETE FROM visited_links WHERE id = ?1",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            for linkID in expectation.deletedVisitedLinkIDs {
                try deleteLink.run([linkID])
                guard sqlite3_changes(database) == 1 else {
                    throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
                }
            }
        }

        if !expectation.deletedURLIDs.isEmpty {
            // Chromium's DeleteOneURL: segment usage, segments, the URL row,
            // then the URL's keyword search terms.
            let deleteSegmentUsage = try ReusableStatement(
                "DELETE FROM segment_usage WHERE segment_id IN (SELECT id FROM segments WHERE url_id = ?1)",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            let deleteSegments = try ReusableStatement(
                "DELETE FROM segments WHERE url_id = ?1",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            let deleteSearchTerms = isProduction
                ? try ReusableStatement(
                    "DELETE FROM keyword_search_terms WHERE url_id = ?1",
                    database: database,
                    control: control,
                    busyDeadline: busyDeadline
                )
                : nil
            let deleteURL = try ReusableStatement(
                "DELETE FROM urls WHERE id = ?1",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            for urlID in expectation.deletedURLIDs {
                try deleteSegmentUsage.run([urlID])
                try deleteSegments.run([urlID])
                try deleteSearchTerms?.run([urlID])
                try deleteURL.run([urlID])
                guard sqlite3_changes(database) == 1 else {
                    throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
                }
            }
        }

        if !expectation.updatedURLs.isEmpty {
            let updateURL = try ReusableStatement(
                "UPDATE urls SET visit_count = ?1, typed_count = ?2, last_visit_time = ?3 WHERE id = ?4",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            )
            for invariant in expectation.updatedURLs {
                try updateURL.run([
                    invariant.visitCount, invariant.typedCount,
                    invariant.lastVisitTime, invariant.urlID,
                ])
                guard sqlite3_changes(database) == 1 else {
                    throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
                }
            }
        }
        return expectation
    }

    private static func verifyMutation(
        _ verification: MutationVerification,
        locators: [BrowserPrivacyRecordLocator],
        adapter: BrowserPrivacySQLiteWriteAdapter,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws {
        guard case let .chromiumV70(expectation) = verification else {
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
            return
        }

        let isProduction = adapter.mutationPlan == .chromiumProduction
        func requireNoRows(_ sql: String) throws {
            if try hasRows(sql, database: database, control: control, busyDeadline: busyDeadline) {
                throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
            }
        }

        // No selected visit and nothing that pointed at one may remain.
        var visitReferences = [
            ("visits", "rowid"),
            ("visit_source", "id"),
            ("context_annotations", "visit_id"),
            ("content_annotations", "visit_id"),
            ("visits", "from_visit"),
        ]
        if isProduction {
            visitReferences += [
                ("clusters_and_visits", "visit_id"),
                ("cluster_visit_duplicates", "visit_id"),
                ("cluster_visit_duplicates", "duplicate_visit_id"),
            ]
        }
        for chunk in identifierChunks(expectation.deletedVisitIDs) {
            for (table, column) in visitReferences {
                try requireNoRows("SELECT 1 FROM \(table) WHERE \(column) IN (\(chunk)) LIMIT 1")
            }
        }

        // URLs that keep visits carry exactly the planned counters.
        for expected in expectation.updatedURLs {
            guard let actual = try chromiumURLInvariant(
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

        // A removed URL leaves no row, no visit and no dependent behind.
        var urlReferences = [("urls", "id"), ("visits", "url"), ("segments", "url_id")]
        if isProduction {
            urlReferences.append(("keyword_search_terms", "url_id"))
        }
        for chunk in identifierChunks(expectation.deletedURLIDs) {
            for (table, column) in urlReferences {
                try requireNoRows("SELECT 1 FROM \(table) WHERE \(column) IN (\(chunk)) LIMIT 1")
            }
        }
        for chunk in identifierChunks(expectation.deletedSegmentIDs) {
            try requireNoRows("SELECT 1 FROM segment_usage WHERE segment_id IN (\(chunk)) LIMIT 1")
        }

        guard isProduction else { return }

        for chunk in identifierChunks(expectation.deletedVisitedLinkIDs) {
            try requireNoRows("SELECT 1 FROM visited_links WHERE id IN (\(chunk)) LIMIT 1")
        }
        for (linkID, expectedCount) in expectation.remainingVisitedLinkCounts {
            guard try integerColumn(
                "SELECT visit_count FROM visited_links WHERE id = \(linkID)",
                database: database,
                control: control,
                busyDeadline: busyDeadline
            ) == [expectedCount] else {
                throw BrowserPrivacyHistoryProcessingFailure.verificationFailed
            }
        }

        let clusterTables = ["clusters_and_visits"] + (try existingOptionalTables(
            adapter: adapter,
            database: database,
            control: control,
            busyDeadline: busyDeadline
        ))
        for chunk in identifierChunks(expectation.emptiedClusterIDs) {
            for table in clusterTables {
                try requireNoRows("SELECT 1 FROM \(table) WHERE cluster_id IN (\(chunk)) LIMIT 1")
            }
        }
    }

    /// Optional tables of the adapter's contract that exist in this database.
    private static func existingOptionalTables(
        adapter: BrowserPrivacySQLiteWriteAdapter,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> [String] {
        try adapter.schema.optionalTables.map(\.name).filter {
            try SQLiteRuntime.tableExists(
                $0,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadline
            )
        }
    }

    /// Row identifiers are our own 64-bit integers, so they are inlined; the
    /// chunks keep every statement far below SQLite's SQL length limit.
    private static func identifierChunks(
        _ identifiers: [Int64],
        size: Int = 400
    ) -> [String] {
        stride(from: 0, to: identifiers.count, by: size).map { start in
            identifiers[start ..< min(start + size, identifiers.count)]
                .map(String.init)
                .joined(separator: ",")
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

    /// Nil means the URL row does not exist. A read error is thrown instead
    /// of being mistaken for a missing row.
    private static func chromiumURLInvariant(
        urlID: Int64,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> ChromiumFixtureURLInvariant? {
        let statement = try SQLiteRuntime.prepare(
            "SELECT visit_count, typed_count, last_visit_time FROM urls WHERE id = \(urlID) LIMIT 1",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        guard try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_ROW else { return nil }
        return ChromiumFixtureURLInvariant(
            urlID: urlID,
            visitCount: sqlite3_column_int64(statement, 0),
            typedCount: sqlite3_column_int64(statement, 1),
            lastVisitTime: sqlite3_column_int64(statement, 2)
        )
    }

    /// The first column of every result row.
    private static func integerColumn(
        _ sql: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadline: UInt64
    ) throws -> [Int64] {
        let statement = try SQLiteRuntime.prepare(
            sql,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        )
        defer { sqlite3_finalize(statement) }
        var result: [Int64] = []
        while try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadline
        ) == SQLITE_ROW {
            result.append(sqlite3_column_int64(statement, 0))
        }
        return result
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

    /// Shared with the restore path: a database with unmerged writes next
    /// to it is never opened for writing.
    static func validateSQLiteSidecars(
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
                // Chromium opens its databases with journal_mode=TRUNCATE, so
                // a cleanly closed History keeps an empty "-journal" file
                // next to it. SQLite ignores an empty rollback journal; it
                // holds no transaction. A journal with content, or any WAL
                // or shared-memory file, means writes that are not merged.
                if suffix == "-journal",
                   metadata.st_mode & S_IFMT == S_IFREG,
                   metadata.st_size == 0 {
                    continue
                }
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
        reason: BrowserPrivacyProcessingReason
    ) -> BrowserPrivacyProcessingEntry {
        BrowserPrivacyProcessingEntry(
            browser: records[0].browser,
            profileID: records[0].profileID,
            profileDisplayName: records[0].resolvedProfileDisplayName,
            recordCount: records.count,
            capability: capability,
            outcome: outcome,
            verifiedDeletedRecordIDs: verifiedDeletedRecordIDs,
            recoveryBackupID: recoveryBackupID,
            reason: reason,
            deletionPath: deletionPath(of: records),
            detail: reason.detail(browserName: records[0].browser.displayName)
        )
    }

    /// Groups never mix records with and without a locator.
    private static func deletionPath(of records: [BrowserPrivacyRecord]) -> BrowserPrivacyDeletionPath {
        records.allSatisfy { $0.locator != nil } ? .direct : .inBrowser
    }

    private static func recoverySummary(
        records: [BrowserPrivacyRecord],
        locators: [BrowserPrivacyRecordLocator],
        outcome: BrowserPrivacyRecoveryOutcome
    ) -> BrowserPrivacyRecoverySummary {
        BrowserPrivacyRecoverySummary(
            browserDisplayName: records[0].browser.displayName,
            profileDisplayName: records[0].resolvedProfileDisplayName,
            visitCount: records.count,
            pageCount: BrowserPrivacyDisplayItem.pageCount(of: records),
            outcome: outcome
        )
    }

    /// Records the browser has to delete itself, with the specific cause the
    /// scan recorded for them.
    static func manualEntry(records: [BrowserPrivacyRecord]) -> BrowserPrivacyProcessingEntry {
        let browser = records[0].browser
        return BrowserPrivacyProcessingEntry(
            browser: browser,
            profileID: records[0].profileID,
            profileDisplayName: records[0].resolvedProfileDisplayName,
            recordCount: records.count,
            capability: .manualBrowserGuidance,
            outcome: .manual,
            reason: .manualOnly,
            deletionPath: deletionPath(of: records),
            detail: BrowserPrivacyDirectDeletionBlocker.manualDetail(
                recorded: records.lazy.compactMap(\.directDeletionBlocker).first,
                browserName: browser.displayName,
                engine: browser.engine
            )
        )
    }

    private static func groupOrder(
        _ lhs: (key: GroupKey, value: [BrowserPrivacyRecord]),
        _ rhs: (key: GroupKey, value: [BrowserPrivacyRecord])
    ) -> Bool {
        if lhs.value[0].browser.displayName != rhs.value[0].browser.displayName {
            return lhs.value[0].browser.displayName < rhs.value[0].browser.displayName
        }
        if lhs.key.profileID != rhs.key.profileID {
            return lhs.key.profileID < rhs.key.profileID
        }
        return lhs.key.isDirectlyDeletable && !rhs.key.isDirectlyDeletable
    }

    private static func reason(for failure: SQLiteSnapshotFailure) -> BrowserPrivacyProcessingReason {
        switch failure {
        case .busy: .databaseBusy
        case .permissionDenied: .permissionDenied
        case .malformedSchema: .schemaUnsupported
        case .corrupt: .databaseDamaged
        case .sizeLimitExceeded: .databaseTooLarge
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .unavailable: .databaseUnavailable
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
    /// Related rows contradict each other, so a consistent deletion cannot be planned.
    case inconsistentDatabase
    /// The selected visits are known to the browser's sync service.
    case syncedVisits
    case productionSidecarPresent
    case rollbackFailed

    var isUnsupported: Bool { self == .unsupportedSchema || self == .inconsistentDatabase }
    var isIndeterminate: Bool { self == .committedButUnverified }
    var requiresManualHandling: Bool { self == .productionSidecarPresent || self == .syncedVisits }

    var reason: BrowserPrivacyProcessingReason {
        switch self {
        case .identityChanged: .databaseChanged
        case .missingLocator: .recordMissing
        case .staleLocator: .recordChanged
        case .verificationFailed: .verificationFailed
        case .committedButUnverified: .committedButUnverified
        case .unsupportedSchema: .schemaUnsupported
        case .inconsistentDatabase: .inconsistentData
        case .syncedVisits: .syncedRecords
        case .productionSidecarPresent: .pendingWrites
        case .rollbackFailed: .restoreUnconfirmed
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
            // Rows of a deleted visit, and of a URL left without visits.
            deleteTables = [
                "visit_source", "context_annotations", "content_annotations", "visits",
                "urls", "segments", "segment_usage",
            ]
            updateColumns = [
                "visits": ["from_visit"],
                "urls": ["visit_count", "typed_count", "last_visit_time"],
            ]
        case .chromiumProduction:
            deleteTables = [
                "visit_source", "context_annotations", "content_annotations", "visits",
                "urls", "segments", "segment_usage", "keyword_search_terms",
                "clusters_and_visits", "cluster_visit_duplicates",
                "clusters", "cluster_keywords", "visited_links",
            ]
            updateColumns = [
                "visits": ["from_visit"],
                "urls": ["visit_count", "typed_count", "last_visit_time"],
                "visited_links": ["visit_count"],
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
