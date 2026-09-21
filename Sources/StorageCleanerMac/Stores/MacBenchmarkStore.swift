import Foundation

enum MacBenchmarkStoreNotice: Equatable, Sendable {
    case historyLoadFailed
    case historySaveFailed
    case resultRejected
}

enum MacAcceleratorBenchmarkStoreNotice: Equatable, Sendable {
    case historySaveFailed
    case resultRejected
}

enum MacBenchmarkSuiteStep: Int, Equatable, Sendable {
    case standard = 1
    case accelerator
    case sustained
}

enum MacBenchmarkSuiteOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(MacBenchmarkSuiteStep)
}

@MainActor
private final class BenchmarkV7PromotionRevocationStore {
    private static let key = "benchmark.v7.unconfirmedPromotionRecordIDs"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func contains(_ recordID: UUID?) -> Bool {
        guard let recordID else { return false }
        return identifiers.contains(recordID.uuidString)
    }

    func revoke(_ recordID: UUID) -> Bool {
        var values = identifiers
        values.insert(recordID.uuidString)
        defaults.set(Array(values).sorted(), forKey: Self.key)
        return defaults.synchronize()
    }

    func acknowledge(_ recordID: UUID) -> Bool {
        let previous = identifiers
        var values = previous
        values.remove(recordID.uuidString)
        defaults.set(Array(values).sorted(), forKey: Self.key)
        guard defaults.synchronize() else {
            defaults.set(Array(previous).sorted(), forKey: Self.key)
            _ = defaults.synchronize()
            return false
        }
        return true
    }

    private var identifiers: Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }
}

@MainActor
final class MacBenchmarkStore: ObservableObject {
    let selectedProfile: BenchmarkProfile = .standard
    @Published private(set) var state: MacBenchmarkState = .idle
    @Published private(set) var progress: MacBenchmarkProgress?
    @Published private(set) var latestResult: MacBenchmarkResult?
    @Published private(set) var history: [MacBenchmarkResult] = []
    @Published private(set) var rawOnlyReason: MacBenchmarkRawOnlyReason?
    @Published private(set) var notice: MacBenchmarkStoreNotice?
    @Published private(set) var acceleratorState: MacAcceleratorBenchmarkState = .idle
    @Published private(set) var acceleratorProgress: MacAcceleratorBenchmarkProgress?
    @Published private(set) var latestAcceleratorResult: MacAcceleratorBenchmarkResult?
    @Published private(set) var acceleratorHistory: [MacAcceleratorBenchmarkResult] = []
    @Published private(set) var acceleratorNotice: MacAcceleratorBenchmarkStoreNotice?
    @Published private(set) var sustainedState: MacSustainedBenchmarkState = .idle
    @Published private(set) var sustainedProgress: MacSustainedBenchmarkProgress?
    @Published private(set) var latestSustainedResult: MacSustainedBenchmarkResult?
    @Published private(set) var suiteStep: MacBenchmarkSuiteStep?
    @Published private(set) var suiteOutcome: MacBenchmarkSuiteOutcome?
    @Published private(set) var v7State: BenchmarkV7State = .idle
    @Published private(set) var v7LatestResult: BenchmarkV7Result?
    @Published private(set) var v7History: [BenchmarkV7Result] = []
    @Published private(set) var v7Preflight: BenchmarkV7PreflightReport?
    @Published private(set) var isV7Preflighting = false
    @Published private(set) var v7HistoryStatus: BenchmarkV7HistoryLoadStatus = .missing

    private struct Operation {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private struct V7HistoryReload: Sendable {
        let records: [BenchmarkV7Result]
        let status: BenchmarkV7HistoryLoadStatus
    }

    private let service: any MacBenchmarkServicing
    private let lifecycleCleaner: any MacBenchmarkLifecycleCleaning
    private let resultProcessor: MacBenchmarkResultProcessor
    private let historyRepository: any MacBenchmarkHistoryPersisting
    private let acceleratorService: (any MacAcceleratorBenchmarkServicing)?
    private let acceleratorHistoryRepository:
        (any MacAcceleratorBenchmarkHistoryPersisting)?
    private let sustainedService: (any MacSustainedBenchmarkServicing)?
    private let v7Coordinator: BenchmarkV7Coordinator
    private let v7HistoryRepository: any BenchmarkV7HistoryPersisting
    private let v7PromotionRevocations: BenchmarkV7PromotionRevocationStore
    private let v7PersistenceTimeout: Duration
    private let v7TimeoutSleep: @Sendable (Duration) async throws -> Void
    private let onCompletedResult: ((MacBenchmarkResult, [MacBenchmarkResult]) -> Void)?
    private var operation: Operation?
    private var acceleratorOperation: Operation?
    private var sustainedOperation: Operation?
    private var v7Operation: Operation?
    private var v7PreflightOperation: Operation?
    private var suiteTask: Task<Void, Never>?
    private var historyLoadGeneration: UUID?
    private var persistenceGeneration: UUID?
    private var acceleratorPersistenceGeneration: UUID?
    private var v7HistoryLoadGeneration: UUID?
    private var v7CancellationRequestedAt: Date?
    private var didPrepareLifecycleOnLaunch = false

    init(
        service: any MacBenchmarkServicing,
        resultProcessor: MacBenchmarkResultProcessor,
        lifecycleCleaner: any MacBenchmarkLifecycleCleaning =
            SystemMacBenchmarkLifecycleCleaner(),
        historyRepository: (any MacBenchmarkHistoryPersisting)? = nil,
        acceleratorService: (any MacAcceleratorBenchmarkServicing)? = nil,
        acceleratorHistoryRepository:
            (any MacAcceleratorBenchmarkHistoryPersisting)? = nil,
        sustainedService: (any MacSustainedBenchmarkServicing)? = nil,
        v7Coordinator: BenchmarkV7Coordinator? = nil,
        v7HistoryRepository: (any BenchmarkV7HistoryPersisting)? = nil,
        v7PromotionRevocationDefaults: UserDefaults = .standard,
        v7PersistenceTimeout: Duration = BenchmarkV7TimeoutPolicy.standard.persistence,
        v7TimeoutSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onCompletedResult: ((MacBenchmarkResult, [MacBenchmarkResult]) -> Void)? = nil
    ) {
        self.service = service
        self.resultProcessor = resultProcessor
        self.lifecycleCleaner = lifecycleCleaner
        self.historyRepository = historyRepository
            ?? MacBenchmarkHistoryRepository()
        self.acceleratorService = acceleratorService
        self.acceleratorHistoryRepository = acceleratorHistoryRepository
        self.sustainedService = sustainedService
        self.v7Coordinator = v7Coordinator
            ?? BenchmarkV7Coordinator(coreService: service)
        self.v7HistoryRepository = v7HistoryRepository
            ?? BenchmarkV7HistoryRepository()
        v7PromotionRevocations = BenchmarkV7PromotionRevocationStore(
            defaults: v7PromotionRevocationDefaults
        )
        self.v7PersistenceTimeout = v7PersistenceTimeout
        self.v7TimeoutSleep = v7TimeoutSleep
        self.onCompletedResult = onCompletedResult
    }

    var isRunning: Bool {
        suiteTask != nil
            || operation != nil
            || acceleratorOperation != nil
            || sustainedOperation != nil
            || v7Operation != nil
            || v7PreflightOperation != nil
    }
    var isCoreBenchmarkRunning: Bool { operation != nil }
    var isAcceleratorBenchmarkRunning: Bool { acceleratorOperation != nil }
    var isSustainedBenchmarkRunning: Bool { sustainedOperation != nil }
    var isV7BenchmarkRunning: Bool { v7Operation != nil }

    /// The only score contract that may be used to compare local V7 history.
    /// A result from an older workload, scoring, or reference-set revision
    /// stays in history for inspection, but is never mixed into a best score.
    var currentV7ScoringVersion: String {
        MSeriesProtocol.scoring
    }

    var currentComparableOfficialV7History: [BenchmarkV7Result] {
        v7History.filter(\.isCurrentComparableOfficialResult)
    }

    private var localBestEligibleOfficialV7History: [BenchmarkV7Result] {
        currentComparableOfficialV7History.filter(\.isCurrentLocalBestEligible)
    }

    var latestOfficialV7Result: BenchmarkV7Result? {
        latestV7Result(in: [v7LatestResult] + v7History.map(Optional.some))
    }

    /// Local best is deliberately derived only from records that were safely
    /// persisted on this Mac. A completed-but-unsaved transient result can be
    /// shown as the latest diagnostic result, but cannot become a best record.
    var localBestOfficialV7Result: BenchmarkV7Result? {
        bestV7Result(
            in: localBestEligibleOfficialV7History,
            score: { $0.coreScore?.overallScore }
        )
    }

    var localBestOfficialV7ResultsByCategory: [
        BenchmarkV7Category: BenchmarkV7Result
    ] {
        Dictionary(uniqueKeysWithValues: BenchmarkV7Category.corePerformance.compactMap {
            category in
            guard let result = bestV7Result(
                in: localBestEligibleOfficialV7History,
                score: { $0.coreScore?.categoryScores[category]?.score }
            ) else {
                return nil
            }
            return (category, result)
        })
    }
    var canRunCompleteSuite: Bool {
        acceleratorService != nil && sustainedService != nil
    }
    var hasVerifiedActiveBaseline: Bool {
        resultProcessor.hasVerifiedActiveBaseline
    }

    func prepareLifecycleOnLaunch() async {
        guard !didPrepareLifecycleOnLaunch else { return }
        didPrepareLifecycleOnLaunch = true
        await lifecycleCleaner.cleanupOrphanedArtifactsOnLaunch()
        await loadHistory()
        if let latestResult {
            onCompletedResult?(latestResult, history)
        }
    }

    func loadHistory() async {
        guard operation == nil,
              acceleratorOperation == nil,
              sustainedOperation == nil,
              v7Operation == nil,
              v7PreflightOperation == nil else { return }
        let generation = UUID()
        let v7Generation = UUID()
        historyLoadGeneration = generation
        v7HistoryLoadGeneration = v7Generation
        let stored = await historyRepository.load()
        let historyLoadStatus = await historyRepository.loadStatus()
        let acceleratorStored = await acceleratorHistoryRepository?.load() ?? []
        let v7Stored = await v7HistoryRepository.load()
        let v7Status = await v7HistoryRepository.loadStatus()
        guard operation == nil,
              acceleratorOperation == nil,
              sustainedOperation == nil,
              v7Operation == nil,
              historyLoadGeneration == generation else {
            return
        }
        guard v7HistoryLoadGeneration == v7Generation else { return }
        historyLoadGeneration = nil
        v7HistoryLoadGeneration = nil
        if case .failed = historyLoadStatus {
            notice = .historyLoadFailed
        } else if notice == .historyLoadFailed {
            notice = nil
        }
        let displayed = reprocessHistory(stored)
        let confirmedV7Stored = confirmedV7History(v7Stored)
        history = displayed
        acceleratorHistory = acceleratorStored
        v7History = confirmedV7Stored
        v7HistoryStatus = v7Status
        if v7LatestResult == nil {
            v7LatestResult = confirmedV7Stored.first
        }
        if latestAcceleratorResult == nil {
            latestAcceleratorResult = acceleratorStored.first
        }
        if latestResult == nil, let first = displayed.first {
            latestResult = first
            rawOnlyReason = rawOnlyReason(for: first)
        }
    }

    func start() {
        guard operation == nil,
              acceleratorOperation == nil,
              sustainedOperation == nil,
              v7Operation == nil,
              v7PreflightOperation == nil else { return }

        let generation = UUID()
        let profile = selectedProfile
        let service = self.service
        historyLoadGeneration = nil
        persistenceGeneration = nil
        notice = nil
        progress = nil
        rawOnlyReason = nil
        transition(to: .preflighting(profile: profile))

        let task = Task<Void, Never> { [weak self] in
            let rawResult = await service.run(profile: profile) { [weak self] update in
                await self?.acceptProgress(update, generation: generation)
            }
            guard !Task.isCancelled else {
                self?.finishCancelled(generation: generation)
                return
            }
            await self?.finish(rawResult, generation: generation)
        }
        operation = Operation(generation: generation, task: task)
    }

    func cancel() {
        guard let operation else { return }
        guard persistenceGeneration != operation.generation else { return }
        transition(to: .cancelling)
        operation.task.cancel()
    }

    func startV7(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category]? = nil,
        targetDirectory: URL = DiskBenchmarkKernel.defaultRootDirectory,
        forcePreflightContinuation: Bool = false
    ) {
        guard operation == nil,
              acceleratorOperation == nil,
              sustainedOperation == nil,
              v7Operation == nil,
              v7PreflightOperation == nil,
              suiteTask == nil,
              v7State.failure?.requiresApplicationRestart != true else { return }

        let generation = UUID()
        let sessionID = UUID()
        let coordinator = v7Coordinator
        historyLoadGeneration = nil
        v7HistoryLoadGeneration = nil
        v7CancellationRequestedAt = nil
        v7Preflight = nil
        v7State = .phase(.preflighting, sessionID: sessionID)

        let task = Task<Void, Never> { [weak self] in
            let result = await coordinator.run(
                sessionID: sessionID,
                plan: plan,
                categories: categories,
                targetDirectory: targetDirectory,
                forcePreflightContinuation: forcePreflightContinuation
            ) { [weak self] state in
                await self?.acceptV7State(state, generation: generation)
            }
            await self?.finishV7(result, generation: generation)
        }
        v7Operation = Operation(generation: generation, task: task)
    }

    /// Starts the one public benchmark flow. Legacy plan overloads remain for
    /// migration fixtures and tests, but no user choice is required here.
    func startOfficialBenchmark() {
        let official = OfficialBenchmarkPlan.current
        startV7(
            plan: official.plan,
            categories: official.categories,
            targetDirectory: MSeriesProtocol.temporaryRoot
        )
    }

    /// Runs the non-destructive v7 environment check without allocating a
    /// benchmark session or starting a workload. The next explicit start
    /// performs a fresh check again, so an old report can never authorize a
    /// later run after the machine state changes.
    func preflightV7(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category]? = nil,
        targetDirectory: URL = DiskBenchmarkKernel.defaultRootDirectory
    ) {
        guard operation == nil,
              acceleratorOperation == nil,
              sustainedOperation == nil,
              v7Operation == nil,
              v7PreflightOperation == nil,
              suiteTask == nil else { return }

        let generation = UUID()
        let requestedCategories = categories ?? plan.categories
        let coordinator = v7Coordinator
        v7Preflight = nil
        isV7Preflighting = true
        let task = Task<Void, Never> { [weak self] in
            let outcome = await coordinator.preflightOutcome(
                plan: plan,
                categories: requestedCategories,
                targetDirectory: targetDirectory
            )
            self?.finishV7Preflight(outcome, generation: generation)
        }
        v7PreflightOperation = Operation(generation: generation, task: task)
    }

    func cancelV7() {
        guard let v7Operation else { return }
        // Once persistence starts, cancellation can no longer be made durable
        // without risking that a committed success reappears after relaunch.
        // The UI presents this short phase as an uninterruptible final save.
        guard v7State.phase != .persisting else { return }
        if v7CancellationRequestedAt == nil {
            v7CancellationRequestedAt = Date()
        }
        v7State = .phase(
            .cancelling,
            sessionID: v7State.sessionID ?? v7Operation.generation
        )
        v7Operation.task.cancel()
    }

    /// Deletes one locally persisted V7 record. Running or preflighting work
    /// is never interrupted by a history action; the caller may retry once the
    /// app-scoped benchmark session is idle.
    @discardableResult
    func deleteV7HistoryRecord(recordID: UUID) async -> Bool {
        guard v7Operation == nil, v7PreflightOperation == nil else { return false }

        let generation = UUID()
        v7HistoryLoadGeneration = generation
        do {
            let deleted = try await v7HistoryRepository.delete(recordID: recordID)
            let stored = await v7HistoryRepository.load()
            let status = await v7HistoryRepository.loadStatus()
            guard v7Operation == nil,
                  v7PreflightOperation == nil,
                  v7HistoryLoadGeneration == generation else {
                return false
            }

            v7HistoryLoadGeneration = nil
            let confirmedStored = confirmedV7History(stored)
            v7History = confirmedStored
            v7HistoryStatus = status
            if deleted {
                _ = v7PromotionRevocations.acknowledge(recordID)
            }
            if deleted, v7LatestResult?.recordID == recordID {
                v7LatestResult = latestV7Result(
                    in: confirmedStored.map(Optional.some)
                )
            }
            return deleted
        } catch {
            guard v7HistoryLoadGeneration == generation else { return false }
            v7HistoryLoadGeneration = nil
            v7HistoryStatus = .failed
            return false
        }
    }

    /// JSON is generated only from the loaded local history, never from a
    /// network or a transient unsaved benchmark result.
    func exportV7HistoryRecord(recordID: UUID) -> Data? {
        guard let result = v7History.first(where: { $0.recordID == recordID }) else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(result)
    }

    func startAcceleratorBenchmark() {
        guard operation == nil,
              acceleratorOperation == nil,
              sustainedOperation == nil,
              v7Operation == nil,
              v7PreflightOperation == nil,
              let acceleratorService else { return }

        let generation = UUID()
        historyLoadGeneration = nil
        acceleratorPersistenceGeneration = nil
        acceleratorNotice = nil
        acceleratorProgress = nil
        acceleratorState = .preflighting

        let task = Task<Void, Never> { [weak self] in
            let result = await acceleratorService.run { [weak self] update in
                await self?.acceptAcceleratorProgress(
                    update,
                    generation: generation
                )
            }
            guard !Task.isCancelled else {
                self?.finishAcceleratorCancelled(generation: generation)
                return
            }
            await self?.finishAccelerator(result, generation: generation)
        }
        acceleratorOperation = Operation(generation: generation, task: task)
    }

    func cancelAcceleratorBenchmark() {
        guard let acceleratorOperation else { return }
        guard acceleratorPersistenceGeneration != acceleratorOperation.generation else {
            return
        }
        acceleratorState = .cancelling
        acceleratorOperation.task.cancel()
    }

    func startSustainedBenchmark() {
        guard operation == nil,
              acceleratorOperation == nil,
              sustainedOperation == nil,
              v7Operation == nil,
              v7PreflightOperation == nil,
              let sustainedService else { return }

        let generation = UUID()
        historyLoadGeneration = nil
        sustainedProgress = nil
        sustainedState = .preflighting

        let task = Task<Void, Never> { [weak self] in
            let result = await sustainedService.run(
                profile: .standard,
                coolingMode: .systemAutomatic
            ) { [weak self] update in
                await self?.acceptSustainedProgress(update, generation: generation)
            }
            guard !Task.isCancelled else {
                self?.finishSustainedCancelled(generation: generation)
                return
            }
            self?.finishSustained(result, generation: generation)
        }
        sustainedOperation = Operation(generation: generation, task: task)
    }

    func cancelSustainedBenchmark() {
        guard let sustainedOperation else { return }
        sustainedState = .cancelling
        sustainedOperation.task.cancel()
    }

    func startCompleteSuite() {
        guard suiteTask == nil, !isRunning, canRunCompleteSuite else { return }
        suiteOutcome = nil
        suiteStep = .standard
        suiteTask = Task { [weak self] in
            await self?.runCompleteSuite()
        }
    }

    /// Requests cooperative cancellation for whichever benchmark mode owns the
    /// shared app-scoped session. Safe to call repeatedly during app shutdown.
    func cancelAll() {
        suiteTask?.cancel()
        cancelV7Preflight()
        cancel()
        cancelAcceleratorBenchmark()
        cancelSustainedBenchmark()
        cancelV7()
    }

    func waitUntilIdle() async {
        if let suiteTask {
            await suiteTask.value
            return
        }
        await waitUntilCurrentBenchmarkIdle()
    }

    private func waitUntilCurrentBenchmarkIdle() async {
        if let operation {
            await operation.task.value
        }
        if let acceleratorOperation {
            await acceleratorOperation.task.value
        }
        if let sustainedOperation {
            await sustainedOperation.task.value
        }
        if let v7Operation {
            await v7Operation.task.value
        }
        if let v7PreflightOperation {
            await v7PreflightOperation.task.value
        }
    }

    private func runCompleteSuite() async {
        start()
        await waitUntilCurrentBenchmarkIdle()
        guard !Task.isCancelled else {
            finishCompleteSuite(outcome: .cancelled)
            return
        }
        guard state == .completed else {
            finishCompleteSuite(outcome: suiteOutcome(for: state, step: .standard))
            return
        }

        suiteStep = .accelerator
        startAcceleratorBenchmark()
        await waitUntilCurrentBenchmarkIdle()
        guard !Task.isCancelled else {
            finishCompleteSuite(outcome: .cancelled)
            return
        }
        guard acceleratorState == .completed else {
            finishCompleteSuite(
                outcome: suiteOutcome(
                    for: acceleratorState,
                    step: .accelerator
                )
            )
            return
        }

        suiteStep = .sustained
        startSustainedBenchmark()
        await waitUntilCurrentBenchmarkIdle()
        guard !Task.isCancelled else {
            finishCompleteSuite(outcome: .cancelled)
            return
        }
        finishCompleteSuite(
            outcome: suiteOutcome(for: sustainedState, step: .sustained)
        )
    }

    private func finishCompleteSuite(outcome: MacBenchmarkSuiteOutcome) {
        suiteOutcome = outcome
        suiteStep = nil
        suiteTask = nil
        if outcome == .completed, let latestResult {
            onCompletedResult?(latestResult, history)
        }
    }

    private func acceptV7State(
        _ next: BenchmarkV7State,
        generation: UUID
    ) {
        guard v7Operation?.generation == generation else { return }
        guard v7State.phase != .cancelling
            || next.phase == .cancelling
            || next.phase == .cancelled else { return }
        v7State = next
    }

    private func finishV7Preflight(
        _ outcome: BenchmarkV7PreflightOutcome,
        generation: UUID
    ) {
        guard v7PreflightOperation?.generation == generation else { return }
        v7Preflight = outcome.report
        isV7Preflighting = false
        v7PreflightOperation = nil
        if let failure = outcome.failure {
            v7State = .failed(failure, sessionID: generation)
        } else {
            v7State = .idle
        }
    }

    private func cancelV7Preflight() {
        guard let v7PreflightOperation else { return }
        v7PreflightOperation.task.cancel()
        self.v7PreflightOperation = nil
        isV7Preflighting = false
    }

    private func finishV7(
        _ result: BenchmarkV7Result,
        generation: UUID
    ) async {
        guard v7Operation?.generation == generation else { return }
        let wasCancelled = isV7CancellationRequested(generation: generation)
        var terminalResult = wasCancelled
            ? cancelledV7Result(from: result)
            : result
        v7Preflight = terminalResult.preflight
        if !wasCancelled, terminalResult.failure == nil {
            v7State = .phase(.persisting, sessionID: terminalResult.session.id)
        }
        var saveFailed = false
        var shouldReloadHistory = true
        if terminalResult.isPersistable {
            // Persist an ineligible provisional record first. If this bounded
            // save returns late, a relaunch can never mistake it for a completed
            // score. A timely save is promoted with one atomic replacement.
            let requiresPromotion = terminalResult.failure == nil
            let resultToSave = requiresPromotion
                ? failedV7Result(from: terminalResult, failure: .persistenceFailed)
                : terminalResult
            let saveOutcome = await BenchmarkTimedOperation.run(
                timeout: v7PersistenceTimeout,
                sleep: v7TimeoutSleep
            ) { [v7HistoryRepository] in
                try await v7HistoryRepository.save(resultToSave)
            }
            switch saveOutcome {
            case .success:
                if requiresPromotion {
                    guard let provisionalRecordID = resultToSave.recordID else {
                        saveFailed = true
                        terminalResult = failedV7Result(
                            from: terminalResult,
                            failure: .persistenceFailed
                        )
                        break
                    }
                    let context = BenchmarkV7TimeoutContext(
                        phase: .persisting,
                        category: nil,
                        workloadID: "history-promote"
                    )
                    let resultToPromote = terminalResult
                    guard let promotedRecordID = resultToPromote.recordID,
                          v7PromotionRevocations.revoke(promotedRecordID) else {
                        saveFailed = true
                        terminalResult = failedV7Result(
                            from: terminalResult,
                            failure: .persistenceFailed
                        )
                        break
                    }
                    let promotionOutcome = await BenchmarkTimedOperation.run(
                        timeout: v7PersistenceTimeout,
                        sleep: v7TimeoutSleep
                    ) { [v7HistoryRepository] in
                        try await v7HistoryRepository.replace(
                            recordID: provisionalRecordID,
                            with: resultToPromote
                        )
                    }
                    switch promotionOutcome {
                    case .success:
                        if !v7PromotionRevocations.acknowledge(promotedRecordID) {
                            saveFailed = true
                            terminalResult = failedV7Result(
                                from: terminalResult,
                                failure: .persistenceFailed
                            )
                        }
                    case .failure:
                        saveFailed = true
                        terminalResult = failedV7Result(
                            from: terminalResult,
                            failure: .persistenceFailed
                        )
                    case let .timedOut(lateOperation),
                         let .cancelled(lateOperation),
                         let .timerFailure(lateOperation):
                        terminalResult = failedV7Result(
                            from: terminalResult,
                            failure: .restartRequired(context)
                        )
                        shouldReloadHistory = false
                        v7HistoryStatus = .failed
                        handOffV7DiscardedOperation(lateOperation)
                    }
                }
            case .failure:
                saveFailed = true
                // A completed score that could not be committed is not a
                // successful product result. Keep only an explicit
                // persistence diagnostic so the latest projection cannot
                // surface an unsaved score as success.
                terminalResult = failedV7Result(
                    from: terminalResult,
                    failure: .persistenceFailed
                )
            case let .timedOut(lateOperation):
                terminalResult = timedOutV7Result(
                    from: terminalResult,
                    context: BenchmarkV7TimeoutContext(
                        phase: .persisting,
                        category: nil,
                        workloadID: "history-save"
                    )
                )
                shouldReloadHistory = false
                handOffV7Persistence(
                    lateOperation,
                    originalRecordID: resultToSave.recordID,
                    replacement: terminalResult,
                    generation: generation
                )
            case let .cancelled(lateOperation):
                terminalResult = cancelledV7Result(from: terminalResult)
                shouldReloadHistory = false
                handOffV7Persistence(
                    lateOperation,
                    originalRecordID: resultToSave.recordID,
                    replacement: terminalResult,
                    generation: generation
                )
            case let .timerFailure(lateOperation):
                terminalResult = failedV7Result(
                    from: terminalResult,
                    failure: .persistenceFailed
                )
                shouldReloadHistory = false
                handOffV7Persistence(
                    lateOperation,
                    originalRecordID: resultToSave.recordID,
                    replacement: terminalResult,
                    generation: generation
                )
            }

            if shouldReloadHistory {
                let reloadOutcome = await BenchmarkTimedOperation.run(
                    timeout: v7PersistenceTimeout,
                    sleep: v7TimeoutSleep
                ) { [v7HistoryRepository] in
                    let records = await v7HistoryRepository.load()
                    let status = await v7HistoryRepository.loadStatus()
                    return V7HistoryReload(records: records, status: status)
                }
                switch reloadOutcome {
                case let .success(snapshot):
                    guard v7Operation?.generation == generation else { return }
                    v7History = confirmedV7History(snapshot.records)
                    v7HistoryStatus = snapshot.status
                case .failure:
                    terminalResult = failedV7Result(
                        from: terminalResult,
                        failure: .persistenceFailed
                    )
                case let .timedOut(lateOperation),
                     let .timerFailure(lateOperation):
                    handOffV7DiscardedOperation(lateOperation)
                    terminalResult = failedV7Result(
                        from: terminalResult,
                        failure: .persistenceFailed
                    )
                case let .cancelled(lateOperation):
                    handOffV7DiscardedOperation(lateOperation)
                    // Cancellation is latched before persistence. Once a result
                    // has been committed, a cancelled reload must not rewrite it.
                }
            }
        }
        // Keep the terminal record available to diagnostics. The public
        // latest-result projection filters it through the current compatible
        // official-result predicate.
        v7LatestResult = terminalResult
        v7Operation = nil
        if let failure = terminalResult.failure {
            if failure == .cancelled, saveFailed {
                v7State = .failed(
                    .persistenceFailed,
                    sessionID: terminalResult.session.id
                )
            } else {
                v7State = failure == .cancelled
                    ? .phase(.cancelled, sessionID: terminalResult.session.id)
                    : .failed(failure, sessionID: terminalResult.session.id)
            }
        } else if saveFailed {
            v7State = .failed(.persistenceFailed, sessionID: terminalResult.session.id)
        } else {
            v7State = .phase(.completed, sessionID: terminalResult.session.id)
        }
    }

    private func isV7CancellationRequested(generation: UUID) -> Bool {
        guard v7Operation?.generation == generation else { return false }
        return v7State.phase == .cancelling
            || v7Operation?.task.isCancelled == true
    }

    private func cancelledV7Result(from result: BenchmarkV7Result) -> BenchmarkV7Result {
        let workloadExecutions = result.workloadExecutions.map { records in
            guard let cancellationDate = v7CancellationRequestedAt else { return records }
            return records.compactMap { record in
                guard record.startedAt < cancellationDate else { return nil }
                guard record.endedAt >= cancellationDate else { return record }
                return BenchmarkV7WorkloadExecutionRecord(
                    category: record.category,
                    workloadID: record.workloadID,
                    repetition: record.repetition,
                    startedAt: record.startedAt,
                    endedAt: cancellationDate,
                    elapsedSeconds: max(0, cancellationDate.timeIntervalSince(record.startedAt)),
                    status: .cancelled,
                    failureReason: "The workload was cancelled."
                )
            }
        }
        return BenchmarkV7Result(
            mSeries: result.mSeries,
            session: result.session,
            preflight: result.preflight,
            environment: result.environment,
            hardwareProfile: result.hardwareProfile,
            versions: result.versions,
            metrics: [],
            coreScore: nil,
            experienceScore: nil,
            sustainedResult: nil,
            confidence: nil,
            runtimeWarnings: result.runtimeWarnings,
            workloadExecutions: workloadExecutions,
            completedAt: nil,
            failure: .cancelled
        )
    }

    private func timedOutV7Result(
        from result: BenchmarkV7Result,
        context: BenchmarkV7TimeoutContext
    ) -> BenchmarkV7Result {
        failedV7Result(from: result, failure: .timedOut(context))
    }

    private func failedV7Result(
        from result: BenchmarkV7Result,
        failure: BenchmarkV7Failure
    ) -> BenchmarkV7Result {
        BenchmarkV7Result(
            mSeries: result.mSeries,
            session: result.session,
            preflight: result.preflight,
            environment: result.environment,
            hardwareProfile: result.hardwareProfile,
            versions: result.versions,
            metrics: result.metrics,
            coreScore: nil,
            experienceScore: nil,
            sustainedResult: nil,
            confidence: nil,
            runtimeWarnings: result.runtimeWarnings,
            workloadFailure: result.workloadFailure,
            workloadExecutions: result.workloadExecutions,
            completedAt: nil,
            failure: failure
        )
    }

    private func handOffV7Persistence(
        _ lateOperation: BenchmarkLateOperation<Void>,
        originalRecordID: UUID?,
        replacement: BenchmarkV7Result,
        generation: UUID
    ) {
        let repository = v7HistoryRepository
        Task {
            let outcome = await lateOperation.result()
            let recordID: UUID? = if case .success = outcome {
                originalRecordID
            } else {
                nil
            }
            self.handOffV7Replacement(
                originalRecordID: recordID,
                replacement: replacement,
                repository: repository,
                generation: generation
            )
        }
    }

    private func handOffV7Replacement(
        originalRecordID: UUID?,
        replacement: BenchmarkV7Result,
        repository: (any BenchmarkV7HistoryPersisting)? = nil,
        generation: UUID
    ) {
        let repository = repository ?? v7HistoryRepository
        let timeout = v7PersistenceTimeout
        let sleep = v7TimeoutSleep
        Task {
            let outcome = await BenchmarkTimedOperation.run(
                timeout: timeout,
                sleep: sleep
            ) {
                if let originalRecordID {
                    try await repository.replace(
                        recordID: originalRecordID,
                        with: replacement
                    )
                } else {
                    try await repository.save(replacement)
                }
            }
            switch outcome {
            case .success:
                break
            case .failure:
                self.markV7ReplacementFailure(
                    replacement: replacement,
                    generation: generation
                )
            case let .timedOut(lateOperation),
                 let .cancelled(lateOperation),
                 let .timerFailure(lateOperation):
                self.markV7ReplacementFailure(
                    replacement: replacement,
                    generation: generation
                )
                self.handOffV7DiscardedOperation(lateOperation)
            }
        }
    }

    private func markV7ReplacementFailure(
        replacement: BenchmarkV7Result,
        generation: UUID
    ) {
        v7HistoryStatus = .failed
        guard v7Operation == nil || v7Operation?.generation == generation,
              v7LatestResult?.session.id == replacement.session.id else { return }
        let failed = failedV7Result(from: replacement, failure: .persistenceFailed)
        v7LatestResult = failed
        v7State = .failed(.persistenceFailed, sessionID: failed.session.id)
    }

    private func handOffV7DiscardedOperation<Value: Sendable>(
        _ lateOperation: BenchmarkLateOperation<Value>
    ) {
        Task { await lateOperation.wait() }
    }

    private func suiteOutcome(
        for state: MacBenchmarkState,
        step: MacBenchmarkSuiteStep
    ) -> MacBenchmarkSuiteOutcome {
        if state == .cancelled { return .cancelled }
        return .failed(step)
    }

    private func suiteOutcome(
        for state: MacAcceleratorBenchmarkState,
        step: MacBenchmarkSuiteStep
    ) -> MacBenchmarkSuiteOutcome {
        if state == .cancelled { return .cancelled }
        return .failed(step)
    }

    private func suiteOutcome(
        for state: MacSustainedBenchmarkState,
        step: MacBenchmarkSuiteStep
    ) -> MacBenchmarkSuiteOutcome {
        if state == .completed { return .completed }
        if state == .cancelled { return .cancelled }
        return .failed(step)
    }

    private func acceptSustainedProgress(
        _ update: MacSustainedBenchmarkProgress,
        generation: UUID
    ) {
        guard sustainedOperation?.generation == generation,
              sustainedState != .cancelling,
              update.completedWindowCount >= 0,
              update.elapsedSeconds.isFinite,
              update.elapsedSeconds >= 0,
              update.targetDurationSeconds.isFinite,
              update.targetDurationSeconds > 0 else { return }

        let previousElapsed = sustainedProgress?.elapsedSeconds ?? 0
        guard update.elapsedSeconds >= previousElapsed else { return }
        sustainedProgress = update
        switch update.stage {
        case .preflight:
            sustainedState = .preflighting
        case .mixedLoad:
            sustainedState = .running(progress: update.progress)
        case .coolingDown:
            sustainedState = .coolingDown
        }
    }

    private func finishSustained(
        _ result: MacSustainedBenchmarkResult,
        generation: UUID
    ) {
        guard sustainedOperation?.generation == generation else { return }
        sustainedOperation = nil
        sustainedProgress = nil
        if let failure = result.failure {
            sustainedState = failure == .cancelled ? .cancelled : .failed(failure)
            return
        }
        guard result.isComplete else {
            sustainedState = .failed(.invalidResult)
            return
        }
        latestSustainedResult = result
        sustainedState = .completed
    }

    private func finishSustainedCancelled(generation: UUID) {
        guard sustainedOperation?.generation == generation else { return }
        sustainedOperation = nil
        sustainedProgress = nil
        sustainedState = .cancelled
    }

    private func acceptAcceleratorProgress(
        _ update: MacAcceleratorBenchmarkProgress,
        generation: UUID
    ) {
        guard acceleratorOperation?.generation == generation,
              acceleratorState != .cancelling,
              update.completedSampleCount >= 0,
              update.totalSampleCount > 0,
              update.completedSampleCount <= update.totalSampleCount,
              update.elapsedSeconds.isFinite,
              update.elapsedSeconds >= 0 else { return }

        let previousCompleted = acceleratorProgress?.completedSampleCount ?? 0
        guard update.completedSampleCount >= previousCompleted else { return }
        acceleratorProgress = update
        acceleratorState = .running(
            metric: update.metric,
            progress: update.progress
        )
    }

    private func finishAccelerator(
        _ result: MacAcceleratorBenchmarkResult,
        generation: UUID
    ) async {
        guard acceleratorOperation?.generation == generation else { return }
        if let failure = result.failure {
            acceleratorPersistenceGeneration = nil
            acceleratorOperation = nil
            acceleratorProgress = nil
            acceleratorState = failure == .cancelled ? .cancelled : .failed(failure)
            return
        }
        guard result.isComplete else {
            acceleratorPersistenceGeneration = nil
            acceleratorOperation = nil
            acceleratorProgress = nil
            acceleratorNotice = .resultRejected
            acceleratorState = .failed(.invalidResult)
            return
        }
        guard !Task.isCancelled else {
            finishAcceleratorCancelled(generation: generation)
            return
        }

        acceleratorPersistenceGeneration = generation
        var saveFailed = false
        if let acceleratorHistoryRepository {
            do {
                try await acceleratorHistoryRepository.save(result)
            } catch {
                saveFailed = true
            }
            acceleratorHistory = await acceleratorHistoryRepository.load()
        } else {
            acceleratorHistory = [result]
        }
        guard acceleratorOperation?.generation == generation else { return }
        latestAcceleratorResult = result
        acceleratorNotice = saveFailed ? .historySaveFailed : nil
        acceleratorProgress = nil
        acceleratorPersistenceGeneration = nil
        acceleratorOperation = nil
        acceleratorState = .completed
    }

    private func finishAcceleratorCancelled(generation: UUID) {
        guard acceleratorOperation?.generation == generation else { return }
        acceleratorPersistenceGeneration = nil
        acceleratorOperation = nil
        acceleratorProgress = nil
        acceleratorState = .cancelled
    }

    private func acceptProgress(
        _ update: MacBenchmarkProgress,
        generation: UUID
    ) {
        guard operation?.generation == generation,
              state != .cancelling,
              update.completedSampleCount >= 0,
              update.totalSampleCount > 0,
              update.completedSampleCount <= update.totalSampleCount,
              update.progress.isFinite,
              update.elapsedSeconds.isFinite,
              update.elapsedSeconds >= 0 else {
            return
        }

        if let previous = progress {
            guard update.stage.canFollow(
                previous.stage,
                previousCompletedSampleCount: previous.completedSampleCount,
                completedSampleCount: update.completedSampleCount
            ) else { return }
        }

        let previousProgress = progress?.progress ?? 0
        let previousElapsed = progress?.elapsedSeconds ?? 0
        let accepted = MacBenchmarkProgress(
            stage: update.stage,
            completedSampleCount: max(
                progress?.completedSampleCount ?? 0,
                update.completedSampleCount
            ),
            totalSampleCount: update.totalSampleCount,
            progress: min(1, max(previousProgress, update.progress)),
            elapsedSeconds: max(previousElapsed, update.elapsedSeconds)
        )
        progress = accepted
        if update.stage == .preflight {
            transition(to: .preflighting(profile: selectedProfile))
        } else {
            transition(to: .running(
                stage: update.stage,
                progress: accepted.progress,
                elapsedSeconds: accepted.elapsedSeconds
            ))
        }
    }

    private func finish(
        _ rawResult: MacBenchmarkRawResult,
        generation: UUID
    ) async {
        guard operation?.generation == generation else { return }

        if let failure = rawResult.failure {
            persistenceGeneration = nil
            operation = nil
            progress = nil
            transition(to: failure == .cancelled ? .cancelled : .failed(failure))
            return
        }

        let processed: ProcessedMacBenchmarkResult
        do {
            processed = try resultProcessor.process(rawResult)
        } catch {
            persistenceGeneration = nil
            operation = nil
            progress = nil
            notice = .resultRejected
            transition(to: .failed(.invalidResult))
            return
        }

        guard !Task.isCancelled else {
            finishCancelled(generation: generation)
            return
        }

        // Persist the immutable score snapshot together with its raw samples.
        // The repository independently recomputes trusted scores before accepting
        // them, so forged or stale values still degrade to raw-only history.
        let persisted = processed.result
        persistenceGeneration = generation
        var saveFailed = false
        do {
            try await historyRepository.save(persisted)
        } catch {
            saveFailed = true
        }
        let stored = await historyRepository.load()
        guard operation?.generation == generation else { return }

        latestResult = processed.result
        rawOnlyReason = processed.rawOnlyReason
        history = reprocessHistory(stored)
        notice = saveFailed ? .historySaveFailed : nil
        progress = nil
        persistenceGeneration = nil
        operation = nil
        transition(to: .completed)
        if suiteTask == nil {
            onCompletedResult?(processed.result, history)
        }
    }

    private func finishCancelled(generation: UUID) {
        guard operation?.generation == generation else { return }
        persistenceGeneration = nil
        operation = nil
        progress = nil
        transition(to: .cancelled)
    }

    private func transition(to next: MacBenchmarkState) {
        guard state.canTransition(to: next) else {
            assertionFailure("Illegal benchmark state transition: \(state) -> \(next)")
            return
        }
        state = next
    }

    private func reprocessHistory(
        _ stored: [MacBenchmarkResult]
    ) -> [MacBenchmarkResult] {
        // The repository validates and canonicalizes a score at write/load time.
        // Do not feed stored raw data through the current processor again: a
        // future baseline or scoring revision must never silently change history.
        stored
    }

    private func rawOnlyReason(
        for result: MacBenchmarkResult
    ) -> MacBenchmarkRawOnlyReason? {
        guard let raw = result.rawResult else { return nil }
        return try? resultProcessor.process(raw).rawOnlyReason
    }

    private func confirmedV7History(
        _ records: [BenchmarkV7Result]
    ) -> [BenchmarkV7Result] {
        records.filter { !v7PromotionRevocations.contains($0.recordID) }
    }

    private func latestV7Result(
        in candidates: [BenchmarkV7Result?]
    ) -> BenchmarkV7Result? {
        candidates
            .compactMap { $0 }
            .filter(\.isCurrentComparableOfficialResult)
            .max { lhs, rhs in
                v7ResultTimestamp(lhs) < v7ResultTimestamp(rhs)
            }
    }

    private func bestV7Result(
        in candidates: [BenchmarkV7Result],
        score: (BenchmarkV7Result) -> Double?
    ) -> BenchmarkV7Result? {
        candidates.reduce(into: nil as (result: BenchmarkV7Result, score: Double)?) {
            best, candidate in
            guard candidate.isCurrentComparableOfficialResult,
                  candidate.isCurrentLocalBestEligible,
                  let candidateScore = score(candidate),
                  candidateScore.isFinite,
                  candidateScore > 0 else {
                return
            }
            guard let current = best else {
                best = (candidate, candidateScore)
                return
            }
            if candidateScore > current.score
                || (candidateScore == current.score
                    && v7ResultTimestamp(candidate) > v7ResultTimestamp(current.result)) {
                best = (candidate, candidateScore)
            }
        }?.result
    }

    private func v7ResultTimestamp(_ result: BenchmarkV7Result) -> Date {
        result.completedAt ?? result.session.startedAt
    }

    deinit {
        suiteTask?.cancel()
        operation?.task.cancel()
        acceleratorOperation?.task.cancel()
        sustainedOperation?.task.cancel()
        v7Operation?.task.cancel()
        v7PreflightOperation?.task.cancel()
    }
}
