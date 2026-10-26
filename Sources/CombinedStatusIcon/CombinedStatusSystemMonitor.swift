// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Store/SystemStatusStore.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): the
// status the icon draws only. The app supplies the battery from its own
// power-source reading; Wi-Fi, the network path and the current output's
// volume come from the ported monitors; a wake recovers them, and the
// display's sleep is tracked for the charging effect. No VPN, input,
// Bluetooth or popover state.

import AppKit
import Combine

@MainActor
public final class CombinedStatusSystemMonitor: ObservableObject {
    @Published public private(set) var snapshot: StatusSnapshot
    @Published public private(set) var isDisplayAsleep = false

    private let makeWiFiMonitor: @MainActor () -> any WiFiMonitoring
    private let makeConnectionMonitor: @MainActor () -> any NetworkConnectionMonitoring
    private let makeVolumeMonitor: @MainActor () -> CombinedStatusVolumeMonitor
    private let notificationCenter: NotificationCenter
    private var wifiMonitor: (any WiFiMonitoring)?
    private var connectionMonitor: (any NetworkConnectionMonitoring)?
    private var volumeMonitor: CombinedStatusVolumeMonitor?
    private var tasks: [Task<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []

    public var isRunning: Bool { wifiMonitor != nil }

    public convenience init(battery: BatteryStatus = .placeholder) {
        self.init(
            battery: battery,
            makeWiFiMonitor: { Self.iconWiFiMonitor() },
            makeConnectionMonitor: { NetworkConnectionMonitor() },
            makeVolumeMonitor: { CombinedStatusVolumeMonitor() }
        )
    }

    init(
        battery: BatteryStatus,
        makeWiFiMonitor: @escaping @MainActor () -> any WiFiMonitoring,
        makeConnectionMonitor: @escaping @MainActor () -> any NetworkConnectionMonitoring,
        makeVolumeMonitor: @escaping @MainActor () -> CombinedStatusVolumeMonitor,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        snapshot = StatusSnapshot(battery: battery, wifi: .placeholder, volume: .placeholder)
        self.makeWiFiMonitor = makeWiFiMonitor
        self.makeConnectionMonitor = makeConnectionMonitor
        self.makeVolumeMonitor = makeVolumeMonitor
        self.notificationCenter = notificationCenter
    }

    /// The icon needs no network name or band: no Location request and no
    /// SSID read, as the popover's details stay hidden.
    static func iconWiFiMonitor(_ monitor: WiFiMonitor = WiFiMonitor()) -> WiFiMonitor {
        monitor.setDetailsVisible(false)
        return monitor
    }

    /// Starts fresh monitors: a stopped upstream monitor finishes its stream,
    /// so a later start never reuses one.
    public func start() {
        guard wifiMonitor == nil else { return }
        let wifi = makeWiFiMonitor()
        let connection = makeConnectionMonitor()
        let volume = makeVolumeMonitor()
        wifiMonitor = wifi
        connectionMonitor = connection
        volumeMonitor = volume

        tasks.append(Task { @MainActor [weak self] in
            for await status in wifi.updates {
                self?.replace(wifi: status)
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            for await path in connection.updates {
                self?.replace(connection: path.connection)
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            for await status in volume.updates {
                self?.replace(volume: status)
            }
        })
        observe(NSWorkspace.didWakeNotification) { monitor in
            monitor.isDisplayAsleep = false
            monitor.recover()
        }
        observe(NSWorkspace.screensDidSleepNotification) { $0.isDisplayAsleep = true }
        observe(NSWorkspace.screensDidWakeNotification) { $0.isDisplayAsleep = false }

        wifi.start()
        connection.start()
        volume.start()
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        wifiMonitor?.stop()
        connectionMonitor?.stop()
        volumeMonitor?.stop()
        wifiMonitor = nil
        connectionMonitor = nil
        volumeMonitor = nil
        isDisplayAsleep = false
    }

    public func recover() {
        wifiMonitor?.recover()
        connectionMonitor?.recover()
        volumeMonitor?.recover()
    }

    public func updateBattery(_ battery: BatteryStatus) {
        guard battery != snapshot.battery else { return }
        snapshot = StatusSnapshot(battery: battery, wifi: snapshot.wifi,
                                  connection: snapshot.connection, volume: snapshot.volume)
    }

    private func replace(wifi: WiFiStatus) {
        guard wifi != snapshot.wifi else { return }
        snapshot = StatusSnapshot(battery: snapshot.battery, wifi: wifi,
                                  connection: snapshot.connection, volume: snapshot.volume)
    }

    private func replace(connection: NetworkConnection) {
        guard connection != snapshot.connection else { return }
        snapshot = StatusSnapshot(battery: snapshot.battery, wifi: snapshot.wifi,
                                  connection: connection, volume: snapshot.volume)
    }

    private func replace(volume: VolumeStatus) {
        guard volume != snapshot.volume else { return }
        snapshot = StatusSnapshot(battery: snapshot.battery, wifi: snapshot.wifi,
                                  connection: snapshot.connection, volume: volume)
    }

    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (CombinedStatusSystemMonitor) -> Void) {
        observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        })
    }
}
