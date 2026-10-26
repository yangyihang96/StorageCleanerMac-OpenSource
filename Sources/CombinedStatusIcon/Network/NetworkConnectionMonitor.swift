// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Monitoring/NetworkConnectionMonitor.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): renamed the queue.

import Foundation
import Network

struct NetworkPathSnapshot: Equatable, Sendable {
    let connected: Bool
    let wired: Bool
    let wireless: Bool
    /// `NWPath.isConstrained`: the system has marked this path as
    /// bandwidth-restricted — Low Data Mode, and some tethered links. It
    /// describes the path rather than the interface carrying it, so it sits
    /// beside `connection` instead of being folded into it, and the popover
    /// reads it only for the row it is describing.
    let constrained: Bool

    init(
        connected: Bool,
        wired: Bool,
        wireless: Bool,
        constrained: Bool = false
    ) {
        self.connected = connected
        self.wired = wired
        self.wireless = wireless
        self.constrained = constrained
    }

    var connection: NetworkConnection {
        NetworkConnection.resolve(
            connected: connected,
            wired: wired,
            wireless: wireless
        )
    }
}

protocol NetworkPathMonitoring: AnyObject {
    func start(
        queue: DispatchQueue,
        handler: @escaping (NetworkPathSnapshot) -> Void
    )
    func cancel()
}

final class NWPathConnectionMonitor: @unchecked Sendable, NetworkPathMonitoring {
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var handler: ((NetworkPathSnapshot) -> Void)?

    func start(
        queue: DispatchQueue,
        handler: @escaping (NetworkPathSnapshot) -> Void
    ) {
        let monitor = NWPathMonitor()
        lock.withLock {
            self.monitor = monitor
            self.handler = handler
        }
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard
                let self,
                let monitor,
                self.lock.withLock({ self.monitor === monitor })
            else { return }

            let snapshot = NetworkPathSnapshot(
                connected: path.status == .satisfied,
                wired: path.usesInterfaceType(.wiredEthernet),
                wireless: path.usesInterfaceType(.wifi),
                constrained: path.isConstrained
            )
            let handler = self.lock.withLock { self.handler }
            handler?(snapshot)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        let monitor = lock.withLock { () -> NWPathMonitor? in
            let monitor = self.monitor
            self.monitor = nil
            handler = nil
            return monitor
        }
        monitor?.cancel()
    }
}

@MainActor
final class NetworkConnectionMonitor: NetworkConnectionMonitoring {
    private enum Lifecycle {
        case idle
        case running
        case stopped
    }

    let updates: AsyncStream<NetworkPathSnapshot>

    nonisolated(unsafe) private let pathMonitor: any NetworkPathMonitoring
    private let queue = DispatchQueue(label: "StorageCleanerMac.CombinedStatusIcon.NetworkConnection")
    private let continuation: AsyncStream<NetworkPathSnapshot>.Continuation
    private var lifecycle = Lifecycle.idle

    init(pathMonitor: any NetworkPathMonitoring = NWPathConnectionMonitor()) {
        self.pathMonitor = pathMonitor
        (updates, continuation) = MonitorStream.make(of: NetworkPathSnapshot.self)
    }

    deinit {
        if lifecycle != .stopped {
            pathMonitor.cancel()
            continuation.finish()
        }
    }

    func start() {
        guard lifecycle == .idle else { return }
        lifecycle = .running
        startPathMonitoring()
    }

    func recover() {
        guard lifecycle == .running else { return }
        pathMonitor.cancel()
        startPathMonitoring()
    }

    func stop() {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        pathMonitor.cancel()
        continuation.finish()
    }

    private func startPathMonitoring() {
        pathMonitor.start(queue: queue) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle == .running else { return }
                self.continuation.yield(snapshot)
            }
        }
    }
}
