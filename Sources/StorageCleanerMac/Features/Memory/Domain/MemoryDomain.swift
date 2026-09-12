import Foundation

enum MeasurementQuality: String, Sendable, Equatable {
    case complete
    case partial
    case unavailable
}

enum MeasurementAvailability: String, Sendable, Equatable {
    case available
    case unavailable
    case permissionDenied
    case unsupported
    case processExited
    case temporarilyInvalid
    case invalidSample

    var title: String {
        switch self {
        case .available:
            L10n.text("可用", "Available")
        case .unavailable:
            L10n.text("不可用", "Unavailable")
        case .permissionDenied:
            L10n.text("权限不足", "Permission denied")
        case .unsupported:
            L10n.text("当前系统不支持", "Unsupported")
        case .processExited:
            L10n.text("进程已退出", "Process exited")
        case .temporarilyInvalid:
            L10n.text("暂时无法读取", "Temporarily unavailable")
        case .invalidSample:
            L10n.text("样本无效", "Invalid sample")
        }
    }
}

struct MemoryMeasurement<Value: Sendable>: Sendable {
    let value: Value?
    let availability: MeasurementAvailability
    let reason: String?

    static func available(_ value: Value) -> Self {
        Self(value: value, availability: .available, reason: nil)
    }

    static func unavailable(
        _ availability: MeasurementAvailability,
        reason: String
    ) -> Self {
        precondition(availability != .available)
        return Self(value: nil, availability: availability, reason: reason)
    }

    var unavailableDetail: String? {
        guard value == nil else { return nil }
        guard let reason, !reason.isEmpty else { return availability.title }
        return "\(availability.title) · \(reason)"
    }
}

enum MeasurementWarning: Sendable, Equatable {
    case metricUnavailable(name: String, reason: String)
    case arithmeticClamped(name: String)
    case invalidProcessSample(processIdentifier: Int32, reason: String)
    case futureSampleIgnored
    case clockDiscontinuity
}

struct MemoryMeasurements: Sendable {
    let pressure: MemoryMeasurement<MemoryPressureLevel>
    let physicalBytes: MemoryMeasurement<UInt64>
    let availableBytes: MemoryMeasurement<UInt64>
    let appBytes: MemoryMeasurement<UInt64>
    let wiredBytes: MemoryMeasurement<UInt64>
    let compressedBytes: MemoryMeasurement<UInt64>
    let cachedBytes: MemoryMeasurement<UInt64>
    let swapUsedBytes: MemoryMeasurement<UInt64>
    let swapInRate: MemoryMeasurement<Double>
    let swapOutRate: MemoryMeasurement<Double>

    static func legacyAvailable(
        physicalBytes: Int64,
        appBytes: Int64,
        wiredBytes: Int64,
        compressedBytes: Int64,
        cachedBytes: Int64,
        swapUsedBytes: Int64
    ) -> Self {
        Self(
            pressure: .unavailable(.temporarilyInvalid, reason: "Pressure is derived from the snapshot."),
            physicalBytes: .available(UInt64(max(0, physicalBytes))),
            availableBytes: .unavailable(.temporarilyInvalid, reason: "Available memory is derived from the snapshot."),
            appBytes: .available(UInt64(max(0, appBytes))),
            wiredBytes: .available(UInt64(max(0, wiredBytes))),
            compressedBytes: .available(UInt64(max(0, compressedBytes))),
            cachedBytes: .available(UInt64(max(0, cachedBytes))),
            swapUsedBytes: .available(UInt64(max(0, swapUsedBytes))),
            swapInRate: .unavailable(.temporarilyInvalid, reason: "A second sample is required."),
            swapOutRate: .unavailable(.temporarilyInvalid, reason: "A second sample is required.")
        )
    }
}

enum ProcessMemoryDataSource: String, Sendable, Equatable {
    case procPIDRUsage
    case legacyResidentSet
}

struct MemoryProcessIdentity: Hashable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let launchDate: Date?
    let executablePath: String
    let bundlePath: String?
    let userIdentifier: UInt32
}

enum MemoryOptimizationAction: Sendable, Equatable {
    case gracefulQuit
    case forceQuit
}

enum MemoryOptimizationConfirmation: Sendable, Equatable {
    case pending
    case approved(at: Date)
    case forceQuitApproved(at: Date)
}

enum MemoryPreflightStatus: Sendable, Equatable {
    case ready
    case targetExited
    case identityChanged
    case permissionDenied
    case unsupported
}

struct MemoryOptimizationTarget: Identifiable, Sendable, Equatable {
    var id: MemoryProcessIdentity { identity }
    let identity: MemoryProcessIdentity
    let name: String
    let estimatedBytes: UInt64
}

struct MemoryOptimizationPreflight: Sendable, Equatable {
    let target: MemoryOptimizationTarget
    let status: MemoryPreflightStatus
    let detail: String?
}

struct MemoryOptimizationPlan: Identifiable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let targets: [MemoryOptimizationTarget]
    let reason: String
    let estimatedApplicationReductionBytes: UInt64
    let action: MemoryOptimizationAction
    let riskNotice: String
    let confirmation: MemoryOptimizationConfirmation
    let preflight: [MemoryOptimizationPreflight]

    func approved(at date: Date, forceQuit: Bool = false) -> Self {
        Self(
            id: id,
            createdAt: createdAt,
            targets: targets,
            reason: reason,
            estimatedApplicationReductionBytes: estimatedApplicationReductionBytes,
            action: forceQuit ? .forceQuit : action,
            riskNotice: riskNotice,
            confirmation: forceQuit ? .forceQuitApproved(at: date) : .approved(at: date),
            preflight: preflight
        )
    }
}

enum MemoryOptimizationTargetOutcome: Sendable, Equatable {
    case gracefulQuitSucceeded
    case forceQuitSucceeded
    case userCancelled
    case targetExitedBeforeRequest
    case identityChanged
    case requestRejected
    case timedOut
    case forceQuitFailed
    case verificationUnavailable
}

struct MemoryOptimizationTargetResult: Sendable, Equatable {
    let target: MemoryOptimizationTarget
    let outcome: MemoryOptimizationTargetOutcome
    let detail: String?
}

enum MemoryOptimizationCompletion: Sendable, Equatable {
    case completed
    case partial
    case cancelled
    case verificationFailed
}

struct MemoryOptimizationExecutionResult: Sendable {
    let planID: UUID
    let startedAt: Date
    let completedAt: Date
    let completion: MemoryOptimizationCompletion
    let targetResults: [MemoryOptimizationTargetResult]
    let snapshotBefore: MemorySnapshot
    let snapshotAfter: MemorySnapshot?
    let estimatedApplicationReductionBytes: UInt64
    let observedApplicationMemoryDeltaBytes: Int64?
    let observedAvailableMemoryDeltaBytes: Int64?
    let pressureBefore: MemoryPressureLevel
    let pressureAfter: MemoryPressureLevel?
    let swapUsedBeforeBytes: UInt64?
    let swapUsedAfterBytes: UInt64?
    let attributionNotice: String
}

enum MemoryOptimizationState: Sendable {
    case idle
    case observing(MemorySnapshot)
    case planning
    case awaitingApproval(MemoryOptimizationPlan)
    case executing(planID: UUID, completedTargets: Int, totalTargets: Int)
    case verifying(planID: UUID)
    case completed(MemoryOptimizationExecutionResult)
    case cancelled
    case failed(MemoryOptimizationCoordinatorError)
}

enum MemoryOptimizationCoordinatorError: LocalizedError, Sendable, Equatable {
    case operationAlreadyRunning
    case planNotFound
    case planAlreadyConsumed
    case approvalRequired
    case forceQuitRequiresIndependentApproval
    case invalidTargets
    case probeUnavailable

    var errorDescription: String? {
        switch self {
        case .operationAlreadyRunning:
            L10n.text("已有内存优化任务正在执行。", "A memory optimization is already running.")
        case .planNotFound:
            L10n.text("内存优化计划已失效，请重新选择。", "The memory optimization plan expired; select again.")
        case .planAlreadyConsumed:
            L10n.text("该内存优化计划已经使用，不能重复执行。", "This memory optimization plan has already been used.")
        case .approvalRequired:
            L10n.text("请先确认内存优化计划。", "Approve the memory optimization plan first.")
        case .forceQuitRequiresIndependentApproval:
            L10n.text("强制退出需要单独确认。", "Force quit requires separate approval.")
        case .invalidTargets:
            L10n.text("没有可安全操作的应用。", "There are no applications that can be handled safely.")
        case .probeUnavailable:
            L10n.text("当前无法读取内存状态。", "Memory measurements are currently unavailable.")
        }
    }
}

enum MemoryByteMath {
    static func add(_ lhs: Int64, _ rhs: Int64) -> (value: Int64, clamped: Bool) {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? (Int64.max, true) : (max(0, result.partialValue), false)
    }

    static func sum<S: Sequence>(_ values: S) -> (value: Int64, clamped: Bool)
    where S.Element == Int64 {
        values.reduce(into: (value: Int64(0), clamped: false)) { partial, value in
            guard !partial.clamped else { return }
            let next = add(partial.value, max(0, value))
            partial = next
        }
    }

    static func signedDifference(_ lhs: UInt64?, _ rhs: UInt64?) -> Int64? {
        guard let lhs, let rhs else { return nil }
        if lhs >= rhs {
            return Int64(clamping: lhs - rhs)
        }
        let magnitude = Int64(clamping: rhs - lhs)
        return magnitude == Int64.max ? Int64.min + 1 : -magnitude
    }

    static func signedDifference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard result.overflow else { return result.partialValue }
        return lhs >= 0 ? Int64.max : Int64.min
    }
}

enum MemoryPressurePolicy {
    static func classify(pressureFreePercentage: Int) -> MemoryPressureLevel {
        if pressureFreePercentage <= 5 { return .critical }
        if pressureFreePercentage <= 15 { return .elevated }
        return .normal
    }

    static func classify(
        physicalBytes: Int64,
        availableBytes: Int64,
        compressedBytes: Int64,
        swapUsedBytes: Int64?,
        pressureFreePercentage: Int?
    ) -> MemoryPressureLevel {
        guard physicalBytes > 0 else { return .elevated }
        let availableRatio = min(1, max(0, Double(availableBytes) / Double(physicalBytes)))
        let compressedRatio = min(1, max(0, Double(compressedBytes) / Double(physicalBytes)))

        if let pressureFreePercentage {
            let pressureLevel = classify(
                pressureFreePercentage: pressureFreePercentage
            )
            if pressureLevel == .critical { return .critical }
        }
        if availableRatio <= 0.05 {
            return .critical
        }
        if let swapUsedBytes,
           swapUsedBytes >= 4 * 1_024 * 1024 * 1024,
           compressedRatio >= 0.30,
           availableRatio <= 0.20 {
            return .critical
        }
        if let pressureFreePercentage,
           classify(pressureFreePercentage: pressureFreePercentage) == .elevated {
            return .elevated
        }
        if availableRatio <= 0.125 {
            return .elevated
        }
        if let swapUsedBytes,
           swapUsedBytes >= 2 * 1_024 * 1024 * 1024,
           compressedRatio >= 0.25,
           availableRatio <= 0.30 {
            return .elevated
        }
        return .normal
    }
}
