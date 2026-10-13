import Foundation
import XCTest
@testable import StorageCleanerMac

/// 测试唯一的 ScanStore 构造入口。偏好和普通数据使用临时目录，操作回执使用隐藏家目录。
/// 所有产品默认值留在生产 initializer 中；本工厂不使用进程级测试开关。
extension ScanStore {
    static func makeForTests(
        for testCase: XCTestCase,
        dataDirectory: URL? = nil,
        heavyWorkCoordinator: HeavyWorkCoordinator = HeavyWorkCoordinator(),
        scanHeavyWorkOperations: ScanHeavyWorkService.Operations? = nil,
        largeFilesScanOperation: LargeFilesStore.ScanOperation? = nil,
        largeFilesStorageMapTargets: [StorageMapScanTarget]? = nil,
        largeFilesStorageAnalysisOperation: LargeFilesStore.StorageAnalysisOperation? = nil,
        duplicateFilesScanOperation: DuplicateFilesStore.ScanOperation? = nil,
        heavyWorkActivityStore: HeavyWorkActivityStore? = nil,
        folderAccessRestoreTimeout: Duration = .seconds(5),
        scanReadinessTimeout: Duration = .seconds(8),
        restoreSavedAccessOperation: @escaping @Sendable () -> Void = {},
        loadScanReadinessSummary: @escaping @Sendable () -> ScanReadinessSummary = {
            ScanReadinessService.summary()
        },
        historyLoader: (any ScanStoreHistoryLoading)? = nil,
        scanHistoryDefaults: UserDefaults? = nil,
        metricHistoryStore: MetricHistoryStore? = nil,
        systemEnergyAccumulator: SystemEnergyAccumulator? = nil,
        menuBarPowerHistoryURL: URL? = nil,
        samplingGaps: MenuBarSamplingGaps? = nil,
        preferences: UserDefaults? = nil,
        fileAnalysisTrashEnvironment: FileAnalysisTrashEnvironment? = nil,
        memoryCoordinator: MemoryCoordinator? = nil,
        fanControlProvider: (@MainActor () -> FanControlCoordinator)? = nil,
        menuBarMemoryStatusProvider: @escaping @Sendable () async -> MemorySnapshot = {
            await MemoryOptimizerService.statusSnapshot()
        },
        menuBarMemoryProcessProvider: @escaping @Sendable () async -> MemorySnapshot = {
            await MemoryOptimizerService.snapshot()
        },
        menuBarProcessSampler: MenuBarProcessSampler = MenuBarProcessSampler(),
        menuBarProcessSampleTimeout: TimeInterval = MenuBarPerformancePolicy.processSampleTimeout,
        startupScanCoordinator: StartupScanCoordinator = StartupScanCoordinator(),
        startupItemManager: StartupItemsDomain.UserLaunchAgentManager? = nil,
        applicationInventoryScanner: any ApplicationInventoryScanning = ApplicationInventoryScanner(metadataCache: nil),
        applicationUpdateCoordinator: ApplicationUpdateCoordinator? = nil,
        applicationUpdateGracefulQuitRequester: ApplicationUpdateGracefulQuitRequester? = nil,
        applicationUpdateRelauncher: ApplicationUpdateRelauncher? = nil,
        websiteUpdateWorkflow: WebsiteUpdateWorkflow? = nil,
        cleanupFeatureConfiguration: CleanupFeatureConfiguration = .productDefault,
        cleanupScanOperation: @escaping CleanupScanOperation = CleanupScanOperations.live,
        smartScanHealthOperation: @escaping SmartScanHealthOperation = { nil },
        cleanupRuleSetLoader: @escaping @Sendable () throws -> CleanupRuleSet = {
            try CleanupRuleSetLoader.loadBundled()
        },
        cleanupPreferences: UserDefaults? = nil,
        cleanupExecutor: SafeCleanupExecutor? = nil,
        cleanupUserHomeURL: URL? = nil,
        cleanupApplicationEnvironment: any CleanupApplicationEnvironment = WorkspaceCleanupApplicationEnvironment(),
        cleanupOwnerQuitService: CleanupOwnerQuitService? = nil,
        cleanupRecoveryService: CleanupRecoveryService? = nil,
        cleanReportLoader: (() -> [CleanReport])? = { [] },
        interruptedOperationReconciler: @escaping @Sendable () -> Set<CleanupReportJournal.ReconcileIssue> = { [] },
        operationJournal: CleanupReportJournal? = nil,
        operationTrashURL: URL? = nil,
        uninstallMoves: UninstallMoveEnvironment? = nil
    ) throws -> ScanStore {
        let cleanupState = TestScanStoreCleanupState()
        let fixture = TestPreferenceDomain.make()
        let suiteName = fixture.suiteName
        testCase.addTeardownBlock {
            guard cleanupState.canRemovePreferences else {
                XCTFail("后台任务未退出，保留本测试偏好域：\(suiteName)")
                return
            }
            TestPreferenceDomain.cleanup(suiteName: suiteName)
        }
        let defaults = fixture.defaults
        let dataRoot = try TestFileSystem.requireOwnedData(
            dataDirectory ?? TestFileSystem.makeHome(for: testCase), for: testCase)
        let operationHome = try TestFileSystem.requireOwned(
            cleanupUserHomeURL ?? TestFileSystem.makeOperationHome(for: testCase, purpose: "scan-store"),
            for: testCase, operation: true)
        let gaps = samplingGaps ?? MenuBarSamplingGaps(defaults: defaults)
        let journal = try TestFileSystem.requireOwned(
            operationJournal ?? CleanupReportJournal(directory: operationHome.appendingPathComponent("receipts")), for: testCase)
        let operations = TestOperationFactory(for: testCase)
        let store = ScanStore(
            heavyWorkCoordinator: heavyWorkCoordinator,
            scanHeavyWorkOperations: scanHeavyWorkOperations ?? operations.scanOperations(),
            largeFilesScanOperation: largeFilesScanOperation,
            largeFilesStorageMapTargets: largeFilesStorageMapTargets,
            largeFilesStorageAnalysisOperation: largeFilesStorageAnalysisOperation,
            duplicateFilesScanOperation: duplicateFilesScanOperation,
            heavyWorkActivityStore: heavyWorkActivityStore,
            folderAccessRestoreTimeout: folderAccessRestoreTimeout,
            scanReadinessTimeout: scanReadinessTimeout,
            restoreSavedAccessOperation: restoreSavedAccessOperation,
            loadScanReadinessSummary: loadScanReadinessSummary,
            historyLoader: historyLoader ?? TestScanStoreHistoryLoader(suiteName: fixture.suiteName),
            scanHistoryDefaults: scanHistoryDefaults ?? defaults,
            metricHistoryStore: metricHistoryStore,
            systemEnergyAccumulator: systemEnergyAccumulator ?? SystemEnergyAccumulator(
                fileURL: dataRoot.appendingPathComponent("SystemEnergySession-v1.json"),
                samplingGaps: gaps, sampleProvider: { nil }),
            menuBarPowerHistoryURL: try TestFileSystem.requireOwnedData(
                menuBarPowerHistoryURL ?? dataRoot.appendingPathComponent("Monitoring/MenuBarPowerHistory.json"), for: testCase),
            samplingGaps: gaps,
            preferences: preferences ?? defaults,
            fileAnalysisTrashEnvironment: try TestFileSystem.requireOwned(
                fileAnalysisTrashEnvironment ?? operations.analysisEnvironment(home: operationHome), for: testCase),
            memoryCoordinator: memoryCoordinator ?? operations.memoryCoordinator(),
            fanControlProvider: fanControlProvider ?? { operations.fanControl(defaults: defaults) },
            menuBarMemoryStatusProvider: menuBarMemoryStatusProvider,
            menuBarMemoryProcessProvider: menuBarMemoryProcessProvider,
            menuBarProcessSampler: menuBarProcessSampler,
            menuBarProcessSampleTimeout: menuBarProcessSampleTimeout,
            startupScanCoordinator: startupScanCoordinator,
            startupItemManager: startupItemManager ?? operations.startupManager(home: operationHome, dataRoot: dataRoot),
            applicationInventoryScanner: applicationInventoryScanner,
            applicationUpdateCoordinator: applicationUpdateCoordinator ?? ApplicationUpdateCoordinator(
                repository: ApplicationUpdateQueueRepository(fileURL: dataRoot.appendingPathComponent("updates.json")),
                executor: operations.updateExecutor()),
            applicationUpdateGracefulQuitRequester: applicationUpdateGracefulQuitRequester ?? operations.updateQuitRequester(),
            applicationUpdateRelauncher: applicationUpdateRelauncher ?? operations.updateRelauncher(),
            websiteUpdateWorkflow: websiteUpdateWorkflow ?? WebsiteUpdateWorkflow(
                queue: WebsiteUpdateQueue(store: FileWebsiteUpdateQueueStore(fileURL: dataRoot.appendingPathComponent("website-updates.json"))),
                opener: ClosureWebsiteUpdatePageOpener { _ in
                    _ = operations.refuseWebsiteOpen()
                    return false
                }),
            cleanupFeatureConfiguration: cleanupFeatureConfiguration,
            cleanupScanOperation: cleanupScanOperation,
            smartScanHealthOperation: smartScanHealthOperation,
            cleanupRuleSetLoader: cleanupRuleSetLoader,
            cleanupPreferences: cleanupPreferences ?? defaults,
            cleanupExecutor: cleanupExecutor ?? SafeCleanupExecutor(
                mover: operations.cleanupIO(), deleter: operations.cleanupIO(), coordinator: heavyWorkCoordinator,
                persistReport: { try journal.checkpoint($0, expectedIdentities: $1) }),
            cleanupUserHomeURL: operationHome,
            cleanupApplicationEnvironment: cleanupApplicationEnvironment,
            cleanupOwnerQuitService: cleanupOwnerQuitService ?? operations.ownerQuitService(),
            cleanupRecoveryService: cleanupRecoveryService ?? operations.recoveryService(),
            cleanReportLoader: cleanReportLoader ?? { [] },
            interruptedOperationReconciler: interruptedOperationReconciler,
            operationJournal: journal,
            operationTrashURL: try TestFileSystem.requireOwned(
                operationTrashURL ?? operationHome.appendingPathComponent(".Trash"), for: testCase, operation: true),
            uninstallMoves: uninstallMoves ?? operations.uninstallMoves()
        )
        // Registered last: join receipt work before earlier fixture/defaults cleanup.
        let fixtureOwner = ObjectIdentifier(testCase)
        // cleanupExecutionTask can move files before upgrading weak self.
        // Keep the store until cancellation and bounded joining have finished.
        testCase.addTeardownBlock { @MainActor [store] in
            let pending = await store.waitForOperationReportTasksForTesting(cancelPending: true)
            if !pending.isEmpty {
                cleanupState.preservePreferences()
                TestFileSystem.preventCleanup(ownedBy: fixtureOwner, unfinishedTasks: pending)
            }
        }
        return store
    }
}

/// 只把 Sendable 的路径带过并发边界，在线程内重新打开绝对路径偏好域。
private struct TestScanStoreHistoryLoader: ScanStoreHistoryLoading {
    let suiteName: String
    func load() async -> ScanStoreHistorySnapshot {
        let defaults = TestPreferenceDomain.open(suiteName: suiteName)!
        return ScanStoreHistorySnapshot(scanHistory: ScanHistoryService.summary(defaults: defaults),
            cleanupHistory: CleanupHistoryService.summary(defaults: defaults))
    }
}

/// Async joining and synchronous preference cleanup share only lock-protected state.
private final class TestScanStoreCleanupState: @unchecked Sendable {
    private let lock = NSLock()
    private var preservesPreferences = false
    var canRemovePreferences: Bool { lock.withLock { !preservesPreferences } }
    func preservePreferences() { lock.withLock { preservesPreferences = true } }
}
