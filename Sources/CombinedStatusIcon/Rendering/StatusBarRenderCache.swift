// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/UI/Icon/StatusBarRenderCache.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

struct StatusBarRenderKey: Equatable {
    let scene: IconSceneState
    let iconSize: Double
    let backingScale: Double
    let appearanceName: String
    let phase: ChargingEffectPhase?
}

struct StatusBarRenderCache {
    private(set) var successfulKey: StatusBarRenderKey?

    func needsRender(_ key: StatusBarRenderKey) -> Bool {
        key != successfulKey
    }

    mutating func recordSuccessfulRender(_ key: StatusBarRenderKey) {
        successfulKey = key
    }

    mutating func reset() {
        successfulKey = nil
    }
}
