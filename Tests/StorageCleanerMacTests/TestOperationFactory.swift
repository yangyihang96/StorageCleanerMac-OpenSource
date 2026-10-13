import AppKit
import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

/// 所有缺省写操作只记录并拒绝。生产 guard 即使回归，也不会先操作用户数据。
/// 显式传入的闭包由测试负责隔离；未覆盖的字段不能回落到 live。
struct TestOperationFactory: Sendable {
    fileprivate let recorder: TestUnexpectedOperations

    init(for testCase: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        let recorder = TestUnexpectedOperations(file: file, line: line)
        self.recorder = recorder
        testCase.addTeardownBlock {
            XCTAssertEqual(recorder.finish(), [], "测试触发了未注入的写操作", file: file, line: line)
        }
    }

    /// 只供本文件的拒绝行为测试检查记录器；返回的操作仍然全部拒绝写入。
    fileprivate init(recorder: TestUnexpectedOperations) { self.recorder = recorder }

    var unexpectedCalls: [String] { recorder.calls }

    func refuseWebsiteOpen() -> any Error { recorder.refuse("website.open") }

    func scanOperations(
        scan: (@Sendable (ScanMode, DiskScanProgressHandler?) async throws -> ScanResult)? = nil,
        moveToTrash: (@Sendable (StorageItem, Set<String>) async throws -> [TrashMoveRecord])? = nil,
        emptyTrash: (@Sendable () async throws -> TrashSummary)? = nil,
        restoreFromTrash: (@Sendable ([TrashMoveRecord]) async throws -> TrashRestoreSummary)? = nil,
        optimizeMemory: (@Sendable () async throws -> MemoryOptimizationResult)? = nil,
        runHomebrewUpgrade: (@Sendable ([AppUpdateItem]) async throws -> AppUpdateHomebrewRunResult)? = nil,
        prepareOneClickUpdate: (@MainActor @Sendable (AppUpdateOneClickPlan) -> AppUpdateOneClickLaunchResult)? = nil
    ) -> ScanHeavyWorkService.Operations {
        let recorder = recorder
        // 一个只读扫描入口沿用生产实现；六个有副作用的入口逐项封闭。
        let denied = ScanHeavyWorkService.Operations(
            moveToTrash: { _, _ in throw recorder.refuse("legacy.moveToTrash") },
            emptyTrash: { throw recorder.refuse("legacy.emptyTrash") },
            restoreFromTrash: { _ in throw recorder.refuse("legacy.restoreFromTrash") },
            optimizeMemory: { throw recorder.refuse("legacy.optimizeMemory") },
            runHomebrewUpgrade: { _ in throw recorder.refuse("legacy.runHomebrewUpgrade") },
            prepareOneClickUpdate: { _ in
                _ = recorder.refuse("legacy.prepareOneClickUpdate")
                // 生产接口不抛错；返回未执行，并由 teardown 的零调用断言报错。
                return AppUpdateOneClickLaunchResult(openedAppStore: false, copiedManualReviewList: false)
            }
        )
        return ScanHeavyWorkService.Operations(
            scan: scan ?? denied.scan,
            moveToTrash: moveToTrash ?? denied.moveToTrash,
            emptyTrash: emptyTrash ?? denied.emptyTrash,
            restoreFromTrash: restoreFromTrash ?? denied.restoreFromTrash,
            optimizeMemory: optimizeMemory ?? denied.optimizeMemory,
            runHomebrewUpgrade: runHomebrewUpgrade ?? denied.runHomebrewUpgrade,
            prepareOneClickUpdate: prepareOneClickUpdate ?? denied.prepareOneClickUpdate
        )
    }

    func uninstallMoves() -> UninstallMoveEnvironment {
        let recorder = recorder
        return UninstallMoveEnvironment(
            recycle: { _ in throw recorder.refuse("uninstall.recycle") },
            authorization: UninstallAuthorizationEnvironment(
                helperVerdict: { _, _, _ in
                    _ = recorder.refuse("uninstall.authorization")
                    return .rejectsLocation
                },
                isWritable: { _ in false }, protection: { _ in .none },
                move: { _, _, _, _ in throw recorder.refuse("uninstall.authorization") }
            )
        )
    }

    @MainActor
    func fanControl(defaults: UserDefaults) -> FanControlCoordinator {
        let recorder = recorder
        return FanControlCoordinator(
            defaults: defaults, helperStatusOverride: .notRegistered,
            requestSender: fanRequestSender(),
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false },
            legacyUninstaller: { throw recorder.refuse("fanControl.legacyUninstall") },
            serviceStatusProvider: { .notRegistered },
            serviceRegistrar: { throw recorder.refuse("fanControl.register") },
            serviceUnregistrar: { throw recorder.refuse("fanControl.unregister") },
            approvalSettingsOpener: { _ = recorder.refuse("fanControl.openApprovalSettings") }
        )
    }

    @MainActor
    func fanRequestSender() -> @MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply {
        let recorder = recorder
        return { request in throw recorder.refuse("fanControl." + request.operation.rawValue) }
    }

    /// Only explicitly listed requests reach the fake; all other paths keep the
    /// factory's record-and-refuse protection and teardown assertion.
    @MainActor
    func fanRequestSender(
        handling operations: Set<FanControlHelperRequest.Operation>,
        reply: @escaping @MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply
    ) -> @MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply {
        let recorder = recorder
        return { request in
            guard operations.contains(request.operation) else {
                throw recorder.refuse("fanControl." + request.operation.rawValue)
            }
            return try await reply(request)
        }
    }

    func batteryPowerModeController() -> TestDeniedBatteryPowerModeController {
        TestDeniedBatteryPowerModeController(recorder: recorder)
    }

    func batteryPowerModeWriter() -> TestDeniedBatteryPowerModeWriter {
        TestDeniedBatteryPowerModeWriter(recorder: recorder)
    }

    func cleanupIO() -> TestDeniedCleanupIO { TestDeniedCleanupIO(recorder: recorder) }

    func recoveryService() -> CleanupRecoveryService {
        // 恢复服务没有 mover 注入点。拒绝元数据读取就不会到达任何 rename。
        CleanupRecoveryService(metadataReader: TestDeniedRecoveryReader(recorder: recorder))
    }

    func analysisEnvironment(home: URL) -> FileAnalysisTrashEnvironment {
        let recorder = recorder
        let environment = TestFileSystem.analysisEnvironment(home: home)
        return FileAnalysisTrashEnvironment(
            journal: environment.journal,
            moveToTrash: { _ in throw recorder.refuse("fileAnalysis.moveToTrash") },
            metadata: environment.metadata, homePath: environment.homePath,
            appDataPath: environment.appDataPath, excludedPaths: environment.excludedPaths,
            isCloudFolder: environment.isCloudFolder, isReadOnlyVolume: environment.isReadOnlyVolume,
            userTrashPath: environment.userTrashPath
        )
    }

    func updateExecutor() -> TestDeniedUpdateExecutor { TestDeniedUpdateExecutor(recorder: recorder) }

    @MainActor
    func memoryCoordinator() -> MemoryCoordinator {
        MemoryCoordinator(applications: TestDeniedMemoryController(recorder: recorder))
    }

    @MainActor
    func ownerQuitService() -> CleanupOwnerQuitService {
        CleanupOwnerQuitService(terminator: TestDeniedOwnerTerminator(recorder: recorder))
    }

    @MainActor
    func updateQuitRequester() -> ApplicationUpdateGracefulQuitRequester {
        let recorder = recorder
        return ApplicationUpdateGracefulQuitRequester(runningApplications: {
            NSWorkspace.shared.runningApplications.map { app in
                .init(bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL,
                      requestTermination: { _ = recorder.refuse("appUpdate.quit"); return false })
            }
        })
    }

    @MainActor
    func updateRelauncher() -> ApplicationUpdateRelauncher {
        let recorder = recorder
        return ApplicationUpdateRelauncher(runningApplications: { [] },
            installedIdentity: { _ in throw recorder.refuse("appUpdate.relaunch") },
            openApplication: { _ in throw recorder.refuse("appUpdate.open") })
    }

    func startupManager(home: URL, dataRoot: URL) -> StartupItemsDomain.UserLaunchAgentManager {
        let runner = TestDeniedStartupRunner(recorder: recorder)
        return StartupItemsDomain.UserLaunchAgentManager(
            processRunner: runner,
            stateResolver: StartupItemsDomain.LaunchctlStartupStateResolver(runner: runner),
            undoStore: StartupItemsDomain.FileStartupUndoStore(fileURL: dataRoot.appendingPathComponent("startup-undo.json")),
            planBuilder: StartupItemsDomain.StartupOperationPlanBuilder(
                capabilityResolver: StartupItemsDomain.StartupCapabilityResolver(
                    platform: .currentApplication(), homeDirectory: home))
        )
    }
}

private struct TestOperationRefused: Error, Sendable { let operation: String }

/// 唯一可变状态受锁保护；Sendable 闭包不捕获 XCTestCase。
fileprivate final class TestUnexpectedOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var finished = false
    private let file: StaticString
    private let line: UInt

    init(file: StaticString = #filePath, line: UInt = #line) { self.file = file; self.line = line }
    var calls: [String] { lock.withLock { recorded } }
    func finish() -> [String] { lock.withLock { finished = true; return recorded } }
    func refuse(_ operation: String) -> any Error {
        let late = lock.withLock { recorded.append(operation); return finished }
        if late { XCTFail("teardown 后仍触发未注入的写操作：\(operation)", file: file, line: line) }
        return TestOperationRefused(operation: operation)
    }
}

struct TestDeniedCleanupIO: CleanupMoving, CleanupPermanentDeleting {
    fileprivate let recorder: TestUnexpectedOperations
    func moveToTrash(_ url: URL) async throws -> URL { throw recorder.refuse("cleanup.moveToTrash") }
    func moveToQuarantine(_ url: URL, planID: CleanPlanID, itemID: UUID) async throws -> URL {
        throw recorder.refuse("cleanup.moveToQuarantine")
    }
    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws {
        throw recorder.refuse("cleanup.removeTrashEntry")
    }
}

struct TestDeniedBatteryPowerModeController: BatteryPowerModeControlling {
    fileprivate let recorder: TestUnexpectedOperations
    func readPowerModes() async -> BatteryPowerModes? { nil }
    func changePowerMode(source: BatteryPowerSource, mode: BatteryPowerMode) async -> BatteryPowerModeChangeResult {
        _ = recorder.refuse("battery.changePowerMode")
        return .failed
    }
}

struct TestDeniedBatteryPowerModeWriter: BatteryPowerModeCommandRunning {
    fileprivate let recorder: TestUnexpectedOperations
    func apply(_ command: BatteryPowerModeWriteCommand) async throws -> BatteryPowerModes? {
        throw recorder.refuse("battery.changePowerMode")
    }
}

private struct TestDeniedRecoveryReader: ReadOnlyFileSystem {
    let recorder: TestUnexpectedOperations
    func snapshot(at url: URL) throws -> FileSnapshot { throw recorder.refuse("cleanup.restore") }
    func children(of directory: URL) throws -> [URL] { throw recorder.refuse("cleanup.restore") }
}

struct TestDeniedUpdateExecutor: ApplicationUpdateExecuting {
    fileprivate let recorder: TestUnexpectedOperations
    func execute(application: InstalledApplication, task: ApplicationUpdateTask,
                 progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async throws -> ApplicationUpdateInstallResult {
        throw recorder.refuse("appUpdate.execute")
    }
    func reconcile(task: ApplicationUpdateTask, application: InstalledApplication?) async throws -> ApplicationUpdateInstallResult {
        throw recorder.refuse("appUpdate.reconcile")
    }
    func cancel(applicationID: String) async {}
}

@MainActor
private final class TestDeniedMemoryController: MemoryApplicationControlling {
    let recorder: TestUnexpectedOperations
    init(recorder: TestUnexpectedOperations) { self.recorder = recorder }
    func preflight(_ target: MemoryOptimizationTarget) -> MemoryPreflightStatus {
        RunningApplicationController().preflight(target)
    }
    func requestGracefulQuit(_ target: MemoryOptimizationTarget) -> Bool {
        _ = recorder.refuse("memory.quit"); return false
    }
    func requestForceQuit(_ target: MemoryOptimizationTarget) -> Bool {
        _ = recorder.refuse("memory.forceQuit"); return false
    }
}

private struct TestDeniedOwnerTerminator: BrowserPrivacyRunningApplicationChecking {
    let recorder: TestUnexpectedOperations
    func runningBundleIdentifiers(matching identifiers: Set<String>) async -> Set<String> {
        await BrowserPrivacyWorkspaceRunningApplicationChecker().runningBundleIdentifiers(matching: identifiers)
    }
    func requestNormalTermination(bundleIdentifiers: Set<String>, timeoutSeconds: TimeInterval) async -> Set<String> {
        _ = recorder.refuse("cleanup.quitOwner"); return bundleIdentifiers
    }
}

private struct TestDeniedStartupRunner: StartupItemsDomain.StartupProcessRunning {
    let recorder: TestUnexpectedOperations
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> StartupItemsDomain.StartupProcessResult {
        throw recorder.refuse("startup.command")
    }
}

@MainActor
final class TestOperationFactoryTests: XCTestCase {
    func testMissingOperationsRejectWithoutTouchingAFile() async throws {
        let recorder = TestUnexpectedOperations()
        let factory = TestOperationFactory(recorder: recorder)
        let operations = factory.scanOperations(scan: { _, _ in throw CancellationError() })
        let input = TestFileSystem.uniqueRoot("DeniedOperations").appendingPathComponent("never-created")
        let item = StorageItem(id: "denied", title: "Fixture", path: input.path, groupTitle: "Fixture",
            sizeBytes: 1, tier: .green, kind: "cache", reason: "fixture", recommendation: "fixture",
            risk: "low", requiresClose: "", trashPaths: [input.path], openPath: input.path, status: .available)
        let identity = FileIdentity(deviceID: 1, inode: 2, entryKind: .regularFile, creationTimeNanoseconds: 3)
        let deletion = CleanupTrashEntryDeletion(trashURL: input, trashIdentity: identity,
                                                entryName: "never-created", entryIdentity: identity)
        let attempts: [@Sendable () async throws -> Void] = [
            { _ = try await operations.moveToTrash(item, []) },
            { _ = try await operations.emptyTrash() },
            { _ = try await operations.restoreFromTrash([]) },
            { _ = try await operations.optimizeMemory() },
            { _ = try await operations.runHomebrewUpgrade([]) },
            { _ = try await factory.uninstallMoves().recycle(input) },
            { _ = try await factory.cleanupIO().moveToTrash(input) },
            { _ = try await factory.cleanupIO().moveToQuarantine(input, planID: CleanPlanID(), itemID: UUID()) },
            { try await factory.cleanupIO().removeTrashEntry(deletion) },
            { _ = try factory.analysisEnvironment(home: input).moveToTrash(input) }
        ]
        for operation in attempts {
            do { try await operation(); XCTFail("缺省操作必须拒绝") }
            catch { XCTAssertTrue(error is TestOperationRefused) }
        }
        let launch = operations.prepareOneClickUpdate(AppUpdateOneClickPlan(
            appStoreApps: [], automaticApps: [], authorizationApps: [], sparkleApps: [], manualApps: []))
        XCTAssertFalse(launch.openedAppStore)
        XCTAssertFalse(launch.copiedManualReviewList)
        XCTAssertEqual(recorder.calls, ["legacy.moveToTrash", "legacy.emptyTrash", "legacy.restoreFromTrash", "legacy.optimizeMemory",
            "legacy.runHomebrewUpgrade", "uninstall.recycle", "cleanup.moveToTrash", "cleanup.moveToQuarantine",
            "cleanup.removeTrashEntry", "fileAnalysis.moveToTrash", "legacy.prepareOneClickUpdate"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    }

    @MainActor
    func testFanHardwareRequestIsRecordedAndRefused() async {
        let recorder = TestUnexpectedOperations()
        let sender = TestOperationFactory(recorder: recorder).fanRequestSender()
        do { _ = try await sender(.restoreAutomatic); XCTFail("风扇请求必须拒绝") }
        catch { XCTAssertTrue(error is TestOperationRefused) }
        XCTAssertEqual(recorder.calls, ["fanControl.restoreAutomatic"])
    }

    @MainActor
    func testMacMiniRequestsWithoutAnOverrideAreRecordedAndRefused() async {
        let recorder = TestUnexpectedOperations()
        let sender = TestOperationFactory(recorder: recorder).fanRequestSender()
        for mode in MacMiniMode.allCases {
            do { _ = try await sender(.setMacMiniMode(mode)); XCTFail("合盖睡眠写入必须拒绝") }
            catch { XCTAssertTrue(error is TestOperationRefused) }
        }
        XCTAssertEqual(recorder.calls, ["fanControl.setMacMiniMode", "fanControl.setMacMiniMode"])
    }

    @MainActor
    func testExplicitMacMiniFakeCannotHandleAnUnlistedRequest() async {
        let recorder = TestUnexpectedOperations()
        var fakeCalls = 0
        let sender = TestOperationFactory(recorder: recorder).fanRequestSender(handling: [.readMacMiniMode]) { request in
            fakeCalls += 1
            return FanControlHelperReply(operation: request.operation, success: false, message: "fake", appliedTargetRPMByFan: [:])
        }
        do { _ = try await sender(.setMacMiniMode(.whenOnAC)); XCTFail("未列出的写入必须拒绝") }
        catch { XCTAssertTrue(error is TestOperationRefused) }
        XCTAssertEqual(fakeCalls, 0)
        XCTAssertEqual(recorder.calls, ["fanControl.setMacMiniMode"])
    }

    func testBatteryServiceRecordsAndRefusesAnActualChangeRequest() async {
        let recorder = TestUnexpectedOperations()
        let factory = TestOperationFactory(recorder: recorder)
        let service = BatteryHealthService(runner: TestBatteryModeReader(), powerModeWriter: factory.batteryPowerModeWriter(),
                                           powerSampleProvider: { nil }, verificationDelay: {})
        let result = await service.changePowerMode(source: .batteryPower, mode: .lowPower)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(recorder.calls, ["battery.changePowerMode"])
    }

    @MainActor
    func testComputerHealthStoreForwardsToTheRefusingController() async {
        let recorder = TestUnexpectedOperations()
        let controller = TestOperationFactory(recorder: recorder).batteryPowerModeController()
        let modes = await controller.readPowerModes()
        XCTAssertNil(modes)
        XCTAssertEqual(recorder.calls, [], "只读请求不能登记写操作")
        let store = ComputerHealthStore(probe: TestUnavailableComputerHealthProbe(), batteryPowerModeController: controller)
        await store.changeBatteryPowerMode(source: .batteryPower, mode: .lowPower)
        XCTAssertEqual(store.batteryPowerModeAdjustmentState, .failed(source: .batteryPower, mode: .lowPower))
        XCTAssertEqual(recorder.calls, ["battery.changePowerMode"])
    }

    func testPrivilegedBatteryRunnerForwardsOnlyToTheInjectedCoordinator() async throws {
        let recorder = TestUnexpectedOperations()
        let defaults = TestPreferenceDomain.make(for: self)
        let controller = FanControlCoordinator(defaults: defaults, helperStatusOverride: .enabled,
            requestSender: TestOperationFactory(recorder: recorder).fanRequestSender(),
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }, serviceRegistrar: { throw CancellationError() })
        var providerCalls = 0
        let writer = PrivilegedBatteryPowerModeCommandRunner(fanControlProvider: {
            providerCalls += 1
            return controller
        })
        XCTAssertEqual(providerCalls, 0, "生产 runner 保持惰性获取控制器")
        let command = try XCTUnwrap(BatteryPowerModeWriteCommand.make(source: .batteryPower, mode: .lowPower, setting: .powerMode))
        do { _ = try await writer.apply(command); XCTFail("硬件写请求必须被替身拒绝") }
        catch { XCTAssertEqual(error as? BatteryPowerModeCommandFailure, .unavailable) }
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(recorder.calls, ["fanControl.applyPowerMode"])
    }

    func testExplicitIsolatedOperationDoesNotEnableAnUnspecifiedOne() async throws {
        let recorder = TestUnexpectedOperations()
        let operations = TestOperationFactory(recorder: recorder).scanOperations(emptyTrash: { .empty })
        let result = try await operations.emptyTrash()
        XCTAssertEqual(result, .empty)
        XCTAssertEqual(recorder.calls, [])
        do { _ = try await operations.restoreFromTrash([]); XCTFail("遗漏的恢复操作必须拒绝") }
        catch { XCTAssertTrue(error is TestOperationRefused) }
        XCTAssertEqual(recorder.calls, ["legacy.restoreFromTrash"])
    }
}

private struct TestBatteryModeReader: BatteryHealthCommandRunning {
    func capture(_ command: BatteryHealthCommand) async throws -> Data {
        guard command == BatteryHealthService.powerModesCommand else { throw CancellationError() }
        return Data("Battery Power:\n powermode 0\nAC Power:\n powermode 0\n".utf8)
    }
}
