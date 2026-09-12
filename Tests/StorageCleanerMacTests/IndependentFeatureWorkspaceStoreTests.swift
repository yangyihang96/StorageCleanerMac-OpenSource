import Foundation
import XCTest
@testable import StorageCleanerMac

final class IndependentFeatureWorkspaceStoreTests: XCTestCase {
    func testScanProgressThrottleCoalescesSamePhaseAndDeliversPhaseChanges() {
        let throttle = ScanProgressThrottle(minimumInterval: 60)

        XCTAssertTrue(throttle.shouldDeliver(phase: "discovering"))
        XCTAssertFalse(throttle.shouldDeliver(phase: "discovering"))
        XCTAssertTrue(throttle.shouldDeliver(phase: "hashing"))
    }

    @MainActor
    func testMigrationSourceSelectionFailsClosedOutsideHome() {
        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: UserDefaults(suiteName: "migration-source-\(UUID().uuidString)")!,
            scanOperation: { _ in [] }
        )
        let allowed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)

        XCTAssertFalse(store.selectMigrationSource(URL(fileURLWithPath: "/Applications")))
        XCTAssertNil(store.migrationSourcePath)
        XCTAssertTrue(store.selectMigrationSource(allowed))
        XCTAssertEqual(store.migrationSourcePath, allowed.path)
        XCTAssertTrue(store.selectMigrationSource(nil))
        XCTAssertNil(store.migrationSourcePath)
    }

    @MainActor
    func testLargeFilesFilterRestoresAndScanStoreKeepsWorkspaceResultAcrossRouteAccess() async {
        let suite = "large-files-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = makeItem(sourceID: "large_files", title: "movie.mov", size: 42)
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let operation: LargeFilesStore.ScanOperation = { _ in [item] }

        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: activity,
            defaults: defaults,
            scanOperation: operation
        )
        store.selectedFilter = .video
        store.startScan()
        await waitUntil { !store.isScanning }

        XCTAssertEqual(store.items, [item])
        XCTAssertEqual(store.phase, .finished)
        XCTAssertTrue(store.hasScanned)

        let scanStore = ScanStore(
            heavyWorkCoordinator: coordinator,
            heavyWorkActivityStore: activity
        )
        let routeWorkspace = scanStore.largeFilesWorkspace
        routeWorkspace.replaceItemsForTesting([item])
        XCTAssertTrue(routeWorkspace === scanStore.largeFilesWorkspace)
        XCTAssertEqual(scanStore.largeFilesWorkspace.items, [item])

        let recreated = LargeFilesStore(
            coordinator: coordinator,
            activityStore: activity,
            defaults: defaults,
            scanOperation: operation
        )
        XCTAssertEqual(recreated.selectedFilter, .video)
        XCTAssertTrue(recreated.items.isEmpty)
    }

    @MainActor
    func testLargeFilesStoreFailedRescanRetainsPreviousResult() async {
        let item = makeItem(sourceID: "large_files", title: "old.dmg", size: 10)
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let calls = Counter()
        let operation: LargeFilesStore.ScanOperation = { _ in
            let count = await calls.incrementAndRead()
            if count > 1 { throw TestError.failed }
            return [item]
        }
        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: activity,
            defaults: UserDefaults(suiteName: "large-files-failure-\(UUID().uuidString)")!,
            scanOperation: operation
        )

        store.startScan()
        await waitUntil { !store.isScanning }
        store.startScan()
        await waitUntil { !store.isScanning }

        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.items, [item])
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testStorageAnalysisFailedRescanRetainsPreviousIndex() async {
        let target = StorageMapScanTarget(
            path: "/tmp",
            title: "Fixture",
            kind: .homeDirectory
        )
        let previous = storageAnalysisResult(target: target)
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let calls = Counter()
        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: activity,
            defaults: UserDefaults(suiteName: "storage-analysis-failure-\(UUID().uuidString)")!,
            scanOperation: { _ in [] },
            storageMapTargets: [target],
            storageAnalysisOperation: { _, _ in
                let count = await calls.incrementAndRead()
                if count > 1 { throw TestError.failed }
                return previous
            }
        )

        store.startStorageAnalysis()
        await waitUntil { !store.isAnalyzingStorage }
        store.startStorageAnalysis()
        await waitUntil { !store.isAnalyzingStorage }

        XCTAssertEqual(store.storageAnalysisPhase, .failed)
        XCTAssertEqual(store.storageAnalysis, previous)
        XCTAssertEqual(store.storageMapNavigation, [previous.rootSnapshot])
        XCTAssertNotNil(store.storageAnalysisErrorMessage)
    }

    @MainActor
    func testStorageAnalysisCancellationReachesOperationAndKeepsPreviousIndex() async {
        let target = StorageMapScanTarget(
            path: "/tmp",
            title: "Fixture",
            kind: .homeDirectory
        )
        let previous = storageAnalysisResult(target: target)
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: activity,
            defaults: UserDefaults(suiteName: "storage-analysis-cancel-\(UUID().uuidString)")!,
            scanOperation: { _ in [] },
            storageMapTargets: [target],
            storageAnalysisOperation: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return previous
            }
        )
        store.replaceStorageAnalysisForTesting(previous)

        store.startStorageAnalysis()
        await waitUntil { store.isAnalyzingStorage }
        store.cancelStorageAnalysis()
        await waitUntil { !store.isAnalyzingStorage }
        await waitUntil { store.canStartStorageAnalysis }

        XCTAssertEqual(store.storageAnalysisPhase, .cancelled)
        XCTAssertTrue(store.canStartStorageAnalysis)
        XCTAssertEqual(store.storageAnalysis, previous)
        XCTAssertEqual(store.storageMapNavigation, [previous.rootSnapshot])
    }

    @MainActor
    func testDuplicateStoreCancelledRescanRetainsPreviousResultAndDropsLateGeneration() async {
        let initial = makeItem(sourceID: "duplicate_files", title: "same.txt", size: 8)
        let late = makeItem(sourceID: "duplicate_files", title: "late.txt", size: 9)
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let gate = AsyncValueGate()
        let operation: DuplicateFilesStore.ScanOperation = { _, _, _, _, _ in
            await gate.wait()
            return Self.report(items: [late])
        }
        let store = DuplicateFilesStore(
            defaults: UserDefaults(suiteName: "duplicate-late-\(UUID().uuidString)")!,
            coordinator: coordinator,
            activityStore: activity,
            scanOperation: operation
        )
        store.replaceItemsForTesting([initial])
        store.startScan()
        await waitUntil { store.isScanning }
        store.pauseScan()
        XCTAssertTrue(store.isScanning)
        XCTAssertEqual(store.phase, .paused)
        store.resumeScan()
        XCTAssertEqual(store.phase, .scanning)
        store.pauseScan()
        store.cancelScan()
        XCTAssertEqual(store.phase, .cancelling)
        store.pauseScan()
        store.resumeScan()
        XCTAssertEqual(store.phase, .cancelling)
        await gate.open()
        await waitUntil { !store.isScanning }

        XCTAssertEqual(store.phase, .cancelled)
        XCTAssertEqual(store.items, [initial])
        XCTAssertFalse(store.items.contains(late))
    }

    @MainActor
    func testDuplicateStoreReloadsResultAndFiltersWithoutSelection() async throws {
        let fixture = try makePersistedDuplicateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suite = "duplicate-result-reload-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resultURL = fixture.root.appendingPathComponent("result.json")
        let resultStore = DuplicateFileResultStore(fileURL: resultURL)
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let operation = persistedDuplicateScanOperation(fixture: fixture)

        let first = DuplicateFilesStore(
            defaults: defaults,
            coordinator: coordinator,
            activityStore: activity,
            scanOperation: operation,
            resultStore: resultStore
        )
        first.addCustomRoot(fixture.root.path)
        first.resultFilter = .exact
        first.resultSort = .name
        first.startScan()
        await first.waitForCurrentScan()

        XCTAssertEqual(first.phase, .finished)
        XCTAssertEqual(first.items.count, 2)
        let selected = first.items[0]
        first.setSelected(true, item: selected, allItems: first.items)
        XCTAssertEqual(first.selectedItemIDs, [selected.id])

        let restoreScanCalls = Counter()
        let restored = DuplicateFilesStore(
            defaults: defaults,
            coordinator: coordinator,
            activityStore: activity,
            scanOperation: { _, _, _, _, _ in
                _ = await restoreScanCalls.incrementAndRead()
                return Self.report(items: [])
            },
            resultStore: resultStore
        )
        await restored.waitForResultRestore()
        let restoreScanCallCount = await restoreScanCalls.currentValue()
        XCTAssertEqual(restoreScanCallCount, 0)
        XCTAssertEqual(restored.phase, .finished)
        XCTAssertEqual(restored.items, first.items)
        XCTAssertNotNil(restored.scanCoverage)
        XCTAssertEqual(restored.scanOutcome, .complete)
        XCTAssertNotNil(restored.lastScanAt)
        XCTAssertNotNil(restored.scanSeconds)
        XCTAssertEqual(restored.resultFilter, .exact)
        XCTAssertEqual(restored.resultSort, .name)
        XCTAssertTrue(restored.selectedItemIDs.isEmpty)
    }

    func testDuplicateStoreRestoresResolvedDefaultCacheWithoutStartingScan() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/DuplicateFiles/Stores/DuplicateFilesStore.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "    init("))
        let end = try XCTUnwrap(source.range(of: "    var isScanning:", range: start.upperBound..<source.endIndex))
        let initializer = String(source[start.lowerBound..<end.lowerBound])
        // The nil argument must not shadow the resolved production cache.
        // Inspect this wiring without reading or writing the user's real cache.
        XCTAssertTrue(initializer.contains("if let resultStore = self.resultStore"))
        XCTAssertTrue(initializer.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(initializer.contains("resultStore.load(configuration: configuration)"))
        XCTAssertFalse(initializer.contains("startScan("))
        XCTAssertFalse(initializer.contains("scanOperation("))
    }

    @MainActor
    func testDuplicateStoreCacheRestoreCannotOverwriteNewScanOrChangedScope() async throws {
        let fixture = try makePersistedDuplicateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suite = "duplicate-restore-race-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resultStore = DuplicateFileResultStore(fileURL: fixture.root.appendingPathComponent("result.json"))
        let first = DuplicateFilesStore(
            defaults: defaults,
            scanOperation: persistedDuplicateScanOperation(fixture: fixture),
            resultStore: resultStore
        )
        first.addCustomRoot(fixture.root.path)
        first.startScan()
        await first.waitForCurrentScan()
        XCTAssertEqual(first.items.count, 2)

        let changedScope = DuplicateFilesStore(defaults: defaults, resultStore: resultStore)
        changedScope.scanScope = .wholeComputer
        await changedScope.waitForResultRestore()
        XCTAssertTrue(changedScope.items.isEmpty)
        XCTAssertNil(changedScope.lastScanAt)

        changedScope.scanScope = .userFiles
        let rescan = DuplicateFilesStore(
            defaults: defaults,
            scanOperation: { _, _, _, _, _ in Self.report(items: []) },
            resultStore: resultStore
        )
        rescan.startScan()
        await rescan.waitForResultRestore()
        await rescan.waitForCurrentScan()
        XCTAssertEqual(rescan.phase, .finished)
        // The report helper adds a sibling candidate even for an empty input.
        // The new report must win over the two entries in the saved snapshot.
        XCTAssertEqual(rescan.items, DuplicateFilesStore.storageItems(from: Self.report(items: [])))
        XCTAssertTrue(Set(rescan.items.map(\.id)).isDisjoint(with: Set(first.items.map(\.id))))
        XCTAssertTrue(rescan.selectedItemIDs.isEmpty)
    }

    @MainActor
    func testDuplicateStoreKeepsCompletedScopeWhenNextScopeChanges() async {
        let suite = "duplicate-completed-scope-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = HeavyWorkCoordinator()
        let store = DuplicateFilesStore(
            defaults: defaults,
            coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            scanOperation: { _, _, _, _, _ in Self.report(items: []) },
            resultStore: nil
        )

        store.scanScope = .userFiles
        store.startScan()
        await store.waitForCurrentScan()
        XCTAssertEqual(store.lastCompletedScanScope, .userFiles)

        store.scanScope = .wholeComputer
        XCTAssertEqual(store.lastCompletedScanScope, .userFiles)
    }

    @MainActor
    func testDuplicateStoreRejectsCorruptResultCache() async throws {
        let fixture = try makePersistedDuplicateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suite = "duplicate-result-corrupt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resultURL = fixture.root.appendingPathComponent("result.json")
        let resultDirectory = resultURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: resultURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: resultURL.path
        )
        defaults.set([fixture.root.path], forKey: "duplicate-files.custom-roots")

        let store = DuplicateFilesStore(
            defaults: defaults,
            resultStore: DuplicateFileResultStore(fileURL: resultURL)
        )
        await store.waitForResultRestore()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.lastScanAt)
    }

    @MainActor
    func testDuplicateStoreRejectsResultWhenFileIdentityChanges() async throws {
        let fixture = try makePersistedDuplicateFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suite = "duplicate-result-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resultStore = DuplicateFileResultStore(
            fileURL: fixture.root.appendingPathComponent("result.json")
        )
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let operation = persistedDuplicateScanOperation(fixture: fixture)

        let first = DuplicateFilesStore(
            defaults: defaults,
            coordinator: coordinator,
            activityStore: activity,
            scanOperation: operation,
            resultStore: resultStore
        )
        first.addCustomRoot(fixture.root.path)
        first.startScan()
        await first.waitForCurrentScan()
        XCTAssertEqual(first.phase, .finished)

        try Data("changed duplicate payload".utf8).write(to: fixture.first)
        let restored = DuplicateFilesStore(
            defaults: defaults,
            coordinator: coordinator,
            activityStore: activity,
            scanOperation: operation,
            resultStore: resultStore
        )
        await restored.waitForResultRestore()
        XCTAssertEqual(restored.phase, .idle)
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertNil(restored.lastScanAt)
    }

    @MainActor
    func testFeatureScansShareHeavyWorkCoordinator() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let gate = AsyncValueGate()
        let large = LargeFilesStore(
            coordinator: coordinator,
            activityStore: activity,
            scanOperation: { _ in
                await gate.wait()
                return []
            }
        )
        let duplicate = DuplicateFilesStore(
            coordinator: coordinator,
            activityStore: activity,
            scanOperation: { _, _, _, _, _ in Self.report(items: []) }
        )

        large.startScan()
        await waitUntil { large.isScanning }
        duplicate.startScan()
        await waitUntil { duplicate.phase == .failed }
        XCTAssertNotNil(duplicate.errorMessage)
        await gate.open()
        await waitUntil { !large.isScanning }
    }

    @MainActor
    func testFeatureStoresDoNotWriteTheirResultsIntoScanStore() {
        let scanStore = ScanStore()
        let original = makeItem(sourceID: "large_files", title: "original.mov", size: 1)
        scanStore.result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0,
            system: SystemSnapshot(
                osName: "test",
                build: "test",
                arch: "arm64",
                user: "tester",
                home: "/Users/tester",
                filesystem: "APFS",
                purgeable: "0",
                diskName: "Test",
                diskTotalBytes: 100,
                diskUsedBytes: 10,
                diskFreeBytes: 90
            ),
            groups: [],
            items: [original],
            deniedPaths: []
        )
        scanStore.largeFilesWorkspace.replaceItemsForTesting([
            makeItem(sourceID: "large_files", title: "new.mov", size: 2)
        ])
        scanStore.duplicateFilesWorkspace.replaceItemsForTesting([
            makeItem(sourceID: "duplicate_files", title: "duplicate.mov", size: 3)
        ])

        XCTAssertEqual(scanStore.result?.items, [original])
    }

    private static func report(items: [StorageItem]) -> DuplicateFileScanReport {
        let entries = items.map {
            DirectoryEntry(name: $0.title, path: $0.path, sizeBytes: $0.sizeBytes)
        }
        let candidateFiles = entries.count > 1
            ? entries
            : entries + [DirectoryEntry(name: "sibling-\(entries.first?.name ?? "file")", path: "/Users/tester/Downloads/sibling", sizeBytes: entries.first?.sizeBytes ?? 1)]
        return DuplicateFileScanReport(
            exactGroups: [],
            candidates: [DuplicateFileCandidateGroup(id: "candidate", files: candidateFiles, rule: .sameName)],
            coverage: DuplicateFileScanCoverage(
                roots: [],
                reachedTimeLimit: false,
                reachedFileLimit: false,
                reachedDirectoryLimit: false,
                reachedResultLimit: false
            ),
            progress: .initial,
            outcome: .complete
        )
    }

    private struct PersistedDuplicateFixture {
        let root: URL
        let first: URL
        let second: URL
        let payloadSize: Int64
    }

    private func makePersistedDuplicateFixture() throws -> PersistedDuplicateFixture {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("DuplicateResultStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        let payload = Data("persisted duplicate payload".utf8)
        try payload.write(to: first)
        try payload.write(to: second)
        return PersistedDuplicateFixture(
            root: root,
            first: first,
            second: second,
            payloadSize: Int64(payload.count)
        )
    }

    private func persistedDuplicateScanOperation(
        fixture: PersistedDuplicateFixture
    ) -> DuplicateFilesStore.ScanOperation {
        { configuration, _, _, _, _ in
            let entries = [fixture.first, fixture.second].map {
                DirectoryEntry(
                    name: $0.lastPathComponent,
                    path: $0.path,
                    sizeBytes: fixture.payloadSize
                )
            }
            let group = DuplicateFileGroup(
                id: Data(repeating: 0xA1, count: 32).base64EncodedString(),
                files: entries,
                contentSizeBytes: fixture.payloadSize,
                matchKind: .logicalContentSHA256,
                estimatedPhysicalReclaimableBytes: nil
            )
            let roots = configuration.roots.map { root in
                DuplicateFileScanRootCoverage(
                    rootPath: PathSafety.lexicalPath(root),
                    status: .scanned,
                    skipReason: nil,
                    scannedDirectories: 1,
                    scannedFiles: 2,
                    scannedBytes: fixture.payloadSize * 2,
                    skippedPaths: []
                )
            }
            let coverage = DuplicateFileScanCoverage(
                roots: roots,
                reachedTimeLimit: false,
                reachedFileLimit: false,
                reachedDirectoryLimit: false,
                reachedResultLimit: false
            )
            let progress = DuplicateFileScanProgress(
                phase: .finished,
                currentPath: nil,
                scannedDirectories: roots.count,
                scannedFiles: 2,
                scannedBytes: fixture.payloadSize * 2,
                hashedFiles: 2,
                hashedBytes: fixture.payloadSize * 2,
                estimatedTotalDirectories: roots.count,
                estimatedTotalFiles: 2,
                estimatedTotalBytes: fixture.payloadSize * 2
            )
            return DuplicateFileScanReport(
                exactGroups: [group],
                candidates: [],
                coverage: coverage,
                progress: progress,
                outcome: .complete
            )
        }
    }

    private func makeItem(sourceID: String, title: String, size: Int64) -> StorageItem {
        StorageItem(
            id: "test|\(sourceID)|\(title)",
            title: title,
            path: "/Users/tester/Downloads/\(title)",
            sourceID: sourceID,
            groupTitle: sourceID,
            sizeBytes: size,
            tier: .yellow,
            kind: "file",
            reason: "test",
            recommendation: "review",
            risk: "review",
            requiresClose: "none",
            trashPaths: [],
            openPath: "/Users/tester/Downloads/\(title)",
            status: .available
        )
    }

    private func storageAnalysisResult(
        target: StorageMapScanTarget
    ) -> StorageMapAnalysisResult {
        let snapshot = StorageMapDirectorySnapshot(
            path: target.path,
            title: target.title,
            entries: [],
            measuredBytes: 0,
            inspectedItemCount: 0,
            omittedEntryCount: 0,
            isComplete: true
        )
        return StorageMapAnalysisResult(
            target: target,
            volumeTotalBytes: 100,
            volumeAvailableBytes: 100,
            inspectedItemCount: 0,
            omittedItemCount: 0,
            scanSeconds: 0.1,
            index: StorageMapAnalysisIndex(
                rootPath: target.path,
                rootVolumeIdentifier: nil,
                directories: [
                    target.path: StorageMapDirectoryAggregate()
                ],
                childrenByDirectory: [target.path: []],
                blockedDirectoryPaths: [],
                duplicateFilePaths: []
            ),
            rootSnapshot: snapshot
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Timed out waiting for feature store state")
    }

    private enum TestError: Error {
        case failed
    }
}

private actor Counter {
    private var value = 0

    func incrementAndRead() -> Int {
        value += 1
        return value
    }

    func currentValue() -> Int { value }
}

private actor AsyncValueGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}
