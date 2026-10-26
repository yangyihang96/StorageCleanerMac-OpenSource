// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/TestSupport/IconRenderFixtures.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon; dropped what tests the Dock icon, the settings preview, the localization tables or the settings store, which this app does not include.

import AppKit
import CoreGraphics
@testable import CombinedStatusIcon

/// Domain fixtures for raster tests that assert independent geometry or color
/// conventions. Product mapping is still exercised through the canonical mapper;
/// these helpers contain no selection or drawing rules.
@MainActor
func renderMenuBarFixture(
    snapshot: StatusSnapshot,
    size: CGFloat,
    scale: CGFloat,
    foreground: CGColor,
    criticalColor: CGColor? = nil,
    options: BatteryIconOptions = .standard,
    connectionOptions: ConnectionIconOptions = .standard,
    volumeOptions: VolumeIconOptions = .standard,
    bluetoothAudioOptions: BluetoothAudioIconOptions = .standard,
    inputs: IconPresentationInputs? = nil,
    phase: ChargingEffectPhase? = nil
) -> CGImage? {
    let configuration = IconPresentationConfiguration(
        battery: options,
        connection: connectionOptions,
        volume: volumeOptions,
        bluetooth: bluetoothAudioOptions
    )
    let resolvedInputs = inputs ?? IconPresentationResourceResolver.inputs(snapshot: snapshot)
    let scene = IconPresentationMapper.scene(inputs: resolvedInputs, configuration: configuration)
    return StatusIconRenderer.render(
        scene: scene,
        environment: StatusIconRenderEnvironment(
            size: size,
            scale: scale,
            foreground: foreground,
            criticalColor: criticalColor ?? StatusIconRenderer.defaultCriticalColor
        ),
        phase: phase
    )
}

@MainActor
func renderMenuBarFixture(
    menuBarStatus: MenuBarStatus,
    size: CGFloat,
    scale: CGFloat,
    foreground: CGColor,
    criticalColor: CGColor? = nil,
    options: BatteryIconOptions = .standard,
    connectionOptions: ConnectionIconOptions = .standard,
    volumeOptions: VolumeIconOptions = .standard,
    bluetoothAudioOptions: BluetoothAudioIconOptions = .standard,
    inputs: IconPresentationInputs? = nil,
    phase: ChargingEffectPhase? = nil
) -> CGImage? {
    renderMenuBarFixture(
        snapshot: snapshotFromMenuBarStatus(menuBarStatus),
        size: size,
        scale: scale,
        foreground: foreground,
        criticalColor: criticalColor,
        options: options,
        connectionOptions: connectionOptions,
        volumeOptions: volumeOptions,
        bluetoothAudioOptions: bluetoothAudioOptions,
        inputs: inputs,
        phase: phase
    )
}

@MainActor
func menuBarFixtureImage(
    menuBarStatus: MenuBarStatus,
    size: CGFloat,
    scale: CGFloat = 2,
    appearance: NSAppearance? = nil,
    options: BatteryIconOptions = .standard,
    connectionOptions: ConnectionIconOptions = .standard,
    volumeOptions: VolumeIconOptions = .standard,
    bluetoothAudioOptions: BluetoothAudioIconOptions = .standard,
    phase: ChargingEffectPhase? = nil
) -> NSImage {
    guard let image = StatusIconRenderer.image(
        scene: IconPresentationMapper.scene(
            inputs: IconPresentationResourceResolver.inputs(snapshot: snapshotFromMenuBarStatus(menuBarStatus)),
            configuration: IconPresentationConfiguration(
                battery: options,
                connection: connectionOptions,
                volume: volumeOptions,
                bluetooth: bluetoothAudioOptions
            )
        ),
        size: size,
        scale: scale,
        appearance: appearance,
        phase: phase
    ) else {
        fatalError("The icon fixture must produce a supported scene.")
    }
    return image
}

@MainActor
func menuBarFixtureImage(
    snapshot: StatusSnapshot,
    size: CGFloat,
    scale: CGFloat = 2,
    appearance: NSAppearance? = nil,
    options: BatteryIconOptions = .standard,
    connectionOptions: ConnectionIconOptions = .standard,
    volumeOptions: VolumeIconOptions = .standard,
    bluetoothAudioOptions: BluetoothAudioIconOptions = .standard,
    phase: ChargingEffectPhase? = nil
) -> NSImage {
    guard let image = StatusIconRenderer.image(
        scene: IconPresentationMapper.scene(
            inputs: IconPresentationResourceResolver.inputs(snapshot: snapshot),
            configuration: IconPresentationConfiguration(
                battery: options,
                connection: connectionOptions,
                volume: volumeOptions,
                bluetooth: bluetoothAudioOptions
            )
        ),
        size: size,
        scale: scale,
        appearance: appearance,
        phase: phase
    ) else {
        fatalError("The icon fixture must produce a supported scene.")
    }
    return image
}

private func snapshotFromMenuBarStatus(_ status: MenuBarStatus) -> StatusSnapshot {
    StatusSnapshot(
        battery: status.battery,
        wifi: status.wifi,
        connection: status.connection,
        volume: VolumeStatus(
            scalar: status.volume.scalar,
            isMuted: status.volume.isMuted,
            deviceName: status.volume.deviceName,
            currentDevice: status.volume.currentDevice
        )
    )
}

