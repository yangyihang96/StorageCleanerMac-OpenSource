import Foundation

/// Eligibility shared by the local latest-result and best-result projections.
///
/// A persisted record is only comparable with a newly produced result when its
/// entire version manifest matches the currently shipped official protocol.
/// Checking the plan alone is not enough: the workload, statistics, scoring,
/// and reference-set revisions can all change the meaning of a score.
extension BenchmarkV7Result {
    var isCurrentComparableOfficialResult: Bool {
        guard isCurrentOfficialResult,
              let coreScore,
              let experienceScore,
              coreScore.overallScore.isFinite,
              coreScore.overallScore > 0,
              experienceScore.overallScore.isFinite,
              experienceScore.overallScore > 0,
              BenchmarkV7Category.corePerformance.allSatisfy({ category in
                  guard let score = coreScore.categoryScores[category] else {
                      return false
                  }
                  return score.ratio.isFinite
                      && score.ratio > 0
                      && score.score.isFinite
                      && score.score > 0
              })
        else {
            return false
        }

        let currentManifest = BenchmarkV7ReferenceCatalog.versions(
            for: OfficialBenchmarkPlan.current.plan
        )
        return BenchmarkV7Compatibility.classify(
            stored: versions,
            current: currentManifest
        ) == .directlyComparable
    }
}
