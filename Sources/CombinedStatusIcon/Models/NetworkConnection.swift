// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Models/NetworkConnection.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): made public what the app reads.

public enum NetworkConnection: Equatable, Sendable {
    case wifi
    case ethernet
    case other
    case offline
    case unknown

    public static func resolve(connected: Bool, wired: Bool, wireless: Bool) -> NetworkConnection {
        guard connected else { return .offline }
        if wired { return .ethernet }
        if wireless { return .wifi }
        return .other
    }
}
