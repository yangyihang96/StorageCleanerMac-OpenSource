import Foundation
import XCTest
@testable import StorageCleanerMac

final class HeavyWorkIntegrationTests: XCTestCase {
    func testRootAppWiresNetworkStoreToTheSharedCoordinator() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains(
            """
            NetworkSpeedTestStore(
                        heavyWorkCoordinator: coordinator,
                        heavyWorkActivityStore: activityStore,
            """
        ))
        XCTAssertTrue(appSource.contains(
            "resultRepository: NetworkSpeedTestResultRepository()"
        ))
    }

    func testHomebrewCleanupRetryBudgetIsFinite() {
        XCTAssertGreaterThan(ScanHeavyWorkService.homebrewCleanupRetryLimit, 0)
        XCTAssertLessThan(ScanHeavyWorkService.homebrewCleanupRetryLimit, 1_000)
    }

    func testDestructiveBoundaryRejectsForgedLeaseBeforeMutation() async throws {
        let coordinator = HeavyWorkCoordinator()
        let mutationCount = InvocationCounter()
        let service = ScanHeavyWorkService(
            coordinator: coordinator,
            operations: .init(moveToTrash: { _, _ in
                await mutationCount.increment()
                return []
            })
        )
        let activeLease = try await coordinator.acquire(owner: .benchmark)
        let forgedLease = HeavyWorkCoordinator.Lease(token: UUID(), owner: .cleanup)

        do {
            _ = try await service.moveToTrash(
                item: makeStorageItem(),
                allowedPaths: ["/tmp/heavy-work-test"],
                lease: forgedLease
            )
            XCTFail("Expected invalid lease")
        } catch let error as HeavyWorkCoordinator.Error {
            XCTAssertEqual(error, .invalidLease(expectedOwner: .cleanup))
        }

        let finalMutationCount = await mutationCount.value
        let finalOwner = await coordinator.activeOwner
        XCTAssertEqual(finalMutationCount, 0)
        XCTAssertEqual(finalOwner, .benchmark)
        await coordinator.release(activeLease)
    }

    @MainActor
    func testMainScanOwnsLeaseOnlyDuringPhysicalScanAndReleasesBeforeBrowsing() async throws {
        let coordinator = HeavyWorkCoordinator()
        let gate = AsyncValueGate(value: makeScanResult())
        let store = ScanStore(
            heavyWorkCoordinator: coordinator,
            scanHeavyWorkOperations: .init(scan: { _, _ in
                await gate.wait()
            }),
            cleanupFeatureConfiguration: .legacy
        )

        store.startScan()
        await gate.waitUntilStarted()

        XCTAssertTrue(store.isScanning)
        let ownerWhileScanning = await coordinator.activeOwner
        XCTAssertEqual(ownerWhileScanning, .mainScan)

        await gate.open()
        await waitUntil { !store.isScanning }

        XCTAssertNotNil(store.result)
        let ownerAfterScan = await coordinator.activeOwner
        XCTAssertNil(ownerAfterScan)
        XCTAssertNil(store.heavyWorkActivityStore.activeOwner)
    }

    @MainActor
    func testApplicationInventoryRefreshCannotOverlapOtherHeavyWork() async throws {
        let coordinator = HeavyWorkCoordinator()
        let inventoryScanner = CountingApplicationInventoryScanner(applications: [])
        let store = ScanStore(
            heavyWorkCoordinator: coordinator,
            applicationInventoryScanner: inventoryScanner
        )
        let largeFilesLease = try await coordinator.acquire(owner: .largeFilesScan)

        store.refreshAppUpdates()
        await waitUntil { !store.isLoadingAppUpdates }

        let scanCount = await inventoryScanner.scanCount
        let owner = await coordinator.activeOwner
        XCTAssertEqual(scanCount, 0)
        XCTAssertEqual(owner, .largeFilesScan)
        XCTAssertEqual(store.heavyWorkActivityStore.activeOwner, .largeFilesScan)
        XCTAssertFalse(store.canRefreshAppUpdates)

        await coordinator.release(largeFilesLease)
        await store.heavyWorkActivityStore.refresh()
    }

    @MainActor
    func testConfirmationPreviewHoldsNoLeaseAndCleanupReacquiresNewLease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let gate = AsyncValueGate(value: [TrashMoveRecord]())
        let item = makeStorageItem()
        let store = ScanStore(
            heavyWorkCoordinator: coordinator,
            scanHeavyWorkOperations: .init(moveToTrash: { _, _ in
                await gate.wait()
            }),
            cleanupFeatureConfiguration: .legacy
        )
        store.result = makeScanResult(items: [item])

        store.requestTrash(item)

        XCTAssertEqual(store.pendingTrashItem?.id, item.id)
        let ownerDuringPreview = await coordinator.activeOwner
        XCTAssertNil(ownerDuringPreview)

        store.confirmTrash()
        await gate.waitUntilStarted()

        let ownerDuringCleanup = await coordinator.activeOwner
        XCTAssertEqual(ownerDuringCleanup, .cleanup)
        XCTAssertNil(store.pendingTrashItem)

        await gate.open()
        await waitUntil {
            store.result?.items.first(where: { $0.id == item.id })?.status == .movedToTrash
        }

        let ownerAfterCleanup = await coordinator.activeOwner
        XCTAssertNil(ownerAfterCleanup)
    }

    @MainActor
    func testBusyBenchmarkBlocksMemoryOptimizationWithoutInvokingService() async throws {
        let coordinator = HeavyWorkCoordinator()
        let optimizationCount = InvocationCounter()
        let store = ScanStore(
            heavyWorkCoordinator: coordinator,
            scanHeavyWorkOperations: .init(optimizeMemory: {
                await optimizationCount.increment()
                return makeMemoryOptimizationResult()
            })
        )
        let benchmarkLease = try await coordinator.acquire(owner: .benchmark)

        store.optimizeMemory()
        await waitUntil { !store.isOptimizingMemory }

        let finalOptimizationCount = await optimizationCount.value
        let ownerAfterConflict = await coordinator.activeOwner
        XCTAssertEqual(finalOptimizationCount, 0)
        XCTAssertEqual(ownerAfterConflict, .benchmark)
        XCTAssertEqual(store.heavyWorkActivityStore.activeOwner, .benchmark)
        XCTAssertNotNil(store.heavyWorkActivityStore.conflictMessage)
        XCTAssertNotNil(store.actionMessage)
        await coordinator.release(benchmarkLease)
    }

    @MainActor
    func testDuplicateEmptyTrashRestoreAndAppUpdatesUseIndependentOwners() async throws {
        let coordinator = HeavyWorkCoordinator()
        let inventoryScanner = CountingApplicationInventoryScanner(applications: [])
        let duplicateGate = AsyncValueGate(value: [StorageItem]())
        let emptyTrashGate = AsyncValueGate(value: TrashSummary.empty)
        let restoreGate = AsyncValueGate(value: TrashRestoreSummary.empty)
        let updateGate = AsyncValueGate(value: ApplicationUpdateInstallResult(
            applicationID: makeHomebrewUpdate().id,
            state: .completed,
            observedVersion: ApplicationVersion(marketing: "2.0"),
            detail: "verified"
        ))
        let applicationUpdateCoordinator = ApplicationUpdateCoordinator(
            repository: HeavyWorkMemoryApplicationUpdateQueueRepository(),
            executor: HeavyWorkGatedApplicationUpdateExecutor(
                coordinator: coordinator,
                gate: updateGate
            )
        )
        let store = ScanStore(
            heavyWorkCoordinator: coordinator,
            scanHeavyWorkOperations: .init(
                duplicateScan: { await duplicateGate.wait() },
                emptyTrash: { await emptyTrashGate.wait() },
                restoreFromTrash: { _ in await restoreGate.wait() }
            ),
            duplicateFilesScanOperation: { _, _, _, _, _ in
                _ = await duplicateGate.wait()
                return DuplicateFileScanReport(
                    exactGroups: [],
                    candidates: [],
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
            },
            applicationInventoryScanner: inventoryScanner,
            applicationUpdateCoordinator: applicationUpdateCoordinator,
            cleanupFeatureConfiguration: .legacy
        )

        store.scanDuplicateFiles()
        await duplicateGate.waitUntilStarted()
        let duplicateOwner = await coordinator.activeOwner
        XCTAssertEqual(duplicateOwner, .duplicateScan)
        await duplicateGate.open()
        await waitUntil { !store.isScanningDuplicates }
        let ownerAfterDuplicate = await coordinator.activeOwner
        XCTAssertNil(ownerAfterDuplicate)

        store.pendingEmptyTrashSummary = TrashSummary(itemCount: 1, totalBytes: 1)
        store.confirmEmptyTrash()
        await emptyTrashGate.waitUntilStarted()
        let emptyTrashOwner = await coordinator.activeOwner
        XCTAssertEqual(emptyTrashOwner, .emptyTrash)
        await emptyTrashGate.open()
        await waitUntil { !store.isEmptyingTrash }
        let ownerAfterEmptyTrash = await coordinator.activeOwner
        XCTAssertNil(ownerAfterEmptyTrash)

        let record = TrashMoveRecord(
            originalPath: "/tmp/original",
            resultingItemURL: URL(fileURLWithPath: "/tmp/trashed"),
            itemIdentity: TrashItemIdentity(
                deviceID: 1,
                fileID: 2,
                objectType: 0,
                birthTimeSeconds: 3,
                birthTimeNanoseconds: 4
            ),
            movedAt: Date()
        )
        let entry = makeCleanupHistoryEntry(record: record)
        store.cleanupHistorySummary = CleanupHistorySummary(entries: [entry])
        store.requestRestoreLatestCleanup()
        let ownerDuringRestorePreview = await coordinator.activeOwner
        XCTAssertNil(ownerDuringRestorePreview)
        store.confirmRestoreLatestCleanup()
        await restoreGate.waitUntilStarted()
        let restoreOwner = await coordinator.activeOwner
        XCTAssertEqual(restoreOwner, .restore)
        await restoreGate.open()
        await waitUntil { !store.isRestoringCleanup }
        let ownerAfterRestore = await coordinator.activeOwner
        XCTAssertNil(ownerAfterRestore)

        let app = makeHomebrewUpdate()
        store.appUpdates = [app]
        store.previewOneClickAppUpdates()
        XCTAssertNotNil(store.pendingOneClickUpdatePlan)
        let ownerDuringUpdatePreview = await coordinator.activeOwner
        XCTAssertNil(ownerDuringUpdatePreview)
        store.confirmOneClickAppUpdates()
        await updateGate.waitUntilStarted()
        let updateOwner = await coordinator.activeOwner
        XCTAssertEqual(updateOwner, .appUpdates)
        await updateGate.open()
        await waitUntil { !store.isRunningOneClickUpdate }
        let ownerAfterUpdates = await coordinator.activeOwner
        XCTAssertNil(ownerAfterUpdates)
        XCTAssertEqual(store.oneClickUpdateResult?.automatic.status, .succeeded)
        XCTAssertEqual(store.oneClickUpdateResult?.appStore.status, .skipped)
        await waitUntilAsync { await inventoryScanner.scanCount == 1 }
        let successfulBatchScanCount = await inventoryScanner.scanCount
        XCTAssertEqual(successfulBatchScanCount, 1)
    }

    @MainActor
    func testStaleAutomaticAppStoreFlagsStillRequireSystemConfirmation() async throws {
        var app = AppUpdateTestFixtures.application(
            id: "app-store-automatic",
            name: "App Store Automatic",
            bundleIdentifier: "com.example.app-store-automatic",
            path: "/Applications/App Store Automatic.app",
            availableVersion: "2.0",
            installationSource: .appStore,
            provider: .macAppStore,
            status: .automaticallyUpdatable,
            sourceEvidence: [
                "verified-app-store-receipt",
                "valid-code-signature",
                "signed-bundle-identity",
                "mas-executable-trusted",
                "mas-product-id:123456789",
            ],
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        app.appStoreProductURL = URL(string: "https://apps.apple.com/app/id123456789")
        XCTAssertEqual(ApplicationUpdatePlanBuilder.destination(for: app), .appStore)
        XCTAssertFalse(ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(app))

        let plan = ApplicationUpdatePlanBuilder().build(applications: [app])
        XCTAssertTrue(plan.automaticApplicationIDs.isEmpty)
        XCTAssertEqual(plan.appStoreApplicationIDs, [app.id])
    }

    @MainActor
    func testPartialUpdateFailureWaitsForEveryTaskThenRunsOneFullInventoryRefresh() async throws {
        let success = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "success",
            token: "success",
            path: "/Applications/Success.app"
        )
        let failure = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "failure",
            token: "failure",
            path: "/Applications/Failure.app"
        )
        let successGate = AsyncValueGate(value: ApplicationUpdateInstallResult(
            applicationID: success.id,
            state: .completed,
            observedVersion: ApplicationVersion(marketing: "2.0"),
            detail: "verified"
        ))
        let executor = MixedResultApplicationUpdateExecutor(
            failureIDs: [failure.id],
            gatedResults: [success.id: successGate]
        )
        let applicationUpdateCoordinator = ApplicationUpdateCoordinator(
            repository: HeavyWorkMemoryApplicationUpdateQueueRepository(),
            executor: executor
        )
        let inventoryScanner = CountingApplicationInventoryScanner(applications: [success, failure])
        let store = ScanStore(
            applicationInventoryScanner: inventoryScanner,
            applicationUpdateCoordinator: applicationUpdateCoordinator
        )
        store.appUpdates = [failure, success]

        store.previewOneClickAppUpdates()
        store.confirmOneClickAppUpdates()
        await successGate.waitUntilStarted()

        let scanCountWhileSecondTaskRuns = await inventoryScanner.scanCount
        XCTAssertEqual(scanCountWhileSecondTaskRuns, 0)
        XCTAssertTrue(store.isRunningOneClickUpdate)

        await successGate.open()
        await waitUntilAsync {
            let scanCount = await inventoryScanner.scanCount
            return !store.isRunningOneClickUpdate && !store.isLoadingAppUpdates
                && scanCount == 1
        }

        let executionOrder = await executor.executionOrder()
        XCTAssertEqual(Set(executionOrder), [failure.id, success.id])
        XCTAssertEqual(store.oneClickUpdateResult?.automatic.status, .failed)
        var finalScanCount = await inventoryScanner.scanCount
        XCTAssertEqual(finalScanCount, 1)
        for _ in 0..<20 { await Task.yield() }
        finalScanCount = await inventoryScanner.scanCount
        XCTAssertEqual(finalScanCount, 1)
    }

    @MainActor
    func testExecutionTimeQuitResumesExactBatchItemAndScansInventoryOnceAfterCompletion() async throws {
        var preferences = ApplicationUpdatePreferences.snapshot()
        let originalPreferences = preferences
        preferences.updatesAfterApplicationQuits = true
        ApplicationUpdatePreferences.set(preferences)
        defer { ApplicationUpdatePreferences.set(originalPreferences) }

        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "/tmp/ExecutionTimeRunning.app",
            token: "execution-time-running",
            path: "/tmp/ExecutionTimeRunning.app"
        )
        let executor = ExecutionTimeWaitThenSuccessExecutor()
        let coordinator = ApplicationUpdateCoordinator(
            repository: HeavyWorkMemoryApplicationUpdateQueueRepository(),
            executor: executor
        )
        let inventoryScanner = CountingApplicationInventoryScanner(applications: [application])
        let store = ScanStore(
            applicationInventoryScanner: inventoryScanner,
            applicationUpdateCoordinator: coordinator
        )
        store.appUpdates = [application]

        store.previewOneClickAppUpdates()
        store.confirmOneClickAppUpdates()
        await waitUntil {
            store.appUpdates.first?.updateStatus == .waitingForQuit
                && store.appUpdateQueueSnapshot?.tasks.first?.state == .waitingForQuit
        }

        let scansWhileWaiting = await inventoryScanner.scanCount
        let firstExecutionCount = await executor.executionCount
        XCTAssertEqual(scansWhileWaiting, 0)
        XCTAssertEqual(firstExecutionCount, 1)

        store.applicationDidTerminateForUpdates(
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL
        )
        await waitUntilAsync {
            let scanCount = await inventoryScanner.scanCount
            return !store.isRunningOneClickUpdate
                && !store.isLoadingAppUpdates
                && scanCount == 1
        }

        let finalExecutionCount = await executor.executionCount
        XCTAssertEqual(finalExecutionCount, 2)
        XCTAssertEqual(store.oneClickUpdateResult?.automatic.status, .succeeded)
        var finalScanCount = await inventoryScanner.scanCount
        XCTAssertEqual(finalScanCount, 1)
        for _ in 0..<20 { await Task.yield() }
        finalScanCount = await inventoryScanner.scanCount
        XCTAssertEqual(finalScanCount, 1)
    }

    @MainActor
    func testBulkCleanupUsesCleanupOwnerAndPublishesAfterGenerationMatch() async throws {
        let coordinator = HeavyWorkCoordinator()
        let gate = AsyncValueGate(value: [TrashMoveRecord]())
        let item = makeStorageItem(id: "bulk-selected")
        let excludedItem = makeStorageItem(id: "bulk-excluded")
        let store = ScanStore(
            heavyWorkCoordinator: coordinator,
            scanHeavyWorkOperations: .init(moveToTrash: { _, _ in
                await gate.wait()
            }),
            cleanupFeatureConfiguration: .legacy
        )
        store.result = makeScanResult(items: [item, excludedItem])
        store.requestTrashAllGreen()

        XCTAssertEqual(
            Set(store.pendingBulkTrashItems.map(\.id)),
            Set([item.id, excludedItem.id])
        )
        let ownerDuringBulkPreview = await coordinator.activeOwner
        XCTAssertNil(ownerDuringBulkPreview)

        store.confirmTrashAllGreen(selectedItemIDs: [item.id])
        await gate.waitUntilStarted()
        let ownerDuringBulkCleanup = await coordinator.activeOwner
        XCTAssertEqual(ownerDuringBulkCleanup, .cleanup)
        XCTAssertEqual(store.cleanupOperationSnapshot?.requestedCount, 1)
        XCTAssertFalse(store.cleanupOperationSnapshot?.isComplete ?? true)

        await gate.open()
        await waitUntil {
            store.result?.items.first?.status == .movedToTrash
        }
        XCTAssertEqual(
            store.result?.items.first(where: { $0.id == excludedItem.id })?.status,
            .available
        )
        XCTAssertEqual(store.cleanupOperationSnapshot?.movedCount, 1)
        XCTAssertEqual(store.cleanupOperationSnapshot?.failedCount, 0)
        XCTAssertTrue(store.cleanupOperationSnapshot?.isComplete ?? false)
        let ownerAfterBulkCleanup = await coordinator.activeOwner
        XCTAssertNil(ownerAfterBulkCleanup)
    }

    @MainActor
    func testCancellationRequestedBeforeDrainedDoesNotFinishNotifyOrRefresh() async throws {
        let coordinator = HeavyWorkCoordinator()
        let inventoryScanner = CountingApplicationInventoryScanner(applications: [])
        let app = makeHomebrewUpdate()
        let updateGate = AsyncValueGate(value: ApplicationUpdateInstallResult(
            applicationID: app.id,
            state: .completed,
            observedVersion: ApplicationVersion(marketing: "2.0"),
            detail: "verified"
        ))
        let applicationUpdateCoordinator = ApplicationUpdateCoordinator(
            repository: HeavyWorkMemoryApplicationUpdateQueueRepository(),
            executor: HeavyWorkGatedApplicationUpdateExecutor(
                coordinator: coordinator,
                gate: updateGate
            )
        )
        let store = ScanStore(
            heavyWorkCoordinator: coordinator,
            applicationInventoryScanner: inventoryScanner,
            applicationUpdateCoordinator: applicationUpdateCoordinator
        )
        store.appUpdates = [app]
        store.previewOneClickAppUpdates()
        store.confirmOneClickAppUpdates()
        await updateGate.waitUntilStarted()

        store.cancelOneClickAppUpdates()
        for _ in 0..<20 {
            await Task.yield()
        }

        let ownerWhileCleanupPending = await coordinator.activeOwner
        XCTAssertEqual(ownerWhileCleanupPending, .appUpdates)

        await updateGate.open()
        await waitUntil { !store.isRunningOneClickUpdate }
        for _ in 0..<2_000 {
            if await coordinator.activeOwner == nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        let ownerAfterCleanup = await coordinator.activeOwner
        XCTAssertNil(ownerAfterCleanup)
        XCTAssertNil(store.oneClickUpdateResult)
        XCTAssertNotEqual(store.appUpdates.first?.updateStatus, .completed)
        var cancelledBatchScanCount = await inventoryScanner.scanCount
        XCTAssertEqual(cancelledBatchScanCount, 0)
        for _ in 0..<20 { await Task.yield() }
        cancelledBatchScanCount = await inventoryScanner.scanCount
        XCTAssertEqual(cancelledBatchScanCount, 0)
    }

    @MainActor
    func testCancellationWhileInitialSnapshotSaveIsBlockedNeverStartsExecutorOrRescans() async throws {
        let application = makeHomebrewUpdate()
        let repository = GatedStartApplicationUpdateQueueRepository()
        let executor = RecordingApplicationUpdateExecutor()
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let inventoryScanner = CountingApplicationInventoryScanner(applications: [application])
        let store = ScanStore(
            applicationInventoryScanner: inventoryScanner,
            applicationUpdateCoordinator: coordinator
        )
        store.appUpdates = [application]

        store.previewOneClickAppUpdates()
        store.confirmOneClickAppUpdates()
        await repository.waitUntilInitialSaveStarted()
        store.cancelOneClickAppUpdates()
        await repository.releaseInitialSave()
        await waitUntil { !store.isRunningOneClickUpdate }

        let executionCount = await executor.executionCount
        let scanCount = await inventoryScanner.scanCount
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(scanCount, 0)
        XCTAssertNil(store.oneClickUpdateResult)
        XCTAssertNotEqual(store.appUpdates.first?.updateStatus, .completed)
        let persisted = await repository.load()
        XCTAssertTrue(persisted == nil || persisted?.tasks.allSatisfy { $0.state == .cancelled } == true)
    }

    @MainActor
    func testCancellationPersistenceFailureIsShownInsteadOfCancellationSuccess() async throws {
        let application = makeHomebrewUpdate()
        let repository = RuntimeFailingApplicationUpdateQueueRepository()
        let executor = CancellableApplicationUpdateExecutor()
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let inventoryScanner = CountingApplicationInventoryScanner(applications: [application])
        let store = ScanStore(
            applicationInventoryScanner: inventoryScanner,
            applicationUpdateCoordinator: coordinator
        )
        store.appUpdates = [application]

        store.previewOneClickAppUpdates()
        store.confirmOneClickAppUpdates()
        await executor.waitUntilStarted()
        await repository.configure(failSave: true, failClear: true)
        store.cancelOneClickAppUpdates()
        await waitUntil { !store.isRunningOneClickUpdate }

        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.actionMessage?.contains("已取消") == true)
        XCTAssertNil(store.oneClickUpdateResult)
        let scanCount = await inventoryScanner.scanCount
        XCTAssertEqual(scanCount, 0)
    }

    @MainActor
    func testExhaustedAppUpdateCleanupKeepsCoordinatorQuarantinedUntilVerifiedExit() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activityStore = HeavyWorkActivityStore(coordinator: coordinator)
        let scheduler = HeavyWorkManualCleanupScheduler()
        let lifecycle = HeavyWorkCleanupLifecycle(presence: .unknown)
        let reaper = ShellProcessCleanupReaper(
            retryDelay: 0,
            maximumRetryCount: 1,
            schedule: { _, operation in scheduler.schedule(operation.run) }
        )
        reaper.retain(lifecycle)
        scheduler.runNext()
        XCTAssertTrue(reaper.hasExhaustedCleanup)
        XCTAssertTrue(reaper.hasPendingCleanup)

        let service = ScanHeavyWorkService(
            coordinator: coordinator,
            operations: .init(
                runHomebrewUpgrade: { _ in
                    throw ScanHeavyWorkCleanupPendingError(reaper: reaper)
                }
            ),
            onCleanupQuarantineCleared: {
                await activityStore.refresh()
            }
        )
        let plan = AppUpdateService.oneClickPlan(for: [makeHomebrewUpdate()])
        let lease = try await coordinator.acquire(owner: .appUpdates)
        do {
            _ = try await service.runAppUpdates(plan: plan, lease: lease)
            XCTFail("Expected cleanup quarantine")
        } catch is ScanHeavyWorkCleanupPendingError {
            // The cleanup reaper now owns the quarantine until process exit is verified.
        }
        await coordinator.release(lease)
        await activityStore.refresh()

        let ownerAfterLeaseExit = await coordinator.activeOwner
        XCTAssertEqual(ownerAfterLeaseExit, .appUpdates)
        XCTAssertEqual(activityStore.activeOwner, .appUpdates)
        do {
            _ = try await coordinator.acquire(owner: .benchmark)
            XCTFail("Expected quarantine to block the benchmark")
        } catch let error as HeavyWorkCoordinator.Error {
            XCTAssertEqual(error, .busy(activeOwner: .appUpdates))
        }

        lifecycle.setPresence(.exited)
        scheduler.runNext()
        for _ in 0..<1_000 {
            if await coordinator.activeOwner == nil,
               activityStore.activeOwner == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        let ownerAfterVerifiedExit = await coordinator.activeOwner
        XCTAssertNil(ownerAfterVerifiedExit)
        XCTAssertNil(activityStore.activeOwner)
        XCTAssertNil(activityStore.conflictMessage)
        XCTAssertNil(activityStore.navigationDestination)
        let benchmarkLease = try await coordinator.acquire(owner: .benchmark)
        await coordinator.release(benchmarkLease)
    }

    @MainActor
    func testActivityStoreMapsOwnerToOneConflictAndNavigationDestination() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activityStore = HeavyWorkActivityStore(coordinator: coordinator)
        let lease = try await coordinator.acquire(owner: .networkTest)

        await activityStore.refresh()

        XCTAssertEqual(activityStore.activeOwner, .networkTest)
        XCTAssertNotNil(activityStore.conflictMessage)
        XCTAssertEqual(activityStore.navigationDestination, .networkTest)
        XCTAssertEqual(
            HeavyWorkActivityStore.navigationDestination(for: .benchmark),
            .review(.performance)
        )

        await coordinator.release(lease)
        await activityStore.refresh()
        XCTAssertNil(activityStore.activeOwner)
        XCTAssertNil(activityStore.conflictMessage)
        XCTAssertNil(activityStore.navigationDestination)
    }

    @MainActor
    private func waitUntil(
        maximumYields: Int = 2_000,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<maximumYields {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for store state")
    }

    @MainActor
    private func waitUntilAsync(
        maximumYields: Int = 2_000,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<maximumYields {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous store state")
    }
}

private actor InvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class HeavyWorkManualCleanupScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations = [@Sendable () -> Void]()

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    func runNext() {
        let operation = lock.withLock {
            operations.isEmpty ? nil : operations.removeFirst()
        }
        operation?()
    }
}

private final class HeavyWorkCleanupLifecycle: ShellProcessCleanupLifecycle, @unchecked Sendable {
    let cleanupID = UUID()
    private let lock = NSLock()
    private var presence: ShellProcessPresence
    private var isRetained = false

    init(presence: ShellProcessPresence) {
        self.presence = presence
    }

    func setPresence(_ presence: ShellProcessPresence) {
        lock.withLock { self.presence = presence }
    }

    func activateRetention() -> Bool {
        lock.withLock {
            isRetained = true
            return true
        }
    }

    func cleanupPresence() -> ShellProcessPresence {
        lock.withLock { presence }
    }

    func retryVerifiedTermination() {}

    func releaseRetention() {
        lock.withLock { isRetained = false }
    }
}

private actor AsyncValueGate<Value: Sendable> {
    private let value: Value
    private var started = false
    private var isOpen = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var valueWaiters = [CheckedContinuation<Value, Never>]()

    init(value: Value) {
        self.value = value
    }

    func wait() async -> Value {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if isOpen { return value }
        return await withCheckedContinuation { continuation in
            valueWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = valueWaiters
        valueWaiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }
    }
}

private actor HeavyWorkMemoryApplicationUpdateQueueRepository: ApplicationUpdateQueuePersisting {
    private var snapshot: ApplicationUpdateQueueSnapshot?

    func load() -> ApplicationUpdateQueueSnapshot? {
        snapshot
    }

    func save(_ snapshot: ApplicationUpdateQueueSnapshot) {
        self.snapshot = snapshot
    }

    func clear() {
        snapshot = nil
    }
}

private actor GatedStartApplicationUpdateQueueRepository: ApplicationUpdateQueuePersisting {
    private let initialSaveGate = AsyncValueGate(value: ())
    private var shouldGateInitialSave = true
    private var snapshot: ApplicationUpdateQueueSnapshot?

    func waitUntilInitialSaveStarted() async {
        await initialSaveGate.waitUntilStarted()
    }

    func releaseInitialSave() async {
        await initialSaveGate.open()
    }

    func load() -> ApplicationUpdateQueueSnapshot? {
        snapshot
    }

    func save(_ snapshot: ApplicationUpdateQueueSnapshot) async {
        if shouldGateInitialSave {
            shouldGateInitialSave = false
            await initialSaveGate.wait()
        }
        self.snapshot = snapshot
    }

    func clear() {
        snapshot = nil
    }
}

private enum RuntimeFailingApplicationUpdateQueueRepositoryError: Error {
    case saveFailed
    case clearFailed
}

private actor RuntimeFailingApplicationUpdateQueueRepository: ApplicationUpdateQueuePersisting {
    private var snapshot: ApplicationUpdateQueueSnapshot?
    private var failSave = false
    private var failClear = false

    func configure(failSave: Bool, failClear: Bool) {
        self.failSave = failSave
        self.failClear = failClear
    }

    func load() -> ApplicationUpdateQueueSnapshot? {
        snapshot
    }

    func save(_ snapshot: ApplicationUpdateQueueSnapshot) throws {
        guard !failSave else {
            throw RuntimeFailingApplicationUpdateQueueRepositoryError.saveFailed
        }
        self.snapshot = snapshot
    }

    func clear() throws {
        guard !failClear else {
            throw RuntimeFailingApplicationUpdateQueueRepositoryError.clearFailed
        }
        snapshot = nil
    }
}

private actor RecordingApplicationUpdateExecutor: ApplicationUpdateExecuting {
    private(set) var executionCount = 0

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        executionCount += 1
        throw CancellationError()
    }

    func cancel(applicationID: String) async {}

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        throw CancellationError()
    }
}

private actor ExecutionTimeWaitThenSuccessExecutor: ApplicationUpdateExecuting {
    private(set) var executionCount = 0

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        executionCount += 1
        if executionCount == 1 {
            return ApplicationUpdateInstallResult(
                applicationID: application.id,
                state: .waitingForQuit,
                observedVersion: nil,
                detail: "started after click-time scan"
            )
        }
        return ApplicationUpdateInstallResult(
            applicationID: application.id,
            state: .completed,
            observedVersion: task.targetVersion,
            detail: "verified"
        )
    }

    func cancel(applicationID: String) async {}

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        throw CancellationError()
    }
}

private actor CancellableApplicationUpdateExecutor: ApplicationUpdateExecuting {
    private var started = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func cancel(applicationID: String) async {}

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        throw CancellationError()
    }
}

private actor HeavyWorkGatedApplicationUpdateExecutor: ApplicationUpdateExecuting {
    private let coordinator: HeavyWorkCoordinator
    private let gate: AsyncValueGate<ApplicationUpdateInstallResult>

    init(
        coordinator: HeavyWorkCoordinator,
        gate: AsyncValueGate<ApplicationUpdateInstallResult>
    ) {
        self.coordinator = coordinator
        self.gate = gate
    }

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        try await coordinator.withLease(owner: .appUpdates) { _ in
            await progress(ApplicationUpdateProgressEvent(
                applicationID: application.id,
                state: .installing,
                fraction: 0.5,
                detail: "fixture installing"
            ))
            let result = await gate.wait()
            try Task.checkCancellation()
            return result
        }
    }

    func cancel(applicationID: String) async {
        // The coordinator cancels the worker task. The gate deliberately remains
        // closed until the test verifies that physical cleanup still owns the lease.
    }

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        throw CancellationError()
    }
}

private actor CountingApplicationInventoryScanner: ApplicationInventoryScanning {
    private let applications: [InstalledApplication]
    private(set) var scanCount = 0

    init(applications: [InstalledApplication]) {
        self.applications = applications
    }

    func scan(
        configuration: ApplicationScanConfiguration,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication] {
        scanCount += 1
        try Task.checkCancellation()
        await onApplications(applications)
        await onProgress(ApplicationScanProgress(
            stage: .completed,
            scannedCount: applications.count,
            discoveredCount: applications.count
        ))
        return applications
    }
}

private enum MixedResultApplicationUpdateError: Error {
    case expectedFailure(String)
}

private actor MixedResultApplicationUpdateExecutor: ApplicationUpdateExecuting {
    private let failureIDs: Set<String>
    private let gatedResults: [String: AsyncValueGate<ApplicationUpdateInstallResult>]
    private var executed: [String] = []

    init(
        failureIDs: Set<String>,
        gatedResults: [String: AsyncValueGate<ApplicationUpdateInstallResult>]
    ) {
        self.failureIDs = failureIDs
        self.gatedResults = gatedResults
    }

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        executed.append(application.id)
        await progress(ApplicationUpdateProgressEvent(
            applicationID: application.id,
            state: .installing,
            fraction: 0.5,
            detail: "fixture installing"
        ))
        if failureIDs.contains(application.id) {
            throw MixedResultApplicationUpdateError.expectedFailure(application.id)
        }
        guard let gate = gatedResults[application.id] else {
            throw MixedResultApplicationUpdateError.expectedFailure("missing-result-\(application.id)")
        }
        return await gate.wait()
    }

    func cancel(applicationID: String) async {}

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        throw CancellationError()
    }

    func executionOrder() -> [String] { executed }
}

private func makeStorageItem(id: String = "single") -> StorageItem {
    StorageItem(
        id: id,
        title: "Build Cache",
        path: "/tmp/heavy-work-test",
        sourceID: "caches",
        groupTitle: "Caches",
        sizeBytes: 42,
        tier: .green,
        kind: "cache",
        reason: "test",
        recommendation: "test",
        risk: "low",
        requiresClose: "",
        trashPaths: ["/tmp/heavy-work-test"],
        openPath: "/tmp",
        status: .available
    )
}

private func makeScanResult(items: [StorageItem] = []) -> ScanResult {
    ScanResult(
        generatedAt: Date(),
        scanSeconds: 0.01,
        system: SystemSnapshot(
            osName: "macOS",
            build: "test",
            arch: "arm64",
            user: "tester",
            home: "/tmp",
            filesystem: "APFS",
            purgeable: "",
            diskName: "Macintosh HD",
            diskTotalBytes: 1_000,
            diskUsedBytes: 500,
            diskFreeBytes: 500
        ),
        groups: [],
        items: items,
        deniedPaths: []
    )
}

private func makeMemoryOptimizationResult() -> MemoryOptimizationResult {
    let snapshot = MemorySnapshot(
        generatedAt: Date(),
        physicalBytes: 16_000,
        freeBytes: 8_000,
        inactiveBytes: 0,
        speculativeBytes: 0,
        fileBackedBytes: 0,
        purgeableBytes: 0,
        wiredBytes: 1_000,
        compressedBytes: 0,
        swapUsedBytes: 0,
        pressureFreePercentage: 80,
        pressureSummary: "Normal",
        topProcesses: []
    )
    return MemoryOptimizationResult(
        beforeSnapshot: snapshot,
        snapshot: snapshot,
        status: .notNeeded,
        detail: "No change",
        durationSeconds: 0.01
    )
}

private func makeHomebrewUpdate() -> AppUpdateItem {
    AppUpdateTestFixtures.strictHomebrewApplication(
        id: "/Applications/Example.app",
        token: "example",
        path: "/Applications/Example.app"
    )
}

private func makeCleanupHistoryEntry(record: TrashMoveRecord) -> CleanupHistoryEntry {
    CleanupHistoryEntry(
        id: UUID(),
        date: Date(),
        title: "Safe Cleanup",
        itemCount: 1,
        totalBytes: 42,
        paths: [record.originalPath],
        moveRecords: [record]
    )
}
