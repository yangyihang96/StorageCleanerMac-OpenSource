import Dispatch
import Foundation

struct ScanBulkTrashResult: Sendable {
    let movedItems: [StorageItem]
    let movedItemIDs: Set<String>
    let moveRecords: [TrashMoveRecord]
    let failedTitles: [String]
}

struct ScanHeavyWorkCleanupPendingError: LocalizedError, @unchecked Sendable {
    let reaper: ShellProcessCleanupReaper

    var errorDescription: String? {
        L10n.text(
            "已多次尝试结束 Homebrew 相关进程，但系统未能确认已跟踪进程全部退出。确认退出前，其他重型操作会保持锁定。",
            "The app repeatedly tried to stop related Homebrew processes. Other heavy operations remain locked until every tracked process exit is verified."
        )
    }
}

struct ScanHeavyWorkService: Sendable {
    struct Operations: Sendable {
        let scan: @Sendable (ScanMode, DiskScanProgressHandler?) async throws -> ScanResult
        let duplicateScan: @Sendable () async throws -> [StorageItem]
        let moveToTrash: @Sendable (StorageItem, Set<String>) async throws -> [TrashMoveRecord]
        let emptyTrash: @Sendable () async throws -> TrashSummary
        let restoreFromTrash: @Sendable ([TrashMoveRecord]) async throws -> TrashRestoreSummary
        let optimizeMemory: @Sendable () async throws -> MemoryOptimizationResult
        let runHomebrewUpgrade: @Sendable ([AppUpdateItem]) async throws -> AppUpdateHomebrewRunResult
        let prepareOneClickUpdate: @MainActor @Sendable (AppUpdateOneClickPlan) -> AppUpdateOneClickLaunchResult

        init(
            scan: @escaping @Sendable (ScanMode, DiskScanProgressHandler?) async throws -> ScanResult = { mode, progressHandler in
                try await Task.detached(priority: .userInitiated) {
                    try DiskScanner(
                        scanMode: mode,
                        progressHandler: progressHandler
                    ).scan()
                }.value
            },
            duplicateScan: @escaping @Sendable () async throws -> [StorageItem] = {
                await Task.detached(priority: .userInitiated) {
                    let groups = DuplicateFileScanner.scanGroups(configuration: .userFiles())
                    return DiskScanner.itemsForDuplicateGroups(groups)
                }.value
            },
            moveToTrash: @escaping @Sendable (StorageItem, Set<String>) async throws -> [TrashMoveRecord] = { item, allowedPaths in
                try await Task.detached(priority: .userInitiated) {
                    try CleanupService.moveToTrash(item, allowedPaths: allowedPaths)
                }.value
            },
            emptyTrash: @escaping @Sendable () async throws -> TrashSummary = {
                try await Task.detached(priority: .userInitiated) {
                    try CleanupService.emptyUserTrash()
                }.value
            },
            restoreFromTrash: @escaping @Sendable ([TrashMoveRecord]) async throws -> TrashRestoreSummary = { records in
                await Task.detached(priority: .userInitiated) {
                    CleanupService.restoreFromTrash(records)
                }.value
            },
            optimizeMemory: @escaping @Sendable () async throws -> MemoryOptimizationResult = {
                await MemoryOptimizerService.optimize()
            },
            runHomebrewUpgrade: @escaping @Sendable ([AppUpdateItem]) async throws -> AppUpdateHomebrewRunResult = { apps in
                try await ScanHeavyWorkService.runCancellableHomebrewUpgrade(for: apps)
            },
            prepareOneClickUpdate: @escaping @MainActor @Sendable (AppUpdateOneClickPlan) -> AppUpdateOneClickLaunchResult = { plan in
                AppUpdateService.prepareOneClickUpdate(plan, opensAppStore: true)
            }
        ) {
            self.scan = scan
            self.duplicateScan = duplicateScan
            self.moveToTrash = moveToTrash
            self.emptyTrash = emptyTrash
            self.restoreFromTrash = restoreFromTrash
            self.optimizeMemory = optimizeMemory
            self.runHomebrewUpgrade = runHomebrewUpgrade
            self.prepareOneClickUpdate = prepareOneClickUpdate
        }
    }

    let coordinator: HeavyWorkCoordinator
    private let operations: Operations
    private let onCleanupQuarantineCleared: @Sendable () async -> Void

    init(
        coordinator: HeavyWorkCoordinator,
        operations: Operations = Operations(),
        onCleanupQuarantineCleared: @escaping @Sendable () async -> Void = {}
    ) {
        self.coordinator = coordinator
        self.operations = operations
        self.onCleanupQuarantineCleared = onCleanupQuarantineCleared
    }

    func scan(
        mode: ScanMode,
        lease: HeavyWorkCoordinator.Lease,
        progressHandler: DiskScanProgressHandler? = nil
    ) async throws -> ScanResult {
        try await coordinator.requireValid(lease, owner: .mainScan)
        return try await operations.scan(mode, progressHandler)
    }

    func scanDuplicates(
        lease: HeavyWorkCoordinator.Lease
    ) async throws -> [StorageItem] {
        try await coordinator.requireValid(lease, owner: .duplicateScan)
        return try await operations.duplicateScan()
    }

    func moveToTrash(
        item: StorageItem,
        allowedPaths: Set<String>,
        lease: HeavyWorkCoordinator.Lease
    ) async throws -> [TrashMoveRecord] {
        try await coordinator.requireValid(lease, owner: .cleanup)
        try Task.checkCancellation()
        return try await operations.moveToTrash(item, allowedPaths)
    }

    func moveToTrash(
        items: [StorageItem],
        allowedPaths: Set<String>,
        lease: HeavyWorkCoordinator.Lease
    ) async throws -> ScanBulkTrashResult {
        try await coordinator.requireValid(lease, owner: .cleanup)

        var movedItems = [StorageItem]()
        var movedItemIDs = Set<String>()
        var moveRecords = [TrashMoveRecord]()
        var failedTitles = [String]()

        for item in items {
            try Task.checkCancellation()
            try await coordinator.requireValid(lease, owner: .cleanup)
            do {
                let records = try await operations.moveToTrash(item, allowedPaths)
                movedItems.append(item)
                movedItemIDs.insert(item.id)
                moveRecords.append(contentsOf: records)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HeavyWorkCoordinator.Error {
                throw error
            } catch {
                failedTitles.append(item.title)
            }
        }

        return ScanBulkTrashResult(
            movedItems: movedItems,
            movedItemIDs: movedItemIDs,
            moveRecords: moveRecords,
            failedTitles: failedTitles
        )
    }

    func emptyTrash(
        lease: HeavyWorkCoordinator.Lease
    ) async throws -> TrashSummary {
        try await coordinator.requireValid(lease, owner: .emptyTrash)
        try Task.checkCancellation()
        return try await operations.emptyTrash()
    }

    func restoreFromTrash(
        records: [TrashMoveRecord],
        lease: HeavyWorkCoordinator.Lease
    ) async throws -> TrashRestoreSummary {
        try await coordinator.requireValid(lease, owner: .restore)
        try Task.checkCancellation()
        return try await operations.restoreFromTrash(records)
    }

    func optimizeMemory(
        lease: HeavyWorkCoordinator.Lease
    ) async throws -> MemoryOptimizationResult {
        try await coordinator.requireValid(lease, owner: .memoryOptimization)
        try Task.checkCancellation()
        return try await operations.optimizeMemory()
    }

    func runAppUpdates(
        plan: AppUpdateOneClickPlan,
        lease: HeavyWorkCoordinator.Lease
    ) async throws -> AppUpdateOneClickResult {
        try await coordinator.requireValid(lease, owner: .appUpdates)
        try Task.checkCancellation()

        // "Update All" is deliberately limited to providers that can complete
        // and report a verifiable result in-process. App Store, website and
        // in-app update entries remain in their dedicated guided workflows.
        let launched = AppUpdateOneClickLaunchResult(
            openedAppStore: false,
            copiedManualReviewList: false
        )
        let appStore = AppUpdateAppStoreRunResult(
            status: .skipped,
            command: nil,
            detail: L10n.text(
                "App Store 项目不属于自动更新队列。",
                "App Store items are not part of the automatic update queue."
            )
        )

        try await coordinator.requireValid(lease, owner: .appUpdates)
        try Task.checkCancellation()
        let automatic: AppUpdateAutomaticRunResult
        do {
            automatic = try await operations.runHomebrewUpgrade(
                plan.automaticApps.filter { $0.primaryUpdateProvider == .homebrew }
            )
        } catch let error as ScanHeavyWorkCleanupPendingError {
            let quarantine = try await coordinator.beginCleanupQuarantine(lease)
            Self.monitorQuarantinedCleanup(
                error.reaper,
                coordinator: coordinator,
                quarantine: quarantine,
                onCleared: onCleanupQuarantineCleared
            )
            throw error
        }
        try Task.checkCancellation()

        return AppUpdateOneClickResult(
            launched: launched,
            appStore: appStore,
            automatic: automatic,
            generatedAt: Date()
        )
    }

    private static let homebrewOutputByteLimit = 1_048_576
    private static let homebrewTimeout: TimeInterval = 600
    static let homebrewCleanupRetryLimit = 100
    private static let homebrewCleanupRetryDelay: TimeInterval = 0.1

    private static func runCancellableHomebrewUpgrade(
        for apps: [AppUpdateItem]
    ) async throws -> AppUpdateHomebrewRunResult {
        let arguments = AppUpdateService.homebrewUpgradeArguments(for: apps)
        let command = AppUpdateService.homebrewUpgradeCommand(for: apps)

        guard !arguments.isEmpty else {
            return AppUpdateHomebrewRunResult(
                status: .skipped,
                command: command,
                detail: L10n.text(
                    "没有 Homebrew Cask 应用需要处理。",
                    "No Homebrew Cask apps to process."
                )
            )
        }

        guard let executable = AppUpdateService.brewExecutablePath() else {
            return AppUpdateHomebrewRunResult(
                status: .unavailable,
                command: command,
                detail: L10n.text("未找到 Homebrew。", "Homebrew was not found.")
            )
        }

        let cancellation = ScanHeavyWorkCancellationSignal()
        let cleanupQueue = DispatchQueue(
            label: "StorageCleanerMac.HomebrewProcessCleanup",
            qos: .utility
        )
        let cleanupReaper = ShellProcessCleanupReaper(
            retryDelay: homebrewCleanupRetryDelay,
            maximumRetryCount: homebrewCleanupRetryLimit
        ) { delay, operation in
            cleanupQueue.asyncAfter(deadline: .now() + delay) {
                operation.run()
            }
        }

        do {
            let output = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await Task.detached(priority: .userInitiated) {
                    try Shell.captureCancellable(
                        executable,
                        arguments,
                        timeout: homebrewTimeout,
                        outputByteLimit: homebrewOutputByteLimit,
                        cancellationCheck: { cancellation.isCancelled },
                        cleanupReaper: cleanupReaper,
                        cleanupWaitTimeout: 1
                    )
                }.value
            } onCancel: {
                cancellation.cancel()
            }

            return AppUpdateHomebrewRunResult(
                status: .succeeded,
                command: command,
                detail: output.trimmed.isEmpty
                    ? L10n.text(
                        "Homebrew 更新命令已完成；请重新检查更新列表确认版本。",
                        "Homebrew update command completed; rescan updates to confirm versions."
                    )
                    : output.trimmed
            )
        } catch let error as ShellError {
            if case .terminationFailed = error {
                let didVerifyExit = await waitForVerifiedProcessExit(cleanupReaper)
                guard didVerifyExit else {
                    throw ScanHeavyWorkCleanupPendingError(reaper: cleanupReaper)
                }
            }

            switch error {
            case .cancelled:
                throw CancellationError()
            case let .failed(_, _, output) where AppUpdateService.needsInteractiveTerminal(output):
                return AppUpdateHomebrewRunResult(
                    status: .needsTerminal,
                    command: command,
                    detail: L10n.text(
                        "Homebrew 需要终端授权；应用内未继续启动无法跟踪的脚本。请在终端手动执行显示的命令。",
                        "Homebrew needs Terminal authorization. The app did not launch an untracked script; run the displayed command manually in Terminal."
                    )
                )
            case .timedOut:
                return AppUpdateHomebrewRunResult(
                    status: .timedOut,
                    command: command,
                    detail: L10n.text(
                        "Homebrew 更新超时，已结束并确认进程退出。",
                        "Homebrew update timed out; the process was stopped and its exit was verified."
                    )
                )
            default:
                return AppUpdateHomebrewRunResult(
                    status: .failed,
                    command: command,
                    detail: error.localizedDescription
                )
            }
        }
    }

    private static func waitForVerifiedProcessExit(
        _ reaper: ShellProcessCleanupReaper
    ) async -> Bool {
        while reaper.hasPendingCleanup, !reaper.hasExhaustedCleanup {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
                    continuation.resume()
                }
            }
        }
        return !reaper.hasPendingCleanup
    }

    private static func monitorQuarantinedCleanup(
        _ reaper: ShellProcessCleanupReaper,
        coordinator: HeavyWorkCoordinator,
        quarantine: HeavyWorkCoordinator.CleanupQuarantine,
        onCleared: @escaping @Sendable () async -> Void
    ) {
        Task.detached(priority: .utility) {
            var delayMilliseconds = 100
            while reaper.hasPendingCleanup {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                delayMilliseconds = min(delayMilliseconds * 2, 2_000)
            }
            await coordinator.clearCleanupQuarantine(quarantine)
            await onCleared()
        }
    }
}

private final class ScanHeavyWorkCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
