import Foundation

enum NetworkExperienceGrade: String, Codable, Sendable {
    case stable
    case average
    case congested
    case dataInsufficient
}

struct NetworkExperienceInput: Equatable, Sendable {
    let downloadMbps: Double?
    let uploadMbps: Double?
    let idleLatencyMS: Double?
    let loadedLatencyP95MS: Double?
    let jitterMS: Double?
    let responsivenessRPM: Double?
}

struct NetworkExperienceScore: Equatable, Codable, Sendable {
    let value: Int?
    let grade: NetworkExperienceGrade
    let completeness: Double
    let missingMetrics: Set<String>
    let modelVersion: String
}

enum NetworkExperienceScoring {
    static let modelVersion = "network-experience-v1"

    private struct Metric {
        let name: String
        let value: Double?
        let weight: Double
        let isCore: Bool
        let normalizedValue: (Double) -> Double
    }

    static func evaluate(_ input: NetworkExperienceInput) -> NetworkExperienceScore {
        let metrics = [
            Metric(
                name: "downloadMbps",
                value: input.downloadMbps,
                weight: 25,
                isCore: true,
                normalizedValue: { higherLog($0, bad: 5, good: 250) }
            ),
            Metric(
                name: "uploadMbps",
                value: input.uploadMbps,
                weight: 15,
                isCore: true,
                normalizedValue: { higherLog($0, bad: 1, good: 50) }
            ),
            Metric(
                name: "idleLatencyMS",
                value: input.idleLatencyMS,
                weight: 20,
                isCore: true,
                normalizedValue: { lowerLinear($0, good: 20, bad: 150) }
            ),
            Metric(
                name: "loadedLatencyP95MS",
                value: input.loadedLatencyP95MS,
                weight: 20,
                isCore: false,
                normalizedValue: { lowerLinear($0, good: 50, bad: 500) }
            ),
            Metric(
                name: "jitterMS",
                value: input.jitterMS,
                weight: 10,
                isCore: false,
                normalizedValue: { lowerLinear($0, good: 5, bad: 80) }
            ),
            Metric(
                name: "responsivenessRPM",
                value: input.responsivenessRPM,
                weight: 10,
                isCore: false,
                normalizedValue: { higherLog($0, bad: 100, good: 1_000) }
            )
        ]

        var availableCount = 0
        var availableWeight = 0.0
        var weightedScore = 0.0
        var isMissingCoreMetric = false
        var missingMetrics = Set<String>()

        for metric in metrics {
            guard let value = metric.value, value.isFinite, value >= 0 else {
                missingMetrics.insert(metric.name)
                isMissingCoreMetric = isMissingCoreMetric || metric.isCore
                continue
            }

            let normalizedValue = metric.normalizedValue(value)
            guard normalizedValue.isFinite else {
                missingMetrics.insert(metric.name)
                isMissingCoreMetric = isMissingCoreMetric || metric.isCore
                continue
            }

            availableCount += 1
            availableWeight += metric.weight
            weightedScore += metric.weight * normalizedValue
        }

        let completeness = Double(availableCount) / Double(metrics.count)
        guard !isMissingCoreMetric, availableWeight > 0, weightedScore.isFinite else {
            return NetworkExperienceScore(
                value: nil,
                grade: .dataInsufficient,
                completeness: completeness,
                missingMetrics: missingMetrics,
                modelVersion: modelVersion
            )
        }

        let normalizedScore = clamp(weightedScore / availableWeight)
        guard normalizedScore.isFinite else {
            return NetworkExperienceScore(
                value: nil,
                grade: .dataInsufficient,
                completeness: completeness,
                missingMetrics: missingMetrics,
                modelVersion: modelVersion
            )
        }

        let value = Int(normalizedScore.rounded())
        let grade: NetworkExperienceGrade
        switch value {
        case 80...:
            grade = .stable
        case 55...:
            grade = .average
        default:
            grade = .congested
        }

        return NetworkExperienceScore(
            value: value,
            grade: grade,
            completeness: completeness,
            missingMetrics: missingMetrics,
            modelVersion: modelVersion
        )
    }

    static func higherLog(_ x: Double, bad: Double, good: Double) -> Double {
        guard x.isFinite,
              x >= 0,
              bad.isFinite,
              bad > 0,
              good.isFinite,
              good > bad else {
            return 0
        }

        let value = log(max(x, bad) / bad) / log(good / bad) * 100
        return value.isFinite ? clamp(value) : 0
    }

    static func lowerLinear(_ x: Double, good: Double, bad: Double) -> Double {
        guard x.isFinite,
              x >= 0,
              good.isFinite,
              good >= 0,
              bad.isFinite,
              bad > good else {
            return 0
        }

        let value = (bad - x) / (bad - good) * 100
        return value.isFinite ? clamp(value) : 0
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
