#if DEBUG
import Foundation
import SwiftUI

/// Inert values for the production B3 views. No scans, quit requests, file
/// operations or helper demand. This file is absent from both Release and Beta.
enum LightfieldPerformanceFixture {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    private static let gib: Int64 = 1_073_741_824
    private static let mib: Int64 = 1_048_576
    static let memory: MemorySnapshot = {
        let physical = 32 * gib
        let used = Int64(Double(physical) * 0.581)
        let cache = Int64(4.2 * Double(gib))
        let swap = Int64(0.8 * Double(gib))
        return MemorySnapshot(generatedAt: date, physicalBytes: physical, freeBytes: physical - used - cache,
            inactiveBytes: 0, speculativeBytes: 0, fileBackedBytes: cache, purgeableBytes: 0,
            wiredBytes: 2 * gib, compressedBytes: gib, swapUsedBytes: swap,
            pressureFreePercentage: nil, pressureSummary: "FIXTURE", topProcesses: memoryProcesses,
            measurements: .init(pressure: .available(.normal), physicalBytes: .available(UInt64(physical)),
                availableBytes: .available(UInt64(physical - used)), appBytes: .available(UInt64(used - 3 * gib)),
                wiredBytes: .available(UInt64(2 * gib)), compressedBytes: .available(UInt64(gib)),
                cachedBytes: .available(UInt64(cache)), swapUsedBytes: .available(UInt64(swap)),
                swapInRate: .available(0), swapOutRate: .available(0)))
    }()
    static let memoryProcesses: [MemoryProcess] = [
        process(6501, "Google Chrome", bundle: "Google Chrome", bytes: 128 * mib),
        process(6502, "Google Chrome Helper (Renderer)", bundle: "Google Chrome", bytes: 942 * mib),
        process(6503, "Google Chrome Helper (GPU)", bundle: "Google Chrome", bytes: 553 * mib),
        process(6504, "Google Chrome Helper", bundle: "Google Chrome", bytes: 287 * mib),
        process(7801, "ChatGPT", bundle: "ChatGPT", bytes: 1100 * mib),
        process(7802, "ChatGPT Helper", bundle: "ChatGPT", bytes: 128 * mib),
        process(8101, "Safari", bundle: "Safari", bytes: 900 * mib),
        process(8301, "Xcode", bundle: "Xcode", bytes: 600 * mib),
        process(8601, "Obsidian", bundle: "Obsidian", bytes: 512 * mib),
        process(8701, "kernel_task", bundle: nil, bytes: 400 * mib)
    ]
    private static func process(_ id: Int32, _ name: String, bundle: String?, bytes: Int64) -> MemoryProcess {
        let bundlePath = bundle.map { "/Applications/" + $0 + ".app" }
        let path = bundlePath.map { $0 + "/Contents/MacOS/" + name } ?? "/usr/libexec/" + name
        return MemoryProcess(id: id, name: name, path: path, iconPath: bundlePath ?? "", bundlePath: bundlePath,
            residentBytes: bytes, percent: Double(bytes) / Double(32 * gib) * 100, canQuit: bundle != nil && !name.contains("Helper"),
            bundleIdentifier: bundle.map { "invalid.lightfield." + $0.replacingOccurrences(of: " ", with: "") },
            capturedAt: date, dataSource: .procPIDRUsage)
    }
    static let trend: [MenuBarTelemetryPoint] = (0..<24).map { index in
        let percent = [42.0, 46, 48, 47, 53, 59, 65, 62, 56, 54, 59, 69, 76, 70, 62, 59, 51, 49, 53, 57, 59, 57, 56, 58.1][index]
        return MenuBarTelemetryPoint(date: date.addingTimeInterval(Double(index - 23) * 5), cpuTotal: nil,
            cpuUser: nil, cpuSystem: nil, gpu: nil, memory: percent, memoryPressure: nil, memoryPressureLevelCode: 1,
            chipTemperature: nil, gpuTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
    }
    static let energy: EnergyImpactSnapshot = {
        let apps = [energyApp("chrome", name: "Google Chrome", ids: [6501, 6502, 6503, 6504], energy: 4.8, watts: 3.1, average: 2.4, cpu: 18),
            energyApp("xcode", name: "Xcode", ids: [8301], energy: 3.6, watts: 2.4, average: 1.8, cpu: 12.4),
            energyApp("music", name: "Music", ids: [8901, 8902], energy: 2.2, watts: 1.2, average: 1.1, cpu: 6),
            energyApp("photos", name: "Photos", ids: [8801], energy: 1.6, watts: 0.4, average: 0.8, cpu: 1.8),
            energyApp("obsidian", name: "Obsidian", ids: [8601], energy: 0.8, watts: 0.3, average: 0.5, cpu: 1),
            energyApp("chatgpt", name: "ChatGPT", ids: [7801, 7802], energy: 0.6, watts: 0.75, average: 0.4, cpu: 3.1)]
        return EnergyImpactSnapshot(generatedAt: date, scanSeconds: 3, sampleSeconds: 2, uptimeSeconds: 30_240,
            apps: apps, processCount: apps.reduce(0) { $0 + $1.processCount },
            measuredProcessCount: apps.reduce(0) { $0 + $1.measuredProcessCount }, unmeasuredProcessCount: 0,
            measuredTotalEnergyWh: apps.reduce(0) { $0 + $1.measuredEnergyWh }, estimatedSupplementEnergyWh: 0,
            calibrationWattsPerCore: 2, usesLocalCalibration: true)
    }()
    private static func energyApp(_ id: String, name: String, ids: [Int32], energy: Double, watts: Double, average: Double, cpu: Double) -> EnergyImpactApp {
        EnergyImpactApp(id: "lightfield-" + id, name: name, path: "/Applications/" + name + ".app/Contents/MacOS/" + name,
            iconPath: "/Applications/" + name + ".app", bundlePath: "/Applications/" + name + ".app", bundleIdentifier: "invalid.lightfield." + id,
            measuredEnergyWh: energy, estimatedSupplementEnergyWh: 0, estimatedEnergyWh: energy,
            currentPowerWatts: watts, averagePowerWatts: average, cpuPercent: cpu,
            diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, residentBytes: 0, cumulativeCPUSeconds: 180,
            longestRunningSeconds: 3600, processCount: ids.count, measuredProcessCount: ids.count,
            processIDs: ids, isApplication: true, currentMeasuredProcessCount: ids.count, sampledAt: date, currentSampleSeconds: 2)
    }
    static func energyProcessNames(_ app: EnergyImpactApp) -> [Int32: String] {
        Dictionary(uniqueKeysWithValues: app.processIDs.map { id in
            let process = memoryProcesses.first { $0.id == id }
            return (id, process.map { LightfieldPerformancePresentation.processName(name: $0.name, path: $0.path, application: app.name) } ?? app.name)
        })
    }
}
#endif
