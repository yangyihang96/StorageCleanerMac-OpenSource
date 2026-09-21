import SwiftUI

enum GeekMemoryComponent: String, CaseIterable, Identifiable {
    case app, wired, compressed, free

    static var chartComponents: [Self] { allCases.filter { $0 != .free } }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: "App"
        case .wired: "Wired"
        case .compressed: "Compressed"
        case .free: "Free"
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
            L10n.text("应用及其他：已用物理内存扣除 Wired 和 Compressed，与上方圆环口径一致。",
                      "App and other: used physical memory excluding Wired and Compressed, matching the ring above.")
        case .wired:
            L10n.text("必须保留在物理内存中、不能换出到磁盘的内存。",
                      "Memory that must remain in RAM and cannot be swapped to disk.")
        case .compressed:
            L10n.text("压缩数据当前实际占用的物理内存。",
                      "Physical memory currently occupied by compressed data.")
        case .free:
            L10n.text("可供应用使用的内存，包含空闲页与可回收缓存，与上方圆环口径一致。",
                      "Memory available to apps, including free pages and reclaimable cache, matching the ring above.")
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
    let composition: MemoryRingComposition?
    var showsPercent = false

    var body: some View {
        VStack(spacing: MiniWindowStyleTokens.rowSpacing) {
            ForEach(GeekMemoryComponent.allCases) { component in
                HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                    Circle().fill(component.color).frame(width: 6, height: 6)
                        .opacity(component == .free ? 0 : 1)
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
    static let preferredSize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 320)
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let composition: MemoryRingComposition?

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
                    MenuBarTelemetrySeries(id: $0.id, title: $0.title, channel: $0.channel, color: $0.color)
                },
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text("App、Wired、Compressed 的实时占比趋势",
                                             "Live percentage trends for App, Wired and Compressed"),
                style: .stackedBars,
                duration: duration,
                showsLegend: false,
                showsTooltip: true,
                horizontalInset: 2,
                showsValueLabels: true,
                showsSamplingDetails: false
            )
            // Composition colors must match the rows and ring, including in
            // a custom panel theme. A single chart accent loses that mapping.
            .environment(\.panelChartAccentColor, nil)
            .frame(height: 174)
        }
    }
}
