import Foundation

struct BatteryWearSample: Equatable, Sendable {
    let recordedAt: Date
    let maximumCapacityPercent: Double
    let cycleCount: Int?
}

enum BatteryWearTrendAnalysis {
    private static let minimumSampleCount = 8
    private static let minimumSpanDays = 45
    private static let maximumSampleCount = 366
    private static let maximumCapacityMAD = 1.5
    private static let highConfidenceThreshold = 70
    private static let maximumLatestSampleAge: TimeInterval = 36 * 3_600
    private static let slopeMADScale = 1.4826
    private static let minimumQuickDeclinePairFraction = 0.75
    private static let quickDeclineLossPer90Days = 3.0

    static func evaluate(
        history: [ComputerHealthHistoryEntry],
        referenceDate: Date = Date()
    ) -> BatteryWearTrend? {
        evaluate(
            samples: history.compactMap { entry in
                guard entry.modelVersion == ComputerHealthHistoryEntry.currentModelVersion,
                      let maximumCapacityPercent = entry.maximumCapacityPercent else {
                    return nil
                }
                return BatteryWearSample(
                    recordedAt: entry.recordedAt,
                    maximumCapacityPercent: Double(maximumCapacityPercent),
                    cycleCount: entry.batteryCycleCount
                )
            },
            referenceDate: referenceDate
        )
    }

    static func evaluate(
        samples rawSamples: [BatteryWearSample],
        referenceDate: Date = Date()
    ) -> BatteryWearTrend? {
        guard referenceDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let samples = distinctValidDailySamples(
            rawSamples,
            noLaterThan: referenceDate
        )
        guard samples.count >= minimumSampleCount,
              samples.count <= maximumSampleCount,
              let latest = samples.last else { return nil }
        let latestSampleAge = referenceDate.timeIntervalSince(latest.recordedAt)
        guard latestSampleAge.isFinite,
              latestSampleAge >= 0,
              latestSampleAge <= maximumLatestSampleAge else { return nil }

        let trendSamples = samples.map {
            RobustTrendSample(
                recordedAt: $0.recordedAt,
                value: $0.maximumCapacityPercent
            )
        }
        guard let estimate = RobustTrendStatistics.theilSen(samples: trendSamples),
              estimate.sampleCount == samples.count,
              estimate.spanDays >= minimumSpanDays,
              estimate.residualMAD <= maximumCapacityMAD else { return nil }

        let lossPer90Days = max(0, -estimate.slopePerDay * 90)
        guard lossPer90Days.isFinite else { return nil }
        let confidence = confidence(
            sampleCount: estimate.sampleCount,
            spanDays: estimate.spanDays,
            capacityMAD: estimate.residualMAD,
            slopePerDay: estimate.slopePerDay,
            slopeMAD: estimate.slopeMAD,
            negativePairFraction: estimate.negativePairFraction
        )
        let robustSlopeRange = slopeMADScale * estimate.slopeMAD
        let hasConsistentQuickDecline = estimate.negativePairFraction
                >= minimumQuickDeclinePairFraction
            && estimate.slopePerDay < 0
            && robustSlopeRange.isFinite
            && estimate.slopePerDay + robustSlopeRange
                <= -quickDeclineLossPer90Days / 90
        let classification: BatteryWearTrendClassification
        if confidence < highConfidenceThreshold {
            classification = .observe
        } else if lossPer90Days >= quickDeclineLossPer90Days,
                  hasConsistentQuickDecline {
            classification = .decliningQuickly
        } else if lossPer90Days >= 1 {
            classification = .observe
        } else {
            classification = .stable
        }

        return BatteryWearTrend(
            lossPer90Days: lossPer90Days,
            lossPer100Cycles: cycleNormalizedLoss(samples: samples),
            capacityMAD: estimate.residualMAD,
            confidence: confidence,
            classification: classification,
            sampleCount: estimate.sampleCount,
            spanDays: estimate.spanDays,
            evaluatedAt: referenceDate
        )
    }

    private static func distinctValidDailySamples(
        _ samples: [BatteryWearSample],
        noLaterThan referenceDate: Date
    ) -> [BatteryWearSample] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var latestByDay: [Date: BatteryWearSample] = [:]

        for sample in samples {
            guard sample.recordedAt.timeIntervalSinceReferenceDate.isFinite,
                  sample.recordedAt <= referenceDate,
                  sample.maximumCapacityPercent.isFinite,
                  (0...100).contains(sample.maximumCapacityPercent) else { continue }
            let normalized = BatteryWearSample(
                recordedAt: sample.recordedAt,
                maximumCapacityPercent: sample.maximumCapacityPercent,
                cycleCount: sample.cycleCount.flatMap { $0 >= 0 ? $0 : nil }
            )
            let day = calendar.startOfDay(for: normalized.recordedAt)
            if let existing = latestByDay[day],
               existing.recordedAt > normalized.recordedAt
            {
                continue
            }
            latestByDay[day] = normalized
        }

        return latestByDay.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    private static func confidence(
        sampleCount: Int,
        spanDays: Int,
        capacityMAD: Double,
        slopePerDay: Double,
        slopeMAD: Double,
        negativePairFraction: Double
    ) -> Int {
        let countCredit = min(Double(sampleCount) / 16, 1)
        let spanCredit = min(Double(spanDays) / 90, 1)
        let noiseCredit = 1 - min(max(capacityMAD / maximumCapacityMAD, 0), 1)
        let slopeScale = max(abs(slopePerDay), 0.01 / 90)
        let slopeCredit = 1 - min(max(slopeMAD / slopeScale, 0), 1)
        // A fraction near either 0 or 1 is directionally coherent; a fraction
        // near 0.5 is consistent with a one-off calibration step or noise.
        let directionCredit = min(max(abs(negativePairFraction - 0.5) * 2, 0), 1)
        let evidenceCredit = 0.40 * countCredit
            + 0.30 * spanCredit
            + 0.30 * noiseCredit
        let consistencyMultiplier = 0.70 + 0.15 * slopeCredit + 0.15 * directionCredit
        let value = 100 * evidenceCredit * consistencyMultiplier
        return Int(min(max(value.rounded(), 0), 100))
    }

    private static func cycleNormalizedLoss(
        samples: [BatteryWearSample]
    ) -> Double? {
        let cycleSamples = samples.compactMap { sample -> (cycle: Int, capacity: Double)? in
            guard let cycle = sample.cycleCount else { return nil }
            return (cycle, sample.maximumCapacityPercent)
        }
        guard cycleSamples.count >= 4 else { return nil }
        for index in cycleSamples.indices.dropFirst() {
            guard cycleSamples[index].cycle >= cycleSamples[index - 1].cycle else {
                return nil
            }
        }
        guard let first = cycleSamples.first?.cycle,
              let last = cycleSamples.last?.cycle,
              last - first >= 10,
              Set(cycleSamples.map(\.cycle)).count >= 4 else { return nil }

        var slopes: [Double] = []
        for lowerIndex in cycleSamples.indices.dropLast() {
            for upperIndex in cycleSamples.indices where upperIndex > lowerIndex {
                let cycleDelta = cycleSamples[upperIndex].cycle - cycleSamples[lowerIndex].cycle
                guard cycleDelta > 0 else { continue }
                let slope = (
                    cycleSamples[upperIndex].capacity - cycleSamples[lowerIndex].capacity
                ) / Double(cycleDelta)
                guard slope.isFinite else { return nil }
                slopes.append(slope)
            }
        }
        guard let slope = RobustTrendStatistics.median(slopes) else { return nil }
        let loss = max(0, -slope * 100)
        return loss.isFinite ? loss : nil
    }
}
