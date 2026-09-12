import FanControlShared
import AppKit
import os

enum PerformanceTelemetry {
    static let logger = Logger(
        subsystem: StorageCleanerBuildIdentity.appBundleIdentifier,
        category: "Performance"
    )
    static let signposter = OSSignposter(logger: logger)

    // Explicit, bounded, data-only audit of the production publishing path.
    // No fixture switch, extra sampler, process names, paths or network identity.
    @MainActor private static var auditCount = 0
    @MainActor private static let auditURL: URL? = {
#if DEBUG || STORAGE_CLEANER_BETA
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--telemetry-audit=") }) else { return nil }
        let path = String(argument.dropFirst("--telemetry-audit=".count))
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
#else
        return nil
#endif
    }()

    @MainActor
    static func samplePublished(_ snapshot: SystemMonitorSnapshot, interval: TimeInterval, memorySnapshot: MemorySnapshot?) {
        guard let auditURL, auditCount < 240 else { return }
        let point = MenuBarTelemetryPoint(snapshot: snapshot)
        var sample: [String: Any] = [
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "source": "SystemMonitorService", "sampleAt": snapshot.generatedAt.timeIntervalSince1970,
            "publishedAt": Date().timeIntervalSince1970, "requestedIntervalSeconds": interval
        ]
#if DEBUG || STORAGE_CLEANER_BETA
        sample["mode"] = MiniWindowDemoData.isEnabled ? "FIXTURE" : "LIVE"
#endif
        sample["memorySampleAt"] = memorySnapshot?.generatedAt.timeIntervalSince1970
        if let memorySnapshot {
            let composition = memorySnapshot.ringComposition
            sample["memorySource"] = "MemorySnapshot.ringComposition"
            sample["memoryPhysicalBytes"] = composition?.physicalBytes
            sample["memoryAppOrOtherBytes"] = composition?.appOrOtherBytes
            sample["memoryWiredBytes"] = composition?.wiredBytes
            sample["memoryCompressedBytes"] = composition?.compressedBytes
            sample["memoryUsedPercent"] = memorySnapshot.measuredUsedRatio.map { $0 * 100 }
        }
        sample["cpuTotal"] = point.cpuTotal
        sample["cpuUser"] = point.cpuUser
        sample["cpuSystem"] = point.cpuSystem
        sample["gpu"] = point.gpu
        sample["memoryPercent"] = point.memory
        sample["fanRPM"] = point.fanRPM
        sample["downloadBytesPerSecond"] = point.downBytesPerSecond
        sample["uploadBytesPerSecond"] = point.upBytesPerSecond
        guard var data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if auditCount == 0 {
            // Never overwrite a prior evidence file.
            guard !FileManager.default.fileExists(atPath: auditURL.path),
                  FileManager.default.createFile(atPath: auditURL.path, contents: nil) else {
                auditCount = 240; return
            }
        }
        do {
            let file = try FileHandle(forWritingTo: auditURL)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
            auditCount += 1
        } catch { auditCount = 240 }
    }

    /// Interaction-only diagnostics: no readings, file paths, or pointer polling.
    @MainActor
    static func panelInput(_ phase: String, target: String, window: NSWindow? = nil, event: NSEvent? = nil) {
#if DEBUG || STORAGE_CLEANER_BETA
        let input = event ?? NSApp?.currentEvent
        let eventType = input.map { String(describing: $0.type) } ?? "none"
        let timestamp = input?.timestamp ?? 0
        let windowNumber = window?.windowNumber ?? input?.windowNumber ?? -1
        let active = NSApp?.isActive ?? false
        let key = window?.isKeyWindow ?? false
        logger.notice("PanelInput phase=\(phase, privacy: .public) target=\(target, privacy: .public) event=\(eventType, privacy: .public) time=\(timestamp) window=\(windowNumber) appActive=\(active) key=\(key)")
#endif
    }
}
