import Foundation

public struct FanCurvePoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var temperatureCelsius: Double
    public var speedFraction: Double

    public init(
        id: UUID = UUID(),
        temperatureCelsius: Double,
        speedFraction: Double
    ) {
        self.id = id
        self.temperatureCelsius = temperatureCelsius
        self.speedFraction = speedFraction
    }

    public var fanPercentage: Double {
        speedFraction * 100
    }
}

public enum FanCurveSensor: String, CaseIterable, Codable, Identifiable, Sendable {
    case chipMaximum
    case cpu
    case gpu
    case performanceCore
    case efficiencyCore

    public var id: String { rawValue }
}

public struct FanCurveProfile: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1
    public static let temperatureRange = 25.0...100.0
    public static let minimumPointCount = 3
    public static let maximumPointCount = 8
    public static let minimumTemperatureGap = 2.0
    public static let latestFullSpeedTemperature = 90.0

    public var id: UUID
    public var name: String
    public var sensor: FanCurveSensor
    public var points: [FanCurvePoint]
    public var targetFanIDs: [Int]
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sensor: FanCurveSensor,
        points: [FanCurvePoint],
        targetFanIDs: [Int],
        version: Int = currentVersion,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sensor = sensor
        self.points = points
        self.targetFanIDs = targetFanIDs
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func balanced(
        targetFanIDs: [Int] = [],
        now: Date = Date()
    ) -> Self {
        Self(
            name: "Balanced",
            sensor: .chipMaximum,
            points: [
                FanCurvePoint(temperatureCelsius: 40, speedFraction: 0.20),
                FanCurvePoint(temperatureCelsius: 55, speedFraction: 0.35),
                FanCurvePoint(temperatureCelsius: 65, speedFraction: 0.55),
                FanCurvePoint(temperatureCelsius: 75, speedFraction: 0.75),
                FanCurvePoint(temperatureCelsius: 85, speedFraction: 1.00),
            ],
            targetFanIDs: targetFanIDs,
            createdAt: now,
            updatedAt: now
        )
    }

    public func replacingTargetFanIDs(_ fanIDs: [Int], now: Date = Date()) -> Self {
        var copy = self
        copy.targetFanIDs = fanIDs.sorted()
        copy.updatedAt = now
        return copy
    }

    public func hasSameControlDefinition(as other: Self?) -> Bool {
        guard let other else { return false }
        return sensor == other.sensor
            && points == other.points
            && targetFanIDs == other.targetFanIDs
            && version == other.version
            && name == other.name
    }
}

public enum FanCurveError: String, Codable, Error, Equatable, Sendable {
    case invalidCurvePointCount
    case invalidCurveTemperature
    case invalidCurvePercentage
    case nonIncreasingTemperatures
    case decreasingFanPercentage
    case missingFullSpeedPoint
    case fullSpeedPointTooHot
    case unsupportedProfileVersion
    case unsupportedSensor
    case invalidTargetFans
    case sensorUnavailable
    case sensorStale
    case fanRangeUnavailable
    case curveActivationFailed
    case curveUpdateFailed
    case curveVerificationFailed
    case curveLeaseExpired
    case thermalProtectionActivated
}

public enum FanCurveValidator {
    public static func validate(
        _ profile: FanCurveProfile,
        allowedSensors: Set<FanCurveSensor>? = nil,
        availableFanIDs: Set<Int>? = nil,
        requiresTargetFans: Bool = false
    ) throws {
        guard profile.version == FanCurveProfile.currentVersion else {
            throw FanCurveError.unsupportedProfileVersion
        }
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64 else {
            throw FanCurveError.curveActivationFailed
        }
        if let allowedSensors, !allowedSensors.contains(profile.sensor) {
            throw FanCurveError.unsupportedSensor
        }
        let fanIDs = profile.targetFanIDs
        guard fanIDs.count <= 16,
              (!requiresTargetFans || !fanIDs.isEmpty),
              Set(fanIDs).count == fanIDs.count,
              fanIDs.allSatisfy({ (0..<16).contains($0) }) else {
            throw FanCurveError.invalidTargetFans
        }
        if let availableFanIDs,
           !Set(fanIDs).isSubset(of: availableFanIDs) {
            throw FanCurveError.invalidTargetFans
        }

        let points = profile.points
        guard (FanCurveProfile.minimumPointCount...FanCurveProfile.maximumPointCount)
            .contains(points.count),
              Set(points.map(\.id)).count == points.count else {
            throw FanCurveError.invalidCurvePointCount
        }

        var previous: FanCurvePoint?
        for point in points {
            guard point.temperatureCelsius.isFinite,
                  FanCurveProfile.temperatureRange.contains(point.temperatureCelsius) else {
                throw FanCurveError.invalidCurveTemperature
            }
            guard point.speedFraction.isFinite,
                  (0...1).contains(point.speedFraction) else {
                throw FanCurveError.invalidCurvePercentage
            }
            if let previous {
                guard point.temperatureCelsius > previous.temperatureCelsius else {
                    throw FanCurveError.nonIncreasingTemperatures
                }
                guard point.temperatureCelsius - previous.temperatureCelsius
                    >= FanCurveProfile.minimumTemperatureGap else {
                    throw FanCurveError.nonIncreasingTemperatures
                }
                guard point.speedFraction >= previous.speedFraction else {
                    throw FanCurveError.decreasingFanPercentage
                }
            }
            previous = point
        }

        guard let last = points.last, last.speedFraction == 1 else {
            throw FanCurveError.missingFullSpeedPoint
        }
        guard last.temperatureCelsius <= FanCurveProfile.latestFullSpeedTemperature else {
            throw FanCurveError.fullSpeedPointTooHot
        }
    }
}

public enum FanCurveInterpolator {
    public static func percentage(
        at temperature: Double,
        profile: FanCurveProfile
    ) throws -> Double {
        try FanCurveValidator.validate(profile)
        return percentage(at: temperature, points: profile.points)
    }

    public static func percentage(
        at temperature: Double,
        points: [FanCurvePoint]
    ) -> Double {
        guard temperature.isFinite,
              let first = points.first,
              let last = points.last else { return 0 }
        if temperature <= first.temperatureCelsius { return first.fanPercentage }
        if temperature >= last.temperatureCelsius { return 100 }

        guard let upperIndex = points.firstIndex(where: {
            $0.temperatureCelsius >= temperature
        }), upperIndex > points.startIndex else {
            return first.fanPercentage
        }
        let lower = points[points.index(before: upperIndex)]
        let upper = points[upperIndex]
        let progress = (temperature - lower.temperatureCelsius)
            / (upper.temperatureCelsius - lower.temperatureCelsius)
        return min(100, max(0,
            lower.fanPercentage
                + (upper.fanPercentage - lower.fanPercentage) * progress
        ))
    }

    public static func temperature(
        forPercentage percentage: Double,
        points: [FanCurvePoint]
    ) -> Double? {
        guard percentage.isFinite,
              let first = points.first,
              let last = points.last else { return nil }
        if percentage <= first.fanPercentage { return first.temperatureCelsius }
        if percentage >= 100 { return last.temperatureCelsius }
        guard let upperIndex = points.firstIndex(where: {
            $0.fanPercentage >= percentage
        }), upperIndex > points.startIndex else {
            return first.temperatureCelsius
        }
        let lower = points[points.index(before: upperIndex)]
        let upper = points[upperIndex]
        let span = upper.fanPercentage - lower.fanPercentage
        guard span > 0 else { return upper.temperatureCelsius }
        let progress = (percentage - lower.fanPercentage) / span
        return lower.temperatureCelsius
            + (upper.temperatureCelsius - lower.temperatureCelsius) * progress
    }
}

public struct FanCurveFanRange: Codable, Equatable, Sendable {
    public let fanID: Int
    public let minimumRPM: Int
    public let maximumRPM: Int
    public let actualRPM: Int

    public init(fanID: Int, minimumRPM: Int, maximumRPM: Int, actualRPM: Int) {
        self.fanID = fanID
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.actualRPM = actualRPM
    }
}

public enum FanCurveRPMMapper {
    public static func targetRPM(
        percentage: Double,
        range: FanCurveFanRange
    ) throws -> Int {
        guard percentage.isFinite, (0...100).contains(percentage),
              range.fanID >= 0,
              range.minimumRPM >= 0,
              range.maximumRPM > range.minimumRPM,
              range.actualRPM >= 0 else {
            throw FanCurveError.fanRangeUnavailable
        }
        let fraction = percentage / 100
        let target = Int((
            Double(range.minimumRPM)
                + fraction * Double(range.maximumRPM - range.minimumRPM)
        ).rounded())
        return min(range.maximumRPM, max(range.minimumRPM, target))
    }

    public static func targets(
        percentage: Double,
        ranges: [FanCurveFanRange]
    ) throws -> [Int: Int] {
        guard !ranges.isEmpty,
              ranges.count <= 16,
              Set(ranges.map(\.fanID)).count == ranges.count else {
            throw FanCurveError.fanRangeUnavailable
        }
        return try Dictionary(uniqueKeysWithValues: ranges.map {
            ($0.fanID, try targetRPM(percentage: percentage, range: $0))
        })
    }

    public static func actualPercentage(
        ranges: [FanCurveFanRange]
    ) throws -> Double {
        guard !ranges.isEmpty else { throw FanCurveError.fanRangeUnavailable }
        let values = try ranges.map { range -> Double in
            guard range.minimumRPM >= 0, range.maximumRPM > range.minimumRPM else {
                throw FanCurveError.fanRangeUnavailable
            }
            return min(100, max(0,
                Double(range.actualRPM - range.minimumRPM)
                    / Double(range.maximumRPM - range.minimumRPM) * 100
            ))
        }
        return values.reduce(0, +) / Double(values.count)
    }
}

public struct FanCurveControlPolicy: Equatable, Sendable {
    public static let standard = Self()

    public var sampleInterval: TimeInterval = 1
    public var staleAfter: TimeInterval = 10
    public var maximumConsecutiveSensorFailures = 3
    public var medianSampleCount = 3
    public var risingFilterTimeConstant: TimeInterval = 3
    public var fallingFilterTimeConstant: TimeInterval = 5
    public var decreaseHold: TimeInterval = 5
    public var decreaseHysteresisCelsius = 2.0
    public var maximumIncreasePerSecond = 10.0
    public var maximumDecreasePerSecond = 3.0
    public var percentageWriteThreshold = 2.0
    public var rpmWriteThreshold = 100

    public init() {}
}

public struct FanCurveControlDecision: Equatable, Sendable {
    public let rawTemperature: Double
    public let filteredTemperature: Double
    public let calculatedPercentage: Double
    public let appliedPercentage: Double
    public let shouldWrite: Bool
}

public struct FanCurveControlEngine: Sendable {
    public let policy: FanCurveControlPolicy
    private var samples: [Double] = []
    private var filteredTemperature: Double?
    private var appliedPercentage: Double?
    private var lastWrittenPercentage: Double?
    private var lastEvaluation: Date?
    private var lastIncrease: Date?
    private var lastSensorUpdate: Date?
    private var consecutiveSensorFailures = 0

    public init(
        policy: FanCurveControlPolicy = .standard,
        initialAppliedPercentage: Double? = nil
    ) {
        self.policy = policy
        if let initialAppliedPercentage, initialAppliedPercentage.isFinite {
            appliedPercentage = min(100, max(0, initialAppliedPercentage))
        }
    }

    public mutating func evaluate(
        rawTemperature: Double,
        profile: FanCurveProfile,
        at now: Date
    ) throws -> FanCurveControlDecision {
        guard rawTemperature.isFinite, (5...130).contains(rawTemperature) else {
            throw FanCurveError.sensorUnavailable
        }
        try FanCurveValidator.validate(profile)
        consecutiveSensorFailures = 0
        lastSensorUpdate = now
        samples.append(rawTemperature)
        if samples.count > policy.medianSampleCount {
            samples.removeFirst(samples.count - policy.medianSampleCount)
        }
        let median = Self.median(samples)
        let elapsed = max(
            0,
            lastEvaluation.map { now.timeIntervalSince($0) } ?? policy.sampleInterval
        )
        let previousFiltered = filteredTemperature
        let timeConstant = median >= (previousFiltered ?? median)
            ? policy.risingFilterTimeConstant
            : policy.fallingFilterTimeConstant
        let alpha = previousFiltered == nil
            ? 1
            : 1 - exp(-max(0.001, elapsed) / max(0.001, timeConstant))
        let filtered = previousFiltered.map { $0 + alpha * (median - $0) } ?? median
        filteredTemperature = filtered

        let calculated = FanCurveInterpolator.percentage(
            at: filtered,
            points: profile.points
        )
        let current = appliedPercentage ?? calculated
        if lastIncrease == nil {
            lastIncrease = now
        }
        let next: Double
        if calculated >= 100 {
            next = 100
            lastIncrease = now
        } else if calculated > current {
            next = min(calculated, current + policy.maximumIncreasePerSecond * elapsed)
            lastIncrease = now
        } else if calculated < current {
            let heldLongEnough = lastIncrease.map {
                now.timeIntervalSince($0) >= policy.decreaseHold
            } ?? true
            let releaseTemperature = FanCurveInterpolator.temperature(
                forPercentage: current,
                points: profile.points
            ).map { $0 - policy.decreaseHysteresisCelsius }
            if heldLongEnough,
               releaseTemperature.map({ filtered <= $0 }) ?? false {
                next = max(calculated, current - policy.maximumDecreasePerSecond * elapsed)
            } else {
                next = current
            }
        } else {
            next = current
        }
        appliedPercentage = min(100, max(0, next))
        lastEvaluation = now
        let resolvedAppliedPercentage = appliedPercentage ?? calculated
        let shouldWrite = lastWrittenPercentage.map {
            resolvedAppliedPercentage == 100 && $0 < 100
                || abs(resolvedAppliedPercentage - $0) >= policy.percentageWriteThreshold
        } ?? true

        return FanCurveControlDecision(
            rawTemperature: rawTemperature,
            filteredTemperature: filtered,
            calculatedPercentage: calculated,
            appliedPercentage: resolvedAppliedPercentage,
            shouldWrite: shouldWrite
        )
    }

    public mutating func markWritten(percentage: Double) {
        guard percentage.isFinite else { return }
        lastWrittenPercentage = min(100, max(0, percentage))
    }

    public mutating func recordSensorFailure(at now: Date) -> FanCurveError? {
        consecutiveSensorFailures += 1
        if let lastSensorUpdate,
           now.timeIntervalSince(lastSensorUpdate) > policy.staleAfter {
            return .sensorStale
        }
        return consecutiveSensorFailures >= policy.maximumConsecutiveSensorFailures
            ? .sensorUnavailable
            : nil
    }

    public func sensorIsStale(at now: Date) -> Bool {
        guard let lastSensorUpdate else { return false }
        return now.timeIntervalSince(lastSensorUpdate) > policy.staleAfter
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            let upper = sorted.count / 2
            return (sorted[upper - 1] + sorted[upper]) / 2
        }
        return sorted[sorted.count / 2]
    }
}

public enum FanCurveRuntimeStatus: String, Codable, Equatable, Sendable {
    case inactive
    case preparing
    case active
    case applying
    case sensorUnavailable
    case sensorStale
    case helperUnavailable
    case leaseExpired
    case thermalProtection
    case verificationFailed
    case restoringAutomatic
}

public struct FanCurveRuntimeState: Codable, Equatable, Sendable {
    public var status: FanCurveRuntimeStatus
    public var rawTemperature: Double?
    public var filteredTemperature: Double?
    public var calculatedPercentage: Double?
    public var appliedPercentage: Double?
    public var targetRPMByFan: [Int: Int]
    public var actualRPMByFan: [Int: Int]
    public var activeProfileID: UUID?
    public var lastSensorUpdate: Date?
    public var lastFanWrite: Date?
    public var lastVerification: Date?
    public var failureReason: FanCurveError?

    public init(
        status: FanCurveRuntimeStatus,
        rawTemperature: Double? = nil,
        filteredTemperature: Double? = nil,
        calculatedPercentage: Double? = nil,
        appliedPercentage: Double? = nil,
        targetRPMByFan: [Int: Int] = [:],
        actualRPMByFan: [Int: Int] = [:],
        activeProfileID: UUID? = nil,
        lastSensorUpdate: Date? = nil,
        lastFanWrite: Date? = nil,
        lastVerification: Date? = nil,
        failureReason: FanCurveError? = nil
    ) {
        self.status = status
        self.rawTemperature = rawTemperature
        self.filteredTemperature = filteredTemperature
        self.calculatedPercentage = calculatedPercentage
        self.appliedPercentage = appliedPercentage
        self.targetRPMByFan = targetRPMByFan
        self.actualRPMByFan = actualRPMByFan
        self.activeProfileID = activeProfileID
        self.lastSensorUpdate = lastSensorUpdate
        self.lastFanWrite = lastFanWrite
        self.lastVerification = lastVerification
        self.failureReason = failureReason
    }

    public static let inactive = Self(status: .inactive)
}
