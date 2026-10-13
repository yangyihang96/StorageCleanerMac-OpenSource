import SwiftUI

enum GeekMemoryComponent: String, CaseIterable, Identifiable {
    case app, wired, compressed, free

    static var chartComponents: [Self] { allCases.filter { $0 != .free } }

    var id: String { rawValue }
    // D4: the Chinese interface uses Chinese terms; English keeps the
    // Activity Monitor names. Wired follows Apple's localization (联动内存).
    var title: String {
        switch self {
        case .app: L10n.text("应用", "App")
        case .wired: L10n.text("联动", "Wired")
        case .compressed: L10n.text("压缩", "Compressed")
        case .free: L10n.text("可用", "Free")
        }
    }

    var color: Color {
        switch self {
        case .app: AppChartPalette.memoryAppOrOther
        case .wired: AppChartPalette.memoryWired
        case .compressed: AppChartPalette.memoryCompressed
        case .free: .secondary
        }
    }

    func color(in palette: PanelMetricColors) -> Color {
        switch self {
        case .app: palette.memoryApp
        case .wired: palette.memoryWired
        case .compressed: palette.memoryCompressed
        case .free: .secondary
        }
    }

    /// Free is drawn as the ring's unfilled track; the track color alone is
    /// barely distinguishable from the card (about 1.5:1 dark, 1.7:1 light),
    /// so its marker adds a hairline in the tertiary text color.
    var legendHasOutline: Bool { self == .free }

    /// Legend marker for the rows. Free is the unfilled part of the ring, so
    /// its marker uses the ring's own track color rather than a data color.
    func legendColor(
        in palette: PanelMetricColors,
        colorScheme: ColorScheme,
        visualMode: MiniWindowVisualMode
    ) -> Color {
        self == .free
            ? GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode)
            : color(in: palette)
    }

    var channel: MenuBarTelemetryChannel {
        switch self {
        case .app: .memoryAppPercent
        case .wired: .memoryWiredPercent
        case .compressed: .memoryCompressedPercent
        case .free: .memoryFreePercent
        }
    }

    var explanation: String {
        switch self {
        case .app:
            L10n.text("应用及其他：已用物理内存扣除联动和压缩，与上方圆环口径一致。",
                      "App and other: used physical memory excluding Wired and Compressed, matching the ring above.")
        case .wired:
            L10n.text("必须保留在物理内存中、不能换出到磁盘的内存。",
                      "Memory that must remain in RAM and cannot be swapped to disk.")
        case .compressed:
            L10n.text("压缩数据当前实际占用的物理内存。",
                      "Physical memory currently occupied by compressed data.")
        case .free:
            L10n.text("可供应用使用的内存，包含空闲页与可回收缓存，与上方圆环口径一致；对应圆环未填充的底轨。",
                      "Memory available to apps, including free pages and reclaimable cache, matching the ring above; it is the ring's unfilled track.")
        }
    }

    func bytes(in composition: MemoryRingComposition) -> UInt64 {
        switch self {
        case .app: composition.appOrOtherBytes
        case .wired: composition.wiredBytes
        case .compressed: composition.compressedBytes
        case .free: composition.availableBytes
        }
    }

    func value(in composition: MemoryRingComposition?, asPercent: Bool) -> String {
        guard let composition else { return "—" }
        let amount = bytes(in: composition)
        return asPercent
            ? String(format: "%.1f%%", Double(amount) / Double(composition.physicalBytes) * 100)
            : ByteFormat.string(Int64(clamping: amount))
    }
}

struct GeekMemoryCompositionRows: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.displayScale) private var displayScale
    let composition: MemoryRingComposition?
    var showsPercent = false

    var body: some View {
        VStack(spacing: MiniWindowStyleTokens.rowSpacing) {
            ForEach(GeekMemoryComponent.allCases) { component in
                HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                    Circle()
                        .fill(component.legendColor(
                            in: metricColors,
                            colorScheme: colorScheme,
                            visualMode: visualMode
                        ))
                        .overlay {
                            if component.legendHasOutline {
                                Circle().strokeBorder(
                                    .tertiary,
                                    lineWidth: MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
                                )
                            }
                        }
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(component.title)
                    Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
                    Text(component.value(in: composition, asPercent: showsPercent))
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(AdvancedPanelTypography.body)
                .lineLimit(1)
                .frame(minHeight: MiniWindowStyleTokens.dataRowHeight)
                .help(component.explanation)
                .accessibilityElement(children: .combine)
                .accessibilityHint(component.explanation)
            }
        }
    }
}

struct GeekMemoryCompositionHistoryDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    static let preferredSize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 280)
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let composition: MemoryRingComposition?

    /// The history still draws the previous window (`MenuBarDisplayedHistory.isUpdating`).
    var isUpdating = false

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("内存组成占比", "Memory Composition"),
            showsRangePicker: true,
            spacing: MiniWindowStyleTokens.rowSpacing
        ) {
            GeekMemoryCompositionRows(composition: composition, showsPercent: true)
            GeekPrecisionLineChart(
                points: points,
                series: GeekMemoryComponent.chartComponents.map {
                    MenuBarTelemetrySeries(id: $0.id, title: $0.title, channel: $0.channel, color: $0.color(in: metricColors))
                },
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text("应用、联动、压缩的实时占比趋势",
                                             "Live percentage trends for App, Wired and Compressed"),
                style: .stackedBars,
                duration: duration,
                showsLegend: false,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: 2,
                showsSamplingDetails: false
            )
            // Composition colors must match the rows and ring, including in
            // a custom panel theme. A single chart accent loses that mapping.
            .environment(\.panelChartAccentColor, nil)
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, valueRange: "0–100%", isUpdating: isUpdating))
        }
    }
}
