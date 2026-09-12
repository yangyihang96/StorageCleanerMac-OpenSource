import Foundation

/// The only benchmark plan exposed by the product UI.
///
/// The underlying standard workload and scoring contract remain unchanged. The
/// official session adds the short sustained-check category to the same session
/// so it cannot be mistaken for a second user-selectable benchmark mode.
struct OfficialBenchmarkPlan: Equatable, Sendable {
    let plan: BenchmarkV7Plan
    let categories: [BenchmarkV7Category]

    static let current = Self(
        plan: BenchmarkV7Plan(
            kind: .standard,
            planVersion: BenchmarkV7Plan.standard.planVersion,
            workloadVersion: BenchmarkV7Plan.standard.workloadVersion,
            expectedMinimumDurationSeconds: BenchmarkV7Plan.standard.expectedMinimumDurationSeconds
                + Int(MacSustainedBenchmarkProfile.standard.targetDurationSeconds),
            expectedMaximumDurationSeconds: BenchmarkV7Plan.standard.expectedMaximumDurationSeconds
                + Int(MacSustainedBenchmarkProfile.standard.targetDurationSeconds),
            categories: BenchmarkV7Plan.standard.categories + [.sustained]
        ),
        categories: BenchmarkV7Plan.standard.categories + [.sustained]
    )

    var protocolVersion: String { plan.planVersion }
    var expectedMinimumDurationSeconds: Int { plan.expectedMinimumDurationSeconds }
    var expectedMaximumDurationSeconds: Int { plan.expectedMaximumDurationSeconds }

    func matches(
        plan candidatePlan: BenchmarkV7Plan,
        categories candidateCategories: [BenchmarkV7Category]
    ) -> Bool {
        candidatePlan == plan && Set(candidateCategories) == Set(categories)
    }
}

extension BenchmarkV7Result {
    var matchesCurrentOfficialPlan: Bool {
        let current = OfficialBenchmarkPlan.current
        return current.matches(plan: session.plan, categories: session.categories)
            && versions.planVersion == current.plan.planVersion
            && versions.workloadVersion == current.plan.workloadVersion
            && versions.isValid
    }

    /// Only a complete, validated official session may replace the visible
    /// latest result or become a ranking candidate.
    var isCurrentOfficialResult: Bool {
        matchesCurrentOfficialPlan
            && failure == nil
            && completedAt != nil
            && coreScore != nil
            && experienceScore != nil
            && sustainedResult?.reachedTargetDuration == true
            && !metrics.isEmpty
            && metrics.allSatisfy(\.isValid)
    }

    var isCurrentLocalBestEligible: Bool {
        isCurrentOfficialResult
            && preflight.powerSource == .acPower
            && !preflight.lowPowerModeEnabled
            && preflight.thermalState == .nominal
    }

    var isCurrentOfficialRankingEligible: Bool {
        // All confidence ratings are publishable by owner decision; a missing
        // rating still cannot be labeled honestly on the public board.
        isCurrentLocalBestEligible && confidence != nil
    }
}
