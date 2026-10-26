// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/TestSupport/SheetFixtures.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import Foundation
@testable import CombinedStatusIcon

/// Example values shared by the generated sheets, so the menu bar sheet and the
/// Dock sheet document the same hardware.
enum SheetFixtures {
    static let bluetoothDeviceName = "AirPods Pro"

    /// `StatusIconRenderer` and `DockIconRenderer` resolve the glyph from the
    /// device, so every sheet shows the symbol the app draws for this output.
    static var bluetoothDevice: AudioOutputDevice {
        AudioOutputDevice(
            id: 42,
            name: bluetoothDeviceName,
            uid: "sheet-bluetooth-output",
            isCurrent: true,
            volume: 0.6,
            transport: .bluetooth
        )
    }
}
