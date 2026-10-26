// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Presentation/Icon/OuterRingState.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

enum RingGapStyle: Equatable, Hashable, Sendable {
    case closed
    case indicator
    case value
}

enum RingAccessoryState: Equatable, Hashable, Sendable {
    case symbol(IconSymbolState)
    case text(IconTextState)
}

struct RingSegmentState: Equatable, Hashable, Sendable {
    let progress: Double
    let color: IconColorRole

    init(progress: Double, color: IconColorRole) {
        self.progress = Self.normalizedProgress(progress)
        self.color = color
    }

    static func normalizedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }
}

struct RingEffectState: Equatable, Hashable, Sendable {
    let pulsesAccessory: Bool
    let tintsAccessory: Bool
}

struct OuterRingState: Equatable, Hashable, Sendable {
    let segments: [RingSegmentState]
    let gap: RingGapStyle
    let accessory: RingAccessoryState?
    let effect: RingEffectState?
    let strokeScale: Double

    init(
        segments: [RingSegmentState],
        gap: RingGapStyle,
        accessory: RingAccessoryState? = nil,
        effect: RingEffectState? = nil,
        strokeScale: Double = 1.25
    ) {
        self.segments = segments
        self.gap = gap
        self.accessory = accessory
        self.effect = effect
        self.strokeScale = Self.normalizedStrokeScale(strokeScale)
    }

    static func normalizedStrokeScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1.25 }
        return min(2.5, max(0.5, scale))
    }
}
