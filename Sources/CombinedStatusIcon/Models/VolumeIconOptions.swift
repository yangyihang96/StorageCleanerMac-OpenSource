// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Models/VolumeIconOptions.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import Foundation

public enum VolumeDisplayStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case dots
    case arc

    public var id: String { rawValue }
}

public struct VolumeIconOptions: Equatable, Hashable, Sendable {
    public let displayStyle: VolumeDisplayStyle
    public let ringStrokeScale: Double

    /// Kept in step with the stroke-style default so tuning the enum cannot
    /// silently desynchronise `.standard`, the previews, and the icon guide.
    public static let defaultRingStrokeScale: Double = RingStrokeStyle.regular.scale

    public static let standard = VolumeIconOptions(displayStyle: .dots, ringStrokeScale: defaultRingStrokeScale)

    /// Scale applied to the discrete dots' radius.
    ///
    /// The four dots sit at fixed positions on the volume arc, so their spacing
    /// cannot grow with the stroke setting. A full multiplier would close the
    /// gap between neighbouring dots (down to ~0.3 pt at 1.5x, i.e. under one
    /// pixel) and push the lowest dot against the canvas edge, so the radius
    /// follows the setting at half strength and keeps the dots readable as
    /// separate marks.
    public var dotRadiusScale: Double {
        1 + (ringStrokeScale - 1) * 0.5
    }

    public init(
        displayStyle: VolumeDisplayStyle = .dots,
        ringStrokeScale: Double = defaultRingStrokeScale
    ) {
        self.displayStyle = displayStyle
        self.ringStrokeScale = ringStrokeScale.isFinite ? min(2.5, max(0.5, ringStrokeScale)) : Self.defaultRingStrokeScale
    }
}
