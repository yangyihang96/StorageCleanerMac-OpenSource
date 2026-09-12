import SwiftUI

@MainActor
final class MenuBarPanelSettingsState: ObservableObject {
    static let alwaysOnTopDefaultsKey = "menuBar.panelAlwaysOnTop"
    static let restoreOnLaunchDefaultsKey = "menuBar.restorePanelOnLaunch"
    static let chartRangesDefaultsKey = "menuBar.geekChartRanges.v1"

    @Published private(set) var selectedDensity: PanelDensity
    @Published private(set) var selectedSection: PanelSection
    @Published private(set) var isAlwaysOnTop: Bool
    @Published private(set) var restoresOnLaunch: Bool
    @Published private(set) var isGeekEditorPresented: Bool
    @Published private(set) var geekDashboardConfiguration: GeekDashboardConfiguration
    @Published private(set) var geekChartRanges: [String: GeekChartRange]
    @Published private(set) var cascadeDirection = MenuBarCascadeDirection.left
    @Published private(set) var secondaryPresentationMode = MenuBarSecondaryPresentationMode.adjacent
    @Published private(set) var tertiaryPresentationMode = MenuBarTertiaryPresentationMode.column
    @Published private(set) var cascadeLayout: MenuBarCascadeLayout?
    @Published private(set) var refreshGeneration = 0
    private var configurationBeforeEditing: GeekDashboardConfiguration?
    private let defaults: UserDefaults

    init(
        initialDensity: PanelDensity,
        selectedSection: PanelSection? = nil,
        isGeekEditorPresented: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        selectedDensity = initialDensity
        self.selectedSection = selectedSection ?? PanelSection.stored(in: defaults)
        self.isGeekEditorPresented = isGeekEditorPresented
        isAlwaysOnTop = defaults.object(forKey: Self.alwaysOnTopDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: Self.alwaysOnTopDefaultsKey)
        restoresOnLaunch = defaults.bool(forKey: Self.restoreOnLaunchDefaultsKey)
#if DEBUG || STORAGE_CLEANER_BETA
        geekDashboardConfiguration = MiniWindowDemoData.isEnabled
            ? .defaultValue
            : GeekDashboardConfiguration.stored(in: defaults)
#else
        geekDashboardConfiguration = GeekDashboardConfiguration.stored(in: defaults)
#endif
        geekChartRanges = Self.chartRanges(in: defaults)
        if isGeekEditorPresented { configurationBeforeEditing = geekDashboardConfiguration }
    }

    func presentGeekEditor() {
        guard !isGeekEditorPresented else { return }
        configurationBeforeEditing = geekDashboardConfiguration
        isGeekEditorPresented = true
    }

    func dismissGeekEditor() {
        guard configurationBeforeEditing != nil else { return }
        geekDashboardConfiguration.save(in: defaults)
        configurationBeforeEditing = nil
        isGeekEditorPresented = false
    }

    func cancelGeekEditor() {
        guard let configurationBeforeEditing else { return }
        geekDashboardConfiguration = configurationBeforeEditing
        self.configurationBeforeEditing = nil
        isGeekEditorPresented = false
    }

    func selectDensity(_ density: PanelDensity) {
        selectedDensity = density
        defaults.set(density.rawValue, forKey: PanelDensity.defaultsKey)
    }

    func synchronizeDensity(_ density: PanelDensity) {
        selectedDensity = density
    }

    func selectSection(_ section: PanelSection) {
        selectedSection = section
        defaults.set(section.rawValue, forKey: PanelSection.defaultsKey)
    }

    func setAlwaysOnTop(_ value: Bool) {
        isAlwaysOnTop = value
        defaults.set(value, forKey: Self.alwaysOnTopDefaultsKey)
    }

    func setRestoresOnLaunch(_ value: Bool) {
        restoresOnLaunch = value
        defaults.set(value, forKey: Self.restoreOnLaunchDefaultsKey)
    }

    func requestRefresh() {
        refreshGeneration &+= 1
    }

    func setCascadeDirection(_ direction: MenuBarCascadeDirection) {
        cascadeDirection = direction
    }

    func setSecondaryPresentationMode(_ mode: MenuBarSecondaryPresentationMode) {
        secondaryPresentationMode = mode
    }

    func setTertiaryPresentationMode(_ mode: MenuBarTertiaryPresentationMode) {
        tertiaryPresentationMode = mode
    }

    func setCascadeLayout(_ layout: MenuBarCascadeLayout?) {
        cascadeLayout = layout
    }

    func updateGeekDashboardConfiguration(
        _ update: (inout GeekDashboardConfiguration) -> Void
    ) {
        var configuration = geekDashboardConfiguration
        update(&configuration)
        configuration = configuration.normalized()
        geekDashboardConfiguration = configuration
        if !isGeekEditorPresented {
            configuration.save(in: defaults)
        }
    }

    func geekChartRange(for section: PanelSection) -> GeekChartRange {
        let fallback = section == .power
            ? (geekDashboardConfiguration.powerChartRange ?? .oneHour)
            : geekDashboardConfiguration.chartRange
        return geekChartRanges[section.rawValue] ?? fallback
    }

    func geekChartRange(
        for metric: GeekChartRangeMetric,
        fallbackTo section: PanelSection
    ) -> GeekChartRange {
        geekChartRanges[metric.storageKey] ?? geekChartRange(for: section)
    }

    func setGeekChartRange(_ range: GeekChartRange, for section: PanelSection) {
        setGeekChartRange(range, forKey: section.rawValue)
    }

    func setGeekChartRange(_ range: GeekChartRange, for metric: GeekChartRangeMetric) {
        setGeekChartRange(range, forKey: metric.storageKey)
    }

    private func setGeekChartRange(_ range: GeekChartRange, forKey key: String) {
        var next = geekChartRanges
        next[key] = range.normalized
        guard next != geekChartRanges else { return }
        geekChartRanges = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.chartRangesDefaultsKey)
    }

    func resetGeekDashboardConfiguration() {
        geekDashboardConfiguration = .defaultValue
        if !isGeekEditorPresented {
            geekDashboardConfiguration.save(in: defaults)
        }
    }

    private static func chartRanges(in defaults: UserDefaults) -> [String: GeekChartRange] {
        guard let data = defaults.data(forKey: chartRangesDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: GeekChartRange].self, from: data) else {
            return [:]
        }
        return decoded.reduce(into: [:]) { result, entry in
            guard PanelSection(rawValue: entry.key) != nil
                || GeekChartRangeMetric.isStorageKey(entry.key) else { return }
            result[entry.key] = entry.value.normalized
        }
    }
}
