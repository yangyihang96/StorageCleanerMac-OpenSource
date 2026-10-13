#if DEBUG
import SwiftUI

/// Rendered inputs, not native AX evidence. The layout probes independently
/// verify the stage and cancellation slot exist in the hosted production page.
struct FeatureRuntimeRenderSnapshot: Equatable, Sendable {
    let stageTitle: String
    let cancellationTitle: String
    let cancellationHasAction: Bool
    let cancellationIsEnabled: Bool
    var safetyText: String = ""
}

struct FeatureScrollRenderSnapshot: Equatable, Sendable {
    let naturalHeight: CGFloat
    let availableHeight: CGFloat
    let visibleHeight: CGFloat
    let overflowing: Bool
    let showsHint: Bool
}
struct FeatureScrollRenderPreferenceKey: PreferenceKey {
    static let defaultValue: [String: FeatureScrollRenderSnapshot] = [:]
    static func reduce(value: inout [String: FeatureScrollRenderSnapshot], nextValue: () -> [String: FeatureScrollRenderSnapshot]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct FeatureBackdropPreferenceKey: PreferenceKey {
    static let defaultValue: [String: Bool] = [:]
    static func reduce(value: inout [String: Bool], nextValue: () -> [String: Bool]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Captured from the rendered preference tree, not calculated by the
/// screenshot driver. No observation/timer or persistent preference writes.
@MainActor
enum FeatureVisualProbeStore {
    static var scrollSnapshots: [String: FeatureScrollRenderSnapshot] = [:]
    static var backdrops: [String: Bool] = [:]
    static var frames: [String: CGRect] = [:]
    static var capture: [String: Any] {
        ["outerBackdrops": backdrops,
         "frames": frames.mapValues { frame in
            ["x": Double(frame.minX), "y": Double(frame.minY),
             "width": Double(frame.width), "height": Double(frame.height)]
         },
         "scrollGeometry": scrollSnapshots.mapValues { value in
            ["naturalHeight": value.naturalHeight, "availableHeight": value.availableHeight,
             "visibleHeight": value.visibleHeight, "overflowing": value.overflowing,
             "showsHint": value.showsHint] as [String: Any]
         }]
    }
}

struct FeatureRuntimeRenderPreferenceKey: PreferenceKey {
    static let defaultValue: [String: FeatureRuntimeRenderSnapshot] = [:]

    static func reduce(value: inout [String: FeatureRuntimeRenderSnapshot],
                       nextValue: () -> [String: FeatureRuntimeRenderSnapshot]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#endif
