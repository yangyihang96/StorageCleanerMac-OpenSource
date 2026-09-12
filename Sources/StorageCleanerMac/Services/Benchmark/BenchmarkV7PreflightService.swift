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
    static let minimumAvailableMemoryBytes: UInt64 = 1 * 1_024 * 1_024 * 1_024

    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.now = now
        self.sleep = sleep
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
        let firstLoad = backgroundLoadRatio()
        let memorySnapshot = await SystemMemoryProbe.shared.snapshot(includeProcesses: false)
        let availableMemoryBytes = memorySnapshot.measurements.availableBytes.value
        let display = await MainActor.run { displayDescription() }
        let secondLoad: Double?
        do {
            try await sleep(.seconds(1))
            secondLoad = backgroundLoadRatio()
        } catch {
            secondLoad = nil
        }
        let backgroundLoad = [firstLoad, secondLoad].compactMap { $0 }.max()

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
        if let backgroundLoad,
           backgroundLoad.isFinite,
           backgroundLoad >= Self.highBackgroundLoadRatio {
            checks.append(check(
                .highBackgroundLoad,
                .warning,
                "Observed background load is \(Int((backgroundLoad * 100).rounded()))% of active processors."
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
            blockedCategories: blocked.sorted { $0.rawValue < $1.rawValue }
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

    private func backgroundLoadRatio() -> Double? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, Int32(values.count)) > 0 else { return nil }
        let processors = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let ratio = values[0] / Double(processors)
        return ratio.isFinite && ratio >= 0 ? ratio : nil
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
