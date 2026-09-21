import SwiftUI

enum GeekSensorPowerHoverDetailMetrics {
    static let sensorHistorySize = GeekHoverDetailMetrics.historySize
    static let compactSamplingSize = GeekHoverDetailMetrics.compactSize
    static let batterySize = CGSize(width: 220, height: 196)
    static let batteryHistorySize = CGSize(width: MiniWindowStyleTokens.compactHistoryWidth, height: 196)
    static let energyModeSize = CGSize(width: 170, height: 167)

    static func energyModeSize(groupCount: Int) -> CGSize {
        energyModeSize(rowCounts: Array(repeating: 3, count: max(0, groupCount)))
    }

    static func energyModeSize(rowCounts: [Int]) -> CGSize {
        let normalized = rowCounts.map { min(3, max(1, $0)) }
        let groupCount = normalized.count
        let groupHeights = normalized.reduce(CGFloat.zero) { partial, rowCount in
            partial + 18 + CGFloat(rowCount) * 18
        }
        let spacing = CGFloat(max(0, groupCount - 1)) * 8
        let calculatedHeight = 16 + groupHeights + spacing
        let height = groupCount == 2 && normalized.allSatisfy({ $0 == 3 })
            ? energyModeSize.height
            : calculatedHeight
        return CGSize(
            width: energyModeSize.width,
            height: max(70, height)
        )
    }

    static func popoverSize(sampleCount: Int, expandedSize: CGSize) -> CGSize {
        sampleCount >= PanelChartSampling.minimumRenderableSampleCount
            ? expandedSize
            : compactSamplingSize
    }
}

enum GeekBatteryChartPalette {
    static let externalPower = AppDesignTokens.Palette.information
    static let battery = AppDesignTokens.Palette.sensitive
    static let health = AppDesignTokens.Palette.batteryHealth
    static let unknown = Color.secondary
}

enum GeekBatteryRemainingTime {
    struct Estimate: Equatable, Sendable {
        let minutes: Int
        let powerWatts: Double
        let sampleCount: Int
    }

    static func estimate(
        snapshot: BatteryPowerSnapshot?,
        electrical: NativeBatteryElectricalSnapshot?,
        history: [MenuBarPowerHistoryPoint],
        referenceDate: Date = Date()
    ) -> Estimate? {
        guard snapshot?.isDischarging == true,
              let electrical,
              let voltage = electrical.voltageVolts,
              voltage.isFinite,
              (5...30).contains(voltage),
              let remainingCapacityMAh = remainingCapacityMAh(
                snapshot: snapshot,
                electrical: electrical
              ) else { return nil }

        let recentPower = history.compactMap { point -> Double? in
            guard point.date >= referenceDate.addingTimeInterval(-300),
                  point.date <= referenceDate.addingTimeInterval(5),
                  point.powerSource == .batteryPower,
                  point.isCharging != true,
                  let watts = point.batteryPowerWatts.map(abs),
                  watts.isFinite,
                  (0.5...200).contains(watts) else { return nil }
            return watts
        }.sorted()
        guard recentPower.count >= 2 else { return nil }

        let middle = recentPower.count / 2
        let smoothedPower = recentPower.count.isMultiple(of: 2)
            ? (recentPower[middle - 1] + recentPower[middle]) / 2
            : recentPower[middle]
        let remainingWattHours = remainingCapacityMAh / 1_000 * voltage
        let rawMinutes = remainingWattHours / smoothedPower * 60
        guard rawMinutes.isFinite, (1...2_160).contains(rawMinutes) else { return nil }

        return Estimate(
            minutes: Int(rawMinutes.rounded()),
            powerWatts: smoothedPower,
            sampleCount: recentPower.count
        )
    }

    static func text(for minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            return L10n.text(
                "\(hours) 小时 \(remainder) 分",
                "\(hours)h \(remainder)m"
            )
        }
        return L10n.text("\(remainder) 分钟", "\(remainder)m")
    }

    private static func remainingCapacityMAh(
        snapshot: BatteryPowerSnapshot?,
        electrical: NativeBatteryElectricalSnapshot
    ) -> Double? {
        if let maximum = electrical.maximumCapacityMAh,
           maximum > 0,
           let percent = snapshot?.chargePercent,
           (1...100).contains(percent) {
            return Double(maximum) * Double(percent) / 100
        }
        guard let current = electrical.currentCapacityMAh, current > 0 else { return nil }
        return Double(current)
    }
}

struct GeekSensorMetricHoverDetail: View {
    let title: String
    let currentValue: String
    let points: [MenuBarTelemetryPoint]
    let channel: MenuBarTelemetryChannel?
    let unit: GeekChartUnit
    let valueRange: ClosedRange<Double>
    let tint: Color
    let duration: TimeInterval
    var secondaryTitle: String?
    var secondaryValue: String?

    var body: some View {
        GeekHoverDetailCanvas(
            title: title,
            trailing: currentValue,
            showsRangePicker: true
        ) {
            if hasRenderableHistory, let channel {
                GeekPrecisionLineChart(
                    points: points,
                    series: [
                        MenuBarTelemetrySeries(
                            id: "sensor-hover-\(channel.rawValue)",
                            title: title,
                            channel: channel,
                            color: tint
                        )
                    ],
                    valueRange: valueRange,
                    unit: unit,
                    accessibilityLabel: L10n.text(
                        "\(title)最近 \(Int(duration.rounded())) 秒趋势",
                        "\(title) trend over the last \(Int(duration.rounded())) seconds"
                    ),
                    style: .stackedBars,
                    duration: duration,
                    showsLegend: false,
                    showsTimelineLabels: false,
                    showsTooltip: true,
                    horizontalInset: 2,
                    showsSamplingDetails: false
                )
                .frame(height: hasSecondaryDetail ? 148 : 172)
            } else {
                Group {
                    if channel == nil {
                        GeekHoverUnavailableState(
                            text: L10n.text("此项目暂无历史数据", "History is unavailable for this item")
                        )
                    } else {
                        PanelChartSamplingPlaceholder()
                    }
                }
                .frame(height: hasSecondaryDetail ? 76 : 94)
            }

            if let secondaryTitle,
               let secondaryValue {
                GeekHoverValueRow(title: secondaryTitle, value: secondaryValue)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary)
    }

    private var values: [Double] {
        guard let channel else { return [] }
        return points.compactMap { channel.value(in: $0) }.filter(\.isFinite)
    }

    private var hasRenderableHistory: Bool {
        values.count >= PanelChartSampling.minimumRenderableSampleCount
    }

    private var statistics: GeekSeriesStatistics? {
        GeekSeriesStatistics(values: values)
    }

    private var hasSecondaryDetail: Bool {
        secondaryTitle != nil && secondaryValue != nil
    }

    private var durationText: String {
        L10n.text(
            "最近 \(Int(duration.rounded())) 秒",
            "Last \(Int(duration.rounded())) Seconds"
        )
    }

    private var statisticsHelpText: String {
        guard let statistics else { return PanelChartSampling.statusText }
        return L10n.text(
            "\(title)：当前 \(unit.formatted(statistics.current, compact: true))，最低 / 平均 / 最高 \(statisticsText(statistics))",
            "\(title): current \(unit.formatted(statistics.current, compact: true)); min / average / max \(statisticsText(statistics))"
        )
    }

    private var accessibilitySummary: String {
        if statistics != nil {
            return statisticsHelpText
        }
        return channel == nil
            ? L10n.text("当前 \(currentValue)，历史未采集", "Current \(currentValue); history not collected")
            : L10n.text("当前 \(currentValue)，正在采样", "Current \(currentValue); sampling")
    }

    private func statisticsText(_ statistics: GeekSeriesStatistics) -> String {
        [statistics.minimum, statistics.average, statistics.maximum]
            .map { unit.formatted($0, compact: true) }
            .joined(separator: " / ")
    }
}

enum GeekPowerHistoryMetric: Sendable {
    case charge
    case batteryPower

    var title: String {
        switch self {
        case .charge: L10n.text("电量", "Charge")
        case .batteryPower: L10n.text("电池功率", "Battery Power")
        }
    }

    func value(in point: MenuBarPowerHistoryPoint) -> Double? {
        switch self {
        case .charge: point.chargePercent
        case .batteryPower: point.batteryPowerWatts
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .charge: String(format: "%.0f%%", value)
        case .batteryPower: String(format: "%+.2f W", value)
        }
    }

    func currentText(_ value: Double) -> String {
        switch self {
        case .charge:
            return L10n.text("当前 \(formatted(value))", "Current \(formatted(value))")
        case .batteryPower:
            let state: String
            if value > 0.05 {
                state = L10n.text("充电", "Charging")
            } else if value < -0.05 {
                state = L10n.text("放电", "Discharging")
            } else {
                state = L10n.text("空闲", "Idle")
            }
            return L10n.text(
                "当前 \(formatted(value)) · \(state)",
                "Current \(formatted(value)) · \(state)"
            )
        }
    }

    func tooltipTitle(_ value: Double) -> String {
        guard case .batteryPower = self else {
            return L10n.text("电量", "Charge")
        }
        if value > 0.05 {
            return L10n.text("充电功率", "Charging Power")
        }
        if value < -0.05 {
            return L10n.text("放电功率", "Discharging Power")
        }
        return title
    }

    func tooltipDetail(
        isCharging: Bool?,
        powerSource: BatteryPowerSource?
    ) -> String? {
        guard case .charge = self else { return nil }
        switch powerSource ?? .unknown {
        case .acPower:
            if isCharging == true {
                return L10n.text("外接电源 · 正在充电", "External power · Charging")
            }
            return L10n.text("外接电源", "External power")
        case .batteryPower:
            return L10n.text("使用电池", "Using battery")
        case .unknown:
            return nil
        }
    }

    var meaningText: String? {
        guard case .batteryPower = self else { return nil }
        return L10n.text(
            "正值表示充电，负值表示放电。",
            "Positive values indicate charging; negative values indicate discharging."
        )
    }
}

enum GeekPowerHistoryScale {
    @available(*, deprecated, message: "Use PowerConnectionTimeline.connectedRuns")
    static let minimumChargeSpan = 20.0
    static let chargeBarWidth: CGFloat = 2
    static let connectionTimelineHeight: CGFloat = 4
    static let connectionTimelineGap: CGFloat = 4
    static let lightningBoltHeight: CGFloat = 10

    @available(*, deprecated, message: "Use PowerConnectionTimeline.connectedRuns")
    static func connectedRuns(statuses: [Bool?]) -> [ClosedRange<Int>] {
        PowerConnectionTimeline.connectedRuns(statuses: statuses)
    }

    static func chargeRange(values _: [Double]) -> ClosedRange<Double> {
        0...100
    }
}

enum PowerConnectionTimeline {
    static func connectedRuns(statuses: [Bool?]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for (index, status) in statuses.enumerated() {
            if status == true {
                runStart = runStart ?? index
            } else if let start = runStart {
                runs.append(start...(index - 1))
                runStart = nil
            }
        }
        if let runStart {
            runs.append(runStart...(statuses.count - 1))
        }
        return runs
    }

    static func segment(
        for run: ClosedRange<Int>,
        in buckets: [GeekChartBucketSnapshot],
        barWidth: CGFloat,
        rail: CGRect
    ) -> CGRect? {
        guard buckets.indices.contains(run.lowerBound),
              buckets.indices.contains(run.upperBound),
              barWidth > 0 else {
            return nil
        }

        let first = buckets[run.lowerBound]
        let last = buckets[run.upperBound]
        let lower = max(rail.minX, first.x - barWidth / 2)
        let upper = min(rail.maxX, last.x + barWidth / 2)
        guard upper > lower else { return nil }
        return CGRect(
            x: lower,
            y: rail.minY,
            width: upper - lower,
            height: rail.height
        )
    }
}

struct GeekPowerBucketPayload: Sendable {
    let value: Double
    let isCharging: Bool?
    let powerSource: BatteryPowerSource?
}

struct GeekPreparedPowerBucket: Sendable {
    let bucket: GeekChartBucketSnapshot
    let payload: GeekPowerBucketPayload
    let isEstimated: Bool
}

struct GeekPowerHistoryChart: View {
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor
    @Environment(\.displayScale) private var displayScale

    let points: [MenuBarPowerHistoryPoint]
    let metric: GeekPowerHistoryMetric
    let duration: TimeInterval
    let tint: Color
    var chargingTint: Color? = nil
    let accessibilityLabel: String
    var showsTimelineLabels = true
    var showsTooltip = false

    @State private var hoverLocation: CGPoint?

    var activeFrame: GeekPreparedPowerFrame? = nil
    private var preparationKernel: GeekPowerPreparationKernel {
        .init(points: points, metric: metric, duration: duration, displayScale: displayScale)
    }

    var body: some View {
        let kernel = preparationKernel
        return MenuBarChartPreparation(kind: "power-summary", first: points.first?.date, last: points.last?.date,
            count: points.count, configuration: "\(metric):\(duration)", cost: 512,
            build: { kernel.statistics }) { statistics in
            chartBody(statistics: statistics)
        }
    }

    private func chartBody(statistics: GeekSeriesStatistics?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if metric == .batteryPower {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(chartColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(metric.title)
                            .font(AdvancedPanelTypography.captionStrong)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let statistics {
                        Text(metric.currentText(statistics.current))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }

            GeekLiveChartTimeline(duration: duration) { referenceDate in
                chartContent(referenceDate: referenceDate)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilitySummary(statistics: statistics))
        .accessibilityHint(helpText(statistics: statistics))
        // The compact preview is hosted inside GeekHoverDetailTarget. Let that
        // parent own the hit test so its delayed tertiary reveal sees the hover.
        .allowsHitTesting(showsTooltip)
    }

    private func chartContent(referenceDate: Date) -> some View {
        let kernel = preparationKernel
        return GeometryReader { proxy in
            let timeline = showsTimelineLabels && metric == .batteryPower && proxy.size.height >= 70
            let rail = metric == .charge ? GeekPowerHistoryScale.connectionTimelineHeight + GeekPowerHistoryScale.connectionTimelineGap : 0
            let plot = CGRect(x: 2, y: 2, width: max(1, proxy.size.width - 4),
                              height: max(1, proxy.size.height - (timeline ? 20 : 4) - rail))
            MenuBarChartPreparation(kind: "power-frame", first: points.first?.date, last: points.last?.date,
                count: points.count, configuration: "\(metric):\(duration):\(plot):\(displayScale)",
                clockRevision: floor(referenceDate.timeIntervalSince1970), cost: max(1024, points.count * 320),
                build: { GeekPreparedPowerFrame(kernel: kernel, plot: plot, reference: referenceDate) }) { frame in
                    preparedChartContent(frame, referenceDate: referenceDate)
                }
        }
    }

    private func preparedChartContent(_ frame: GeekPreparedPowerFrame, referenceDate: Date) -> some View {
        var copy = self
        copy.activeFrame = frame
        return copy.renderChartContent(referenceDate: referenceDate)
    }

    @ViewBuilder
    private func renderChartContent(referenceDate: Date) -> some View {
        let livePoints = usablePoints(endingAt: referenceDate)
        let liveSamples = livePoints.map {
            MenuBarChartSample(date: $0.date, value: $0.value)
        }

        Group {
            if !PanelChartSampling.hasRenderableTrend(liveSamples) {
                PanelChartSamplingPlaceholder()
            } else {
                GeometryReader { proxy in
                    let shouldShowTimelineLabels = showsTimelineLabels
                        && metric == .batteryPower
                        && proxy.size.height >= 70
                    let connectionRailHeight: CGFloat = metric == .charge
                        ? GeekPowerHistoryScale.connectionTimelineHeight
                        : 0
                    let connectionRailGap: CGFloat = metric == .charge
                        ? GeekPowerHistoryScale.connectionTimelineGap
                        : 0
                    let plot = CGRect(
                        x: 2,
                        y: 2,
                        width: max(1, proxy.size.width - 4),
                        height: max(
                            1,
                            proxy.size.height
                                - (shouldShowTimelineLabels ? 20 : 4)
                                - connectionRailHeight
                                - connectionRailGap
                        )
                    )
                    let connectionRail = CGRect(
                        x: plot.minX,
                        y: plot.maxY + connectionRailGap,
                        width: plot.width,
                        height: connectionRailHeight
                    )

                    tooltipHoverTracking(
                        ZStack(alignment: .topLeading) {
                            Color.clear

                            Canvas { context, _ in
                                drawGrid(
                                    context: &context,
                                    plot: plot,
                                    referenceDate: referenceDate
                                )
                                drawBars(
                                    context: &context,
                                    plot: plot,
                                    referenceDate: referenceDate
                                )
                                drawPowerConnectionTimeline(
                                    context: &context,
                                    plot: plot,
                                    rail: connectionRail,
                                    referenceDate: referenceDate
                                )
                            }

                            if shouldShowTimelineLabels {
                                timelineLabels(in: plot, referenceDate: referenceDate)
                            }
                            if showsTooltip, proxy.size.height >= 82 {
                                hoverOverlay(in: plot, referenceDate: referenceDate)
                            }
                        }
                    )
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tooltipHoverTracking<Content: View>(_ content: Content) -> some View {
        if showsTooltip {
            content.onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoverLocation = location
                case .ended:
                    hoverLocation = nil
                }
            }
        } else {
            content
        }
    }

    func usablePoints(endingAt referenceDate: Date) -> [GeekPreparedPowerFrame.Point] {
        activeFrame?.points ?? preparationKernel.usablePoints(endingAt: referenceDate)
    }

    private func batteryBuckets(_ livePoints: [GeekPreparedPowerFrame.Point], plot: CGRect,
                                referenceDate: Date) -> [GeekChartBucketSnapshot] {
        activeFrame?.rawBuckets ?? preparationKernel.batteryBuckets(livePoints, plot: plot, referenceDate: referenceDate)
    }

    private func preparedBatteryBuckets(_ livePoints: [GeekPreparedPowerFrame.Point], plot: CGRect,
                                        referenceDate: Date) -> [GeekPreparedPowerBucket] {
        activeFrame?.buckets ?? preparationKernel.preparedBatteryBuckets(livePoints, plot: plot, referenceDate: referenceDate)
    }

    private func valueRange(for values: [Double]) -> ClosedRange<Double> {
        switch metric {
        case .charge:
            return GeekPowerHistoryScale.chargeRange(values: values)
        case .batteryPower:
            let lower = min(0, (values.min() ?? 0) * 1.12)
            let upper = max(1, (values.max() ?? 1) * 1.12)
            return lower...(upper - lower < 0.5 ? lower + 1 : upper)
        }
    }

    private var chartColor: Color {
        metric == .charge
            ? GeekBatteryChartPalette.externalPower
            : (panelChartAccentColor ?? tint)
    }

    private var chargeBarWidth: CGFloat {
        MiniWindowPixel.snappedLength(
            GeekPowerHistoryScale.chargeBarWidth,
            displayScale: displayScale
        )
    }

    private func drawGrid(
        context: inout GraphicsContext,
        plot: CGRect,
        referenceDate: Date
    ) {
        guard case .batteryPower = metric else { return }
        let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
        for step in 1...3 {
            let y = MiniWindowPixel.strokeCenter(
                plot.minY + plot.height * CGFloat(step) / 4,
                lineWidth: hairline,
                displayScale: displayScale
            )
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(Color.secondary.opacity(0.12)), lineWidth: hairline)
        }

        let livePoints = usablePoints(endingAt: referenceDate)
        let values = preparedBatteryBuckets(
            livePoints,
            plot: plot,
            referenceDate: referenceDate
        ).filter { !$0.isEstimated }.map(\.payload.value)
        let range = valueRange(for: values)
        let span = max(Double.ulpOfOne, range.upperBound - range.lowerBound)
        let zeroY = MiniWindowPixel.strokeCenter(
            plot.maxY - plot.height * CGFloat((0 - range.lowerBound) / span),
            lineWidth: hairline,
            displayScale: displayScale
        )
        var baseline = Path()
        baseline.move(to: CGPoint(x: plot.minX, y: zeroY))
        baseline.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
        context.stroke(
            baseline,
            with: .color(Color.secondary.opacity(0.42)),
            style: StrokeStyle(lineWidth: hairline, dash: [3, 2])
        )
    }

    private func drawBars(
        context: inout GraphicsContext,
        plot: CGRect,
        referenceDate: Date
    ) {
        let livePoints = usablePoints(endingAt: referenceDate)
        let sampleDates = livePoints.map(\.date)
        guard !sampleDates.isEmpty else { return }

        if metric == .charge {
            let preparedBuckets = preparedBatteryBuckets(
                livePoints,
                plot: plot,
                referenceDate: referenceDate
            )
            let range = GeekPowerHistoryScale.chargeRange(values: [])
            let span = range.upperBound - range.lowerBound
            let valuePlot = plot.insetBy(dx: 0, dy: plot.height > 4 ? 2 : 0)
            let baselineY = MiniWindowPixel.aligned(
                valuePlot.maxY,
                displayScale: displayScale
            )
            let barWidth = chargeBarWidth

            GeekChartDrawing.gaps(in: context, plot: plot,
                occupiedX: preparedBuckets.map { $0.bucket.x }, displayScale: displayScale)
            for prepared in preparedBuckets {
                let bucket = prepared.bucket
                let point = prepared.payload
                let value = point.value
                let valueFraction = (value - range.lowerBound) / span
                let valueY = MiniWindowPixel.aligned(
                    valuePlot.maxY - valuePlot.height * CGFloat(valueFraction),
                    displayScale: displayScale
                )
                let height = max(
                    MiniWindowPixel.onePhysicalPixel(displayScale: displayScale),
                    MiniWindowPixel.snappedLength(
                        abs(valueY - baselineY),
                        displayScale: displayScale
                    )
                )
                let y = MiniWindowPixel.aligned(
                    min(valueY, baselineY),
                    displayScale: displayScale
                )
                GeekChartDrawing.bar(in: context,
                    rect: CGRect(x: MiniWindowPixel.aligned(bucket.x - barWidth / 2, displayScale: displayScale),
                        y: y, width: barWidth, height: height),
                    color: barColor(for: point), estimated: prepared.isEstimated, displayScale: displayScale)
            }
            return
        }

        let preparedBuckets = preparedBatteryBuckets(
            livePoints,
            plot: plot,
            referenceDate: referenceDate
        )
        let range = valueRange(for: preparedBuckets.filter {
            !$0.isEstimated
        }.map(\.payload.value))
        let span = max(Double.ulpOfOne, range.upperBound - range.lowerBound)
        let valuePlot = metric == .charge && plot.height > 4
            ? plot.insetBy(dx: 0, dy: 2)
            : plot
        let baselineValue: Double
        switch metric {
        case .charge:
            baselineValue = range.lowerBound
        case .batteryPower:
            baselineValue = 0
        }
        let baselineFraction = (baselineValue - range.lowerBound) / span
        let baselineY = MiniWindowPixel.aligned(
            valuePlot.maxY - valuePlot.height * CGFloat(baselineFraction),
            displayScale: displayScale
        )
        let barWidth = metric == .charge
            ? chargeBarWidth
            : GeekChartWindow.barMetrics(displayScale: displayScale).width

        for prepared in preparedBuckets {
            let point = prepared.payload
            let value = point.value
            let valueFraction = (value - range.lowerBound) / span
            let valueY = MiniWindowPixel.aligned(
                valuePlot.maxY - valuePlot.height * CGFloat(valueFraction),
                displayScale: displayScale
            )
            let y = MiniWindowPixel.aligned(min(valueY, baselineY), displayScale: displayScale)
            let height = max(
                MiniWindowPixel.onePhysicalPixel(displayScale: displayScale),
                MiniWindowPixel.snappedLength(abs(valueY - baselineY), displayScale: displayScale)
            )
            GeekChartDrawing.bar(in: context,
                rect: CGRect(x: MiniWindowPixel.aligned(prepared.bucket.x - barWidth / 2, displayScale: displayScale),
                    y: y, width: barWidth, height: height),
                color: barColor(for: point), estimated: prepared.isEstimated, displayScale: displayScale)
        }
    }

    private func drawPowerConnectionTimeline(
        context: inout GraphicsContext,
        plot: CGRect,
        rail: CGRect,
        referenceDate: Date
    ) {
        guard metric == .charge, rail.height > 0 else { return }
        let livePoints = usablePoints(endingAt: referenceDate)
        let preparedBuckets = preparedBatteryBuckets(
            livePoints,
            plot: plot,
            referenceDate: referenceDate
        )
        let buckets = batteryBuckets(livePoints, plot: plot, referenceDate: referenceDate)
        let sourcesByStart = Dictionary(uniqueKeysWithValues: preparedBuckets.map {
            ($0.bucket.start, $0.payload.powerSource)
        })
        let statuses: [Bool?] = buckets.map { bucket -> Bool? in
            switch sourcesByStart[bucket.start] ?? nil {
            case .acPower: return true
            case .batteryPower: return false
            case .unknown, nil: return nil
            }
        }
        for run in PowerConnectionTimeline.connectedRuns(statuses: statuses) {
            guard let segment = PowerConnectionTimeline.segment(
                for: run,
                in: buckets,
                barWidth: chargeBarWidth,
                rail: rail
            ) else {
                continue
            }
            context.fill(
                Path(roundedRect: segment, cornerRadius: min(2, rail.height / 2)),
                with: .color(GeekBatteryChartPalette.externalPower)
            )
            if segment.width >= 14 {
                drawLightningBolt(context: &context, in: segment)
            }
        }
    }

    private func drawLightningBolt(
        context: inout GraphicsContext,
        in segment: CGRect
    ) {
        let center = CGPoint(x: segment.midX, y: segment.midY)
        let halfHeight = GeekPowerHistoryScale.lightningBoltHeight / 2
        var bolt = Path()
        bolt.move(to: CGPoint(x: center.x + 1, y: center.y - halfHeight))
        bolt.addLine(to: CGPoint(x: center.x - 3, y: center.y + 0.5))
        bolt.addLine(to: CGPoint(x: center.x - 0.5, y: center.y + 0.5))
        bolt.addLine(to: CGPoint(x: center.x - 1.5, y: center.y + halfHeight))
        bolt.addLine(to: CGPoint(x: center.x + 3, y: center.y - 1))
        bolt.addLine(to: CGPoint(x: center.x + 0.5, y: center.y - 1))
        bolt.closeSubpath()
        context.fill(bolt, with: .color(.white))
    }

    private func timelineLabels(
        in plot: CGRect,
        referenceDate: Date
    ) -> some View {
        GeekBarTimelineLabels(
            dates: usablePoints(endingAt: referenceDate).map(\.date),
            duration: duration,
            plotRect: plot,
            referenceDate: referenceDate
        )
    }

    @ViewBuilder
    private func hoverOverlay(
        in plot: CGRect,
        referenceDate: Date
    ) -> some View {
        if let hoveredPoint = hoveredPoint(
            in: plot,
            referenceDate: referenceDate
        ), let hoverLocation {
            let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
            let indicatorX = MiniWindowPixel.strokeCenter(
                hoveredPoint.x,
                lineWidth: hairline,
                displayScale: displayScale
            )
            Path { path in
                path.move(to: CGPoint(x: indicatorX, y: plot.minY))
                path.addLine(to: CGPoint(x: indicatorX, y: plot.maxY))
            }
            .stroke(.primary.opacity(0.72), style: StrokeStyle(lineWidth: hairline))

            GeekHoverTooltip(
                date: hoveredPoint.date,
                values: [
                    GeekHoverValue(
                        title: metric.tooltipTitle(hoveredPoint.point.value),
                        value: metric.formatted(hoveredPoint.point.value),
                        color: barColor(for: hoveredPoint.point),
                        isEstimated: hoveredPoint.isEstimated
                    )
                ],
                visibleDuration: duration,
                detail: metric.tooltipDetail(
                    isCharging: hoveredPoint.point.isCharging,
                    powerSource: hoveredPoint.point.powerSource
                )
            )
            .position(
                x: min(plot.maxX - 72, max(plot.minX + 72, hoverLocation.x)),
                y: plot.minY + 39
            )
        }
    }

    private func hoveredPoint(
        in plot: CGRect,
        referenceDate: Date
    ) -> (
        point: GeekPowerBucketPayload,
        date: Date,
        x: CGFloat,
        isEstimated: Bool
    )? {
        guard let hoverLocation,
              plot.insetBy(dx: -4, dy: -4).contains(hoverLocation),
              !points.isEmpty else { return nil }
        let livePoints = usablePoints(endingAt: referenceDate)
        let candidates = preparedBatteryBuckets(
            livePoints,
            plot: plot,
            referenceDate: referenceDate
        ).map { prepared -> (
            point: GeekPowerBucketPayload,
            date: Date,
            x: CGFloat,
            isEstimated: Bool
        ) in
            return (
                point: prepared.payload,
                date: prepared.bucket.end,
                x: prepared.bucket.x,
                isEstimated: prepared.isEstimated
            )
        }
        let nearest = candidates
        .min { abs($0.x - hoverLocation.x) < abs($1.x - hoverLocation.x) }
        guard let nearest,
                  abs(nearest.x - hoverLocation.x) <= max(
                      8,
                      (metric == .charge
                          ? GeekPowerHistoryScale.chargeBarWidth
                          : GeekChartWindow.barMarkWidth) * 2
              ) else {
            return nil
        }
        return nearest
    }

    private func barColor(
        for point: GeekPowerBucketPayload
    ) -> Color {
        guard metric == .charge else { return chartColor }
        switch point.powerSource ?? .unknown {
        case .acPower:
            return GeekBatteryChartPalette.externalPower
        case .batteryPower:
            return chargingTint ?? GeekBatteryChartPalette.battery
        case .unknown:
            return GeekBatteryChartPalette.unknown
        }
    }

    private func helpText(statistics: GeekSeriesStatistics?) -> String {
        [
            accessibilitySummary(statistics: statistics),
            metric.meaningText,
            TimeBucketAggregator.nearestFillDescription,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func accessibilitySummary(statistics: GeekSeriesStatistics?) -> String {
        guard let statistics else {
            return L10n.text("正在采样…", "Sampling…")
        }
        return L10n.text(
            "当前 \(metric.formatted(statistics.current))，最低 \(metric.formatted(statistics.minimum))，平均 \(metric.formatted(statistics.average))，最高 \(metric.formatted(statistics.maximum))",
            "Current \(metric.formatted(statistics.current)), minimum \(metric.formatted(statistics.minimum)), average \(metric.formatted(statistics.average)), maximum \(metric.formatted(statistics.maximum))"
        )
    }
}

struct GeekFanHoverDetail: View {
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let currentValue: String
    let readings: [SystemFanReading]
    let valueRange: ClosedRange<Double>
    let selectedFanIndex: Int?

    var body: some View {
        GeekHoverDetailCanvas(
            title: chartTitle,
            trailing: currentValue,
            showsRangePicker: true
        ) {
            if hasHistory {
                GeekPrecisionLineChart(
                    points: chartPoints,
                    series: [
                        MenuBarTelemetrySeries(
                            id: "fan-hover",
                            title: chartTitle,
                            channel: .fanRPM,
                            color: AppDesignTokens.Palette.tertiary
                        )
                    ],
                    valueRange: valueRange,
                    unit: .fanRPM,
                    accessibilityLabel: chartTitle + L10n.text("转速趋势", " speed trend"),
                    style: .stackedBars,
                    duration: duration,
                    showsLegend: false,
                    showsTimelineLabels: false,
                    showsTooltip: true,
                    horizontalInset: 2,
                    showsSamplingDetails: false
                )
                .frame(height: selectedFanIndex == nil ? 130 : 120)
            } else {
                PanelChartSamplingPlaceholder()
                    .frame(height: selectedFanIndex == nil ? 58 : 44)
            }

            if selectedFanIndex != nil {
                Divider().opacity(0.4)
                HStack(alignment: .top, spacing: 8) {
                    rangeColumn(L10n.text("最低", "Minimum"), value: rangeValues[0])
                    rangeColumn(L10n.text("最高", "Maximum"), value: rangeValues[1])
                    rangeColumn(L10n.text("目标", "Target"), value: rangeValues[2])
                }
                .help(L10n.text(
                    "最低和最高为设备报告的硬件量程，目标为设备回读值；不是此时间窗统计值。未读取的值显示 —。",
                    "Minimum and maximum are the hardware-reported range; target is the hardware readback, not statistics for this time window. Unread values show —."
                ))
            } else {
                ForEach(Array(readings.prefix(2))) { reading in
                    GeekHoverValueRow(
                        title: reading.displayName,
                        value: fanReadingText(reading)
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chartTitle)
    }

    private var chartTitle: String {
        guard let selectedFanIndex else { return L10n.text("平均转速", "Average Fan Speed") }
        return selectedReading?.displayName
            ?? L10n.text("风扇 \(selectedFanIndex + 1)", "Fan \(selectedFanIndex + 1)")
    }

    private var rangeValues: [String] { Self.rangeValues(for: selectedReading) }

    static func rangeValues(for reading: SystemFanReading?) -> [String] {
        [reading?.minimumRPM, reading?.maximumRPM, reading?.targetRPM]
            .map { $0.map(SystemFanSpeedFormat.string) ?? "—" }
    }

    private func rangeColumn(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(AdvancedPanelTypography.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var hasHistory: Bool {
        chartPoints.compactMap(\.fanRPM).filter(\.isFinite).count
            >= PanelChartSampling.minimumRenderableSampleCount
    }

    private var selectedReading: SystemFanReading? {
        guard let selectedFanIndex else { return nil }
        return readings.first { $0.index == selectedFanIndex }
    }

    private var chartPoints: [MenuBarTelemetryPoint] {
        guard let selectedFanIndex else { return points }
        return points.map { point in
            point.replacingFanRPM(with: point.fanRPM(at: selectedFanIndex))
        }
    }

    private var durationText: String {
        L10n.text(
            "最近 \(Int(duration.rounded())) 秒",
            "Last \(Int(duration.rounded())) Seconds"
        )
    }

    private func fanReadingText(_ reading: SystemFanReading) -> String {
        let bounds = [
            reading.minimumRPM.map { L10n.text("最低 \(SystemFanSpeedFormat.string($0))", "min \(SystemFanSpeedFormat.string($0))") },
            reading.maximumRPM.map { L10n.text("最高 \(SystemFanSpeedFormat.string($0))", "max \(SystemFanSpeedFormat.string($0))") },
            reading.targetRPM.map { L10n.text("目标 \(SystemFanSpeedFormat.string($0))", "target \(SystemFanSpeedFormat.string($0))") },
        ].compactMap { $0 }
        if bounds.isEmpty {
            return "\(reading.displayRPM) · \(L10n.text("范围未采集", "range not collected"))"
        }
        return "\(reading.displayRPM) · \(bounds.joined(separator: " / "))"
    }
}

struct GeekBatteryElectricalHoverDetail: View {
    let electrical: NativeBatteryElectricalSnapshot?
    let cycleCount: Int?
    let condition: String?
    let chargePercent: Int?
    let healthPercent: Int?
    let statusText: String
    let isCharging: Bool?
    let chargeTargetPercent: Int?
    let remainingTimeMinutes: Int?
    let runtimeEstimate: GeekBatteryRemainingTime.Estimate?

    init(
        electrical: NativeBatteryElectricalSnapshot?,
        cycleCount: Int?,
        condition: String?,
        chargePercent: Int? = nil,
        healthPercent: Int? = nil,
        statusText: String = L10n.text("不可用", "Unavailable"),
        isCharging: Bool? = nil,
        chargeTargetPercent: Int? = nil,
        remainingTimeMinutes: Int? = nil,
        runtimeEstimate: GeekBatteryRemainingTime.Estimate? = nil
    ) {
        self.electrical = electrical
        self.cycleCount = cycleCount
        self.condition = condition
        self.chargePercent = chargePercent
        self.healthPercent = healthPercent
        self.statusText = statusText
        self.isCharging = isCharging
        self.chargeTargetPercent = chargeTargetPercent
        self.remainingTimeMinutes = remainingTimeMinutes
        self.runtimeEstimate = runtimeEstimate
    }

    var body: some View {
        VStack(spacing: 7) {
            GeekHoverDetailGroup(title: L10n.text("电池", "Battery")) {
                GeekBatteryCompactValueGrid(rows: batteryRows)
            }

            if !chargingRows.isEmpty {
                GeekHoverDetailGroup(title: L10n.text("供电与充电", "Power and Charging")) {
                    GeekBatteryCompactValueGrid(rows: chargingRows)
                }
            }

            if !healthRows.isEmpty {
                GeekHoverDetailGroup(title: L10n.text("健康", "Health")) {
                    GeekBatteryCompactValueGrid(rows: healthRows)
                }
            }
        }
        .padding(GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var batteryRows: [(String, String)] {
        var rows = [
            (L10n.text("电量", "Charge"), percentValue(chargePercent)),
            (L10n.text("健康度", "Health"), percentValue(healthPercent)),
            (L10n.text("状态", "Status"), statusText),
        ]
        if isCharging == true,
           let remainingTime = GeekBatteryRemainingTime.text(for: remainingTimeMinutes) {
            rows.append((
                L10n.text("预计充满", "Full Charge In"),
                remainingTime
            ))
        } else if let runtimeEstimate,
                  let remainingTime = GeekBatteryRemainingTime.text(for: runtimeEstimate.minutes) {
            rows.append((L10n.text("耗电预计可用", "Power-based Runtime"), remainingTime))
        } else if let remainingTime = GeekBatteryRemainingTime.text(for: remainingTimeMinutes) {
            rows.append((L10n.text("系统预计可用", "System Runtime"), remainingTime))
        }
        return rows
    }

    private var chargingRows: [(String, String)] {
        var rows = [(String, String)]()
        if let watts = electrical?.adapterPowerWatts,
           watts.isFinite,
           watts > 0 {
            rows.append((
                L10n.text("适配器功率", "Adapter Power"),
                String(format: "%.0f W", watts)
            ))
        }
        if let chargeTargetPercent {
            rows.append((
                L10n.text("目标电量", "Target Charge"),
                "\(chargeTargetPercent)%"
            ))
        }
        return rows
    }

    private var healthRows: [(String, String)] {
        var rows = [(String, String)]()
        if let condition {
            rows.append((L10n.text("状况", "Condition"), condition))
        }
        if let cycleCount {
            rows.append((L10n.text("循环次数", "Cycles"), String(cycleCount)))
        }
        if let temperature = electrical?.temperatureCelsius {
            rows.append((
                L10n.text("电池温度", "Battery Temperature"),
                String(format: "%.1f°C", temperature)
            ))
        }
        return rows
    }

    private func percentValue(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }
}

private struct GeekBatteryCompactValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { index in
                HStack(spacing: 7) {
                    GeekBatteryCompactValueRow(title: rows[index].0, value: rows[index].1)
                    if rows.indices.contains(index + 1) {
                        GeekBatteryCompactValueRow(title: rows[index + 1].0, value: rows[index + 1].1)
                    }
                }
            }
        }
    }
}

private struct GeekBatteryCompactValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 1)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .font(AdvancedPanelTypography.caption)
        .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
    }
}

struct GeekBatteryHistoryHoverDetail: View {
    let points: [MenuBarPowerHistoryPoint]
    let tint: Color
    let chargingTint: Color

    @Environment(\.geekChartRangeSelection) private var chartRangeSelection

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("电池", "Battery").uppercased(),
            showsRangePicker: true,
            availableRanges: batteryHistoryRanges
        ) {
            GeekPowerHistoryChart(
                points: points,
                metric: .charge,
                duration: chartRangeSelection.range.duration,
                tint: tint,
                chargingTint: chargingTint,
                accessibilityLabel: L10n.text("电池电量趋势", "Battery-level trend"),
                showsTimelineLabels: false,
                showsTooltip: true
            )
            .frame(height: 154)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("电池", "Battery"))
    }

    private var hasRenderableHistory: Bool {
        points.compactMap(\.chargePercent).filter(\.isFinite).count
            >= PanelChartSampling.minimumRenderableSampleCount
    }

    private var batteryHistoryRanges: [GeekChartRange] {
        let ordered = points.sorted { $0.date < $1.date }
        let span = ordered.last?.date.timeIntervalSince(ordered.first?.date ?? .distantPast) ?? 0
        var ranges: [GeekChartRange] = [
            .oneHour,
            .threeHours,
            .sixHours,
            .twelveHours,
            .oneDay,
            .threeDays,
            .sevenDays,
        ]
        if span >= GeekChartRange.fourteenDays.duration {
            ranges.append(.fourteenDays)
        }
        if span >= GeekChartRange.twentyEightDays.duration {
            ranges.append(.twentyEightDays)
        }
        return ranges
    }
}

struct GeekEnergyModeHoverDetail: View {
    let batteryMode: BatteryPowerMode?
    let batterySupportedModes: [BatteryPowerMode]
    let adapterMode: BatteryPowerMode?
    let adapterSupportedModes: [BatteryPowerMode]
    let powerSource: BatteryPowerSource
    let isCharging: Bool
    let showsChargeTargetSetting: Bool
    let showsFullChargeAction: Bool
    let chargeLimitState: BatteryChargeLimitState?
    let batteryPowerWatts: Double?
    let adapterPowerWatts: Double?
    let adjustmentState: BatteryPowerModeAdjustmentState
    var controlsEnabled = true
    let onChargeToFull: () async -> BatteryFullChargeResult
    let onSetChargeTarget: (BatteryChargeTarget) async -> BatteryChargeTargetUpdateResult
    let onOpenBatterySettings: () -> Void
    let onChangeMode: (BatteryPowerSource, BatteryPowerMode) -> Void

    var body: some View {
        VStack(spacing: MiniWindowStyleTokens.cardSpacing) {
            if showsChargeTargetSetting {
                GeekChargeTargetSetting(
                    showsFullChargeAction: showsFullChargeAction,
                    chargeLimitState: chargeLimitState,
                    chargeToFull: onChargeToFull,
                    setChargeTarget: onSetChargeTarget,
                    openBatterySettings: onOpenBatterySettings
                )
            }
            if !batterySupportedModes.isEmpty {
                GeekEnergyModeGroup(
                    title: GeekEnergyModePowerTitle.battery(
                        isCharging: isCharging,
                        watts: batteryPowerWatts
                    ),
                    source: .batteryPower,
                    mode: batteryMode,
                    supportedModes: batterySupportedModes,
                    isActiveSource: powerSource == .batteryPower,
                    adjustmentState: adjustmentState,
                    controlsEnabled: controlsEnabled,
                    onChangeMode: onChangeMode
                )
            }
            if !adapterSupportedModes.isEmpty {
                GeekEnergyModeGroup(
                    title: GeekEnergyModePowerTitle.adapter(watts: adapterPowerWatts),
                    source: .acPower,
                    mode: adapterMode,
                    supportedModes: adapterSupportedModes,
                    isActiveSource: powerSource == .acPower,
                    adjustmentState: adjustmentState,
                    controlsEnabled: controlsEnabled,
                    onChangeMode: onChangeMode
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct GeekChargeTargetSetting: View {
    let showsFullChargeAction: Bool
    let chargeLimitState: BatteryChargeLimitState?
    let chargeToFull: () async -> BatteryFullChargeResult
    let setChargeTarget: (BatteryChargeTarget) async -> BatteryChargeTargetUpdateResult
    let openBatterySettings: () -> Void
    @State private var isRequesting = false
    @State private var selectedTarget = BatteryChargeTarget.stored()
    @State private var targetUpdateResult: BatteryChargeTargetUpdateResult?
    @State private var result: BatteryFullChargeResult?

    var body: some View {
        GeekHoverDetailGroup(title: L10n.text("充电上限", "Charge Limit")) {
            VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
                VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
                    if isRequesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    MiniWindowSegmentedPicker(
                        title: L10n.text("充电上限", "Charge Limit"),
                        selection: Binding(
                            get: { selectedTarget },
                            set: { updateTarget($0) }
                        ),
                        options: availableTargets,
                        label: { $0.displayText }
                    )
                    .frame(maxWidth: .infinity)
                    .disabled(isRequesting || chargeLimitState == nil)
                }
                .font(AdvancedPanelTypography.body)

                .frame(maxWidth: .infinity, alignment: .leading)

                if targetUpdateFailed || chargeLimitState == nil {
                    Text(targetStatusText)
                        .font(AdvancedPanelTypography.caption).foregroundStyle(targetStatusColor)
                        .fixedSize(horizontal: false, vertical: true)

                }

                Button(
                    L10n.text("打开电池设置", "Open Battery Settings"),
                    action: openBatterySettings
                )
                .buttonStyle(.link)
                .font(AdvancedPanelTypography.caption)


                if showsFullChargeAction {
                    fullChargeButton
                }
            }
        }
        .alert(
            resultTitle,
            isPresented: Binding(
                get: { result != nil },
                set: { if !$0 { result = nil } }
            )
        ) {
            if result?.needsBatterySettings == true {
                Button(L10n.text("打开电池设置", "Open Battery Settings")) {
                    openBatterySettings()
                }
            }
            Button(L10n.text("知道了", "Got It"), role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
        .onAppear(perform: synchronizeTargetFromSystem)
        .onChange(of: chargeLimitState) { _, _ in
            synchronizeTargetFromSystem()
        }
    }

    private var fullChargeButton: some View {
        Button {
            requestFullCharge()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "battery.100percent.bolt")
                    .foregroundStyle(Color.accentColor)
                Text(L10n.text("本次充到 100%", "Charge This Time to 100%"))
                    .foregroundStyle(.primary)
                Spacer(minLength: 2)
                Image(systemName: AppSymbols.Panel.attachedDetail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(AdvancedPanelTypography.body)

            .frame(height: 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(isRequesting)
        .help(L10n.text(
            "临时解除 macOS 的充电暂停，不改变已选充电上限。",
            "Temporarily override the macOS charging pause without changing the selected limit."
        ))
        .accessibilityLabel(L10n.text("本次充到百分之百", "Charge This Time to 100 Percent"))
        .accessibilityHint(L10n.text(
            "请求 macOS 临时充到百分之百并回读结果",
            "Requests the native temporary charge to 100 percent and verifies the result"
        ))
    }

    private func updateTarget(_ target: BatteryChargeTarget) {
        guard target != selectedTarget, !isRequesting else { return }
        Task {
            isRequesting = true
            let update = await setChargeTarget(target)
            targetUpdateResult = update
            if update == .applied {
                selectedTarget = target
                if target == .full, showsFullChargeAction {
                    result = await chargeToFull()
                }
            }
            isRequesting = false
        }
    }

    private func requestFullCharge() {
        guard !isRequesting else { return }
        Task {
            isRequesting = true
            result = await chargeToFull()
            isRequesting = false
        }
    }

    private var targetUpdateFailed: Bool {
        guard let targetUpdateResult else { return false }
        return targetUpdateResult != .applied
    }

    private var targetStatusColor: Color {
        targetUpdateFailed ? .red : .secondary
    }

    private var targetStatusText: String {
        switch targetUpdateResult {
        case .unsupported:
            return L10n.text(
                "此机型不支持充电上限",
                "Charge limit unavailable on this Mac"
            )
        case .rejected:
            return L10n.text("macOS 未接受充电上限更改。", "macOS did not accept the charge-limit change.")
        case .verificationFailed:
            return L10n.text(
                "更改已发送，但系统回读结果不一致。",
                "The change was sent, but the system readback did not match."
            )
        case .applied, .none:
            guard chargeLimitState != nil else {
                return L10n.text(
                    "充电上限不可用",
                    "Charge limit unavailable"
                )
            }
            return L10n.text(
                "与系统设置同步 · 当前目标 \(selectedTarget.displayText)",
                "Synced with System Settings · Target \(selectedTarget.displayText)"
            )
        }
    }

    private var availableTargets: [BatteryChargeTarget] {
        chargeLimitState?.availableTargets ?? [selectedTarget]
    }

    private func synchronizeTargetFromSystem() {
        guard !isRequesting, let target = chargeLimitState?.target else { return }
        selectedTarget = target
        targetUpdateResult = nil
    }

    private var resultTitle: String {
        switch result {
        case .accepted:
            L10n.text("已请求充到满电", "Charge to Full Requested")
        case .alreadyCharging:
            L10n.text("正在充电", "Already Charging")
        case .alreadyFull:
            L10n.text("电池已满", "Battery Is Full")
        case .requiresACPower:
            L10n.text("请先连接电源", "Connect Power First")
        case .unsupported, .rejected, .verificationFailed, .none:
            L10n.text("无法充到满电", "Unable to Charge to Full")
        }
    }

    private var resultMessage: String {
        switch result {
        case .accepted:
            L10n.text(
                "macOS 已接受临时满充请求，通常会在几十秒内开始充电，目标为 100%。长期电池保护仍保持开启。",
                "macOS accepted the temporary full-charge request. Charging usually starts within tens of seconds and targets 100%. Long-term battery protection remains enabled."
            )
        case .alreadyCharging:
            L10n.text("电池已经在充电。", "The battery is already charging.")
        case .alreadyFull:
            L10n.text("电池已经充满。", "The battery is already fully charged.")
        case .requiresACPower:
            L10n.text("连接电源适配器后再试。", "Connect a power adapter and try again.")
        case .unsupported:
            L10n.text(
                "当前 macOS 或机型不提供可验证的临时满充控制，请使用系统电池菜单。",
                "This macOS version or Mac does not expose a verifiable temporary full-charge control. Use the system Battery menu."
            )
        case .rejected:
            L10n.text(
                "macOS 拒绝了临时满充请求，请检查电池设置后重试。",
                "macOS rejected the temporary full-charge request. Check Battery settings and try again."
            )
        case .verificationFailed:
            L10n.text(
                "请求已发送，但无法回读到临时满充状态，因此没有按成功处理。",
                "The request was sent, but the temporary full-charge state could not be read back, so it was not treated as successful."
            )
        case .none:
            ""
        }
    }
}

private extension BatteryFullChargeResult {
    var needsBatterySettings: Bool {
        switch self {
        case .unsupported, .rejected, .verificationFailed:
            true
        case .accepted, .alreadyCharging, .alreadyFull, .requiresACPower:
            false
        }
    }
}

enum GeekEnergyModePowerTitle {
    static func overviewACSummary(
        powerSource: BatteryPowerSource?,
        adapterWatts: Double?,
        targetPercent: Int?
    ) -> String? {
        guard powerSource == .acPower else { return nil }
        var values = [String]()
        if let adapterWatts, adapterWatts.isFinite, adapterWatts > 0 {
            values.append(L10n.text(
                "适配器 \(formatted(adapterWatts))",
                "Adapter \(formatted(adapterWatts))"
            ))
        }
        if let targetPercent {
            values.append(L10n.text(
                "目标 \(targetPercent)%",
                "Target \(targetPercent)%"
            ))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    static func battery(isCharging: Bool, watts: Double?) -> String {
        let base = L10n.text("电池", "Battery")
        guard isCharging, let watts, watts.isFinite, watts > 0 else { return base }
        return L10n.text(
            "电池 · 充电 \(formatted(watts))",
            "Battery · Charging \(formatted(watts))"
        )
    }

    static func adapter(watts: Double?) -> String {
        let base = L10n.text("电源适配器", "Power Adapter")
        guard let watts, watts.isFinite, watts > 0 else { return base }
        return "\(base) · \(formatted(watts))"
    }

    private static func formatted(_ watts: Double) -> String {
        String(format: "%.0f W", locale: Locale(identifier: "en_US_POSIX"), watts)
    }
}

private struct GeekHoverDetailGroup<Content: View>: View {
    let title: String
    let isActive: Bool
    let showsFailure: Bool
    let content: Content

    init(title: String, isActive: Bool = false, showsFailure: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.isActive = isActive
        self.showsFailure = showsFailure
        self.content = content()
    }

    var body: some View {
        MiniWindowGroup {
            HStack(alignment: .firstTextBaseline, spacing: MiniWindowStyleTokens.inlineSpacing) {
                Text(title.uppercased())
                    .font(AdvancedPanelTypography.captionStrong)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if showsFailure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AdvancedPanelTypography.symbol)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                        .accessibilityHidden(true)
                } else if isActive {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            content
        }
    }
}

private struct GeekEnergyModeGroup: View {
    let title: String
    let source: BatteryPowerSource
    let mode: BatteryPowerMode?
    let supportedModes: [BatteryPowerMode]
    let isActiveSource: Bool
    let adjustmentState: BatteryPowerModeAdjustmentState
    let controlsEnabled: Bool
    let onChangeMode: (BatteryPowerSource, BatteryPowerMode) -> Void

    var body: some View {
        GeekHoverDetailGroup(title: title, isActive: isActiveSource, showsFailure: showsFailure) {
            VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
                MiniWindowSegmentedPicker(
                    title: title,
                    selection: modeBinding,
                    options: (mode == nil ? [nil] : []) + supportedModes.map(Optional.some),
                    label: { $0.map { title(for: $0) } ?? "—" }
                )
                .frame(maxWidth: .infinity)
                .disabled(!controlsEnabled || adjustmentState.isChanging)

                if let statusText {
                    Text(statusText)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(showsFailure ? AppDesignTokens.Palette.warning : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .help(statusText ?? L10n.text(
            "选择模式后会通过同一个高级控制辅助程序写入，并读取系统实际值确认。",
            "The shared advanced-control helper applies the mode and reads the system value back for confirmation."
        ))
    }

    private var modeBinding: Binding<BatteryPowerMode?> {
        Binding(
            get: { mode },
            set: { if let selected = $0 { onChangeMode(source, selected) } }
        )
    }

    private func title(for mode: BatteryPowerMode) -> String {
        switch mode {
        case .automatic:
            L10n.text("自动", "Automatic")
        case .lowPower:
            L10n.text("低功耗", "Low Power")
        case .highPower:
            L10n.text("高功率", "High Power")
        }
    }

    private var showsFailure: Bool {
        switch adjustmentState {
        case let .unsupported(failedSource, _),
             let .cancelled(failedSource, _),
             let .permissionDenied(failedSource, _),
             let .timedOut(failedSource, _),
             let .failed(failedSource, _),
             let .verificationFailed(failedSource, _):
            failedSource == source
        case .idle, .changing, .changed:
            false
        }
    }

    private var statusText: String? {
        switch adjustmentState {
        case let .changing(changingSource, _) where changingSource == source:
            L10n.text("正在应用…", "Applying…")
        case let .changed(changedSource, _) where changedSource == source:
            nil
        case let .unsupported(failedSource, _) where failedSource == source:
            L10n.text("此模式不受本机支持", "This mode is not supported on this Mac")
        case let .cancelled(failedSource, _) where failedSource == source:
            L10n.text("系统控制设置已取消", "System control setup was cancelled")
        case let .permissionDenied(failedSource, _) where failedSource == source:
            L10n.text("请完成一次系统控制批准", "Complete the one-time system control approval")
        case let .timedOut(failedSource, _) where failedSource == source:
            L10n.text("更改超时，请重试", "The change timed out; try again")
        case let .failed(failedSource, _) where failedSource == source:
            L10n.text("无法更改能源模式", "Could not change Energy Mode")
        case let .verificationFailed(failedSource, _) where failedSource == source:
            L10n.text("系统未应用所选模式", "macOS did not apply the selected mode")
        default:
            nil
        }
    }

    private func rowStatusText(for option: BatteryPowerMode) -> String? {
        guard let request = adjustmentRequest,
              request.source == source,
              request.mode == option else { return nil }
        return statusText
    }

    private var adjustmentRequest: (source: BatteryPowerSource, mode: BatteryPowerMode)? {
        switch adjustmentState {
        case .idle:
            nil
        case let .changing(source, mode),
             let .changed(source, mode),
             let .unsupported(source, mode),
             let .cancelled(source, mode),
             let .permissionDenied(source, mode),
             let .timedOut(source, mode),
             let .failed(source, mode),
             let .verificationFailed(source, mode):
            (source, mode)
        }
    }
}

private struct GeekEnergyModeOptionRow: View {
    let sourceTitle: String
    let title: String
    let selected: Bool
    let isChanging: Bool
    let isDisabled: Bool
    let statusText: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 2)
                if isChanging {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(AdvancedPanelTypography.captionStrong)
                        .accessibilityHidden(true)
                }
            }
            .font(AdvancedPanelTypography.body)

            .frame(height: 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous)
                    .fill(
                        isHovered || isChanging
                            ? Color.accentColor.opacity(0.16)
                            : .clear
                    )
            )
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(statusText ?? L10n.text(
            "更改为\(title)",
            "Change to \(title)"
        ))
        .accessibilityLabel(L10n.text(
            "\(sourceTitle)，更改能源模式为\(title)",
            "\(sourceTitle), Change Energy Mode to \(title)"
        ))
        .accessibilityHint(statusText ?? L10n.text(
            "将\(sourceTitle)能源模式更改为\(title)；首次使用时只需批准一次系统控制辅助程序",
            "Changes the \(sourceTitle) Energy Mode to \(title); the system-control helper needs one approval on first use"
        ))
        .accessibilityValue(selected
            ? L10n.text("当前模式", "Current Mode")
            : (statusText ?? L10n.text("可选择", "Available")))
    }
}
