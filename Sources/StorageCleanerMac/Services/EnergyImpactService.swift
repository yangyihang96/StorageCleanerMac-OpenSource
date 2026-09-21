import AppKit
import Darwin
import Foundation

struct EnergyProcessRow: Hashable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let residentBytes: Int64
    let elapsedSeconds: TimeInterval?
    let cpuTimeSeconds: TimeInterval
    let cpuPercent: Double
    let path: String
}

struct EnergyResourceUsage: Hashable, Sendable {
    let pid: Int32
    let energyNanojoules: UInt64
    let cpuTimeMach: UInt64
    let processStartMach: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
}

enum EnergyImpactService {
    private static let measuredSampleInterval: Duration = .milliseconds(1_200)
    private static let processListArguments = [
        "-axo",
        "pid=,ppid=,rss=,etime=,time=,pcpu=,comm=",
    ]

    static func snapshot(
        sampleInterval: Duration = measuredSampleInterval,
        onProgress: (@MainActor @Sendable (EnergyImpactScanPhase) -> Void)? = nil,
        onProcessSnapshot: (@MainActor @Sendable (EnergyImpactSnapshot) -> Void)? = nil
    ) async -> EnergyImpactSnapshot {
        let startedAt = Date()
        if let onProgress {
            await onProgress(.readingProcesses)
        }
        let processOutput = await processListOutput()

        if let onProgress {
            await onProgress(.identifyingApplications)
        }
        let processRows = processRows(fromPSOutput: processOutput)
        let applicationProcesses = applicationProcesses(from: processRows)
        let processIDs = applicationProcesses.map(\.row.pid)

        if let onProgress {
            await onProgress(.capturingBaseline)
        }
        let firstResourceSamples = resourceUsagesByPID(for: processIDs)
        let energySampleStartedAt = Date()

        if let onProgress {
            await onProgress(.preparingPreview)
        }
        if let onProcessSnapshot {
            await onProcessSnapshot(makeSnapshot(
                startedAt: startedAt,
                applicationProcesses: applicationProcesses,
                firstResourceSamples: firstResourceSamples,
                latestResourceSamples: [:],
                measuredSampleSeconds: 0
            ))
        }

        if let onProgress {
            await onProgress(.measuringChanges)
        }
        if !firstResourceSamples.isEmpty {
            try? await Task.sleep(for: sampleInterval)
        }
        let latestResourceSamples = firstResourceSamples.isEmpty
            ? [:]
            : resourceUsagesByPID(for: processIDs)
        let measuredSampleSeconds = Date().timeIntervalSince(energySampleStartedAt)

        if let onProgress {
            await onProgress(.calculatingResults)
        }
        return makeSnapshot(
            startedAt: startedAt,
            applicationProcesses: applicationProcesses,
            firstResourceSamples: firstResourceSamples,
            latestResourceSamples: latestResourceSamples,
            measuredSampleSeconds: measuredSampleSeconds
        )
    }

    private static func processListOutput() async -> String {
        guard !Task.isCancelled else { return "" }
        let worker = Task.detached(priority: .utility) { captureProcessList() }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }

    /// `ps` is deliberately fixed here rather than routed through a shell.
    /// The shared process-group runner is intended for commands that may own
    /// descendants; macOS can reject that setup for this short-lived binary.
    private static func captureProcessList() -> String {
        guard !Task.isCancelled else { return "" }
        let fileManager = FileManager.default
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-EnergyPS-\(UUID().uuidString)", isDirectory: true)
        let standardOutputURL = outputDirectory.appendingPathComponent("stdout")
        let standardErrorURL = outputDirectory.appendingPathComponent("stderr")

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            _ = fileManager.createFile(atPath: standardOutputURL.path, contents: nil)
            _ = fileManager.createFile(atPath: standardErrorURL.path, contents: nil)
            let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
            let standardError = try FileHandle(forWritingTo: standardErrorURL)
            defer {
                try? standardOutput.close()
                try? standardError.close()
                try? fileManager.removeItem(at: outputDirectory)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = processListArguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = standardOutput
            process.standardError = standardError

            let didTerminate = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in didTerminate.signal() }
            guard !Task.isCancelled else { return "" }
            try process.run()
            let childIdentity = Shell.directChildIdentity(for: process.processIdentifier)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var completed = false
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if didTerminate.wait(timeout: .now() + 0.05) == .success {
                    completed = true
                    break
                }
            }
            if !completed {
                // This is our own fixed, short-lived ps child, never another
                // application. Keep the worker occupied until it really exits.
                if process.isRunning { Shell.signalDirectChild(childIdentity, signal: SIGTERM) }
                if didTerminate.wait(timeout: .now() + 1) != .success, process.isRunning {
                    Shell.signalDirectChild(childIdentity, signal: SIGKILL)
                }
                process.waitUntilExit()
                return ""
            }
            guard !Task.isCancelled else { return "" }

            try? standardOutput.synchronize()
            try? standardError.synchronize()
            guard process.terminationStatus == 0 else { return "" }
            let data = try Data(contentsOf: standardOutputURL)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            try? fileManager.removeItem(at: outputDirectory)
            return ""
        }
    }

    struct MenuBarCounterFrame: Sendable {
        let sampledAt: Date
        let uptime: TimeInterval
        let rows: [EnergyProcessRow]
        let counters: [Int32: EnergyResourceUsage]
    }

    /// One read per interval. The menu does not restart a 1.2-second measurement
    /// on each refresh; its previous counter frame is the next baseline.
    static func menuBarCounterFrame() async -> MenuBarCounterFrame? {
        let output = await processListOutput()
        guard !Task.isCancelled, !output.isEmpty else { return nil }
        let rows = processRows(fromPSOutput: output)
        let counters = resourceUsagesByPID(for: rows.map(\.pid))
        guard !rows.isEmpty, !counters.isEmpty else { return nil }
        return MenuBarCounterFrame(sampledAt: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                                   rows: rows, counters: counters)
    }

    static func menuBarSnapshot(previous: MenuBarCounterFrame, current: MenuBarCounterFrame) -> EnergyImpactSnapshot? {
        let elapsed = current.uptime - previous.uptime
        guard elapsed > 0, elapsed.isFinite else { return nil }
        // New/reused PIDs and reset counters need another baseline, not a
        // fabricated zero or ps's lifetime CPU average.
        let rows = current.rows.filter { row in
            guard let before = previous.counters[row.pid], let after = current.counters[row.pid] else { return false }
            return before.processStartMach == after.processStartMach
                && after.cpuTimeMach >= before.cpuTimeMach
                && after.diskReadBytes >= before.diskReadBytes
                && after.diskWrittenBytes >= before.diskWrittenBytes
                && after.energyNanojoules >= before.energyNanojoules
        }
        guard !rows.isEmpty else { return nil }
        return makeSnapshot(startedAt: current.sampledAt,
                            applicationProcesses: applicationProcesses(from: rows),
                            firstResourceSamples: previous.counters,
                            latestResourceSamples: current.counters,
                            measuredSampleSeconds: elapsed, sampledAt: current.sampledAt)
    }

    private static func makeSnapshot(
        startedAt: Date,
        applicationProcesses: [PreparedEnergyProcess],
        firstResourceSamples: [Int32: EnergyResourceUsage],
        latestResourceSamples: [Int32: EnergyResourceUsage],
        measuredSampleSeconds: TimeInterval,
        sampledAt: Date? = nil
    ) -> EnergyImpactSnapshot {
        let resourceSamples = latestResourceSamples.isEmpty ? firstResourceSamples : latestResourceSamples
        let hasEnergyCounters = resourceSamples.values.contains { $0.energyNanojoules > 0 }
        let measuredResourceSamples = hasEnergyCounters ? resourceSamples : [:]
        let currentMeasurements = currentEnergyMeasurements(
            firstResourceSamples: firstResourceSamples,
            latestResourceSamples: latestResourceSamples,
            sampleSeconds: measuredSampleSeconds,
            hasEnergyCounters: hasEnergyCounters
        )
        let uptimeSeconds = ProcessInfo.processInfo.systemUptime
        let calibration = energyCalibration(
            processes: applicationProcesses,
            resourceSamples: measuredResourceSamples,
            currentMeasurements: currentMeasurements
        )
        let apps = groupedApps(
            processes: applicationProcesses,
            resourceSamples: measuredResourceSamples,
            currentMeasurements: currentMeasurements,
            uptimeSeconds: uptimeSeconds,
            calibration: calibration
        )
        let measuredProcessCount = applicationProcesses.reduce(0) { count, process in
            count + (measuredResourceSamples[process.row.pid] == nil ? 0 : 1)
        }
        let measuredTotalEnergyWh = apps.reduce(0) { $0 + $1.measuredEnergyWh }
        let estimatedSupplementEnergyWh = apps.reduce(0) { $0 + $1.estimatedSupplementEnergyWh }

        return EnergyImpactSnapshot(
            generatedAt: sampledAt ?? Date(),
            scanSeconds: Date().timeIntervalSince(startedAt),
            sampleSeconds: firstResourceSamples.isEmpty ? 0 : measuredSampleSeconds,
            uptimeSeconds: uptimeSeconds,
            apps: apps,
            processCount: applicationProcesses.count,
            measuredProcessCount: measuredProcessCount,
            unmeasuredProcessCount: max(0, applicationProcesses.count - measuredProcessCount),
            measuredTotalEnergyWh: measuredTotalEnergyWh,
            estimatedSupplementEnergyWh: estimatedSupplementEnergyWh,
            calibrationWattsPerCore: calibration.cumulativeWattsPerCore,
            usesLocalCalibration: calibration.usesLocalCalibration
        )
    }

    static func processRows(fromPSOutput output: String) -> [EnergyProcessRow] {
        var seenPIDs: Set<Int32> = []
        return output.split(separator: "\n").compactMap { rawLine -> EnergyProcessRow? in
            let line = String(rawLine).trimmed
            guard !line.isEmpty else { return nil }

            let parts = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard parts.count == 7,
                  let pid = Int32(parts[0]),
                  let parentPID = Int32(parts[1]),
                  let residentKB = Int64(parts[2]),
                  let cpuTimeSeconds = durationSeconds(from: String(parts[4])),
                  let cpuPercent = Double(parts[5]) else {
                return nil
            }
            guard seenPIDs.insert(pid).inserted else { return nil }

            return EnergyProcessRow(
                pid: pid,
                parentPID: parentPID,
                residentBytes: max(0, residentKB) * 1024,
                elapsedSeconds: durationSeconds(from: String(parts[3])),
                cpuTimeSeconds: cpuTimeSeconds,
                cpuPercent: max(0, cpuPercent),
                path: String(parts[6])
            )
        }
    }

    static func durationSeconds(from rawValue: String) -> TimeInterval? {
        let trimmedValue = rawValue.trimmed
        guard !trimmedValue.isEmpty else { return nil }

        var days = 0
        var timeValue = trimmedValue
        if let daySeparator = trimmedValue.firstIndex(of: "-") {
            let dayText = String(trimmedValue[..<daySeparator])
            guard let parsedDays = Int(dayText) else { return nil }
            days = parsedDays
            timeValue = String(trimmedValue[trimmedValue.index(after: daySeparator)...])
        }

        let pieces = timeValue.split(separator: ":").map(String.init)
        guard !pieces.isEmpty else { return nil }

        let seconds: Double
        switch pieces.count {
        case 3:
            guard let hours = Double(pieces[0]),
                  let minutes = Double(pieces[1]),
                  let parsedSeconds = Double(pieces[2]) else {
                return nil
            }
            seconds = hours * 3_600 + minutes * 60 + parsedSeconds
        case 2:
            guard let minutes = Double(pieces[0]),
                  let parsedSeconds = Double(pieces[1]) else {
                return nil
            }
            seconds = minutes * 60 + parsedSeconds
        case 1:
            guard let parsedSeconds = Double(pieces[0]) else { return nil }
            seconds = parsedSeconds
        default:
            return nil
        }

        return max(0, Double(days) * 86_400 + seconds)
    }

    static func resourceUsage(pid: Int32) -> EnergyResourceUsage? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            let buffer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, buffer)
        }
        guard result == 0 else { return nil }

        return EnergyResourceUsage(
            pid: pid,
            energyNanojoules: info.ri_energy_nj,
            cpuTimeMach: info.ri_user_time.addingReportingOverflow(info.ri_system_time).partialValue,
            processStartMach: info.ri_proc_start_abstime,
            diskReadBytes: info.ri_diskio_bytesread,
            diskWrittenBytes: info.ri_diskio_byteswritten
        )
    }

    static func wattHours(fromNanojoules nanojoules: UInt64) -> Double {
        Double(nanojoules) / 3_600_000_000_000
    }

    static func sumEnergyNanojoules<S: Sequence>(_ samples: S) -> UInt64 where S.Element == EnergyResourceUsage {
        samples.reduce(UInt64(0)) { total, sample in
            total.addingReportingOverflow(sample.energyNanojoules).partialValue
        }
    }

    private static func resourceUsagesByPID(for processIDs: [Int32]) -> [Int32: EnergyResourceUsage] {
        Dictionary(uniqueKeysWithValues: processIDs.compactMap { pid in
            guard let usage = resourceUsage(pid: pid) else { return nil }
            return (pid, usage)
        })
    }

    private struct EnergyProcessMeasurement {
        let powerWatts: Double
        let usesMeasuredPower: Bool
        let cpuCoreUtilization: Double
        let diskReadBytesPerSecond: Int64
        let diskWriteBytesPerSecond: Int64
    }

    private static func currentEnergyMeasurements(
        firstResourceSamples: [Int32: EnergyResourceUsage],
        latestResourceSamples: [Int32: EnergyResourceUsage],
        sampleSeconds: TimeInterval,
        hasEnergyCounters: Bool
    ) -> [Int32: EnergyProcessMeasurement] {
        guard sampleSeconds > 0 else { return [:] }
        var measurementsByPID: [Int32: EnergyProcessMeasurement] = [:]

        for (pid, latestSample) in latestResourceSamples {
            guard let firstSample = firstResourceSamples[pid],
                  latestSample.processStartMach == firstSample.processStartMach else {
                continue
            }

            let hasMeasuredPower = hasEnergyCounters
                && latestSample.energyNanojoules >= firstSample.energyNanojoules
            let deltaNanojoules = hasMeasuredPower
                ? latestSample.energyNanojoules - firstSample.energyNanojoules
                : 0
            let deltaCPUMach = latestSample.cpuTimeMach >= firstSample.cpuTimeMach
                ? latestSample.cpuTimeMach - firstSample.cpuTimeMach
                : 0
            measurementsByPID[pid] = EnergyProcessMeasurement(
                powerWatts: watts(fromNanojoules: deltaNanojoules, over: sampleSeconds),
                usesMeasuredPower: hasMeasuredPower,
                cpuCoreUtilization: machTimeSeconds(deltaCPUMach) / sampleSeconds,
                diskReadBytesPerSecond: byteRate(
                    previous: firstSample.diskReadBytes,
                    current: latestSample.diskReadBytes,
                    over: sampleSeconds
                ),
                diskWriteBytesPerSecond: byteRate(
                    previous: firstSample.diskWrittenBytes,
                    current: latestSample.diskWrittenBytes,
                    over: sampleSeconds
                )
            )
        }

        return measurementsByPID
    }

    static func watts(fromNanojoules nanojoules: UInt64, over seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(nanojoules) / 1_000_000_000 / seconds
    }

    static func byteRate(previous: UInt64, current: UInt64, over seconds: TimeInterval) -> Int64 {
        guard seconds > 0, current >= previous else { return 0 }
        let rate = Double(current - previous) / seconds
        guard rate.isFinite, rate > 0 else { return 0 }
        return Int64(min(Double(Int64.max), rate.rounded()))
    }

    static func calibratedWattsPerCore(
        measuredEnergyNanojoules: UInt64,
        cpuTimeSeconds: TimeInterval,
        fallback: Double
    ) -> Double {
        guard cpuTimeSeconds >= 1, measuredEnergyNanojoules > 0 else {
            return fallback
        }
        let joulesPerCPUSecond = Double(measuredEnergyNanojoules) / 1_000_000_000 / cpuTimeSeconds
        guard joulesPerCPUSecond.isFinite else { return fallback }
        return min(12, max(0.08, joulesPerCPUSecond))
    }

    static func secondsFromMachTime(
        _ machTime: UInt64,
        numerator: UInt32,
        denominator: UInt32
    ) -> TimeInterval {
        guard denominator > 0 else { return 0 }
        return Double(machTime) * Double(numerator) / Double(denominator) / 1_000_000_000
    }

    private static func machTimeSeconds(_ machTime: UInt64) -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return secondsFromMachTime(
            machTime,
            numerator: timebase.numer,
            denominator: timebase.denom
        )
    }

    private struct PreparedEnergyProcess {
        let row: EnergyProcessRow
        let presentation: EnergyProcessPresentation
    }

    private struct EnergyAppAccumulator {
        var name: String
        var path: String
        var iconPath: String
        var bundlePath: String?
        var bundleIdentifier: String?
        var cpuPercent: Double = 0
        var residentBytes: Int64 = 0
        var cumulativeCPUSeconds: TimeInterval = 0
        var measuredEnergyNanojoules: UInt64 = 0
        var estimatedSupplementJoules: Double = 0
        var measuredProcessCount = 0
        var currentPowerWatts: Double = 0
        var diskReadBytesPerSecond: Int64 = 0
        var diskWriteBytesPerSecond: Int64 = 0
        var longestRunningSeconds: TimeInterval?
        var processIDs: [Int32] = []
        var isApplication = false

        mutating func add(
            _ row: EnergyProcessRow,
            resourceUsage: EnergyResourceUsage?,
            currentMeasurement: EnergyProcessMeasurement?,
            calibration: EnergyCalibration
        ) {
            cpuPercent += row.cpuPercent
            residentBytes += row.residentBytes
            let processCPUSeconds = max(0, row.cpuTimeSeconds)
            cumulativeCPUSeconds += processCPUSeconds
            if let resourceUsage {
                measuredEnergyNanojoules = measuredEnergyNanojoules
                    .addingReportingOverflow(resourceUsage.energyNanojoules)
                    .partialValue
                measuredProcessCount += 1
            } else {
                estimatedSupplementJoules += processCPUSeconds * calibration.cumulativeWattsPerCore
            }
            if let currentMeasurement, currentMeasurement.usesMeasuredPower {
                currentPowerWatts += max(0, currentMeasurement.powerWatts)
            } else {
                currentPowerWatts += max(0, row.cpuPercent) / 100 * calibration.currentWattsPerCore
            }
            if let currentMeasurement {
                diskReadBytesPerSecond = diskReadBytesPerSecond
                    .addingReportingOverflow(max(0, currentMeasurement.diskReadBytesPerSecond))
                    .partialValue
                diskWriteBytesPerSecond = diskWriteBytesPerSecond
                    .addingReportingOverflow(max(0, currentMeasurement.diskWriteBytesPerSecond))
                    .partialValue
            }
            if let elapsedSeconds = row.elapsedSeconds {
                longestRunningSeconds = max(longestRunningSeconds ?? 0, elapsedSeconds)
            }
            processIDs.append(row.pid)
        }

        func app(
            uptimeSeconds: TimeInterval
        ) -> EnergyImpactApp {
            let measuredEnergyWh = EnergyImpactService.wattHours(fromNanojoules: measuredEnergyNanojoules)
            let estimatedSupplementEnergyWh = max(0, estimatedSupplementJoules) / 3_600
            let estimatedEnergyWh = measuredEnergyWh + estimatedSupplementEnergyWh
            let averageWindowSeconds = max(longestRunningSeconds ?? uptimeSeconds, 1)
            let averagePowerWatts = estimatedEnergyWh / max(averageWindowSeconds / 3_600, 1 / 3_600)

            return EnergyImpactApp(
                id: path,
                name: name,
                path: path,
                iconPath: iconPath,
                bundlePath: bundlePath,
                bundleIdentifier: bundleIdentifier,
                measuredEnergyWh: measuredEnergyWh,
                estimatedSupplementEnergyWh: estimatedSupplementEnergyWh,
                estimatedEnergyWh: estimatedEnergyWh,
                currentPowerWatts: currentPowerWatts,
                averagePowerWatts: averagePowerWatts,
                cpuPercent: cpuPercent,
                diskReadBytesPerSecond: diskReadBytesPerSecond,
                diskWriteBytesPerSecond: diskWriteBytesPerSecond,
                residentBytes: residentBytes,
                cumulativeCPUSeconds: cumulativeCPUSeconds,
                longestRunningSeconds: longestRunningSeconds,
                processCount: processIDs.count,
                measuredProcessCount: measuredProcessCount,
                processIDs: processIDs.sorted(),
                isApplication: isApplication
            )
        }
    }

    private struct EnergyProcessPresentation {
        let name: String
        let groupKey: String
        let groupPath: String
        let iconPath: String
        let bundlePath: String?
        let bundleIdentifier: String?
        let isApplication: Bool
    }

    private struct EnergyCalibration {
        let cumulativeWattsPerCore: Double
        let currentWattsPerCore: Double
        let usesLocalCalibration: Bool
    }

    private static func applicationProcesses(from processRows: [EnergyProcessRow]) -> [PreparedEnergyProcess] {
        let processRowsByPID = Dictionary(uniqueKeysWithValues: processRows.map { ($0.pid, $0) })
        return processRows.compactMap { row in
            guard !row.path.trimmed.isEmpty else { return nil }
            let presentation = presentation(for: row, processRowsByPID: processRowsByPID)
            guard presentation.isApplication else { return nil }
            return PreparedEnergyProcess(row: row, presentation: presentation)
        }
    }

    private static func groupedApps(
        processes: [PreparedEnergyProcess],
        resourceSamples: [Int32: EnergyResourceUsage],
        currentMeasurements: [Int32: EnergyProcessMeasurement],
        uptimeSeconds: TimeInterval,
        calibration: EnergyCalibration
    ) -> [EnergyImpactApp] {
        var groups: [String: EnergyAppAccumulator] = [:]

        for process in processes {
            let row = process.row
            let presentation = process.presentation
            var accumulator = groups[presentation.groupKey] ?? EnergyAppAccumulator(
                name: presentation.name,
                path: presentation.groupPath,
                iconPath: presentation.iconPath,
                bundlePath: presentation.bundlePath,
                bundleIdentifier: presentation.bundleIdentifier,
                isApplication: presentation.isApplication
            )
            accumulator.add(
                row,
                resourceUsage: resourceSamples[row.pid],
                currentMeasurement: currentMeasurements[row.pid],
                calibration: calibration
            )
            groups[presentation.groupKey] = accumulator
        }

        return groups.values
            .map { $0.app(uptimeSeconds: uptimeSeconds) }
            .sorted(by: sortByImpact)
    }

    private static func presentation(
        for row: EnergyProcessRow,
        processRowsByPID: [Int32: EnergyProcessRow]
    ) -> EnergyProcessPresentation {
        if let appBundlePath = appBundlePath(in: row.path) {
            return appPresentation(appURL: URL(fileURLWithPath: appBundlePath))
        }

        if let parentAppURL = parentApplicationURL(for: row, processRowsByPID: processRowsByPID) {
            return appPresentation(appURL: parentAppURL)
        }

        let runningApp = NSRunningApplication(processIdentifier: row.pid)
        let executablePath = runningApp?.executableURL?.path ?? row.path

        if let appBundlePath = appBundlePath(in: executablePath) {
            return appPresentation(
                appURL: URL(fileURLWithPath: appBundlePath),
                fallbackName: runningApp?.localizedName,
                fallbackBundleIdentifier: runningApp?.bundleIdentifier
            )
        }

        if let bundleURL = runningApp?.bundleURL {
            return appPresentation(
                appURL: bundleURL,
                fallbackName: runningApp?.localizedName,
                fallbackBundleIdentifier: runningApp?.bundleIdentifier
            )
        }

        for bundleIdentifier in bundleIdentifierCandidates(from: row.path) {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return appPresentation(
                    appURL: appURL,
                    fallbackBundleIdentifier: bundleIdentifier
                )
            }
        }

        return EnergyProcessPresentation(
            name: displayName(from: executablePath),
            groupKey: "process:\(executablePath)",
            groupPath: executablePath,
            iconPath: executablePath,
            bundlePath: nil,
            bundleIdentifier: nil,
            isApplication: false
        )
    }

    private static func appPresentation(
        appURL: URL,
        fallbackName: String? = nil,
        fallbackBundleIdentifier: String? = nil
    ) -> EnergyProcessPresentation {
        let canonicalAppURL = appBundlePath(in: appURL.path)
            .map { URL(fileURLWithPath: $0) }
            ?? appURL
        let bundle = Bundle(url: canonicalAppURL)
        let bundleIdentifier = bundle?.bundleIdentifier?.nonEmpty ?? fallbackBundleIdentifier
        let displayName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)?.nonEmpty
            ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)?.nonEmpty
            ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)?.nonEmpty
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)?.nonEmpty
            ?? fallbackName?.nonEmpty
            ?? canonicalAppURL.deletingPathExtension().lastPathComponent
        let appPath = canonicalAppURL.path
        let groupKey = softwareGroupKey(appPath: appPath, bundleIdentifier: bundleIdentifier)

        return EnergyProcessPresentation(
            name: displayName,
            groupKey: groupKey,
            groupPath: appPath,
            iconPath: appPath,
            bundlePath: appPath,
            bundleIdentifier: bundleIdentifier,
            isApplication: isUserFacingApplicationPath(appPath)
        )
    }

    private static func isUserFacingApplicationPath(_ path: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardizedPath.hasSuffix(".app") else { return false }
        return !standardizedPath.hasPrefix("/System/Library/")
    }

    private static func parentApplicationURL(
        for row: EnergyProcessRow,
        processRowsByPID: [Int32: EnergyProcessRow]
    ) -> URL? {
        var visitedPIDs: Set<Int32> = [row.pid]
        var parentPID = row.parentPID

        for _ in 0..<8 {
            guard parentPID > 1, !visitedPIDs.contains(parentPID) else { return nil }
            visitedPIDs.insert(parentPID)

            if let parentRow = processRowsByPID[parentPID] {
                if let appBundlePath = appBundlePath(in: parentRow.path) {
                    return URL(fileURLWithPath: appBundlePath)
                }
                parentPID = parentRow.parentPID
                continue
            }

            return NSRunningApplication(processIdentifier: parentPID)?.bundleURL
        }

        return nil
    }

    static func appBundlePath(in path: String) -> String? {
        let trimmedPath = path.trimmed
        guard trimmedPath.contains(".app") else { return nil }

        var collectedComponents: [String] = []
        for component in URL(fileURLWithPath: trimmedPath).pathComponents {
            collectedComponents.append(component)
            if component.hasSuffix(".app") {
                return NSString.path(withComponents: collectedComponents)
            }
        }
        return nil
    }

    static func bundleIdentifierCandidate(from value: String) -> String? {
        bundleIdentifierCandidates(from: value).first
    }

    static func bundleIdentifierCandidates(from value: String) -> [String] {
        let trimmedValue = value.trimmed
        guard !trimmedValue.isEmpty else { return [] }

        var candidates: [String] = []
        let tokens = trimmedValue
            .split(separator: "/")
            .map(String.init)
            .flatMap { token in
                token.split(separator: " ").map(String.init)
            }

        for token in tokens {
            let cleanedToken = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]{}"))
            guard cleanedToken.hasPrefix("com.") else { continue }
            appendBundleIdentifierCandidates(from: cleanedToken, into: &candidates)
        }

        return candidates
    }

    private static func appendBundleIdentifierCandidates(from value: String, into candidates: inout [String]) {
        let parts = value.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return }

        for count in stride(from: parts.count, through: 3, by: -1) {
            let candidate = parts.prefix(count).joined(separator: ".")
            guard !candidates.contains(candidate) else { continue }
            candidates.append(candidate)
        }
    }

    private static func displayName(from path: String) -> String {
        let lastComponent = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return lastComponent.nonEmpty ?? L10n.text("未知进程", "Unknown Process")
    }

    private static func sortByImpact(_ lhs: EnergyImpactApp, _ rhs: EnergyImpactApp) -> Bool {
        if lhs.estimatedEnergyWh != rhs.estimatedEnergyWh {
            return lhs.estimatedEnergyWh > rhs.estimatedEnergyWh
        }
        if lhs.currentPowerWatts != rhs.currentPowerWatts {
            return lhs.currentPowerWatts > rhs.currentPowerWatts
        }
        if lhs.cumulativeCPUSeconds != rhs.cumulativeCPUSeconds {
            return lhs.cumulativeCPUSeconds > rhs.cumulativeCPUSeconds
        }
        if lhs.cpuPercent != rhs.cpuPercent {
            return lhs.cpuPercent > rhs.cpuPercent
        }
        if lhs.name != rhs.name {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    static func softwareGroupKey(appPath: String, bundleIdentifier: String?) -> String {
        if let bundleIdentifier = bundleIdentifier?.nonEmpty {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        return "app:\(appPath)"
    }

    private static func energyCalibration(
        processes: [PreparedEnergyProcess],
        resourceSamples: [Int32: EnergyResourceUsage],
        currentMeasurements: [Int32: EnergyProcessMeasurement]
    ) -> EnergyCalibration {
        let fallback = defaultWattsPerCore
        var measuredEnergyNanojoules: UInt64 = 0
        var measuredCPUSeconds: TimeInterval = 0

        for process in processes {
            guard let usage = resourceSamples[process.row.pid] else { continue }
            measuredEnergyNanojoules = measuredEnergyNanojoules
                .addingReportingOverflow(usage.energyNanojoules)
                .partialValue
            measuredCPUSeconds += max(0, process.row.cpuTimeSeconds)
        }

        let hasCumulativeCalibration = measuredEnergyNanojoules > 0 && measuredCPUSeconds >= 1
        let cumulativeWattsPerCore = calibratedWattsPerCore(
            measuredEnergyNanojoules: measuredEnergyNanojoules,
            cpuTimeSeconds: measuredCPUSeconds,
            fallback: fallback
        )

        let measuredCurrentSamples = currentMeasurements.values.filter(\.usesMeasuredPower)
        let sampledPowerWatts = measuredCurrentSamples.reduce(0) { $0 + $1.powerWatts }
        let sampledCoreUtilization = measuredCurrentSamples.reduce(0) { $0 + $1.cpuCoreUtilization }
        let hasCurrentCalibration = sampledPowerWatts > 0 && sampledCoreUtilization >= 0.02
        let sampledWattsPerCore = hasCurrentCalibration
            ? min(12, max(0.08, sampledPowerWatts / sampledCoreUtilization))
            : cumulativeWattsPerCore
        let currentWattsPerCore = hasCurrentCalibration
            ? sampledWattsPerCore * 0.65 + cumulativeWattsPerCore * 0.35
            : cumulativeWattsPerCore

        return EnergyCalibration(
            cumulativeWattsPerCore: cumulativeWattsPerCore,
            currentWattsPerCore: currentWattsPerCore,
            usesLocalCalibration: hasCumulativeCalibration || hasCurrentCalibration
        )
    }

    private static var defaultWattsPerCore: Double {
#if arch(arm64)
        0.55
#else
        1.25
#endif
    }
}
