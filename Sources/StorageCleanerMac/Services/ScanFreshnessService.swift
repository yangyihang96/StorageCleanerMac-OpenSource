import Foundation

enum ScanFreshnessLevel: Equatable, Sendable {
    case fresh
    case aging
    case stale
}

struct ScanFreshnessSummary: Equatable, Sendable {
    let generatedAt: Date
    let referenceDate: Date
    let ageSeconds: TimeInterval

    var level: ScanFreshnessLevel {
        if ageSeconds < ScanFreshnessService.agingThresholdSeconds {
            return .fresh
        }
        if ageSeconds < ScanFreshnessService.staleThresholdSeconds {
            return .aging
        }
        return .stale
    }

    var shouldRescan: Bool {
        level != .fresh
    }
}

enum ScanFreshnessService {
    static let agingThresholdSeconds: TimeInterval = 2 * 60 * 60
    static let staleThresholdSeconds: TimeInterval = 24 * 60 * 60

    static func summary(
        generatedAt: Date,
        referenceDate: Date = Date()
    ) -> ScanFreshnessSummary {
        ScanFreshnessSummary(
            generatedAt: generatedAt,
            referenceDate: referenceDate,
            ageSeconds: max(0, referenceDate.timeIntervalSince(generatedAt))
        )
    }
}
