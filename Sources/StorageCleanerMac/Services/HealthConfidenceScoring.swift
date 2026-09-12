import Foundation

enum HealthConfidenceScoring {
    static let modelVersion = "health-confidence-v1"
    private static let halfLifeHours = 72.0
    private static let maximumFreshAgeHours = 30.0 * 24

    static func evaluate(
        coverage: Double,
        components: [HealthComponentEvaluation],
        history: [ComputerHealthHistoryEntry],
        referenceDate: Date = Date(),
        evaluationModelVersion: String = ComputerHealthEvaluation.currentModelVersion
    ) -> HealthConfidence {
        let validCoverage = coverage.isFinite ? clamp(coverage) : 0
        let freshnessValue = weightedFreshness(
            components: components,
            referenceDate: referenceDate
        )
        let historySpanValue = historySpan(
            history: history,
            modelVersion: evaluationModelVersion
        )
        let sameModelScores = history.compactMap { entry -> Double? in
            guard entry.evaluation.modelVersion == evaluationModelVersion,
                  let score = entry.evaluation.score,
                  score.isFinite,
                  (0...100).contains(score) else { return nil }
            return score
        }
        let consistencyValue = consistency(scores: sameModelScores)
        let rawValue = 100 * (
            0.50 * validCoverage
                + 0.25 * freshnessValue
                + 0.15 * historySpanValue
                + 0.10 * consistencyValue
        )
        let value = Int((clamp(rawValue / 100) * 100).rounded())
        let level: HealthConfidenceLevel
        if value >= 80 {
            level = .high
        } else if value >= 60 {
            level = .medium
        } else {
            level = .low
        }
        return HealthConfidence(
            value: value,
            level: level,
            modelVersion: modelVersion
        )
    }

    static func freshness(ageHours: Double) -> Double {
        guard ageHours.isFinite else { return 0 }
        if ageHours <= 0 { return 1 }
        if ageHours > maximumFreshAgeHours { return 0 }
        let value = exp(-log(2) * ageHours / halfLifeHours)
        return value.isFinite ? clamp(value) : 0
    }

    static func weightedFreshness(
        components: [HealthComponentEvaluation],
        referenceDate: Date
    ) -> Double {
        guard referenceDate.timeIntervalSinceReferenceDate.isFinite else { return 0 }
        var weightedTotal = 0.0
        var applicableWeight = 0.0
        for component in components where component.availability != .notApplicable {
            guard let weight = ComputerHealthScoring.weights[component.factor],
                  weight > 0,
                  weight.isFinite else { continue }
            let ageHours = referenceDate.timeIntervalSince(component.evaluatedAt) / 3_600
            applicableWeight += weight
            weightedTotal += weight * freshness(ageHours: ageHours)
        }
        guard applicableWeight > 0,
              applicableWeight.isFinite,
              weightedTotal.isFinite else { return 0 }
        return clamp(weightedTotal / applicableWeight)
    }

    static func historySpan(
        history: [ComputerHealthHistoryEntry],
        modelVersion: String
    ) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = Set(history.compactMap { entry -> Date? in
            guard entry.evaluation.modelVersion == modelVersion,
                  entry.recordedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return calendar.startOfDay(for: entry.recordedAt)
        })
        return clamp(Double(days.count) / 30)
    }

    static func consistency(scores: [Double]) -> Double {
        let validScores = scores.filter { $0.isFinite && (0...100).contains($0) }
        guard validScores.count >= 5,
              let medianScore = median(validScores) else { return 0 }
        let deviations = validScores.map { abs($0 - medianScore) }
        guard let scoreMAD = median(deviations), scoreMAD.isFinite else { return 0 }
        return 1 - clamp(scoreMAD / 15)
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

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
