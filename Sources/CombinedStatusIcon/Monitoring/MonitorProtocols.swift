// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Monitoring/MonitorProtocols.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): the Wi-Fi
// and network-connection protocols only.

import Foundation

@MainActor
protocol WiFiMonitoring: AnyObject {
    var updates: AsyncStream<WiFiStatus> { get }
    func start()
    func stop()
    func refresh()
    func recover()
    @discardableResult
    func requestNameAccess() -> WiFiNameAccessRequestResult
    func setDetailsVisible(_ visible: Bool)
}

@MainActor
extension WiFiMonitoring {
    func setDetailsVisible(_ visible: Bool) {}
}

@MainActor
protocol NetworkConnectionMonitoring: AnyObject {
    var updates: AsyncStream<NetworkPathSnapshot> { get }
    func start()
    func stop()
    func recover()
}
