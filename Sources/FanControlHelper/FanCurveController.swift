import FanControlShared
import Foundation

/// Runs only on the helper's serial SMC queue. It owns one SMC connection and
/// never depends on an app window or SwiftUI lifecycle.
final class FanCurveController {
    private(set) var profile: FanCurveProfile
    private(set) var leaseID: UUID
    private(set) var runtimeState: FanCurveRuntimeState

    private let smc: SMCFanController
    private let policy: FanCurveControlPolicy
    private var engine: FanCurveControlEngine
    private var leaseDeadline: Date
    private var lastTick: Date?
    private var lastTargets: [Int: Int] = [:]
    private var lastAppliedPercentage: Double
    private var rangesByFan: [Int: FanCurveFanRange]

    init(
        profile: FanCurveProfile,
        leaseID: UUID,
        watchdogSeconds: TimeInterval,
        smc: SMCFanController,
        now: Date,
        policy: FanCurveControlPolicy = .standard
    ) throws {
        let availableFanIDs = Set(0..<smc.availableFanCount())
        let allowedSensors = smc.availableFanCurveSensors()
        try FanCurveValidator.validate(
            profile,
            allowedSensors: allowedSensors,
            availableFanIDs: availableFanIDs,
            requiresTargetFans: true
        )
        guard watchdogSeconds.isFinite, (3...30).contains(watchdogSeconds) else {
            throw FanCurveError.curveLeaseExpired
        }
        let ranges = try profile.targetFanIDs.map { fanID -> FanCurveFanRange in
            guard let range = smc.curveFanRange(fanID: fanID) else {
                throw FanCurveError.fanRangeUnavailable
            }
            return range
        }
        let initialPercentage = try FanCurveRPMMapper.actualPercentage(ranges: ranges)
        self.profile = profile
        self.leaseID = leaseID
        self.smc = smc
        self.policy = policy
        engine = FanCurveControlEngine(
            policy: policy,
            initialAppliedPercentage: initialPercentage
        )
        lastAppliedPercentage = initialPercentage
        leaseDeadline = now.addingTimeInterval(watchdogSeconds)
        rangesByFan = Dictionary(uniqueKeysWithValues: ranges.map { ($0.fanID, $0) })
        runtimeState = FanCurveRuntimeState(
            status: .preparing,
            appliedPercentage: initialPercentage,
            actualRPMByFan: Dictionary(uniqueKeysWithValues: ranges.map {
                ($0.fanID, $0.actualRPM)
            }),
            activeProfileID: profile.id
        )
    }

    func activate(at now: Date) throws -> FanCurveRuntimeState {
        try tick(at: now, forceWrite: true)
    }

    func update(
        profile: FanCurveProfile,
        leaseID: UUID,
        watchdogSeconds: TimeInterval,
        at now: Date
    ) throws -> FanCurveRuntimeState {
        guard leaseID == self.leaseID,
              profile.targetFanIDs == self.profile.targetFanIDs else {
            throw FanCurveError.curveUpdateFailed
        }
        try FanCurveValidator.validate(
            profile,
            allowedSensors: smc.availableFanCurveSensors(),
            availableFanIDs: Set(0..<smc.availableFanCount()),
            requiresTargetFans: true
        )
        if profile.sensor != self.profile.sensor {
            let ranges = try currentRanges()
            let currentPercentage = try FanCurveRPMMapper.actualPercentage(ranges: ranges)
            engine = FanCurveControlEngine(
                policy: policy,
                initialAppliedPercentage: currentPercentage
            )
            lastAppliedPercentage = currentPercentage
            lastTick = nil
        }
        self.profile = profile
        try renew(leaseID: leaseID, watchdogSeconds: watchdogSeconds, at: now)
        return try tick(at: now, forceWrite: true)
    }

    func renew(
        leaseID: UUID,
        watchdogSeconds: TimeInterval,
        at now: Date
    ) throws {
        guard leaseID == self.leaseID,
              watchdogSeconds.isFinite,
              (3...30).contains(watchdogSeconds) else {
            throw FanCurveError.curveLeaseExpired
        }
        leaseDeadline = now.addingTimeInterval(watchdogSeconds)
    }

    func tick(
        at now: Date,
        forceWrite: Bool = false
    ) throws -> FanCurveRuntimeState {
        guard now < leaseDeadline else { throw FanCurveError.curveLeaseExpired }
        if let lastTick,
           now.timeIntervalSince(lastTick) > policy.staleAfter {
            throw FanCurveError.sensorStale
        }
        lastTick = now
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            throw FanCurveError.thermalProtectionActivated
        case .nominal, .fair:
            break
        @unknown default:
            throw FanCurveError.thermalProtectionActivated
        }

        guard let rawTemperature = smc.curveTemperature(profile.sensor) else {
            if let failure = engine.recordSensorFailure(at: now) {
                throw failure
            }
            return runtimeState
        }
        let decision = try engine.evaluate(
            rawTemperature: rawTemperature,
            profile: profile,
            at: now
        )
        let ranges = try currentRanges()
        let requestedTargets = try FanCurveRPMMapper.targets(
            percentage: decision.appliedPercentage,
            ranges: ranges
        )
        let rpmThresholdReached = lastTargets.isEmpty || requestedTargets.contains {
            guard let previous = lastTargets[$0.key] else { return true }
            return abs($0.value - previous) >= policy.rpmWriteThreshold
        }
        let shouldWrite = forceWrite
            || decision.appliedPercentage >= 100
            || (decision.shouldWrite && rpmThresholdReached)

        if shouldWrite {
            runtimeState.status = .applying
            var applied: [Int: Int] = [:]
            for (fanID, targetRPM) in requestedTargets.sorted(by: { $0.key < $1.key }) {
                guard let appliedRPM = smc.applyCoolingBoost(
                    fanID: fanID,
                    requestedRPM: targetRPM,
                    allowsRPMDecrease: true
                ) else {
                    throw FanCurveError.curveVerificationFailed
                }
                applied[fanID] = appliedRPM
            }
            guard smc.verifiesManualTargets(applied) else {
                throw FanCurveError.curveVerificationFailed
            }
            lastTargets = applied
            engine.markWritten(percentage: decision.appliedPercentage)
            lastAppliedPercentage = decision.appliedPercentage
            runtimeState.lastFanWrite = now
        } else if !lastTargets.isEmpty,
                  !smc.verifiesManualTargets(lastTargets) {
            throw FanCurveError.curveVerificationFailed
        }

        let actualRPMByFan = try Dictionary(uniqueKeysWithValues: profile.targetFanIDs.map {
            fanID -> (Int, Int) in
            guard let actual = smc.curveFanRange(fanID: fanID)?.actualRPM else {
                throw FanCurveError.curveVerificationFailed
            }
            return (fanID, actual)
        })
        runtimeState = FanCurveRuntimeState(
            status: .active,
            rawTemperature: decision.rawTemperature,
            filteredTemperature: decision.filteredTemperature,
            calculatedPercentage: decision.calculatedPercentage,
            appliedPercentage: lastAppliedPercentage,
            targetRPMByFan: lastTargets,
            actualRPMByFan: actualRPMByFan,
            activeProfileID: profile.id,
            lastSensorUpdate: now,
            lastFanWrite: runtimeState.lastFanWrite,
            lastVerification: now,
            failureReason: nil
        )
        return runtimeState
    }

    private func currentRanges() throws -> [FanCurveFanRange] {
        try profile.targetFanIDs.map { fanID in
            guard let range = smc.curveFanRange(fanID: fanID),
                  let original = rangesByFan[fanID],
                  range.minimumRPM == original.minimumRPM,
                  range.maximumRPM == original.maximumRPM else {
                throw FanCurveError.fanRangeUnavailable
            }
            return range
        }
    }
}
