import Foundation
import FanControlShared

enum GeekFanControlMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemAutomatic
    case fanSet
    case customCurve
    case manual
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemAutomatic:
            L10n.text("自动", "Automatic")
        case .fanSet:
            L10n.text("固定风扇组", "Fan Set")
        case .customCurve:
            L10n.text("曲线调节", "Custom Fan Curve")
        case .manual:
            L10n.text("手动转速", "Manual RPM")
        case .maximum:
            L10n.text("狂暴模式 · 最大转速", "Maximum Cooling · Maximum RPM")
        }
    }
}

struct FanTelemetryState: Equatable, Sendable {
    let actualRPM: Int?
    let minRPM: Int?
    let maxRPM: Int?
    let targetRPM: Int?
    let fanCount: Int
    let timestamp: Date?
    let telemetryAvailable: Bool
    let isSampling: Bool
    let isFanless: Bool
    let readings: [SystemFanReading]

    static func resolve(snapshot: SystemMonitorSnapshot?) -> Self {
        let readings: [SystemFanReading]
        if let reported = snapshot?.fanReadings, !reported.isEmpty {
            readings = reported.sorted { $0.index < $1.index }
        } else {
            readings = (snapshot?.fanSpeedsRPM ?? []).enumerated().map { index, rpm in
                SystemFanReading(
                    index: index,
                    actualRPM: rpm,
                    minimumRPM: nil,
                    maximumRPM: nil,
                    targetRPM: nil
                )
            }
        }
        let isFanless = readings.isEmpty
            && snapshot?.fanCount == 0
        let isSampling = readings.isEmpty && !isFanless
            && (snapshot == nil || snapshot?.fanAvailability == .sampling)
        return Self(
            actualRPM: average(readings.map(\.actualRPM)),
            minRPM: averageIfComplete(readings.compactMap(\.minimumRPM), count: readings.count),
            maxRPM: averageIfComplete(readings.compactMap(\.maximumRPM), count: readings.count),
            targetRPM: averageIfComplete(readings.compactMap(\.targetRPM), count: readings.count),
            fanCount: readings.count,
            timestamp: snapshot?.generatedAt,
            telemetryAvailable: !readings.isEmpty,
            isSampling: isSampling,
            isFanless: isFanless,
            readings: readings
        )
    }

    var percentage: Double? {
        let percentages = readings.compactMap(\.normalizedPercent)
        guard !readings.isEmpty, percentages.count == readings.count else { return nil }
        return min(100, max(0, percentages.reduce(0, +) / Double(percentages.count)))
    }

    var hasVerifiedRanges: Bool {
        !readings.isEmpty && readings.allSatisfy { reading in
            guard let minimumRPM = reading.minimumRPM,
                  let maximumRPM = reading.maximumRPM else { return false }
            return reading.index >= 0
                && reading.actualRPM >= 0
                && minimumRPM >= 0
                && maximumRPM > minimumRPM
        }
    }

    private static func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private static func averageIfComplete(_ values: [Int], count: Int) -> Int? {
        guard count > 0, values.count == count else { return nil }
        return average(values)
    }
}

enum HelperState: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case unavailable
    case connectionInterrupted
    case signatureRejected

    var title: String {
        switch self {
        case .notRegistered: L10n.text("尚未启用", "Not Enabled")
        case .requiresApproval: L10n.text("等待系统批准", "Awaiting System Approval")
        case .enabled: L10n.text("高级控制已启用", "Advanced Control Enabled")
        case .unavailable: L10n.text("高级控制不可用", "Advanced Control Unavailable")
        case .connectionInterrupted: L10n.text("高级控制暂不可用", "Advanced Control Temporarily Unavailable")
        case .signatureRejected: L10n.text("高级控制验证失败", "Advanced Control Validation Failed")
        }
    }
}

enum FanControlCapability: Equatable, Sendable {
    case checking
    case authorizationRequired
    case requiresSystemApproval
    case readOnly
    case controllable
    case unsupported(reason: String)
    case connectionFailed

    static func resolve(
        telemetry: FanTelemetryState,
        helperState: HelperState
    ) -> Self {
        if telemetry.isSampling { return .checking }
        if telemetry.isFanless {
            return .unsupported(reason: L10n.text("此设备采用被动散热", "This device uses passive cooling"))
        }
        guard telemetry.telemetryAvailable else {
            return .unsupported(reason: L10n.text("风扇遥测不可用", "Fan telemetry is unavailable"))
        }
        guard telemetry.hasVerifiedRanges else { return .readOnly }
        switch helperState {
        case .notRegistered:
            return .authorizationRequired
        case .requiresApproval:
            return .requiresSystemApproval
        case .enabled:
            return .controllable
        case .connectionInterrupted, .unavailable:
            return .connectionFailed
        case .signatureRejected:
            return .unsupported(reason: L10n.text("Helper 签名校验失败", "Helper signature validation failed"))
        }
    }

    var title: String {
        switch self {
        case .checking: L10n.text("检测中", "Checking")
        case .authorizationRequired: L10n.text("需要授权", "Authorization Required")
        case .requiresSystemApproval: L10n.text("等待系统批准", "Awaiting System Approval")
        case .readOnly: L10n.text("只读", "Read Only")
        case .controllable: L10n.text("支持手动控制", "Manual Control Supported")
        case .unsupported: L10n.text("不支持", "Unsupported")
        case .connectionFailed: L10n.text("高级控制暂不可用", "Advanced Control Temporarily Unavailable")
        }
    }
}

enum FanStatusPresentation {
    static func monitoringTitle(
        mode: FanControlMode,
        capability: FanControlCapability
    ) -> String {
        switch mode {
        case .systemAutomatic:
            L10n.text("自动", "Automatic")
        case .manual:
            L10n.text("手动", "Manual")
        case .temperatureCurve:
            L10n.text("曲线", "Curve")
        case .unknown:
            switch capability {
            case .checking:
                L10n.text("检测中", "Checking")
            case .authorizationRequired, .requiresSystemApproval,
                 .readOnly, .controllable, .connectionFailed:
                L10n.text("仅监测", "Monitoring Only")
            case .unsupported:
                L10n.text("不支持", "Unsupported")
            }
        }
    }
}

enum FanControlMode: Equatable, Sendable {
    case unknown
    case systemAutomatic
    case manual
    case temperatureCurve

    static func resolve(observedMode: GeekFanControlMode?) -> Self {
        switch observedMode {
        case .systemAutomatic: .systemAutomatic
        case .customCurve: .temperatureCurve
        case .fanSet, .manual, .maximum: .manual
        case nil: .unknown
        }
    }

    var title: String {
        switch self {
        case .unknown: L10n.text("仅监测", "Monitoring Only")
        case .systemAutomatic: L10n.text("系统自动", "System Automatic")
        case .manual: L10n.text("手动控制", "Manual Control")
        case .temperatureCurve: L10n.text("曲线调节", "Temperature Curve")
        }
    }
}

enum PowerModeCapability: Equatable, Sendable {
    case checking
    case automaticOnly
    case automaticAndLowPower
    case automaticLowAndHighPower
    case unsupported
    case authorizationRequired

    static func resolve(
        modes: BatteryPowerModes,
        hasCompletedRead: Bool,
        helperState: HelperState
    ) -> Self {
        guard hasCompletedRead else { return .checking }
        let supported = Set(modes.supportedBatteryModes + modes.supportedAdapterModes)
        guard !supported.isEmpty else { return .unsupported }
        guard helperState == .enabled else { return .authorizationRequired }
        if supported.contains(.highPower) { return .automaticLowAndHighPower }
        if supported.contains(.lowPower) { return .automaticAndLowPower }
        return .automaticOnly
    }
}

enum GeekFanControlAvailability {
    static func availableModes(
        capability: HardwareFanCapability
    ) -> [GeekFanControlMode] {
        guard capability.supportsWriting else { return [.systemAutomatic] }
        return [.systemAutomatic]
            + (capability.supportsCustomCurve ? [.customCurve] : [])
            + [.manual, .maximum]
    }
}

struct HardwareFanCapability: Equatable, Sendable {
    struct Fan: Equatable, Sendable, Identifiable {
        let id: Int
        let name: String
        let currentRPM: Int
        let minimumRPM: Int?
        let maximumRPM: Int?
        let targetRPM: Int?

        var hasWritableRange: Bool {
            guard let minimumRPM, let maximumRPM else { return false }
            return minimumRPM >= 0 && maximumRPM > minimumRPM
        }
    }

    let supportsReading: Bool
    let fans: [Fan]
    let supportsWriting: Bool
    let requiresPrivilegedHelper: Bool
    let observedMode: GeekFanControlMode?
    let temperatureSensors: [SystemTemperatureZone]

    var hasWritableRanges: Bool {
        !fans.isEmpty
            && Set(fans.map(\.id)).count == fans.count
            && fans.allSatisfy {
            $0.id >= 0 && $0.currentRPM >= 0 && $0.hasWritableRange
        }
    }

    var supportsCustomCurve: Bool {
        supportsWriting && !temperatureSensors.isEmpty
    }
}

enum HardwareFanCapabilityProbe {
    static func probe(
        fanReadings: [SystemFanReading],
        temperatureReadings: [SystemTemperatureReading],
        hasTrustedHelper: Bool,
        observedMode: GeekFanControlMode?
    ) -> HardwareFanCapability {
        let fans = fanReadings.map { reading in
            HardwareFanCapability.Fan(
                id: reading.index,
                name: reading.displayName,
                currentRPM: reading.actualRPM,
                minimumRPM: reading.minimumRPM,
                maximumRPM: reading.maximumRPM,
                targetRPM: reading.targetRPM
            )
        }
        let temperatureSensors = Array(Set(temperatureReadings.map(\.zone)))
            .sorted { $0.rawValue < $1.rawValue }
        let hasUniqueFanIDs = Set(fans.map(\.id)).count == fans.count
        let hasValidFanReadings = fans.allSatisfy {
            $0.id >= 0 && $0.currentRPM >= 0
        }
        let hasWritableRanges = !fans.isEmpty
            && hasUniqueFanIDs
            && hasValidFanReadings
            && fans.allSatisfy(\.hasWritableRange)
        let supportsWriting = hasTrustedHelper && hasWritableRanges
        return HardwareFanCapability(
            supportsReading: !fans.isEmpty,
            fans: fans,
            supportsWriting: supportsWriting,
            requiresPrivilegedHelper: hasWritableRanges && !hasTrustedHelper,
            observedMode: supportsWriting ? observedMode : nil,
            temperatureSensors: temperatureSensors
        )
    }
}

enum FanControlSet: String, CaseIterable, Codable, Identifiable, Sendable {
    case balanced
    case cooling
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            L10n.text("均衡 · 60%", "Balanced · 60%")
        case .cooling:
            L10n.text("加强散热 · 75%", "Extra Cooling · 75%")
        case .maximum:
            L10n.text("全速 · 100%", "Maximum · 100%")
        }
    }

    var fraction: Double {
        switch self {
        case .balanced: 0.60
        case .cooling: 0.75
        case .maximum: 1
        }
    }
}

struct FanCurveConfiguration: Codable, Equatable, Sendable {
    // Legacy settings migration only. Runtime curve control uses the stricter
    // FanCurveProfile validator in both the app and helper.
    static let temperatureRange = 30.0...105.0
    static let minimumPointCount = 2
    static let maximumPointCount = FanCurveProfile.maximumPointCount

    var synchronizesFans: Bool
    var sharedPoints: [FanCurvePoint]
    var pointsByFan: [Int: [FanCurvePoint]]

    static var `default`: Self {
        Self(
            synchronizesFans: true,
            sharedPoints: defaultPoints,
            pointsByFan: [:]
        )
    }

    static var defaultPoints: [FanCurvePoint] {
        FanCurveProfile.balanced().points
    }

    static func migrated(lowTemperature: Double, highTemperature: Double) -> Self {
        let low = min(
            temperatureRange.upperBound - 3,
            max(temperatureRange.lowerBound, lowTemperature)
        )
        let high = max(
            low + 3,
            min(temperatureRange.upperBound, highTemperature)
        )
        let span = high - low
        return Self(
            synchronizesFans: true,
            sharedPoints: [
                FanCurvePoint(temperatureCelsius: low, speedFraction: 0.40),
                FanCurvePoint(temperatureCelsius: low + span / 3, speedFraction: 0.58),
                FanCurvePoint(temperatureCelsius: low + span * 2 / 3, speedFraction: 0.78),
                FanCurvePoint(temperatureCelsius: high, speedFraction: 1.00),
            ],
            pointsByFan: [:]
        ).normalized()
    }

    func points(forFanID fanID: Int) -> [FanCurvePoint] {
        synchronizesFans ? sharedPoints : (pointsByFan[fanID] ?? sharedPoints)
    }

    mutating func setPoints(_ points: [FanCurvePoint], forFanID fanID: Int?) {
        let normalized = Self.normalizedPoints(points)
        if synchronizesFans || fanID == nil {
            sharedPoints = normalized
        } else if let fanID {
            pointsByFan[fanID] = normalized
        }
    }

    func normalized() -> Self {
        var copy = self
        copy.sharedPoints = Self.normalizedPoints(sharedPoints)
        copy.pointsByFan = pointsByFan.reduce(
            into: [Int: [FanCurvePoint]]()
        ) { result, entry in
            guard entry.key >= 0 else { return }
            result[entry.key] = Self.normalizedPoints(entry.value)
        }
        return copy
    }

    static func normalizedPoints(_ points: [FanCurvePoint]) -> [FanCurvePoint] {
        let usable = points
            .filter { $0.temperatureCelsius.isFinite && $0.speedFraction.isFinite }
            .sorted { lhs, rhs in
                lhs.temperatureCelsius == rhs.temperatureCelsius
                    ? lhs.speedFraction < rhs.speedFraction
                    : lhs.temperatureCelsius < rhs.temperatureCelsius
            }

        var result: [FanCurvePoint] = []
        var usedIDs = Set<UUID>()
        var previousTemperature = temperatureRange.lowerBound - 1
        var previousFraction = 0.0
        for original in usable.prefix(maximumPointCount) {
            var point = original
            point.temperatureCelsius = min(
                temperatureRange.upperBound,
                max(temperatureRange.lowerBound, point.temperatureCelsius.rounded())
            )
            point.temperatureCelsius = max(
                point.temperatureCelsius,
                previousTemperature + 1
            )
            guard point.temperatureCelsius <= temperatureRange.upperBound else { continue }
            point.speedFraction = max(
                previousFraction,
                min(1, max(0, point.speedFraction))
            )
            if !usedIDs.insert(point.id).inserted {
                point.id = UUID()
                usedIDs.insert(point.id)
            }
            result.append(point)
            previousTemperature = point.temperatureCelsius
            previousFraction = point.speedFraction
        }
        guard result.count >= minimumPointCount else { return defaultPoints }
        return result
    }
}

enum FanControlPreferences {
    static let modeKey = "fanControl.mode"
    static let setKey = "fanControl.set"
    static let manualFractionKey = "fanControl.manualFraction"
    static let curveLowTemperatureKey = "fanControl.curveLowTemperature"
    static let curveHighTemperatureKey = "fanControl.curveHighTemperature"
    static let curveConfigurationKey = "fanControl.curveConfiguration.v1"

    static let defaultManualFraction = 0.70
    static let defaultCurveLowTemperature = 48.0
    static let defaultCurveHighTemperature = 86.0
}

struct FanControlPlan: Equatable, Sendable {
    let targetRPMByFan: [Int: Int]
    let automaticFanIDs: [Int]
    let restoresAllFans: Bool

    static let restoreAll = FanControlPlan(
        targetRPMByFan: [:],
        automaticFanIDs: [],
        restoresAllFans: true
    )
}

enum FanTargetProgressState: Equatable, Sendable {
    case increasing
    case decreasing
    case reached

    static func resolve(actualRPM: Int, targetRPM: Int) -> Self {
        let tolerance = max(100, Int(Double(targetRPM) * 0.05))
        if abs(actualRPM - targetRPM) <= tolerance { return .reached }
        return actualRPM < targetRPM ? .increasing : .decreasing
    }
}

enum FanControlSafetyPolicy {
    // Matches the hardware-facing SystemMonitorSnapshot validation boundary.
    static let sensorTemperatureRange = 5.0...130.0
    static let minimumUpdateInterval: TimeInterval = 2
    static let manualControlDebounce: TimeInterval = 0.15
    static let leaseRenewalInterval: TimeInterval = 5
    static let maximumRPMChangePerSecond = 500
    static let feedbackGracePeriod: TimeInterval = 12
    /// The helper restores automatic control when renewals stop for this
    /// long. 30s tolerates AppKit event-tracking pauses (menus, window
    /// drags) that freeze MainActor renewals, while still guaranteeing the
    /// fans return to system control shortly after the app dies.
    static let watchdogSeconds: TimeInterval = 30
    static let helperRequestTimeout: TimeInterval = 5
    /// First control on some Apple Silicon firmware must wait for the thermal
    /// manager to release its SMC latch. Keep this below the helper watchdog.
    static let fanWriteRequestTimeout: TimeInterval = 25
    static let powerModeRequestTimeout: TimeInterval = 15

    static func rateLimited(
        _ plan: FanControlPlan,
        fanReadings: [SystemFanReading],
        previousTargets: [Int: Int],
        elapsed: TimeInterval
    ) -> FanControlPlan {
        guard !plan.restoresAllFans else { return plan }
        let readings = fanReadings.reduce(into: [Int: SystemFanReading]()) {
            if $0[$1.index] == nil { $0[$1.index] = $1 }
        }
        let allowedChange = max(
            1,
            Int(Double(maximumRPMChangePerSecond) * max(0, elapsed))
        )
        let targets = plan.targetRPMByFan.compactMapValues { target in target }
            .reduce(into: [Int: Int]()) { result, entry in
                let fanID = entry.key
                let requested = entry.value
                guard let reading = readings[fanID],
                      let minimum = reading.minimumRPM,
                      let maximum = reading.maximumRPM else { return }
                let baseline = previousTargets[fanID] ?? reading.actualRPM
                result[fanID] = min(
                    maximum,
                    max(
                        minimum,
                        min(baseline + allowedChange, max(baseline - allowedChange, requested))
                    )
                )
            }
        return FanControlPlan(
            targetRPMByFan: targets,
            automaticFanIDs: plan.automaticFanIDs,
            restoresAllFans: false
        )
    }

    static func validatedAppliedTargets(
        expected: [Int: Int],
        applied: [Int: Int],
        fanReadings: [SystemFanReading]
    ) -> Bool {
        guard expected.count == applied.count,
              Set(expected.keys) == Set(applied.keys) else {
            return false
        }
        let readings = fanReadings.reduce(into: [Int: SystemFanReading]()) {
            if $0[$1.index] == nil { $0[$1.index] = $1 }
        }
        return expected.allSatisfy { fanID, requested in
            guard let appliedRPM = applied[fanID],
                  let reading = readings[fanID],
                  let minimumRPM = reading.minimumRPM,
                  let maximumRPM = reading.maximumRPM,
                  minimumRPM >= 0,
                  maximumRPM > minimumRPM else {
                return false
            }
            return appliedRPM == requested
                && (minimumRPM...maximumRPM).contains(appliedRPM)
        }
    }
}

enum FanControlPlanner {
    static let minimumBoostRPM = 120

    static func plan(
        mode: GeekFanControlMode,
        fanSet: FanControlSet,
        manualFraction: Double,
        manualFractionByFan: [Int: Double] = [:],
        synchronizesManualFans: Bool = true,
        curveLowTemperature: Double,
        curveHighTemperature: Double,
        thermalState: SystemThermalState,
        fanReadings: [SystemFanReading]?,
        temperatureReadings: [SystemTemperatureReading]?,
        curveConfiguration: FanCurveConfiguration? = nil
    ) -> FanControlPlan? {
        guard mode != .systemAutomatic else { return .restoreAll }
        guard thermalState != .serious, thermalState != .critical else {
            return .restoreAll
        }
        guard let fanReadings, !fanReadings.isEmpty else { return nil }
        guard Set(fanReadings.map(\.index)).count == fanReadings.count,
              fanReadings.allSatisfy({ $0.index >= 0 && $0.actualRPM >= 0 }) else {
            return nil
        }

        let fraction: Double
        var curveTemperature: Double?
        switch mode {
        case .systemAutomatic:
            return .restoreAll
        case .fanSet:
            fraction = fanSet.fraction
        case .manual:
            fraction = normalizedFraction(manualFraction)
        case .maximum:
            fraction = 1
        case .customCurve:
            guard let temperatureReadings,
                  !temperatureReadings.isEmpty,
                  temperatureReadings.allSatisfy({
                      $0.celsius.isFinite
                          && FanControlSafetyPolicy.sensorTemperatureRange.contains(
                              $0.celsius
                          )
                  }),
                  let hottestTemperature = temperatureReadings
                  .map(\.celsius)
                  .max() else {
                return nil
            }
            fraction = curveFraction(
                temperature: hottestTemperature,
                lowTemperature: curveLowTemperature,
                highTemperature: curveHighTemperature
            )
            curveTemperature = hottestTemperature
        }

        var targets: [Int: Int] = [:]
        var automaticFanIDs: [Int] = []

        for reading in fanReadings {
            guard let minimumRPM = reading.minimumRPM,
                  let maximumRPM = reading.maximumRPM,
                  minimumRPM >= 0,
                  maximumRPM > minimumRPM else {
                return nil
            }
            let fanFraction: Double
            if mode == .manual, !synchronizesManualFans {
                fanFraction = normalizedFraction(
                    manualFractionByFan[reading.index] ?? manualFraction
                )
            } else if let curveTemperature, let curveConfiguration {
                fanFraction = curveFraction(
                    temperature: curveTemperature,
                    points: curveConfiguration.points(forFanID: reading.index)
                )
            } else {
                fanFraction = fraction
            }
            let clampedRPM = targetRPM(
                minimumRPM: minimumRPM,
                maximumRPM: maximumRPM,
                fraction: fanFraction
            )

            // Fan-set and curve modes are cooling overlays above Apple's
            // thermal floor. Manual and maximum modes are explicit targets,
            // even when the requested RPM is close to or below the current RPM.
            let requiresExplicitTarget = mode == .manual || mode == .maximum
            if requiresExplicitTarget
                || clampedRPM >= reading.actualRPM + minimumBoostRPM {
                targets[reading.index] = clampedRPM
            } else {
                automaticFanIDs.append(reading.index)
            }
        }

        return FanControlPlan(
            targetRPMByFan: targets,
            automaticFanIDs: automaticFanIDs.sorted(),
            restoresAllFans: false
        )
    }

    static func curveFraction(
        temperature: Double,
        lowTemperature: Double,
        highTemperature: Double
    ) -> Double {
        let low = min(lowTemperature, highTemperature - 1)
        let high = max(highTemperature, low + 1)
        let progress = (temperature - low) / (high - low)
        return 0.40 + normalizedFraction(progress) * 0.60
    }

    static func curveFraction(
        temperature: Double,
        points: [FanCurvePoint]
    ) -> Double {
        let points = FanCurveConfiguration.normalizedPoints(points)
        guard let first = points.first, let last = points.last else { return 0 }
        if temperature <= first.temperatureCelsius { return first.speedFraction }
        if temperature >= last.temperatureCelsius { return last.speedFraction }

        guard let upperIndex = points.firstIndex(where: {
            $0.temperatureCelsius >= temperature
        }), upperIndex > points.startIndex else {
            return first.speedFraction
        }
        let lower = points[points.index(before: upperIndex)]
        let upper = points[upperIndex]
        let progress = (temperature - lower.temperatureCelsius)
            / (upper.temperatureCelsius - lower.temperatureCelsius)
        return normalizedFraction(
            lower.speedFraction
                + (upper.speedFraction - lower.speedFraction) * progress
        )
    }

    static func targetRPM(
        minimumRPM: Int,
        maximumRPM: Int,
        fraction: Double
    ) -> Int {
        let desiredRPM = Int((
            Double(minimumRPM)
                + Double(maximumRPM - minimumRPM) * normalizedFraction(fraction)
        ).rounded())
        return min(maximumRPM, max(minimumRPM, desiredRPM))
    }

    static func manualEntryFraction(
        fanReadings: [SystemFanReading]?
    ) -> Double? {
        guard let fanReadings,
              !fanReadings.isEmpty,
              Set(fanReadings.map(\.index)).count == fanReadings.count else {
            return nil
        }
        let fractions = fanReadings.compactMap { reading -> Double? in
            guard let minimumRPM = reading.minimumRPM,
                  let maximumRPM = reading.maximumRPM,
                  minimumRPM >= 0,
                  maximumRPM > minimumRPM,
                  reading.actualRPM >= 0 else {
                return nil
            }
            return normalizedFraction(
                Double(reading.actualRPM - minimumRPM)
                    / Double(maximumRPM - minimumRPM)
            )
        }
        guard fractions.count == fanReadings.count else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    private static func normalizedFraction(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

enum FanControlHelperProtocolContract {
    static let currentVersion = 2
}

enum FanControlHelperErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case unsupportedHardware
    case pmsetFailed
    case pmsetVerificationFailed
    case smcReadFailed
    case smcWriteFailed
    case fanVerificationFailed
    case fanLeaseExpired
    case partialFanWriteFailure
    case invalidCurvePointCount
    case invalidCurveTemperature
    case invalidCurvePercentage
    case nonIncreasingTemperatures
    case decreasingFanPercentage
    case missingFullSpeedPoint
    case fullSpeedPointTooHot
    case sensorUnavailable
    case sensorStale
    case fanRangeUnavailable
    case curveActivationFailed
    case curveUpdateFailed
    case curveVerificationFailed
    case curveLeaseExpired
    case thermalProtectionActivated
}

struct FanControlPowerConfiguration: Codable, Equatable, Sendable {
    let battery: BatteryPowerMode?
    let adapter: BatteryPowerMode?
    let supportedBatteryModes: [BatteryPowerMode]
    let supportedAdapterModes: [BatteryPowerMode]
    let batterySetting: BatteryPowerModeSettingKey?
    let adapterSetting: BatteryPowerModeSettingKey?

    var batteryPowerModes: BatteryPowerModes {
        BatteryPowerModes(
            battery: battery,
            adapter: adapter,
            supportedBatteryModes: supportedBatteryModes,
            supportedAdapterModes: supportedAdapterModes,
            batterySetting: batterySetting,
            adapterSetting: adapterSetting
        )
    }

    func matches(_ command: BatteryPowerModeWriteCommand) -> Bool {
        batteryPowerModes.currentMode(for: command.source) == command.mode
            && batteryPowerModes.setting(for: command.source) == command.setting
    }
}

struct FanControlHelperRequest: Codable, Sendable {
    enum Operation: String, Codable, Equatable, Sendable {
        case ping
        case readPowerConfiguration
        case apply
        case renewFanControlLease
        case restoreAutomatic
        case applyPowerMode
        case validateFanCurve
        case activateFanCurve
        case updateFanCurve
        case getFanCurveRuntimeState
        case deactivateFanCurve
    }

    let protocolVersion: Int
    let operation: Operation
    let targetRPMByFan: [Int: Int]
    let automaticFanIDs: [Int]
    let allowsRPMDecrease: Bool
    let watchdogSeconds: Double
    let powerModeSource: String?
    let powerModeSetting: String?
    let powerModeValue: Int?
    let curveProfile: FanCurveProfile?
    let curveLeaseID: UUID?

    init(
        protocolVersion: Int = FanControlHelperProtocolContract.currentVersion,
        operation: Operation,
        targetRPMByFan: [Int: Int],
        automaticFanIDs: [Int],
        allowsRPMDecrease: Bool,
        watchdogSeconds: Double,
        powerModeSource: String?,
        powerModeSetting: String?,
        powerModeValue: Int?,
        curveProfile: FanCurveProfile? = nil,
        curveLeaseID: UUID? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.targetRPMByFan = targetRPMByFan
        self.automaticFanIDs = automaticFanIDs
        self.allowsRPMDecrease = allowsRPMDecrease
        self.watchdogSeconds = watchdogSeconds
        self.powerModeSource = powerModeSource
        self.powerModeSetting = powerModeSetting
        self.powerModeValue = powerModeValue
        self.curveProfile = curveProfile
        self.curveLeaseID = curveLeaseID
    }

    static let ping = FanControlHelperRequest(
        operation: .ping,
        targetRPMByFan: [:],
        automaticFanIDs: [],
        allowsRPMDecrease: false,
        watchdogSeconds: 0,
        powerModeSource: nil,
        powerModeSetting: nil,
        powerModeValue: nil
    )

    static let readPowerConfiguration = FanControlHelperRequest(
        operation: .readPowerConfiguration,
        targetRPMByFan: [:],
        automaticFanIDs: [],
        allowsRPMDecrease: false,
        watchdogSeconds: 0,
        powerModeSource: nil,
        powerModeSetting: nil,
        powerModeValue: nil
    )

    static let renewFanControlLease = FanControlHelperRequest(
        operation: .renewFanControlLease,
        targetRPMByFan: [:],
        automaticFanIDs: [],
        allowsRPMDecrease: false,
        watchdogSeconds: FanControlSafetyPolicy.watchdogSeconds,
        powerModeSource: nil,
        powerModeSetting: nil,
        powerModeValue: nil
    )

    static let restoreAutomatic = FanControlHelperRequest(
        operation: .restoreAutomatic,
        targetRPMByFan: [:],
        automaticFanIDs: [],
        allowsRPMDecrease: false,
        watchdogSeconds: 0,
        powerModeSource: nil,
        powerModeSetting: nil,
        powerModeValue: nil
    )

    static func apply(
        _ plan: FanControlPlan,
        allowsRPMDecrease: Bool = false
    ) -> FanControlHelperRequest {
        if plan.restoresAllFans {
            return .restoreAutomatic
        }
        return FanControlHelperRequest(
            operation: .apply,
            targetRPMByFan: plan.targetRPMByFan,
            automaticFanIDs: plan.automaticFanIDs,
            allowsRPMDecrease: allowsRPMDecrease,
            watchdogSeconds: FanControlSafetyPolicy.watchdogSeconds,
            powerModeSource: nil,
            powerModeSetting: nil,
            powerModeValue: nil
        )
    }

    static func applyPowerMode(
        _ command: BatteryPowerModeWriteCommand
    ) -> FanControlHelperRequest? {
        guard command.isWhitelisted,
              command.arguments.count == 3,
              let value = Int(command.arguments[2]) else {
            return nil
        }
        return FanControlHelperRequest(
            operation: .applyPowerMode,
            targetRPMByFan: [:],
            automaticFanIDs: [],
            allowsRPMDecrease: false,
            watchdogSeconds: 0,
            powerModeSource: command.arguments[0],
            powerModeSetting: command.arguments[1],
            powerModeValue: value
        )
    }

    static func validateFanCurve(
        _ profile: FanCurveProfile
    ) -> FanControlHelperRequest {
        FanControlHelperRequest(
            operation: .validateFanCurve,
            targetRPMByFan: [:],
            automaticFanIDs: [],
            allowsRPMDecrease: false,
            watchdogSeconds: 0,
            powerModeSource: nil,
            powerModeSetting: nil,
            powerModeValue: nil,
            curveProfile: profile
        )
    }

    static func activateFanCurve(
        _ profile: FanCurveProfile,
        leaseID: UUID
    ) -> FanControlHelperRequest {
        curveRequest(operation: .activateFanCurve, profile: profile, leaseID: leaseID)
    }

    static func updateFanCurve(
        _ profile: FanCurveProfile,
        leaseID: UUID
    ) -> FanControlHelperRequest {
        curveRequest(operation: .updateFanCurve, profile: profile, leaseID: leaseID)
    }

    static func renewFanCurveLease(_ leaseID: UUID) -> FanControlHelperRequest {
        FanControlHelperRequest(
            operation: .renewFanControlLease,
            targetRPMByFan: [:],
            automaticFanIDs: [],
            allowsRPMDecrease: false,
            watchdogSeconds: FanControlSafetyPolicy.watchdogSeconds,
            powerModeSource: nil,
            powerModeSetting: nil,
            powerModeValue: nil,
            curveLeaseID: leaseID
        )
    }

    static let getFanCurveRuntimeState = FanControlHelperRequest(
        operation: .getFanCurveRuntimeState,
        targetRPMByFan: [:],
        automaticFanIDs: [],
        allowsRPMDecrease: false,
        watchdogSeconds: 0,
        powerModeSource: nil,
        powerModeSetting: nil,
        powerModeValue: nil
    )

    static let deactivateFanCurve = FanControlHelperRequest(
        operation: .deactivateFanCurve,
        targetRPMByFan: [:],
        automaticFanIDs: [],
        allowsRPMDecrease: false,
        watchdogSeconds: 0,
        powerModeSource: nil,
        powerModeSetting: nil,
        powerModeValue: nil
    )

    private static func curveRequest(
        operation: Operation,
        profile: FanCurveProfile,
        leaseID: UUID
    ) -> FanControlHelperRequest {
        FanControlHelperRequest(
            operation: operation,
            targetRPMByFan: [:],
            automaticFanIDs: [],
            allowsRPMDecrease: false,
            watchdogSeconds: FanControlSafetyPolicy.watchdogSeconds,
            powerModeSource: nil,
            powerModeSetting: nil,
            powerModeValue: nil,
            curveProfile: profile,
            curveLeaseID: leaseID
        )
    }
}

struct FanControlHelperReply: Codable, Equatable, Sendable {
    let protocolVersion: Int?
    let operation: FanControlHelperRequest.Operation?
    let success: Bool
    let message: String
    let appliedTargetRPMByFan: [Int: Int]
    let powerConfiguration: FanControlPowerConfiguration?
    let curveRuntimeState: FanCurveRuntimeState?
    let errorCode: FanControlHelperErrorCode?

    init(
        protocolVersion: Int? = FanControlHelperProtocolContract.currentVersion,
        operation: FanControlHelperRequest.Operation? = nil,
        success: Bool,
        message: String,
        appliedTargetRPMByFan: [Int: Int],
        powerConfiguration: FanControlPowerConfiguration? = nil,
        curveRuntimeState: FanCurveRuntimeState? = nil,
        errorCode: FanControlHelperErrorCode? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.success = success
        self.message = message
        self.appliedTargetRPMByFan = appliedTargetRPMByFan
        self.powerConfiguration = powerConfiguration
        self.curveRuntimeState = curveRuntimeState
        self.errorCode = errorCode
    }

    func validated(for request: FanControlHelperRequest) throws -> Self {
        guard let protocolVersion else {
            throw FanControlHelperProtocolError.missingProtocolVersion
        }
        guard protocolVersion == FanControlHelperProtocolContract.currentVersion else {
            throw FanControlHelperProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        guard let operation else {
            throw FanControlHelperProtocolError.missingResponseOperation
        }
        guard operation == request.operation else {
            throw FanControlHelperProtocolError.operationMismatch(
                expected: request.operation,
                received: operation
            )
        }
        let requiresCurveState = [
            .validateFanCurve,
            .activateFanCurve,
            .updateFanCurve,
            .getFanCurveRuntimeState,
        ].contains(request.operation)
            || (request.operation == .renewFanControlLease
                && request.curveLeaseID != nil)
        if success,
           requiresCurveState,
           curveRuntimeState == nil {
            throw FanControlHelperProtocolError.missingCurveRuntimeState
        }
        return self
    }
}

enum FanControlHelperProtocolError: Error, Equatable, LocalizedError, Sendable {
    case missingProtocolVersion
    case unsupportedProtocolVersion(Int)
    case missingResponseOperation
    case missingCurveRuntimeState
    case operationMismatch(
        expected: FanControlHelperRequest.Operation,
        received: FanControlHelperRequest.Operation
    )

    var errorDescription: String? {
        switch self {
        case .missingProtocolVersion:
            L10n.text(
                "检测到旧版系统控制辅助程序协议；未发送风扇转速，系统控制保持关闭。",
                "A legacy system-control helper protocol was detected. No fan RPM was sent and system control remains disabled."
            )
        case .unsupportedProtocolVersion(let version):
            L10n.text(
                "系统控制辅助程序协议版本不兼容（\(version)）；未发送风扇转速。",
                "The system-control helper protocol version is incompatible (\(version)); no fan RPM was sent."
            )
        case .missingResponseOperation:
            L10n.text(
                "系统控制辅助程序未回报请求类型；未发送风扇转速。",
                "The system-control helper did not echo the request operation; no fan RPM was sent."
            )
        case .missingCurveRuntimeState:
            L10n.text(
                "系统控制辅助程序未返回温控曲线运行状态；已停止自定义控制。",
                "The helper did not return fan-curve runtime state; custom control was stopped."
            )
        case .operationMismatch(let expected, let received):
            L10n.text(
                "系统控制辅助程序回报类型不匹配（请求 \(expected.rawValue)，收到 \(received.rawValue)）；未发送风扇转速。",
                "The system-control helper response operation did not match (expected \(expected.rawValue), received \(received.rawValue)); no fan RPM was sent."
            )
        }
    }
}
