import Foundation
import XCTest
@testable import StorageCleanerMac

/// D52：未识别所属应用的行仍按扫描时的修改时间复查；所有文件系统和移动均可注入。
final class CleanupWriteRecheckTests: XCTestCase {
    func testPreflightAndFinalMoveCheckTraverseExactlyTwice() async throws {
        let fixture = try WriteRecheckFixture(fileCount: 1_024)
        let executor = fixture.executor()
        let preflight = await executor.preflight(plan: fixture.plan, context: fixture.context)
        XCTAssertEqual(preflight.items.map(\.status), [.ready])
        XCTAssertEqual(fixture.fileSystem.traversals, 1)
        let report = await executor.execute(plan: fixture.plan, context: fixture.context, progress: { _ in })
        XCTAssertEqual(fixture.fileSystem.traversals, 2, "预检查一遍，保存移动意图之后最后一遍")
        XCTAssertEqual(fixture.fileSystem.childReads, 2_048)
        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertEqual(report.summary.failedItemCount, 0)
        let moves = await fixture.mover.count
        XCTAssertEqual(moves, 1)
    }

    func testCancellationStopsInsideTheTraversalAndNeverMoves() async throws {
        let fixture = try WriteRecheckFixture(fileCount: 20_000)
        fixture.fileSystem.onChildRead = { count in
            if count == 256 {
                // Synchronous reader: cancel its current task at a deterministic
                // read, then await completion asynchronously; never block a worker.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let executor = fixture.executor()
        let task = Task {
            await executor.execute(plan: fixture.plan, context: fixture.context, progress: { _ in })
        }
        let report = await task.value
        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertEqual(report.items.map(\.outcome), [.notProcessed])
        XCTAssertLessThanOrEqual(fixture.fileSystem.childReads, 512, "取消不能等整遍完成")
        XCTAssertEqual(report.summary.failedItemCount, 0)
        XCTAssertEqual(report.summary.skippedItemCount, 0)
        let moves = await fixture.mover.count
        XCTAssertEqual(moves, 0)
    }

    func testCancelledPreflightCannotApproveAPartialTraversal() async throws {
        let fixture = try WriteRecheckFixture(fileCount: 20_000)
        fixture.fileSystem.onChildRead = { count in
            if count == 256 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let executor = fixture.executor()
        let task = Task { await executor.preflight(plan: fixture.plan, context: fixture.context) }
        let report = await task.value
        XCTAssertEqual(report.readyCount, 0)
        XCTAssertFalse(report.isConfirmable)
        XCTAssertEqual(report.failure?.detailCode, "cancelled")
        XCTAssertEqual(report.failure.map(CleanFailurePresentation.title), L10n.text("已取消", "Cancelled"))
        XCTAssertLessThanOrEqual(fixture.fileSystem.childReads, 512)
        let moves = await fixture.mover.count
        XCTAssertEqual(moves, 0)
    }

    func testWriteDuringDurableIntentIsCaughtByTheLastTraversal() async throws {
        let fixture = try WriteRecheckFixture(fileCount: 1_024)
        let writes = WriteRecheckJournalCounter()
        let executor = fixture.executor { _, _ in
            // 第一次保存整份冻结计划；第二次保存本项的移动意图。
            if writes.increment() == 2 { fixture.fileSystem.childTime = 2 }
        }
        let preflight = await executor.preflight(plan: fixture.plan, context: fixture.context)
        XCTAssertEqual(preflight.items.map(\.status), [.ready])
        let report = await executor.execute(plan: fixture.plan, context: fixture.context, progress: { _ in })
        XCTAssertEqual(report.items.map(\.outcome), [.skipped(.candidateBecameActive)])
        XCTAssertEqual(fixture.fileSystem.traversals, 2)
        XCTAssertEqual(report.summary.failedItemCount, 0)
        let moves = await fixture.mover.count
        XCTAssertEqual(moves, 0)
    }

    func testReaderCancellationErrorWithoutTaskCancellationIsSkipped() async throws {
        for fromChild in [false, true] {
            let fixture = try WriteRecheckFixture(fileCount: 2)
            let executor = fixture.executor()
            // Preflight succeeds; the same reader then fails during execution.
            let preflight = await executor.preflight(plan: fixture.plan, context: fixture.context)
            XCTAssertEqual(preflight.items.map(\.status), [.ready])
            fixture.fileSystem.cancellationErrorFromChild = fromChild
            fixture.fileSystem.throwsCancellationError = true
            let report = await executor.execute(plan: fixture.plan, context: fixture.context, progress: { _ in })
            XCTAssertFalse(Task.isCancelled)
            XCTAssertEqual(report.items.map(\.outcome), [.skipped(.permissionChanged)])
            XCTAssertEqual(report.summary.failedItemCount, 0)
            let moves = await fixture.mover.count
            XCTAssertEqual(moves, 0, "A reader's error must not authorize a move")
            let preflightFixture = try WriteRecheckFixture(fileCount: 2)
            preflightFixture.fileSystem.cancellationErrorFromChild = fromChild
            preflightFixture.fileSystem.throwsCancellationError = true
            let rejected = await preflightFixture.executor().preflight(
                plan: preflightFixture.plan, context: preflightFixture.context)
            XCTAssertEqual(rejected.items.map(\.status), [.skipped(.permissionChanged)])
            XCTAssertFalse(rejected.isConfirmable)
        }
    }

    func testCancelledTraversalCheckpointsBeforeAFailedFinalReceipt() async throws {
        let fixture = try WriteRecheckFixture(fileCount: 1_024)
        fixture.fileSystem.onChildRead = { count in
            if count == 256 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let journal = WriteRecheckFinalReceiptProbe()
        let executor = fixture.executor(capacityReader: journal) { report, _ in
            // Fail saves only after the final capacity read, regardless of the
            // number of checkpoints. Before it, durable state must be corrected.
            try journal.persist(report)
        }
        let report = await Task {
            await executor.execute(plan: fixture.plan, context: fixture.context, progress: { _ in })
        }.value
        XCTAssertEqual(report.persistenceFailure, "final-write-failed")
        XCTAssertEqual(report.items.map(\.outcome), [.notProcessed])
        let checkpoint = try XCTUnwrap(journal.reports.last)
        XCTAssertEqual(checkpoint.outcome, .cancelled)
        XCTAssertEqual(checkpoint.items.map(\.outcome), [.notProcessed])
        let moves = await fixture.mover.count
        XCTAssertEqual(moves, 0)
    }

    func testModificationTimeComparisonKeepsTheExistingDecision() async throws {
        // 最新可读修改时间相等才可执行；恢复时间或非最新条目的变化仍是现有盲区。
        for (time, expected) in [(Int64(1), CleanPreflightItemStatus.ready),
                                 (2, .skipped(.candidateBecameActive)),
                                 (0, .ready)] {
            let fixture = try WriteRecheckFixture(fileCount: 2)
            fixture.fileSystem.childTime = time
            let report = await fixture.executor().preflight(plan: fixture.plan, context: fixture.context)
            XCTAssertEqual(report.items.map(\.status), [expected])
        }
        let missingBaseline = try WriteRecheckFixture(fileCount: 2, latest: nil)
        let report = await missingBaseline.executor().preflight(
            plan: missingBaseline.plan, context: missingBaseline.context)
        XCTAssertEqual(report.items.map(\.status), [.skipped(.candidateBecameActive)])
        XCTAssertEqual(missingBaseline.fileSystem.traversals, 0)
    }

    /// 只定向运行此方法：同一份真实 2 万文件夹具，计时不包含创建文件；移动器不动文件。
    func testTwentyThousandFileWriteRecheckTimings() async throws {
        guard ProcessInfo.processInfo.environment["STORAGE_CLEANER_RUN_TIMING"] == "1" else {
            throw XCTSkip("Set STORAGE_CLEANER_RUN_TIMING=1 to run the 20,000-file timing fixture")
        }
        let configuredRoot = ProcessInfo.processInfo.environment["STORAGE_CLEANER_RECHECK_BENCHMARK_ROOT"]
        let home = configuredRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("WriteRecheck-\(UUID().uuidString)")
        let directory = home.appendingPathComponent("Library/Caches/UnknownTool", isDirectory: true)
        // 防止配置错误把夹具指向真实用户缓存。
        let realLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        XCTAssertFalse(PathSafety.isContained(directory.path, in: realLibrary.path, resolvingSymlinks: true))
        guard !PathSafety.isContained(directory.path, in: realLibrary.path, resolvingSymlinks: true) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if configuredRoot == nil { try? FileManager.default.removeItem(at: home) } }
        for index in 0..<20_000 {
            let url = directory.appendingPathComponent("\(index).bin")
            if !FileManager.default.fileExists(atPath: url.path) { try Data([1]).write(to: url) }
        }
        let foundation = FoundationReadOnlyFileSystem()
        let snapshot = try foundation.aggregateSnapshot(at: directory)
        let urls = try foundation.children(of: directory)
        XCTAssertEqual(urls.count, 20_000)
        let latest = try urls.reduce(snapshot.modificationTimeNanoseconds ?? 0) {
            max($0, try foundation.aggregateSnapshot(at: $1).modificationTimeNanoseconds ?? 0)
        }
        for trial in 1...3 {
            let fixture = try WriteRecheckFixture(fileCount: 20_000, home: home,
                realSnapshot: snapshot, latest: latest)
            let executor = fixture.executor()
            let start = Date()
            let preflight = await executor.preflight(plan: fixture.plan, context: fixture.context)
            let checked = Date()
            let report = await executor.execute(plan: fixture.plan, context: fixture.context, progress: { _ in })
            let end = Date()
            XCTAssertEqual(preflight.items.map(\.status), [.ready])
            XCTAssertEqual(report.summary.movedItemCount, 1)
            print("复查计时 trial=\(trial) files=20000 preflight=\(checked.timeIntervalSince(start)) execution=\(end.timeIntervalSince(checked)) total=\(end.timeIntervalSince(start)) traversals=\(fixture.fileSystem.traversals)")
        }
    }
}

private struct WriteRecheckFixture: Sendable {
    let fileSystem: WriteRecheckFileSystem
    let mover = WriteRecheckMover()
    let plan: CleanPlan
    let context: CleanupExecutionContext

    init(fileCount: Int, home: URL? = nil, realSnapshot: FileSnapshot? = nil, latest: Int64? = 1) throws {
        let home = home ?? URL(fileURLWithPath: "/Users/Shared/WriteRecheck-\(UUID().uuidString)")
        let root = home.appendingPathComponent("Library/Caches")
        let source = root.appendingPathComponent("UnknownTool")
        let rule = try XCTUnwrap(CleanupRuleSetLoader.loadBundled().rules.first { $0.id == "system.user-caches" })
        let rules = CleanupRuleSet(schemaVersion: 2, rulesVersion: "write-recheck-fixture", rules: [rule])
        let snapshot = realSnapshot ?? FileSnapshot(identity: FileIdentity(deviceID: 1, inode: 1,
            entryKind: .directory, creationTimeNanoseconds: 1), standardizedPath: source.path,
            volumeIdentifier: "fixture", logicalSizeBytes: 1, allocatedSizeBytes: 1,
            modificationTimeNanoseconds: 1, isWritableVolume: true, isCloudItem: false,
            isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
        fileSystem = WriteRecheckFileSystem(source: source, rootSnapshot: snapshot, fileCount: fileCount,
            usesRealChildren: realSnapshot != nil)
        let sessionID = ScanSessionID()
        var candidate = ScanCandidate(id: ScanCandidateID(), sessionID: sessionID, ruleID: rule.id,
            ruleSelectionPolicyVersion: rule.selectionPolicyVersion, categoryID: rule.categoryID,
            categoryTitle: "System", subcategoryTitle: "Caches", sourceURL: source, allowedRootURL: root,
            snapshot: snapshot, risk: rule.risk,
            recommendation: CleanupRecommendation(level: rule.recommendation,
                reasonCode: rule.reasonKey, evidenceCodes: []), defaultSelection: rule.defaultSelection,
            executionEligibility: rule.executionEligibility, measurementCompleteness: .complete,
            isManuallySelectable: rule.allowsManualSelection, action: rule.action,
            requiredClosedBundleIDs: rule.requiredClosedBundleIDs, reason: "Fixture")
        candidate.latestContentModificationTimeNanoseconds = latest
        candidate.ownerResolution = .unresolved
        // D82: a rule scan stamps every row with its rule revision and the
        // rule-set fingerprint; plans refuse tracked rows without them.
        candidate.ruleRevision = rule.maintenance?.revision
        candidate.rulesProvenance = rules.effectiveProvenance
        let session = ScanSession(id: sessionID, rulesVersion: rules.rulesVersion,
            startedAt: Date(), completedAt: Date(), outcome: .complete,
            categories: [CleanupScanCategory(id: rule.categoryID, title: "System", subcategories: [
                CleanupScanSubcategory(id: rule.id, title: "Caches", risk: rule.risk,
                    recommendation: rule.recommendation, reason: "Fixture", candidates: [candidate])
            ])], issues: [], permissions: [], metrics: ScanMetrics(visitedEntryCount: fileCount,
                candidateCount: 1, deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: snapshot.logicalSizeBytes, duration: 0))
        var selection = CleanupSelection()
        selection.setCandidate(candidate.id, selected: true, in: session)
        plan = try CleanPlanBuilder.makePlan(session: session, selection: selection,
            activeRules: rules, disposition: .trash)
        context = CleanupExecutionContext(featureConfiguration: CleanupFeatureConfiguration(mode: .v2Full),
            activeSessionID: plan.sessionID, activeRules: rules, userHomeURL: home, excludedURLs: [],
            approvedPlanItemIDs: Set(plan.items.map(\.id)))
    }

    func executor(capacityReader: any CleanupCapacityReading = WriteRecheckCapacityReader(),
        persist: @escaping @Sendable (CleanReport, [String: FileIdentity]) throws -> Void = { _, _ in }) -> SafeCleanupExecutor {
        SafeCleanupExecutor(metadataReader: fileSystem, mover: mover,
            volumeChecker: WriteRecheckVolumeChecker(), runningApplicationChecker: WriteRecheckAppChecker(),
            capacityReader: capacityReader, coordinator: HeavyWorkCoordinator(), persistReport: persist)
    }
}

private final class WriteRecheckFileSystem: ReadOnlyFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private let source: URL
    private let rootSnapshot: FileSnapshot
    private let fileCount: Int
    private let usesRealChildren: Bool
    private var traversalCount = 0
    private var readCount = 0
    private var time: Int64 = 1
    private var callback: (@Sendable (Int) -> Void)?
    private var cancellationError = false
    private var cancellationFromChild = false
    var throwsCancellationError: Bool {
        get { lock.withLock { cancellationError } }
        set { lock.withLock { cancellationError = newValue } }
    }
    var cancellationErrorFromChild: Bool {
        get { lock.withLock { cancellationFromChild } }
        set { lock.withLock { cancellationFromChild = newValue } }
    }
    var traversals: Int { lock.withLock { traversalCount } }
    var childReads: Int { lock.withLock { readCount } }
    var childTime: Int64 {
        get { lock.withLock { time } }
        set { lock.withLock { time = newValue } }
    }
    var onChildRead: (@Sendable (Int) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    init(source: URL, rootSnapshot: FileSnapshot, fileCount: Int, usesRealChildren: Bool) {
        self.source = source; self.rootSnapshot = rootSnapshot
        self.fileCount = fileCount; self.usesRealChildren = usesRealChildren
    }
    func snapshot(at url: URL) throws -> FileSnapshot {
        // 根目录和假移动目的地共用冻结身份；移动器从不修改文件。
        rootSnapshot
    }
    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        if throwsCancellationError && cancellationErrorFromChild { throw CancellationError() }
        let (count, callback, time) = lock.withLock {
            readCount += 1
            return (readCount, self.callback, self.time)
        }
        callback?(count)
        if usesRealChildren { return try FoundationReadOnlyFileSystem().aggregateSnapshot(at: url) }
        return FileSnapshot(identity: FileIdentity(deviceID: 1,
            inode: UInt64(Int(url.deletingPathExtension().lastPathComponent)! + 2),
            entryKind: .regularFile, creationTimeNanoseconds: 1), standardizedPath: url.path,
            volumeIdentifier: "fixture", logicalSizeBytes: 1, allocatedSizeBytes: 1,
            modificationTimeNanoseconds: time, isWritableVolume: true, isCloudItem: false,
            isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
    }
    func children(of directory: URL) throws -> [URL] {
        if throwsCancellationError && !cancellationErrorFromChild { throw CancellationError() }
        lock.withLock { traversalCount += 1 }
        if usesRealChildren { return try FoundationReadOnlyFileSystem().children(of: directory) }
        return (0..<fileCount).map { source.appendingPathComponent("\($0).bin") }
    }
}

private actor WriteRecheckMover: CleanupMoving {
    private(set) var count = 0
    func moveToTrash(_ url: URL) async throws -> URL { count += 1; return url.appendingPathExtension("fixture-trash") }
    func moveToQuarantine(_ url: URL, planID: CleanPlanID, itemID: UUID) async throws -> URL {
        try await moveToTrash(url)
    }
}
private struct WriteRecheckVolumeChecker: CleanupVolumeChecking {
    func isAvailable(volumeIdentifier: String) async -> Bool { true }
}
private struct WriteRecheckAppChecker: CleanupRunningApplicationChecking {
    func isRunning(bundleIdentifier: String) async -> Bool { false }
}
private struct WriteRecheckCapacityReader: CleanupCapacityReading {
    func availableCapacity(at url: URL) async -> Int64? { nil }
}
private final class WriteRecheckJournalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class WriteRecheckFinalReceiptProbe: CleanupCapacityReading, @unchecked Sendable {
    private let lock = NSLock()
    private var capacityReads = 0
    private var savedReports: [CleanReport] = []
    var reports: [CleanReport] { lock.withLock { savedReports } }
    func availableCapacity(at url: URL) async -> Int64? {
        lock.withLock { capacityReads += 1 }
        return nil
    }
    func persist(_ report: CleanReport) throws {
        try lock.withLock {
            if capacityReads >= 2 { throw CocoaError(.fileWriteUnknown) }
            savedReports.append(report)
        }
    }
}
