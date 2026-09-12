import Foundation

/// Versioned, standalone scoring vocabulary for the next benchmark protocol.
/// It intentionally does not participate in the frozen v2-v6 result paths.
enum BenchmarkV7PlanKind: String, CaseIterable, Codable, Sendable, Equatable {
    case quick
    case standard
    case sustained
    case custom
}

enum BenchmarkV7Category: String, CaseIterable, Codable, Sendable, Hashable {
    case cpu
    case gpu
    case memory
    case storage
    case display
    case sustained

    static let corePerformance: [Self] = [.cpu, .gpu, .memory, .storage]
}

enum BenchmarkV7MetricDirection: String, Codable, Sendable, Equatable {
    case higherIsBetter
    case lowerIsBetter
}

struct BenchmarkV7Plan: Equatable, Codable, Sendable {
    let kind: BenchmarkV7PlanKind
    let planVersion: String
    let workloadVersion: String
    let expectedMinimumDurationSeconds: Int
    let expectedMaximumDurationSeconds: Int
    let categories: [BenchmarkV7Category]

    var isValid: Bool {
        nonempty(planVersion)
            && nonempty(workloadVersion)
            && expectedMinimumDurationSeconds > 0
            && expectedMaximumDurationSeconds >= expectedMinimumDurationSeconds
            && !categories.isEmpty
            && Set(categories).count == categories.count
    }

    static let quick = Self(
        kind: .quick,
        planVersion: "benchmark-quick-plan-v7",
        workloadVersion: "benchmark-quick-v7",
        expectedMinimumDurationSeconds: 60,
        expectedMaximumDurationSeconds: 90,
        categories: [.cpu, .gpu, .memory, .storage, .display]
    )

    static let standard = Self(
        kind: .standard,
        planVersion: "benchmark-standard-plan-v9",
        workloadVersion: "benchmark-standard-v9",
        expectedMinimumDurationSeconds: 4 * 60,
        expectedMaximumDurationSeconds: 6 * 60,
        categories: [.cpu, .gpu, .memory, .storage, .display]
    )

    static let sustained = Self(
        kind: .sustained,
        planVersion: "benchmark-sustained-plan-v7",
        workloadVersion: "benchmark-sustained-v7",
        expectedMinimumDurationSeconds: 10 * 60,
        expectedMaximumDurationSeconds: 15 * 60,
        categories: [.cpu, .gpu, .sustained]
    )

    static func custom(
        categories: [BenchmarkV7Category],
        expectedDurationSeconds: Int = 90
    ) -> Self {
        let duration = max(30, min(15 * 60, expectedDurationSeconds))
        return Self(
            kind: .custom,
            planVersion: "benchmark-custom-plan-v7",
            workloadVersion: "benchmark-custom-v7",
            expectedMinimumDurationSeconds: duration,
            expectedMaximumDurationSeconds: duration,
            categories: categories
        )
    }
}

struct BenchmarkV7VersionManifest: Equatable, Codable, Sendable {
    static let resultSchemaVersion = "benchmark-result-v7"

    let schemaVersion: String
    let planVersion: String
    let workloadVersion: String
    let cpuWorkloadVersion: String
    let gpuWorkloadVersion: String
    let memoryWorkloadVersion: String
    let storageWorkloadVersion: String
    let displayWorkloadVersion: String
    let statisticsVersion: String
    let scoringVersion: String
    let referenceSetVersion: String

    init(
        schemaVersion: String = Self.resultSchemaVersion,
        planVersion: String,
        workloadVersion: String,
        cpuWorkloadVersion: String = "not-run-v7",
        gpuWorkloadVersion: String = "not-run-v7",
        memoryWorkloadVersion: String = "not-run-v7",
        storageWorkloadVersion: String = "not-run-v7",
        displayWorkloadVersion: String = "not-run-v7",
        statisticsVersion: String,
        scoringVersion: String,
        referenceSetVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.planVersion = planVersion
        self.workloadVersion = workloadVersion
        self.cpuWorkloadVersion = cpuWorkloadVersion
        self.gpuWorkloadVersion = gpuWorkloadVersion
        self.memoryWorkloadVersion = memoryWorkloadVersion
        self.storageWorkloadVersion = storageWorkloadVersion
        self.displayWorkloadVersion = displayWorkloadVersion
        self.statisticsVersion = statisticsVersion
        self.scoringVersion = scoringVersion
        self.referenceSetVersion = referenceSetVersion
    }

    var isValid: Bool {
        schemaVersion == Self.resultSchemaVersion
            && nonempty(planVersion)
            && nonempty(workloadVersion)
            && nonempty(cpuWorkloadVersion)
            && nonempty(gpuWorkloadVersion)
            && nonempty(memoryWorkloadVersion)
            && nonempty(storageWorkloadVersion)
            && nonempty(displayWorkloadVersion)
            && nonempty(statisticsVersion)
            && nonempty(scoringVersion)
            && nonempty(referenceSetVersion)
    }
}

struct BenchmarkV7MetricManifest: Equatable, Codable, Sendable {
    let id: String
    let category: BenchmarkV7Category
    let unit: String
    let direction: BenchmarkV7MetricDirection
    let weight: Double
    let workloadVersion: String

    var isValid: Bool {
        nonempty(id)
            && nonempty(unit)
            && nonempty(workloadVersion)
            && weight.isFinite
            && weight > 0
    }
}

struct BenchmarkV7CategoryWeight: Equatable, Codable, Sendable {
    let category: BenchmarkV7Category
    let weight: Double

    var isValid: Bool {
        weight.isFinite && weight > 0
    }
}

enum BenchmarkV7ReferenceValidationStatus: String, Codable, Sendable, Equatable {
    case controlledLocal
    case pendingVerification
    case invalid
}

struct BenchmarkV7ReferenceMetric: Equatable, Codable, Sendable {
    let id: String
    let value: Double
    let unit: String
    let direction: BenchmarkV7MetricDirection
    let sourceDescription: String
    let sampleCount: Int
    let validationStatus: BenchmarkV7ReferenceValidationStatus

    var isValid: Bool {
        nonempty(id)
            && value.isFinite
            && value > 0
            && nonempty(unit)
            && nonempty(sourceDescription)
            && sampleCount > 0
            && validationStatus == .controlledLocal
    }
}

struct BenchmarkV7ReferenceSet: Equatable, Codable, Sendable {
    let version: String
    let supportedWorkloadVersions: [String]
    let createdAt: Date
    let sourceDescription: String
    let metrics: [String: BenchmarkV7ReferenceMetric]

    var isValid: Bool {
        nonempty(version)
            && !supportedWorkloadVersions.isEmpty
            && supportedWorkloadVersions.allSatisfy(nonempty)
            && createdAt.timeIntervalSinceReferenceDate.isFinite
            && nonempty(sourceDescription)
            && !metrics.isEmpty
            && metrics.allSatisfy { id, metric in
                id == metric.id && metric.isValid
            }
    }
}

struct BenchmarkV7ScoringManifest: Equatable, Codable, Sendable {
    let versions: BenchmarkV7VersionManifest
    let displayBaseline: Double
    let coreCategoryWeights: [BenchmarkV7CategoryWeight]
    let metrics: [BenchmarkV7MetricManifest]

    var isValid: Bool {
        guard versions.isValid,
              displayBaseline.isFinite,
              displayBaseline > 0,
              !metrics.isEmpty,
              Set(metrics.map(\.id)).count == metrics.count,
              metrics.allSatisfy(\.isValid),
              metrics.allSatisfy({ $0.workloadVersion == versions.workloadVersion }),
              coreCategoryWeights.allSatisfy(\.isValid),
              Set(coreCategoryWeights.map(\.category))
                == Set(BenchmarkV7Category.corePerformance),
              coreCategoryWeights.count == BenchmarkV7Category.corePerformance.count
        else {
            return false
        }
        return BenchmarkV7Category.corePerformance.allSatisfy { category in
            metrics.contains { $0.category == category }
        }
    }
}

enum BenchmarkV7ScoringError: Error, Equatable, Sendable {
    case invalidPlan
    case invalidManifest
    case invalidReferenceSet
    case referenceSetVersionMismatch
    case referenceWorkloadVersionMismatch
    case referenceMetricMismatch(String)
    case missingCategory(BenchmarkV7Category)
    case missingMetric(String)
    case invalidMetricValue(String)
    case invalidReferenceValue(String)
    case invalidWeight
}

struct BenchmarkV7CategoryScore: Equatable, Codable, Sendable {
    let ratio: Double
    let score: Double
}

struct BenchmarkV7CoreScore: Equatable, Codable, Sendable {
    let categoryScores: [BenchmarkV7Category: BenchmarkV7CategoryScore]
    let overallScore: Double
}

struct BenchmarkV7ExperienceScore: Equatable, Codable, Sendable {
    let metricRatios: [String: Double]
    let overallScore: Double
}

struct BenchmarkV7ExperienceScoringManifest: Equatable, Codable, Sendable {
    let versions: BenchmarkV7VersionManifest
    let displayBaseline: Double
    let metrics: [BenchmarkV7MetricManifest]

    var isValid: Bool {
        versions.isValid
            && displayBaseline.isFinite
            && displayBaseline > 0
            && !metrics.isEmpty
            && Set(metrics.map(\.id)).count == metrics.count
            && metrics.allSatisfy(\.isValid)
            && metrics.allSatisfy { $0.workloadVersion == versions.workloadVersion }
    }
}

enum BenchmarkV7Scoring {
    static func scoreCore(
        plan: BenchmarkV7Plan,
        manifest: BenchmarkV7ScoringManifest,
        referenceSet: BenchmarkV7ReferenceSet,
        measurements: [String: Double]
    ) throws -> BenchmarkV7CoreScore {
        guard plan.isValid else { throw BenchmarkV7ScoringError.invalidPlan }
        guard manifest.isValid else { throw BenchmarkV7ScoringError.invalidManifest }
        guard referenceSet.isValid else {
            throw BenchmarkV7ScoringError.invalidReferenceSet
        }
        guard plan.planVersion == manifest.versions.planVersion,
              plan.workloadVersion == manifest.versions.workloadVersion
        else {
            throw BenchmarkV7ScoringError.invalidPlan
        }
        guard referenceSet.version == manifest.versions.referenceSetVersion else {
            throw BenchmarkV7ScoringError.referenceSetVersionMismatch
        }
        guard referenceSet.supportedWorkloadVersions.contains(
            manifest.versions.workloadVersion
        ) else {
            throw BenchmarkV7ScoringError.referenceWorkloadVersionMismatch
        }

        var categoryScores: [BenchmarkV7Category: BenchmarkV7CategoryScore] = [:]
        var categoryRatios: [(value: Double, weight: Double)] = []
        for category in BenchmarkV7Category.corePerformance {
            guard plan.categories.contains(category) else {
                throw BenchmarkV7ScoringError.missingCategory(category)
            }
            let metricDefinitions = manifest.metrics.filter { $0.category == category }
            guard metricDefinitions.contains(where: { measurements[$0.id] != nil }) else {
                throw BenchmarkV7ScoringError.missingCategory(category)
            }

            let metricRatios = try metricDefinitions.map { metric -> (Double, Double) in
                guard let measured = measurements[metric.id] else {
                    throw BenchmarkV7ScoringError.missingMetric(metric.id)
                }
                guard measured.isFinite, measured > 0 else {
                    throw BenchmarkV7ScoringError.invalidMetricValue(metric.id)
                }
                guard let referenceMetric = referenceSet.metrics[metric.id] else {
                    throw BenchmarkV7ScoringError.missingMetric(metric.id)
                }
                guard referenceMetric.unit == metric.unit,
                      referenceMetric.direction == metric.direction else {
                    throw BenchmarkV7ScoringError.referenceMetricMismatch(metric.id)
                }
                let reference = referenceMetric.value
                guard reference.isFinite, reference > 0 else {
                    throw BenchmarkV7ScoringError.invalidReferenceValue(metric.id)
                }
                let ratio: Double
                switch metric.direction {
                case .higherIsBetter:
                    ratio = measured / reference
                case .lowerIsBetter:
                    ratio = reference / measured
                }
                guard ratio.isFinite, ratio > 0 else {
                    throw BenchmarkV7ScoringError.invalidMetricValue(metric.id)
                }
                return (ratio, metric.weight)
            }
            let categoryRatio = try weightedGeometricMean(metricRatios)
            let categoryScore = manifest.displayBaseline * categoryRatio
            guard categoryScore.isFinite, categoryScore > 0 else {
                throw BenchmarkV7ScoringError.invalidMetricValue(category.rawValue)
            }
            categoryScores[category] = BenchmarkV7CategoryScore(
                ratio: categoryRatio,
                score: categoryScore
            )
            guard let categoryWeight = manifest.coreCategoryWeights.first(
                where: { $0.category == category }
            )?.weight else {
                throw BenchmarkV7ScoringError.invalidManifest
            }
            categoryRatios.append((categoryRatio, categoryWeight))
        }

        let overallRatio = try weightedGeometricMean(categoryRatios)
        let overallScore = manifest.displayBaseline * overallRatio
        guard overallScore.isFinite, overallScore > 0 else {
            throw BenchmarkV7ScoringError.invalidMetricValue("core")
        }
        return BenchmarkV7CoreScore(
            categoryScores: categoryScores,
            overallScore: overallScore
        )
    }

    static func weightedGeometricMean(
        _ values: [(value: Double, weight: Double)]
    ) throws -> Double {
        guard !values.isEmpty else { throw BenchmarkV7ScoringError.invalidWeight }
        var weightedLog = 0.0
        var totalWeight = 0.0
        for value in values {
            guard value.value.isFinite,
                  value.value > 0,
                  value.weight.isFinite,
                  value.weight > 0
            else {
                throw BenchmarkV7ScoringError.invalidWeight
            }
            weightedLog += value.weight * log(value.value)
            totalWeight += value.weight
        }
        guard totalWeight.isFinite, totalWeight > 0 else {
            throw BenchmarkV7ScoringError.invalidWeight
        }
        let result = exp(weightedLog / totalWeight)
        guard result.isFinite, result > 0 else {
            throw BenchmarkV7ScoringError.invalidWeight
        }
        return result
    }

    static func scoreExperience(
        plan: BenchmarkV7Plan,
        manifest: BenchmarkV7ExperienceScoringManifest,
        referenceSet: BenchmarkV7ReferenceSet,
        measurements: [String: Double]
    ) throws -> BenchmarkV7ExperienceScore {
        guard plan.isValid else { throw BenchmarkV7ScoringError.invalidPlan }
        guard manifest.isValid else { throw BenchmarkV7ScoringError.invalidManifest }
        guard referenceSet.isValid else {
            throw BenchmarkV7ScoringError.invalidReferenceSet
        }
        guard plan.planVersion == manifest.versions.planVersion,
              plan.workloadVersion == manifest.versions.workloadVersion,
              referenceSet.version == manifest.versions.referenceSetVersion,
              referenceSet.supportedWorkloadVersions.contains(plan.workloadVersion)
        else {
            throw BenchmarkV7ScoringError.referenceSetVersionMismatch
        }

        var ratios: [String: Double] = [:]
        var weightedRatios: [(value: Double, weight: Double)] = []
        for metric in manifest.metrics {
            guard let measured = measurements[metric.id] else {
                throw BenchmarkV7ScoringError.missingMetric(metric.id)
            }
            guard measured.isFinite, measured > 0 else {
                throw BenchmarkV7ScoringError.invalidMetricValue(metric.id)
            }
            guard let reference = referenceSet.metrics[metric.id] else {
                throw BenchmarkV7ScoringError.missingMetric(metric.id)
            }
            guard reference.isValid,
                  reference.unit == metric.unit,
                  reference.direction == metric.direction else {
                throw BenchmarkV7ScoringError.referenceMetricMismatch(metric.id)
            }
            let ratio = metric.direction == .higherIsBetter
                ? measured / reference.value
                : reference.value / measured
            guard ratio.isFinite, ratio > 0 else {
                throw BenchmarkV7ScoringError.invalidMetricValue(metric.id)
            }
            ratios[metric.id] = ratio
            weightedRatios.append((ratio, metric.weight))
        }
        let overallRatio = try weightedGeometricMean(weightedRatios)
        let overallScore = manifest.displayBaseline * overallRatio
        guard overallScore.isFinite, overallScore > 0 else {
            throw BenchmarkV7ScoringError.invalidMetricValue("experience")
        }
        return BenchmarkV7ExperienceScore(
            metricRatios: ratios,
            overallScore: overallScore
        )
    }
}

enum BenchmarkV7HistoryCompatibility: Equatable, Sendable {
    case directlyComparable
    case legacy
    case incompatible
}

enum BenchmarkV7Compatibility {
    /// A record without a v7 manifest is legacy by definition. A v7 record only
    /// compares directly when every semantic version is identical.
    static func classify(
        stored: BenchmarkV7VersionManifest?,
        current: BenchmarkV7VersionManifest
    ) -> BenchmarkV7HistoryCompatibility {
        guard current.isValid else { return .incompatible }
        guard let stored else { return .legacy }
        guard stored.isValid else { return .legacy }
        return stored == current ? .directlyComparable : .incompatible
    }
}

private func nonempty(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
