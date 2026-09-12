import Foundation

typealias BenchmarkPowerReading = (
    source: BenchmarkPowerSource,
    batteryPercent: Double?
)

protocol MacBenchmarkPreflighting: Sendable {
    func capture(requiredDiskBytes: Int64) async throws -> BenchmarkPreflight
}

enum MacBenchmarkPreflightError: Error, Equatable, Sendable {
    case invalidRequiredDiskBytes
}

struct MacBenchmarkPreflightService: MacBenchmarkPreflighting, Sendable {
    private let now: @Sendable () -> Date
    private let powerProbe: @Sendable () -> BenchmarkPowerReading
    private let lowPowerModeProbe: @Sendable () -> Bool
    private let thermalProbe: @Sendable () -> BenchmarkThermalState
    private let capacityProbe: @Sendable () -> Int64
    private let diskReliabilityProbe: @Sendable () async throws -> BenchmarkDiskReliability

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        powerProbe: @escaping @Sendable () -> BenchmarkPowerReading = {
            Self.currentPowerReading()
        },
        lowPowerModeProbe: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        thermalProbe: @escaping @Sendable () -> BenchmarkThermalState = {
            Self.currentThermalState()
        },
        capacityProbe: @escaping @Sendable () -> Int64 = {
            StorageCapacityService.snapshot()?.availableBytes ?? 0
        },
        diskReliabilityProbe: @escaping @Sendable () async throws
            -> BenchmarkDiskReliability = {
                try await Self.currentDiskReliability()
            }
    ) {
        self.now = now
        self.powerProbe = powerProbe
        self.lowPowerModeProbe = lowPowerModeProbe
        self.thermalProbe = thermalProbe
        self.capacityProbe = capacityProbe
        self.diskReliabilityProbe = diskReliabilityProbe
    }

    func capture(requiredDiskBytes: Int64) async throws -> BenchmarkPreflight {
        guard requiredDiskBytes > 0 else {
            throw MacBenchmarkPreflightError.invalidRequiredDiskBytes
        }
        try Task.checkCancellation()

        async let reliability = diskReliabilityProbe()
        let capturedAt = now()
        let power = powerProbe()
        let lowPowerModeEnabled = lowPowerModeProbe()
        let thermalState = thermalProbe()
        let availableDiskBytes = max(0, capacityProbe())
        let diskReliability = try await reliability
        try Task.checkCancellation()

        let batteryPercent = power.batteryPercent.flatMap { value -> Double? in
            guard value.isFinite else { return nil }
            return min(100, max(0, value))
        }
        let draft = BenchmarkPreflight(
            capturedAt: capturedAt,
            powerSource: power.source,
            batteryPercent: batteryPercent,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            diskReliability: diskReliability,
            availableDiskBytes: availableDiskBytes,
            requiredDiskBytes: requiredDiskBytes,
            warnings: []
        )
        return BenchmarkPreflight(
            capturedAt: draft.capturedAt,
            powerSource: draft.powerSource,
            batteryPercent: draft.batteryPercent,
            lowPowerModeEnabled: draft.lowPowerModeEnabled,
            thermalState: draft.thermalState,
            diskReliability: draft.diskReliability,
            availableDiskBytes: draft.availableDiskBytes,
            requiredDiskBytes: draft.requiredDiskBytes,
            warnings: MacBenchmarkPreflightPolicy.warnings(for: draft)
        )
    }

    private static func currentPowerReading() -> BenchmarkPowerReading {
        let snapshot = BatteryPowerService.internalBatterySnapshot()
        let source: BenchmarkPowerSource
        switch BatteryPowerService.currentSystemPowerSource() {
        case .acPower:
            source = .acPower
        case .batteryPower:
            source = .battery
        case .unknown:
            source = .unknown
        }
        return (source, snapshot?.chargePercent.map(Double.init))
    }

    private static func currentThermalState() -> BenchmarkThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .unknown
        }
    }

    private static func currentDiskReliability() async throws -> BenchmarkDiskReliability {
        let worker = Task.detached(priority: .utility) { () throws -> BenchmarkDiskReliability in
            try Task.checkCancellation()
            let snapshot = DiskHealthService().snapshot()
            try Task.checkCancellation()
            switch snapshot.smartStatus {
            case .verified:
                return .verified
            case .failing:
                return .failing
            case .unsupported, .unavailable:
                return .unavailable
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}

enum MacBenchmarkPreflightPolicy {
    static let minimumBatteryPercent = 20.0

    static func warnings(for preflight: BenchmarkPreflight) -> [BenchmarkSafetyIssue] {
        var issues: [BenchmarkSafetyIssue] = []
        switch preflight.thermalState {
        case .nominal:
            break
        case .critical:
            issues.append(.thermalCritical)
        case .fair, .serious, .unknown:
            issues.append(.thermalNotNominal)
        }
        if preflight.powerSource == .battery,
           (preflight.batteryPercent ?? 0) < minimumBatteryPercent
        {
            issues.append(.batteryTooLow)
        }
        if preflight.lowPowerModeEnabled {
            issues.append(.lowPowerModeEnabled)
        }
        if preflight.powerSource != .acPower {
            issues.append(.acPowerRequired)
        }
        if preflight.diskReliability == .failing {
            issues.append(.diskReliabilityFailing)
        }
        if !preflight.hasRequiredDiskCapacity {
            issues.append(.insufficientDiskCapacity)
        }
        return issues
    }

    static func blockingIssue(in preflight: BenchmarkPreflight) -> BenchmarkSafetyIssue? {
        switch preflight.thermalState {
        case .critical:
            return .thermalCritical
        case .fair, .serious, .unknown:
            return .thermalNotNominal
        case .nominal:
            break
        }
        if preflight.diskReliability == .failing {
            return .diskReliabilityFailing
        }
        if !preflight.hasRequiredDiskCapacity {
            return .insufficientDiskCapacity
        }
        if preflight.lowPowerModeEnabled {
            return .lowPowerModeEnabled
        }
        if preflight.powerSource == .battery,
           (preflight.batteryPercent ?? 0) < minimumBatteryPercent
        {
            return .batteryTooLow
        }
        if preflight.powerSource != .acPower {
            return .acPowerRequired
        }
        return nil
    }

    static func isComparable(_ preflight: BenchmarkPreflight) -> Bool {
        blockingIssue(in: preflight) == nil
            && warnings(for: preflight) == preflight.warnings
    }
}
