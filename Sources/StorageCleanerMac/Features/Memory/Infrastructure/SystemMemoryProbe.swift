import AppKit
import Darwin
import Foundation

protocol MemoryProbing: Sendable {
    func snapshot(includeProcesses: Bool) async -> MemorySnapshot
}

actor MemoryHistoryStore {
    private struct CounterSample: Sendable {
        let instant: ContinuousClock.Instant
        let pageIns: UInt64
        let pageOuts: UInt64
        let pageSize: UInt64
    }

    private var previous: CounterSample?

    func rates(
        instant: ContinuousClock.Instant,
        pageIns: UInt64,
        pageOuts: UInt64,
        pageSize: UInt64
    ) -> (swapIn: Double?, swapOut: Double?) {
        let current = CounterSample(
            instant: instant,
            pageIns: pageIns,
            pageOuts: pageOuts,
            pageSize: pageSize
        )
        defer { previous = current }
        guard let previous,
              pageIns >= previous.pageIns,
              pageOuts >= previous.pageOuts else {
            return (nil, nil)
        }

        let duration = previous.instant.duration(to: instant)
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds > 0 else { return (nil, nil) }

        func rate(_ delta: UInt64) -> Double? {
            let value = Double(delta) * Double(pageSize) / seconds
            return value.isFinite && value >= 0 ? value : nil
        }

        return (
            rate(pageIns - previous.pageIns),
            rate(pageOuts - previous.pageOuts)
        )
    }
}

actor SystemMemoryProbe: MemoryProbing {
    static let shared = SystemMemoryProbe()

    private struct PageReadings: Sendable {
        let pageSize: UInt64
        let values: [String: UInt64]
    }

    private struct SwapReadings: Sendable {
        let used: UInt64
        let total: UInt64
    }

    struct RunningAppIdentity: Sendable {
        let name: String?
        let bundleIdentifier: String?
        let bundlePath: String?
        let executablePath: String?
        let launchDate: Date?
        let activationPolicy: MemoryRunningApplicationActivationPolicy
        let isActive: Bool
        var processStartTime: UInt64? = nil
    }

    struct ProcessUsage: Sendable {
        let footprintBytes: UInt64
        let birth: UInt64
    }

    struct ProcessIdentity: Sendable {
        let startTime: UInt64
        let userIdentifier: UInt32

        var launchDate: Date { Date(timeIntervalSince1970: Double(startTime) / 1_000_000) }
    }

    private let history: MemoryHistoryStore
    private let clock = ContinuousClock()
    private let systemPressureLevelCode: @Sendable () -> Int32?
    private let processCache: ProcessSamplingCache

    init(
        history: MemoryHistoryStore = MemoryHistoryStore(),
        systemPressureLevelCode: @escaping @Sendable () -> Int32? = SystemMemoryProbe.readSystemPressureLevelCode,
        processCache: ProcessSamplingCache = .shared
    ) {
        self.history = history
        self.systemPressureLevelCode = systemPressureLevelCode
        self.processCache = processCache
    }

    /// The kernel's memory pressure condition: 1 normal, 2 warning, 4 critical.
    static let readSystemPressureLevelCode: @Sendable () -> Int32? = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return value
    }

    func snapshot(includeProcesses: Bool) async -> MemorySnapshot {
        await snapshot(
            includeProcesses: includeProcesses,
            includePressureReading: true
        )
    }

    func snapshot(
        includeProcesses: Bool,
        includePressureReading: Bool
    ) async -> MemorySnapshot {
        let capturedInstant = clock.now
        let capturedAt = Date()
        let pageReadings = Self.pageReadings()
        let physicalBytes = ProcessInfo.processInfo.physicalMemory
        let swapReadings = Self.swapReadings()
        let pressureReading = includePressureReading
            ? Self.pressureReading()
            : (
                summary: L10n.text("轻量后台采样", "Lightweight background sample"),
                freePercentage: nil,
                reason: "The free percentage was skipped for a lightweight status sample."
            )
        let processResult = includeProcesses
            ? await processes(physicalBytes: physicalBytes, capturedAt: capturedAt)
            : (processes: [], warnings: [])
        var warnings = processResult.warnings

        func byteValue(_ key: String) -> UInt64? {
            guard let pages = pageReadings?.values[key],
                  let pageSize = pageReadings?.pageSize else { return nil }
            let result = pages.multipliedReportingOverflow(by: pageSize)
            if result.overflow {
                warnings.append(.arithmeticClamped(name: key))
                return UInt64.max
            }
            return result.partialValue
        }

        let speculative = byteValue("Pages speculative")
        let rawFree = byteValue("Pages free")
        let freeBytes = Self.safeAdd(
            rawFree,
            speculative,
            warningName: "freeBytes",
            warnings: &warnings
        )
        let inactive = byteValue("Pages inactive")
        let fileBacked = byteValue("File-backed pages")
        let purgeable = byteValue("Pages purgeable")
        let wired = byteValue("Pages wired down")
        let compressed = byteValue("Pages occupied by compressor")
        let cached = fileBacked.flatMap { fileBacked in
            purgeable.map { max(fileBacked, $0) }
        }

        let appSum = MemoryByteMath.sum(processResult.processes.map(\.residentBytes))
        if appSum.clamped {
            warnings.append(.arithmeticClamped(name: "appBytes"))
        }

        let rates: (swapIn: Double?, swapOut: Double?)
        if let pageReadings,
           let pageIns = pageReadings.values["Swapins"],
           let pageOuts = pageReadings.values["Swapouts"] {
            rates = await history.rates(
                instant: capturedInstant,
                pageIns: pageIns,
                pageOuts: pageOuts,
                pageSize: pageReadings.pageSize
            )
        } else {
            rates = (nil, nil)
        }

        let physical = Int64(clamping: physicalBytes)
        let legacyFree = Int64(clamping: freeBytes ?? 0)
        let legacyFileBacked = Int64(clamping: fileBacked ?? 0)
        let legacyPurgeable = Int64(clamping: purgeable ?? 0)
        let availableEstimate = Self.safeAdd(
            freeBytes,
            cached,
            warningName: "availableBytes",
            warnings: &warnings
        ).map { min(physicalBytes, $0) }
        // The level is the system's own level. It is not derived from the
        // free percentage, the available estimate, swap or compression.
        let pressure = Self.pressureMeasurement(systemLevelCode: systemPressureLevelCode())

        let measurements = MemoryMeasurements(
            pressure: pressure,
            physicalBytes: .available(physicalBytes),
            availableBytes: availableEstimate.map(MemoryMeasurement.available)
                ?? .unavailable(.temporarilyInvalid, reason: "VM statistics could not provide an available-memory estimate."),
            appBytes: includeProcesses
                ? .available(UInt64(clamping: appSum.value))
                : .unavailable(.temporarilyInvalid, reason: "Process enumeration was skipped for this lightweight sample."),
            wiredBytes: Self.measurement(wired, metric: "wired memory", warnings: &warnings),
            compressedBytes: Self.measurement(compressed, metric: "compressed memory", warnings: &warnings),
            cachedBytes: Self.measurement(cached, metric: "cached files", warnings: &warnings),
            swapUsedBytes: swapReadings.map { .available($0.used) }
                ?? .unavailable(.temporarilyInvalid, reason: "vm.swapusage could not be read."),
            swapInRate: rates.swapIn.map(MemoryMeasurement.available)
                ?? .unavailable(.temporarilyInvalid, reason: "A valid previous page-in sample is required."),
            swapOutRate: rates.swapOut.map(MemoryMeasurement.available)
                ?? .unavailable(.temporarilyInvalid, reason: "A valid previous page-out sample is required.")
        )

        if pageReadings == nil {
            warnings.append(.metricUnavailable(name: "VM statistics", reason: "host_statistics64 failed."))
        }
        if swapReadings == nil {
            warnings.append(.metricUnavailable(name: "Swap", reason: "vm.swapusage could not be read."))
        }
        if includePressureReading, pressureReading.freePercentage == nil {
            warnings.append(.metricUnavailable(name: "Pressure headroom", reason: pressureReading.reason))
        }
        if let reason = pressure.reason, pressure.value == nil {
            warnings.append(.metricUnavailable(name: "Pressure level", reason: reason))
        }

        let requiredUnavailable = [
            measurements.pressure.availability,
            measurements.physicalBytes.availability,
            measurements.availableBytes.availability,
            measurements.wiredBytes.availability,
            measurements.compressedBytes.availability,
            measurements.cachedBytes.availability,
            measurements.swapUsedBytes.availability,
        ].filter { $0 != .available }.count
        let quality: MeasurementQuality = requiredUnavailable == 0
            ? (warnings.isEmpty ? .complete : .partial)
            : (requiredUnavailable >= 6 ? .unavailable : .partial)

        return MemorySnapshot(
            generatedAt: capturedAt,
            capturedInstant: capturedInstant,
            physicalBytes: physical,
            freeBytes: legacyFree,
            inactiveBytes: Int64(clamping: inactive ?? 0),
            speculativeBytes: Int64(clamping: speculative ?? 0),
            fileBackedBytes: legacyFileBacked,
            purgeableBytes: legacyPurgeable,
            wiredBytes: Int64(clamping: wired ?? 0),
            compressedBytes: Int64(clamping: compressed ?? 0),
            swapUsedBytes: Int64(clamping: swapReadings?.used ?? 0),
            pressureFreePercentage: pressureReading.freePercentage,
            pressureSummary: pressureReading.summary,
            topProcesses: processResult.processes,
            swapTotalBytes: Int64(clamping: swapReadings?.total ?? 0),
            swappedInBytes: Self.swapActivityBytes(pages: pageReadings?.values["Swapins"], pageSize: pageReadings?.pageSize),
            swappedOutBytes: Self.swapActivityBytes(pages: pageReadings?.values["Swapouts"], pageSize: pageReadings?.pageSize),
            measurements: measurements,
            quality: quality,
            warnings: warnings
        )
    }

    /// The system's level, or unavailable. A level the system did not report
    /// is never replaced with one of our own.
    nonisolated static func pressureMeasurement(
        systemLevelCode: Int32?
    ) -> MemoryMeasurement<MemoryPressureLevel> {
        guard let systemLevelCode else {
            return .unavailable(
                .unsupported,
                reason: "kern.memorystatus_vm_pressure_level could not be read."
            )
        }
        guard let level = MemoryPressureLevel(systemCode: Int(systemLevelCode)) else {
            return .unavailable(
                .invalidSample,
                reason: "kern.memorystatus_vm_pressure_level reported an unknown level \(systemLevelCode)."
            )
        }
        return .available(level)
    }

    /// Swap activity in bytes. vm_stat's Swapins / Swapouts are "the amount
    /// of compressed data read back in from / written out to swap files, in
    /// units of pages" (vm_stat(1)), so bytes = pages x page size. They are
    /// not Pageins / Pageouts, which count requests to any pager (mostly
    /// file-backed reads) and file-backed pages written back. Unknown inputs
    /// stay unknown; an overflow clamps.
    nonisolated static func swapActivityBytes(pages: UInt64?, pageSize: UInt64?) -> Int64? {
        guard let pages, let pageSize else { return nil }
        let bytes = pages.multipliedReportingOverflow(by: pageSize)
        return bytes.overflow ? .max : Int64(clamping: bytes.partialValue)
    }

    private static func measurement(
        _ value: UInt64?,
        metric: String,
        warnings: inout [MeasurementWarning]
    ) -> MemoryMeasurement<UInt64> {
        guard let value else {
            let reason = "The system did not provide a valid \(metric) sample."
            warnings.append(.metricUnavailable(name: metric, reason: reason))
            return .unavailable(.temporarilyInvalid, reason: reason)
        }
        return .available(value)
    }

    private static func safeAdd(
        _ lhs: UInt64?,
        _ rhs: UInt64?,
        warningName: String,
        warnings: inout [MeasurementWarning]
    ) -> UInt64? {
        guard let lhs, let rhs else { return nil }
        let result = lhs.addingReportingOverflow(rhs)
        if result.overflow {
            warnings.append(.arithmeticClamped(name: warningName))
            return UInt64.max
        }
        return result.partialValue
    }

    private static func pageReadings() -> PageReadings? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var rawPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &rawPageSize) == KERN_SUCCESS,
              rawPageSize > 0 else { return nil }

        return PageReadings(
            pageSize: UInt64(rawPageSize),
            values: [
                "Pages free": UInt64(stats.free_count),
                "Pages active": UInt64(stats.active_count),
                "Pages inactive": UInt64(stats.inactive_count),
                "Pages speculative": UInt64(stats.speculative_count),
                "File-backed pages": UInt64(stats.external_page_count),
                "Pages purgeable": UInt64(stats.purgeable_count),
                "Pages wired down": UInt64(stats.wire_count),
                "Pages occupied by compressor": UInt64(stats.compressor_page_count),
                "Swapins": UInt64(stats.swapins),
                "Swapouts": UInt64(stats.swapouts),
            ]
        )
    }

    private static func swapReadings() -> SwapReadings? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapReadings(used: usage.xsu_used, total: usage.xsu_total)
    }

    /// The system-wide memory free percentage, the value `memory_pressure -Q`
    /// prints as "System-wide memory free percentage". Read directly: the
    /// status sample no longer starts that tool on every refresh.
    static let readSystemMemoryFreePercentage: @Sendable () -> Int32? = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return value
    }

    private static func pressureReading() -> (summary: String, freePercentage: Int?, reason: String) {
        guard let freePercentage = readSystemMemoryFreePercentage() else {
            return (
                L10n.text("压力数据不可用", "Pressure unavailable"),
                nil,
                "kern.memorystatus_level could not be read."
            )
        }
        let reading = MemoryOptimizerService.pressureSummary(freePercentage: Int(freePercentage))
        return (reading.summary, reading.freePercentage, "kern.memorystatus_level did not expose headroom.")
    }

    /// Launch Services can transiently report duplicate or terminated PIDs.
    /// Keep one complete identity, preferring the newest known launch, rather
    /// than trapping or combining fields from different process lifetimes.
    nonisolated static func indexRunningApplications(
        _ applications: [(pid_t, RunningAppIdentity)]
    ) -> [pid_t: RunningAppIdentity] {
        Dictionary(applications.filter { $0.0 > 0 }, uniquingKeysWith: { existing, incoming in
            switch (existing.launchDate, incoming.launchDate) {
            case let (old?, new?) where old > new: return existing
            case (_?, nil): return existing
            default: return incoming
            }
        })
    }

    private func processes(
        physicalBytes: UInt64,
        capturedAt: Date
    ) async -> (processes: [MemoryProcess], warnings: [MeasurementWarning]) {
        let runningApps = await MainActor.run {
            MenuBarPresentationTrace.measure("memory.processes.main") {
                let workspace = NSWorkspace.shared
                return Self.indexRunningApplications(
                    RunningApplicationIdentityCache.identities(
                        of: workspace.runningApplications,
                        userFrontmostProcessIdentifier: UserFrontmostApplicationTracker.shared
                            .userFrontmostProcessIdentifier(
                                frontmost: workspace.frontmostApplication?.processIdentifier
                            )
                    )
                )
            }
        }

        return await Self.processesAwaitingDiscovery(physicalBytes: physicalBytes, capturedAt: capturedAt,
                                                    runningApps: runningApps, processCache: processCache)
    }

    nonisolated static func processesAwaitingDiscovery(
        physicalBytes: UInt64,
        capturedAt: Date,
        runningApps: [pid_t: RunningAppIdentity],
        processCache: ProcessSamplingCache,
        discoveryTimeout: Duration = .milliseconds(250),
        readUsage: (Int32) -> ProcessUsage? = readProcessUsage,
        readIdentity: (Int32) -> ProcessIdentity? = readProcessIdentity,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        currentUser: UInt32 = UInt32(getuid())
    ) async -> (processes: [MemoryProcess], warnings: [MeasurementWarning]) {
        guard let pids = await processCache.memoryProcessIDsAwaitingEnergyDiscovery(timeout: discoveryTimeout) else {
            return Task.isCancelled ? ([], [])
                : ([], [.metricUnavailable(name: "Processes", reason: "proc_listpids failed.")])
        }
        return processes(physicalBytes: physicalBytes, capturedAt: capturedAt, runningApps: runningApps,
                         processCache: processCache, readUsage: readUsage, readIdentity: readIdentity,
                         currentPID: currentPID, currentUser: currentUser, discoveredPIDs: pids)
    }

    /// The injectable providers keep tests off the actual process table.
    /// Each PID still gets fresh rusage and BSD identity reads; only its
    /// validated static path/name can be shared with the CPU/disk frame.
    nonisolated static func processes(
        physicalBytes: UInt64,
        capturedAt: Date,
        runningApps: [pid_t: RunningAppIdentity],
        processCache: ProcessSamplingCache,
        readUsage: (Int32) -> ProcessUsage? = readProcessUsage,
        readIdentity: (Int32) -> ProcessIdentity? = readProcessIdentity,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        currentUser: UInt32 = UInt32(getuid()),
        discoveredPIDs: [Int32]? = nil
    ) -> (processes: [MemoryProcess], warnings: [MeasurementWarning]) {
        guard !Task.isCancelled else { return ([], []) }
        guard let pids = discoveredPIDs ?? processCache.memoryProcessIDs() else {
            return ([], [.metricUnavailable(name: "Processes", reason: "proc_listpids failed.")])
        }

        var warnings: [MeasurementWarning] = []
        var samples: [MemoryProcess] = []
        samples.reserveCapacity(min(pids.count, 512))

        for pid in pids {
            guard !Task.isCancelled else { return ([], warnings) }
            guard let usage = readUsage(pid) else {
                processCache.invalidate(pid: pid)
                continue
            }
            guard let bsd = readIdentity(pid) else {
                processCache.invalidate(pid: pid)
                if warnings.count < 20 {
                    warnings.append(.invalidProcessSample(
                        processIdentifier: pid,
                        reason: "Process identity changed during sampling."
                    ))
                }
                continue
            }

            guard let metadata = processCache.metadata(pid: pid, birth: usage.birth) else { continue }
            let app = runningApps[pid].flatMap { app -> RunningAppIdentity? in
                // The main-thread application list predates this dynamic
                // read. Never attach an old app identity to a reused PID.
                if let startTime = app.processStartTime { return startTime == bsd.startTime ? app : nil }
                guard let launchDate = app.launchDate,
                      abs(launchDate.timeIntervalSince(bsd.launchDate)) < 0.01 else { return nil }
                return app
            }
            let executablePath = app?.executablePath ?? metadata.path
            let bundlePath = app?.bundlePath ?? Self.appBundlePath(containing: executablePath)
            let name = app?.name ?? metadata.fallbackName
            let residentBytes = Int64(clamping: usage.footprintBytes)
            guard residentBytes > 0 else { continue }

            let launchDate = app?.launchDate ?? bsd.launchDate
            let userIdentifier = bsd.userIdentifier
            let isUserAppBundle = bundlePath.map { path in
                path.hasSuffix(".app")
                    && (path.hasPrefix("/Applications/")
                        || path.hasPrefix("\(PathSafety.homePath)/Applications/"))
            } ?? false
            let canQuit = pid != currentPID
                && userIdentifier == currentUser
                && isUserAppBundle
                && app?.activationPolicy == .regular
            let percent = physicalBytes > 0
                ? min(100, Double(usage.footprintBytes) / Double(physicalBytes) * 100)
                : 0

            samples.append(MemoryProcess(
                id: pid,
                name: name.isEmpty ? executablePath : name,
                path: executablePath,
                iconPath: bundlePath ?? executablePath,
                bundlePath: bundlePath,
                residentBytes: residentBytes,
                percent: percent.isFinite ? max(0, percent) : 0,
                canQuit: canQuit,
                isActive: app?.isActive == true,
                bundleIdentifier: app?.bundleIdentifier,
                launchDate: launchDate,
                userIdentifier: userIdentifier,
                capturedAt: capturedAt,
                dataSource: .procPIDRUsage,
                availability: .available
            ))
        }

        return (
            Array(samples.sorted { $0.residentBytes > $1.residentBytes }.prefix(256)),
            warnings
        )
    }

    /// The shared ps inventory is only a one-round hint. Missing, stale or
    /// incomplete hints use this full native discovery through the cache's
    /// default provider; a full buffer is grown instead of being truncated.
    nonisolated static func discoverAllProcessIDs() -> [Int32]? {
        var capacity = 16_384
        while capacity <= 1_048_576 {
            var pids = [Int32](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
            }
            guard bytes > 0 else { return nil }
            let count = Int(bytes) / MemoryLayout<Int32>.stride
            guard count < capacity else { capacity *= 2; continue }
            return Array(pids.prefix(count))
        }
        return nil
    }

    nonisolated static func readProcessUsage(_ pid: Int32) -> ProcessUsage? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            let buffer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
        }
        guard result == 0 else { return nil }
        return ProcessUsage(footprintBytes: usage.ri_phys_footprint, birth: usage.ri_proc_start_abstime)
    }

    nonisolated static func readProcessIdentity(_ pid: Int32) -> ProcessIdentity? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        return ProcessIdentity(startTime: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec,
                               userIdentifier: UInt32(bsd.pbi_uid))
    }

    private static func appBundlePath(containing executablePath: String) -> String? {
        guard let appRange = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<appRange.upperBound].dropLast())
    }
}

/// What the memory probe reads from a running application
/// (`NSRunningApplication`; tests supply their own).
protocol RunningApplicationIdentitySource: AnyObject {
    var processIdentifier: pid_t { get }
    var localizedName: String? { get }
    var bundleIdentifier: String? { get }
    var bundleURL: URL? { get }
    var executableURL: URL? { get }
    var launchDate: Date? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isActive: Bool { get }
}

extension NSRunningApplication: RunningApplicationIdentitySource {}

/// Running applications as the memory probe identifies them. Bundle
/// identifier, bundle and executable paths and launch date never change for
/// one process, so they are read once per process: reading them for every
/// running application on each process-list refresh took most of the
/// refresh's main-thread time (phase 2 audit, `memory.processes.main`;
/// offline with 165 applications, 24.9 ms per refresh with them, 10.2 ms
/// reading only the name, policy, active state and start time).
///
/// A process is identified by its process identifier and start time: the
/// identifier alone can be reused, and the `NSRunningApplication` objects
/// cannot be compared, because `NSWorkspace.runningApplications` returns new
/// ones on each run-loop turn (review of phase 2). An application whose start
/// time cannot be read is read every time and not stored. The
/// activation policy and active state are read every time. Successful names
/// are static metadata too; incomplete metadata is retried on the next read.
@MainActor
enum RunningApplicationIdentityCache {
    private struct Entry {
        let startTime: UInt64
        let name: String?
        let bundleIdentifier: String?
        let bundlePath: String?
        let executablePath: String?
        let launchDate: Date?
    }

    private static var entries: [pid_t: Entry] = [:]
#if DEBUG
    /// Tests: applications whose stored entry was used / that were read, in
    /// the last call.
    private(set) static var reusedCount = 0
    private(set) static var readCount = 0
#endif

    /// The process's start time (microseconds since 1970), or nil when it
    /// cannot be read, for example because the process has ended.
    nonisolated static func processStartTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// `userFrontmostProcessIdentifier` is the application the user is
    /// working in (`UserFrontmostApplicationTracker`); it counts as active.
    static func identities<Application: RunningApplicationIdentitySource>(
        of applications: [Application],
        startTime: (pid_t) -> UInt64? = processStartTime,
        userFrontmostProcessIdentifier: pid_t? = nil
    ) -> [(pid_t, SystemMemoryProbe.RunningAppIdentity)] {
        var current: [pid_t: Entry] = [:]
#if DEBUG
        reusedCount = 0
        readCount = 0
#endif
        let identities = applications.map { app -> (pid_t, SystemMemoryProbe.RunningAppIdentity) in
            let pid = app.processIdentifier
            let started = startTime(pid).flatMap { $0 > 0 ? $0 : nil }
            let entry: Entry
            if let started, let stored = entries[pid], stored.startTime == started {
                // A nil from Launch Services can be transient. Reuse each
                // successful field, but retry missing fields after recovery.
                entry = Entry(startTime: started,
                              name: stored.name ?? app.localizedName,
                              bundleIdentifier: stored.bundleIdentifier ?? app.bundleIdentifier,
                              bundlePath: stored.bundlePath ?? app.bundleURL?.path,
                              executablePath: stored.executablePath ?? app.executableURL?.path,
                              launchDate: stored.launchDate ?? app.launchDate)
#if DEBUG
                reusedCount += 1
#endif
            } else {
                entry = Entry(startTime: started ?? 0,
                              name: app.localizedName,
                              bundleIdentifier: app.bundleIdentifier,
                              bundlePath: app.bundleURL?.path,
                              executablePath: app.executableURL?.path,
                              launchDate: app.launchDate)
#if DEBUG
                readCount += 1
#endif
            }
            if started != nil {
                current[pid] = entry
            }
            let policy: MemoryRunningApplicationActivationPolicy
            switch app.activationPolicy {
            case .regular: policy = .regular
            case .accessory: policy = .accessory
            case .prohibited: policy = .prohibited
            @unknown default: policy = .prohibited
            }
            return (pid, SystemMemoryProbe.RunningAppIdentity(
                name: entry.name,
                bundleIdentifier: entry.bundleIdentifier,
                bundlePath: entry.bundlePath,
                executablePath: entry.executablePath,
                launchDate: entry.launchDate,
                activationPolicy: policy,
                isActive: app.isActive || pid == userFrontmostProcessIdentifier,
                processStartTime: started
            ))
        }
        entries = current
        return identities
    }
}
