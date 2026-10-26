// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Monitoring/WiFiNameAuthorizer.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): the
// protocol and the request result only; the Core Location authorizer is
// replaced by UnavailableWiFiNameAuthorizer.

import Foundation

enum WiFiNameAccessRequestResult: Equatable, Sendable {
    case requested
    case openLocationSettings
    case notNeeded
}

@MainActor
protocol WiFiNameAuthorizing: AnyObject {
    var access: WiFiNameAccess { get }
    var onAccessChange: (() -> Void)? { get set }

    @discardableResult
    func requestAccess() -> WiFiNameAccessRequestResult
}

/// The status icon draws the signal, never the network name, so the monitor
/// reads no SSID and never asks for Location access.
@MainActor
final class UnavailableWiFiNameAuthorizer: WiFiNameAuthorizing {
    let access: WiFiNameAccess = .notDetermined
    var onAccessChange: (() -> Void)?

    func requestAccess() -> WiFiNameAccessRequestResult { .notNeeded }
}
