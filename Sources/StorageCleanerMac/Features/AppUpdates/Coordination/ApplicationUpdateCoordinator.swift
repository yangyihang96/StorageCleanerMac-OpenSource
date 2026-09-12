import Foundation

protocol ApplicationUpdateExecuting: Sendable {
    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult

    func cancel(applicationID: String) async

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult

    func stageDownloads(
        applications: [InstalledApplication],
        tasks: [ApplicationUpdateTask],
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async -> ApplicationUpdateStagingReport

    func discardStagedDownloads() async
}

extension ApplicationUpdateExecuting {
    func stageDownloads(
        applications _: [InstalledApplication],
        tasks _: [ApplicationUpdateTask],
        progress _: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async -> ApplicationUpdateStagingReport {
        ApplicationUpdateStagingReport()
    }

    func discardStagedDownloads() async {}
}

enum ApplicationUpdateExecutionError: LocalizedError, Sendable {
    case unsupportedProvider(ApplicationUpdateProviderIdentifier)

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "No automatic update executor is available for \(provider.rawValue)."
        }
    }
}

struct UnsupportedApplicationUpdateExecutor: ApplicationUpdateExecuting {
    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        throw ApplicationUpdateExecutionError.unsupportedProvider(task.providerIdentifier)
    }

    func cancel(applicationID: String) async {}

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        throw ApplicationUpdateExecutionError.unsupportedProvider(task.providerIdentifier)
    }
}

enum ApplicationUpdateCoordinatorError: LocalizedError, Sendable {
    case sessionAlreadyActive
    case noActiveSession
    case unknownApplication(String)
    case duplicatePlanMembership(String)
    case unsafeAutomaticApplication(String)
    case invalidTransition(
        applicationID: String,
        from: ApplicationUpdateTaskState,
        to: ApplicationUpdateTaskState
    )
    case taskCannotBeRetried(String)
    case sessionStillActive
    case cancellationInProgress
    case persistenceFailed(String)
    case cancellationPersistenceFailed(saveError: String, clearError: String)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "An application update session is already active."
        case .noActiveSession:
            return "There is no application update session."
        case let .unknownApplication(id):
            return "The update plan references an unknown application: \(id)"
        case let .duplicatePlanMembership(id):
            return "The application appears in more than one update-plan group: \(id)"
        case let .unsafeAutomaticApplication(id):
            return "The application is not eligible for verified automatic update: \(id)"
        case let .invalidTransition(id, from, to):
            return "Invalid update state transition for \(id): \(from.rawValue) -> \(to.rawValue)"
        case let .taskCannotBeRetried(id):
            return "The application update task cannot be retried: \(id)"
        case .sessionStillActive:
            return "The active application update session cannot be cleared."
        case .cancellationInProgress:
            return "The application update session is still cancelling its active executor."
        case let .persistenceFailed(detail):
            return "The update queue could not persist its next safe state: \(detail)"
        case let .cancellationPersistenceFailed(saveError, clearError):
            return "The update work stopped, but its cancellation could not be persisted (save: \(saveError); clear: \(clearError))."
        }
    }
}

enum ApplicationUpdateCoordinatorEvent: Sendable {
    case restored(ApplicationUpdateQueueSnapshot)
    case started(ApplicationUpdateQueueSnapshot)
    case snapshotChanged(ApplicationUpdateQueueSnapshot)
    case taskChanged(ApplicationUpdateTask)
    case paused(ApplicationUpdateQueueSnapshot)
    case resumed(ApplicationUpdateQueueSnapshot)
    case drained(ApplicationUpdateQueueSnapshot)
    case persistenceFailed(sessionID: UUID?, detail: String)
}

actor ApplicationUpdateCoordinator {
    private let repository: any ApplicationUpdateQueuePersisting
    private let executor: any ApplicationUpdateExecuting
    private let now: @Sendable () -> Date
    private let beforeWorkerSchedule: @Sendable () async -> Void

    private var snapshot: ApplicationUpdateQueueSnapshot?
    private var applicationsByID: [String: InstalledApplication] = [:]
    private var worker: Task<Void, Never>?
    private var currentApplicationID: String?
    private var isCancelling = false
    private var eventContinuations: [UUID: AsyncStream<ApplicationUpdateCoordinatorEvent>.Continuation] = [:]

    init(
        repository: any ApplicationUpdateQueuePersisting,
        executor: any ApplicationUpdateExecuting,
        now: @escaping @Sendable () -> Date = { Date() },
        beforeWorkerSchedule: @escaping @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.executor = executor
        self.now = now
        self.beforeWorkerSchedule = beforeWorkerSchedule
    }

    func events() -> AsyncStream<ApplicationUpdateCoordinatorEvent> {
        events(bufferingPolicy: .bufferingNewest(64))
    }

    func events(
        bufferingPolicy: AsyncStream<ApplicationUpdateCoordinatorEvent>.Continuation.BufferingPolicy
    ) -> AsyncStream<ApplicationUpdateCoordinatorEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeEventContinuation(id) }
            }
        }
    }

    func currentSnapshot() -> ApplicationUpdateQueueSnapshot? {
        snapshot
    }

    @discardableResult
    func refreshApplications(
        _ applications: [InstalledApplication]
    ) async throws -> ApplicationUpdateQueueSnapshot? {
        let refreshed = Self.applicationMap(from: applications)
        guard var current = snapshot else { return nil }

        let timestamp = now()
        var changedTaskIndices = [Int]()
        for index in current.tasks.indices
            where current.tasks[index].state == .waitingForQuit {
            let applicationID = current.tasks[index].applicationID
            let task = current.tasks[index]
            guard let observedApplication = refreshed[applicationID],
                  let clickTimeApplication = applicationsByID[applicationID],
                  let application = Self.runtimeRefreshedApplication(
                    observedApplication,
                    for: task,
                    clickTimeApplication: clickTimeApplication
                  )
            else { continue }
            // Preserve the click-time membership, target and identity for every
            // queued item. Only the exact item that was waiting for a normal
            // quit may receive its freshly observed runtime state.
            applicationsByID[applicationID] = application
            try Self.validateTransition(
                applicationID: applicationID,
                from: .waitingForQuit,
                to: .queued
            )
            current.tasks[index].state = .queued
            current.tasks[index].detail = "The application has quit and the verified update is queued."
            current.tasks[index].updatedAt = timestamp
            changedTaskIndices.append(index)
        }

        guard !changedTaskIndices.isEmpty else { return current }
        current.updatedAt = timestamp
        snapshot = current
        try await repository.save(current)
        for index in changedTaskIndices {
            emit(.taskChanged(current.tasks[index]))
        }
        emit(.snapshotChanged(current))
        scheduleWorkerIfNeeded(sessionID: current.plan.id)
        return current
    }

    private static func runtimeRefreshedApplication(
        _ observed: InstalledApplication,
        for task: ApplicationUpdateTask,
        clickTimeApplication: InstalledApplication
    ) -> InstalledApplication? {
        guard !observed.isRunning,
              observed.identity == task.originalIdentity,
              observed.installedVersion == task.originalVersion,
              observed.availableVersion == task.targetVersion,
              observed.primaryUpdateProvider == task.providerIdentifier,
              clickTimeApplication.identity == task.originalIdentity,
              clickTimeApplication.installedVersion == task.originalVersion,
              clickTimeApplication.availableVersion == task.targetVersion,
              clickTimeApplication.primaryUpdateProvider == task.providerIdentifier
        else { return nil }

        // UI progress maps the item to `waitingForQuit`, which is intentionally
        // not plan-eligible. Keep the immutable click-time update evidence and
        // merge only local runtime facts; the executor re-reads the exact app
        // bundle and signature again immediately before invoking the provider.
        var refreshed = clickTimeApplication
        refreshed.executableURL = observed.executableURL
        refreshed.architectures = observed.architectures
        refreshed.minimumSystemVersion = observed.minimumSystemVersion
        refreshed.isRunning = false
        refreshed.isReadOnly = observed.isReadOnly
        refreshed.requiresApplicationQuit = false
        refreshed.modifiedAt = observed.modifiedAt
        refreshed.lastScanDate = observed.lastScanDate
        guard ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(refreshed) else {
            return nil
        }
        return refreshed
    }

    @discardableResult
    func restore(
        applications: [InstalledApplication],
        autoResume: Bool = false
    ) async throws -> ApplicationUpdateQueueSnapshot? {
        guard worker == nil, !isCancelling else {
            throw ApplicationUpdateCoordinatorError.sessionAlreadyActive
        }
        if let snapshot, hasActiveWork(snapshot) {
            throw ApplicationUpdateCoordinatorError.sessionAlreadyActive
        }
        guard var restored = try await repository.load() else {
            snapshot = nil
            applicationsByID = Self.applicationMap(from: applications)
            await executor.discardStagedDownloads()
            return nil
        }

        // Staged packages are process-local and are never trusted across a
        // relaunch. The restored queue will re-stage only queued items.
        await executor.discardStagedDownloads()
        applicationsByID = Self.applicationMap(from: applications)
        let recoveryDate = now()
        for index in restored.tasks.indices {
            switch restored.tasks[index].state {
            case .installing, .verifying:
                restored.tasks[index].state = .needsReconciliation
                restored.tasks[index].detail = "The previous process ended during installation; the on-disk version must be reconciled."
                restored.tasks[index].updatedAt = recoveryDate
            case .checking, .downloading:
                restored.tasks[index].state = .queued
                restored.tasks[index].progressFraction = nil
                restored.tasks[index].detail = "The interrupted pre-install work will be retried."
                restored.tasks[index].updatedAt = recoveryDate
            case .queued, .waitingForQuit, .waitingForAuthorization,
                 .completed, .skipped, .cancelled, .failed, .needsReconciliation:
                break
            }
        }
        restored.isPaused = restored.isPaused || !autoResume
        restored.updatedAt = recoveryDate
        snapshot = restored
        try await repository.save(restored)
        emit(.restored(restored))

        if autoResume {
            await reconcilePendingTasks()
            scheduleWorkerIfNeeded(sessionID: restored.plan.id)
        }
        return snapshot
    }

    @discardableResult
    func start(
        plan: ApplicationUpdatePlan,
        applications: [InstalledApplication]
    ) async throws -> ApplicationUpdateQueueSnapshot {
        guard !isCancelling else {
            throw ApplicationUpdateCoordinatorError.cancellationInProgress
        }
        if let snapshot, hasActiveWork(snapshot), !allTasksTerminal(snapshot.tasks) {
            throw ApplicationUpdateCoordinatorError.sessionAlreadyActive
        }
        guard worker == nil else { throw ApplicationUpdateCoordinatorError.sessionAlreadyActive }

        let applicationMap = Self.applicationMap(from: applications)
        try validate(plan: plan, applications: applicationMap)

        let createdAt = now()
        let tasks = allPlanIDs(plan).map { applicationID -> ApplicationUpdateTask in
            let application = applicationMap[applicationID]!
            let state = initialState(applicationID: applicationID, plan: plan)
            var task = ApplicationUpdateTask(
                sessionID: plan.id,
                application: application,
                state: state,
                createdAt: createdAt
            )
            task.detail = initialDetail(for: state, application: application)
            return task
        }
        let newSnapshot = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: plan,
            tasks: tasks,
            isPaused: false,
            updatedAt: createdAt
        )

        try Task.checkCancellation()
        try await repository.save(newSnapshot)
        if Task.isCancelled {
            var cancelledSnapshot = newSnapshot
            let cancellationDate = now()
            Self.markNonterminalTasksCancelled(
                in: &cancelledSnapshot,
                at: cancellationDate
            )
            applicationsByID = applicationMap
            snapshot = cancelledSnapshot
            try await persistExplicitCancellation(cancelledSnapshot)
            throw CancellationError()
        }
        // Testable suspension point for the only cancellation window that used
        // to sit between the final check and worker creation.
        await beforeWorkerSchedule()
        if Task.isCancelled {
            var cancelledSnapshot = newSnapshot
            let cancellationDate = now()
            Self.markNonterminalTasksCancelled(
                in: &cancelledSnapshot,
                at: cancellationDate
            )
            applicationsByID = applicationMap
            snapshot = cancelledSnapshot
            try await persistExplicitCancellation(cancelledSnapshot)
            throw CancellationError()
        }
        applicationsByID = applicationMap
        snapshot = newSnapshot
        await executor.discardStagedDownloads()
        emit(.started(newSnapshot))
        scheduleWorkerIfNeeded(sessionID: plan.id)
        if tasks.allSatisfy(\.state.isTerminal) {
            emit(.drained(newSnapshot))
        }
        return newSnapshot
    }

    @discardableResult
    func start(applications: [InstalledApplication]) async throws -> ApplicationUpdateQueueSnapshot {
        let plan = ApplicationUpdatePlanBuilder().build(applications: applications, createdAt: now())
        return try await start(plan: plan, applications: applications)
    }

    func pause() async throws {
        guard !isCancelling else {
            throw ApplicationUpdateCoordinatorError.cancellationInProgress
        }
        guard var current = snapshot else { throw ApplicationUpdateCoordinatorError.noActiveSession }
        guard !current.isPaused else { return }
        current.isPaused = true
        current.updatedAt = now()
        snapshot = current
        try await repository.save(current)
        emit(.paused(current))
    }

    func resume() async throws {
        guard !isCancelling else {
            throw ApplicationUpdateCoordinatorError.cancellationInProgress
        }
        guard var current = snapshot else { throw ApplicationUpdateCoordinatorError.noActiveSession }
        guard current.isPaused else {
            scheduleWorkerIfNeeded(sessionID: current.plan.id)
            return
        }
        current.isPaused = false
        current.updatedAt = now()
        snapshot = current
        try await repository.save(current)
        emit(.resumed(current))

        await reconcilePendingTasks()
        scheduleWorkerIfNeeded(sessionID: current.plan.id)
    }

    func cancel() async throws {
        guard var current = snapshot else { throw ApplicationUpdateCoordinatorError.noActiveSession }
        guard !isCancelling else {
            throw ApplicationUpdateCoordinatorError.cancellationInProgress
        }
        isCancelling = true
        defer { isCancelling = false }
        let timestamp = now()
        Self.markNonterminalTasksCancelled(in: &current, at: timestamp)
        current.isPaused = false
        current.updatedAt = timestamp
        snapshot = current
        var persistenceError: Error?
        do {
            try await persistExplicitCancellation(current)
        } catch {
            persistenceError = error
        }
        emit(.snapshotChanged(current))

        let runningWorker = worker
        runningWorker?.cancel()
        if let currentApplicationID {
            await executor.cancel(applicationID: currentApplicationID)
        }
        await runningWorker?.value
        worker = nil
        self.currentApplicationID = nil
        await executor.discardStagedDownloads()
        if let persistenceError {
            throw persistenceError
        }
        emit(.drained(current))
    }

    private static func markNonterminalTasksCancelled(
        in snapshot: inout ApplicationUpdateQueueSnapshot,
        at timestamp: Date
    ) {
        for index in snapshot.tasks.indices where !snapshot.tasks[index].state.isTerminal {
            snapshot.tasks[index].state = .cancelled
            snapshot.tasks[index].progressFraction = nil
            snapshot.tasks[index].detail = "Cancelled by the user."
            snapshot.tasks[index].updatedAt = timestamp
        }
        snapshot.isPaused = false
        snapshot.updatedAt = timestamp
    }

    /// Stops in-flight work for application termination without converting the
    /// user's persisted update intent into an explicit cancellation.
    func suspendForTermination() async throws {
        guard var current = snapshot else { return }
        guard !isCancelling else {
            throw ApplicationUpdateCoordinatorError.cancellationInProgress
        }
        isCancelling = true
        defer { isCancelling = false }

        let sessionID = current.plan.id
        let tasksBeforeSuspension = current.tasks
        let timestamp = now()
        current.isPaused = true
        current.updatedAt = timestamp
        snapshot = current
        do {
            try await persist(current)
        } catch {
            // Provider cleanup is mandatory even when this intermediate pause
            // cannot be saved. The recovered snapshot below is persisted after
            // the active process has stopped and remains the final authority.
        }

        let runningWorker = worker
        let activeApplicationID = currentApplicationID
        runningWorker?.cancel()
        if let activeApplicationID {
            await executor.cancel(applicationID: activeApplicationID)
        }
        await runningWorker?.value
        worker = nil
        currentApplicationID = nil
        await executor.discardStagedDownloads()

        guard var recovered = snapshot, recovered.plan.id == sessionID else { return }
        for suspendedTask in tasksBeforeSuspension {
            guard let index = recovered.tasks.firstIndex(where: { $0.id == suspendedTask.id }) else {
                continue
            }
            var task = suspendedTask
            switch suspendedTask.state {
            case .checking, .downloading:
                task.state = .queued
                task.progressFraction = nil
                task.detail = "The app closed before installation; this update can resume safely."
                task.errorDescription = nil
            case .installing, .verifying:
                task.state = .needsReconciliation
                task.progressFraction = nil
                task.detail = "The app closed during installation; the on-disk version must be reconciled before resuming."
                task.errorDescription = nil
            case .queued:
                task.progressFraction = nil
                task.detail = "Paused because the app is closing."
                task.errorDescription = nil
            case .waitingForQuit, .waitingForAuthorization, .needsReconciliation,
                 .completed, .skipped, .cancelled, .failed:
                break
            }
            if !suspendedTask.state.isTerminal {
                task.updatedAt = timestamp
            }
            recovered.tasks[index] = task
        }
        recovered.isPaused = true
        recovered.updatedAt = timestamp
        snapshot = recovered
        try await persist(recovered)
        for task in recovered.tasks where !task.state.isTerminal {
            emit(.taskChanged(task))
        }
        emit(.paused(recovered))
        emit(.snapshotChanged(recovered))
    }

    func retry(applicationID: String) async throws {
        guard !isCancelling else {
            throw ApplicationUpdateCoordinatorError.cancellationInProgress
        }
        guard var current = snapshot else { throw ApplicationUpdateCoordinatorError.noActiveSession }
        guard let index = current.tasks.firstIndex(where: { $0.applicationID == applicationID }) else {
            throw ApplicationUpdateCoordinatorError.unknownApplication(applicationID)
        }
        let oldState = current.tasks[index].state
        guard oldState == .failed || oldState == .cancelled || oldState == .needsReconciliation else {
            throw ApplicationUpdateCoordinatorError.taskCannotBeRetried(applicationID)
        }
        guard let application = applicationsByID[applicationID],
              ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(application)
        else {
            throw ApplicationUpdateCoordinatorError.unsafeAutomaticApplication(applicationID)
        }
        try Self.validateTransition(applicationID: applicationID, from: oldState, to: .queued)
        current.tasks[index].state = .queued
        current.tasks[index].progressFraction = nil
        current.tasks[index].detail = "Queued for retry."
        current.tasks[index].errorDescription = nil
        current.tasks[index].updatedAt = now()
        current.updatedAt = now()
        snapshot = current
        try await repository.save(current)
        emit(.taskChanged(current.tasks[index]))
        emit(.snapshotChanged(current))
        scheduleWorkerIfNeeded(sessionID: current.plan.id)
    }

    func reconcilePendingTasks() async {
        guard let current = snapshot else { return }
        let sessionID = current.plan.id
        let taskIDs = current.tasks
            .filter { $0.state == .needsReconciliation }
            .map(\.id)

        for taskID in taskIDs where !Task.isCancelled {
            guard let task = task(id: taskID, sessionID: sessionID) else { continue }
            currentApplicationID = task.applicationID
            do {
                let result = try await executor.reconcile(
                    task: task,
                    application: applicationsByID[task.applicationID]
                )
                await applyExecutionResult(result, to: taskID, sessionID: sessionID)
            } catch is CancellationError {
                await finishTask(
                    taskID,
                    sessionID: sessionID,
                    state: .needsReconciliation,
                    error: nil,
                    detail: "Reconciliation was interrupted and will be retried after launch."
                )
            } catch {
                await finishTask(
                    taskID,
                    sessionID: sessionID,
                    state: .failed,
                    error: String(describing: error),
                    detail: "The interrupted update could not be reconciled."
                )
            }
            if currentApplicationID == task.applicationID {
                currentApplicationID = nil
            }
        }
    }

    func clearFinishedSession() async throws {
        guard !isCancelling else {
            throw ApplicationUpdateCoordinatorError.cancellationInProgress
        }
        guard let current = snapshot else {
            try await repository.clear()
            return
        }
        guard allTasksTerminal(current.tasks) else {
            throw ApplicationUpdateCoordinatorError.sessionStillActive
        }
        isCancelling = true
        defer { isCancelling = false }
        let finishingWorker = worker
        finishingWorker?.cancel()
        await finishingWorker?.value
        worker = nil
        currentApplicationID = nil
        await executor.discardStagedDownloads()
        snapshot = nil
        applicationsByID = [:]
        try await repository.clear()
    }

    private func runLoop(sessionID: UUID) async {
        defer {
            if snapshot?.plan.id == sessionID {
                worker = nil
                currentApplicationID = nil
            }
        }

        await stageOfficialWebsiteTasks(sessionID: sessionID)
        while !Task.isCancelled {
            guard let current = snapshot, current.plan.id == sessionID else { return }
            if current.isPaused { return }
            guard let nextTask = current.tasks.first(where: { $0.state == .queued }) else {
                emit(.drained(current))
                return
            }
            await execute(taskID: nextTask.id, sessionID: sessionID)
        }
    }

    private func stageOfficialWebsiteTasks(sessionID: UUID) async {
        guard let current = snapshot, current.plan.id == sessionID else { return }
        let tasks = current.tasks.filter {
            $0.state == .queued && $0.providerIdentifier == .officialWebsite
        }
        guard !tasks.isEmpty else { return }

        var stageTasks = [ApplicationUpdateTask]()
        for task in tasks {
            do {
                try await transition(taskID: task.id, sessionID: sessionID, to: .downloading) { task in
                    task.progressFraction = nil
                    task.detail = L10n.text(
                        "正在并行暂存官方更新包。",
                        "Staging verified official packages in parallel."
                    )
                    task.errorDescription = nil
                }
                if let stagedTask = self.task(id: task.id, sessionID: sessionID),
                   stagedTask.state == .downloading {
                    stageTasks.append(stagedTask)
                }
            } catch {
                await finishTask(
                    task.id,
                    sessionID: sessionID,
                    state: .failed,
                    error: String(describing: error),
                    detail: "The official staging phase could not start."
                )
            }
        }

        guard !stageTasks.isEmpty else { return }
        let stageTasksForWork = stageTasks

        guard !Task.isCancelled,
              let latest = snapshot,
              latest.plan.id == sessionID else {
            await executor.discardStagedDownloads()
            return
        }
        let applications = stageTasksForWork.compactMap { applicationsByID[$0.applicationID] }
        let report = await executor.stageDownloads(
            applications: applications,
            tasks: stageTasksForWork,
            progress: { [weak self] progress in
                guard let task = stageTasksForWork.first(where: {
                    $0.applicationID == progress.applicationID
                }) else { return }
                await self?.receive(
                    progress: progress,
                    taskID: task.id,
                    sessionID: sessionID
                )
            }
        )
        guard !Task.isCancelled else {
            await executor.discardStagedDownloads()
            return
        }

        for task in stageTasksForWork {
            guard let currentTask = self.task(id: task.id, sessionID: sessionID),
                  currentTask.state == .downloading else { continue }
            if let detail = report.failedApplicationDetails[task.applicationID] {
                await finishTask(
                    task.id,
                    sessionID: sessionID,
                    state: .failed,
                    error: detail,
                    detail: detail
                )
            } else if report.stagedApplicationIDs.contains(task.applicationID) {
                do {
                    try await transition(taskID: task.id, sessionID: sessionID, to: .queued) { task in
                        task.progressFraction = nil
                        task.detail = L10n.text(
                            "官方更新包已暂存，等待串行安装。",
                            "The official package is staged and queued for serial installation."
                        )
                    }
                } catch {
                    await finishTask(
                        task.id,
                        sessionID: sessionID,
                        state: .failed,
                        error: String(describing: error),
                        detail: "The staged package could not be queued safely."
                    )
                }
            } else {
                await finishTask(
                    task.id,
                    sessionID: sessionID,
                    state: .failed,
                    error: "The official package was not staged.",
                    detail: "The official package was not staged."
                )
            }
        }
    }

    private func execute(taskID: UUID, sessionID: UUID) async {
        guard let startingTask = task(id: taskID, sessionID: sessionID),
              let application = applicationsByID[startingTask.applicationID]
        else { return }

        do {
            try await transition(taskID: taskID, sessionID: sessionID, to: .checking) { task in
                task.attemptCount += 1
                task.progressFraction = nil
                task.detail = L10n.text(
                    "正在检查来源、版本、签名、运行能力和磁盘空间。",
                    "Checking source, version, signature, runtime capability, and disk space."
                )
                task.errorDescription = nil
            }
        } catch {
            return
        }

        currentApplicationID = application.id
        guard let executionTask = task(id: taskID, sessionID: sessionID) else { return }

        do {
            let result = try await executor.execute(
                application: application,
                task: executionTask,
                progress: { [weak self] progress in
                    await self?.receive(progress: progress, taskID: taskID, sessionID: sessionID)
                }
            )
            await applyExecutionResult(result, to: taskID, sessionID: sessionID)
        } catch is CancellationError {
            await finishTask(taskID, sessionID: sessionID, state: .cancelled, error: nil, detail: "Update was cancelled.")
        } catch {
            let description = error.localizedDescription
            await finishTask(
                taskID,
                sessionID: sessionID,
                state: .failed,
                error: description,
                detail: description
            )
        }

        if currentApplicationID == application.id {
            currentApplicationID = nil
        }
    }

    private func receive(
        progress: ApplicationUpdateProgressEvent,
        taskID: UUID,
        sessionID: UUID
    ) async {
        guard let currentTask = task(id: taskID, sessionID: sessionID),
              currentTask.applicationID == progress.applicationID,
              !currentTask.state.isTerminal,
              progress.state != .completed,
              progress.state != .needsReconciliation
        else { return }

        do {
            try await transition(taskID: taskID, sessionID: sessionID, to: progress.state) { task in
                if let fraction = progress.fraction, fraction.isFinite {
                    task.progressFraction = min(max(fraction, 0), 1)
                }
                task.detail = progress.detail
                if progress.state == .failed {
                    task.errorDescription = progress.detail
                }
            }
        } catch {
            await finishTask(
                taskID,
                sessionID: sessionID,
                state: .failed,
                error: String(describing: error),
                detail: "The update provider reported an invalid state transition."
            )
            await executor.cancel(applicationID: currentTask.applicationID)
        }
    }

    private func applyExecutionResult(
        _ result: ApplicationUpdateInstallResult,
        to taskID: UUID,
        sessionID: UUID
    ) async {
        guard let currentTask = task(id: taskID, sessionID: sessionID),
              currentTask.applicationID == result.applicationID,
              !currentTask.state.isTerminal
        else { return }

        switch result.state {
        case .completed:
            guard let observed = result.observedVersion,
                  isVerifiedUpgrade(
                    observed,
                    from: currentTask.originalVersion,
                    target: currentTask.targetVersion
                  )
            else {
                await finishTask(
                    taskID,
                    sessionID: sessionID,
                    state: .failed,
                    error: "The on-disk version did not change to the expected version.",
                    detail: "The provider completed, but version verification failed."
                )
                return
            }
            do {
                if currentTask.state != .verifying {
                    try await transition(taskID: taskID, sessionID: sessionID, to: .verifying) { task in
                        task.progressFraction = nil
                        task.detail = "Verifying the installed version."
                    }
                }
                await finishTask(
                    taskID,
                    sessionID: sessionID,
                    state: .completed,
                    error: nil,
                    detail: result.detail
                )
            } catch {
                await finishTask(
                    taskID,
                    sessionID: sessionID,
                    state: .failed,
                    error: String(describing: error),
                    detail: "The update result could not enter verification."
                )
            }
        case .failed, .cancelled, .skipped:
            await finishTask(
                taskID,
                sessionID: sessionID,
                state: result.state,
                error: result.state == .failed ? result.detail : nil,
                detail: result.detail
            )
        case .waitingForQuit, .waitingForAuthorization:
            do {
                try await transition(taskID: taskID, sessionID: sessionID, to: result.state) { task in
                    task.progressFraction = nil
                    task.detail = result.detail
                }
            } catch {
                await finishTask(
                    taskID,
                    sessionID: sessionID,
                    state: .failed,
                    error: String(describing: error),
                    detail: "The update provider returned an invalid waiting state."
                )
            }
        case .queued, .checking, .downloading, .installing, .verifying, .needsReconciliation:
            await finishTask(
                taskID,
                sessionID: sessionID,
                state: .failed,
                error: "The update executor returned a non-terminal result.",
                detail: result.detail
            )
        }
    }

    private func transition(
        taskID: UUID,
        sessionID: UUID,
        to state: ApplicationUpdateTaskState,
        mutate: (inout ApplicationUpdateTask) -> Void = { _ in }
    ) async throws {
        guard var current = snapshot, current.plan.id == sessionID,
              let index = current.tasks.firstIndex(where: { $0.id == taskID })
        else { return }
        let applicationID = current.tasks[index].applicationID
        let oldState = current.tasks[index].state
        try Self.validateTransition(applicationID: applicationID, from: oldState, to: state)
        current.tasks[index].state = state
        mutate(&current.tasks[index])
        current.tasks[index].updatedAt = now()
        current.updatedAt = now()
        do {
            try await persist(current)
        } catch {
            // Stop this in-memory worker immediately. The last durable snapshot
            // is either pre-side-effect or `needsReconciliation`, so relaunch is
            // safe even though this paused flag itself could not be written.
            current.isPaused = true
            snapshot = current
            emit(.snapshotChanged(current))
            throw error
        }
        snapshot = current
        emit(.taskChanged(current.tasks[index]))
        emit(.snapshotChanged(current))
    }

    private func finishTask(
        _ taskID: UUID,
        sessionID: UUID,
        state: ApplicationUpdateTaskState,
        error: String?,
        detail: String
    ) async {
        do {
            try await transition(taskID: taskID, sessionID: sessionID, to: state) { task in
                task.progressFraction = state == .completed ? 1 : nil
                task.detail = detail
                task.errorDescription = error
            }
        } catch let transitionError {
            guard state != .failed else { return }
            try? await transition(taskID: taskID, sessionID: sessionID, to: .failed) { task in
                task.progressFraction = nil
                task.detail = detail
                task.errorDescription = error ?? String(describing: transitionError)
            }
        }
    }

    private func persist(_ snapshot: ApplicationUpdateQueueSnapshot) async throws {
        do {
            try await repository.save(snapshot)
        } catch {
            let detail = String(describing: error)
            emit(.persistenceFailed(sessionID: snapshot.plan.id, detail: detail))
            throw ApplicationUpdateCoordinatorError.persistenceFailed(detail)
        }
    }

    /// Explicit user cancellation must never leave an older active snapshot
    /// behind. If overwriting fails, removing the stale snapshot is the safe
    /// fallback; if both operations fail the caller must surface that failure.
    private func persistExplicitCancellation(
        _ snapshot: ApplicationUpdateQueueSnapshot
    ) async throws {
        do {
            try await repository.save(snapshot)
        } catch {
            let saveError = String(describing: error)
            emit(.persistenceFailed(sessionID: snapshot.plan.id, detail: saveError))
            do {
                try await repository.clear()
            } catch {
                let clearError = String(describing: error)
                emit(.persistenceFailed(sessionID: snapshot.plan.id, detail: clearError))
                throw ApplicationUpdateCoordinatorError.cancellationPersistenceFailed(
                    saveError: saveError,
                    clearError: clearError
                )
            }
        }
    }

    private func scheduleWorkerIfNeeded(sessionID: UUID) {
        guard worker == nil,
              let current = snapshot,
              current.plan.id == sessionID,
              !current.isPaused,
              current.tasks.contains(where: { $0.state == .queued })
        else { return }

        worker = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.runLoop(sessionID: sessionID)
        }
    }

    private func task(id: UUID, sessionID: UUID) -> ApplicationUpdateTask? {
        guard let current = snapshot, current.plan.id == sessionID else { return nil }
        return current.tasks.first(where: { $0.id == id })
    }

    private func validate(
        plan: ApplicationUpdatePlan,
        applications: [String: InstalledApplication]
    ) throws {
        var seen: Set<String> = []
        for id in allPlanIDs(plan) {
            guard applications[id] != nil else {
                throw ApplicationUpdateCoordinatorError.unknownApplication(id)
            }
            guard seen.insert(id).inserted else {
                throw ApplicationUpdateCoordinatorError.duplicatePlanMembership(id)
            }
        }
        for id in plan.automaticApplicationIDs {
            guard let application = applications[id],
                  ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(application)
            else {
                throw ApplicationUpdateCoordinatorError.unsafeAutomaticApplication(id)
            }
        }
    }

    private func allPlanIDs(_ plan: ApplicationUpdatePlan) -> [String] {
        plan.automaticApplicationIDs
            + plan.requiresQuitApplicationIDs
            + plan.requiresAuthorizationApplicationIDs
            + plan.appStoreApplicationIDs
            + plan.websiteApplicationIDs
            + plan.manualApplicationIDs
            + plan.skippedApplicationIDs
    }

    private func initialState(
        applicationID: String,
        plan: ApplicationUpdatePlan
    ) -> ApplicationUpdateTaskState {
        if plan.automaticApplicationIDs.contains(applicationID) { return .queued }
        if plan.requiresQuitApplicationIDs.contains(applicationID) { return .waitingForQuit }
        if plan.requiresAuthorizationApplicationIDs.contains(applicationID) { return .waitingForAuthorization }
        return .skipped
    }

    private func initialDetail(
        for state: ApplicationUpdateTaskState,
        application: InstalledApplication
    ) -> String {
        switch state {
        case .queued:
            return "Queued for verified automatic update."
        case .waitingForQuit:
            return "Waiting for the user to quit the application safely."
        case .waitingForAuthorization:
            return "Administrator authorization is required before installation."
        case .skipped:
            return application.updateHandlingDetail
        case .checking, .downloading, .installing, .verifying, .completed,
             .cancelled, .failed, .needsReconciliation:
            return ""
        }
    }

    private func hasActiveWork(_ snapshot: ApplicationUpdateQueueSnapshot) -> Bool {
        snapshot.tasks.contains { !$0.state.isTerminal }
    }

    private func allTasksTerminal(_ tasks: [ApplicationUpdateTask]) -> Bool {
        tasks.allSatisfy(\.state.isTerminal)
    }

    private func emit(_ event: ApplicationUpdateCoordinatorEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    static func isValidTransition(
        from: ApplicationUpdateTaskState,
        to: ApplicationUpdateTaskState
    ) -> Bool {
        if from == to { return true }
        let allowed: Set<ApplicationUpdateTaskState>
        switch from {
        case .queued:
            allowed = [.checking, .cancelled, .skipped]
        case .checking:
            allowed = [.downloading, .waitingForQuit, .waitingForAuthorization,
                       .installing, .verifying, .failed, .cancelled, .skipped,
                       .needsReconciliation]
        case .downloading:
            allowed = [.queued, .waitingForQuit, .waitingForAuthorization, .installing,
                       .verifying, .failed, .cancelled, .skipped]
        case .waitingForQuit, .waitingForAuthorization:
            allowed = [.queued, .installing, .verifying, .failed, .cancelled, .skipped]
        case .installing:
            allowed = [.verifying, .needsReconciliation, .failed, .cancelled]
        case .verifying:
            allowed = [.completed, .needsReconciliation, .failed, .cancelled]
        case .needsReconciliation:
            allowed = [.queued, .downloading, .waitingForQuit, .waitingForAuthorization,
                       .installing, .verifying, .completed, .failed, .cancelled, .skipped]
        case .failed, .cancelled:
            allowed = [.queued]
        case .completed, .skipped:
            allowed = []
        }
        return allowed.contains(to)
    }

    private static func validateTransition(
        applicationID: String,
        from: ApplicationUpdateTaskState,
        to: ApplicationUpdateTaskState
    ) throws {
        guard isValidTransition(from: from, to: to) else {
            throw ApplicationUpdateCoordinatorError.invalidTransition(
                applicationID: applicationID,
                from: from,
                to: to
            )
        }
    }

    private static func applicationMap(
        from applications: [InstalledApplication]
    ) -> [String: InstalledApplication] {
        var result: [String: InstalledApplication] = [:]
        for application in applications {
            if let existing = result[application.id], existing.lastScanDate > application.lastScanDate {
                continue
            }
            result[application.id] = application
        }
        return result
    }

    private func isVerifiedUpgrade(
        _ observed: ApplicationVersion,
        from original: ApplicationVersion,
        target: ApplicationVersion?
    ) -> Bool {
        guard observed != original,
              compareVersion(observed, original) != .orderedAscending
        else { return false }
        guard let target else { return true }
        return compareVersion(observed, target) != .orderedAscending
    }

    private func compareVersion(
        _ lhs: ApplicationVersion,
        _ rhs: ApplicationVersion
    ) -> ComparisonResult {
        let marketing = ApplicationVersion.compare(lhs.marketing, rhs.marketing)
        guard marketing == .orderedSame else { return marketing }
        return ApplicationVersion.compare(lhs.build, rhs.build)
    }
}
