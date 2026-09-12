import Foundation

enum BenchmarkProfile: String, CaseIterable, Codable, Sendable {
    case standard
    case quick
    case full

    /// Only the current public workload is selectable. Quick and Full remain
    /// decodable so existing history and the frozen v3 calibration stay intact.
    static let allCases: [BenchmarkProfile] = [.standard]
    static let legacyCases: [BenchmarkProfile] = [.quick, .full]
    static let persistedCases: [BenchmarkProfile] = [.standard, .quick, .full]
}

enum BenchmarkStage: String, CaseIterable, Codable, Sendable {
    case preflight
    case cpuSingle
    case cpuMulti
    case gpu
    case memory
    case diskWrite
    case diskRead
    case finalizing
}

enum BenchmarkComponent: String, CaseIterable, Codable, Sendable {
    case cpuSingle
    case cpuMulti
    case gpu
    case memory
    case diskRead
    case diskWrite

    var metricUnit: BenchmarkMetricUnit {
        switch self {
        case .cpuSingle, .cpuMulti:
            .millionOperationsPerSecond
        case .gpu:
            .billionOperationsPerSecond
        case .memory, .diskRead, .diskWrite:
            .decimalGigabytesPerSecond
        }
    }

    func metricUnit(for profile: BenchmarkProfile) -> BenchmarkMetricUnit {
        if self == .gpu, profile == .standard {
            return .millionTrianglesPerSecond
        }
        return metricUnit
    }
}

enum BenchmarkMetricUnit: String, Codable, Sendable {
    case millionOperationsPerSecond
    case billionOperationsPerSecond
    case millionTrianglesPerSecond
    case decimalGigabytesPerSecond
}

enum BenchmarkArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64
    case unsupported

    static var current: Self {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unsupported
        #endif
    }
}

struct BenchmarkCapabilitySet: Hashable, Sendable, Codable,
    ExpressibleByArrayLiteral
{
    private let storage: Set<BenchmarkComponent>

    static let all = Self(BenchmarkComponent.allCases)
    static let none = Self([])

    init(_ components: some Sequence<BenchmarkComponent>) {
        storage = Set(components)
    }

    init(arrayLiteral elements: BenchmarkComponent...) {
        self.init(elements)
    }

    var components: [BenchmarkComponent] {
        BenchmarkComponent.allCases.filter(storage.contains)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    func contains(_ component: BenchmarkComponent) -> Bool {
        storage.contains(component)
    }

    func isSuperset(of required: BenchmarkCapabilitySet) -> Bool {
        storage.isSuperset(of: required.storage)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode([BenchmarkComponent].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(components)
    }
}

enum BenchmarkPowerSource: String, Codable, Sendable {
    case acPower
    case battery
    case unknown
}

enum BenchmarkThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

enum BenchmarkDiskReliability: String, Codable, Sendable {
    case verified
    case failing
    case unavailable
}

struct BenchmarkPreflight: Equatable, Codable, Sendable {
    let capturedAt: Date
    let powerSource: BenchmarkPowerSource
    let batteryPercent: Double?
    let lowPowerModeEnabled: Bool
    let thermalState: BenchmarkThermalState
    let diskReliability: BenchmarkDiskReliability
    let availableDiskBytes: Int64
    let requiredDiskBytes: Int64
    let warnings: [BenchmarkSafetyIssue]

    var hasRequiredDiskCapacity: Bool {
        availableDiskBytes >= requiredDiskBytes && requiredDiskBytes >= 0
    }
}

struct BenchmarkPostflight: Equatable, Codable, Sendable {
    let capturedAt: Date
    let powerSource: BenchmarkPowerSource
    let lowPowerModeEnabled: Bool
    let thermalState: BenchmarkThermalState
    /// Final disk state is optional only for records written before Standard v6.
    /// New runs always populate these fields so a completed workload can retain
    /// its measurements even when the final environment is no longer scoreable.
    let diskReliability: BenchmarkDiskReliability?
    let availableDiskBytes: Int64?
    let requiredDiskBytes: Int64?
    let warnings: [BenchmarkSafetyIssue]?

    init(
        capturedAt: Date,
        powerSource: BenchmarkPowerSource,
        lowPowerModeEnabled: Bool,
        thermalState: BenchmarkThermalState,
        diskReliability: BenchmarkDiskReliability? = nil,
        availableDiskBytes: Int64? = nil,
        requiredDiskBytes: Int64? = nil,
        warnings: [BenchmarkSafetyIssue]? = nil
    ) {
        self.capturedAt = capturedAt
        self.powerSource = powerSource
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
        self.diskReliability = diskReliability
        self.availableDiskBytes = availableDiskBytes
        self.requiredDiskBytes = requiredDiskBytes
        self.warnings = warnings
    }

    var hasCompleteDiskSnapshot: Bool {
        diskReliability != nil
            && availableDiskBytes != nil
            && requiredDiskBytes != nil
            && warnings != nil
    }

    var hasRequiredDiskCapacity: Bool {
        guard let availableDiskBytes, let requiredDiskBytes else { return false }
        return availableDiskBytes >= requiredDiskBytes && requiredDiskBytes > 0
    }
}

struct BenchmarkEnvironmentMetadata: Equatable, Codable, Sendable {
    let architecture: BenchmarkArchitecture
    let chipName: String
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64
    /// Total capacity of the APFS volume that owns the benchmark temporary
    /// directory. Legacy history predates capacity-aware scoring, so this is
    /// optional when decoding old records and scored only by legacy Standard v5.
    /// Standard v6 keeps it as configuration metadata, not performance points.
    let systemDiskCapacityBytes: UInt64?
    let powerSource: BenchmarkPowerSource
    let thermalState: BenchmarkThermalState
    let operatingSystemVersion: String
    let appVersion: String
    let appBuild: String

    init(
        architecture: BenchmarkArchitecture,
        chipName: String,
        activeProcessorCount: Int,
        physicalMemoryBytes: UInt64,
        systemDiskCapacityBytes: UInt64? = nil,
        powerSource: BenchmarkPowerSource,
        thermalState: BenchmarkThermalState,
        operatingSystemVersion: String,
        appVersion: String,
        appBuild: String
    ) {
        self.architecture = architecture
        self.chipName = chipName
        self.activeProcessorCount = activeProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.systemDiskCapacityBytes = systemDiskCapacityBytes
        self.powerSource = powerSource
        self.thermalState = thermalState
        self.operatingSystemVersion = operatingSystemVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
    }
}

struct BenchmarkComponentSample: Equatable, Codable, Sendable {
    let value: Double
    let elapsedSeconds: Double
    let checksum: UInt64
}

struct BenchmarkComponentMeasurement: Equatable, Codable, Sendable {
    let component: BenchmarkComponent
    let unit: BenchmarkMetricUnit
    let samples: [BenchmarkComponentSample]

    var medianValue: Double {
        Self.median(samples.map(\.value)) ?? .nan
    }

    var coefficientOfVariation: Double {
        let values = samples.map(\.value)
        return Self.coefficientOfVariation(values) ?? .nan
    }

    /// A calibration-only stability signal that tolerates one scheduler or I/O outlier.
    /// Three-sample Quick runs keep a 20% hard deviation gate; five-sample Full runs
    /// may discard one arbitrary outlier because four independent inliers remain.
    /// The published score still uses the median of every sample, never the best sample.
    var calibrationStabilityCoefficientOfVariation: Double {
        let values = samples.map(\.value)
        guard let rawCoefficient = Self.coefficientOfVariation(values),
              values.count >= 3,
              let median = Self.median(values),
              median.isFinite,
              median > 0
        else {
            return coefficientOfVariation
        }

        let maximumRelativeDeviation = values.reduce(0) { current, value in
            max(current, abs(value - median) / median)
        }
        guard values.count >= 5 || maximumRelativeDeviation <= 0.20 else {
            return rawCoefficient
        }

        var bestCoefficient = rawCoefficient
        for excludedIndex in values.indices {
            var inliers = values
            inliers.remove(at: excludedIndex)
            if let coefficient = Self.coefficientOfVariation(inliers) {
                bestCoefficient = min(bestCoefficient, coefficient)
            }
        }
        return bestCoefficient
    }

    private static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard !values.isEmpty,
              values.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean.isFinite, mean > 0 else { return nil }
        let squaredError = values.reduce(0) { partial, value in
            let difference = value - mean
            return partial + (difference * difference)
        }
        let sampleVariance = squaredError / Double(values.count - 1)
        let value = sqrt(sampleVariance) / mean
        return value.isFinite ? value : nil
    }

    var isValid: Bool {
        let unitMatchesComponent = unit == component.metricUnit
            || (component == .gpu && unit == .millionTrianglesPerSecond)
        guard unitMatchesComponent, !samples.isEmpty else { return false }
        guard samples.allSatisfy({ sample in
            sample.value.isFinite
                && sample.value > 0
                && sample.elapsedSeconds.isFinite
                && sample.elapsedSeconds > 0
        }) else { return false }
        guard medianValue.isFinite, medianValue > 0 else { return false }
        return coefficientOfVariation.isFinite && coefficientOfVariation >= 0
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

enum BenchmarkSafetyIssue: String, Codable, Sendable {
    case thermalNotNominal
    case thermalCritical
    case batteryTooLow
    case lowPowerModeEnabled
    case acPowerRequired
    case diskReliabilityFailing
    case insufficientDiskCapacity
}

enum BenchmarkFailureReason: String, Codable, Sendable {
    case unavailable
    case invalidMetric
    case checksumMismatch
    case resourceLimit
    case systemFailure
}

enum MacBenchmarkFailure: Equatable, Codable, Sendable {
    case busy(activeTask: String)
    case safetyCheck(BenchmarkSafetyIssue)
    case unsupported(BenchmarkComponent)
    case timedOut(BenchmarkStage)
    case kernelFailure(component: BenchmarkComponent, reason: BenchmarkFailureReason)
    case cancelled
    case invalidResult
}

struct MacBenchmarkRawResult: Equatable, Codable, Sendable {
    let profile: BenchmarkProfile
    let workloadVersion: String
    let startedAt: Date
    let completedAt: Date?
    let environment: BenchmarkEnvironmentMetadata
    let preflight: BenchmarkPreflight
    let postflight: BenchmarkPostflight?
    let capabilitySet: BenchmarkCapabilitySet
    let measurements: [BenchmarkComponentMeasurement]
    let failure: MacBenchmarkFailure?

    var measurementsByComponent: [BenchmarkComponent: BenchmarkComponentMeasurement] {
        guard Set(measurements.map(\.component)).count == measurements.count else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: measurements.map { ($0.component, $0) })
    }

    var isComplete: Bool {
        guard failure == nil,
              !workloadVersion.isEmpty,
              let completedAt,
              postflight != nil,
              completedAt >= startedAt,
              capabilitySet == .all
        else { return false }

        let byComponent = measurementsByComponent
        return byComponent.count == BenchmarkComponent.allCases.count
            && BenchmarkComponent.allCases.allSatisfy { component in
                guard let measurement = byComponent[component] else { return false }
                return measurement.isValid
                    && measurement.unit == component.metricUnit(for: profile)
            }
    }
}

struct BenchmarkComparisonKey: Equatable, Hashable, Codable, Sendable {
    var workloadVersion: String
    var baselineVersion: String
    var profile: BenchmarkProfile
    var architecture: BenchmarkArchitecture
    var capabilitySet: BenchmarkCapabilitySet
}

struct MacBenchmarkBaseline: Equatable, Codable, Sendable {
    let comparisonKey: BenchmarkComparisonKey
    let referenceMetrics: [BenchmarkComponent: Double]
    let reportSHA256: String
    let referenceHardware: String
    let frozenAt: Date

    var isValid: Bool {
        comparisonKey.capabilitySet == .all
            && referenceMetrics.count == BenchmarkComponent.allCases.count
            && BenchmarkComponent.allCases.allSatisfy { component in
                guard let value = referenceMetrics[component] else { return false }
                return value.isFinite && value > 0
            }
            && reportSHA256.count == 64
            && reportSHA256.allSatisfy { $0.isHexDigit }
            && !referenceHardware.isEmpty
    }
}

struct MacBenchmarkResult: Equatable, Codable, Sendable {
    let rawResult: MacBenchmarkRawResult?
    let comparisonKey: BenchmarkComparisonKey?
    let matchedBaselineKey: BenchmarkComparisonKey?
    let componentScores: [BenchmarkComponent: Double]
    let overallScore: Double?
    let isComplete: Bool

    init(
        rawResult: MacBenchmarkRawResult,
        comparisonKey: BenchmarkComparisonKey?,
        matchedBaselineKey: BenchmarkComparisonKey?,
        componentScores: [BenchmarkComponent: Double],
        proposedOverallScore: Double?
    ) {
        let validatedComponentScores = componentScores.filter {
            $0.value.isFinite && $0.value > 0
        }
        self.rawResult = rawResult
        self.comparisonKey = comparisonKey
        self.matchedBaselineKey = matchedBaselineKey
        self.componentScores = validatedComponentScores
        isComplete = rawResult.isComplete

        let hasEveryComponentScore = BenchmarkComponent.allCases.allSatisfy {
            validatedComponentScores[$0] != nil
        }
        let keyMatchesRaw = comparisonKey.map { key in
            key.workloadVersion == rawResult.workloadVersion
                && key.profile == rawResult.profile
                && key.architecture == rawResult.environment.architecture
                && key.capabilitySet == rawResult.capabilitySet
        } ?? false
        if rawResult.isComplete,
           keyMatchesRaw,
           let comparisonKey,
           comparisonKey == matchedBaselineKey,
           comparisonKey.capabilitySet == .all,
           hasEveryComponentScore,
           let proposedOverallScore,
           proposedOverallScore.isFinite,
           proposedOverallScore > 0
        {
            overallScore = proposedOverallScore
        } else {
            overallScore = nil
        }
    }

    static func incomplete(
        completed: [BenchmarkComponent: Double]
    ) -> MacBenchmarkResult {
        MacBenchmarkResult(
            rawResult: nil,
            comparisonKey: nil,
            matchedBaselineKey: nil,
            componentScores: completed.filter { $0.value.isFinite && $0.value > 0 },
            overallScore: nil,
            isComplete: false
        )
    }

    private init(
        rawResult: MacBenchmarkRawResult?,
        comparisonKey: BenchmarkComparisonKey?,
        matchedBaselineKey: BenchmarkComparisonKey?,
        componentScores: [BenchmarkComponent: Double],
        overallScore: Double?,
        isComplete: Bool
    ) {
        self.rawResult = rawResult
        self.comparisonKey = comparisonKey
        self.matchedBaselineKey = matchedBaselineKey
        self.componentScores = componentScores
        self.overallScore = overallScore
        self.isComplete = isComplete
    }

    private enum CodingKeys: String, CodingKey {
        case rawResult
        case comparisonKey
        case matchedBaselineKey
        case componentScores
        case overallScore
        case isComplete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawResult = try container.decodeIfPresent(
            MacBenchmarkRawResult.self,
            forKey: .rawResult
        )
        let comparisonKey = try container.decodeIfPresent(
            BenchmarkComparisonKey.self,
            forKey: .comparisonKey
        )
        let matchedBaselineKey = try container.decodeIfPresent(
            BenchmarkComparisonKey.self,
            forKey: .matchedBaselineKey
        )
        let componentScores = try container.decode(
            [BenchmarkComponent: Double].self,
            forKey: .componentScores
        )
        let proposedOverallScore = try container.decodeIfPresent(
            Double.self,
            forKey: .overallScore
        )

        if let rawResult {
            self.init(
                rawResult: rawResult,
                comparisonKey: comparisonKey,
                matchedBaselineKey: matchedBaselineKey,
                componentScores: componentScores,
                proposedOverallScore: proposedOverallScore
            )
        } else {
            self = .incomplete(completed: componentScores)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rawResult, forKey: .rawResult)
        try container.encodeIfPresent(comparisonKey, forKey: .comparisonKey)
        try container.encodeIfPresent(matchedBaselineKey, forKey: .matchedBaselineKey)
        try container.encode(componentScores, forKey: .componentScores)
        try container.encodeIfPresent(overallScore, forKey: .overallScore)
        try container.encode(isComplete, forKey: .isComplete)
    }
}

enum MacBenchmarkState: Equatable, Codable, Sendable {
    case idle
    case preflighting(profile: BenchmarkProfile)
    case running(stage: BenchmarkStage, progress: Double, elapsedSeconds: Double)
    case cancelling
    case completed
    case cancelled
    case failed(MacBenchmarkFailure)
}
