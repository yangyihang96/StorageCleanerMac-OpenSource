// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Models/WiFiFrequencyBand.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): made public what the app reads.

import CoreWLAN

/// Known bands only; unknown or unavailable channels remain nil.
public enum WiFiFrequencyBand: Equatable, Sendable {
    case twoPointFourGHz, fiveGHz, sixGHz

    public init?(coreWLANBand: CWChannelBand) {
        switch coreWLANBand {
        case .band2GHz: self = .twoPointFourGHz
        case .band5GHz: self = .fiveGHz
        case .band6GHz: self = .sixGHz
        default: return nil
        }
    }

    public var gigahertz: Double {
        switch self {
        case .twoPointFourGHz: 2.4
        case .fiveGHz: 5
        case .sixGHz: 6
        }
    }
}
