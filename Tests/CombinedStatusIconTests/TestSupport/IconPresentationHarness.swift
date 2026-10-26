// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/TestSupport/IconPresentationHarness.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon; dropped what tests the Dock icon, the settings preview, the localization tables or the settings store, which this app does not include.

@testable import CombinedStatusIcon

@MainActor
final class TestTaskIconPresentationScheduler: IconPresentationScheduling {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class ManualIconPresentationScheduler: IconPresentationScheduling {
    private(set) var scheduledDelays: [Duration] = []
    private var action: (@MainActor () -> Void)?
    var hasPendingAction: Bool { action != nil }

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
        scheduledDelays.append(delay)
        self.action = action
    }

    func cancel() {
        action = nil
    }

    func runScheduled() {
        let scheduledAction = action
        action = nil
        scheduledAction?()
    }
}

@MainActor
func makeIconPresentationScene(
    status: MenuBarStatus,
    battery: BatteryIconOptions = .standard,
    connection: ConnectionIconOptions = .standard,
    volume: VolumeIconOptions = .standard,
    bluetooth: BluetoothAudioIconOptions = .standard
) -> IconSceneState {
    let snapshot = StatusSnapshot(
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
    return IconPresentationMapper.scene(
        inputs: IconPresentationInputs(snapshot: snapshot, audioIcon: nil),
        configuration: IconPresentationConfiguration(
            battery: battery,
            connection: connection,
            volume: volume,
            bluetooth: bluetooth
        )
    )
}
