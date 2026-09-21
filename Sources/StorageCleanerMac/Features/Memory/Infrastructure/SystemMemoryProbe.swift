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
    }

    private let history: MemoryHistoryStore
    private let clock = ContinuousClock()

    init(history: MemoryHistoryStore = MemoryHistoryStore()) {
        self.history = history
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
                reason: "memory_pressure was skipped for a lightweight status sample."
            )
        let processResult = includeProcesses
            ? await Self.processes(physicalBytes: physicalBytes, capturedAt: capturedAt)
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
        let pressure: MemoryPressureLevel?
        if let availableEstimate {
            pressure = MemoryPressurePolicy.classify(
                physicalBytes: physical,
                availableBytes: Int64(clamping: availableEstimate),
                compressedBytes: Int64(clamping: compressed ?? 0),
                swapUsedBytes: swapReadings.map { Int64(clamping: $0.used) },
                pressureFreePercentage: pressureReading.freePercentage
            )
        } else {
            pressure = pressureReading.freePercentage.map(
                MemoryPressurePolicy.classify(pressureFreePercentage:)
            )
        }

        let measurements = MemoryMeasurements(
            pressure: pressure.map(MemoryMeasurement.available)
                ?? .unavailable(.temporarilyInvalid, reason: pressureReading.reason),
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
            pageInsCount: Int64(clamping: pageReadings?.values["Pageins"] ?? 0),
            pageOutsCount: Int64(clamping: pageReadings?.values["Pageouts"] ?? 0),
            measurements: measurements,
            quality: quality,
            warnings: warnings
        )
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
                "Pageins": UInt64(stats.pageins),
                "Pageouts": UInt64(stats.pageouts),
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

    private static func pressureReading() -> (summary: String, freePercentage: Int?, reason: String) {
        do {
            let output = try Shell.capture(
                "/usr/bin/memory_pressure",
                ["-Q"],
                timeout: 2
            )
            let parsed = MemoryOptimizerService.pressureSummary(from: output)
            return (parsed.summary, parsed.freePercentage, "memory_pressure did not expose headroom.")
        } catch {
            return (
                L10n.text("压力数据不可用", "Pressure unavailable"),
                nil,
                "memory_pressure could not be read."
            )
        }
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

    private static func processes(
        physicalBytes: UInt64,
        capturedAt: Date
    ) async -> (processes: [MemoryProcess], warnings: [MeasurementWarning]) {
        let runningApps = await MainActor.run {
            indexRunningApplications(NSWorkspace.shared.runningApplications.map { app in
                let policy: MemoryRunningApplicationActivationPolicy
                switch app.activationPolicy {
                case .regular: policy = .regular
                case .accessory: policy = .accessory
                case .prohibited: policy = .prohibited
                @unknown default: policy = .prohibited
                }
                return (
                    app.processIdentifier,
                    RunningAppIdentity(
                        name: app.localizedName,
                        bundleIdentifier: app.bundleIdentifier,
                        bundlePath: app.bundleURL?.path,
                        executablePath: app.executableURL?.path,
                        launchDate: app.launchDate,
                        activationPolicy: policy,
                        isActive: app.isActive
                    )
                )
            })
        }

        var rawPIDs = [pid_t](repeating: 0, count: 16_384)
        let bytesWritten = rawPIDs.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesWritten > 0 else {
            return ([], [.metricUnavailable(name: "Processes", reason: "proc_listpids failed.")])
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentUser = getuid()
        var warnings: [MeasurementWarning] = []
        let count = min(rawPIDs.count, Int(bytesWritten) / MemoryLayout<pid_t>.stride)
        var samples: [MemoryProcess] = []
        samples.reserveCapacity(min(count, 512))

        for pid in rawPIDs.prefix(count) where pid > 0 {
            var usage = rusage_info_v4()
            let usageResult = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
                let buffer = UnsafeMutableRawPointer(pointer)
                    .assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
            }
            guard usageResult == 0 else { continue }

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let bsdResult = withUnsafeMutablePointer(to: &bsd) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, bsdSize)
            }
            guard bsdResult == bsdSize else {
                if warnings.count < 20 {
                    warnings.append(.invalidProcessSample(
                        processIdentifier: pid,
                        reason: "Process identity changed during sampling."
                    ))
                }
                continue
            }

            var pathBuffer = [CChar](repeating: 0, count: 4_096)
            let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
                proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            guard pathLength > 0 else { continue }

            let pathBytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let rawExecutablePath = String(decoding: pathBytes, as: UTF8.self)
            let app = runningApps[pid]
            let executablePath = app?.executablePath ?? rawExecutablePath
            let bundlePath = app?.bundlePath ?? Self.appBundlePath(containing: executablePath)
            let name = app?.name
                ?? URL(fileURLWithPath: bundlePath ?? executablePath)
                    .deletingPathExtension()
                    .lastPathComponent
            let residentBytes = Int64(clamping: usage.ri_phys_footprint)
            guard residentBytes > 0 else { continue }

            let launchDate = app?.launchDate ?? Date(
                timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)
                    + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
            )
            let userIdentifier = UInt32(bsd.pbi_uid)
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
                ? min(100, Double(usage.ri_phys_footprint) / Double(physicalBytes) * 100)
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

    private static func appBundlePath(containing executablePath: String) -> String? {
        guard let appRange = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<appRange.upperBound].dropLast())
    }
}
