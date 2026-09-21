import Foundation

struct MemoryProcess: Identifiable, Hashable, Sendable {
    let id: Int32
    let name: String
    let path: String
    let iconPath: String
    let bundlePath: String?
    let residentBytes: Int64
    let percent: Double
    let canQuit: Bool
    var isActive = false
    var bundleIdentifier: String? = nil
    var launchDate: Date? = nil
    var userIdentifier: UInt32 = 0
    var capturedAt: Date = Date()
    var dataSource: ProcessMemoryDataSource = .legacyResidentSet
    var availability: MeasurementAvailability = .available

    var identity: MemoryProcessIdentity {
        MemoryProcessIdentity(
            processIdentifier: id,
            bundleIdentifier: bundleIdentifier,
            launchDate: launchDate,
            executablePath: path,
            bundlePath: bundlePath,
            userIdentifier: userIdentifier
        )
    }

    var isUserApplication: Bool {
        guard let bundlePath else { return false }
        return bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix("\(PathSafety.homePath)/Applications/")
    }

    var processKindTitle: String {
        !isUserApplication
            ? L10n.text("系统进程", "System Process")
            : L10n.text("应用程序", "Application")
    }

    var quitHint: String {
        canQuit
            ? L10n.text("会请求应用正常退出，不会强制结束。", "Requests a normal quit and does not force quit.")
            : L10n.text("系统进程或非应用进程只展示占用，不提供退出。", "System or non-app processes are shown for context and cannot be quit here.")
    }

    var memoryShareTitle: String {
        String(format: "%.1f%%", percent)
    }

    var isRecommendedQuitCandidate: Bool {
        canQuit && residentBytes >= 384 * 1024 * 1024
    }

    var quitImpactTitle: String {
        guard canQuit else {
            return L10n.text("仅查看", "Read-only")
        }
        if residentBytes >= 1_500 * 1024 * 1024 {
            return L10n.text("高收益", "High impact")
        }
        if residentBytes >= 768 * 1024 * 1024 {
            return L10n.text("中等收益", "Medium impact")
        }
        return L10n.text("低收益", "Low impact")
    }
}

enum MemoryCleanupPrimaryAction: Sendable, Equatable {
    case observe
    case quitHighUsageApps
}

struct MemoryCleanupPlan: Sendable, Equatable {
    let primaryAction: MemoryCleanupPrimaryAction
    let title: String
    let detail: String
    let estimatedRecoverableBytes: Int64
}

struct MemoryAppUsage: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let iconPath: String
    let bundlePath: String?
    let bytes: Int64
    let canQuit: Bool
    let isActive: Bool
    let percent: Double
    let processCount: Int
    let processIDs: [Int32]
    let selectableProcessIDs: [Int32]

    var shouldAvoidQuitRecommendation: Bool {
        let bundleIdentifier = bundlePath.flatMap { Bundle(path: $0)?.bundleIdentifier } ?? ""
        let identity = "\(name) \(bundleIdentifier)".folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ).lowercased()
        return Self.protectedRecommendationTokens.contains { identity.contains($0) }
    }

    private static let protectedRecommendationTokens = [
        "wechat", "weixin", "微信", "com.tencent.xin", "com.tencent.qq", " qq",
        "whatsapp", "telegram", "signal", "discord", "slack", "teams",
        "dingtalk", "钉钉", "lark", "feishu", "飞书", "zoom", "messenger",
        "outlook", "mail", "onedrive", "dropbox", "google drive", "googledrive",
        "syncthing", "resilio", "1password", "bitwarden", "tailscale", "zerotier",
    ]
}

/// A point-in-time estimate captured before asking the user to confirm a quit.
///
/// `estimatedBytes` represents the complete application groups shown in the UI,
/// including helper processes. It is deliberately independent from the one or
/// more regular application instances used as safe quit targets for each group.
struct MemoryQuitSelectionSummary: Equatable, Sendable {
    let appCount: Int
    let estimatedBytes: Int64
}

private struct MemoryProcessAnalysis: Sendable {
    let processesByResidentUsage: [MemoryProcess]
    let selectableQuitProcesses: [MemoryProcess]
    let quitCandidates: [MemoryProcess]
    let appsByResidentUsage: [MemoryAppUsage]
    let quitCandidateApps: [MemoryAppUsage]
    let selectableQuitBytes: Int64
    let quitCandidateBytes: Int64
    let quitCandidateAppBytes: Int64
    let topProcessBytes: Int64

    init(topProcesses: [MemoryProcess], physicalBytes: Int64) {
        let orderedProcesses = topProcesses.sorted(by: Self.sortByResidentUsage)
        let selectableProcesses = orderedProcesses.filter(\.canQuit)
        let recommendedProcesses = orderedProcesses.filter(\.isRecommendedQuitCandidate)
        let grouped = Dictionary(grouping: orderedProcesses) { process in
            process.bundlePath ?? process.path
        }
        let orderedApps: [MemoryAppUsage] = grouped.compactMap { key, processes in
            let sortedProcesses = processes.sorted { lhs, rhs in
                if lhs.canQuit != rhs.canQuit {
                    return lhs.canQuit && !rhs.canQuit
                }
                if lhs.residentBytes != rhs.residentBytes {
                    return lhs.residentBytes > rhs.residentBytes
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            guard let representative = sortedProcesses.first else { return nil }
            let bytes = MemoryByteMath.sum(processes.map(\.residentBytes)).value
            let selectable = sortedProcesses.filter(\.canQuit).map(\.id)
            return MemoryAppUsage(
                id: key,
                name: representative.name,
                iconPath: representative.bundlePath ?? representative.iconPath,
                bundlePath: representative.bundlePath,
                bytes: bytes,
                canQuit: !selectable.isEmpty,
                isActive: processes.contains(where: \.isActive),
                percent: physicalBytes > 0 ? Double(bytes) / Double(physicalBytes) * 100 : 0,
                processCount: processes.count,
                processIDs: sortedProcesses.map(\.id),
                selectableProcessIDs: selectable
            )
        }
        .sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes {
                return lhs.bytes > rhs.bytes
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let threshold = Self.recommendedQuitThresholdBytes(physicalBytes: physicalBytes)
        let candidateApps = orderedApps.filter { app in
            app.canQuit
                && app.bundlePath?.hasSuffix(".app") == true
                && !app.isActive
                && app.bytes >= threshold
                && !app.shouldAvoidQuitRecommendation
        }

        processesByResidentUsage = orderedProcesses
        selectableQuitProcesses = selectableProcesses
        quitCandidates = recommendedProcesses
        appsByResidentUsage = orderedApps
        quitCandidateApps = candidateApps
        selectableQuitBytes = MemoryByteMath.sum(selectableProcesses.map(\.residentBytes)).value
        quitCandidateBytes = MemoryByteMath.sum(recommendedProcesses.map(\.residentBytes)).value
        quitCandidateAppBytes = MemoryByteMath.sum(candidateApps.map(\.bytes)).value
        topProcessBytes = MemoryByteMath.sum(topProcesses.map(\.residentBytes)).value
    }

    static func recommendedQuitThresholdBytes(physicalBytes: Int64) -> Int64 {
        max(512 * 1024 * 1024, min(1_500 * 1024 * 1024, physicalBytes / 64))
    }

    private static func sortByResidentUsage(_ lhs: MemoryProcess, _ rhs: MemoryProcess) -> Bool {
        if lhs.residentBytes != rhs.residentBytes {
            return lhs.residentBytes > rhs.residentBytes
        }
        if lhs.name != rhs.name {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}

struct MemoryRingComposition: Equatable, Sendable {
    let physicalBytes: UInt64
    let availableBytes: UInt64
    let usedBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let appOrOtherBytes: UInt64

    let availableRatio: Double
    let usedRatio: Double
    let wiredRatio: Double
    let compressedRatio: Double
    let appOrOtherRatio: Double

    init?(
        physicalBytes: UInt64,
        availableBytes rawAvailableBytes: UInt64,
        wiredBytes rawWiredBytes: UInt64,
        compressedBytes rawCompressedBytes: UInt64
    ) {
        guard physicalBytes > 0 else { return nil }

        let availableBytes = min(rawAvailableBytes, physicalBytes)
        let usedBytes = physicalBytes - availableBytes
        let wiredBytes = min(rawWiredBytes, usedBytes)
        let compressedBytes = min(rawCompressedBytes, usedBytes - wiredBytes)
        let appOrOtherBytes = usedBytes - wiredBytes - compressedBytes
        let physical = Double(physicalBytes)
        let usedRatio = Double(usedBytes) / physical
        let wiredRatio = min(usedRatio, Double(wiredBytes) / physical)
        let remainingAfterWired = max(0, usedRatio - wiredRatio)
        let compressedRatio = min(
            remainingAfterWired,
            Double(compressedBytes) / physical
        )

        self.physicalBytes = physicalBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.appOrOtherBytes = appOrOtherBytes
        self.usedRatio = usedRatio
        availableRatio = max(0, 1 - usedRatio)
        self.wiredRatio = wiredRatio
        self.compressedRatio = compressedRatio
        appOrOtherRatio = max(0, remainingAfterWired - compressedRatio)
    }
}

struct MemorySnapshot: Sendable {
    let generatedAt: Date
    let capturedInstant: ContinuousClock.Instant?
    let physicalBytes: Int64
    let freeBytes: Int64
    let inactiveBytes: Int64
    let speculativeBytes: Int64
    let fileBackedBytes: Int64
    let purgeableBytes: Int64
    let wiredBytes: Int64
    let compressedBytes: Int64
    let swapUsedBytes: Int64
    let swapTotalBytes: Int64
    let pageInsCount: Int64
    let pageOutsCount: Int64
    let pressureFreePercentage: Int?
    let pressureSummary: String
    let topProcesses: [MemoryProcess]
    let measurements: MemoryMeasurements
    let quality: MeasurementQuality
    let warnings: [MeasurementWarning]
    private let processAnalysis: MemoryProcessAnalysis

    init(
        generatedAt: Date,
        capturedInstant: ContinuousClock.Instant? = nil,
        physicalBytes: Int64,
        freeBytes: Int64,
        inactiveBytes: Int64,
        speculativeBytes: Int64,
        fileBackedBytes: Int64,
        purgeableBytes: Int64,
        wiredBytes: Int64,
        compressedBytes: Int64,
        swapUsedBytes: Int64,
        pressureFreePercentage: Int?,
        pressureSummary: String,
        topProcesses: [MemoryProcess],
        swapTotalBytes: Int64 = 0,
        pageInsCount: Int64 = 0,
        pageOutsCount: Int64 = 0,
        measurements: MemoryMeasurements? = nil,
        quality: MeasurementQuality = .complete,
        warnings: [MeasurementWarning] = []
    ) {
        self.generatedAt = generatedAt
        self.capturedInstant = capturedInstant
        self.physicalBytes = physicalBytes
        self.freeBytes = freeBytes
        self.inactiveBytes = inactiveBytes
        self.speculativeBytes = speculativeBytes
        self.fileBackedBytes = fileBackedBytes
        self.purgeableBytes = purgeableBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = max(swapUsedBytes, swapTotalBytes)
        self.pageInsCount = max(0, pageInsCount)
        self.pageOutsCount = max(0, pageOutsCount)
        self.pressureFreePercentage = pressureFreePercentage
        self.pressureSummary = pressureSummary
        self.topProcesses = topProcesses
        let appBytes = MemoryByteMath.sum(topProcesses.map(\.residentBytes)).value
        let cachedBytes = max(0, max(fileBackedBytes, purgeableBytes))
        self.measurements = measurements ?? .legacyAvailable(
            physicalBytes: physicalBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedBytes: cachedBytes,
            swapUsedBytes: swapUsedBytes
        )
        self.quality = quality
        self.warnings = warnings
        processAnalysis = MemoryProcessAnalysis(
            topProcesses: topProcesses,
            physicalBytes: physicalBytes
        )
    }

    var cachedEstimateBytes: Int64 {
        max(0, max(fileBackedBytes, purgeableBytes))
    }

    var availableBytes: Int64 {
        min(physicalBytes, MemoryByteMath.add(freeBytes, cachedEstimateBytes).value)
    }

    var usedBytes: Int64 {
        max(0, physicalBytes - availableBytes)
    }

    var measuredUsedBytes: UInt64? {
        guard let physical = measurements.physicalBytes.value,
              let available = measurements.availableBytes.value,
              available <= physical else { return nil }
        return physical - available
    }

    var measuredUsedRatio: Double? {
        guard let physical = measurements.physicalBytes.value,
              let used = measuredUsedBytes,
              physical > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(physical)))
    }

    var measuredAvailableRatio: Double? {
        guard let physical = measurements.physicalBytes.value,
              let available = measurements.availableBytes.value,
              physical > 0 else { return nil }
        return min(1, max(0, Double(available) / Double(physical)))
    }

    var ringComposition: MemoryRingComposition? {
        guard measurements.physicalBytes.availability == .available,
              measurements.availableBytes.availability == .available,
              measurements.wiredBytes.availability == .available,
              measurements.compressedBytes.availability == .available,
              let physicalBytes = measurements.physicalBytes.value,
              let availableBytes = measurements.availableBytes.value,
              let wiredBytes = measurements.wiredBytes.value,
              let compressedBytes = measurements.compressedBytes.value else {
            return nil
        }
        return MemoryRingComposition(
            physicalBytes: physicalBytes,
            availableBytes: availableBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes
        )
    }

    var freePercentText: String {
        ByteFormat.percent(freeBytes, of: physicalBytes)
    }

    var availablePercentText: String {
        ByteFormat.percent(availableBytes, of: physicalBytes)
    }

    var usedPercentText: String {
        ByteFormat.percent(usedBytes, of: physicalBytes)
    }

    var processesByResidentUsage: [MemoryProcess] {
        processAnalysis.processesByResidentUsage
    }

    var selectableQuitProcesses: [MemoryProcess] {
        processAnalysis.selectableQuitProcesses
    }

    var selectableQuitBytes: Int64 {
        processAnalysis.selectableQuitBytes
    }

    var quitCandidates: [MemoryProcess] {
        processAnalysis.quitCandidates
    }

    var quitCandidateBytes: Int64 {
        processAnalysis.quitCandidateBytes
    }

    var topProcessBytes: Int64 {
        processAnalysis.topProcessBytes
    }

    var appsByResidentUsage: [MemoryAppUsage] {
        processAnalysis.appsByResidentUsage
    }

    var recommendedQuitThresholdBytes: Int64 {
        MemoryProcessAnalysis.recommendedQuitThresholdBytes(physicalBytes: physicalBytes)
    }

    var quitCandidateApps: [MemoryAppUsage] {
        processAnalysis.quitCandidateApps
    }

    var recommendedQuitApps: [MemoryAppUsage] {
        switch cleanupPlan.primaryAction {
        case .quitHighUsageApps:
            quitCandidateApps
        case .observe:
            []
        }
    }

    var recommendedQuitProcessIDs: Set<Int32> {
        Set(recommendedQuitApps.flatMap(\.selectableProcessIDs))
    }

    var quitCandidateAppBytes: Int64 {
        processAnalysis.quitCandidateAppBytes
    }

    var availableRatio: Double {
        guard physicalBytes > 0 else { return 0 }
        return min(1, max(0, Double(availableBytes) / Double(physicalBytes)))
    }

    var compressedRatio: Double {
        guard physicalBytes > 0 else { return 0 }
        return min(1, max(0, Double(compressedBytes) / Double(physicalBytes)))
    }

    /// The integer headroom reported by `memory_pressure -Q`.
    /// This is not Apple's three-level memory-pressure state.
    var pressureHeadroomPercent: Int? {
        guard let pressureFreePercentage,
              (0...100).contains(pressureFreePercentage) else { return nil }
        return pressureFreePercentage
    }

    /// A trend-only complement of system headroom, not an iStat/Activity Monitor percentage.
    var pressureEstimatePercent: Int? {
        pressureHeadroomPercent.map { 100 - $0 }
    }

    /// A pressure level suitable for user-facing status. Missing measurements stay unavailable
    /// instead of inheriting the conservative `.elevated` action-policy fallback.
    var reportablePressureLevel: MemoryPressureLevel? {
        if let measuredLevel = measurements.pressure.value {
            return measuredLevel
        }
        guard pressureHeadroomPercent != nil else { return nil }
        return pressureLevel
    }

    var cleanupPlan: MemoryCleanupPlan {
        let quitThreshold = max(512 * 1024 * 1024, physicalBytes / 24)
        let hasQuitOpportunity = quitCandidateAppBytes >= quitThreshold && !quitCandidateApps.isEmpty

        if hasQuitOpportunity {
            return MemoryCleanupPlan(
                primaryAction: .quitHighUsageApps,
                title: L10n.text("先退出高占用应用", "Quit heavy apps first"),
                detail: L10n.text(
                    "当前主要收益来自正常退出高占用应用，缓存回收收益不明显；文件缓存仍属于可用内存，不建议反复清空。",
                    "The main benefit now is quitting heavy apps normally; cache reclaim is not meaningful enough. File cache is still available memory, so repeated cache clearing is not recommended."
                ),
                estimatedRecoverableBytes: quitCandidateAppBytes
            )
        }

        return MemoryCleanupPlan(
            primaryAction: .observe,
            title: pressureLevel == .normal ? L10n.text("当前状态正常", "Memory looks normal") : L10n.text("继续观察压力", "Keep watching pressure"),
            detail: pressureLevel == .normal
                ? L10n.text(
                    "当前没有明显需要处理的内存项。macOS 会把可用内存用于文件缓存来加速再次打开应用和文件，保持观察即可。",
                    "There is no obvious memory item to handle right now. macOS uses available memory for file cache to speed up reopening apps and files, so monitoring is enough."
                )
                : L10n.text(
                    "系统有压力信号，但当前缓存或应用退出收益还不够明确；先观察占用变化，必要时再处理具体应用。",
                    "There are pressure signals, but cache or app-quit benefits are not clear enough yet. Watch usage changes first, then handle specific apps if needed."
                ),
            estimatedRecoverableBytes: 0
        )
    }

    var pressureLevel: MemoryPressureLevel {
        if let measured = measurements.pressure.value { return measured }
        guard pressureFreePercentage != nil else { return .elevated }
        return MemoryPressurePolicy.classify(
            physicalBytes: physicalBytes,
            availableBytes: availableBytes,
            compressedBytes: compressedBytes,
            swapUsedBytes: measurements.swapUsedBytes.value.map(Int64.init(clamping:)),
            pressureFreePercentage: pressureFreePercentage
        )
    }

    var memoryAdviceTitle: String {
        cleanupPlan.title
    }

    var memoryAdviceDetail: String {
        cleanupPlan.detail
    }

}

enum MemoryOptimizationStatus: Sendable, Equatable {
    case completed
    case partial
    case cancelled
    case verificationFailed
    case notNeeded
    case restricted
    case timedOut
    case unavailable
}

enum MemoryPressureLevel: Sendable {
    case normal
    case elevated
    case critical

    var title: String {
        switch self {
        case .normal:
            L10n.text("正常", "Normal")
        case .elevated:
            L10n.text("上升", "Elevated")
        case .critical:
            L10n.text("偏高", "High")
        }
    }
}

struct MemoryOptimizationResult: Sendable {
    let beforeSnapshot: MemorySnapshot
    let snapshot: MemorySnapshot
    let status: MemoryOptimizationStatus
    let detail: String
    let durationSeconds: TimeInterval
    let executionResult: MemoryOptimizationExecutionResult?

    init(
        beforeSnapshot: MemorySnapshot,
        snapshot: MemorySnapshot,
        status: MemoryOptimizationStatus,
        detail: String,
        durationSeconds: TimeInterval,
        executionResult: MemoryOptimizationExecutionResult? = nil
    ) {
        self.beforeSnapshot = beforeSnapshot
        self.snapshot = snapshot
        self.status = status
        self.detail = detail
        self.durationSeconds = durationSeconds
        self.executionResult = executionResult
    }

    var freeDeltaBytes: Int64 {
        MemoryByteMath.signedDifference(snapshot.freeBytes, beforeSnapshot.freeBytes)
    }

    var availableDeltaBytes: Int64 {
        MemoryByteMath.signedDifference(snapshot.availableBytes, beforeSnapshot.availableBytes)
    }

    var releasedBytes: Int64 {
        max(0, availableDeltaBytes)
    }

    var absoluteFreeDeltaBytes: Int64 {
        freeDeltaBytes == Int64.min ? Int64.max : abs(freeDeltaBytes)
    }

    var absoluteAvailableDeltaBytes: Int64 {
        availableDeltaBytes == Int64.min ? Int64.max : abs(availableDeltaBytes)
    }
}

enum EnergyMeasurementQuality: String, Sendable {
    case measured
    case mixed
    case estimated

    var title: String {
        switch self {
        case .measured:
            L10n.text("系统测量", "Measured")
        case .mixed:
            L10n.text("实测 + 估算", "Measured + estimated")
        case .estimated:
            L10n.text("校准估算", "Calibrated estimate")
        }
    }
}

enum EnergyImpactScanPhase: Int, CaseIterable, Identifiable, Sendable {
    case readingProcesses
    case identifyingApplications
    case capturingBaseline
    case preparingPreview
    case measuringChanges
    case calculatingResults

    var id: Int { rawValue }

    var fractionCompleted: Double {
        Double(rawValue + 1) / Double(Self.allCases.count)
    }
}

struct EnergyImpactApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let iconPath: String
    let bundlePath: String?
    let bundleIdentifier: String?
    let measuredEnergyWh: Double
    let estimatedSupplementEnergyWh: Double
    let estimatedEnergyWh: Double
    let currentPowerWatts: Double
    let averagePowerWatts: Double
    let cpuPercent: Double
    let diskReadBytesPerSecond: Int64
    let diskWriteBytesPerSecond: Int64
    let residentBytes: Int64
    let cumulativeCPUSeconds: TimeInterval
    let longestRunningSeconds: TimeInterval?
    let processCount: Int
    let measuredProcessCount: Int
    let processIDs: [Int32]
    let isApplication: Bool

    var measurementQuality: EnergyMeasurementQuality {
        if measuredProcessCount <= 0 {
            return .estimated
        }
        if measuredProcessCount >= processCount {
            return .measured
        }
        return .mixed
    }

    var usesMeasuredEnergy: Bool {
        measuredProcessCount > 0
    }

    var measurementTitle: String {
        switch measurementQuality {
        case .measured:
            return L10n.text("实测", "Measured")
        case .mixed:
            return L10n.text("实测 \(measuredProcessCount)/\(processCount)", "Measured \(measuredProcessCount)/\(processCount)")
        case .estimated:
            return L10n.text("估算", "Estimated")
        }
    }

    var estimatedEnergyText: String {
        Self.energyText(estimatedEnergyWh)
    }

    var currentPowerWattsText: String {
        Self.powerText(currentPowerWatts)
    }

    var averagePowerWattsText: String {
        Self.powerText(averagePowerWatts)
    }

    var cpuPercentText: String {
        String(format: "%.1f%%", cpuPercent)
    }

    var cumulativeCPUText: String {
        Self.durationText(cumulativeCPUSeconds)
    }

    var runningTimeText: String {
        guard let longestRunningSeconds else {
            return L10n.text("未知", "Unknown")
        }
        return Self.durationText(longestRunningSeconds)
    }

    var sourceTitle: String {
        bundleIdentifier?.nonEmpty ?? path
    }

    var kindTitle: String {
        isApplication ? L10n.text("应用", "App") : L10n.text("进程", "Process")
    }

    var activityLevelTitle: String {
        if currentPowerWatts >= 2 || cpuPercent >= 20 {
            return L10n.text("高功率", "High power")
        }
        if currentPowerWatts >= 0.5 || cpuPercent >= 5 {
            return L10n.text("当前活跃", "Active now")
        }
        if estimatedEnergyWh >= 1 {
            return L10n.text("累计能耗较高", "Notable energy")
        }
        return L10n.text("低能耗", "Low energy")
    }

    /// Uses the same live thresholds as the app's existing activity language.
    /// Every app, including Storage Cleaner, is evaluated by this predicate.
    var isSignificantCurrentEnergy: Bool {
        currentPowerWatts >= 0.5 || cpuPercent >= 5
    }

    static func energyText(_ wattHours: Double) -> String {
        let clamped = max(0, wattHours)
        let milliWattHours = clamped * 1_000

        if clamped < 1 {
            if milliWattHours < 10 {
                return String(format: "%.1f mWh", locale: numericLocale, milliWattHours)
            }
            return String(format: "%.0f mWh", locale: numericLocale, milliWattHours)
        }
        if clamped < 10 {
            return String(format: "%.2f Wh", locale: numericLocale, clamped)
        }
        return String(format: "%.1f Wh", locale: numericLocale, clamped)
    }

    static func powerText(_ watts: Double) -> String {
        let clamped = max(0, watts)
        if clamped < 1 {
            return String(format: "%.0f mW", locale: numericLocale, clamped * 1_000)
        }
        if clamped < 10 {
            return String(format: "%.2f W", locale: numericLocale, clamped)
        }
        return String(format: "%.1f W", locale: numericLocale, clamped)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded()))
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainingSeconds = wholeSeconds % 60

        if hours > 0 {
            return L10n.text("\(hours) 小时 \(minutes) 分钟", "\(hours)h \(minutes)m")
        }
        if minutes > 0 {
            return L10n.text("\(minutes) 分钟 \(remainingSeconds) 秒", "\(minutes)m \(remainingSeconds)s")
        }
        return L10n.text("\(remainingSeconds) 秒", "\(remainingSeconds)s")
    }

    private static let numericLocale = Locale(identifier: "en_US_POSIX")
}

struct EnergyImpactSnapshot: Sendable {
    let generatedAt: Date
    let scanSeconds: TimeInterval
    let sampleSeconds: TimeInterval
    let uptimeSeconds: TimeInterval
    let apps: [EnergyImpactApp]
    let processCount: Int
    let measuredProcessCount: Int
    let unmeasuredProcessCount: Int
    let measuredTotalEnergyWh: Double
    let estimatedSupplementEnergyWh: Double
    let calibrationWattsPerCore: Double
    let usesLocalCalibration: Bool

    var estimatedTotalEnergyWh: Double {
        measuredTotalEnergyWh + estimatedSupplementEnergyWh
    }

    var estimatedTotalEnergyText: String {
        EnergyImpactApp.energyText(estimatedTotalEnergyWh)
    }

    var energyCoverageText: String {
        guard processCount > 0 else {
            return L10n.text("没有可归因的应用进程", "No attributable app processes")
        }
        return L10n.text(
            "\(measuredProcessCount)/\(processCount) 个应用进程实测",
            "\(measuredProcessCount)/\(processCount) app processes measured"
        )
    }

    var energyCoveragePercent: Double {
        guard processCount > 0 else { return 0 }
        return Double(measuredProcessCount) / Double(processCount) * 100
    }

    var energyCoveragePercentText: String {
        String(format: "%.0f%%", energyCoveragePercent)
    }

    var measurementQuality: EnergyMeasurementQuality {
        if measuredProcessCount <= 0 {
            return .estimated
        }
        if measuredProcessCount >= processCount {
            return .measured
        }
        return .mixed
    }

    var source: String {
        measurementQuality.title
    }

    var calibrationText: String {
        if usesLocalCalibration {
            return L10n.text(
                "未覆盖进程按本机 \(EnergyImpactApp.powerText(calibrationWattsPerCore))/核校准",
                "Uncovered processes calibrated at \(EnergyImpactApp.powerText(calibrationWattsPerCore))/core on this Mac"
            )
        }
        return L10n.text(
            "未覆盖进程使用兼容估算",
            "Uncovered processes use a compatibility estimate"
        )
    }

    var sampleDurationText: String {
        String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), sampleSeconds)
    }

    var totalCurrentPowerWatts: Double {
        apps.reduce(0) { $0 + $1.currentPowerWatts }
    }

    var currentPowerWattsText: String {
        EnergyImpactApp.powerText(totalCurrentPowerWatts)
    }

    var totalCumulativeCPUSeconds: TimeInterval {
        apps.reduce(0) { $0 + $1.cumulativeCPUSeconds }
    }

    var activeAppCount: Int {
        apps.filter { $0.currentPowerWatts >= 0.01 || $0.cpuPercent >= 0.1 }.count
    }

    var bootStartedAt: Date {
        generatedAt.addingTimeInterval(-uptimeSeconds)
    }

    var uptimeText: String {
        EnergyImpactApp.durationText(uptimeSeconds)
    }

    var cumulativeCPUText: String {
        EnergyImpactApp.durationText(totalCumulativeCPUSeconds)
    }
}

enum InstalledAppStatus: String, Sendable {
    case installed
    case movedToTrash

    var title: String {
        switch self {
        case .installed:
            L10n.text("已安装", "Installed")
        case .movedToTrash:
            L10n.text("已移到废纸篓", "Moved to Trash")
        }
    }
}

enum AppUninstallRecommendation: String, CaseIterable, Identifiable, Sendable {
    case protected
    case keep
    case review
    case candidate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .protected:
            L10n.text("谨慎保留", "Keep Carefully")
        case .keep:
            L10n.text("建议保留", "Keep")
        case .review:
            L10n.text("建议复核", "Review")
        case .candidate:
            L10n.text("可考虑卸载", "Uninstall Candidate")
        }
    }

    var shortTitle: String {
        switch self {
        case .protected:
            L10n.text("谨慎", "Careful")
        case .keep:
            L10n.text("保留", "Keep")
        case .review:
            L10n.text("复核", "Review")
        case .candidate:
            L10n.text("候选", "Candidate")
        }
    }

    var detail: String {
        switch self {
        case .protected:
            L10n.text("系统或 Apple 应用不建议直接卸载，先确认依赖关系。", "System or Apple apps should not be removed directly; review dependencies first.")
        case .keep:
            L10n.text("近期使用或证据不足，暂不作为释放空间优先项。", "Recently used or not enough evidence; not a priority for reclaiming space.")
        case .review:
            L10n.text("占用、关联文件或使用时间值得检查，但卸载前仍需确认。", "Size, associated files, or usage timing deserve review, but confirm before uninstalling.")
        case .candidate:
            L10n.text("长期未打开或有可靠的同类低评分证据，可考虑卸载。", "Long unused or reliably lower-rated than a similar app; consider uninstalling it.")
        }
    }

    var sortRank: Int {
        switch self {
        case .candidate: 3
        case .review: 2
        case .keep: 1
        case .protected: 0
        }
    }
}

enum AppUninstallSimilarityGroup: String, CaseIterable, Sendable {
    case webBrowser
    case wordProcessor
    case spreadsheet
    case presentation
    case cloudStorage
    case mediaPlayer
    case archiveUtility
    case codeEditor
    case passwordManager
    case emailClient

    var title: String {
        switch self {
        case .webBrowser: L10n.text("网页浏览器", "web browser")
        case .wordProcessor: L10n.text("文字处理", "word processor")
        case .spreadsheet: L10n.text("电子表格", "spreadsheet")
        case .presentation: L10n.text("演示文稿", "presentation")
        case .cloudStorage: L10n.text("云盘同步", "cloud storage")
        case .mediaPlayer: L10n.text("媒体播放器", "media player")
        case .archiveUtility: L10n.text("压缩解压", "archive utility")
        case .codeEditor: L10n.text("代码编辑器", "code editor")
        case .passwordManager: L10n.text("密码管理", "password manager")
        case .emailClient: L10n.text("邮件客户端", "email client")
        }
    }

    static func resolve(bundleIdentifier: String) -> Self? {
        let identifier = bundleIdentifier.trimmed.lowercased()
        guard !identifier.isEmpty else { return nil }
        return allCases.first { group in
            group.bundleSignatures.contains { signature in
                identifier == signature || identifier.hasPrefix(signature + ".")
            }
        }
    }

    private var bundleSignatures: [String] {
        switch self {
        case .webBrowser:
            ["com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi", "company.thebrowser.browser", "com.duckduckgo.macos.browser"]
        case .wordProcessor:
            ["com.microsoft.word", "com.apple.iwork.pages"]
        case .spreadsheet:
            ["com.microsoft.excel", "com.apple.iwork.numbers"]
        case .presentation:
            ["com.microsoft.powerpoint", "com.apple.iwork.keynote"]
        case .cloudStorage:
            ["com.getdropbox.dropbox", "com.microsoft.onedrive", "com.google.drivefs", "com.baidu.netdisk", "com.baidu.baidunetdisk", "com.jianguoyun.nutstore"]
        case .mediaPlayer:
            ["org.videolan.vlc", "com.colliderli.iina", "com.apple.quicktimeplayerx", "com.movist", "com.eltima.elmediaplayer"]
        case .archiveUtility:
            ["com.aone.keka", "cx.c3.theunarchiver", "com.macitbetter.betterzip", "com.winzip.winzip-mac", "com.rarlab.winrar"]
        case .codeEditor:
            ["com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "dev.zed.zed", "com.sublimetext", "com.macromates.textmate"]
        case .passwordManager:
            ["com.1password.1password", "com.bitwarden.desktop", "com.dashlane", "com.lastpass"]
        case .emailClient:
            ["com.microsoft.outlook", "com.readdle.smartemail-macos", "com.mimestream.mimestream", "com.edisonmail", "com.apple.mail"]
        }
    }
}

struct AppUninstallRatingComparison: Hashable, Sendable {
    let group: AppUninstallSimilarityGroup
    let rating: Double
    let ratingCount: Int
    let higherRatedAppName: String
    let higherRating: Double
    let higherRatingCount: Int
}

struct InstalledAppItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let path: String
    let version: String
    let build: String
    let category: String
    let appDescription: String
    let appIntroduction: String
    let developerName: String
    let sizeBytes: Int64
    let source: String
    let modifiedAt: Date?
    let scanIdentity: FileIdentity?
    let lastUsedAt: Date?
    let relatedPaths: [String]
    let relatedItems: [InstalledAppRelatedItem]
    var status: InstalledAppStatus
    var appStoreRating: Double?
    var appStoreRatingCount: Int?
    var uninstallRatingComparison: AppUninstallRatingComparison?

    init(
        id: String,
        name: String,
        bundleIdentifier: String,
        path: String,
        version: String,
        build: String,
        category: String,
        appDescription: String,
        appIntroduction: String? = nil,
        developerName: String = "",
        sizeBytes: Int64,
        source: String,
        modifiedAt: Date?,
        scanIdentity: FileIdentity? = nil,
        lastUsedAt: Date? = nil,
        relatedPaths: [String],
        relatedItems: [InstalledAppRelatedItem],
        status: InstalledAppStatus,
        appStoreRating: Double? = nil,
        appStoreRatingCount: Int? = nil,
        uninstallRatingComparison: AppUninstallRatingComparison? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.version = version
        self.build = build
        self.category = category
        self.appDescription = appDescription
        self.appIntroduction = (appIntroduction ?? appDescription).trimmed
        self.developerName = developerName.trimmed
        self.sizeBytes = sizeBytes
        self.source = source
        self.modifiedAt = modifiedAt
        self.scanIdentity = scanIdentity
        self.lastUsedAt = lastUsedAt
        self.relatedPaths = relatedPaths
        self.relatedItems = relatedItems
        self.status = status
        self.appStoreRating = appStoreRating
        self.appStoreRatingCount = appStoreRatingCount
        self.uninstallRatingComparison = uninstallRatingComparison
    }

    var versionDisplay: String {
        AppUpdateService.versionDisplay(shortVersion: version, buildVersion: build)
    }

    var relatedBytes: Int64 {
        relatedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalFootprintBytes: Int64 {
        sizeBytes + relatedBytes
    }

    var externalManagementProviderName: String? {
        let normalizedPath = PathSafety.normalizedPath(path)
        guard normalizedPath.hasPrefix("/Applications/Setapp/") else { return nil }
        return "Setapp"
    }

    var canMoveToTrash: Bool {
        status == .installed
            && path.hasSuffix(".app")
            && (PathSafety.isInsideApplications(path) || PathSafety.isInsideHome(path))
    }

    var isAppleApp: Bool {
        bundleIdentifier.lowercased().hasPrefix("com.apple.")
            || developerName.caseInsensitiveCompare("Apple") == .orderedSame
    }

    var displayDescriptionDetail: String? {
        let description = appDescription.trimmed
        let introduction = appIntroduction.trimmed

        guard !description.isEmpty else { return nil }
        guard !introduction.isEmpty else { return description }
        guard description != introduction else { return nil }

        if description.hasPrefix(introduction) {
            let remainderStart = description.index(description.startIndex, offsetBy: introduction.count)
            return String(description[remainderStart...]).trimmed.nonEmpty
        }

        return description
    }

    var uninstallReviewScore: Int {
        guard status == .installed, canMoveToTrash else { return 0 }
        guard !isAppleApp else { return min(24, baseUninstallReviewScore) }
        return baseUninstallReviewScore
    }

    var uninstallRecommendation: AppUninstallRecommendation {
        guard status == .installed, canMoveToTrash else { return .protected }
        if isAppleApp { return .protected }
        if isLongUnused() { return .candidate }
        if uninstallReviewScore >= 70 { return .candidate }
        if uninstallReviewScore >= 45 { return .review }
        return .keep
    }

    var uninstallRecommendationReasons: [String] {
        var reasons = [String]()

        if let provider = externalManagementProviderName {
            reasons.append(L10n.text(
                "此应用来自 \(provider)。确认后会由存储清理助手移到废纸篓；\(provider) 中的订阅与安装记录不会随之更改。",
                "This app comes from \(provider). Storage Cleaner will move it to Trash after confirmation; its subscription and installation records in \(provider) are not changed."
            ))
        } else if !canMoveToTrash {
            reasons.append(L10n.text("当前路径不在可安全移动到废纸篓的应用范围内。", "The current path is outside the app locations that can be safely moved to Trash."))
        }
        if isAppleApp {
            reasons.append(L10n.text("Apple 或系统应用可能被系统功能、账户同步或其它 App 依赖。", "Apple or system apps may be used by system features, account sync, or other apps."))
        }
        if isLongUnused() {
            reasons.append(L10n.text("超过 60 天没有打开记录。", "No launch record in the last 60 days."))
        } else if let lastUsedAt {
            let days = max(0, Calendar.current.dateComponents([.day], from: lastUsedAt, to: Date()).day ?? 0)
            if days <= 14 {
                reasons.append(L10n.text("最近 \(days) 天内使用过。", "Used within the last \(days) days."))
            }
        } else {
            reasons.append(L10n.text("没有读取到最近使用时间，建议先按名称确认用途。", "No last-used date was found; confirm the app's purpose by name first."))
        }

        if totalFootprintBytes >= 5_000_000_000 {
            reasons.append(L10n.text("总占用超过 5 GB。", "Total footprint is over 5 GB."))
        } else if totalFootprintBytes >= 1_000_000_000 {
            reasons.append(L10n.text("总占用超过 1 GB。", "Total footprint is over 1 GB."))
        }

        if relatedBytes >= 1_000_000_000 {
            reasons.append(L10n.text("发现超过 1 GB 的常见关联文件。", "Common associated files exceed 1 GB."))
        } else if relatedBytes > 0 {
            reasons.append(L10n.text("发现常见关联文件，可在卸载确认时一并移到废纸篓。", "Common associated files were found and can be moved to Trash during uninstall confirmation."))
        } else {
            reasons.append(L10n.text("暂未发现常见关联文件。", "No common associated files were found."))
        }

        if let modifiedAt {
            let days = max(0, Calendar.current.dateComponents([.day], from: modifiedAt, to: Date()).day ?? 0)
            if days <= 14 {
                reasons.append(L10n.text("最近 \(days) 天内更新过。", "Updated within the last \(days) days."))
            }
        }

        reasons.append(L10n.text("卸载操作会先进入确认页，可选择同时把关联文件移到废纸篓。", "Uninstalling opens a confirmation sheet where associated files can also be moved to Trash."))

        return reasons
    }

    var uninstallSuggestionReason: String? {
        guard uninstallRecommendation == .candidate else { return nil }
        var reasons = [String]()

        if isLongUnused(), let lastUsedAt {
            let days = max(60, Calendar.current.dateComponents([.day], from: lastUsedAt, to: Date()).day ?? 60)
            reasons.append(L10n.text(
                "已 \(days) 天未打开，上次使用于 \(lastUsedAt.formatted(date: .abbreviated, time: .omitted))",
                "Not opened for \(days) days; last used \(lastUsedAt.formatted(date: .abbreviated, time: .omitted))"
            ))
        }



        if reasons.isEmpty, totalFootprintBytes >= 1_000_000_000 {
            reasons.append(L10n.text(
                "应用与常见关联文件合计占用 \(ByteFormat.string(totalFootprintBytes))",
                "The app and common associated files use \(ByteFormat.string(totalFootprintBytes))"
            ))
        }

        return reasons.joined(separator: L10n.text("；", "; ")).nonEmpty
    }

    var uninstallInsightCards: [InstalledAppInsightCard] {
        var cards = [
            InstalledAppInsightCard(
                kind: .introduction,
                title: L10n.text("应用用途", "App Purpose"),
                detail: appIntroduction,
                tone: .blue
            )
        ]

        if let description = displayDescriptionDetail {
            cards.append(
                InstalledAppInsightCard(
                    kind: .description,
                    title: L10n.text("应用信息", "App Information"),
                    detail: description,
                    tone: .indigo
                )
            )
        }

        cards.append(
            InstalledAppInsightCard(
                kind: .scan,
                title: L10n.text("扫描说明", "Scan Note"),
                detail: uninstallScanSummary,
                tone: relatedBytes > 0 ? .orange : .green
            )
        )

        cards.append(
            InstalledAppInsightCard(
                kind: .usage,
                title: L10n.text("使用记录", "Usage"),
                detail: uninstallUsageSummary,
                tone: isLongUnused() ? .purple : .secondary
            )
        )

        cards.append(
            InstalledAppInsightCard(
                kind: .leftovers,
                title: L10n.text("关联文件", "Associated Files"),
                detail: uninstallLeftoverSummary,
                tone: relatedBytes > 0 ? .orange : .green
            )
        )

        return cards
    }

    var uninstallScanSummary: String {
        if relatedItems.isEmpty {
            return L10n.text(
                "已读取应用包信息并统计占用，暂未发现常见配置、缓存或偏好设置等关联文件。卸载时只将应用文件移到废纸篓。",
                "App bundle information and storage usage were read. No common support, cache, or preference files were found. Uninstalling only moves the app to Trash."
            )
        }

        return L10n.text(
            "已读取应用包信息并统计占用，同时发现 \(relatedItems.count) 个常见关联文件，合计 \(ByteFormat.string(relatedBytes))；卸载确认时可一并移到废纸篓。",
            "App bundle information and storage usage were read, along with \(relatedItems.count) common associated files totaling \(ByteFormat.string(relatedBytes)); they can be moved to Trash during uninstall confirmation."
        )
    }

    var uninstallLeftoverSummary: String {
        if relatedItems.isEmpty {
            return L10n.text(
                "没有发现常见关联文件；卸载后仍可按应用名称手动搜索确认。",
                "No common associated files were found; you can still search manually by app name after uninstalling."
            )
        }

        let preview = relatedItems
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(2)
            .map { item in
                "\(URL(fileURLWithPath: item.path).lastPathComponent) \(ByteFormat.string(item.sizeBytes))"
            }
            .joined(separator: " · ")

        return L10n.text(
            "发现 \(relatedItems.count) 个常见关联文件，合计 \(ByteFormat.string(relatedBytes))。最大：\(preview)。卸载确认时可一并移到废纸篓。",
            "\(relatedItems.count) common associated files were found, totaling \(ByteFormat.string(relatedBytes)). Largest: \(preview). They can be moved to Trash during uninstall confirmation."
        )
    }

    var uninstallUsageSummary: String {
        if let lastUsedAt {
            let days = max(0, Calendar.current.dateComponents([.day], from: lastUsedAt, to: Date()).day ?? 0)
            if isLongUnused() {
                return L10n.text(
                    "最近使用于 \(lastUsedAt.formatted(date: .abbreviated, time: .omitted))，已超过 60 天；建议先确认项目或账号依赖后再卸载。",
                    "Last used \(lastUsedAt.formatted(date: .abbreviated, time: .omitted)), over 60 days ago; confirm project or account dependencies before uninstalling."
                )
            }

            return L10n.text(
                "最近 \(days) 天内使用过，建议保留或先确认是否仍在日常工作流中。",
                "Used within the last \(days) days; keep it or confirm whether it is still part of your daily workflow."
            )
        }

        return L10n.text(
            "没有读取到最近使用时间；建议按应用名称、用途和开发者先确认后再卸载。",
            "No last-used date was found; confirm by app name, purpose, and developer before uninstalling."
        )
    }

    func isLongUnused(referenceDate: Date = Date(), thresholdDays: Int = 60) -> Bool {
        guard let lastUsedAt else { return false }
        let seconds = referenceDate.timeIntervalSince(lastUsedAt)
        guard seconds > 0 else { return false }
        return seconds >= Double(thresholdDays) * 24 * 60 * 60
    }

    private var baseUninstallReviewScore: Int {
        var score = 28

        if isLongUnused() {
            score += 42
        } else if let lastUsedAt {
            let days = max(0, Calendar.current.dateComponents([.day], from: lastUsedAt, to: Date()).day ?? 0)
            if days <= 14 {
                score -= 24
            } else if days >= 45 {
                score += 12
            }
        }

        if totalFootprintBytes >= 8_000_000_000 {
            score += 22
        } else if totalFootprintBytes >= 5_000_000_000 {
            score += 18
        } else if totalFootprintBytes >= 1_000_000_000 {
            score += 10
        } else if totalFootprintBytes >= 500_000_000 {
            score += 5
        }

        if relatedBytes >= 2_000_000_000 {
            score += 18
        } else if relatedBytes >= 1_000_000_000 {
            score += 14
        } else if relatedBytes > 0 {
            score += 8
        }

        if let modifiedAt {
            let days = max(0, Calendar.current.dateComponents([.day], from: modifiedAt, to: Date()).day ?? 0)
            if days <= 14 {
                score -= 8
            }
        }

        return min(100, max(0, score))
    }
}

struct InstalledAppRelatedItem: Identifiable, Hashable, Sendable {
    let path: String
    let sizeBytes: Int64
    let scanIdentity: FileIdentity?
    // An exact bundle-ID match is only a candidate, not exclusive ownership.
    // No production ownership verifier currently issues this evidence.
    let verifiedExclusiveOwnerBundleID: String?

    init(path: String, sizeBytes: Int64, scanIdentity: FileIdentity? = nil,
         verifiedExclusiveOwnerBundleID: String? = nil) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.scanIdentity = scanIdentity
        self.verifiedExclusiveOwnerBundleID = verifiedExclusiveOwnerBundleID
    }

    var id: String { path }
}

enum InstalledAppInsightTone: String, Sendable {
    case pink
    case indigo
    case orange
    case green
    case purple
    case blue
    case secondary
}

enum InstalledAppInsightKind: String, Sendable {
    case introduction
    case description
    case scan
    case leftovers
    case usage
}

struct InstalledAppInsightCard: Identifiable, Hashable, Sendable {
    let kind: InstalledAppInsightKind
    let title: String
    let detail: String
    let tone: InstalledAppInsightTone

    var id: String { kind.rawValue }
}

enum AppUninstallListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case reviewRecommended
    case thirdParty
    case apple
    case withLeftovers
    case longUnused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .reviewRecommended: L10n.text("建议复核", "Review")
        case .thirdParty: L10n.text("第三方", "Third-Party")
        case .apple: "Apple"
        case .withLeftovers: L10n.text("有关联文件", "Associated Files")
        case .longUnused: L10n.text("长期未用", "Unused")
        }
    }

    func includes(_ app: InstalledAppItem) -> Bool {
        switch self {
        case .all:
            true
        case .reviewRecommended:
            app.uninstallRecommendation == .review || app.uninstallRecommendation == .candidate
        case .thirdParty:
            !app.isAppleApp
        case .apple:
            app.isAppleApp
        case .withLeftovers:
            app.relatedBytes > 0 || !app.relatedItems.isEmpty
        case .longUnused:
            app.isLongUnused()
        }
    }
}

enum AppUninstallSortMode: String, CaseIterable, Identifiable, Sendable {
    case recommendation
    case totalFootprint
    case bundleSize
    case leftovers
    case lastUsed
    case modified
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommendation: L10n.text("建议", "Recommendation")
        case .totalFootprint: L10n.text("总占用", "Total Size")
        case .bundleSize: L10n.text("应用大小", "App Size")
        case .leftovers: L10n.text("关联文件大小", "Associated Files")
        case .lastUsed: L10n.text("最近使用", "Last Used")
        case .modified: L10n.text("最近更新", "Recently Modified")
        case .name: L10n.text("名称", "Name")
        }
    }
}

enum AppUninstallListPresenter {
    static func visibleApps(
        from apps: [InstalledAppItem],
        query: String,
        filter: AppUninstallListFilter,
        sortMode: AppUninstallSortMode
    ) -> [InstalledAppItem] {
        let normalizedQuery = query.trimmed
        return apps
            .filter(filter.includes)
            .filter { app in
                guard !normalizedQuery.isEmpty else { return true }
                return app.name.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.bundleIdentifier.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.appIntroduction.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.appDescription.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.uninstallRecommendation.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.uninstallRecommendation.detail.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.uninstallRecommendationReasons.contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
                    || app.uninstallInsightCards.contains {
                        $0.title.localizedCaseInsensitiveContains(normalizedQuery)
                            || $0.detail.localizedCaseInsensitiveContains(normalizedQuery)
                    }
                    || app.developerName.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.category.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.versionDisplay.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.source.localizedCaseInsensitiveContains(normalizedQuery)
                    || app.path.localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                switch sortMode {
                case .recommendation:
                    return compareRecommendation(lhs, rhs)
                case .totalFootprint:
                    return compareDescending(lhs.totalFootprintBytes, rhs.totalFootprintBytes, lhs: lhs, rhs: rhs)
                case .bundleSize:
                    return compareDescending(lhs.sizeBytes, rhs.sizeBytes, lhs: lhs, rhs: rhs)
                case .leftovers:
                    return compareDescending(lhs.relatedBytes, rhs.relatedBytes, lhs: lhs, rhs: rhs)
                case .lastUsed:
                    return compareLastUsed(lhs, rhs)
                case .modified:
                    return compareDescending(lhs.modifiedAt ?? .distantPast, rhs.modifiedAt ?? .distantPast, lhs: lhs, rhs: rhs)
                case .name:
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
    }

    private static func compareDescending<T: Comparable>(
        _ lhsValue: T,
        _ rhsValue: T,
        lhs: InstalledAppItem,
        rhs: InstalledAppItem
    ) -> Bool {
        if lhsValue == rhsValue {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhsValue > rhsValue
    }

    private static func compareAscending<T: Comparable>(
        _ lhsValue: T,
        _ rhsValue: T,
        lhs: InstalledAppItem,
        rhs: InstalledAppItem
    ) -> Bool {
        if lhsValue == rhsValue {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhsValue < rhsValue
    }

    private static func compareLastUsed(_ lhs: InstalledAppItem, _ rhs: InstalledAppItem) -> Bool {
        switch (lhs.lastUsedAt, rhs.lastUsedAt) {
        case let (lhsDate?, rhsDate?):
            return compareAscending(lhsDate, rhsDate, lhs: lhs, rhs: rhs)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func compareRecommendation(_ lhs: InstalledAppItem, _ rhs: InstalledAppItem) -> Bool {
        if lhs.uninstallRecommendation.sortRank != rhs.uninstallRecommendation.sortRank {
            return lhs.uninstallRecommendation.sortRank > rhs.uninstallRecommendation.sortRank
        }
        if lhs.uninstallReviewScore != rhs.uninstallReviewScore {
            return lhs.uninstallReviewScore > rhs.uninstallReviewScore
        }
        return compareDescending(lhs.totalFootprintBytes, rhs.totalFootprintBytes, lhs: lhs, rhs: rhs)
    }
}

enum AppUpdateMethod: String, CaseIterable, Identifiable, Sendable {
    case appStore
    case homebrew
    case sparkle
    case manual

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .appStore:
            L10n.text("App Store", "App Store")
        case .homebrew:
            L10n.text("Homebrew", "Homebrew")
        case .sparkle:
            L10n.text("应用内更新", "In-app Update")
        case .manual:
            L10n.text("手动检查", "Manual Check")
        }
    }

    var detail: String {
        switch self {
        case .appStore:
            L10n.text("可在 Mac App Store 的更新页检查。", "Check updates in the Mac App Store Updates page.")
        case .homebrew:
            L10n.text("由 Homebrew Cask 管理，可通过批量更新执行。", "Managed by Homebrew Cask and supported by batch update.")
        case .sparkle:
            L10n.text("应用包含 Sparkle 更新源，通常在应用菜单里检查更新。", "The app includes a Sparkle update feed, usually checked from the app menu.")
        case .manual:
            L10n.text("未发现通用更新源，请打开应用或官网检查。", "No common update source was detected. Open the app or its website to check.")
        }
    }
}

struct AppUpdateSourceConfiguration: Equatable, Sendable {
    var enabledMethods: Set<AppUpdateMethod>

    static let all = AppUpdateSourceConfiguration(enabledMethods: Set(AppUpdateMethod.allCases))

    var enabledCount: Int {
        enabledMethods.count
    }

    var isEmpty: Bool {
        enabledMethods.isEmpty
    }

    func includes(_ method: AppUpdateMethod) -> Bool {
        enabledMethods.contains(method)
    }

    mutating func set(_ method: AppUpdateMethod, isEnabled: Bool) {
        if isEnabled {
            enabledMethods.insert(method)
        } else {
            enabledMethods.remove(method)
        }
    }
}

struct AppUpdateOneClickPlan: Sendable {
    let appStoreApps: [AppUpdateItem]
    let automaticApps: [AppUpdateItem]
    let authorizationApps: [AppUpdateItem]
    let sparkleApps: [AppUpdateItem]
    let manualApps: [AppUpdateItem]

    var applications: [AppUpdateItem] {
        automaticApps + authorizationApps + appStoreApps + sparkleApps + manualApps
    }

    var totalCount: Int {
        applications.count
    }

    var manualReviewCount: Int {
        sparkleApps.count + manualApps.count
    }

    var automaticCount: Int {
        automaticApps.count
    }

    var hasAutomaticUpdates: Bool {
        automaticCount > 0
    }

    var isEmpty: Bool {
        totalCount == 0
    }

    var homebrewCommand: String? {
        AppUpdateService.homebrewUpgradeCommand(
            for: automaticApps.filter { $0.primaryUpdateProvider == .homebrew }
        )
    }
}

struct AppUpdateOneClickLaunchResult: Sendable {
    let openedAppStore: Bool
    let copiedManualReviewList: Bool
}

enum AppUpdateExecutionStatus: String, Equatable, Sendable {
    case skipped
    case succeeded
    case launched
    case opened
    case needsTerminal
    case failed
    case timedOut
    case unavailable

    var title: String {
        switch self {
        case .skipped:
            L10n.text("已跳过", "Skipped")
        case .succeeded:
            L10n.text("命令完成", "Command Complete")
        case .launched:
            L10n.text("已启动", "Launched")
        case .opened:
            L10n.text("已打开", "Opened")
        case .needsTerminal:
            L10n.text("需终端", "Needs Terminal")
        case .failed:
            L10n.text("失败", "Failed")
        case .timedOut:
            L10n.text("超时", "Timed Out")
        case .unavailable:
            L10n.text("不可用", "Unavailable")
        }
    }
}

struct AppUpdateCommandRunResult: Sendable {
    let status: AppUpdateExecutionStatus
    let command: String?
    let detail: String
}

typealias AppUpdateAppStoreRunResult = AppUpdateCommandRunResult
typealias AppUpdateHomebrewRunResult = AppUpdateCommandRunResult
typealias AppUpdateAutomaticRunResult = AppUpdateCommandRunResult

struct AppUpdateOneClickResult: Sendable {
    let launched: AppUpdateOneClickLaunchResult
    let appStore: AppUpdateAppStoreRunResult
    let automatic: AppUpdateAutomaticRunResult
    let generatedAt: Date
}
