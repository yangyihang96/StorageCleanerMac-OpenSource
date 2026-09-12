import Foundation
import SwiftUI

enum GeekDashboardModuleWidth: String, CaseIterable, Codable, Sendable {
    case half
    case full

    var title: String {
        switch self {
        case .half: L10n.text("半宽", "Half Width")
        case .full: L10n.text("全宽", "Full Width")
        }
    }
}

enum GeekDashboardModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case coreMetrics
    case processorGraphics
    case network
    case memoryBreakdown
    case disk
    case sensors
    case fans
    case power
    case systemLoad
    case cleanupSummary

    var id: Self { self }

    /// Legacy cases remain decodable so existing on-disk configurations do
    /// not fail to load, but they are no longer selectable or rendered in the
    /// menu-bar overview.
    static var overviewCases: [Self] {
        allCases.filter(\.isAvailableInOverview)
    }

    var isAvailableInOverview: Bool {
        switch self {
        case .memoryBreakdown, .fans, .systemLoad, .cleanupSummary:
            false
        case .coreMetrics, .processorGraphics, .network, .disk, .sensors, .power:
            true
        }
    }

    var title: String {
        switch self {
        case .coreMetrics: L10n.text("内存与压力", "Memory & Pressure")
        case .processorGraphics: L10n.text("CPU 与 GPU", "CPU & GPU")
        case .network: L10n.text("网络", "Network")
        case .memoryBreakdown: L10n.text("内存构成", "Memory Breakdown")
        case .disk: L10n.text("磁盘", "Disk")
        case .sensors: L10n.text("传感器", "Sensors")
        case .fans: L10n.text("风扇", "Fans")
        case .power: L10n.text("电源", "Power")
        case .systemLoad: L10n.text("CPU 使用情况", "CPU Usage")
        case .cleanupSummary: L10n.text("清理摘要", "Cleanup Summary")
        }
    }

    var systemImage: String {
        switch self {
        case .coreMetrics: AppSymbols.Monitor.overview
        case .processorGraphics: AppSymbols.Monitor.processor
        case .network: AppSymbols.Monitor.network
        case .memoryBreakdown: AppSymbols.Monitor.memory
        case .disk: AppSymbols.Monitor.storage
        case .sensors: AppSymbols.Monitor.sensors
        case .fans: AppSymbols.Monitor.sensors
        case .power: AppSymbols.Monitor.power
        case .systemLoad: AppSymbols.Panel.utilization
        case .cleanupSummary: AppSymbols.Monitor.cleanup
        }
    }

    var defaultWidth: GeekDashboardModuleWidth {
        .full
    }

    var isWidthConfigurable: Bool {
        false
    }
}

enum GeekSummaryMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case cpu
    case gpu
    case memory
    case temperature
    case fans
    case battery
    case disk
    case network

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: L10n.text("内存", "Memory")
        case .temperature: L10n.text("温度", "Temperature")
        case .fans: L10n.text("风扇", "Fans")
        case .battery: L10n.text("电池", "Battery")
        case .disk: L10n.text("磁盘", "Disk")
        case .network: L10n.text("网络", "Network")
        }
    }

}

enum GeekChartRange: Int, CaseIterable, Identifiable, Codable, Sendable {
    case thirtySeconds = 30
    case oneMinute = 60
    // Retained for decoding older preferences.
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case oneHour = 3_600
    case threeHours = 10_800
    case sixHours = 21_600
    case twelveHours = 43_200
    case oneDay = 86_400
    case threeDays = 259_200
    case sevenDays = 604_800
    case fourteenDays = 1_209_600
    case twentyEightDays = 2_419_200

    static let allCases: [Self] = [
        .thirtySeconds,
        .oneMinute,
        .fiveMinutes,
        .tenMinutes,
        .fifteenMinutes,
        .oneHour,
        .threeHours,
        .sixHours,
        .twelveHours,
        .oneDay,
        .threeDays,
        .sevenDays,
        .fourteenDays,
        .twentyEightDays,
    ]

    var id: Int { rawValue }
    var duration: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .thirtySeconds: L10n.text("30 秒", "30 Seconds")
        case .oneMinute: L10n.text("60 秒", "60 Seconds")
        case .twoMinutes: L10n.text("120 秒", "120 Seconds")
        case .fiveMinutes: L10n.text("5 分钟", "5 Minutes")
        case .tenMinutes: L10n.text("10 分钟", "10 Minutes")
        case .fifteenMinutes: L10n.text("15 分钟", "15 Minutes")
        case .oneHour: L10n.text("1 小时", "1 Hour")
        case .threeHours: L10n.text("3 小时", "3 Hours")
        case .sixHours: L10n.text("6 小时", "6 Hours")
        case .twelveHours: L10n.text("12 小时", "12 Hours")
        case .oneDay: L10n.text("1 天", "1 Day")
        case .threeDays: L10n.text("3 天", "3 Days")
        case .sevenDays: L10n.text("7 天", "7 Days")
        case .fourteenDays: L10n.text("14 天", "14 Days")
        case .twentyEightDays: L10n.text("28 天", "28 Days")
        }
    }

    var normalized: Self {
        switch self {
        case .twoMinutes: .oneHour
        default: self
        }
    }
}

enum GeekChartRangeMetric: String, CaseIterable, Sendable {
    case cpu
    case gpu
    case memory
    case network
    case disk
    case temperature
    case fan
    case battery
    case energy

    var storageKey: String {
        "metric.\(rawValue)"
    }

    static func isStorageKey(_ key: String) -> Bool {
        allCases.contains { $0.storageKey == key }
    }
}

struct GeekChartRangeSelection: @unchecked Sendable {
    var range: GeekChartRange
    var select: (GeekChartRange) -> Void
}

private struct GeekChartRangeSelectionKey: EnvironmentKey {
    static let defaultValue = GeekChartRangeSelection(
        range: .oneHour,
        select: { _ in }
    )
}

extension EnvironmentValues {
    var geekChartRangeSelection: GeekChartRangeSelection {
        get { self[GeekChartRangeSelectionKey.self] }
        set { self[GeekChartRangeSelectionKey.self] = newValue }
    }
}

struct GeekDashboardModuleConfiguration: Identifiable, Codable, Equatable, Sendable {
    var module: GeekDashboardModule
    var isVisible: Bool
    var width: GeekDashboardModuleWidth

    var id: GeekDashboardModule { module }
}

struct GeekDashboardConfiguration: Codable, Equatable, Sendable {
    static let defaultsKey = "menuBar.geekDashboardConfiguration.v1"
    static let maximumSummaryMetricCount = 6

    var modules: [GeekDashboardModuleConfiguration]
    var summaryMetrics: [GeekSummaryMetric]
    var chartRange: GeekChartRange
    /// Kept optional so configurations written before 1.9.9 decode without
    /// migration loss; new installs use the same one-hour default everywhere.
    var powerChartRange: GeekChartRange? = nil

    static let defaultModuleOrder: [GeekDashboardModule] = [
        .processorGraphics,
        .coreMetrics,
        .disk,
        .network,
        .sensors,
        .power
    ]

    static let defaultValue = GeekDashboardConfiguration(
        modules: defaultModuleOrder.map { module in
            GeekDashboardModuleConfiguration(
                module: module,
                isVisible: [
                    .processorGraphics,
                    .coreMetrics,
                    .disk,
                    .network,
                    .sensors,
                    .power
                ].contains(module),
                width: module.defaultWidth
            )
        },
        summaryMetrics: [.cpu, .gpu, .memory, .temperature, .fans, .battery],
        chartRange: .oneHour,
        powerChartRange: .oneHour
    )

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return defaultValue
        }
        if decoded.matchesLegacyDefaultLayout {
            return defaultValue
        }
        return decoded.normalized()
    }

    func save(in defaults: UserDefaults = .standard) {
        let normalized = normalized()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func normalized() -> Self {
        var seenModules = Set<GeekDashboardModule>()
        var normalizedModules = modules.compactMap { item -> GeekDashboardModuleConfiguration? in
            guard item.module.isAvailableInOverview else { return nil }
            guard seenModules.insert(item.module).inserted else { return nil }
            var item = item
            if !item.module.isWidthConfigurable {
                item.width = item.module.defaultWidth
            }
            return item
        }
        for item in Self.defaultValue.modules where !seenModules.contains(item.module) {
            normalizedModules.append(item)
        }

        var seenMetrics = Set<GeekSummaryMetric>()
        var normalizedMetrics = summaryMetrics.filter { seenMetrics.insert($0).inserted }
        if normalizedMetrics.isEmpty {
            normalizedMetrics = Self.defaultValue.summaryMetrics
        }
        normalizedMetrics = Array(normalizedMetrics.prefix(Self.maximumSummaryMetricCount))

        return Self(
            modules: normalizedModules,
            summaryMetrics: normalizedMetrics,
            chartRange: chartRange.normalized,
            powerChartRange: powerChartRange?.normalized
        )
    }

    mutating func setModule(_ module: GeekDashboardModule, isVisible: Bool) {
        guard module.isAvailableInOverview else { return }
        guard let index = modules.firstIndex(where: { $0.module == module }) else { return }
        modules[index].isVisible = isVisible
    }

    mutating func setModule(_ module: GeekDashboardModule, width: GeekDashboardModuleWidth) {
        guard module.isAvailableInOverview,
              module.isWidthConfigurable,
              let index = modules.firstIndex(where: { $0.module == module }) else { return }
        modules[index].width = width
    }

    mutating func moveModule(_ module: GeekDashboardModule, by offset: Int) {
        guard module.isAvailableInOverview,
              let index = modules.firstIndex(where: { $0.module == module }) else { return }
        let destination = min(max(0, index + offset), modules.index(before: modules.endIndex))
        guard destination != index else { return }
        let item = modules.remove(at: index)
        modules.insert(item, at: destination)
    }

    mutating func moveModule(
        _ module: GeekDashboardModule,
        before target: GeekDashboardModule
    ) {
        guard module.isAvailableInOverview,
              target.isAvailableInOverview,
              module != target,
              let sourceIndex = modules.firstIndex(where: { $0.module == module }) else {
            return
        }
        let item = modules.remove(at: sourceIndex)
        guard let targetIndex = modules.firstIndex(where: { $0.module == target }) else {
            modules.insert(item, at: min(sourceIndex, modules.endIndex))
            return
        }
        modules.insert(item, at: targetIndex)
    }

    mutating func setSummaryMetric(_ metric: GeekSummaryMetric, isVisible: Bool) {
        if isVisible {
            guard !summaryMetrics.contains(metric),
                  summaryMetrics.count < Self.maximumSummaryMetricCount else { return }
            summaryMetrics.append(metric)
        } else {
            guard summaryMetrics.count > 1 else { return }
            summaryMetrics.removeAll { $0 == metric }
        }
    }

    private var matchesLegacyDefaultLayout: Bool {
        let legacyOrder = GeekDashboardModule.allCases
        guard modules.map(\.module) == legacyOrder,
              modules.allSatisfy({ item in
                  item.isVisible == (item.module != .fans)
              }),
              modules.allSatisfy({ item in
                  item.width == (item.module == .coreMetrics ? .full : .half)
              }),
              summaryMetrics == [.cpu, .gpu, .memory, .temperature, .fans, .battery],
              chartRange == .twoMinutes else {
            return false
        }
        return true
    }
}

struct GeekDashboardLayoutRow: Identifiable, Equatable, Sendable {
    let modules: [GeekDashboardModule]
    let isFullWidth: Bool

    var id: String {
        modules.map(\.rawValue).joined(separator: ":") + (isFullWidth ? ":full" : ":half")
    }
}

enum GeekDashboardLayoutPlanner {
    static func rows(
        for configurations: [GeekDashboardModuleConfiguration]
    ) -> [GeekDashboardLayoutRow] {
        var rows: [GeekDashboardLayoutRow] = []
        var pendingHalfWidth: GeekDashboardModule?

        for configuration in configurations
        where configuration.isVisible && configuration.module.isAvailableInOverview {
            if configuration.width == .full {
                if let pendingHalfWidth {
                    rows.append(GeekDashboardLayoutRow(modules: [pendingHalfWidth], isFullWidth: false))
                }
                pendingHalfWidth = nil
                rows.append(GeekDashboardLayoutRow(modules: [configuration.module], isFullWidth: true))
            } else if let previousHalfWidth = pendingHalfWidth {
                rows.append(GeekDashboardLayoutRow(
                    modules: [previousHalfWidth, configuration.module],
                    isFullWidth: true
                ))
                pendingHalfWidth = nil
            } else {
                pendingHalfWidth = configuration.module
            }
        }

        if let pendingHalfWidth {
            rows.append(GeekDashboardLayoutRow(modules: [pendingHalfWidth], isFullWidth: false))
        }
        return rows
    }

}

struct GeekDashboardCanvasBlock: Identifiable, Equatable, Sendable {
    let fullWidthModule: GeekDashboardModule?
    let orderedModules: [GeekDashboardModule]
    let primaryModules: [GeekDashboardModule]
    let secondaryModules: [GeekDashboardModule]

    var id: String {
        if let fullWidthModule {
            return "full:\(fullWidthModule.rawValue)"
        }
        return "columns:" + orderedModules.map(\.rawValue).joined(separator: ":")
    }
}

enum GeekDashboardCanvasPlanner {
    static func blocks(
        for configurations: [GeekDashboardModuleConfiguration]
    ) -> [GeekDashboardCanvasBlock] {
        var blocks: [GeekDashboardCanvasBlock] = []
        var pendingColumns: [GeekDashboardModule] = []

        func appendPendingColumns() {
            guard !pendingColumns.isEmpty else { return }
            blocks.append(
                GeekDashboardCanvasBlock(
                    fullWidthModule: nil,
                    orderedModules: pendingColumns,
                    primaryModules: pendingColumns.enumerated().compactMap { index, module in
                        index.isMultiple(of: 2) ? module : nil
                    },
                    secondaryModules: pendingColumns.enumerated().compactMap { index, module in
                        index.isMultiple(of: 2) ? nil : module
                    }
                )
            )
            pendingColumns.removeAll(keepingCapacity: true)
        }

        for configuration in configurations
        where configuration.isVisible && configuration.module.isAvailableInOverview {
            if configuration.width == .full {
                appendPendingColumns()
                blocks.append(
                    GeekDashboardCanvasBlock(
                        fullWidthModule: configuration.module,
                        orderedModules: [configuration.module],
                        primaryModules: [],
                        secondaryModules: []
                    )
                )
            } else {
                pendingColumns.append(configuration.module)
            }
        }
        appendPendingColumns()
        return blocks
    }
}
