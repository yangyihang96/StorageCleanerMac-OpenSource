import AppKit
import Darwin
import Foundation

protocol BenchmarkV7Preflighting: Sendable {
    func capture(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL
    ) async -> BenchmarkV7PreflightReport
}

struct BenchmarkV7PreflightService: BenchmarkV7Preflighting, Sendable {
    static let highBackgroundLoadRatio = 0.75
    /// BOARD N22: the share of all CPU time busy in the background over the
    /// preflight's one-second window above which results may read low.
    static let highBackgroundCPUBusyRatio = 0.25
    static let minimumAvailableMemoryBytes: UInt64 = 1 * 1_024 * 1_024 * 1_024

    /// Cumulative CPU ticks of all processors: busy (user, system, nice) and total.
    typealias CPUTicks = (busy: UInt64, total: UInt64)

    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let loadAverageRatio: @Sendable () -> Double?
    private let cpuTicks: @Sendable () -> CPUTicks?
    private let processCPUSeconds: @Sendable () -> TimeInterval?

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        loadAverageRatio: @escaping @Sendable () -> Double? = BenchmarkV7PreflightService.systemLoadAverageRatio,
        cpuTicks: @escaping @Sendable () -> CPUTicks? = BenchmarkV7PreflightService.systemCPUTicks,
        processCPUSeconds: @escaping @Sendable () -> TimeInterval? = BenchmarkV7PreflightService.ownProcessCPUSeconds
    ) {
        self.now = now
        self.sleep = sleep
        self.loadAverageRatio = loadAverageRatio
        self.cpuTicks = cpuTicks
        self.processCPUSeconds = processCPUSeconds
    }

    /// The host CPU tick counters' rate (`_SC_CLK_TCK`, 100 on macOS).
    static let ticksPerSecond: Double = {
        let ticks = sysconf(Int32(_SC_CLK_TCK))
        return ticks > 0 ? Double(ticks) : 100
    }()

    /// Half a second of every active processor's ticks.
    static var minimumWindowTicks: UInt64 {
        UInt64(Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) * ticksPerSecond / 2)
    }

    /// This process's CPU time, user and system over all its threads.
    static let ownProcessCPUSeconds: @Sendable () -> TimeInterval? = {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ time: timeval) -> TimeInterval {
            TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000
        }
        let total = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        return total.isFinite && total >= 0 ? total : nil
    }

    /// The busy share of all CPU time between two tick readings, less this
    /// process's own CPU time over the same window (review P2-10: the app's
    /// interface, monitors and the preflight itself are not background load).
    /// The host's counters advance about once a second for all processors
    /// (in between only the reading processor's own ticks); a window that
    /// counted less than half a second of every processor's ticks gives no
    /// share.
    static func busyRatio(
        from start: CPUTicks?,
        to end: CPUTicks?,
        ownCPUSeconds: TimeInterval? = nil,
        minimumTotalTicks: UInt64 = minimumWindowTicks
    ) -> Double? {
        guard let start, let end, end.total > start.total, end.busy >= start.busy,
              end.total - start.total >= minimumTotalTicks else { return nil }
        let own = ownCPUSeconds.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        let busy = max(0, Double(end.busy - start.busy) - own * ticksPerSecond)
        let ratio = busy / Double(end.total - start.total)
        return ratio.isFinite ? min(1, max(0, ratio)) : nil
    }

    static let systemCPUTicks: @Sendable () -> CPUTicks? = {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    static let systemLoadAverageRatio: @Sendable () -> Double? = {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, Int32(values.count)) > 0 else { return nil }
        let processors = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let ratio = values[0] / Double(processors)
        return ratio.isFinite && ratio >= 0 ? ratio : nil
    }

    func capture(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL
    ) async -> BenchmarkV7PreflightReport {
        let target = storageTarget(at: targetDirectory)
        let power = currentPowerReading()
        let lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermalState = currentThermalState()
        let firstLoad = loadAverageRatio()
        let firstTicks = cpuTicks()
        let firstOwnSeconds = processCPUSeconds()
        let memorySnapshot = await SystemMemoryProbe.shared.snapshot(includeProcesses: false)
        let availableMemoryBytes = memorySnapshot.measurements.availableBytes.value
        let display = await MainActor.run { displayDescription() }
        let secondLoad: Double?
        let secondTicks: CPUTicks?
        let secondOwnSeconds: TimeInterval?
        do {
            try await sleep(.seconds(1))
            secondLoad = loadAverageRatio()
            secondTicks = cpuTicks()
            secondOwnSeconds = processCPUSeconds()
        } catch {
            secondLoad = nil
            secondTicks = nil
            secondOwnSeconds = nil
        }
        let backgroundLoad = [firstLoad, secondLoad].compactMap { $0 }.max()
        let ownSeconds = firstOwnSeconds.flatMap { first in secondOwnSeconds.map { $0 - first } }
        let backgroundCPUBusy = Self.busyRatio(from: firstTicks, to: secondTicks, ownCPUSeconds: ownSeconds)

        var checks: [BenchmarkV7PreflightCheck] = []
        var blocked = Set<BenchmarkV7Category>()
        if power.source != .acPower {
            checks.append(check(.acPowerRecommended, .warning, "External power is recommended."))
        }
        if lowPowerModeEnabled {
            checks.append(check(.lowPowerMode, .warning, "Low Power Mode is enabled."))
        }
        switch thermalState {
        case .critical:
            checks.append(check(.thermalCritical, .blocked, "The system reports critical thermal pressure."))
            blocked.formUnion(categories)
        case .serious:
            checks.append(check(.thermalSerious, .blocked, "The system reports serious thermal pressure."))
            blocked.formUnion(categories)
        case .fair:
            checks.append(check(.thermalFair, .warning, "The system is warmer than nominal."))
        case .nominal, .unknown:
            break
        }
        // BOARD N22: the load average lags and needs a whole machine's worth
        // of runnable threads; the busy share of the last second catches a
        // build or a sync already using a quarter of the CPU. Either one is
        // a warning ("后台负载高，结果可能偏低"); neither blocks the test.
        let loadIsHigh = backgroundLoad.map { $0.isFinite && $0 >= Self.highBackgroundLoadRatio } ?? false
        let busyIsHigh = backgroundCPUBusy.map { $0 >= Self.highBackgroundCPUBusyRatio } ?? false
        if loadIsHigh || busyIsHigh {
            var observations: [String] = []
            if let backgroundCPUBusy {
                observations.append(
                    "background CPU use (other than this app) is \(Int((backgroundCPUBusy * 100).rounded()))% of all processors"
                )
            }
            if let backgroundLoad {
                observations.append("the 1-minute load is \(Int((backgroundLoad * 100).rounded()))% of active processors")
            }
            checks.append(check(
                .highBackgroundLoad,
                .warning,
                "Observed " + observations.joined(separator: "; ") + "."
            ))
        }
        if let availableMemoryBytes,
           availableMemoryBytes < Self.minimumAvailableMemoryBytes {
            checks.append(check(.lowAvailableMemory, .warning, "Available memory is below 1 GiB."))
        }
        if categories.contains(.storage) {
            if target.isReadOnly {
                checks.append(check(.targetVolumeReadOnly, .blocked, "The selected volume is read-only."))
                blocked.insert(.storage)
            }
            if target.availableBytes < requiredStorageBytes(for: plan) {
                checks.append(check(.storageSpaceInsufficient, .blocked, "The selected volume lacks benchmark workspace capacity."))
                blocked.insert(.storage)
            }
        }
        if display == nil, categories.contains(.display) {
            checks.append(check(.displayUnavailable, .warning, "A reliable current display description is unavailable."))
        }

        return BenchmarkV7PreflightReport(
            capturedAt: now(),
            powerSource: power.source,
            batteryPercent: power.batteryPercent,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            backgroundLoadRatio: backgroundLoad,
            availableMemoryBytes: availableMemoryBytes,
            storageTarget: target,
            displayDescription: display,
            checks: checks,
            blockedCategories: blocked.sorted { $0.rawValue < $1.rawValue },
            backgroundCPUBusyRatio: backgroundCPUBusy
        )
    }

    private func check(
        _ issue: BenchmarkV7PreflightIssue,
        _ severity: BenchmarkV7PreflightSeverity,
        _ detail: String
    ) -> BenchmarkV7PreflightCheck {
        BenchmarkV7PreflightCheck(issue: issue, severity: severity, detail: detail)
    }

    private func storageTarget(at targetDirectory: URL) -> BenchmarkV7StorageTarget {
        let fileManager = FileManager.default
        var probe = targetDirectory.standardizedFileURL
        while !fileManager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent != probe else { break }
            probe = parent
        }

        let values = try? probe.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsReadOnlyKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? (try? fileManager.attributesOfFileSystem(forPath: probe.path)[.systemFreeSize]
                as? NSNumber)?.int64Value
            ?? 0
        return BenchmarkV7StorageTarget(
            volumeName: values?.volumeName ?? "Storage volume",
            fileSystem: values?.volumeLocalizedFormatDescription,
            availableBytes: max(0, available),
            isReadOnly: values?.volumeIsReadOnly ?? false
        )
    }

    private func currentPowerReading() -> BenchmarkPowerReading {
        let snapshot = BatteryPowerService.internalBatterySnapshot()
        let source: BenchmarkPowerSource
        switch BatteryPowerService.currentSystemPowerSource() {
        case .acPower: source = .acPower
        case .batteryPower: source = .battery
        case .unknown: source = .unknown
        }
        return (source, snapshot?.chargePercent.map(Double.init))
    }

    private func currentThermalState() -> BenchmarkThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }

    @MainActor
    private func displayDescription() -> String? {
        guard let screen = NSScreen.main else { return nil }
        let mode = screen.deviceDescription[NSDeviceDescriptionKey("NSDeviceResolution")]
        let size = screen.frame.size
        return "\(screen.localizedName) · \(Int(size.width))×\(Int(size.height)) · \(String(describing: mode ?? ""))"
    }

    private func requiredStorageBytes(for plan: BenchmarkV7Plan) -> Int64 {
        switch plan.kind {
        case .quick: 3 * 1_024 * 1_024 * 1_024
        case .standard: 8 * 1_024 * 1_024 * 1_024
        case .sustained: 3 * 1_024 * 1_024 * 1_024
        case .custom: 3 * 1_024 * 1_024 * 1_024
        }
    }
}
