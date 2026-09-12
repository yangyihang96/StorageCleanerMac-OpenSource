import Foundation

protocol MemoryExecutionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousMemoryExecutionClock: MemoryExecutionClock {
    private let clock = ContinuousClock()

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

@MainActor
final class MemoryCoordinator {
    private(set) var state: MemoryOptimizationState = .idle

    private let probe: any MemoryProbing
    private let applications: any MemoryApplicationControlling
    private let clock: any MemoryExecutionClock
    private let pollInterval: Duration
    private let maximumPolls: Int
    private var activePlan: MemoryOptimizationPlan?
    private var consumedPlanIDs = Set<UUID>()
    private var consumedPlanOrder: [UUID] = []
    private var cancelRequested = false

    init(
        probe: any MemoryProbing = SystemMemoryProbe.shared,
        applications: any MemoryApplicationControlling = RunningApplicationController(),
        clock: any MemoryExecutionClock = ContinuousMemoryExecutionClock(),
        pollInterval: Duration = .milliseconds(100),
        gracefulQuitTimeout: Duration = .seconds(3)
    ) {
        self.probe = probe
        self.applications = applications
        self.clock = clock
        self.pollInterval = pollInterval
        maximumPolls = max(1, Self.pollCount(timeout: gracefulQuitTimeout, interval: pollInterval))
    }

    func observe(includeProcesses: Bool = true) async -> MemorySnapshot {
        let snapshot = await probe.snapshot(includeProcesses: includeProcesses)
        state = .observing(snapshot)
        return snapshot
    }

    func makePlan(
        processes: [MemoryProcess],
        snapshot: MemorySnapshot,
        now: Date = Date()
    ) throws -> MemoryOptimizationPlan {
        guard !isExecuting else {
            throw MemoryOptimizationCoordinatorError.operationAlreadyRunning
        }
        state = .planning

        var seen = Set<MemoryProcessIdentity>()
        let targets = processes.compactMap { process -> MemoryOptimizationTarget? in
            guard process.canQuit,
                  process.availability == .available,
                  seen.insert(process.identity).inserted else { return nil }
            return MemoryOptimizationTarget(
                identity: process.identity,
                name: process.name,
                estimatedBytes: UInt64(max(0, process.residentBytes))
            )
        }
        guard !targets.isEmpty else {
            state = .failed(.invalidTargets)
            throw MemoryOptimizationCoordinatorError.invalidTargets
        }

        let estimated = targets.reduce(UInt64(0)) { partial, target in
            partial.addingReportingOverflow(target.estimatedBytes).overflow
                ? UInt64.max
                : partial + target.estimatedBytes
        }
        let preflight = targets.map { target in
            MemoryOptimizationPreflight(
                target: target,
                status: applications.preflight(target),
                detail: nil
            )
        }
        let plan = MemoryOptimizationPlan(
            id: UUID(),
            createdAt: now,
            targets: targets,
            reason: snapshot.memoryAdviceTitle,
            estimatedApplicationReductionBytes: estimated,
            action: .gracefulQuit,
            riskNotice: L10n.text(
                "退出应用前请保存未保存的工作；计划不会自动升级为强制退出。",
                "Save unsaved work before quitting apps; this plan never escalates to force quit automatically."
            ),
            confirmation: .pending,
            preflight: preflight
        )
        activePlan = plan
        cancelRequested = false
        state = .awaitingApproval(plan)
        return plan
    }

    func execute(
        planID: UUID,
        before: MemorySnapshot,
        forceQuitApproved: Bool = false,
        now: Date = Date()
    ) async throws -> MemoryOptimizationExecutionResult {
        guard let pending = activePlan, pending.id == planID else {
            throw consumedPlanIDs.contains(planID)
                ? MemoryOptimizationCoordinatorError.planAlreadyConsumed
                : MemoryOptimizationCoordinatorError.planNotFound
        }
        guard !consumedPlanIDs.contains(planID) else {
            throw MemoryOptimizationCoordinatorError.planAlreadyConsumed
        }
        if pending.action == .forceQuit, !forceQuitApproved {
            throw MemoryOptimizationCoordinatorError.forceQuitRequiresIndependentApproval
        }

        let plan = pending.approved(at: now, forceQuit: forceQuitApproved)
        activePlan = plan
        markConsumed(planID)
        cancelRequested = false

        var results: [MemoryOptimizationTargetResult] = []
        for target in plan.targets {
            if cancelRequested || Task.isCancelled {
                results.append(MemoryOptimizationTargetResult(
                    target: target,
                    outcome: .userCancelled,
                    detail: nil
                ))
                continue
            }

            state = .executing(
                planID: planID,
                completedTargets: results.count,
                totalTargets: plan.targets.count
            )
            let preflight = applications.preflight(target)
            guard preflight == .ready else {
                results.append(MemoryOptimizationTargetResult(
                    target: target,
                    outcome: Self.outcome(for: preflight),
                    detail: nil
                ))
                continue
            }

            let accepted = plan.action == .forceQuit
                ? applications.requestForceQuit(target)
                : applications.requestGracefulQuit(target)
            guard accepted else {
                results.append(MemoryOptimizationTargetResult(
                    target: target,
                    outcome: plan.action == .forceQuit ? .forceQuitFailed : .requestRejected,
                    detail: nil
                ))
                continue
            }

            results.append(await waitForExit(target, action: plan.action))
        }

        if cancelRequested || Task.isCancelled {
            state = .cancelled
            activePlan = nil
            return Self.cancelledResult(plan: plan, before: before, results: results, now: Date())
        }

        state = .verifying(planID: planID)
        let after = await probe.snapshot(includeProcesses: true)
        let verificationAvailable = after.quality != .unavailable
        let successCount = results.filter { result in
            result.outcome == .gracefulQuitSucceeded || result.outcome == .forceQuitSucceeded
        }.count
        let completion: MemoryOptimizationCompletion
        if !verificationAvailable {
            completion = .verificationFailed
        } else if successCount == results.count {
            completion = .completed
        } else {
            completion = .partial
        }

        let result = MemoryOptimizationExecutionResult(
            planID: planID,
            startedAt: plan.createdAt,
            completedAt: Date(),
            completion: completion,
            targetResults: results,
            snapshotBefore: before,
            snapshotAfter: verificationAvailable ? after : nil,
            estimatedApplicationReductionBytes: plan.estimatedApplicationReductionBytes,
            observedApplicationMemoryDeltaBytes: MemoryByteMath.signedDifference(
                before.measurements.appBytes.value,
                after.measurements.appBytes.value
            ),
            observedAvailableMemoryDeltaBytes: MemoryByteMath.signedDifference(
                after.measurements.availableBytes.value,
                before.measurements.availableBytes.value
            ),
            pressureBefore: before.pressureLevel,
            pressureAfter: verificationAvailable ? after.pressureLevel : nil,
            swapUsedBeforeBytes: before.measurements.swapUsedBytes.value,
            swapUsedAfterBytes: after.measurements.swapUsedBytes.value,
            attributionNotice: L10n.text(
                "观察到的系统内存变化可能同时受缓存、压缩和其他进程影响，不能全部归因于本次退出。",
                "Observed system memory changes can also come from cache, compression, and other processes and are not fully attributable to these quits."
            )
        )
        state = .completed(result)
        activePlan = nil
        return result
    }

    func requestForceQuitPlan(planID: UUID) throws -> MemoryOptimizationPlan {
        guard let pending = activePlan, pending.id == planID else {
            throw MemoryOptimizationCoordinatorError.planNotFound
        }
        guard !consumedPlanIDs.contains(planID) else {
            throw MemoryOptimizationCoordinatorError.planAlreadyConsumed
        }
        let forcePlan = MemoryOptimizationPlan(
            id: pending.id,
            createdAt: pending.createdAt,
            targets: pending.targets,
            reason: pending.reason,
            estimatedApplicationReductionBytes: pending.estimatedApplicationReductionBytes,
            action: .forceQuit,
            riskNotice: pending.riskNotice,
            confirmation: .pending,
            preflight: pending.preflight
        )
        activePlan = forcePlan
        state = .awaitingApproval(forcePlan)
        return forcePlan
    }

    func cancel() {
        cancelRequested = true
        activePlan = nil
        state = .cancelled
    }

    private var isExecuting: Bool {
        switch state {
        case .executing, .verifying:
            true
        default:
            false
        }
    }

    private func markConsumed(_ planID: UUID) {
        guard consumedPlanIDs.insert(planID).inserted else { return }
        consumedPlanOrder.append(planID)
        if consumedPlanOrder.count > 128 {
            consumedPlanIDs.remove(consumedPlanOrder.removeFirst())
        }
    }

    private func waitForExit(
        _ target: MemoryOptimizationTarget,
        action: MemoryOptimizationAction
    ) async -> MemoryOptimizationTargetResult {
        for _ in 0..<maximumPolls {
            if cancelRequested || Task.isCancelled {
                return MemoryOptimizationTargetResult(
                    target: target,
                    outcome: .userCancelled,
                    detail: nil
                )
            }
            do {
                try await clock.sleep(for: pollInterval)
            } catch {
                return MemoryOptimizationTargetResult(
                    target: target,
                    outcome: .userCancelled,
                    detail: nil
                )
            }
            switch applications.preflight(target) {
            case .targetExited:
                return MemoryOptimizationTargetResult(
                    target: target,
                    outcome: action == .forceQuit ? .forceQuitSucceeded : .gracefulQuitSucceeded,
                    detail: nil
                )
            case .identityChanged:
                return MemoryOptimizationTargetResult(
                    target: target,
                    outcome: .identityChanged,
                    detail: nil
                )
            case .ready:
                continue
            case .permissionDenied, .unsupported:
                return MemoryOptimizationTargetResult(
                    target: target,
                    outcome: .verificationUnavailable,
                    detail: nil
                )
            }
        }
        return MemoryOptimizationTargetResult(target: target, outcome: .timedOut, detail: nil)
    }

    private static func outcome(
        for preflight: MemoryPreflightStatus
    ) -> MemoryOptimizationTargetOutcome {
        switch preflight {
        case .ready: .requestRejected
        case .targetExited: .targetExitedBeforeRequest
        case .identityChanged: .identityChanged
        case .permissionDenied, .unsupported: .verificationUnavailable
        }
    }

    private static func pollCount(timeout: Duration, interval: Duration) -> Int {
        let timeoutComponents = timeout.components
        let intervalComponents = interval.components
        let timeoutSeconds = Double(timeoutComponents.seconds)
            + Double(timeoutComponents.attoseconds) / 1_000_000_000_000_000_000
        let intervalSeconds = Double(intervalComponents.seconds)
            + Double(intervalComponents.attoseconds) / 1_000_000_000_000_000_000
        guard timeoutSeconds.isFinite,
              intervalSeconds.isFinite,
              timeoutSeconds > 0,
              intervalSeconds > 0 else { return 1 }
        return Int(ceil(timeoutSeconds / intervalSeconds))
    }

    private static func cancelledResult(
        plan: MemoryOptimizationPlan,
        before: MemorySnapshot,
        results: [MemoryOptimizationTargetResult],
        now: Date
    ) -> MemoryOptimizationExecutionResult {
        MemoryOptimizationExecutionResult(
            planID: plan.id,
            startedAt: plan.createdAt,
            completedAt: now,
            completion: .cancelled,
            targetResults: results,
            snapshotBefore: before,
            snapshotAfter: nil,
            estimatedApplicationReductionBytes: plan.estimatedApplicationReductionBytes,
            observedApplicationMemoryDeltaBytes: nil,
            observedAvailableMemoryDeltaBytes: nil,
            pressureBefore: before.pressureLevel,
            pressureAfter: nil,
            swapUsedBeforeBytes: before.measurements.swapUsedBytes.value,
            swapUsedAfterBytes: nil,
            attributionNotice: L10n.text(
                "操作已取消，未继续处理剩余应用。",
                "The operation was cancelled and remaining apps were not processed."
            )
        )
    }
}
