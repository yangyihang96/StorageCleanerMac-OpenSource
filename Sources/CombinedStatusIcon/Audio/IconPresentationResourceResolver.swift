// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/App/IconPresentationResourceResolver.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import AppKit
import Foundation

@MainActor
enum IconPresentationResourceResolver {
    static let availableBluetoothAudioIconChoices = BluetoothAudioIconChoice.availableChoices(
        isSymbolAvailable: { symbol in
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        }
    )

    static func inputs(
        snapshot: StatusSnapshot,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isSymbolAvailable: (String) -> Bool = { symbol in
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        }
    ) -> IconPresentationInputs {
        guard let device = snapshot.volume.currentDevice else {
            return IconPresentationInputs(snapshot: snapshot, audioIcon: nil)
        }

        let source: IconSymbolSource
        if let iconURL = device.iconURL, fileExists(iconURL) {
            source = .image(url: iconURL, fallbackSymbol: "headphones")
        } else {
            let kind = AudioOutputDeviceIcon.kind(for: device)
            let host = HostMacKind(deviceName: device.name)
            let symbol = AudioOutputDeviceIcon.symbolName(for: kind, host: host, isSymbolAvailable: isSymbolAvailable)
            source = .symbol(name: symbol, variableValue: nil, fallback: "headphones")
        }
        return IconPresentationInputs(snapshot: snapshot, audioIcon: source)
    }
}
