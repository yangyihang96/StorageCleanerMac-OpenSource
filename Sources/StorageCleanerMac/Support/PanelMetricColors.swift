import SwiftUI

/// The menu window has its own dark chrome in both appearance modes. Keep its
/// display palette uses the same pigments as the main window. Metric overrides
/// remain independent of surfaces and of system appearance.
enum MiniWindowColorPalette {
    static let blue = MonitorPalette.blue
    static let graphiteHeaderBlue = MonitorPalette.headerBlue
    static let pink = MonitorPalette.pink
    static let yellow = MonitorPalette.yellow
    static let lightBlue = MonitorPalette.lightBlue
    static let lightPink = MonitorPalette.lightPink
    static let lightYellow = MonitorPalette.lightYellow
    static let primaryText = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let secondaryText = MonitorPalette.secondaryText
    static let tertiaryText = MonitorPalette.tertiaryText
}

/// Data colors are independent of the panel surface and of the optional
/// one-color chart accent. Every stored override belongs to one metric only.
enum PanelMetricColorRole: String, CaseIterable, Identifiable {
    case sectionHeader, cpuUser, cpuSystem, gpu
    case memoryPressure, memoryApp, memoryWired, memoryCompressed, swap
    case diskRead, diskWrite, networkUpload, networkDownload
    case sensorGraph, battery, batteryHealth, batteryCharging, batteryDraining

    var id: String { rawValue }
    var defaultsKey: String { "menuBar.metricColor.\(rawValue)" }

    var title: String {
        switch self {
        case .sectionHeader: L10n.text("栏目标题", "Section Header")
        case .cpuUser: L10n.text("用户", "User")
        case .cpuSystem: L10n.text("系统", "System")
        case .gpu: "GPU"
        case .memoryPressure: L10n.text("内存压力", "Memory Pressure")
        // D4: same Chinese memory terms as the mini-window composition rows.
        case .memoryApp: L10n.text("应用", "App")
        case .memoryWired: L10n.text("联动", "Wired")
        case .memoryCompressed: L10n.text("压缩", "Compressed")
        case .swap: L10n.text("交换内存", "Swap")
        case .diskRead: L10n.text("读取", "Read")
        case .diskWrite: L10n.text("写入", "Write")
        case .networkUpload: L10n.text("上传", "Upload")
        case .networkDownload: L10n.text("下载", "Download")
        case .sensorGraph: L10n.text("传感器图表", "Sensor Graph")
        case .battery: L10n.text("电池", "Battery")
        case .batteryHealth: L10n.text("电池健康", "Battery Health")
        case .batteryCharging: L10n.text("充电", "Charging")
        case .batteryDraining: L10n.text("放电", "Draining")
        }
    }

    var defaultColor: Color {
        switch self {
        case .sectionHeader, .cpuUser, .gpu, .memoryPressure, .memoryApp,
             .swap, .diskWrite, .networkDownload, .sensorGraph,
             .battery, .batteryCharging:
            MiniWindowColorPalette.blue
        case .cpuSystem, .memoryWired, .diskRead, .networkUpload,
             .batteryHealth, .batteryDraining:
            MiniWindowColorPalette.pink
        case .memoryCompressed:
            MiniWindowColorPalette.yellow
        }
    }
}

struct PanelMetricColors {
    let sectionHeader: Color
    let cpuUser: Color
    let cpuSystem: Color
    let gpu: Color
    let gpuIsCustomized: Bool
    let memoryPressure: Color
    let memoryApp: Color
    let memoryWired: Color
    let memoryCompressed: Color
    let swap: Color
    let diskRead: Color
    let diskWrite: Color
    let networkUpload: Color
    let networkDownload: Color
    let sensorGraph: Color
    let sensorGraphIsCustomized: Bool
    let battery: Color
    let batteryHealth: Color
    let batteryCharging: Color
    let batteryDraining: Color

    init(
        visualMode: MiniWindowVisualMode = .black,
        lightSurface: Bool = false,
        surfaceAccent: Color? = nil,
        sectionHeader: String = "",
        cpuUser: String = "", cpuSystem: String = "",
        gpu: String = "", memoryPressure: String = "",
        memoryApp: String = "", memoryWired: String = "", memoryCompressed: String = "",
        swap: String = "", diskRead: String = "", diskWrite: String = "",
        networkUpload: String = "", networkDownload: String = "",
        sensorGraph: String = "", battery: String = "", batteryHealth: String = "",
        batteryCharging: String = "", batteryDraining: String = ""
    ) {
        func resolved(_ role: PanelMetricColorRole, _ stored: String) -> Color {
            if let override = PanelAppearancePreferences.color(from: stored) { return override }
            if role == .sectionHeader, let surfaceAccent { return surfaceAccent }
            if lightSurface {
                switch role {
                case .cpuSystem, .memoryWired, .diskRead, .networkUpload,
                     .batteryHealth, .batteryDraining:
                    return MiniWindowColorPalette.lightPink
                case .memoryCompressed:
                    return MiniWindowColorPalette.lightYellow
                default: return MiniWindowColorPalette.lightBlue
                }
            }
            if role == .sectionHeader, visualMode == .graphite {
                // iStat's original blue is legible as a graph stroke on
                // graphite, but small header text needs a brighter variant.
                return MiniWindowColorPalette.graphiteHeaderBlue
            }
            return role.defaultColor
        }
        self.sectionHeader = resolved(.sectionHeader, sectionHeader)
        self.cpuUser = resolved(.cpuUser, cpuUser)
        self.cpuSystem = resolved(.cpuSystem, cpuSystem)
        self.gpu = resolved(.gpu, gpu)
        self.gpuIsCustomized = PanelAppearancePreferences.color(from: gpu) != nil
        self.memoryPressure = resolved(.memoryPressure, memoryPressure)
        self.memoryApp = resolved(.memoryApp, memoryApp)
        self.memoryWired = resolved(.memoryWired, memoryWired)
        self.memoryCompressed = resolved(.memoryCompressed, memoryCompressed)
        self.swap = resolved(.swap, swap)
        self.diskRead = resolved(.diskRead, diskRead)
        self.diskWrite = resolved(.diskWrite, diskWrite)
        self.networkUpload = resolved(.networkUpload, networkUpload)
        self.networkDownload = resolved(.networkDownload, networkDownload)
        self.sensorGraph = resolved(.sensorGraph, sensorGraph)
        self.sensorGraphIsCustomized = PanelAppearancePreferences.color(from: sensorGraph) != nil
        self.battery = resolved(.battery, battery)
        self.batteryHealth = resolved(.batteryHealth, batteryHealth)
        self.batteryCharging = resolved(.batteryCharging, batteryCharging)
        self.batteryDraining = resolved(.batteryDraining, batteryDraining)
    }

    /// The memory-pressure ring and its history chart share this color: the
    /// metric color while pressure is normal, warning / destructive while it
    /// is elevated / critical, secondary while the level is unknown.
    func memoryPressure(for level: MemoryPressureLevel?) -> Color {
        switch level {
        case .critical: AppDesignTokens.Palette.destructive
        case .elevated: AppDesignTokens.Palette.warning
        case .normal: memoryPressure
        case nil: .secondary
        }
    }

    /// GPU ring and GPU history share this exit: a customized GPU color wins,
    /// then the panel's chart theme color, then the default GPU color.
    /// `MenuBarAdvancedStatusView.resolvedGPUTint` calls it.
    func gpu(chartAccent: Color?) -> Color {
        gpuIsCustomized ? gpu : (chartAccent ?? gpu)
    }

    /// Temperature and fan rings and their histories share this exit: a
    /// customized sensor color wins, then the chart theme color, then the
    /// default sensor color. `resolvedThermalTint` calls it.
    func sensorGraph(chartAccent: Color?) -> Color {
        sensorGraphIsCustomized ? sensorGraph : (chartAccent ?? sensorGraph)
    }

    /// The single temperature color rule for rings and histories: 80 °C
    /// warning, 90 °C destructive, otherwise (and while unknown) the sensor
    /// color exit.
    func temperature(_ celsius: Double?, chartAccent: Color?) -> Color {
        guard let celsius, celsius.isFinite else { return sensorGraph(chartAccent: chartAccent) }
        if celsius >= 90 { return AppDesignTokens.Palette.destructive }
        if celsius >= 80 { return AppDesignTokens.Palette.warning }
        return sensorGraph(chartAccent: chartAccent)
    }

    /// CPU load color for the data that shows total CPU use (the CPU card's
    /// total and the CPU usage row's total): 75 % warning, 90 % destructive,
    /// otherwise (and while unknown) the CPU user color. Headings keep the
    /// section-header color.
    func cpuLoad(_ percent: Double?) -> Color {
        guard let percent, percent.isFinite else { return cpuUser }
        if percent >= 90 { return AppDesignTokens.Palette.destructive }
        if percent >= 75 { return AppDesignTokens.Palette.warning }
        return cpuUser
    }

    func color(for role: PanelMetricColorRole) -> Color {
        switch role {
        case .sectionHeader: sectionHeader
        case .cpuUser: cpuUser
        case .cpuSystem: cpuSystem
        case .gpu: gpu
        case .memoryPressure: memoryPressure
        case .memoryApp: memoryApp
        case .memoryWired: memoryWired
        case .memoryCompressed: memoryCompressed
        case .swap: swap
        case .diskRead: diskRead
        case .diskWrite: diskWrite
        case .networkUpload: networkUpload
        case .networkDownload: networkDownload
        case .sensorGraph: sensorGraph
        case .battery: battery
        case .batteryHealth: batteryHealth
        case .batteryCharging: batteryCharging
        case .batteryDraining: batteryDraining
        }
    }
}

private struct PanelMetricColorsKey: EnvironmentKey {
    static let defaultValue = PanelMetricColors()
}

extension EnvironmentValues {
    var panelMetricColors: PanelMetricColors {
        get { self[PanelMetricColorsKey.self] }
        set { self[PanelMetricColorsKey.self] = newValue }
    }
}

/// Shared by the live panel and its static settings preview, so color edits
/// repaint both without rebuilding a sampling Store or losing the open route.
struct PanelMetricColorEnvironment: ViewModifier {
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.panelChromePalette) private var panelChromePalette
    @AppStorage("menuBar.metricColor.sectionHeader") private var sectionHeader = ""
    @AppStorage("menuBar.metricColor.cpuUser") private var cpuUser = ""
    @AppStorage("menuBar.metricColor.cpuSystem") private var cpuSystem = ""
    @AppStorage("menuBar.metricColor.gpu") private var gpu = ""
    @AppStorage("menuBar.metricColor.memoryPressure") private var memoryPressure = ""
    @AppStorage("menuBar.metricColor.memoryApp") private var memoryApp = ""
    @AppStorage("menuBar.metricColor.memoryWired") private var memoryWired = ""
    @AppStorage("menuBar.metricColor.memoryCompressed") private var memoryCompressed = ""
    @AppStorage("menuBar.metricColor.swap") private var swap = ""
    @AppStorage("menuBar.metricColor.diskRead") private var diskRead = ""
    @AppStorage("menuBar.metricColor.diskWrite") private var diskWrite = ""
    @AppStorage("menuBar.metricColor.networkUpload") private var networkUpload = ""
    @AppStorage("menuBar.metricColor.networkDownload") private var networkDownload = ""
    @AppStorage("menuBar.metricColor.sensorGraph") private var sensorGraph = ""
    @AppStorage("menuBar.metricColor.battery") private var battery = ""
    @AppStorage("menuBar.metricColor.batteryHealth") private var batteryHealth = ""
    @AppStorage("menuBar.metricColor.batteryCharging") private var batteryCharging = ""
    @AppStorage("menuBar.metricColor.batteryDraining") private var batteryDraining = ""

    func body(content: Content) -> some View {
        content.environment(\.panelMetricColors, PanelMetricColors(
            visualMode: visualMode,
            lightSurface: panelChromePalette?.controlScheme == .light,
            surfaceAccent: panelChromePalette?.accent,
            sectionHeader: sectionHeader,
            cpuUser: cpuUser, cpuSystem: cpuSystem,
            gpu: gpu, memoryPressure: memoryPressure,
            memoryApp: memoryApp, memoryWired: memoryWired, memoryCompressed: memoryCompressed,
            swap: swap, diskRead: diskRead, diskWrite: diskWrite,
            networkUpload: networkUpload, networkDownload: networkDownload,
            sensorGraph: sensorGraph, battery: battery, batteryHealth: batteryHealth,
            batteryCharging: batteryCharging, batteryDraining: batteryDraining
        ))
    }
}

struct PanelMetricColorPicker: View {
    let role: PanelMetricColorRole
    @AppStorage private var storedHex: String

    init(role: PanelMetricColorRole) {
        self.role = role
        _storedHex = AppStorage(wrappedValue: "", role.defaultsKey)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(role.title)
            Spacer(minLength: 8)
            ColorPicker(role.title, selection: Binding(
                get: { PanelAppearancePreferences.color(from: storedHex) ?? role.defaultColor },
                set: { storedHex = PanelAppearancePreferences.hexString(from: $0) ?? "" }
            ), supportsOpacity: false)
            .labelsHidden()
            .accessibilityLabel(role.title)
            Button(L10n.text("默认", "Default")) { storedHex = "" }
                .disabled(storedHex.isEmpty)
        }
        .frame(minHeight: AppControlSizes.minimumControlHeight)
    }
}
