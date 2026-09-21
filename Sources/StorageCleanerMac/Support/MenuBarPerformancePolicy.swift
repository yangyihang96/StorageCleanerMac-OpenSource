import Foundation

/// Local performance contract shared by collection, presentation and release checks.
enum MenuBarPerformancePolicy {
    static let visibleProcessInterval: TimeInterval = 2
    static let cachedWindowLifetime: Duration = .seconds(300)
    static let derivedCacheByteLimit = 32 * 1_024 * 1_024
    static let derivedCachePageLimit = 4
    static let warmPresentationBudget: TimeInterval = 0.100
    static let coldPresentationBudget: TimeInterval = 0.250
    static let publicationBudget: TimeInterval = 0.100
    static let mainThreadBlockBudget: TimeInterval = 0.050
    static let contentCoalescingInterval: TimeInterval = 0.016
}

struct MenuBarDisplayRevision: Equatable, Sendable {
    let sampledAt: Date?
    let version: UInt64
}
