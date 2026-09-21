import Foundation

/// App-scoped v7 coordinator. It intentionally wraps the frozen v6 core
/// runner during the migration so old data stays immutable while the new
/// session/state/persistence protocol is exercised by real workloads.
actor BenchmarkV7Coordinator {
    typealias ProgressHandler = @Sendable (BenchmarkV7State) async -> Void

    /// Kept only for the migration fixture path. Production v7 uses the
    /// dedicated workload runner below and never rewrites a v6 result.
    private let coreService: (any MacBenchmarkServicing)?
    private let workloadRunner: (any BenchmarkV7WorkloadRunning)?
    private let heavyWorkCoordinator: HeavyWorkCoordinator?
    private let sustainedService: (any MacSustainedBenchmarkServicing)?
    private let preflightService: any BenchmarkV7Preflighting
    private let environmentProvider: any MacBenchmarkEnvironmentProviding
    private let hardwareProfileProvider: any BenchmarkV7HardwareProfileProviding
    private let timeouts: BenchmarkV7TimeoutPolicy
    private let resourceJournal: CleanupReportJournal?
    private var activeSessionID: UUID?
    private var cleanupSessionID: UUID?
    /// A deadline can return while a kernel is still executing. Once that
    /// happens, this process never starts another benchmark; only an app restart
    /// can prove the old task and its process-owned resources are gone.
    private var restartRequiredContext: BenchmarkV7TimeoutContext?
    private var activeHardwareProfile: BenchmarkV7HardwareProfile?

    init(
        coreService: any MacBenchmarkServicing,
        preflightService: any BenchmarkV7Preflighting = BenchmarkV7PreflightService(),
        environmentProvider: any MacBenchmarkEnvironmentProviding
            = SystemMacBenchmarkEnvironmentProvider(),
        hardwareProfileProvider: any BenchmarkV7HardwareProfileProviding
            = SystemBenchmarkV7HardwareProfileProvider(),
        timeouts: BenchmarkV7TimeoutPolicy = .standard
    ) {
        self.coreService = coreService
        workloadRunner = nil
        heavyWorkCoordinator = nil
        sustainedService = nil
        self.preflightService = preflightService
        self.environmentProvider = environmentProvider
        self.hardwareProfileProvider = hardwareProfileProvider
        self.timeouts = timeouts
        resourceJournal = nil
    }

    init(
        workloadRunner: any BenchmarkV7WorkloadRunning,
        heavyWorkCoordinator: HeavyWorkCoordinator,
        sustainedService: (any MacSustainedBenchmarkServicing)? = nil,
        preflightService: any BenchmarkV7Preflighting = BenchmarkV7PreflightService(),
        environmentProvider: any MacBenchmarkEnvironmentProviding
            = SystemMacBenchmarkEnvironmentProvider(),
        hardwareProfileProvider: any BenchmarkV7HardwareProfileProviding
            = SystemBenchmarkV7HardwareProfileProvider(),
        timeouts: BenchmarkV7TimeoutPolicy = .standard,
        resourceJournal: CleanupReportJournal? = .live
    ) {
        coreService = nil
        self.workloadRunner = workloadRunner
        self.heavyWorkCoordinator = heavyWorkCoordinator
        self.sustainedService = sustainedService
        self.preflightService = preflightService
        self.environmentProvider = environmentProvider
        self.hardwareProfileProvider = hardwareProfileProvider
        self.timeouts = timeouts
        self.resourceJournal = resourceJournal
    }

    func preflight(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL = DiskBenchmarkKernel.defaultRootDirectory
    ) async -> BenchmarkV7PreflightReport {
        await preflightOutcome(
            plan: plan,
            categories: categories,
            targetDirectory: targetDirectory
        ).report
    }

    func preflightOutcome(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL = DiskBenchmarkKernel.defaultRootDirectory
    ) async -> BenchmarkV7PreflightOutcome {
        let fallback = Self.fallbackPreflight(targetDirectory: targetDirectory)
        if let restartRequiredContext {
            return BenchmarkV7PreflightOutcome(
                report: fallback,
                failure: .restartRequired(restartRequiredContext)
            )
        }
        guard activeSessionID == nil, cleanupSessionID == nil else {
            return BenchmarkV7PreflightOutcome(
                report: fallback,
                failure: .alreadyRunning
            )
        }
        do {
            let report = try await timedOperation(
                sessionID: UUID(),
                timeout: timeouts.preflight,
                context: BenchmarkV7TimeoutContext(
                    phase: .preflighting,
                    category: nil,
                    workloadID: "preflight"
                )
            ) { [preflightService] in
                await preflightService.capture(
                    plan: plan,
                    categories: categories,
                    targetDirectory: targetDirectory
                )
            }
            return BenchmarkV7PreflightOutcome(report: report, failure: nil)
        } catch {
            return BenchmarkV7PreflightOutcome(
                report: fallback,
                failure: failure(from: error)
            )
        }
    }

    func run(
        sessionID suppliedSessionID: UUID? = nil,
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category]? = nil,
        targetDirectory: URL = DiskBenchmarkKernel.defaultRootDirectory,
        forcePreflightContinuation: Bool = false,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> BenchmarkV7Result {
        let requestedCategories = categories ?? plan.categories
        let sessionID = suppliedSessionID ?? UUID()
        if plan.planVersion == MSeriesProtocol.plan {
            return await runMSeries(sessionID: sessionID, targetDirectory: targetDirectory, progress: progress)
        }
        if let restartRequiredContext {
            let preflight = Self.fallbackPreflight(targetDirectory: targetDirectory)
            return BenchmarkV7Result(
                session: BenchmarkV7Session(
                    id: sessionID,
                    plan: plan,
                    categories: requestedCategories,
                    storageTarget: preflight.storageTarget,
                    forcedPreflightContinuation: forcePreflightContinuation
                ),
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: Self.versions(for: plan),
                metrics: [],
                coreScore: nil,
                completedAt: nil,
                failure: .restartRequired(restartRequiredContext)
            )
        }
        guard activeSessionID == nil, cleanupSessionID == nil else {
            let preflight = Self.fallbackPreflight(targetDirectory: targetDirectory)
            return BenchmarkV7Result(
                session: BenchmarkV7Session(
                    id: sessionID,
                    plan: plan,
                    categories: requestedCategories,
                    storageTarget: preflight.storageTarget,
                    forcedPreflightContinuation: forcePreflightContinuation
                ),
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: Self.versions(for: plan),
                metrics: [],
                coreScore: nil,
                completedAt: nil,
                failure: .alreadyRunning
            )
        }

        activeSessionID = sessionID
        activeHardwareProfile = hardwareProfileProvider.capture()
        defer {
            activeSessionID = nil
            activeHardwareProfile = nil
        }
        var stateMachine = BenchmarkV7StateMachine()
        _ = stateMachine.transition(to: .phase(.preflighting, sessionID: sessionID))
        await progress(stateMachine.state)
        let fallbackPreflight = Self.fallbackPreflight(targetDirectory: targetDirectory)
        let preflight: BenchmarkV7PreflightReport
        do {
            preflight = try await timedOperation(
                sessionID: sessionID,
                timeout: timeouts.preflight,
                context: BenchmarkV7TimeoutContext(
                    phase: .preflighting,
                    category: nil,
                    workloadID: "preflight"
                )
            ) { [preflightService] in
                await preflightService.capture(
                    plan: plan,
                    categories: requestedCategories,
                    targetDirectory: targetDirectory
                )
            }
        } catch {
            let fallbackSession = BenchmarkV7Session(
                id: sessionID,
                plan: plan,
                categories: requestedCategories,
                storageTarget: fallbackPreflight.storageTarget,
                forcedPreflightContinuation: forcePreflightContinuation
            )
            let timeoutFailure = failure(from: error)
            return await failedResult(
                timeoutFailure,
                session: fallbackSession,
                preflight: fallbackPreflight,
                environment: environment(for: fallbackPreflight),
                versions: Self.versions(for: plan),
                rawRuns: [],
                runtimeWarnings: [Self.safeFailureWarning(timeoutFailure)],
                progress: progress
            )
        }
        let blockedCategories = Set(preflight.blockedCategories)
        let hardBlockedCategories = preflight.hardBlockedCategories
        let runnableCategories = forcePreflightContinuation
            ? requestedCategories.filter { !hardBlockedCategories.contains($0) }
            : requestedCategories.filter { !blockedCategories.contains($0) }
        let session = BenchmarkV7Session(
            id: sessionID,
            plan: plan,
            categories: runnableCategories,
            storageTarget: preflight.storageTarget,
            forcedPreflightContinuation: forcePreflightContinuation
        )
        let versions = Self.versions(for: plan)
        if Task.isCancelled {
            return await failedResult(
                .cancelled,
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: versions,
                rawRuns: [],
                progress: progress
            )
        }
        if OfficialBenchmarkPlan.legacyV9.matches(
            plan: plan,
            categories: requestedCategories
        ), hardBlockedCategories.contains(.storage) {
            let blockedSession = BenchmarkV7Session(
                id: sessionID,
                plan: plan,
                categories: requestedCategories,
                storageTarget: preflight.storageTarget,
                forcedPreflightContinuation: forcePreflightContinuation
            )
            return await failedResult(
                .preflightBlocked,
                session: blockedSession,
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: versions,
                rawRuns: [],
                progress: progress
            )
        }
        // The migration-only legacy core service cannot omit one category. Do
        // not let it silently run a blocked workload; the production runner
        // below supports the documented partial-result behaviour instead.
        if coreService != nil,
           (!hardBlockedCategories.isEmpty
               || (!forcePreflightContinuation && !blockedCategories.isEmpty)) {
            return BenchmarkV7Result(
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: versions,
                metrics: [],
                coreScore: nil,
                completedAt: nil,
                failure: .preflightBlocked
            )
        }
        if runnableCategories.isEmpty {
            return BenchmarkV7Result(
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: versions,
                metrics: [],
                coreScore: nil,
                completedAt: nil,
                failure: .preflightBlocked
            )
        }

        guard session.isValid else {
            return BenchmarkV7Result(
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: versions,
                metrics: [],
                coreScore: nil,
                completedAt: nil,
                failure: .internalFailure
            )
        }

        _ = stateMachine.transition(to: .phase(.ready, sessionID: sessionID))
        await progress(stateMachine.state)
        _ = stateMachine.transition(to: .phase(.preparing, sessionID: sessionID))
        await progress(stateMachine.state)
        _ = stateMachine.transition(to: .phase(.warmingUp, sessionID: sessionID))
        await progress(stateMachine.state)
        _ = stateMachine.transition(to: .phase(.calibrating, sessionID: sessionID))
        await progress(stateMachine.state)
        _ = stateMachine.transition(to: .phase(.running, sessionID: sessionID))
        await progress(stateMachine.state)
        if Task.isCancelled {
            return await failedResult(
                .cancelled,
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: versions,
                rawRuns: [],
                progress: progress
            )
        }

        var rawRuns: [MacBenchmarkRawResult] = []
        var sustainedOutput: MacSustainedBenchmarkResult?
        var metrics: [BenchmarkV7MetricResult] = []
        let includesSustainedCheck = runnableCategories.contains(.sustained)
        let workloadCategories = runnableCategories.filter { $0 != .sustained }
        let workloadProgressScale = includesSustainedCheck ? 0.8 : 1.0
        let timedProgress = BenchmarkV7TimedProgressRelay(
            sessionID: sessionID,
            fallbackContext: BenchmarkV7TimeoutContext(
                phase: .running,
                category: plan.kind == .sustained
                    ? .sustained
                    : workloadCategories.first,
                workloadID: plan.kind == .sustained
                    ? "sustained"
                    : workloadCategories.first?.rawValue
            ),
            callback: progress
        )
        let executionRecorder = BenchmarkV7WorkloadExecutionRecorder()
        do {
            if plan.kind == .sustained {
                guard let sustainedService else {
                    throw BenchmarkV7CoordinatorError.noRunner
                }
                let execution = executionRecorder.begin(
                    category: .sustained,
                    workloadID: "sustained",
                    repetition: nil
                )
                let result = try await timedOperation(
                    sessionID: sessionID,
                    timeout: timeouts.sustained(),
                    context: BenchmarkV7TimeoutContext(
                        phase: .running,
                        category: .sustained,
                        workloadID: "sustained"
                    ),
                    progressRelay: timedProgress,
                    executionRecorder: executionRecorder
                ) {
                    await sustainedService.run(
                        profile: .standard,
                        coolingMode: .systemAutomatic
                    ) { update in
                        await timedProgress.emit(
                            category: .sustained,
                            workloadID: Self.sustainedWorkloadID(for: update.stage),
                            repetition: update.completedWindowCount,
                            progress: update.progress
                        )
                    }
                }
                sustainedOutput = result
                if let failure = result.failure {
                    throw BenchmarkV7CoordinatorError.sustainedFailure(failure)
                }
                guard result.reachedTargetDuration else {
                    throw BenchmarkV7CoordinatorError.sustainedEndedBeforeTarget(
                        result.termination
                    )
                }
                executionRecorder.finish(
                    execution,
                    status: .completed,
                    failureReason: nil
                )
                metrics = try Self.sustainedMetrics(from: result)
            } else if let workloadRunner {
                let workloadProgress: @Sendable (
                    BenchmarkV7Category,
                    String,
                    Int,
                    Double
                ) async -> Void = { category, workloadID, repetition, fraction in
                        await timedProgress.emit(
                            category: category,
                            workloadID: workloadID,
                            repetition: repetition,
                            progress: fraction * workloadProgressScale
                        )
                    }
                metrics = try await timedOperation(
                    sessionID: sessionID,
                    timeout: timeouts.workload(
                        plan: plan,
                        includesSustainedCheck: includesSustainedCheck
                    ),
                    context: BenchmarkV7TimeoutContext(
                        phase: .running,
                        category: workloadCategories.first,
                        workloadID: workloadCategories.first?.rawValue
                    ),
                    progressRelay: timedProgress,
                    executionRecorder: executionRecorder,
                    acquireHeavyWorkLease: heavyWorkCoordinator != nil
                ) {
                        try await workloadRunner.run(
                            plan: plan,
                            categories: workloadCategories,
                            targetDirectory: targetDirectory,
                            executionRecorder: executionRecorder,
                            progress: workloadProgress
                        )
                }
            } else if let coreService {
                let passes = Self.corePassCount(for: plan)
                rawRuns.reserveCapacity(passes)
                for pass in 0..<passes {
                    try Task.checkCancellation()
                    let result = try await timedOperation(
                        sessionID: sessionID,
                        timeout: timeouts.workload(
                            plan: plan,
                            includesSustainedCheck: includesSustainedCheck
                        ),
                        context: BenchmarkV7TimeoutContext(
                            phase: .running,
                            category: nil,
                            workloadID: "legacy-core-pass"
                        ),
                        progressRelay: timedProgress,
                        executionRecorder: executionRecorder
                    ) {
                        await coreService.run(profile: .standard) { update in
                            let category = Self.category(for: update.stage)
                            let localProgress = (Double(pass) + update.progress)
                                / Double(passes)
                            if let category {
                                executionRecorder.observeCategory(
                                    category: category,
                                    workloadID: "legacy-core.\(category.rawValue)",
                                    repetition: pass + 1
                                )
                            }
                            await timedProgress.emit(
                                category: category,
                                workloadID: "legacy-core-pass",
                                repetition: pass + 1,
                                progress: localProgress * workloadProgressScale
                            )
                        }
                    }
                    if let failure = result.failure {
                        throw BenchmarkV7CoordinatorError.legacyFailure(
                            Self.failure(from: failure)
                        )
                    }
                    guard result.isComplete else {
                        throw BenchmarkV7CoordinatorError.invalidLegacyResult
                    }
                    executionRecorder.finishActive(
                        status: .completed,
                        failureReason: nil
                    )
                    rawRuns.append(result)
                }
                metrics = try Self.metrics(from: rawRuns, plan: plan)
            } else {
                throw BenchmarkV7CoordinatorError.noRunner
            }

            if includesSustainedCheck, plan.kind != .sustained {
                guard let sustainedService else {
                    throw BenchmarkV7CoordinatorError.noRunner
                }
                let execution = executionRecorder.begin(
                    category: .sustained,
                    workloadID: "sustained",
                    repetition: nil
                )
                let result = try await timedOperation(
                    sessionID: sessionID,
                    timeout: timeouts.sustained(),
                    context: BenchmarkV7TimeoutContext(
                        phase: .running,
                        category: .sustained,
                        workloadID: "sustained"
                    ),
                    progressRelay: timedProgress,
                    executionRecorder: executionRecorder
                ) {
                    await sustainedService.run(
                        profile: .standard,
                        coolingMode: .systemAutomatic
                    ) { update in
                        await timedProgress.emit(
                            category: .sustained,
                            workloadID: Self.sustainedWorkloadID(for: update.stage),
                            repetition: update.completedWindowCount,
                            progress: workloadProgressScale
                                + update.progress * (1 - workloadProgressScale)
                        )
                    }
                }
                sustainedOutput = result
                if let failure = result.failure {
                    throw BenchmarkV7CoordinatorError.sustainedFailure(failure)
                }
                guard result.reachedTargetDuration else {
                    throw BenchmarkV7CoordinatorError.sustainedEndedBeforeTarget(
                        result.termination
                    )
                }
                executionRecorder.finish(
                    execution,
                    status: .completed,
                    failureReason: nil
                )
                metrics.append(contentsOf: try Self.sustainedMetrics(from: result))
            }
            try Task.checkCancellation()
        } catch {
            let failureContext = await timedProgress.timeoutContext()
            await timedProgress.close()
            let failure = failure(from: error)
            let workloadFailure = workloadFailureRecord(
                from: error,
                fallbackContext: failureContext
            )
            let executionFailureReason = workloadFailure?.reason
                ?? Self.safeFailureWarning(failure)
            switch failure {
            case .cancelled:
                executionRecorder.finishActive(
                    status: .cancelled,
                    failureReason: "The workload was cancelled."
                )
            case let .timedOut(context), let .restartRequired(context):
                executionRecorder.markTimedOut(
                    reason: "timedOut \(context.detail)"
                )
            default:
                executionRecorder.finishActive(
                    status: .failed,
                    failureReason: executionFailureReason
                )
            }
            executionRecorder.close()
            let retainedMetrics = (error as? BenchmarkV7WorkloadFailure)?.completedMetrics
                ?? metrics
            let warning = workloadFailure.map {
                "v7 workload failure: category=\($0.category.rawValue) "
                    + "workload=\($0.workloadID) reason=\($0.reason)"
            } ?? Self.safeFailureWarning(failure)
            let failureWarnings = failure.requiresApplicationRestart && workloadFailure != nil
                ? [warning, Self.safeFailureWarning(failure)]
                : [warning]
            return await failedResult(
                failure,
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: versions,
                rawRuns: rawRuns,
                metrics: retainedMetrics,
                sustainedResult: sustainedOutput,
                workloadFailure: workloadFailure,
                workloadExecutions: executionRecorder.records,
                runtimeWarnings: failureWarnings,
                progress: progress
            )
        }

        if Task.isCancelled {
            executionRecorder.finishActive(
                status: .cancelled,
                failureReason: "The workload was cancelled."
            )
            executionRecorder.close()
            return await failedResult(
                .cancelled,
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                versions: versions,
                rawRuns: rawRuns,
                workloadExecutions: executionRecorder.records,
                progress: progress
            )
        }

        _ = stateMachine.transition(to: .phase(.validating, sessionID: sessionID))
        await progress(stateMachine.state)

        _ = stateMachine.transition(to: .phase(.aggregating, sessionID: sessionID))
        await progress(stateMachine.state)
        _ = stateMachine.transition(to: .phase(.scoring, sessionID: sessionID))
        await progress(stateMachine.state)
        let coreScore = Self.coreScore(plan: plan, metrics: metrics)
        let experienceScore = Self.experienceScore(plan: plan, metrics: metrics)
        let warnings = runtimeWarnings(
            requested: requestedCategories,
            runnable: runnableCategories,
            preflight: preflight,
            metrics: metrics
        )
        let confidence = Self.confidence(
            plan: plan,
            metrics: metrics,
            preflight: preflight,
            forcedPreflightContinuation: forcePreflightContinuation,
            runtimeWarnings: warnings
        )
        guard BenchmarkV7Result.scoresSatisfyCompletionContract(
            plan: plan,
            categories: runnableCategories,
            coreScore: coreScore,
            experienceScore: experienceScore
        ) else {
            let failure = BenchmarkV7Failure.validationFailed(
                "Official benchmark Core/Experience score validation failed."
            )
            executionRecorder.close()
            return await failedResult(
                failure,
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                hardwareProfile: activeHardwareProfile,
                versions: versions,
                rawRuns: rawRuns,
                metrics: metrics,
                workloadExecutions: executionRecorder.records,
                runtimeWarnings: warnings + [Self.safeFailureWarning(failure)],
                progress: progress
            )
        }
        _ = stateMachine.transition(to: .phase(.persisting, sessionID: sessionID))
        await progress(stateMachine.state)
        if Task.isCancelled {
            executionRecorder.finishActive(
                status: .cancelled,
                failureReason: "The workload was cancelled."
            )
            executionRecorder.close()
            return await failedResult(
                .cancelled,
                session: session,
                preflight: preflight,
                environment: environment(for: preflight),
                versions: versions,
                rawRuns: rawRuns,
                workloadExecutions: executionRecorder.records,
                progress: progress
            )
        }
        _ = stateMachine.transition(to: .phase(.completed, sessionID: sessionID))
        await progress(stateMachine.state)
        executionRecorder.finishActive(status: .completed, failureReason: nil)
        executionRecorder.close()
        return BenchmarkV7Result(
            session: session,
            preflight: preflight,
            environment: environment(for: preflight),
            hardwareProfile: activeHardwareProfile,
            versions: versions,
            metrics: metrics,
            coreScore: coreScore,
            experienceScore: experienceScore,
            sustainedResult: sustainedOutput,
            confidence: confidence,
            runtimeWarnings: warnings,
            workloadExecutions: executionRecorder.records,
            completedAt: Date(),
            failure: nil
        )
    }

    private func failedResult(
        _ failure: BenchmarkV7Failure,
        session: BenchmarkV7Session,
        preflight: BenchmarkV7PreflightReport,
        environment: BenchmarkEnvironmentMetadata,
        hardwareProfile: BenchmarkV7HardwareProfile? = nil,
        versions: BenchmarkV7VersionManifest,
        rawRuns: [MacBenchmarkRawResult],
        metrics: [BenchmarkV7MetricResult] = [],
        sustainedResult: MacSustainedBenchmarkResult? = nil,
        workloadFailure: BenchmarkV7WorkloadFailureRecord? = nil,
        workloadExecutions: [BenchmarkV7WorkloadExecutionRecord] = [],
        runtimeWarnings: [String] = [],
        progress: @escaping ProgressHandler
    ) async -> BenchmarkV7Result {
        if failure == .cancelled {
            await progress(.phase(.cancelling, sessionID: session.id))
            await progress(.phase(.cancelled, sessionID: session.id))
        } else {
            await progress(.failed(failure, sessionID: session.id))
        }
        return BenchmarkV7Result(
            session: session,
            preflight: preflight,
            environment: environment,
            hardwareProfile: hardwareProfile ?? activeHardwareProfile,
            versions: versions,
            metrics: metrics.isEmpty
                ? ((try? Self.metrics(from: rawRuns, plan: session.plan)) ?? [])
                : metrics,
            coreScore: nil,
            sustainedResult: sustainedResult,
            runtimeWarnings: runtimeWarnings,
            workloadFailure: workloadFailure,
            workloadExecutions: workloadExecutions,
            completedAt: nil,
            failure: failure
        )
    }

    private func environment(
        for report: BenchmarkV7PreflightReport
    ) -> BenchmarkEnvironmentMetadata {
        environmentProvider.metadata(preflight: BenchmarkPreflight(
            capturedAt: report.capturedAt,
            powerSource: report.powerSource,
            batteryPercent: report.batteryPercent,
            lowPowerModeEnabled: report.lowPowerModeEnabled,
            thermalState: report.thermalState,
            diskReliability: .unavailable,
            availableDiskBytes: report.storageTarget.availableBytes,
            requiredDiskBytes: 0,
            warnings: []
        ))
    }

    private func timedOperation<Value: Sendable>(
        sessionID: UUID,
        timeout: Duration,
        context: BenchmarkV7TimeoutContext,
        progressRelay: BenchmarkV7TimedProgressRelay? = nil,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder? = nil,
        acquireHeavyWorkLease: Bool = false,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let coordinator = heavyWorkCoordinator
        let lease: HeavyWorkCoordinator.Lease?
        if acquireHeavyWorkLease, let coordinator {
            lease = try await coordinator.acquire(owner: .benchmark)
        } else {
            lease = nil
        }

        let outcome = await BenchmarkTimedOperation.run(
            timeout: timeout,
            operation: operation
        )
        switch outcome {
        case let .success(value):
            if let lease, let coordinator { await coordinator.release(lease) }
            return value
        case let .failure(error):
            if let terminal = error.value as? BenchmarkV7SubtestTerminalFault {
                await progressRelay?.close()
                executionRecorder?.close()
                await handOffCleanup(
                    terminal.lateOperation,
                    sessionID: sessionID,
                    lease: lease,
                    coordinator: coordinator,
                    executionRecorder: executionRecorder
                )
                switch terminal.kind {
                case .timedOut:
                    restartRequiredContext = terminal.context
                    throw BenchmarkV7TimedOutFault(context: terminal.context)
                case .timerFailure:
                    restartRequiredContext = terminal.context
                    throw BenchmarkV7TimerFault(context: terminal.context)
                }
            }
            if error.value is CancellationError,
               let executionRecorder,
               executionRecorder.pendingLateOperationCount > 0 {
                await progressRelay?.close()
                executionRecorder.close()
                await handOffCleanup(
                    BenchmarkLateOperationHandle {},
                    sessionID: sessionID,
                    lease: lease,
                    coordinator: coordinator,
                    executionRecorder: executionRecorder
                )
                throw CancellationError()
            }
            if let lease, let coordinator { await coordinator.release(lease) }
            throw error.value
        case let .timedOut(lateOperation):
            await progressRelay?.close()
            let timeoutContext = await progressRelay?.timeoutContext() ?? context
            executionRecorder?.markTimedOut(reason: "timedOut \(timeoutContext.detail)")
            executionRecorder?.close()
            restartRequiredContext = timeoutContext
            await handOffCleanup(
                lateOperation.handle,
                sessionID: sessionID,
                lease: lease,
                coordinator: coordinator,
                executionRecorder: executionRecorder
            )
            throw BenchmarkV7TimedOutFault(context: timeoutContext)
        case let .cancelled(lateOperation):
            await progressRelay?.close()
            executionRecorder?.finishActive(
                status: .cancelled,
                failureReason: "The workload was cancelled."
            )
            executionRecorder?.close()
            await handOffCleanup(
                lateOperation.handle,
                sessionID: sessionID,
                lease: lease,
                coordinator: coordinator,
                executionRecorder: executionRecorder
            )
            throw CancellationError()
        case let .timerFailure(lateOperation):
            await progressRelay?.close()
            executionRecorder?.close()
            restartRequiredContext = context
            await handOffCleanup(
                lateOperation.handle,
                sessionID: sessionID,
                lease: lease,
                coordinator: coordinator,
                executionRecorder: executionRecorder
            )
            throw BenchmarkV7TimerFault(context: context)
        }
    }

    private func handOffCleanup(
        _ lateOperation: BenchmarkLateOperationHandle,
        sessionID: UUID,
        lease: HeavyWorkCoordinator.Lease?,
        coordinator: HeavyWorkCoordinator?,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder?
    ) async {
        if let lease, let coordinator {
            do {
                let quarantine = try await coordinator.beginCleanupQuarantine(lease)
                await coordinator.release(lease)
                Task {
                    await lateOperation.wait()
                    await executionRecorder?.waitForLateOperations()
                    await coordinator.clearCleanupQuarantine(quarantine)
                }
            } catch {
                Task {
                    await lateOperation.wait()
                    await executionRecorder?.waitForLateOperations()
                    await coordinator.release(lease)
                }
            }
            return
        }

        cleanupSessionID = sessionID
        Task {
            await lateOperation.wait()
            await executionRecorder?.waitForLateOperations()
            self.clearCleanupSession(sessionID)
        }
    }

    private func clearCleanupSession(_ sessionID: UUID) {
        guard cleanupSessionID == sessionID else { return }
        cleanupSessionID = nil
    }

    private static func fallbackPreflight(
        targetDirectory: URL
    ) -> BenchmarkV7PreflightReport {
        let volumeName = targetDirectory.lastPathComponent.isEmpty
            ? targetDirectory.path
            : targetDirectory.lastPathComponent
        return BenchmarkV7PreflightReport(
            capturedAt: Date(),
            powerSource: .unknown,
            batteryPercent: nil,
            lowPowerModeEnabled: false,
            thermalState: .unknown,
            backgroundLoadRatio: nil,
            availableMemoryBytes: nil,
            storageTarget: BenchmarkV7StorageTarget(
                volumeName: volumeName.isEmpty ? "Unavailable" : volumeName,
                fileSystem: nil,
                availableBytes: 0,
                isReadOnly: false
            ),
            displayDescription: nil,
            checks: [],
            blockedCategories: []
        )
    }

    private func failure(from error: Error) -> BenchmarkV7Failure {
        if error is CancellationError { return .cancelled }
        if let error = error as? BenchmarkV7TimedOutFault {
            return .restartRequired(error.context)
        }
        if let error = error as? BenchmarkV7TimerFault {
            return .restartRequired(error.context)
        }
        if Task.isCancelled { return .cancelled }
        if let error = error as? HeavyWorkCoordinator.Error {
            switch error {
            case .busy: return .alreadyRunning
            case .invalidLease: return .internalFailure
            }
        }
        if let error = error as? BenchmarkV7WorkloadFailure {
            let record = error.record
            return .validationFailed(
                "\(record.category.rawValue)/\(record.workloadID): \(record.reason)"
            )
        }
        if let error = error as? BenchmarkV7CoordinatorError {
            switch error {
            case let .legacyFailure(failure): return failure
            case let .sustainedFailure(failure):
                return Self.failure(from: failure)
            case .invalidLegacyResult, .noRunner:
                return .validationFailed(String(describing: error))
            case let .sustainedEndedBeforeTarget(termination):
                return .validationFailed(
                    Self.sustainedEarlyStopReason(termination)
                )
            }
        }
        if let error = error as? BenchmarkV7WorkloadRunnerError {
            switch error {
            case let .unsupportedPlan(kind):
                return .unsupportedCategory(kind == .sustained ? .sustained : .cpu)
            case .unavailableCategory:
                return .validationFailed(String(describing: error))
            case .invalidMeasurement:
                return .validationFailed("v7 workload returned an invalid measurement.")
            }
        }
        if let error = error as? BenchmarkV7MemoryWorkloadError {
            switch error {
            case .unsupportedPlan:
                return .unsupportedCategory(.memory)
            case .unavailable:
                return .unsupportedCategory(.memory)
            case .invalidConfiguration, .timedOut, .checksumMismatch, .invalidMeasurement:
                return .validationFailed(String(describing: error))
            }
        }
        if error is StorageRandomAccessBenchmarkV7.Failure {
            return .validationFailed("Random storage measurement failed.")
        }
        if error is BenchmarkKernelError {
            return .validationFailed("A benchmark kernel failed validation.")
        }
        if error is BenchmarkStatisticsError {
            return .validationFailed("A workload produced a non-scoreable statistic.")
        }
        return .internalFailure
    }

    private func workloadFailureRecord(
        from error: Error,
        fallbackContext: BenchmarkV7TimeoutContext
    ) -> BenchmarkV7WorkloadFailureRecord? {
        if let failure = error as? BenchmarkV7WorkloadFailure {
            return failure.record
        }
        if let failure = error as? BenchmarkV7TimedOutFault,
           let category = failure.context.category {
            return BenchmarkV7WorkloadFailureRecord(
                category: category,
                workloadID: failure.context.workloadID ?? category.rawValue,
                reason: "timedOut \(failure.context.detail)"
            )
        }
        if case let BenchmarkV7CoordinatorError.sustainedFailure(failure) = error {
            return BenchmarkV7WorkloadFailureRecord(
                category: .sustained,
                workloadID: "sustained",
                reason: String(describing: failure)
            )
        }
        if case let BenchmarkV7CoordinatorError.sustainedEndedBeforeTarget(termination) = error {
            return BenchmarkV7WorkloadFailureRecord(
                category: .sustained,
                workloadID: "sustained",
                reason: Self.sustainedEarlyStopReason(termination)
            )
        }
        guard let category = fallbackContext.category,
              isWorkloadFailure(error) else {
            return nil
        }
        let workloadID = fallbackContext.workloadID?.isEmpty == false
            ? fallbackContext.workloadID!
            : category.rawValue
        return BenchmarkV7WorkloadFailureRecord(
            category: category,
            workloadID: workloadID,
            reason: BenchmarkV7WorkloadFailureReason.safe(error)
        )
    }

    private static func sustainedEarlyStopReason(
        _ termination: MacSustainedBenchmarkTermination?
    ) -> String {
        switch termination {
        case let .powerSourceChanged(source):
            "Sustained check stopped because the power source changed to \(source.rawValue)."
        case let .thermalSafety(state):
            "Sustained check stopped for thermal safety (\(state.rawValue))."
        case .lowPowerModeEnabled:
            "Sustained check stopped because Low Power Mode was enabled."
        case .targetDurationReached, nil:
            "Sustained check ended before its target duration."
        }
    }

    private func isWorkloadFailure(_ error: Error) -> Bool {
        error is BenchmarkKernelError
            || error is BenchmarkV7WorkloadRunnerError
            || error is BenchmarkV7MemoryWorkloadError
            || error is StorageRandomAccessBenchmarkV7.Failure
            || error is BenchmarkStatisticsError
    }

    private static func safeFailureWarning(_ failure: BenchmarkV7Failure) -> String {
        let detail: String = switch failure {
        case .alreadyRunning:
            "already running"
        case .cancelled:
            "cancelled"
        case let .timedOut(context):
            "timed out phase=\(context.phase.rawValue) category=\(context.category?.rawValue ?? "unknown")"
        case let .restartRequired(context):
            "operation termination unconfirmed \(context.detail); restart required; cleanup quarantine remains active"
        case .preflightBlocked:
            "preflight blocked"
        case let .unsupportedCategory(category):
            "unsupported category=\(category.rawValue)"
        case .invalidMeasurement:
            "invalid measurement"
        case .validationFailed:
            "validation failed"
        case .persistenceFailed:
            "persistence failed"
        case .internalFailure:
            "internal failure"
        }
        return "v7 workload failure: \(detail)"
    }

    private func runtimeWarnings(
        requested: [BenchmarkV7Category],
        runnable: [BenchmarkV7Category],
        preflight: BenchmarkV7PreflightReport,
        metrics: [BenchmarkV7MetricResult]
    ) -> [String] {
        var warnings = preflight.warnings.map(\.detail)
        let skipped = Set(requested).subtracting(runnable)
        if !skipped.isEmpty {
            warnings.append("Skipped blocked categories: \(skipped.map(\.rawValue).sorted().joined(separator: ", ")).")
        }
        if runnable.contains(.display), !metrics.contains(where: { $0.manifest.category == .display }) {
            warnings.append("Display cadence was unavailable; no Display Experience metric was recorded.")
        }
        if runnable.contains(.display) {
            let expectedDisplayMetrics: Set<String> = [
                "display.effective-fps",
                "display.cadence.p50.ms",
                "display.cadence.p95.ms",
                "display.cadence.p99.ms",
                "display.cadence.jitter.ms",
            ]
            let observedDisplayMetrics = Set(metrics.lazy
                .filter { $0.manifest.category == .display }
                .map(\.manifest.id))
            let omitted = expectedDisplayMetrics.subtracting(observedDisplayMetrics).sorted()
            if !observedDisplayMetrics.isEmpty, !omitted.isEmpty {
                warnings.append("Display metrics had non-scoreable zero observations and were omitted without epsilon: \(omitted.joined(separator: ", ")).")
            }
        }
        return Array(Set(warnings)).sorted()
    }

    private static func corePassCount(for plan: BenchmarkV7Plan) -> Int {
        switch plan.kind {
        case .quick: 3
        case .standard: 10
        case .custom: 3
        case .sustained: 0
        }
    }

    private static func category(for stage: BenchmarkStage) -> BenchmarkV7Category? {
        switch stage {
        case .cpuSingle, .cpuMulti: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .diskWrite, .diskRead: .storage
        case .preflight, .finalizing: nil
        }
    }

    private static func failure(from failure: MacBenchmarkFailure) -> BenchmarkV7Failure {
        switch failure {
        case .cancelled: .cancelled
        case let .unsupported(component):
            switch component {
            case .cpuSingle, .cpuMulti: .unsupportedCategory(.cpu)
            case .gpu: .unsupportedCategory(.gpu)
            case .memory: .unsupportedCategory(.memory)
            case .diskRead, .diskWrite: .unsupportedCategory(.storage)
            }
        case .busy: .alreadyRunning
        case .safetyCheck: .preflightBlocked
        case .timedOut, .kernelFailure, .invalidResult: .validationFailed(String(describing: failure))
        }
    }

    private static func failure(
        from failure: MacSustainedBenchmarkFailure
    ) -> BenchmarkV7Failure {
        switch failure {
        case .cancelled:
            .cancelled
        case .unsupportedCPU:
            .unsupportedCategory(.cpu)
        case .unsupportedGPU:
            .unsupportedCategory(.gpu)
        case .busy:
            .alreadyRunning
        case .safetyCheck:
            .preflightBlocked
        case .insufficientSamples, .workloadFailed, .invalidResult:
            .validationFailed(String(describing: failure))
        }
    }

    private static func sustainedWorkloadID(
        for stage: MacSustainedBenchmarkStage
    ) -> String {
        switch stage {
        case .preflight: "sustained.preflight"
        case .mixedLoad: "sustained.cpu-then-gpu"
        case .coolingDown: "sustained.cooling-down"
        }
    }

    private static func sustainedMetrics(
        from result: MacSustainedBenchmarkResult
    ) throws -> [BenchmarkV7MetricResult] {
        let cpuSamples = result.windows.map { window in
            BenchmarkV7RawSample(
                value: window.cpuMultiSample.value,
                elapsedSeconds: window.cpuMultiSample.elapsedSeconds,
                wallElapsedSeconds: window.cpuMultiSample.elapsedSeconds,
                checksum: window.cpuMultiSample.checksum
            )
        }
        let gpuSamples = result.windows.map { window in
            BenchmarkV7RawSample(
                value: window.gpuRasterSample.value,
                elapsedSeconds: window.gpuRasterSample.elapsedSeconds,
                wallElapsedSeconds: window.gpuRasterSample.elapsedSeconds,
                checksum: window.gpuRasterSample.checksum
            )
        }
        let cpuStatistics = try BenchmarkStatistics.summarize(cpuSamples.map(\.value))
        let gpuStatistics = try BenchmarkStatistics.summarize(gpuSamples.map(\.value))
        return [
            BenchmarkV7MetricResult(
                manifest: BenchmarkV7MetricManifest(
                    id: "sustained.cpu.multi",
                    category: .sustained,
                    unit: "Mops/s",
                    direction: .higherIsBetter,
                    weight: 0.5,
                    workloadVersion: result.workloadVersion
                ),
                samples: cpuSamples,
                statistics: cpuStatistics
            ),
            BenchmarkV7MetricResult(
                manifest: BenchmarkV7MetricManifest(
                    id: "sustained.gpu.graphics",
                    category: .sustained,
                    unit: "Mtri/s",
                    direction: .higherIsBetter,
                    weight: 0.5,
                    workloadVersion: result.workloadVersion
                ),
                samples: gpuSamples,
                statistics: gpuStatistics
            ),
        ]
    }

    private static func versions(for plan: BenchmarkV7Plan) -> BenchmarkV7VersionManifest {
        BenchmarkV7ReferenceCatalog.versions(for: plan)
    }

    private static func coreScore(
        plan: BenchmarkV7Plan,
        metrics: [BenchmarkV7MetricResult]
    ) -> BenchmarkV7CoreScore? {
        guard let manifest = BenchmarkV7ReferenceCatalog.scoringManifest(for: plan) else {
            return nil
        }
        let measurements = Dictionary(
            uniqueKeysWithValues: metrics.map { ($0.manifest.id, $0.statistics.median) }
        )
        return try? BenchmarkV7Scoring.scoreCore(
            plan: plan,
            manifest: manifest,
            referenceSet: BenchmarkV7ReferenceCatalog.referenceSet,
            measurements: measurements
        )
    }

    private static func experienceScore(
        plan: BenchmarkV7Plan,
        metrics: [BenchmarkV7MetricResult]
    ) -> BenchmarkV7ExperienceScore? {
        guard let manifest = BenchmarkV7ReferenceCatalog.experienceManifest(for: plan) else {
            return nil
        }
        let measurements = Dictionary(
            uniqueKeysWithValues: metrics.map { ($0.manifest.id, $0.statistics.median) }
        )
        return try? BenchmarkV7Scoring.scoreExperience(
            plan: plan,
            manifest: manifest,
            referenceSet: BenchmarkV7ReferenceCatalog.referenceSet,
            measurements: measurements
        )
    }

    private static func confidence(
        plan: BenchmarkV7Plan,
        metrics: [BenchmarkV7MetricResult],
        preflight: BenchmarkV7PreflightReport,
        forcedPreflightContinuation: Bool,
        runtimeWarnings: [String]
    ) -> BenchmarkV7Confidence {
        let coreMetrics = metrics.filter {
            BenchmarkV7Category.corePerformance.contains($0.manifest.category)
        }
        let coreCategories = Set(coreMetrics.map(\.manifest.category))
        let maximumRelativeMAD = coreMetrics
            .map(\.statistics.relativeMedianAbsoluteDeviation)
            .max()
        var reasons: [String] = []
        if coreCategories.count < BenchmarkV7Category.corePerformance.count {
            reasons.append("One or more Core categories are unavailable.")
        }
        if let maximumRelativeMAD, maximumRelativeMAD > 0.05 {
            reasons.append("Core relative MAD exceeds 5%.")
        }
        if preflight.lowPowerModeEnabled {
            reasons.append("Low Power Mode was enabled.")
        }
        if preflight.thermalState == .fair {
            reasons.append("Thermal state was fair rather than nominal.")
        }
        if preflight.backgroundLoadRatio ?? 0 >= BenchmarkV7PreflightService.highBackgroundLoadRatio {
            reasons.append("Background load was high during preflight.")
        }
        if forcedPreflightContinuation {
            reasons.append("The user forced continuation past preflight.")
        }
        reasons.append(contentsOf: runtimeWarnings)

        let rating: BenchmarkV7ConfidenceRating
        if forcedPreflightContinuation
            || preflight.lowPowerModeEnabled
            || preflight.thermalState == .fair
            || coreCategories.count < BenchmarkV7Category.corePerformance.count
            || (maximumRelativeMAD ?? .infinity) > 0.10 {
            rating = .low
        } else if !reasons.isEmpty || (maximumRelativeMAD ?? .infinity) > 0.02 {
            rating = .medium
        } else {
            rating = .high
        }
        return BenchmarkV7Confidence(
            rating: rating,
            maximumRelativeMAD: maximumRelativeMAD,
            reasons: Array(Set(reasons)).sorted()
        )
    }

    private static func metrics(
        from runs: [MacBenchmarkRawResult],
        plan: BenchmarkV7Plan
    ) throws -> [BenchmarkV7MetricResult] {
        let definitions = [
            (BenchmarkComponent.cpuSingle, "cpu.single", BenchmarkV7Category.cpu, "Mops/s", 0.5),
            (BenchmarkComponent.cpuMulti, "cpu.multi", BenchmarkV7Category.cpu, "Mops/s", 0.5),
            (BenchmarkComponent.gpu, "gpu.graphics", BenchmarkV7Category.gpu, "Mtri/s", 1.0),
            (BenchmarkComponent.memory, "memory.copy", BenchmarkV7Category.memory, "GB/s", 1.0),
            (BenchmarkComponent.diskRead, "storage.sequentialRead", BenchmarkV7Category.storage, "GB/s", 0.5),
            (BenchmarkComponent.diskWrite, "storage.sequentialWrite", BenchmarkV7Category.storage, "GB/s", 0.5),
        ]
        return try definitions.compactMap { component, id, category, unit, weight in
            guard plan.categories.contains(category) else { return nil }
            let sourceSamples = runs.flatMap { result in
                result.measurementsByComponent[component]?.samples ?? []
            }
            guard !sourceSamples.isEmpty else { return nil }
            let samples = sourceSamples.map {
                BenchmarkV7RawSample(
                    value: $0.value,
                    elapsedSeconds: $0.elapsedSeconds,
                    wallElapsedSeconds: nil,
                    checksum: $0.checksum
                )
            }
            let statistics = try BenchmarkStatistics.summarize(samples.map(\.value))
            return BenchmarkV7MetricResult(
                manifest: BenchmarkV7MetricManifest(
                    id: id,
                    category: category,
                    unit: unit,
                    direction: .higherIsBetter,
                    weight: weight,
                    workloadVersion: plan.workloadVersion
                ),
                samples: samples,
                statistics: statistics
            )
        }
    }
}

private enum BenchmarkV7CoordinatorError: Error, Sendable {
    case legacyFailure(BenchmarkV7Failure)
    case sustainedFailure(MacSustainedBenchmarkFailure)
    case invalidLegacyResult
    case sustainedEndedBeforeTarget(MacSustainedBenchmarkTermination?)
    case noRunner
}

private struct BenchmarkV7TimedOutFault: Error, Sendable {
    let context: BenchmarkV7TimeoutContext
}

private struct BenchmarkV7TimerFault: Error, Sendable {
    let context: BenchmarkV7TimeoutContext
}

private actor BenchmarkV7TimedProgressRelay {
    private let sessionID: UUID
    private let callback: BenchmarkV7Coordinator.ProgressHandler
    private var context: BenchmarkV7TimeoutContext
    private var isOpen = true

    init(
        sessionID: UUID,
        fallbackContext: BenchmarkV7TimeoutContext,
        callback: @escaping BenchmarkV7Coordinator.ProgressHandler
    ) {
        self.sessionID = sessionID
        context = fallbackContext
        self.callback = callback
    }

    func emit(
        category: BenchmarkV7Category?,
        workloadID: String,
        repetition: Int,
        progress: Double
    ) async {
        guard isOpen else { return }
        context = BenchmarkV7TimeoutContext(
            phase: .running,
            category: category,
            workloadID: workloadID
        )
        await callback(.phase(
            .running,
            sessionID: sessionID,
            category: category,
            workloadID: workloadID,
            repetition: repetition,
            progress: progress
        ))
    }

    func timeoutContext() -> BenchmarkV7TimeoutContext { context }

    func close() { isOpen = false }

}

extension BenchmarkV7Coordinator {
    private func runMSeries(sessionID: UUID, targetDirectory: URL,
                            progress: @escaping ProgressHandler) async -> BenchmarkV7Result {
        let plan = MSeriesProtocol.officialPlan
        var preflight = Self.fallbackPreflight(targetDirectory: targetDirectory)
        func envelope(_ payload: MSeriesResult?, failure: BenchmarkV7Failure?) -> BenchmarkV7Result {
            BenchmarkV7Result(mSeries: payload,
                session: BenchmarkV7Session(id: sessionID, plan: plan, storageTarget: preflight.storageTarget),
                preflight: preflight, environment: environment(for: preflight),
                hardwareProfile: hardwareProfileProvider.capture(), versions: MSeriesProtocol.versions,
                metrics: [], coreScore: nil,
                runtimeWarnings: ["Calibration unavailable: raw-only", "Extensions pending implementation"],
                completionStatus: payload?.cancelled == true ? .cancelled :
                    (payload?.isCompleteCore == true ? .completed : .partiallyCompleted),
                completedAt: payload?.completedAt, failure: failure)
        }
        guard activeSessionID == nil, cleanupSessionID == nil, restartRequiredContext == nil,
              let heavyWorkCoordinator else { return envelope(nil, failure: .alreadyRunning) }
        activeSessionID = sessionID
        defer { activeSessionID = nil }
        let lease: HeavyWorkCoordinator.Lease
        do { lease = try await heavyWorkCoordinator.acquire(owner: .benchmark) }
        catch { return envelope(nil, failure: .alreadyRunning) }
        // No detached worker is abandoned on cancellation. Release happens only
        // after run returns, which includes command-buffer drain and cleanup.
        preflight = await preflightService.capture(plan: plan, categories: plan.categories, targetDirectory: targetDirectory)
        if Task.isCancelled {
            await heavyWorkCoordinator.release(lease)
            return envelope(nil, failure: .cancelled)
        }
        if preflight.thermalState == .serious || preflight.thermalState == .critical {
            await heavyWorkCoordinator.release(lease)
            return envelope(nil, failure: .preflightBlocked)
        }
        let result = await MSeriesCoreRunner.run(sessionID: sessionID, root: targetDirectory,
                                                resourceJournal: resourceJournal) { token, id, index in
            let category: BenchmarkV7Category = id.hasPrefix("cpu.") ? .cpu :
                id.hasPrefix("gpu.") ? .gpu : id.hasPrefix("memory.") ? .memory : .storage
            await progress(.phase(.running, sessionID: token, category: category,
                workloadID: id, progress: min(0.98, Double(index) / 19)))
        }
        await heavyWorkCoordinator.release(lease)
        return envelope(result, failure: result.cancelled ? .cancelled :
            (result.globalFailure != nil ? .validationFailed(result.globalFailure!) : nil))
    }

}
