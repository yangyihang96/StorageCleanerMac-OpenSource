#if DEBUG
import Foundation
import SwiftUI

/// A bounded settle gate driven by observed render frames and state layers.
/// Busy=false alone does not mean that a screenshot is settled.
struct FeatureLightfieldSettleGate {
    static let animationBudget = max(FeatureLightfieldMotion.completion, FeatureLightfieldMotion.number,
        FeatureLightfieldMotion.rowDelay + Double(FeatureLightfieldMotion.maximumEntranceIndex) * FeatureLightfieldMotion.rowInterval
            + FeatureLightfieldMotion.row) + FeatureLightfieldMotion.artworkFade
    static let stableInterval = 0.35
    private var previous: [String: CGRect]?
    private var stableSince: TimeInterval?

    mutating func observe(elapsed: TimeInterval, busy: Bool, matchesPage: Bool,
                         layers: [String: Int], expectedPhase: FeatureLightfieldPhase,
                         frames: [String: CGRect], minimumDelay: TimeInterval = animationBudget) -> Bool {
        guard !busy, matchesPage, layers == [expectedPhase.rawValue: 1],
              let content = frames["lightfield.content"], content.height > 0,
              frames["lightfield.primary"] != nil, frames["lightfield.status"] != nil else {
            previous = nil
            stableSince = nil
            return false
        }
        if previous != frames { previous = frames; stableSince = elapsed }
        guard let stableSince else { return false }
        return elapsed >= minimumDelay && elapsed - stableSince >= Self.stableInterval
    }
}

@MainActor
enum FeatureLightfieldResultAudit {
    static var module: ReviewFilter?
    static var phase: FeatureLightfieldPhase?
    static var layers: [String: Int] = [:]
    static func begin(module: ReviewFilter, phase: FeatureLightfieldPhase) {
        self.module = module
        self.phase = phase
    }
    /// Only shell/list geometry is used for settling. Changing live text values
    /// are not compared or exported as part of the stability fingerprint.
    static var frames: [String: CGRect] {
        FeatureVisualProbeStore.frames.filter { key, _ in
            ["lightfield.canvas", "lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.primary.hitTarget", "lightfield.status",
             "lightfield.artwork", "lightfield.result.summary", "lightfield.results.scrollViewport",
             "lightfield.privacy.scrollViewport"].contains(key)
        }
    }
    static var capture: [String: Any] {
        ["module": module?.rawValue ?? "unobserved", "phase": phase?.rawValue ?? "unobserved",
         "stateLayers": layers, "singleStateLayer": layers.values.reduce(0, +) == 1,
         "frames": frames.mapValues { ["x": Double($0.minX), "y": Double($0.minY),
            "width": Double($0.width), "height": Double($0.height)] }]
    }
}
#endif
