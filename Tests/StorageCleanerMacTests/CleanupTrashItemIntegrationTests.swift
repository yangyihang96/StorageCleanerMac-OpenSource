#if STORAGE_CLEANER_RC_TRASH_INTEGRATION
import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class CleanupTrashItemIntegrationTests: XCTestCase {
    private struct PlanBundle {
        let plan: CleanPlan
        let context: CleanupExecutionContext
        let executor: SafeCleanupExecutor
    }

    private enum IntegrationError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message): message
            }
        }
    }

    func testRealTrashItemOnDisposableAPFSVolumes() async throws {
        let environment = ProcessInfo.processInfo.environment
        let readWriteRoot = try environmentURL("SC_RC_TRASH_RW_ROOT", environment)
        let readOnlyRoot = try environmentURL("SC_RC_TRASH_RO_ROOT", environment)
        let readOnlyImage = try environmentURL("SC_RC_TRASH_RO_IMAGE", environment)
        let detachRoot = try environmentURL("SC_RC_TRASH_DETACH_ROOT", environment)
        let runLabel = environment["SC_RC_TRASH_RUN"] ?? "unknown"

        try require(getuid() != 0, "integration test must not run as root")
        try require(geteuid() == getuid(), "integration test must not have elevated euid")
        try proveIsolatedVolume(readWriteRoot, expectedReadOnly: false)
        try proveIsolatedVolume(readOnlyRoot, expectedReadOnly: false)
        try proveIsolatedVolume(detachRoot, expectedReadOnly: false)

        let personalTrashStamp = fileStamp(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true)
        )
        print("RC_TRASH_ENV|run=\(runLabel)|filesystem=APFS|account=non-root-disposable-volume")

        let normal = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "normal-file",
            name: "cache.bin",
            data: Data("normal-file-data".utf8)
        )
        let normalBundle = try makePlan(urls: [normal.url], home: normal.home)
        let normalResult = try await execute(normalBundle)
        let normalReceipt = try onlyReceipt(normalResult.report)
        try require(normalResult.preflight.readyCount == 1, "normal file preflight not ready")
        try require(normalResult.report.summary.movedItemCount == 1, "normal file not moved")
        pass(1, "ordinary-file-moved")

        try require(
            PathSafety.isContained(
                normalReceipt.resultingItemURL.path,
                in: readWriteRoot.path,
                resolvingSymlinks: false
            ),
            "trashItem returned a path outside the disposable volume"
        )
        try require(
            !PathSafety.isContained(
                normalReceipt.resultingItemURL.path,
                in: FileManager.default.homeDirectoryForCurrentUser.path,
                resolvingSymlinks: false
            ),
            "trashItem returned a path inside the personal home"
        )
        pass(15, "result-url=\(relativePath(normalReceipt.resultingItemURL, root: readWriteRoot))")

        try require(
            normalReceipt.movedIdentity == normalResult.plan.items[0].expectedSnapshot.identity,
            "moved identity differs from scan identity"
        )
        try require(normalReceipt.verification == .identityVerified, "identity verification failed")
        pass(16, "device-and-inode-verified")

        try require(!FileManager.default.fileExists(atPath: normal.url.path), "original path remains")
        pass(17, "original-path-absent")

        let movedNormalData = try Data(contentsOf: normalReceipt.resultingItemURL)
        try require(movedNormalData == normal.data, "file data changed during trash move")
        pass(18, "content-bytes-unchanged")

        try require(normalResult.report.outcome == .completed, "normal report not completed")
        try require(normalResult.report.summary.failedItemCount == 0, "normal report has failure")
        pass(19, "report-matches-system-result")

        try require(normalReceipt.isRestorable, "normal receipt is not restorable")
        try require(
            normalResult.report.summary.permanentlyFreedBytes == 0,
            "trash move was reported as permanent release"
        )
        try require(
            normalResult.report.summary.reclaimableAfterEmptyingTrashBytes
                == normalResult.plan.estimatedMovableBytes,
            "estimated reclaimable bytes do not match plan"
        )
        pass(20, "recoverable-and-estimated-space-correct")

        let directory = try makeDirectory(
            volumeRoot: readWriteRoot,
            scenario: "normal-directory",
            name: "Cache Folder",
            childData: Data("directory-data".utf8)
        )
        let directoryResult = try await execute(
            makePlan(urls: [directory.url], home: directory.home)
        )
        let directoryReceipt = try onlyReceipt(directoryResult.report)
        try require(
            FileManager.default.fileExists(
                atPath: directoryReceipt.resultingItemURL
                    .appendingPathComponent("child.bin").path
            ),
            "directory contents did not move with directory"
        )
        pass(2, "ordinary-directory-moved")

        let multi = try makeFiles(
            volumeRoot: readWriteRoot,
            scenario: "multi-plan",
            names: ["one.bin", "two.bin", "three.bin"]
        )
        let multiResult = try await execute(makePlan(urls: multi.urls, home: multi.home))
        try require(multiResult.report.summary.movedItemCount == 3, "multi plan was incomplete")
        try require(multiResult.report.restorableReceipts.count == 3, "multi receipts missing")
        pass(3, "multi-item-plan-moved-three")

        let unicode = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "unicode",
            name: "缓存-测试-🍋.bin",
            data: Data("unicode".utf8)
        )
        let unicodeResult = try await execute(makePlan(urls: [unicode.url], home: unicode.home))
        try require(unicodeResult.report.summary.movedItemCount == 1, "unicode file not moved")
        pass(4, "unicode-name-moved")

        let special = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "special-name",
            name: "space # [fixture]\nline.bin",
            data: Data("special".utf8)
        )
        let specialResult = try await execute(makePlan(urls: [special.url], home: special.home))
        try require(specialResult.report.summary.movedItemCount == 1, "special file not moved")
        pass(5, "space-newline-special-name-moved")

        let conflictHome = try makeHome(volumeRoot: readWriteRoot, scenario: "name-conflict")
        let firstParent = conflictHome.cache.appendingPathComponent("first", isDirectory: true)
        let secondParent = conflictHome.cache.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: true)
        let firstSameName = firstParent.appendingPathComponent("same.bin")
        let secondSameName = secondParent.appendingPathComponent("same.bin")
        try Data("first".utf8).write(to: firstSameName)
        try Data("second".utf8).write(to: secondSameName)
        let conflictResult = try await execute(
            makePlan(
                urls: [firstSameName, secondSameName],
                home: conflictHome.home
            )
        )
        let conflictDestinations = Set(
            conflictResult.report.restorableReceipts.map(\.resultingItemURL.path)
        )
        try require(conflictDestinations.count == 2, "same-name destinations collided")
        pass(6, "same-name-targets-remained-distinct")

        let vanished = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "vanished",
            name: "vanish.bin",
            data: Data("vanish".utf8)
        )
        let vanishedBundle = try makePlan(urls: [vanished.url], home: vanished.home)
        let vanishedPreflight = await vanishedBundle.executor.preflight(
            plan: vanishedBundle.plan,
            context: vanishedBundle.context
        )
        try FileManager.default.removeItem(at: vanished.url)
        let vanishedReport = await execute(
            vanishedBundle,
            approved: readyIDs(vanishedPreflight)
        )
        try require(
            vanishedReport.items.map(\.outcome) == [.skipped(.itemMissing)],
            "vanished item was not skipped"
        )
        pass(7, "post-preflight-disappearance-skipped")

        let changed = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "identity-change",
            name: "changed.bin",
            data: Data("old".utf8)
        )
        let changedBundle = try makePlan(urls: [changed.url], home: changed.home)
        let changedPreflight = await changedBundle.executor.preflight(
            plan: changedBundle.plan,
            context: changedBundle.context
        )
        try FileManager.default.removeItem(at: changed.url)
        try Data("replacement".utf8).write(to: changed.url)
        let changedReport = await execute(
            changedBundle,
            approved: readyIDs(changedPreflight)
        )
        try require(
            changedReport.items.map(\.outcome) == [.skipped(.identityChanged)],
            "identity replacement was not skipped"
        )
        pass(8, "identity-change-skipped")

        let kindChanged = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "kind-change",
            name: "kind.bin",
            data: Data("file".utf8)
        )
        let kindBundle = try makePlan(urls: [kindChanged.url], home: kindChanged.home)
        let kindPreflight = await kindBundle.executor.preflight(
            plan: kindBundle.plan,
            context: kindBundle.context
        )
        try FileManager.default.removeItem(at: kindChanged.url)
        try FileManager.default.createDirectory(at: kindChanged.url, withIntermediateDirectories: false)
        let kindReport = await execute(kindBundle, approved: readyIDs(kindPreflight))
        try require(
            kindReport.items.map(\.outcome) == [.skipped(.entryKindChanged)],
            "file-to-directory replacement was not skipped"
        )
        pass(9, "file-replaced-by-directory-skipped")

        let symlink = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "symlink-swap",
            name: "swap.bin",
            data: Data("original".utf8)
        )
        let symlinkBundle = try makePlan(urls: [symlink.url], home: symlink.home)
        let symlinkPreflight = await symlinkBundle.executor.preflight(
            plan: symlinkBundle.plan,
            context: symlinkBundle.context
        )
        let symlinkTarget = symlink.home.appendingPathComponent("target.bin")
        try Data("must-remain".utf8).write(to: symlinkTarget)
        try FileManager.default.removeItem(at: symlink.url)
        try FileManager.default.createSymbolicLink(at: symlink.url, withDestinationURL: symlinkTarget)
        let symlinkReport = await execute(
            symlinkBundle,
            approved: readyIDs(symlinkPreflight)
        )
        try require(
            symlinkReport.items.map(\.outcome) == [.skipped(.symbolicLinkDetected)],
            "symlink swap was not skipped"
        )
        let symlinkTargetData = try Data(contentsOf: symlinkTarget)
        try require(symlinkTargetData == Data("must-remain".utf8), "symlink target changed")
        pass(10, "symlink-swap-skipped")

        let readOnly = try makeFile(
            volumeRoot: readOnlyRoot,
            scenario: "read-only",
            name: "readonly.bin",
            data: Data("readonly".utf8)
        )
        let readOnlyBundle = try makePlan(urls: [readOnly.url], home: readOnly.home)
        let readOnlyPreflight = await readOnlyBundle.executor.preflight(
            plan: readOnlyBundle.plan,
            context: readOnlyBundle.context
        )
        try detachVolume(readOnlyRoot)
        let remountedReadOnlyRoot = try attachReadOnly(image: readOnlyImage)
        try require(
            PathSafety.lexicalPath(remountedReadOnlyRoot.path)
                == PathSafety.lexicalPath(readOnlyRoot.path),
            "read-only image remounted at an unexpected path"
        )
        try proveIsolatedVolume(readOnlyRoot, expectedReadOnly: true)
        let remountedReadOnlySnapshot = try FoundationReadOnlyFileSystem().snapshot(at: readOnly.url)
        try require(
            remountedReadOnlySnapshot.volumeIdentifier
                == readOnlyBundle.plan.items[0].expectedSnapshot.volumeIdentifier,
            "read-only remount changed volume identity"
        )
        try require(!remountedReadOnlySnapshot.isWritableVolume, "read-only snapshot was writable")
        let readOnlyReport = await execute(
            readOnlyBundle,
            approved: readyIDs(readOnlyPreflight)
        )
        try require(
            readOnlyReport.items.map(\.outcome) == [.skipped(.volumeReadOnly)],
            "read-only volume was not skipped"
        )
        pass(11, "read-only-volume-skipped")

        let disconnected = try makeFile(
            volumeRoot: detachRoot,
            scenario: "disconnected",
            name: "disconnect.bin",
            data: Data("disconnect".utf8)
        )
        let disconnectedBundle = try makePlan(
            urls: [disconnected.url],
            home: disconnected.home
        )
        let disconnectedPreflight = await disconnectedBundle.executor.preflight(
            plan: disconnectedBundle.plan,
            context: disconnectedBundle.context
        )
        try detachVolume(detachRoot)
        let disconnectedReport = await execute(
            disconnectedBundle,
            approved: readyIDs(disconnectedPreflight)
        )
        try require(
            disconnectedReport.items.map(\.outcome) == [.skipped(.volumeUnavailable)],
            "disconnected volume was not skipped"
        )
        pass(12, "disconnected-volume-skipped")

        let partial = try makeFiles(
            volumeRoot: readWriteRoot,
            scenario: "partial",
            names: ["keep-moving.bin", "disappear.bin"]
        )
        let partialBundle = try makePlan(urls: partial.urls, home: partial.home)
        let partialPreflight = await partialBundle.executor.preflight(
            plan: partialBundle.plan,
            context: partialBundle.context
        )
        try FileManager.default.removeItem(at: partial.urls[1])
        let partialReport = await execute(
            partialBundle,
            approved: readyIDs(partialPreflight)
        )
        try require(partialReport.summary.movedItemCount == 1, "partial move count incorrect")
        try require(partialReport.summary.skippedItemCount == 1, "partial skip count incorrect")
        try require(partialReport.outcome == .partiallyCompleted, "partial outcome incorrect")
        pass(13, "single-failure-did-not-expand")

        let cancellable = try makeFiles(
            volumeRoot: readWriteRoot,
            scenario: "cancel",
            names: ["cancel-1.bin", "cancel-2.bin", "cancel-3.bin"]
        )
        let cancelBundle = try makePlan(urls: cancellable.urls, home: cancellable.home)
        let cancelPreflight = await cancelBundle.executor.preflight(
            plan: cancelBundle.plan,
            context: cancelBundle.context
        )
        let cancelContext = approvedContext(
            cancelBundle.context,
            approved: readyIDs(cancelPreflight)
        )
        let cancelTask = Task {
            await cancelBundle.executor.execute(
                plan: cancelBundle.plan,
                context: cancelContext
            ) { progress in
                if progress.movedItemCount == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let cancelReport = await cancelTask.value
        try require(cancelReport.outcome == .cancelled, "cancel outcome incorrect")
        try require(cancelReport.summary.movedItemCount == 1, "cancel moved unexpected count")
        try require(cancelReport.summary.notProcessedItemCount == 2, "cancel did not preserve remaining")
        pass(14, "safe-cancel-after-current-move")

        let restorable = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "restore",
            name: "restore.bin",
            data: Data("restore-data".utf8)
        )
        let restoreResult = try await execute(makePlan(urls: [restorable.url], home: restorable.home))
        let restoreReceipt = try onlyReceipt(restoreResult.report)
        let recovery = await CleanupRecoveryService().restore(
            receipts: [restoreReceipt],
            userHomeURL: restorable.home,
            trashURL: restoreReceipt.resultingItemURL.deletingLastPathComponent(),
            quarantineRootURL: restorable.home.appendingPathComponent("Quarantine")
        )
        try require(recovery.items.map(\.outcome) == [.restored], "restore did not succeed")
        let restoredData = try Data(contentsOf: restorable.url)
        try require(restoredData == restorable.data, "restored data changed")
        pass(21, "identity-checked-restore-succeeded")

        let restoreConflict = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "restore-conflict",
            name: "conflict.bin",
            data: Data("trash-copy".utf8)
        )
        let restoreConflictResult = try await execute(
            makePlan(urls: [restoreConflict.url], home: restoreConflict.home)
        )
        let restoreConflictReceipt = try onlyReceipt(restoreConflictResult.report)
        try Data("existing-destination".utf8).write(to: restoreConflict.url)
        let conflictRecovery = await CleanupRecoveryService().restore(
            receipts: [restoreConflictReceipt],
            userHomeURL: restoreConflict.home,
            trashURL: restoreConflictReceipt.resultingItemURL.deletingLastPathComponent(),
            quarantineRootURL: restoreConflict.home.appendingPathComponent("Quarantine")
        )
        try require(
            conflictRecovery.items.map(\.outcome) == [.conflict],
            "restore overwrote an existing destination"
        )
        pass(22, "restore-conflict-refused")

        let restoreChanged = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "restore-identity",
            name: "identity.bin",
            data: Data("original-trash".utf8)
        )
        let restoreChangedResult = try await execute(
            makePlan(urls: [restoreChanged.url], home: restoreChanged.home)
        )
        let restoreChangedReceipt = try onlyReceipt(restoreChangedResult.report)
        try FileManager.default.removeItem(at: restoreChangedReceipt.resultingItemURL)
        try Data("replacement-trash".utf8).write(to: restoreChangedReceipt.resultingItemURL)
        let changedRecovery = await CleanupRecoveryService().restore(
            receipts: [restoreChangedReceipt],
            userHomeURL: restoreChanged.home,
            trashURL: restoreChangedReceipt.resultingItemURL.deletingLastPathComponent(),
            quarantineRootURL: restoreChanged.home.appendingPathComponent("Quarantine")
        )
        try require(
            changedRecovery.items.map(\.outcome) == [.identityChanged],
            "restore accepted a changed source identity"
        )
        pass(23, "restore-source-identity-change-refused")

        let repeated = try makeFile(
            volumeRoot: readWriteRoot,
            scenario: "repeat-plan",
            name: "repeat.bin",
            data: Data("repeat".utf8)
        )
        let repeatedBundle = try makePlan(urls: [repeated.url], home: repeated.home)
        let repeatedPreflight = await repeatedBundle.executor.preflight(
            plan: repeatedBundle.plan,
            context: repeatedBundle.context
        )
        let repeatedContext = approvedContext(
            repeatedBundle.context,
            approved: readyIDs(repeatedPreflight)
        )
        let firstExecution = await repeatedBundle.executor.execute(
            plan: repeatedBundle.plan,
            context: repeatedContext,
            progress: { _ in }
        )
        let secondExecution = await repeatedBundle.executor.execute(
            plan: repeatedBundle.plan,
            context: repeatedContext,
            progress: { _ in }
        )
        try require(firstExecution.summary.movedItemCount == 1, "first execution did not move")
        try require(secondExecution.outcome == .failed, "repeated plan was not rejected")
        try require(secondExecution.summary.failedItemCount == 1, "repeat failure not reported")
        pass(24, "repeated-plan-rejected")

        try require(
            fileStamp(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".Trash", isDirectory: true)
            ) == personalTrashStamp,
            "personal Trash metadata changed during disposable-volume test"
        )
        print("RC_TRASH_ENV|run=\(runLabel)|personal-trash=unchanged|privilege=none")
    }

    private func makePlan(
        urls: [URL],
        home: URL,
        requiredClosedBundleIDs: [String] = []
    ) throws -> PlanBundle {
        let sessionID = ScanSessionID()
        let root = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let rule = CleanupRule(
            id: "rc.fixture",
            selectionPolicyVersion: 1,
            categoryID: "rc",
            categoryTitleKey: "rc.category",
            titleKey: "rc.rule",
            root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Caches"),
            maximumDepth: 8,
            minimumAgeDays: 0,
            minimumBytes: 0,
            include: CleanupRuleMatch(
                entryKinds: [.regularFile, .directory],
                extensions: [],
                nameMatcher: CleanupNameMatcher(mode: .any, values: [])
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .skipPlaceholder,
            risk: .safe,
            recommendation: .recommended,
            defaultSelection: .selected,
            executionEligibility: .eligible,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrash,
            requiredClosedBundleIDs: requiredClosedBundleIDs,
            reasonKey: "rc.fixture"
        )
        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "rc-trash-v1",
            rules: [rule]
        )
        let fileSystem = FoundationReadOnlyFileSystem()
        let candidates = try urls.map { url -> ScanCandidate in
            let snapshot = try fileSystem.snapshot(at: url)
            return ScanCandidate(
                id: ScanCandidateID(),
                sessionID: sessionID,
                ruleID: rule.id,
                ruleSelectionPolicyVersion: rule.selectionPolicyVersion,
                categoryID: rule.categoryID,
                categoryTitle: "RC",
                subcategoryTitle: "Fixture",
                sourceURL: url,
                allowedRootURL: root,
                snapshot: snapshot,
                risk: .safe,
                recommendation: CleanupRecommendation(
                    level: .recommended,
                    reasonCode: rule.reasonKey,
                    evidenceCodes: ["isolated-apfs"]
                ),
                defaultSelection: .selected,
                executionEligibility: .eligible,
                measurementCompleteness: .complete,
                isManuallySelectable: true,
                action: .moveToTrash,
                requiredClosedBundleIDs: requiredClosedBundleIDs,
                reason: "Disposable APFS fixture"
            )
        }
        let session = ScanSession(
            id: sessionID,
            rulesVersion: rules.rulesVersion,
            startedAt: Date(),
            completedAt: Date(),
            outcome: .complete,
            categories: [
                CleanupScanCategory(
                    id: "rc",
                    title: "RC",
                    subcategories: [
                        CleanupScanSubcategory(
                            id: rule.id,
                            title: "Fixture",
                            risk: .safe,
                            recommendation: .recommended,
                            reason: "Disposable APFS fixture",
                            candidates: candidates
                        )
                    ]
                )
            ],
            issues: [],
            permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: candidates.count,
                candidateCount: candidates.count,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: CleanupByteCount.sum(
                    candidates.map(\.snapshot.logicalSizeBytes)
                ),
                duration: 0
            )
        )
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: CleanupSelection(
                selectedCandidateIDs: Set(candidates.map(\.id))
            ),
            activeRules: rules,
            disposition: .trash
        )
        return PlanBundle(
            plan: plan,
            context: CleanupExecutionContext(
                featureConfiguration: .productDefault,
                activeSessionID: session.id,
                activeRules: rules,
                userHomeURL: home,
                excludedURLs: [],
                approvedPlanItemIDs: nil
            ),
            executor: SafeCleanupExecutor(coordinator: HeavyWorkCoordinator())
        )
    }

    private func execute(
        _ bundle: PlanBundle
    ) async throws -> (plan: CleanPlan, preflight: CleanPreflightReport, report: CleanReport) {
        let preflight = await bundle.executor.preflight(
            plan: bundle.plan,
            context: bundle.context
        )
        try require(preflight.failure == nil, "preflight failed")
        let report = await execute(bundle, approved: readyIDs(preflight))
        return (bundle.plan, preflight, report)
    }

    private func execute(
        _ bundle: PlanBundle,
        approved: Set<UUID>
    ) async -> CleanReport {
        await bundle.executor.execute(
            plan: bundle.plan,
            context: approvedContext(bundle.context, approved: approved),
            progress: { _ in }
        )
    }

    private func approvedContext(
        _ context: CleanupExecutionContext,
        approved: Set<UUID>
    ) -> CleanupExecutionContext {
        CleanupExecutionContext(
            featureConfiguration: context.featureConfiguration,
            activeSessionID: context.activeSessionID,
            activeRules: context.activeRules,
            userHomeURL: context.userHomeURL,
            excludedURLs: context.excludedURLs,
            approvedPlanItemIDs: approved
        )
    }

    private func readyIDs(_ report: CleanPreflightReport) -> Set<UUID> {
        Set(report.items.compactMap {
            $0.status == .ready ? $0.planItemID : nil
        })
    }

    private func onlyReceipt(_ report: CleanReport) throws -> CleanupMoveReceipt {
        try require(report.restorableReceipts.count == 1, "expected one restorable receipt")
        return report.restorableReceipts[0]
    }

    private func makeHome(
        volumeRoot: URL,
        scenario: String
    ) throws -> (home: URL, cache: URL) {
        let home = volumeRoot
            .appendingPathComponent("StorageCleanerRCFixtures", isDirectory: true)
            .appendingPathComponent(scenario, isDirectory: true)
            .appendingPathComponent("Home", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return (home, cache)
    }

    private func makeFile(
        volumeRoot: URL,
        scenario: String,
        name: String,
        data: Data
    ) throws -> (home: URL, url: URL, data: Data) {
        let fixture = try makeHome(volumeRoot: volumeRoot, scenario: scenario)
        let url = fixture.cache.appendingPathComponent(name)
        try data.write(to: url)
        return (fixture.home, url, data)
    }

    private func makeFiles(
        volumeRoot: URL,
        scenario: String,
        names: [String]
    ) throws -> (home: URL, urls: [URL]) {
        let fixture = try makeHome(volumeRoot: volumeRoot, scenario: scenario)
        let urls = try names.enumerated().map { index, name in
            let url = fixture.cache.appendingPathComponent(name)
            try Data("fixture-\(index)".utf8).write(to: url)
            return url
        }
        return (fixture.home, urls)
    }

    private func makeDirectory(
        volumeRoot: URL,
        scenario: String,
        name: String,
        childData: Data
    ) throws -> (home: URL, url: URL) {
        let fixture = try makeHome(volumeRoot: volumeRoot, scenario: scenario)
        let url = fixture.cache.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try childData.write(to: url.appendingPathComponent("child.bin"))
        return (fixture.home, url)
    }

    private func environmentURL(
        _ key: String,
        _ environment: [String: String]
    ) throws -> URL {
        guard let value = environment[key], !value.isEmpty else {
            throw IntegrationError.failed("missing \(key)")
        }
        return URL(fileURLWithPath: value, isDirectory: key.hasSuffix("_ROOT"))
    }

    private func proveIsolatedVolume(
        _ root: URL,
        expectedReadOnly: Bool
    ) throws {
        try require(
            root.path.hasPrefix("/Volumes/StorageCleanerRC-"),
            "test mount is outside the dedicated temporary boundary"
        )
        let keys: Set<URLResourceKey> = [
            .volumeIdentifierKey,
            .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        let rootValues = try root.resourceValues(forKeys: keys)
        let homeValues = try FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeIdentifierKey])
        var fileSystemStatus = statfs()
        let fileSystemStatusResult = root.withUnsafeFileSystemRepresentation { path in
            statfs(path, &fileSystemStatus)
        }
        try require(rootValues.volumeIdentifier != nil, "test volume has no identifier")
        try require(
            String(describing: rootValues.volumeIdentifier)
                != String(describing: homeValues.volumeIdentifier),
            "test volume is the personal home volume"
        )
        try require(
            fileSystemStatusResult == 0
                && (fileSystemStatus.f_flags & UInt32(MNT_RDONLY) != 0) == expectedReadOnly,
            "test volume read-only state differs from expectation"
        )
        try require(
            rootValues.volumeLocalizedFormatDescription?.contains("APFS") == true,
            "test volume is not APFS"
        )
    }

    private func attachReadOnly(image: URL) throws -> URL {
        let output = try runHdiutil([
            "attach",
            "-readonly",
            image.path
        ])
        guard let path = output
            .split(whereSeparator: \.isNewline)
            .flatMap({ $0.split(whereSeparator: \.isWhitespace) })
            .map(String.init)
            .first(where: { $0.hasPrefix("/Volumes/StorageCleanerRC-") }) else {
            throw IntegrationError.failed("read-only image did not return a fixture mount path")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func detachVolume(_ mountPoint: URL) throws {
        _ = try runHdiutil(["detach", mountPoint.path])
    }

    private func runHdiutil(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        try require(
            process.terminationStatus == 0,
            "hdiutil failed with status \(process.terminationStatus)"
        )
        return text
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let raw = url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count))
            : "<outside-test-volume>"
        return raw.replacingOccurrences(of: "\n", with: "\\n")
    }

    private func fileStamp(_ url: URL) -> String? {
        var status = stat()
        guard url.withUnsafeFileSystemRepresentation({
            Darwin.lstat($0, &status)
        }) == 0 else {
            return nil
        }
        return [
            String(status.st_dev),
            String(status.st_ino),
            String(status.st_mtimespec.tv_sec),
            String(status.st_mtimespec.tv_nsec),
            String(status.st_ctimespec.tv_sec),
            String(status.st_ctimespec.tv_nsec),
            String(status.st_size)
        ].joined(separator: ":")
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw IntegrationError.failed(message)
        }
    }

    private func pass(_ scenario: Int, _ detail: String) {
        print("RC_TRASH_SCENARIO|\(scenario)|PASS|\(detail)")
    }
}
#endif
