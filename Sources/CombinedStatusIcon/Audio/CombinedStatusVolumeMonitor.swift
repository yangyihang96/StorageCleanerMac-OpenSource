// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Monitoring/VolumeMonitor.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): the
// status icon's part of VolumeMonitor only. It keeps the listeners, the 150 ms
// refresh debounce, the single in-flight read with its watchdog and the cleared
// volume while the default output changes; it never lists the output devices,
// never sets the volume or the mute, and has no DDC path for external displays.

import Foundation

@MainActor
final class CombinedStatusVolumeMonitor {
    private enum Lifecycle {
        case idle
        case running
        case stopped
    }

    let updates: AsyncStream<VolumeStatus>

    private let continuation: AsyncStream<VolumeStatus>.Continuation
    private let statusReader: any AudioStatusReadingProviding
    private let eventMonitor: any VolumeEventMonitoring
    private let refreshDebounceInterval: Duration
    private let refreshDebounceSleep: @Sendable (Duration) async throws -> Void
    private var scheduledRefreshTask: Task<Void, Never>?
    private var readInFlight = false
    private var refreshPending = false
    private var readGeneration: UInt64 = 0
    private var readToken: UInt64 = 0
    private let readWatchdog: ReadWatchdog
    private var lifecycle = Lifecycle.idle
    private(set) var latestStatus = VolumeStatus.placeholder

    init(
        statusReader: any AudioStatusReadingProviding = CoreAudioStatusReader(),
        eventMonitor: any VolumeEventMonitoring = CoreAudioVolumeEventMonitor(),
        refreshDebounceInterval: Duration = .milliseconds(150),
        refreshDebounceSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        readTimeout: Duration = .seconds(5),
        readTimeoutSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.statusReader = statusReader
        self.eventMonitor = eventMonitor
        self.refreshDebounceInterval = refreshDebounceInterval
        self.refreshDebounceSleep = refreshDebounceSleep
        readWatchdog = ReadWatchdog(
            baseTimeout: readTimeout,
            maxTimeout: .seconds(60),
            sleep: readTimeoutSleep
        )
        (updates, continuation) = MonitorStream.make(of: VolumeStatus.self)
    }

    deinit {
        MainActor.assumeIsolated {
            scheduledRefreshTask?.cancel()
            if lifecycle != .stopped {
                eventMonitor.stop()
            }
        }
        continuation.finish()
    }

    func start() {
        guard lifecycle == .idle else { return }
        lifecycle = .running
        eventMonitor.start(
            onDefaultDeviceChange: { [weak self] in
                self?.clearVolumeForDeviceTransition()
                self?.scheduleRefresh()
            },
            onVolumeChange: { [weak self] in
                self?.scheduleRefresh()
            }
        )
        refresh()
    }

    func stop() {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        readWatchdog.cancel()
        eventMonitor.stop()
        continuation.finish()
    }

    func recover() {
        guard lifecycle == .running else { return }
        readGeneration &+= 1
        eventMonitor.recover()
        refresh()
    }

    func refresh() {
        performRefresh()
    }

    private func scheduleRefresh() {
        guard lifecycle == .running else { return }
        // A queued result may predate an event.
        readGeneration &+= 1
        guard scheduledRefreshTask == nil else { return }
        let interval = refreshDebounceInterval
        let sleep = refreshDebounceSleep
        scheduledRefreshTask = Task { @MainActor [weak self] in
            do {
                try await sleep(interval)
            } catch {
                self?.scheduledRefreshTask = nil
                return
            }
            guard !Task.isCancelled, let self, self.lifecycle == .running else {
                self?.scheduledRefreshTask = nil
                return
            }
            self.scheduledRefreshTask = nil
            self.performRefresh()
        }
    }

    private func performRefresh() {
        guard lifecycle != .stopped else { return }
        guard !readInFlight else {
            refreshPending = true
            return
        }
        eventMonitor.reconcile()
        readInFlight = true
        readToken &+= 1
        let token = readToken
        let generation = readGeneration
        readWatchdog.arm { [weak self] in
            self?.abandonTimedOutRead(token: token)
        }
        statusReader.read(includeOutputDevices: false) { [weak self] result in
            // A completion that arrives after the read was declared stuck must not
            // release the latch of the read that replaced it.
            guard let self, token == self.readToken else { return }
            self.readWatchdog.cancel()
            guard self.lifecycle != .stopped else { return }
            self.readWatchdog.recordSuccess()
            self.readInFlight = false
            let needsRefresh = self.refreshPending || generation != self.readGeneration
            self.refreshPending = false
            if generation == self.readGeneration {
                self.receive(result)
            }
            if needsRefresh, self.scheduledRefreshTask == nil {
                self.performRefresh()
            }
        }
    }

    /// A system read never returned. Ignore its late completion, release the
    /// single-read latch and try again; the reader moves the retry to a fresh
    /// queue.
    private func abandonTimedOutRead(token: UInt64) {
        guard token == readToken else { return }
        readToken &+= 1
        readInFlight = false
        readGeneration &+= 1
        refresh()
    }

    private func receive(_ result: AudioStatusReading) {
        if let reading = result.volume {
            latestStatus = VolumeStatus(
                scalar: reading.scalar,
                isMuted: reading.isMuted,
                deviceName: reading.deviceName,
                currentDevice: reading.currentDevice,
                canSetVolume: reading.canSetVolume,
                canMute: reading.canMute
            )
        } else {
            latestStatus = .placeholder
        }
        continuation.yield(latestStatus)
    }

    private func clearVolumeForDeviceTransition() {
        guard latestStatus.scalar != nil || latestStatus.currentDevice != nil else { return }
        latestStatus = VolumeStatus(
            scalar: nil, isMuted: false, deviceName: nil, canSetVolume: false, canMute: false
        )
        continuation.yield(latestStatus)
    }
}
