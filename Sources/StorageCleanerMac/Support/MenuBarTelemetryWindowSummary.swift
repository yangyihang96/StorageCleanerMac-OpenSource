import Foundation

/// Facts about one prepared telemetry window that the sensors pages show
/// (review of phase 1, P2-1). They are computed with the window, off the main
/// thread (`MenuBarMonitorState`), because walking a 7- or 28-day window on
/// every redraw of the page cost the main thread several milliseconds each
/// time. Each fact is the computation the pages made before.
struct MenuBarTelemetryWindowSummary: Sendable, Equatable {
    /// Of chip and GPU temperature, the channels with a drawable trend
    /// (`PanelChartSampling.hasRenderableTrend`).
    let renderableTemperatureChannels: Set<MenuBarTelemetryChannel>
    /// A fan target speed was recorded in the window.
    let hasFanTarget: Bool
    /// The largest finite fan speed or fan target in the window.
    let fanMaximum: Double?
    let gpuTemperatureStatistics: GeekSeriesStatistics?
    /// D133: the highest chip or GPU temperature (a folded minute's peak),
    /// for iStat's temperature scale.
    let temperaturePeak: Double?

    static let temperatureChannels: [MenuBarTelemetryChannel] = [.chipTemperature, .gpuTemperature]

    init(points: [MenuBarTelemetryPoint]) {
        renderableTemperatureChannels = Set(Self.temperatureChannels.filter { channel in
            PanelChartSampling.hasRenderableTrend(MenuBarTelemetryPoint.historyPoints(points, channels: [channel]).map {
                MenuBarChartSample(date: $0.date, value: channel.value(in: $0)
            ) })
        })
        hasFanTarget = points.contains { $0.fanTargetRPM?.isFinite == true }
        fanMaximum = points.lazy
            .flatMap { [$0.fanRPM, $0.fanTargetRPM].compactMap { $0 } }
            .filter(\.isFinite)
            .max()
        gpuTemperatureStatistics = GeekSeriesStatistics(values: points.compactMap(\.gpuTemperature))
        temperaturePeak = points.lazy
            .flatMap { point in Self.temperatureChannels.compactMap { $0.peak(in: point) } }
            .filter(\.isFinite)
            .max()
    }

    /// The fan chart's scale: `MenuBarChartGeometry.niceCeiling` of the
    /// window's fan readings, which depends only on their maximum.
    var fanTrendMaximum: Double {
        MenuBarChartGeometry.niceCeiling(for: fanMaximum.map { [$0] } ?? [], minimum: 1_000)
    }
}
