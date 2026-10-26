// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Models/WiFiNetworkModels.swift (lines 327-336)
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): BluetoothHexIdentifier only (lines 327-336), which the AirPods model lookup needs; added the Foundation import.

import Foundation

enum BluetoothHexIdentifier {
    static func value(from text: String?) -> Int? {
        var digits = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if digits.hasPrefix("0x") {
            digits.removeFirst(2)
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }
        return Int(digits, radix: 16)
    }
}
