import Foundation

struct RobustTrendSample: Equatable, Sendable {
    let recordedAt: Date
    let value: Double
}

struct RobustTrendEstimate: Equatable, Sendable {
    let slopePerDay: Double
    let slopeMAD: Double
    let residualMAD: Double
    let negativePairFraction: Double
    let sampleCount: Int
    let spanDays: Int
}

enum RobustTrendStatistics {
    private static let secondsPerDay = 86_400.0
    private static let maximumSampleCount = 366

    static func distinctDailySamples(
        _ samples: [RobustTrendSample]
    ) -> [RobustTrendSample] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var latestByDay: [Date: RobustTrendSample] = [:]

        for sample in samples {
            guard sample.recordedAt.timeIntervalSinceReferenceDate.isFinite,
                  sample.value.isFinite else { continue }
            let day = calendar.startOfDay(for: sample.recordedAt)
            if let existing = latestByDay[day],
               existing.recordedAt > sample.recordedAt
            {
                continue
            }
            latestByDay[day] = sample
        }

        return latestByDay.values.sorted { lhs, rhs in
            if lhs.recordedAt == rhs.recordedAt {
                return lhs.value < rhs.value
            }
            return lhs.recordedAt < rhs.recordedAt
        }
    }

    static func theilSen(
        samples rawSamples: [RobustTrendSample]
    ) -> RobustTrendEstimate? {
        let samples = distinctDailySamples(rawSamples)
        guard samples.count >= 2,
              samples.count <= maximumSampleCount,
              let firstDate = samples.first?.recordedAt,
              let lastDate = samples.last?.recordedAt else { return nil }

        let span = lastDate.timeIntervalSince(firstDate) / secondsPerDay
        guard span.isFinite, span >= 1 else { return nil }

        var slopes: [Double] = []
        let pairCount = samples.count * (samples.count - 1) / 2
        slopes.reserveCapacity(pairCount)
        for lowerIndex in samples.indices.dropLast() {
            for upperIndex in samples.indices where upperIndex > lowerIndex {
                let elapsedDays = samples[upperIndex].recordedAt
                    .timeIntervalSince(samples[lowerIndex].recordedAt) / secondsPerDay
                guard elapsedDays.isFinite, elapsedDays > 0 else { continue }
                let slope = (samples[upperIndex].value - samples[lowerIndex].value)
                    / elapsedDays
                guard slope.isFinite else { return nil }
                slopes.append(slope)
            }
        }

        guard !slopes.isEmpty,
              let slope = median(slopes),
              let slopeMAD = medianAbsoluteDeviation(slopes) else { return nil }

        let interceptCandidates = samples.map { sample -> Double in
            let elapsedDays = sample.recordedAt.timeIntervalSince(firstDate) / secondsPerDay
            return sample.value - slope * elapsedDays
        }
        guard let intercept = median(interceptCandidates) else { return nil }
        let residuals = samples.map { sample -> Double in
            let elapsedDays = sample.recordedAt.timeIntervalSince(firstDate) / secondsPerDay
            return sample.value - (intercept + slope * elapsedDays)
        }
        guard let residualMAD = medianAbsoluteDeviation(residuals) else { return nil }

        let negativeCount = slopes.reduce(into: 0) { count, candidate in
            if candidate < 0 { count += 1 }
        }
        let negativePairFraction = Double(negativeCount) / Double(slopes.count)
        let spanDays = Int(floor(span + 0.000_000_1))
        guard slope.isFinite,
              slopeMAD.isFinite,
              residualMAD.isFinite,
              negativePairFraction.isFinite,
              spanDays >= 1 else { return nil }

        return RobustTrendEstimate(
            slopePerDay: slope,
            slopeMAD: slopeMAD,
            residualMAD: residualMAD,
            negativePairFraction: negativePairFraction,
            sampleCount: samples.count,
            spanDays: spanDays
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty,
              values.allSatisfy(\.isFinite) else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            let sum = sorted[middle - 1] + sorted[middle]
            guard sum.isFinite else { return nil }
            return sum / 2
        }
        return sorted[middle]
    }

    static func medianAbsoluteDeviation(_ values: [Double]) -> Double? {
        guard let center = median(values) else { return nil }
        let deviations = values.map { abs($0 - center) }
        return median(deviations)
    }
}
