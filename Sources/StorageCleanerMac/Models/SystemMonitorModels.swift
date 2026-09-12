import Foundation

enum PanelDensity: String, CaseIterable, Identifiable, Codable, Sendable {
    // `compact` and `advanced` remain decodable so preferences written by
    // earlier releases do not become corrupt. They are migration-only values:
    // the menu-bar product now exposes and restores Geek exclusively.
    case simple = "compact"
    case complex = "advanced"
    case geek

    static let defaultsKey = "menuBar.panelMode"
    static let menuBarChoices: [PanelDensity] = [.geek]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: L10n.text("简单", "Simple")
        case .complex: L10n.text("详细", "Detailed")
        case .geek: L10n.text("极客", "Geek")
        }
    }

    /// Legacy density values retain enough geometry metadata to decode old
    /// preferences safely. Runtime state is canonicalized to Geek before the
    /// menu-bar panel is constructed.
    var usesAttachedDetailPresentation: Bool {
        self == .complex || self == .geek
    }

    var systemImage: String {
        switch self {
        case .simple: AppSymbols.Panel.simple
        case .complex: AppSymbols.Panel.complex
        case .geek: AppSymbols.Panel.geek
        }
    }

    static var defaultValue: PanelDensity { .geek }

    static func stored(in defaults: UserDefaults = .standard) -> PanelDensity {
        if defaults.string(forKey: defaultsKey) != PanelDensity.geek.rawValue {
            defaults.set(PanelDensity.geek.rawValue, forKey: defaultsKey)
        }
        return .geek
    }
}

enum PanelSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case processor
    case memory
    case disk
    case network
    case sensors
    case power
    case cleanup

    static let defaultsKey = "menuBar.panelSection"
    static let legacyMonitorDefaultsKey = "menuBar.monitorSection"
    static let legacySimpleDefaultsKey = "menuBar.simpleSection"
    static let simpleChoices: [PanelSection] = [.overview, .cleanup]

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: L10n.text("概览", "Overview")
        case .processor: L10n.text("CPU 与 GPU", "CPU & GPU")
        case .memory: L10n.text("内存", "Memory")
        case .disk: L10n.text("磁盘", "Disk")
        case .network: L10n.text("网络", "Network")
        case .sensors: L10n.text("传感器", "Sensors")
        case .power: L10n.text("电源与能耗", "Power & Energy")
        case .cleanup: L10n.text("清理", "Cleanup")
        }
    }

    var simpleTitle: String {
        switch self {
        case .overview: L10n.text("系统", "System")
        case .cleanup: L10n.text("清理", "Cleanup")
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .overview: AppSymbols.Monitor.overview
        case .processor: AppSymbols.Monitor.processor
        case .memory: AppSymbols.Monitor.memory
        case .disk: AppSymbols.Monitor.storage
        case .network: AppSymbols.Monitor.network
        case .sensors: AppSymbols.Monitor.sensors
        case .power: AppSymbols.Monitor.power
        case .cleanup: AppSymbols.Monitor.cleanup
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> PanelSection {
        if let rawValue = defaults.string(forKey: defaultsKey),
           let section = PanelSection(rawValue: rawValue) {
            return section
        }

        if let rawValue = defaults.string(forKey: legacyMonitorDefaultsKey),
           let section = PanelSection(rawValue: rawValue) {
            return section
        }

        if defaults.string(forKey: legacySimpleDefaultsKey) == "cleanup" {
            return .cleanup
        }
        return .overview
    }
}

/// Fixed geometry shared by the Detailed and Geek combined monitors and their
/// attached detail surface. These are controlled presentation states, not
/// user-resizable window sizes, and both are hosted by the same panel session.
enum GeekPanelPresentationMetrics {
    /// The overview keeps the measured reference width while child pages use
    /// their own compact column. This preserves a readable main summary
    /// without letting history pages grow into ordinary document windows.
    static let secondaryWidth = MiniWindowStyleTokens.overviewSize.width
    static let detailWidth = MiniWindowStyleTokens.detailWidth
    static let powerDetailWidth = MiniWindowStyleTokens.powerDetailWidth
    static let overviewSize = MiniWindowStyleTokens.overviewSize
    /// Generic deep-detail pages keep the legacy full-column size. Inline
    /// hover details supply their own preferred size and are normalized below.
    static let tertiarySize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 480)
    static let tertiaryMaximumSize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 520)
    static let tertiaryMinimumDimension: CGFloat = 1
    static let sensorsDetailHeight = overviewSize.height

    static func normalizedOverviewSize(_ preferredSize: CGSize?) -> CGSize {
        guard let preferredSize,
              preferredSize.width.isFinite,
              preferredSize.height.isFinite,
              preferredSize.width > 0,
              preferredSize.height > 0 else { return overviewSize }
        return CGSize(
            width: overviewSize.width,
            height: preferredSize.height.rounded(.up)
        )
    }

    static func normalizedTertiarySize(_ preferredSize: CGSize?) -> CGSize {
        let candidate = preferredSize ?? tertiarySize
        return CGSize(
            width: normalizedTertiaryDimension(
                candidate.width,
                fallback: tertiarySize.width,
                maximum: tertiaryMaximumSize.width
            ),
            height: normalizedTertiaryDimension(
                candidate.height,
                fallback: tertiarySize.height,
                maximum: tertiaryMaximumSize.height
            )
        )
    }

    static func normalizedTertiarySourceOffset(_ sourceOffset: CGFloat?) -> CGFloat? {
        guard let sourceOffset, sourceOffset.isFinite else { return nil }
        return max(0, sourceOffset)
    }

    /// The top edge of each module in the fixed six-row combined overview.
    /// Detailed keeps this exact visual structure, so its shorter attached
    /// pages can remain anchored to the same row instead of inheriting the
    /// upward clamp required by the taller Geek page.
    private static func overviewAnchorOffset(for section: PanelSection) -> CGFloat {
        switch section {
        case .overview, .processor: 0
        case .memory: 135
        case .disk: 254
        case .network: 303
        case .sensors: 410
        case .power: 505
        case .cleanup: 0
        }
    }

    static func detailSize(for section: PanelSection) -> CGSize {
        switch section {
        case .overview: .zero
        case .processor: CGSize(width: detailWidth, height: 561)
        case .memory: CGSize(width: detailWidth, height: 465)
        case .disk: CGSize(width: detailWidth, height: 400)
        case .network: CGSize(width: detailWidth, height: 483)
        // The sensor page keeps every real reading visible, using a compact
        // two-column temperature grid to avoid scrolling in the fixed panel.
        case .sensors: CGSize(width: detailWidth, height: sensorsDetailHeight)
        case .power: CGSize(width: powerDetailWidth, height: 365)
        case .cleanup: CGSize(width: detailWidth, height: 420)
        }
    }

    static func detailSize(for section: PanelSection, density: PanelDensity) -> CGSize {
        guard density == .complex else { return detailSize(for: section) }
        return switch section {
        case .overview: .zero
        case .processor: CGSize(width: detailWidth, height: 368)
        case .memory: CGSize(width: detailWidth, height: 334)
        case .disk: CGSize(width: detailWidth, height: 281)
        // Detailed keeps the shared interface/address/details stack while
        // omitting the public-address card and the extended session rows.
        case .network: CGSize(width: detailWidth, height: 367)
        case .sensors: CGSize(width: detailWidth, height: 414)
        case .power: CGSize(width: powerDetailWidth, height: 257)
        // Cleanup has an adaptive action grid and remains scrollable.
        case .cleanup: CGSize(width: detailWidth, height: 360)
        }
    }

    static func normalizedDetailSize(
        _ preferredSize: CGSize?,
        for section: PanelSection,
        density: PanelDensity
    ) -> CGSize {
        let maximumSize = detailSize(for: section, density: density)
        guard section != .overview,
              let preferredSize,
              preferredSize.height.isFinite,
              preferredSize.height > 0 else { return maximumSize }
        return CGSize(
            width: maximumSize.width,
            height: min(preferredSize.height.rounded(.up), maximumSize.height)
        )
    }

    static func detailVerticalOffset(for section: PanelSection) -> CGFloat {
        detailVerticalOffset(for: section, density: .geek)
    }

    static func detailVerticalOffset(
        for section: PanelSection,
        density: PanelDensity,
        detailSize requestedDetailSize: CGSize? = nil,
        overviewSize requestedOverviewSize: CGSize = GeekPanelPresentationMetrics.overviewSize
    ) -> CGFloat {
        guard section != .overview, section != .network else { return 0 }
        let detailHeight = normalizedDetailSize(
            requestedDetailSize,
            for: section,
            density: density
        ).height
        let maximumOffset = max(0, requestedOverviewSize.height - detailHeight)
        return min(overviewAnchorOffset(for: section), maximumOffset)
    }

    static func expandedSize(for section: PanelSection) -> CGSize {
        expandedSize(for: section, detailSize: detailSize(for: section))
    }

    static func expandedSize(
        for section: PanelSection,
        density: PanelDensity,
        detailSize requestedDetailSize: CGSize? = nil,
        overviewSize requestedOverviewSize: CGSize = GeekPanelPresentationMetrics.overviewSize
    ) -> CGSize {
        let normalizedDetailSize = normalizedDetailSize(
            requestedDetailSize,
            for: section,
            density: density
        )
        return expandedSize(
            for: section,
            detailSize: normalizedDetailSize,
            detailOffset: detailVerticalOffset(
                for: section,
                density: density,
                detailSize: normalizedDetailSize,
                overviewSize: requestedOverviewSize
            ),
            overviewSize: requestedOverviewSize
        )
    }

    static func expandedSize(
        for section: PanelSection,
        density: PanelDensity,
        includesTertiaryColumn: Bool,
        detailSize requestedDetailSize: CGSize? = nil,
        tertiarySize requestedTertiarySize: CGSize = GeekPanelPresentationMetrics.tertiarySize,
        overviewSize requestedOverviewSize: CGSize = GeekPanelPresentationMetrics.overviewSize
    ) -> CGSize {
        let base = expandedSize(
            for: section,
            density: density,
            detailSize: requestedDetailSize,
            overviewSize: requestedOverviewSize
        )
        guard section != .overview, includesTertiaryColumn else { return base }
        let normalizedSize = normalizedTertiarySize(requestedTertiarySize)
        return CGSize(
            width: base.width + MiniWindowStyleTokens.cascadeGap + normalizedSize.width,
            height: base.height
        )
    }

    static func tertiaryVerticalOffset(
        for section: PanelSection,
        density: PanelDensity,
        detailSize requestedDetailSize: CGSize? = nil,
        detailTopOffset: CGFloat? = nil,
        tertiarySize _: CGSize = GeekPanelPresentationMetrics.tertiarySize,
        sourceOffset: CGFloat? = nil,
        overviewSize requestedOverviewSize: CGSize = GeekPanelPresentationMetrics.overviewSize
    ) -> CGFloat {
        let resolvedDetailTopOffset = detailTopOffset.flatMap { offset in
            offset.isFinite ? max(0, offset) : nil
        } ?? detailVerticalOffset(
            for: section,
            density: density,
            detailSize: requestedDetailSize,
            overviewSize: requestedOverviewSize
        )
        let triggerOffset = normalizedTertiarySourceOffset(sourceOffset) ?? 0
        return resolvedDetailTopOffset + triggerOffset
    }

    private static func normalizedTertiaryDimension(
        _ value: CGFloat,
        fallback: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, tertiaryMinimumDimension), maximum)
    }

    private static func expandedSize(
        for section: PanelSection,
        detailSize: CGSize,
        detailOffset: CGFloat? = nil,
        overviewSize requestedOverviewSize: CGSize = GeekPanelPresentationMetrics.overviewSize
    ) -> CGSize {
        guard section != .overview else { return requestedOverviewSize }
        return CGSize(
            width: requestedOverviewSize.width
                + MiniWindowStyleTokens.cascadeGap
                + detailSize.width,
            height: max(
                requestedOverviewSize.height,
                (detailOffset ?? detailVerticalOffset(for: section)) + detailSize.height
            )
        )
    }
}

enum MenuBarMetricKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case cpuUsage
    case gpuUsage
    case memoryUsage
    case chipTemperature
    case fanSpeed
    case networkSpeed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuUsage:
            L10n.text("CPU 使用率", "CPU Usage")
        case .gpuUsage:
            L10n.text("GPU 负载", "GPU Usage")
        case .memoryUsage:
            L10n.text("内存使用率", "Memory Usage")
        case .chipTemperature:
            L10n.text("芯片温度", "Chip Temperature")
        case .fanSpeed:
            L10n.text("风扇转速", "Fan Speed")
        case .networkSpeed:
            L10n.text("网络上下行", "Network Up/Down")
        }
    }

    var systemImage: String {
        switch self {
        case .cpuUsage:
            AppSymbols.Monitor.processor
        case .gpuUsage:
            AppSymbols.Monitor.graphics
        case .memoryUsage:
            AppSymbols.Monitor.memory
        case .chipTemperature:
            "thermometer.medium"
        case .fanSpeed:
            AppSymbols.Monitor.sensors
        case .networkSpeed:
            AppSymbols.Monitor.network
        }
    }

    static var defaultSelection: Set<MenuBarMetricKind> {
        Set(allCases)
    }
}

/// What the resident menu-bar status item shows between panel opens. The
/// hover panel is unchanged; this only selects the always-visible summary.
enum MenuBarStatusDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case deviceStatus
    case memory
    case cpu
    case cpuAndMemory
    case network
    case temperature

    static let defaultsKey = "menuBar.statusDisplay.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deviceStatus:
            L10n.text("设备状态（自动）", "Device Status (Auto)")
        case .memory:
            L10n.text("内存占用", "Memory Usage")
        case .cpu:
            L10n.text("CPU 占用", "CPU Usage")
        case .cpuAndMemory:
            L10n.text("CPU + 内存", "CPU + Memory")
        case .network:
            L10n.text("网络速率", "Network Speed")
        case .temperature:
            L10n.text("芯片温度", "Chip Temperature")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> MenuBarStatusDisplayMode {
        defaults.string(forKey: defaultsKey)
            .flatMap(MenuBarStatusDisplayMode.init(rawValue:)) ?? .deviceStatus
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum MenuBarRefreshInterval: String, CaseIterable, Identifiable, Codable, Sendable {
    case oneSecond
    case twoSeconds
    case fiveSeconds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneSecond:
            "1s"
        case .twoSeconds:
            "2s"
        case .fiveSeconds:
            "5s"
        }
    }

    var pickerTitle: String {
        switch self {
        case .oneSecond:
            L10n.text("1 秒", "1 second")
        case .twoSeconds:
            L10n.text("2 秒", "2 seconds")
        case .fiveSeconds:
            L10n.text("5 秒", "5 seconds")
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .oneSecond:
            1
        case .twoSeconds:
            2
        case .fiveSeconds:
            5
        }
    }

    var sleepNanoseconds: UInt64 {
        UInt64(seconds * 1_000_000_000)
    }

    func sleepNanoseconds(
        panelVisible: Bool,
        statusDisplayMode: MenuBarStatusDisplayMode,
        customFanControlActive: Bool,
        lowPowerMode: Bool
    ) -> UInt64 {
        // The status icon chooses a metric, not the history's sampling rate.
        // Keep cheap CPU/network reads continuous across opening and closing.
        // Background low-power gaps remain genuine gaps in the chart.
        let resolvedInterval: TimeInterval
        if customFanControlActive {
            resolvedInterval = min(seconds, SystemMonitorSamplingInterval.interactive)
        } else if lowPowerMode && !panelVisible {
            resolvedInterval = 30
        } else {
            resolvedInterval = seconds
        }
        return UInt64(resolvedInterval * 1_000_000_000)
    }

    var memorySnapshotSeconds: TimeInterval { seconds }

    static var defaultValue: MenuBarRefreshInterval {
        .oneSecond
    }
}

struct SystemMonitorMetric: Identifiable, Equatable, Sendable {
    let kind: MenuBarMetricKind
    let value: String
    let detail: String
    let isAvailable: Bool

    var id: MenuBarMetricKind { kind }
}

struct NetworkMonitorSample: Equatable, Sendable {
    let date: Date
    let receivedBytes: Int64
    let sentBytes: Int64
}

struct NetworkMonitorThroughput: Equatable, Sendable {
    let downBytesPerSecond: Int64
    let upBytesPerSecond: Int64
}

struct CPUUsageBreakdown: Equatable, Sendable {
    let totalPercent: Double
    let userPercent: Double
    let systemPercent: Double
}

struct SystemLoadAverage: Equatable, Sendable {
    let oneMinute: Double
    let fiveMinutes: Double
    let fifteenMinutes: Double
}

enum SystemThermalState: String, Equatable, Sendable {
    case unknown
    case nominal
    case fair
    case serious
    case critical
}

enum SystemSensorAvailability: Equatable, Sendable {
    case sampling
    case available
    case unavailable
}

enum SystemTemperatureZone: String, CaseIterable, Codable, Hashable, Sendable {
    case chip
    case soc
    case performanceCores
    case superCores
    case efficiencyCores
    case gpu
    case storage
    case battery
    case ambient
    case palmRest
    case thunderboltLeft
    case thunderboltRight
    case wifi
}

struct SystemTemperatureReading: Codable, Equatable, Sendable, Identifiable {
    let zone: SystemTemperatureZone
    let celsius: Double

    var id: SystemTemperatureZone { zone }
}

enum SystemFanIdentity: Codable, Equatable, Sendable {
    case left
    case right
    case cpu
    case gpu
    case storage
    case opticalDrive
    case powerSupply
    case exhaust
    case intake
    case named(String)
}

struct SystemFanReading: Codable, Equatable, Sendable, Identifiable {
    let index: Int
    let identity: SystemFanIdentity?
    let actualRPM: Int
    let minimumRPM: Int?
    let maximumRPM: Int?
    let targetRPM: Int?

    init(
        index: Int,
        identity: SystemFanIdentity? = nil,
        actualRPM: Int,
        minimumRPM: Int?,
        maximumRPM: Int?,
        targetRPM: Int?
    ) {
        self.index = index
        self.identity = identity
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
    }

    var id: Int { index }

    var normalizedPercent: Double? {
        guard let minimumRPM,
              let maximumRPM,
              maximumRPM > minimumRPM else { return nil }
        return min(
            100,
            max(0, Double(actualRPM - minimumRPM) / Double(maximumRPM - minimumRPM) * 100)
        )
    }

    var displayName: String {
        switch identity {
        case .left:
            return L10n.text("左侧风扇", "Left Fan")
        case .right:
            return L10n.text("右侧风扇", "Right Fan")
        case .cpu:
            return L10n.text("CPU 风扇", "CPU Fan")
        case .gpu:
            return L10n.text("GPU 风扇", "GPU Fan")
        case .storage:
            return L10n.text("存储风扇", "Storage Fan")
        case .opticalDrive:
            return L10n.text("光驱风扇", "Optical Drive Fan")
        case .powerSupply:
            return L10n.text("电源风扇", "Power Supply Fan")
        case .exhaust:
            return L10n.text("排风扇", "Exhaust Fan")
        case .intake:
            return L10n.text("进风扇", "Intake Fan")
        case let .named(name):
            return name
        case nil:
            return L10n.text("风扇 \(index + 1)", "Fan \(index + 1)")
        }
    }

    var displayRPM: String {
        SystemFanSpeedFormat.string(actualRPM)
    }
}

enum SystemFanSpeedFormat {
    static func number(_ rpm: Int) -> String {
        let digits = Array(String(max(0, rpm)))
        var groups: [String] = []
        var end = digits.count
        while end > 0 {
            let start = max(0, end - 3)
            groups.append(String(digits[start..<end]))
            end = start
        }
        return groups.reversed().joined(separator: ",")
    }

    static func string(_ rpm: Int) -> String {
        "\(number(rpm)) rpm"
    }
}

struct SystemMonitorSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let metrics: [SystemMonitorMetric]
    let networkThroughput: NetworkMonitorThroughput?
    let cpuUsageBreakdown: CPUUsageBreakdown?
    let cpuCoreUsagePercent: [Double]?
    let loadAverage: SystemLoadAverage?
    let systemUptimeSeconds: TimeInterval
    let thermalState: SystemThermalState
    let fanSpeedsRPM: [Int]?
    /// A successful SMC FNum read; zero is confirmed fanless, nil is unknown.
    let fanCount: Int?
    let fanReadings: [SystemFanReading]?
    let temperatureReadings: [SystemTemperatureReading]?
    let gpuMemoryUsedBytes: Int64?
    let sensorAvailability: SystemSensorAvailability
    let fanAvailability: SystemSensorAvailability

    init(
        generatedAt: Date,
        metrics: [SystemMonitorMetric],
        networkThroughput: NetworkMonitorThroughput?,
        cpuUsageBreakdown: CPUUsageBreakdown? = nil,
        cpuCoreUsagePercent: [Double]? = nil,
        loadAverage: SystemLoadAverage? = nil,
        systemUptimeSeconds: TimeInterval = 0,
        thermalState: SystemThermalState = .unknown,
        fanSpeedsRPM: [Int]? = nil,
        fanCount: Int? = nil,
        fanReadings: [SystemFanReading]? = nil,
        temperatureReadings: [SystemTemperatureReading]? = nil,
        gpuMemoryUsedBytes: Int64? = nil,
        sensorAvailability: SystemSensorAvailability? = nil,
        fanAvailability: SystemSensorAvailability? = nil
    ) {
        self.generatedAt = generatedAt
        self.metrics = metrics
        self.networkThroughput = networkThroughput
        self.cpuUsageBreakdown = cpuUsageBreakdown
        if let cpuCoreUsagePercent,
           !cpuCoreUsagePercent.isEmpty,
           cpuCoreUsagePercent.count <= 256,
           cpuCoreUsagePercent.allSatisfy({ $0.isFinite && (0...100).contains($0) }) {
            self.cpuCoreUsagePercent = cpuCoreUsagePercent
        } else {
            self.cpuCoreUsagePercent = nil
        }
        self.loadAverage = loadAverage
        self.systemUptimeSeconds = max(0, systemUptimeSeconds)
        self.thermalState = thermalState
        self.fanCount = fanCount.flatMap { (0...16).contains($0) ? $0 : nil }
        if let fanSpeedsRPM,
           !fanSpeedsRPM.isEmpty,
           fanSpeedsRPM.count <= 16,
           fanSpeedsRPM.allSatisfy({ (0...20_000).contains($0) }) {
            self.fanSpeedsRPM = fanSpeedsRPM
        } else {
            self.fanSpeedsRPM = nil
        }
        if let fanReadings,
           !fanReadings.isEmpty,
           fanReadings.count <= 16,
           Set(fanReadings.map(\.index)).count == fanReadings.count,
           fanReadings.allSatisfy({ reading in
               (0...20_000).contains(reading.actualRPM)
                   && reading.minimumRPM.map { (0...20_000).contains($0) } ?? true
                   && reading.maximumRPM.map { (0...20_000).contains($0) } ?? true
                   && reading.targetRPM.map { (0...20_000).contains($0) } ?? true
           }) {
            self.fanReadings = fanReadings
        } else {
            self.fanReadings = nil
        }
        if let temperatureReadings,
           !temperatureReadings.isEmpty,
           temperatureReadings.count <= SystemTemperatureZone.allCases.count,
           Set(temperatureReadings.map(\.zone)).count == temperatureReadings.count,
           temperatureReadings.allSatisfy({ $0.celsius.isFinite && (5...130).contains($0.celsius) }) {
            self.temperatureReadings = temperatureReadings
        } else {
            self.temperatureReadings = nil
        }
        if let gpuMemoryUsedBytes, gpuMemoryUsedBytes >= 0 {
            self.gpuMemoryUsedBytes = gpuMemoryUsedBytes
        } else {
            self.gpuMemoryUsedBytes = nil
        }
        self.sensorAvailability = sensorAvailability ?? (
            metrics.contains { metric in
                metric.isAvailable
                    && [.gpuUsage, .chipTemperature, .fanSpeed].contains(metric.kind)
            }
                || self.fanSpeedsRPM != nil
                || self.fanReadings != nil
                || self.temperatureReadings != nil
                ? .available
                : .unavailable
        )
        self.fanAvailability = self.fanReadings != nil || self.fanSpeedsRPM != nil || self.fanCount == 0
            ? .available
            : ((fanAvailability ?? sensorAvailability) == .sampling ? .sampling : .unavailable)
    }

    func metric(for kind: MenuBarMetricKind) -> SystemMonitorMetric? {
        metrics.first { $0.kind == kind }
    }
}
