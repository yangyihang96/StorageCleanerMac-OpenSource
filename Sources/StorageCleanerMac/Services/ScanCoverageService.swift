import Foundation

enum ScanCoverageLevel: String, Equatable, Sendable {
    case complete
    case partial
    case limited
}

struct ScanCoverageSummary: Equatable, Sendable {
    let deniedPaths: [String]
    let previewLimit: Int

    var deniedCount: Int {
        deniedPaths.count
    }

    var highImpactDeniedCount: Int {
        ScanCoverageService.highImpactDeniedCount(in: deniedPaths)
    }

    var level: ScanCoverageLevel {
        switch deniedCount {
        case 0:
            .complete
        case 1...2:
            .partial
        default:
            .limited
        }
    }

    var estimatedCoveragePercent: Int {
        switch level {
        case .complete:
            100
        case .partial, .limited:
            max(55, 100 - deniedCount * 10 - highImpactDeniedCount * 5)
        }
    }

    var scorePenalty: Int {
        ScanCoverageService.scorePenalty(deniedPaths: deniedPaths)
    }

    var previewPaths: [String] {
        Array(deniedPaths.prefix(previewLimit))
    }

    var hiddenDeniedCount: Int {
        max(0, deniedCount - previewLimit)
    }
}

enum ScanCoverageService {
    static func summary(
        deniedPaths: [String],
        previewLimit: Int = 4
    ) -> ScanCoverageSummary {
        ScanCoverageSummary(
            deniedPaths: uniqueDeniedPaths(deniedPaths).sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            },
            previewLimit: max(0, previewLimit)
        )
    }

    static func scorePenalty(deniedPaths: [String]) -> Int {
        let uniquePaths = uniqueDeniedPaths(deniedPaths)
        let highImpactCount = highImpactDeniedCount(in: uniquePaths)
        let lowImpactCount = max(0, uniquePaths.count - highImpactCount)

        guard highImpactCount > 0 else {
            return scorePenalty(deniedCount: lowImpactCount)
        }

        return min(10, 5 + highImpactCount + (lowImpactCount + 1) / 2)
    }

    static func scorePenalty(deniedCount: Int) -> Int {
        switch deniedCount {
        case ..<1:
            return 0
        case 1:
            return 2
        case 2:
            return 3
        default:
            return 4
        }
    }

    static func highImpactDeniedCount(in paths: [String]) -> Int {
        uniqueDeniedPaths(paths).filter(isHighImpactDeniedPath).count
    }

    private static func uniqueDeniedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            let key = PathSafety.normalizedPath(path).lowercased()
            return seen.insert(key).inserted
        }
    }

    private static func isHighImpactDeniedPath(_ path: String) -> Bool {
        let normalized = PathSafety.normalizedPath(path).lowercased()
        let tokens = [
            "/downloads",
            "/desktop",
            "/documents",
            "/.trash",
            "trash",
            "/pictures",
            "photos library",
            "library/mail",
            "mobile documents",
            "onedrive",
            "icloud"
        ]

        return tokens.contains { normalized.contains($0) }
    }
}
