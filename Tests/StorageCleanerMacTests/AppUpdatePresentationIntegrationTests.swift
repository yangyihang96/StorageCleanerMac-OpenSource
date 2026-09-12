import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdatePresentationIntegrationTests: XCTestCase {
    @MainActor
    func testScanLifecyclePublishesRealTotalsThenPreservesSummaryAcrossManagerNavigation() async throws {
        let applications = [
            AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic"),
            AppUpdateTestFixtures.application(
                id: "current",
                provider: .manual,
                status: .upToDate
            ),
        ]
        let scanner = PhasedApplicationInventoryScanner(applications: applications)
        let store = makeStore(scanner: scanner)

        XCTAssertEqual(store.appUpdatePresentationState.phase, .idle)
        store.refreshAppUpdates()

        guard case let .scanning(initial) = store.appUpdatePresentationState else {
            return XCTFail("Refresh must synchronously enter scanning")
        }
        XCTAssertNil(initial.totalUnitCount)
        XCTAssertNil(initial.progressFraction)

        await waitUntil("scanner start") { await scanner.hasStarted }
        await scanner.advance()
        await waitUntil("source-resolution progress") {
            guard case let .scanning(progress) = store.appUpdatePresentationState else {
                return false
            }
            return progress.stage == .resolvingSources
                && progress.totalUnitCount == applications.count
        }

        guard case let .scanning(resolving) = store.appUpdatePresentationState else {
            return XCTFail("Expected resolving-sources progress")
        }
        XCTAssertEqual(resolving.completedUnitCount, 1)
        XCTAssertEqual(resolving.totalUnitCount, applications.count)

        await scanner.advance()
        await waitUntil("scan summary") {
            !store.isLoadingAppUpdates
                && store.appUpdatePresentationState.phase == .scanSummary
        }

        guard case let .scanSummary(summary) = store.appUpdatePresentationState else {
            return XCTFail("Expected scan summary")
        }
        XCTAssertEqual(summary.applications.map(\.id), applications.map(\.id))
        let sessionID = summary.sessionID

        store.showAppUpdateManager()
        guard case let .managing(catalog) = store.appUpdatePresentationState else {
            return XCTFail("Expected catalog manager")
        }
        XCTAssertEqual(catalog.sessionID, sessionID)
        XCTAssertEqual(catalog.entries.map(\.id), ["automatic"])

        store.selectedUtilityFilter = .memory
        await Task.yield()
        XCTAssertEqual(store.appUpdatePresentationState.phase, .managing)
        XCTAssertEqual(store.appUpdates.map(\.id), applications.map(\.id))

        store.selectedUtilityFilter = .updater
        store.showAppUpdateScanSummary()
        guard case let .scanSummary(restoredSummary) = store.appUpdatePresentationState else {
            return XCTFail("Expected the retained scan summary")
        }
        XCTAssertEqual(restoredSummary.sessionID, sessionID)
        XCTAssertEqual(restoredSummary.applications.map(\.id), applications.map(\.id))
    }

    @MainActor
    func testUserUpdateRequestsStayPendingUntilConfirmationAndSeparateManualActions() throws {
        let automatic = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")
        let appStore = AppUpdateTestFixtures.application(
            id: "app-store",
            availableVersion: "2.0",
            provider: .macAppStore,
            status: .updateAvailable
        )
        let manual = AppUpdateTestFixtures.application(
            id: "manual",
            availableVersion: "2.0",
            provider: .manual,
            status: .updateAvailable
        )
        let system = AppUpdateTestFixtures.application(
            id: "system",
            path: "/System/Applications/System Settings.app",
            availableVersion: "2.0",
            provider: .systemManaged,
            status: .systemManaged,
            isSystem: true
        )
        let store = makeStore(scanner: ImmediateApplicationInventoryScanner(applications: []))
        store.appUpdates = [automatic, appStore, manual, system]

        store.requestOneClickAppUpdates()

        let plan = try XCTUnwrap(store.pendingOneClickUpdatePlan)
        XCTAssertEqual(plan.automaticCount, 1)
        XCTAssertEqual(plan.automaticApps.map(\.id), [automatic.id])
        XCTAssertEqual(plan.appStoreApps.map(\.id), [appStore.id])
        XCTAssertEqual(plan.manualApps.map(\.id), [manual.id])
        XCTAssertFalse(store.isRunningOneClickUpdate)
        XCTAssertFalse(plan.automaticApps.contains { [appStore.id, manual.id, system.id].contains($0.id) })
        XCTAssertFalse(
            (plan.appStoreApps + plan.automaticApps + plan.sparkleApps + plan.manualApps)
                .contains { $0.id == system.id }
        )

        store.cancelOneClickAppUpdates()
        store.requestSelectedAppUpdates(applicationIDs: [automatic.id])
        XCTAssertEqual(try XCTUnwrap(store.pendingOneClickUpdatePlan).automaticApps.map(\.id), [automatic.id])
        XCTAssertFalse(store.isRunningOneClickUpdate)

        store.cancelOneClickAppUpdates()
        store.requestAppUpdate(automatic)
        XCTAssertEqual(try XCTUnwrap(store.pendingOneClickUpdatePlan).automaticApps.map(\.id), [automatic.id])
        XCTAssertFalse(store.isRunningOneClickUpdate)
    }

    @MainActor
    func testOneConfirmationExecutesEligibleItemOnceAndKeepsUnsupportedItemsVisible() async throws {
        let automatic = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")
        let authorization = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "authorization",
            token: "authorization",
            path: "/Applications/Authorization.app",
            requiresAuthorization: true
        )
        let appStore = AppUpdateTestFixtures.application(
            id: "app-store",
            availableVersion: "2.0",
            provider: .macAppStore,
            status: .updateAvailable
        )
        let sparkle = AppUpdateTestFixtures.application(
            id: "sparkle",
            availableVersion: "2.0",
            provider: .sparkle,
            status: .applicationUpdateRequired
        )
        let manual = AppUpdateTestFixtures.application(
            id: "manual",
            availableVersion: "2.0",
            provider: .manual,
            status: .updateAvailable
        )
        let applications = [automatic, authorization, appStore, sparkle, manual]
        let executor = ImmediateSuccessfulApplicationUpdateExecutor()
        let store = ScanStore(
            applicationInventoryScanner: ImmediateApplicationInventoryScanner(
                applications: applications
            ),
            applicationUpdateCoordinator: ApplicationUpdateCoordinator(
                repository: InMemoryApplicationUpdateQueueRepository(),
                executor: executor
            )
        )
        store.appUpdates = applications

        store.requestOneClickAppUpdates()
        let pending = try XCTUnwrap(store.pendingOneClickUpdatePlan)
        XCTAssertEqual(pending.automaticApps.map(\.id), [automatic.id])
        XCTAssertEqual(pending.authorizationApps.map(\.id), [authorization.id])
        XCTAssertEqual(pending.appStoreApps.map(\.id), [appStore.id])
        XCTAssertEqual(pending.sparkleApps.map(\.id), [sparkle.id])
        XCTAssertEqual(pending.manualApps.map(\.id), [manual.id])

        store.confirmOneClickAppUpdates()
        await waitUntil("truthful mixed-provider batch") {
            store.appUpdatePresentationState.phase == .completed
                && !store.isRunningOneClickUpdate
        }

        guard case let .completed(report) = store.appUpdatePresentationState else {
            return XCTFail("The verified automatic item should complete the mixed plan")
        }
        let reportItems = Dictionary(
            uniqueKeysWithValues: report.items.map { ($0.applicationID, $0) }
        )
        XCTAssertEqual(reportItems[automatic.id]?.state, .completed)
        for application in [authorization, appStore, sparkle, manual] {
            XCTAssertEqual(reportItems[application.id]?.state, .skipped)
            XCTAssertEqual(reportItems[application.id]?.detail, application.updateHandlingDetail)
        }
        let executionCount = await executor.count()
        XCTAssertEqual(executionCount, 1)
    }

    @MainActor
    func testSelectedRunningAutomaticSurvivesStoreGateWhileAuthorizationIsRejected() throws {
        let running = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "running",
            token: "running",
            path: "/Applications/Running.app",
            isRunning: true
        )
        let authorization = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "authorization",
            token: "authorization",
            path: "/Applications/Authorization.app",
            requiresAuthorization: true
        )
        let store = makeStore(scanner: ImmediateApplicationInventoryScanner(applications: []))
        store.appUpdates = [running, authorization]

        store.requestSelectedAppUpdates(applicationIDs: [running.id, authorization.id])

        let pending = try XCTUnwrap(store.pendingOneClickUpdatePlan)
        XCTAssertEqual(pending.automaticApps.map(\.id), [running.id])
        let frozen = FrozenUpdatePlan(applications: pending.automaticApps)
        XCTAssertTrue(frozen.plan.automaticApplicationIDs.isEmpty)
        XCTAssertEqual(frozen.plan.requiresQuitApplicationIDs, [running.id])
        XCTAssertTrue(frozen.plan.requiresAuthorizationApplicationIDs.isEmpty)

        store.cancelOneClickAppUpdates()
        store.requestSelectedAppUpdates(applicationIDs: [authorization.id])
        XCTAssertNil(store.pendingOneClickUpdatePlan)
        XCTAssertFalse(store.isRunningOneClickUpdate)

        store.requestAppUpdate(running)
        XCTAssertEqual(
            try XCTUnwrap(store.pendingOneClickUpdatePlan).automaticApps.map(\.id),
            [running.id]
        )
        store.cancelOneClickAppUpdates()
        store.requestAppUpdate(authorization)
        XCTAssertNil(store.pendingOneClickUpdatePlan)
    }

    @MainActor
    func testRestoredActiveQueueMapsToUpdatingPresentation() async {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "waiting-for-quit",
            isRunning: true
        )
        let sessionID = UUID()
        let plan = ApplicationUpdatePlan(
            id: sessionID,
            automaticApplicationIDs: [],
            requiresQuitApplicationIDs: [application.id],
            requiresAuthorizationApplicationIDs: [],
            appStoreApplicationIDs: [],
            websiteApplicationIDs: [],
            manualApplicationIDs: [],
            skippedApplicationIDs: []
        )
        let task = ApplicationUpdateTask(
            sessionID: sessionID,
            application: application,
            state: .waitingForQuit
        )
        let queue = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: plan,
            tasks: [task],
            isPaused: false,
            updatedAt: Date()
        )
        let repository = InMemoryApplicationUpdateQueueRepository(snapshot: queue)
        let coordinator = ApplicationUpdateCoordinator(
            repository: repository,
            executor: UnsupportedApplicationUpdateExecutor()
        )
        let store = ScanStore(
            applicationInventoryScanner: ImmediateApplicationInventoryScanner(
                applications: [application]
            ),
            applicationUpdateCoordinator: coordinator
        )

        store.refreshAppUpdates()
        await waitUntil("restored update queue") {
            !store.isLoadingAppUpdates
                && store.appUpdatePresentationState.phase == .updating
        }

        guard case let .updating(snapshot) = store.appUpdatePresentationState else {
            return XCTFail("An active restored queue must own the presentation")
        }
        XCTAssertEqual(snapshot.sessionID, sessionID)
        XCTAssertEqual(snapshot.items.map(\.applicationID), [application.id])
        XCTAssertEqual(snapshot.items.first?.task.state, .waitingForQuit)
    }

    @MainActor
    func testFastAutoResumedQueueDrainIsBufferedBeforeRestoreMonitorStarts() async {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "fast-restore")
        let sessionID = UUID()
        let plan = ApplicationUpdatePlan(
            id: sessionID,
            automaticApplicationIDs: [application.id],
            requiresQuitApplicationIDs: [],
            requiresAuthorizationApplicationIDs: [],
            appStoreApplicationIDs: [],
            websiteApplicationIDs: [],
            manualApplicationIDs: [],
            skippedApplicationIDs: []
        )
        let queue = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: plan,
            tasks: [
                ApplicationUpdateTask(
                    sessionID: sessionID,
                    application: application,
                    state: .queued
                )
            ],
            isPaused: false,
            updatedAt: Date()
        )
        let scanner = CountingApplicationInventoryScanner(applications: [application])
        let coordinator = ApplicationUpdateCoordinator(
            repository: InMemoryApplicationUpdateQueueRepository(snapshot: queue),
            executor: ImmediateSuccessfulApplicationUpdateExecutor()
        )
        let store = ScanStore(
            applicationInventoryScanner: scanner,
            applicationUpdateCoordinator: coordinator
        )

        store.refreshAppUpdates()
        await waitUntil("fast restored queue drain") {
            let scanCount = await scanner.count()
            return !store.isRunningOneClickUpdate
                && !store.isLoadingAppUpdates
                && scanCount == 2
                && store.appUpdateQueueSnapshot?.tasks.first?.state == .completed
        }

        let scanCount = await scanner.count()
        XCTAssertEqual(scanCount, 2)
        XCTAssertEqual(store.appUpdateQueueSnapshot?.plan.id, sessionID)
        XCTAssertEqual(store.appUpdateQueueSnapshot?.tasks.first?.state, .completed)
    }

    func testAppStorePresentationUsesPublicEntryAndNeverInvokesMasFromUIOrStore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"
            ),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let service = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/AppUpdateService.swift"
            ),
            encoding: .utf8
        )

        for source in [view, store] {
            XCTAssertFalse(source.contains("masExecutablePath"))
            XCTAssertFalse(source.contains("runAppStoreUpgrade"))
        }

        let entry = try XCTUnwrap(service.range(of: "static func openAppStoreUpdates()"))
        let remainder = service[entry.lowerBound...]
        let end = remainder.dropFirst().range(of: "\n    static func ")?.lowerBound
            ?? remainder.endIndex
        let publicEntryFunction = String(remainder[..<end])
        XCTAssertTrue(publicEntryFunction.contains("macappstore://showUpdatesPage"))
        XCTAssertFalse(publicEntryFunction.contains("masExecutablePath"))
        XCTAssertFalse(publicEntryFunction.contains("runAppStoreUpgrade"))
    }

    func testHomebrewCommandIsAnAdvancedFallbackBehindOneClickUpdate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("一键更新全部 · \\(summary.batchEligibleApps.count) 个"))
        XCTAssertFalse(view.contains("安全更新 · \\(summary.batchEligibleApps.count) 个"))
        XCTAssertTrue(view.contains("advancedHomebrewDetails"))
        XCTAssertTrue(view.contains("高级详情与备用命令"))
        XCTAssertTrue(view.contains("复制命令（备用）"))
        XCTAssertTrue(view.contains("不会执行此显示文本"))
        XCTAssertFalse(view.contains("title: manualActionTitle"))
    }

    @MainActor
    func testTerminalRestoredQueueDoesNotDoubleFinalizeNextForegroundBatch() async {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")
        let oldSessionID = UUID()
        let oldPlan = ApplicationUpdatePlan(
            id: oldSessionID,
            automaticApplicationIDs: [application.id],
            requiresQuitApplicationIDs: [],
            requiresAuthorizationApplicationIDs: [],
            appStoreApplicationIDs: [],
            websiteApplicationIDs: [],
            manualApplicationIDs: [],
            skippedApplicationIDs: []
        )
        let oldQueue = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: oldPlan,
            tasks: [
                ApplicationUpdateTask(
                    sessionID: oldSessionID,
                    application: application,
                    state: .completed
                )
            ],
            isPaused: false,
            updatedAt: Date()
        )
        let scanner = CountingApplicationInventoryScanner(applications: [application])
        let executor = ImmediateSuccessfulApplicationUpdateExecutor()
        let coordinator = ApplicationUpdateCoordinator(
            repository: InMemoryApplicationUpdateQueueRepository(snapshot: oldQueue),
            executor: executor
        )
        let store = ScanStore(
            applicationInventoryScanner: scanner,
            applicationUpdateCoordinator: coordinator
        )

        store.refreshAppUpdates()
        await waitUntil("initial scan and terminal restore") {
            let scanCount = await scanner.count()
            return !store.isLoadingAppUpdates && scanCount == 1
        }

        store.requestSelectedAppUpdates(applicationIDs: [application.id])
        XCTAssertNotNil(store.pendingOneClickUpdatePlan)
        XCTAssertFalse(store.isRunningOneClickUpdate)
        store.confirmOneClickAppUpdates()
        await waitUntil("single post-update rescan") {
            let scanCount = await scanner.count()
            return !store.isRunningOneClickUpdate
                && !store.isLoadingAppUpdates
                && scanCount == 2
        }
        try? await Task.sleep(for: .milliseconds(150))

        let finalScanCount = await scanner.count()
        let executionCount = await executor.count()
        XCTAssertEqual(finalScanCount, 2)
        XCTAssertEqual(executionCount, 1)
    }

    @MainActor
    func testAllFailedBatchEntersFailedAndRetryKeepsSameSession() async throws {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "retryable")
        let scanner = CountingApplicationInventoryScanner(applications: [application])
        let executor = FailThenSucceedApplicationUpdateExecutor()
        let coordinator = ApplicationUpdateCoordinator(
            repository: InMemoryApplicationUpdateQueueRepository(),
            executor: executor
        )
        let store = ScanStore(
            applicationInventoryScanner: scanner,
            applicationUpdateCoordinator: coordinator
        )

        store.refreshAppUpdates()
        await waitUntil("initial retry scan") {
            let scanCount = await scanner.count()
            return !store.isLoadingAppUpdates && scanCount == 1
        }
        store.requestSelectedAppUpdates(applicationIDs: [application.id])
        XCTAssertNotNil(store.pendingOneClickUpdatePlan)
        XCTAssertFalse(store.isRunningOneClickUpdate)
        store.confirmOneClickAppUpdates()
        await waitUntil("failed presentation after recheck") {
            let scanCount = await scanner.count()
            return store.appUpdatePresentationState.phase == .failed
                && !store.isLoadingAppUpdates
                && scanCount == 2
        }

        guard case let .failed(firstReport) = store.appUpdatePresentationState else {
            return XCTFail("All failed tasks must own the failed presentation")
        }
        XCTAssertEqual(firstReport.items.first?.attemptCount, 1)
        let sessionID = firstReport.sessionID

        store.retryAppUpdates(applicationIDs: [application.id])
        await waitUntil("same-session retry completion") {
            let scanCount = await scanner.count()
            return store.appUpdatePresentationState.phase == .completed
                && !store.isLoadingAppUpdates
                && scanCount == 3
        }

        guard case let .completed(retriedReport) = store.appUpdatePresentationState else {
            return XCTFail("Successful retry must produce a completed report")
        }
        XCTAssertEqual(retriedReport.sessionID, sessionID)
        XCTAssertEqual(retriedReport.items.first?.attemptCount, 2)
        let executionCount = await executor.count()
        XCTAssertEqual(executionCount, 2)
    }

    @MainActor
    func testCancellationRequestIsVisibleBeforeQueueStops() async {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "cancellable")
        let executor = BlockingApplicationUpdateExecutor()
        let store = ScanStore(
            applicationInventoryScanner: ImmediateApplicationInventoryScanner(
                applications: [application]
            ),
            applicationUpdateCoordinator: ApplicationUpdateCoordinator(
                repository: InMemoryApplicationUpdateQueueRepository(),
                executor: executor
            )
        )

        store.refreshAppUpdates()
        await waitUntil("cancellation scan") { !store.isLoadingAppUpdates }
        store.requestSelectedAppUpdates(applicationIDs: [application.id])
        XCTAssertNotNil(store.pendingOneClickUpdatePlan)
        XCTAssertFalse(store.isRunningOneClickUpdate)
        store.confirmOneClickAppUpdates()
        await waitUntil("provider starts") {
            await executor.hasStarted
                && store.appUpdatePresentationState.phase == .updating
        }

        store.cancelOneClickAppUpdates()
        guard case let .updating(snapshot) = store.appUpdatePresentationState else {
            return XCTFail("Cancellation must first remain on the updating page")
        }
        XCTAssertTrue(snapshot.isCancellationRequested)

        await waitUntil("cancelled report") {
            store.appUpdatePresentationState.phase == .cancelled
        }
    }

    @MainActor
    func testDismissingConfirmedPreviewDoesNotCancelRunningBatch() async {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "preview-dismiss")
        let executor = BlockingApplicationUpdateExecutor()
        let store = ScanStore(
            applicationInventoryScanner: ImmediateApplicationInventoryScanner(
                applications: [application]
            ),
            applicationUpdateCoordinator: ApplicationUpdateCoordinator(
                repository: InMemoryApplicationUpdateQueueRepository(),
                executor: executor
            )
        )

        store.refreshAppUpdates()
        await waitUntil("preview-dismiss scan") { !store.isLoadingAppUpdates }
        store.requestSelectedAppUpdates(applicationIDs: [application.id])
        store.confirmOneClickAppUpdates()
        await waitUntil("preview-dismiss provider starts") {
            await executor.hasStarted
                && store.appUpdatePresentationState.phase == .updating
        }

        store.dismissOneClickUpdatePreview()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(store.isRunningOneClickUpdate)
        guard case let .updating(snapshot) = store.appUpdatePresentationState else {
            store.cancelOneClickAppUpdates()
            return XCTFail("Dismissing the confirmed preview must keep the update running")
        }
        XCTAssertFalse(snapshot.isCancellationRequested)

        store.cancelOneClickAppUpdates()
        await waitUntil("preview-dismiss cleanup") {
            store.appUpdatePresentationState.phase == .cancelled
        }
    }

    func testManagerUsesConfirmedCatalogAndLogDoesNotFakeUnknownTotals() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Models/AppUpdatePresentationModels.swift"
            ),
            encoding: .utf8
        )
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(model.contains("guard $0.hasConfirmedPresentableUpdate"))
        XCTAssertFalse(source.contains(".filter { $0.category != .systemManaged }"))
        XCTAssertTrue(source.contains("knownSizes.count == entries.count"))
        XCTAssertTrue(source.contains("已知至少"))
    }

    @MainActor
    private func makeStore(
        scanner: some ApplicationInventoryScanning
    ) -> ScanStore {
        ScanStore(
            applicationInventoryScanner: scanner,
            applicationUpdateCoordinator: ApplicationUpdateCoordinator(
                repository: InMemoryApplicationUpdateQueueRepository(),
                executor: UnsupportedApplicationUpdateExecutor()
            )
        )
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private actor PhasedApplicationInventoryScanner: ApplicationInventoryScanning {
    private let applications: [InstalledApplication]
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var hasStarted = false

    init(applications: [InstalledApplication]) {
        self.applications = applications
    }

    func scan(
        configuration: ApplicationScanConfiguration,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication] {
        hasStarted = true
        await onProgress(ApplicationScanProgress(
            stage: .scanningStandardDirectories,
            scannedCount: 0,
            discoveredCount: applications.count
        ))
        await waitForAdvance()
        try Task.checkCancellation()

        await onApplications(applications)
        await onProgress(ApplicationScanProgress(
            stage: .identifyingSources,
            scannedCount: 1,
            discoveredCount: applications.count
        ))
        await waitForAdvance()
        try Task.checkCancellation()

        await onProgress(ApplicationScanProgress(
            stage: .completed,
            scannedCount: applications.count,
            discoveredCount: applications.count
        ))
        return applications
    }

    func advance() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            permits += 1
        }
    }

    private func waitForAdvance() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct ImmediateApplicationInventoryScanner: ApplicationInventoryScanning {
    let applications: [InstalledApplication]

    func scan(
        configuration: ApplicationScanConfiguration,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication] {
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

private actor InMemoryApplicationUpdateQueueRepository: ApplicationUpdateQueuePersisting {
    private var snapshot: ApplicationUpdateQueueSnapshot?

    init(snapshot: ApplicationUpdateQueueSnapshot? = nil) {
        self.snapshot = snapshot
    }

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

private actor CountingApplicationInventoryScanner: ApplicationInventoryScanning {
    private let applications: [InstalledApplication]
    private var scanCount = 0

    init(applications: [InstalledApplication]) {
        self.applications = applications
    }

    func scan(
        configuration: ApplicationScanConfiguration,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication] {
        try Task.checkCancellation()
        scanCount += 1
        await onApplications(applications)
        await onProgress(ApplicationScanProgress(
            stage: .completed,
            scannedCount: applications.count,
            discoveredCount: applications.count
        ))
        return applications
    }

    func count() -> Int { scanCount }
}

private actor ImmediateSuccessfulApplicationUpdateExecutor: ApplicationUpdateExecuting {
    private var executionCount = 0

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        executionCount += 1
        return ApplicationUpdateInstallResult(
            applicationID: application.id,
            state: .completed,
            observedVersion: application.availableVersion,
            detail: "fixture verified"
        )
    }

    func cancel(applicationID: String) async {}

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        ApplicationUpdateInstallResult(
            applicationID: task.applicationID,
            state: .completed,
            observedVersion: application?.availableVersion,
            detail: "fixture reconciled"
        )
    }

    func count() -> Int { executionCount }
}

private actor FailThenSucceedApplicationUpdateExecutor: ApplicationUpdateExecuting {
    private var executionCount = 0

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        executionCount += 1
        if executionCount == 1 {
            throw NSError(
                domain: "AppUpdatePresentationIntegrationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "fixture provider failed"]
            )
        }
        return ApplicationUpdateInstallResult(
            applicationID: application.id,
            state: .completed,
            observedVersion: application.availableVersion,
            detail: "fixture retry verified"
        )
    }

    func cancel(applicationID: String) async {}

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        ApplicationUpdateInstallResult(
            applicationID: task.applicationID,
            state: .completed,
            observedVersion: application?.availableVersion,
            detail: "fixture retry reconciled"
        )
    }

    func count() -> Int { executionCount }
}

private actor BlockingApplicationUpdateExecutor: ApplicationUpdateExecuting {
    private(set) var hasStarted = false

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        hasStarted = true
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
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
