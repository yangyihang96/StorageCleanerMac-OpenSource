import Combine
import Foundation

enum NetworkSpeedTestState: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case offline
    case timedOut
    case cancelled
    case failed
    case consentRequired
    case compatibilityAvailable
    case compatibilityConsentRequired
}

@MainActor
final class NetworkSpeedTestStore: ObservableObject {
    @Published private(set) var state: NetworkSpeedTestState = .idle
    @Published private(set) var lastSuccessfulResult: NetworkSpeedTestResult?
    @Published private(set) var conflictMessage: String?

    private enum CompatibilityFallbackAccess: Equatable {
        case locked
        case offered
    }

    private var compatibilityFallbackAccess: CompatibilityFallbackAccess = .locked
    var isCompatibilityAvailable: Bool { compatibilityFallbackAccess == .offered }

    private enum TestKind: Equatable, Sendable {
        case native
        case compatibility
    }

    private enum Outcome: Sendable {
        case success(NetworkSpeedTestResult, TestKind)
        case failure(NetworkSpeedTestError, TestKind)
        case blocked(HeavyWorkCoordinator.Owner)
    }

    private struct Operation {
        let generation: UUID
        let task: Task<Outcome, Never>
    }

    private let service: NetworkSpeedTestService
    private let compatibilityService: any NetworkCompatibilitySpeedTesting
    private let heavyWorkCoordinator: HeavyWorkCoordinator
    private let heavyWorkActivityStore: HeavyWorkActivityStore
    private let resultRepository: any NetworkSpeedTestResultPersisting
    private let onSuccessfulResult: @MainActor (NetworkSpeedTestResult) -> Void
    private var operation: Operation?
    private var hasAttemptedResultRestore = false

    init(
        heavyWorkCoordinator: HeavyWorkCoordinator = HeavyWorkCoordinator(),
        heavyWorkActivityStore: HeavyWorkActivityStore? = nil,
        runner: any NetworkQualityRunning = NetworkQualityProcessRunner(),
        watchdog: Duration = NetworkSpeedTestService.defaultWatchdog,
        now: @escaping @Sendable () -> Date = { Date() },
        compatibilityService: any NetworkCompatibilitySpeedTesting = NetworkCompatibilitySpeedTestService(),
        resultRepository: any NetworkSpeedTestResultPersisting = DiscardingNetworkSpeedTestResultRepository(),
        onSuccessfulResult: @escaping @MainActor (NetworkSpeedTestResult) -> Void = { _ in }
    ) {
        self.heavyWorkCoordinator = heavyWorkCoordinator
        self.heavyWorkActivityStore = heavyWorkActivityStore
            ?? HeavyWorkActivityStore(coordinator: heavyWorkCoordinator)
        service = NetworkSpeedTestService(
            runner: runner,
            watchdog: watchdog,
            now: now
        )
        self.compatibilityService = compatibilityService
        self.resultRepository = resultRepository
        self.onSuccessfulResult = onSuccessfulResult
    }

    func restoreLastSuccessfulResult() async {
        guard !hasAttemptedResultRestore else { return }
        hasAttemptedResultRestore = true

        guard let result = await resultRepository.load(),
              operation == nil,
              lastSuccessfulResult == nil else {
            return
        }
        lastSuccessfulResult = result
        state = .succeeded
        onSuccessfulResult(result)
    }

    func start(consentGranted: Bool) {
        begin(.native, consentGranted: consentGranted)
    }

    func startCompatibility(consentGranted: Bool) {
        guard isCompatibilityAvailable else { return }
        begin(.compatibility, consentGranted: consentGranted)
    }

    private func begin(_ kind: TestKind, consentGranted: Bool) {
        guard operation == nil else { return }
        conflictMessage = nil
        guard consentGranted else {
            state = kind == .native
                ? .consentRequired
                : .compatibilityConsentRequired
            return
        }

        let generation = UUID()
        let service = self.service
        let compatibilityService = self.compatibilityService
        let coordinator = heavyWorkCoordinator
        let activityStore = heavyWorkActivityStore
        let task = Task<Outcome, Never> {
            let outcome: Outcome
            do {
                try Task.checkCancellation()
                let result = try await coordinator.withLease(owner: .networkTest) { lease in
                    await activityStore.refresh()
                    try await coordinator.requireValid(lease, owner: .networkTest)
                    let result: NetworkSpeedTestResult
                    switch kind {
                    case .native:
                        do {
                            result = try await service.test()
                        } catch let error as NetworkSpeedTestCleanupPendingError {
                            let quarantine = try await coordinator.beginCleanupQuarantine(lease)
                            Self.monitorCleanup(
                                error.context,
                                coordinator: coordinator,
                                quarantine: quarantine,
                                activityStore: activityStore
                            )
                            throw error
                        }
                    case .compatibility:
                        do {
                            result = try await compatibilityService.test()
                        } catch let error as NetworkCompatibilitySpeedTestCleanupPendingError {
                            let quarantine = try await coordinator.beginCleanupQuarantine(lease)
                            Self.monitorCleanup(
                                error.context,
                                coordinator: coordinator,
                                quarantine: quarantine,
                                activityStore: activityStore
                            )
                            throw error
                        }
                    }
                    try Task.checkCancellation()
                    guard Self.isExpectedSource(result.source, for: kind) else {
                        throw NetworkSpeedTestError.invalidOutput
                    }
                    return result
                }
                outcome = .success(result, kind)
            } catch let error as HeavyWorkCoordinator.Error {
                switch error {
                case let .busy(activeOwner):
                    activityStore.reportConflict(activeOwner: activeOwner)
                    outcome = .blocked(activeOwner)
                case .invalidLease:
                    outcome = .failure(.failed, kind)
                }
            } catch let error as NetworkSpeedTestError {
                outcome = .failure(error, kind)
            } catch let error as CompatibilitySpeedTestError {
                outcome = .failure(Self.mapCompatibilityError(error), kind)
            } catch is NetworkCompatibilitySpeedTestCleanupPendingError {
                outcome = .failure(.terminationFailed, kind)
            } catch is NetworkSpeedTestCleanupPendingError {
                outcome = .failure(.terminationFailed, kind)
            } catch is CancellationError {
                outcome = .failure(.cancelled, kind)
            } catch {
                outcome = .failure(.failed, kind)
            }
            await activityStore.refresh()
            return outcome
        }

        operation = Operation(generation: generation, task: task)
        state = .running

        Task { @MainActor [weak self] in
            let outcome = await task.value
            await self?.finish(outcome, generation: generation)
        }
    }

    func cancel() {
        guard let operation, state == .running else { return }
        operation.task.cancel()
    }

    func waitUntilIdle() async {
        guard let operation else { return }
        let outcome = await operation.task.value
        await finish(outcome, generation: operation.generation)
    }

    private func finish(_ outcome: Outcome, generation: UUID) async {
        guard operation?.generation == generation else { return }
        operation = nil
        conflictMessage = nil

        switch outcome {
        case let .success(result, kind):
            if kind == .native {
                compatibilityFallbackAccess = .locked
            }
            lastSuccessfulResult = result
            state = .succeeded
            onSuccessfulResult(result)
            try? await resultRepository.save(result)
        case let .failure(error, kind):
            switch error {
            case .offline:
                state = .offline
            case .timedOut:
                state = .timedOut
            case .cancelled:
                state = .cancelled
            case .serviceUnavailable where kind == .native:
                compatibilityFallbackAccess = .offered
                state = .compatibilityAvailable
            case .invalidOutput,
                 .outputTooLarge,
                 .serviceUnavailable,
                 .failed,
                 .terminationFailed:
                state = .failed
            }
        case let .blocked(activeOwner):
            conflictMessage = HeavyWorkActivityStore.conflictMessage(
                activeOwner: activeOwner
            )
            state = .failed
        }
    }

    nonisolated private static func mapCompatibilityError(
        _ error: CompatibilitySpeedTestError
    ) -> NetworkSpeedTestError {
        error == .cancelled ? .cancelled : .failed
    }

    nonisolated private static func isExpectedSource(
        _ source: NetworkTestSource,
        for kind: TestKind
    ) -> Bool {
        switch (kind, source) {
        case (.native, .nativeSystem), (.compatibility, .compatibilityEstimate):
            true
        default:
            false
        }
    }

    nonisolated private static func monitorCleanup(
        _ context: NetworkQualityCleanupContext,
        coordinator: HeavyWorkCoordinator,
        quarantine: HeavyWorkCoordinator.CleanupQuarantine,
        activityStore: HeavyWorkActivityStore
    ) {
        Task.detached(priority: .utility) {
            await context.waitForVerifiedExit()
            await coordinator.clearCleanupQuarantine(quarantine)
            await activityStore.refresh()
        }
    }

    nonisolated private static func monitorCleanup(
        _ context: NetworkCompatibilityCleanupContext,
        coordinator: HeavyWorkCoordinator,
        quarantine: HeavyWorkCoordinator.CleanupQuarantine,
        activityStore: HeavyWorkActivityStore
    ) {
        Task.detached(priority: .utility) {
            await context.waitForVerifiedInvalidation()
            await coordinator.clearCleanupQuarantine(quarantine)
            await activityStore.refresh()
        }
    }

    deinit {
        operation?.task.cancel()
    }
}
