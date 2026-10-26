// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Models/RingStrokeStyle.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import Foundation

/// Line thickness of the status ring, the continuous volume arc, and the
/// discrete volume dots.
///
/// The menu bar icon and the Dock icon are drawn by the same renderer, so this
/// value is carried through `BatteryIconOptions` and `VolumeIconOptions` and
/// applies to both surfaces rather than to the menu bar alone.
public enum RingStrokeStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The hairline thickness the app shipped with before this option existed.
    case light
    case regular
    case bold

    public var id: String { rawValue }

    /// Stroke multiplier applied to the battery ring and the volume arc.
    public var scale: Double {
        switch self {
        case .light: return 1.0
        case .regular: return 1.25
        case .bold: return 1.5
        }
    }

    /// Decoding also accepts descriptive synonyms, so a hand-edited defaults
    /// value or a later rename resolves to a usable style instead of silently
    /// falling back to the default.
    public init?(rawValue: String) {
        switch rawValue {
        case "light", "standard": self = .light
        case "regular", "normal": self = .regular
        case "bold", "heavy": self = .bold
        default: return nil
        }
    }
}
