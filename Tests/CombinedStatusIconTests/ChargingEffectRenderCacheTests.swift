// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/ChargingEffectRenderCacheTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon; dropped what tests the Dock icon, the settings preview, the localization tables or the settings store, which this app does not include.

import Testing
@testable import CombinedStatusIcon

struct ChargingEffectRenderCacheTests {
    @Test func menuBarCacheInvalidatesForEachSteadyPhase() {
        var cache = StatusBarRenderCache()
        let first = menuBarKey(phase: .init(step: 2, stepsPerCycle: 36, kind: .steady))
        let second = menuBarKey(phase: .init(step: 3, stepsPerCycle: 36, kind: .steady))

        #expect(cache.needsRender(first))
        cache.recordSuccessfulRender(first)
        #expect(cache.needsRender(second))
        cache.recordSuccessfulRender(second)
        #expect(cache.needsRender(second) == false)
    }

    @Test func nilMenuBarPhasePreservesStaticKeyDeduplication() {
        var cache = StatusBarRenderCache()
        let omittedPhase = menuBarKey()
        let explicitNilPhase = menuBarKey(phase: nil)

        let rendersStaticKey = cache.needsRender(omittedPhase)
        cache.recordSuccessfulRender(omittedPhase)
        let suppressesDuplicateStaticKey = cache.needsRender(explicitNilPhase)
        #expect(omittedPhase == explicitNilPhase)
        #expect(rendersStaticKey)
        #expect(suppressesDuplicateStaticKey == false)
    }

    private func menuBarKey(phase: ChargingEffectPhase? = nil) -> StatusBarRenderKey {
        StatusBarRenderKey(
            scene: IconPresentationMapper.scene(
                inputs: IconPresentationInputs(snapshot: .placeholder, audioIcon: nil),
                configuration: .standard
            ),
            iconSize: 28,
            backingScale: 2,
            appearanceName: "darkAqua",
            phase: phase
        )
    }

}
