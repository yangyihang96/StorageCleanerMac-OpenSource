import Foundation

struct HealthComponentScoreAccounting: Equatable, Sendable {
    let factor: HealthFactor
    let availabilityCredit: Double
    let creditedWeight: Double
    let weightedScore: Double
    let normalizedDeduction: Double?
}

struct ComputerHealthScoreAccounting: Equatable, Sendable {
    let applicableWeight: Double
    let creditedWeight: Double
    let coverage: Double
    let weightedScore: Double
    let normalizedScore: Double?
    let components: [HealthComponentScoreAccounting]

    func component(for factor: HealthFactor) -> HealthComponentScoreAccounting? {
        components.first { $0.factor == factor }
    }
}

enum ComputerHealthScoring {
    static let modelVersion = ComputerHealthEvaluation.currentModelVersion
    static let minimumCoverage = 0.70
    static let scoredFactors: [HealthFactor] = [
        .diskReliability,
        .capacity,
        .stability,
        .battery
    ]
    static let weights: [HealthFactor: Double] = [
        .diskReliability: 35,
        .capacity: 15,
        .stability: 20,
        .backup: 0,
        .battery: 30
    ]

    static func evaluate(
        snapshot: ComputerHealthSnapshot,
        history: [ComputerHealthHistoryEntry] = [],
        referenceDate: Date = Date(),
        confidence: HealthConfidence = HealthConfidence(
            value: 0,
            level: .low,
            modelVersion: "health-confidence-v1"
        )
    ) -> ComputerHealthEvaluation {
        let components = [
            diskEvaluation(snapshot.disk, referenceDate: referenceDate),
            capacityEvaluation(snapshot.capacity, referenceDate: referenceDate),
            stabilityEvaluation(snapshot.stability, referenceDate: referenceDate),
            backupEvaluation(
                snapshot.backup,
                history: history,
                referenceDate: referenceDate
            ),
            batteryEvaluation(snapshot.batteryEvidence, referenceDate: referenceDate)
        ]

        let accounting = accounting(for: components)
        let applicableWeight = accounting.applicableWeight
        let creditedWeight = accounting.creditedWeight
        let coverage = accounting.coverage

        let smartIsFailing = snapshot.disk.smartStatus == .failing
        guard applicableWeight > 0,
              creditedWeight > 0,
              coverage >= minimumCoverage
        else {
            return ComputerHealthEvaluation(
                score: nil,
                status: smartIsFailing ? .actionRequired : .dataInsufficient,
                coverage: coverage,
                confidence: confidence,
                components: components,
                evaluatedAt: referenceDate,
                modelVersion: modelVersion
            )
        }

        guard let normalizedScore = accounting.normalizedScore,
              normalizedScore.isFinite else {
            return ComputerHealthEvaluation.dataInsufficient(
                coverage: coverage,
                confidence: confidence,
                components: components,
                evaluatedAt: referenceDate,
                modelVersion: modelVersion
            )
        }

        var score = clamp(normalizedScore, lower: 0, upper: 100)
        if smartIsFailing {
            score = min(score, 20)
        }
        let scoredComponentScores = components.compactMap { component -> Double? in
            guard scoredFactors.contains(component.factor),
                  component.availability == .available || component.availability == .partial,
                  let score = component.score,
                  score.isFinite else { return nil }
            return score
        }
        let hasActionRequiredComponent = scoredComponentScores.contains { $0 < 50 }
        let hasAttentionComponent = scoredComponentScores.contains { $0 < 85 }
        let status: ComputerHealthEvaluationStatus
        if smartIsFailing || hasActionRequiredComponent {
            status = .actionRequired
        } else if hasAttentionComponent || score < 90 {
            status = .attention
        } else {
            status = .healthy
        }

        return ComputerHealthEvaluation(
            score: score,
            status: status,
            coverage: coverage,
            confidence: confidence,
            components: components,
            evaluatedAt: referenceDate,
            modelVersion: modelVersion
        )
    }

    static func availabilityCredit(_ availability: HealthEvidenceAvailability) -> Double {
        switch availability {
        case .available:
            1
        case .partial:
            0.5
        case .permissionDenied, .timedOut, .unavailable, .notApplicable:
            0
        }
    }

    static func accounting(
        for components: [HealthComponentEvaluation]
    ) -> ComputerHealthScoreAccounting {
        struct Intermediate {
            let factor: HealthFactor
            let availabilityCredit: Double
            let creditedWeight: Double
            let weightedScore: Double
        }

        var applicableWeight = 0.0
        var creditedWeight = 0.0
        var weightedScore = 0.0
        var intermediate: [Intermediate] = []
        intermediate.reserveCapacity(components.count)

        for component in components {
            let rawWeight = weights[component.factor] ?? 0
            let weight = rawWeight.isFinite && rawWeight > 0 ? rawWeight : 0
            if component.availability != .notApplicable {
                applicableWeight += weight
            }

            let credit = availabilityCredit(component.availability)
            let componentCreditedWeight = weight * credit
            let componentWeightedScore: Double
            if let score = component.score, score.isFinite {
                componentWeightedScore = componentCreditedWeight
                    * clamp(score, lower: 0, upper: 100)
            } else {
                componentWeightedScore = 0
            }
            creditedWeight += componentCreditedWeight
            weightedScore += componentWeightedScore
            intermediate.append(Intermediate(
                factor: component.factor,
                availabilityCredit: credit,
                creditedWeight: componentCreditedWeight,
                weightedScore: componentWeightedScore
            ))
        }

        let hasCreditedEvidence = creditedWeight > 0 && creditedWeight.isFinite
        let coverage: Double
        if applicableWeight > 0, applicableWeight.isFinite,
           creditedWeight.isFinite, creditedWeight >= 0 {
            coverage = clamp(creditedWeight / applicableWeight, lower: 0, upper: 1)
        } else {
            coverage = 0
        }
        let normalizedScore = hasCreditedEvidence && weightedScore.isFinite
            ? clamp(weightedScore / creditedWeight, lower: 0, upper: 100)
            : nil
        let componentAccounting = intermediate.map { component in
            let deduction: Double?
            if hasCreditedEvidence, component.creditedWeight > 0 {
                deduction = clamp(
                    (component.creditedWeight * 100 - component.weightedScore) / creditedWeight,
                    lower: 0,
                    upper: 100
                )
            } else {
                deduction = nil
            }
            return HealthComponentScoreAccounting(
                factor: component.factor,
                availabilityCredit: component.availabilityCredit,
                creditedWeight: component.creditedWeight,
                weightedScore: component.weightedScore,
                normalizedDeduction: deduction
            )
        }

        return ComputerHealthScoreAccounting(
            applicableWeight: applicableWeight,
            creditedWeight: creditedWeight,
            coverage: coverage,
            weightedScore: weightedScore,
            normalizedScore: normalizedScore,
            components: componentAccounting
        )
    }

    static func capacityScore(
        availableBytes: Int64,
        totalBytes: Int64
    ) -> Double? {
        guard totalBytes > 0,
              availableBytes >= 0,
              availableBytes <= totalBytes else { return nil }
        let ratio = Double(availableBytes) / Double(totalBytes)
        guard ratio.isFinite else { return nil }
        let ratioScore: Double = switch ratio {
        case 0.20...: 100
        case 0.10..<0.20: 70 + ((ratio - 0.10) / 0.10) * 30
        case 0.05..<0.10: 40 + ((ratio - 0.05) / 0.05) * 30
        default: clamp((ratio / 0.05) * 40, lower: 0, upper: 40)
        }
        let availableGiB = Double(availableBytes) / Double(1_024 * 1_024 * 1_024)
        let absoluteScore: Double = switch availableGiB {
        case 100...: 100
        case 50..<100: 85 + ((availableGiB - 50) / 50) * 15
        case 20..<50: 60 + ((availableGiB - 20) / 30) * 25
        case 10..<20: 40 + ((availableGiB - 10) / 10) * 20
        default: clamp((availableGiB / 10) * 40, lower: 0, upper: 40)
        }
        return clamp(0.6 * ratioScore + 0.4 * absoluteScore, lower: 0, upper: 100)
    }

    static func batteryCapacityScore(_ maximumCapacityPercent: Int) -> Double? {
        guard (0...100).contains(maximumCapacityPercent) else { return nil }
        let capacity = Double(maximumCapacityPercent)
        return switch capacity {
        case 90...: 100
        case 80..<90: 80 + (capacity - 80) * 2
        case 70..<80: 50 + (capacity - 70) * 3
        default: clamp((capacity / 70) * 50, lower: 0, upper: 50)
        }
    }

    static func stabilityScore(
        events: [StabilityEvent],
        referenceDate: Date
    ) -> Double {
        let penalty = events.reduce(0.0) { partial, event in
            let ageSeconds = max(0, referenceDate.timeIntervalSince(event.occurredAt))
            let ageDays = ageSeconds / 86_400
            let decay = pow(0.5, ageDays / 14)
            let eventPenalty = stabilityWeight(event.type) * decay
            guard eventPenalty.isFinite, eventPenalty >= 0 else { return partial }
            return min(100, partial + eventPenalty)
        }
        return clamp(100 - penalty, lower: 0, upper: 100)
    }

    private static func diskEvaluation(
        _ disk: DiskHealthSnapshot,
        referenceDate: Date
    ) -> HealthComponentEvaluation {
        let availability: HealthEvidenceAvailability
        let score: Double?
        switch disk.smartStatus {
        case .verified:
            availability = .available
            score = disk.remainingLifePercent.map { Double(min(max($0, 0), 100)) } ?? 100
        case .failing:
            availability = .available
            score = 0
        case .unsupported:
            availability = .unavailable
            score = nil
        case .unavailable:
            availability = evidenceAvailability(disk.availability)
            score = nil
        }
        return component(
            factor: .diskReliability,
            availability: score == nil
                ? unavailableVariant(from: availability)
                : availability,
            score: score,
            summary: "smart:\(disk.smartStatus.rawValue)",
            evaluatedAt: disk.checkedAt,
            fallbackDate: referenceDate
        )
    }

    private static func capacityEvaluation(
        _ capacity: CapacityTrendSnapshot,
        referenceDate: Date
    ) -> HealthComponentEvaluation {
        let mappedAvailability = evidenceAvailability(capacity.availability)
        let score: Double?
        if mappedAvailability == .available || mappedAvailability == .partial,
           let availableBytes = capacity.availableForImportantUsageBytes,
           let totalBytes = capacity.totalBytes
        {
            score = capacityScore(availableBytes: availableBytes, totalBytes: totalBytes)
        } else {
            score = nil
        }
        let availability: HealthEvidenceAvailability = score == nil
            ? unavailableVariant(from: mappedAvailability)
            : mappedAvailability
        return component(
            factor: .capacity,
            availability: availability,
            score: score,
            summary: "available-for-important-usage",
            evaluatedAt: capacity.recordedAt,
            fallbackDate: referenceDate
        )
    }

    private static func stabilityEvaluation(
        _ stability: StabilitySummary,
        referenceDate: Date
    ) -> HealthComponentEvaluation {
        let mappedAvailability = evidenceAvailability(stability.availability)
        let legacyCount = [
            stability.crashCount,
            stability.hangCount,
            stability.spinCount,
            stability.panicCount,
            stability.unexpectedRestartCount
        ].compactMap { $0 }.reduce(0, +)
        let hasUsableAvailability = mappedAvailability == .available
            || mappedAvailability == .partial
        let hasMissingDatedEvents = stability.events.isEmpty && legacyCount > 0
        let score = hasUsableAvailability && !hasMissingDatedEvents
            ? stabilityScore(events: stability.events, referenceDate: referenceDate)
            : nil
        let availability: HealthEvidenceAvailability = score == nil
            ? unavailableVariant(from: mappedAvailability)
            : mappedAvailability
        return component(
            factor: .stability,
            availability: availability,
            score: score,
            summary: hasMissingDatedEvents ? "dated-events-missing" : "dated-events",
            evaluatedAt: stability.generatedAt,
            fallbackDate: referenceDate
        )
    }

    private static func backupEvaluation(
        _ backup: TimeMachineSnapshot,
        history: [ComputerHealthHistoryEntry],
        referenceDate: Date
    ) -> HealthComponentEvaluation {
        let availability: HealthEvidenceAvailability
        let score: Double?
        let summary: String

        switch backup.destinationState {
        case .unconfigured:
            availability = .available
            score = 0
            summary = "not-configured"
        case .unreachable:
            let fallbackDate = backup.latestCompleteBackup
                ?? history.compactMap(\.latestVerifiedCompleteBackupAt).max()
            if fallbackDate != nil {
                availability = backup.availability == .available
                    ? .partial
                    : unavailableVariantAllowingPartial(
                        from: evidenceAvailability(backup.availability)
                    )
                score = availability == .partial ? 40 : nil
                summary = "destination-unreachable-with-verified-backup"
            } else {
                availability = unavailableVariant(
                    from: evidenceAvailability(backup.completeBackupAvailability)
                )
                score = nil
                summary = "destination-unreachable"
            }
        case .configured:
            if let latestCompleteBackup = backup.latestCompleteBackup {
                let mapped = evidenceAvailability(backup.completeBackupAvailability)
                availability = mapped == .available || mapped == .partial
                    ? mapped
                    : .partial
                score = backupAgeScore(
                    backupDate: latestCompleteBackup,
                    referenceDate: referenceDate
                )
                summary = "verified-complete-backup"
            } else {
                availability = unavailableVariant(
                    from: evidenceAvailability(backup.completeBackupAvailability)
                )
                score = nil
                summary = "complete-backup-date-unavailable"
            }
        case .permissionDenied:
            availability = .permissionDenied
            score = nil
            summary = "permission-denied"
        case .timedOut:
            availability = .timedOut
            score = nil
            summary = "timed-out"
        case .unavailable:
            availability = .unavailable
            score = nil
            summary = "unavailable"
        }

        return component(
            factor: .backup,
            availability: availability,
            score: score,
            summary: summary,
            evaluatedAt: backup.checkedAt,
            fallbackDate: referenceDate
        )
    }

    private static func batteryEvaluation(
        _ evidence: BatteryHealthEvidence,
        referenceDate: Date
    ) -> HealthComponentEvaluation {
        switch evidence {
        case let .notPresent(checkedAt):
            return component(
                factor: .battery,
                availability: .notApplicable,
                score: nil,
                summary: "no-internal-battery",
                evaluatedAt: checkedAt,
                fallbackDate: referenceDate
            )
        case let .failed(reason, checkedAt):
            return component(
                factor: .battery,
                availability: batteryFailureAvailability(reason),
                score: nil,
                summary: "probe:\(reason.rawValue)",
                evaluatedAt: checkedAt,
                fallbackDate: referenceDate
            )
        case let .present(battery):
            let mappedAvailability = evidenceAvailability(battery.availability)
            guard mappedAvailability == .available || mappedAvailability == .partial else {
                return component(
                    factor: .battery,
                    availability: mappedAvailability,
                    score: nil,
                    summary: "battery-evidence-unavailable",
                    evaluatedAt: battery.sampledAt,
                    fallbackDate: referenceDate
                )
            }

            let capacityScore = battery.maximumCapacityPercent.flatMap(batteryCapacityScore)
            let score: Double?
            let availability: HealthEvidenceAvailability
            if battery.condition == .serviceRecommended {
                score = min(capacityScore ?? 40, 40)
                availability = capacityScore == nil ? .partial : mappedAvailability
            } else {
                score = capacityScore
                availability = capacityScore == nil
                    ? unavailableVariant(from: mappedAvailability)
                    : mappedAvailability
            }
            return component(
                factor: .battery,
                availability: availability,
                score: score,
                summary: "maximum-capacity-and-condition",
                evaluatedAt: battery.sampledAt,
                fallbackDate: referenceDate
            )
        }
    }

    private static func backupAgeScore(
        backupDate: Date,
        referenceDate: Date
    ) -> Double {
        let ageDays = max(0, referenceDate.timeIntervalSince(backupDate)) / 86_400
        return switch ageDays {
        case ...1:
            100
        case ...3:
            90
        case ...7:
            75
        case ...14:
            50
        default:
            25
        }
    }

    private static func stabilityWeight(_ type: StabilityEventType) -> Double {
        switch type {
        case .panic:
            60
        case .unexpectedRestart:
            40
        case .hang:
            8
        case .spin, .crash:
            0 // Per-app diagnostics do not measure device-level stability.
        }
    }

    private static func batteryFailureAvailability(
        _ reason: BatteryHealthProbeFailureReason
    ) -> HealthEvidenceAvailability {
        switch reason {
        case .permissionDenied:
            .permissionDenied
        case .timedOut:
            .timedOut
        case .cancelled, .unavailable, .readFailed:
            .unavailable
        }
    }

    private static func evidenceAvailability(
        _ availability: HealthAvailability
    ) -> HealthEvidenceAvailability {
        switch availability {
        case .available:
            .available
        case .partial:
            .partial
        case .permissionDenied:
            .permissionDenied
        case .timedOut:
            .timedOut
        case .cancelled, .unavailable:
            .unavailable
        }
    }

    private static func unavailableVariant(
        from availability: HealthEvidenceAvailability
    ) -> HealthEvidenceAvailability {
        switch availability {
        case .permissionDenied, .timedOut:
            availability
        case .available, .partial, .unavailable, .notApplicable:
            .unavailable
        }
    }

    private static func unavailableVariantAllowingPartial(
        from availability: HealthEvidenceAvailability
    ) -> HealthEvidenceAvailability {
        switch availability {
        case .available, .partial:
            .partial
        case .permissionDenied, .timedOut, .unavailable:
            availability
        case .notApplicable:
            .unavailable
        }
    }

    private static func component(
        factor: HealthFactor,
        availability: HealthEvidenceAvailability,
        score: Double?,
        summary: String,
        evaluatedAt: Date,
        fallbackDate: Date
    ) -> HealthComponentEvaluation {
        HealthComponentEvaluation(
            factor: factor,
            availability: availability,
            score: score.map { clamp($0, lower: 0, upper: 100) },
            evidenceSummary: summary,
            evaluatedAt: evaluatedAt.timeIntervalSinceReferenceDate.isFinite
                ? evaluatedAt
                : fallbackDate,
            modelVersion: modelVersion
        )
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}
