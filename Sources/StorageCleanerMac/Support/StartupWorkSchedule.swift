import Foundation
import Combine

/// Finite first-round deadlines only. Later calls retain the owner's cadence.
struct ResidentStartupSchedule: Sendable {
    enum Source: String, CaseIterable, Sendable {
        case hardware, localData, processes, processor, power, metadata
        var offset: TimeInterval {
            switch self {
            case .hardware: 0.75
            case .localData: 1
            case .processes: 2
            case .processor: 2.5
            case .power: 3
            case .metadata: 4
            }
        }
    }
    let beganAt: Date
    func permits(_ source: Source, now: Date, promoted: Bool) -> Bool {
        promoted || now.timeIntervalSince(beganAt) >= source.offset
    }
    static let deadlines: [TimeInterval] = [0.75, 1, 2, 2.5, 3, 4]
}

/// Automatic launch scans yield to the first frame and resident first samples.
/// Both waits are bounded; user demand cancels the wait and runs the same policy.
@MainActor
final class StartupApplicationUpdateScheduler {
    static let shared = StartupApplicationUpdateScheduler()
    static let earliestDelay: TimeInterval = 6
    static let maximumDelay: TimeInterval = 10
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    private let sleep: Sleep
    private var pending: Task<Void, Never>?
    private var action: (@MainActor () -> Void)?
    private var policyEligible: (@MainActor () -> Bool)?
    private var executionAvailable: (@MainActor () -> Bool)?
    private var completionObservation: AnyCancellable?
    private var terminating = false
    private var generation = 0
    private var startupCompleted = false
    var isPending: Bool { pending != nil || action != nil }
    var isDelaying: Bool { pending != nil }
    var isWaitingForAvailability: Bool { pending == nil && action != nil }

    init(sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    func scheduleIfDue(shouldCheck: @escaping @MainActor () -> Bool,
                       executionAvailable: @escaping @MainActor () -> Bool = { true },
                       priorityReady: @escaping @MainActor () -> Bool,
                       operation: @escaping @MainActor () -> Void) {
        guard !terminating, shouldCheck(), !isPending else { return }
        policyEligible = shouldCheck
        self.executionAvailable = executionAvailable
        action = operation
        if startupCompleted { finish(); return }
        generation &+= 1
        let captured = generation, sleep = sleep
        pending = Task { @MainActor [weak self] in
            do {
                try await sleep(Self.earliestDelay)
                guard let self, !Task.isCancelled, captured == generation else { return }
                if !priorityReady() {
                    try await sleep(Self.maximumDelay - Self.earliestDelay)
                }
                guard !Task.isCancelled, captured == generation else { return }
                finish()
            } catch { /* Cancellation never starts a scan. */ }
        }
    }

    func promoteIfPending() {
        guard !terminating, isPending else { return }
        generation &+= 1
        pending?.cancel()
        finish()
    }

    func performUserRequest(_ operation: @MainActor () -> Void) {
        guard !terminating else { return }
        cancel()
        startupCompleted = true
        operation()
    }

    func cancel() {
        generation &+= 1
        pending?.cancel()
        pending = nil
        action = nil
        policyEligible = nil
        executionAvailable = nil
    }

    /// Observe the existing completion publisher for the lifetime of the App,
    /// including periods with no main window. Published delivers in willSet,
    /// so join MainActor after delivery before consulting the Store's owner.
    func observeCompletion(of activity: HeavyWorkActivityStore) {
        guard !terminating else { return }
        completionObservation = activity.$activeOwner.dropFirst().sink { [weak self] owner in
            guard owner == nil else { return }
            Task { @MainActor [weak self] in self?.executionAvailabilityDidChange() }
        }
    }

    func cancelForTermination() {
        terminating = true
        cancel()
        completionObservation?.cancel()
        completionObservation = nil
    }

    /// Driven by the existing heavy-work activeOwner completion event.
    /// Before the deadline it cannot advance the first-frame budget.
    func executionAvailabilityDidChange() {
        guard !terminating, pending == nil, startupCompleted else { return }
        finish()
    }

    private func finish() {
        pending = nil
        startupCompleted = true
        guard !terminating, let operation = action else { return }
        guard policyEligible?() == true else { cancel(); return }
        // A busy lease is temporary: retain the qualified intent until the
        // existing owner-release event, without scheduling another timer.
        guard executionAvailable?() == true else { return }
        action = nil
        policyEligible = nil
        executionAvailable = nil
        operation()
    }
}
