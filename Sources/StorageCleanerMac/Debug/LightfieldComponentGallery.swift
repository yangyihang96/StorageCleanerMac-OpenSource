#if DEBUG
import SwiftUI

@MainActor
final class LightfieldComponentGallerySession: ObservableObject {
    static let shared = LightfieldComponentGallerySession()
    @Published var component = LightfieldComponentGallery.components[0]
}

/// Inert component fixtures only. The gallery argument enables the existing
/// demo monitor mode; no provider/cleanup/action is retained by this view.
struct LightfieldComponentGallery: View {
    nonisolated static let launchArgument = "--debug-lightfield-gallery"
    nonisolated static let components = ["option-row", "app-icon", "status-glyph", "ring", "metric-group", "data-bar",
        "expandable-row", "text-segments", "trend-chart", "bubble-chart", "donut-chart", "summary"]
    nonisolated static func requested(arguments: [String]) -> Bool { arguments.contains(launchArgument) }
    nonisolated static var isRequested: Bool { requested(arguments: ProcessInfo.processInfo.arguments) }
    @ObservedObject var session: LightfieldComponentGallerySession
    @Environment(\.colorScheme) private var scheme
    @State private var selected = true
    @State private var expanded = true
    @State private var segment = 0
    @State private var highlighted: String?
    @State private var drillDown: String?
    @State private var hoverIndex: Int?
    @State private var range: LightfieldTrendSelection?
    var body: some View {
        FeatureLightfieldPage(module: .memory, phase: .result, title: "光场组件 · " + session.component,
            status: "Debug · 固定夹具", safety: "仅演示共用组件", actionTitle: "组件陈列", showsArtwork: false, action: {}) {
            ScrollView {
                examples.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.featureDisablesLayoutAnimations, FeaturePresentationDemo.disablesLayoutAnimations)
        .preferredColorScheme(MiniWindowDemoData.forcedColorScheme == "light" ? .light
            : MiniWindowDemoData.forcedColorScheme == "dark" ? .dark : nil)
    }
    @ViewBuilder private var examples: some View {
        switch session.component {
        case "option-row":
            VStack(spacing: 0) {
                LightfieldOptionRow(title: "系统缓存", icon: .cleanupSystemCache, module: .green, selection: $selected, metadata: "可重新生成")
                LightfieldOptionRow(title: "后台任务", icon: .startupBackground, module: .startup, selection: .constant(false), metadata: "8 项")
                LightfieldOptionRow(title: "处理器测试", icon: .benchmarkCpu, module: .performance, metadata: "6 项 · 固定项目")
            }
        case "app-icon":
            HStack(spacing: 24) {
                ForEach(LightfieldAppIcon.Size.allCases, id: \.rawValue) { size in
                    VStack(spacing: 12) {
                        LightfieldAppIcon(path: Bundle.main.bundlePath, size: size, accessibilityName: "当前应用")
                        LightfieldAppIcon(size: size, accessibilityName: "系统进程")
                        Text("\(Int(size.rawValue)) pt")
                    }
                }
            }
        case "status-glyph":
            HStack(spacing: 24) {
                ForEach(Array(MetadataPillStatus.allCases.enumerated()), id: \.offset) { _, status in
                    VStack(spacing: 12) { LightfieldStatusGlyph(status: status); Text(status.lightfieldDescription) }
                }
            }
        case "ring":
            HStack(alignment: .center, spacing: 24) {
                LightfieldRing(diameter: 76, progress: 0.61, color: FeatureLightfieldPalette.accent(.memory), value: "61", unit: "%", label: "占用")
                LightfieldRing(diameter: 112, progress: 0.58, color: FeatureLightfieldStatus.normal.color(.resolve(scheme)),
                    value: "58", unit: "%", label: "正常", labelIsStatus: true)
                LightfieldRing(diameter: 132, progress: 0.7, color: FeatureLightfieldStatus.warning.color(.resolve(scheme)), value: "升高", label: "内存压力")
                LightfieldRing(diameter: 96, progress: nil, color: FeatureLightfieldPalette.accent(.memory), value: "—", label: "未提供")
            }
        case "metric-group": LightfieldMetricGroup(metrics: Self.metrics).frame(width: 520)
        case "data-bar":
            VStack(alignment: .leading, spacing: 24) {
                Text("行内比例 · 2 pt"); LightfieldDataBar(progress: 0.62, module: .memory)
                Text("连续进度 · 6 pt"); LightfieldDataBar(progress: 0.42, module: .performance, style: .progress())
                Text("分段进度 · 18 格"); LightfieldDataBar(progress: 0.42, module: .performance, style: .progress(segments: 18))
                Text("未提供"); LightfieldDataBar(progress: nil, module: .memory)
            }
        case "expandable-row":
            LightfieldExpandableRow(title: "example.test", metadata: "3 个页面", expanded: $expanded) {
                LightfieldAppIcon(size: .medium)
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    LightfieldPathText(path: "https://example.test/docs/reference/very-long-page-title")
                    Text("第二个页面 · 固定夹具")
                }
            }
        case "text-segments": LightfieldTextSegments(titles: ["全部", "登录时打开", "后台运行"], selection: $segment, module: .startup)
        case "trend-chart":
            VStack(alignment: .leading, spacing: 12) {
                // Approved memory landing: title + pressure legend, GB · % bubble.
                LightfieldTrendChart(samples: Self.samples, module: .memory, hint: "悬停回看 · 拖选看平均",
                    title: "2 分钟内存占用", legend: .pressure,
                    valueFormat: .scaledWithPercent(maximum: 32, unit: "GB"),
                    onHoverIndex: { hoverIndex = $0 }, onSelection: { range = $0 }).frame(width: 520)
                Text(hoverIndex.map { "该时刻占用最多 · 示例进程 \($0 + 1)" } ?? "悬停选择时刻")
                if let range { Text("选中 \(ByteFormat.count(range.range.count)) 个时刻 · 有测量 \(ByteFormat.count(range.measuredCount)) 个") }
                // Approved performance run monitor: CPU / GPU, no bands, no axis.
                LightfieldTrendChart(samples: Self.cpuSamples, module: .performance, height: 48,
                    title: "2 分钟 CPU / GPU 负载", primaryName: "CPU",
                    series: [.init(id: "gpu", name: "GPU", color: FeatureLightfieldPalette.resolve(scheme).fg2, samples: Self.gpuSamples)],
                    legend: .series, showsPressureBands: false, axis: .hidden, fillsArea: false, showsCurrentValue: false)
                    .frame(width: 520).padding(.top, 16)
            }
        case "bubble-chart":
            VStack(alignment: .leading, spacing: 8) {
                LightfieldBubbleChart(items: Self.chartItems, onHighlight: { highlighted = $0 }, onDrillDown: { drillDown = $0 })
                    .frame(width: 510, height: 268)
                Text("高亮：\(highlighted ?? "无") · 下钻：\(drillDown ?? "无")")
            }
        case "donut-chart": LightfieldDonutChart(items: Self.chartItems, centerValue: "36.2 GB", centerLabel: "· 4 类\n文件类型")
            .frame(width: 340)
        default:
            VStack(spacing: 24) {
                LightfieldSummary(module: .startup, label: "已发现", value: "12", unit: "项", note: "· 2 项可直接管理")
                LightfieldSummary(module: .energy, label: "当前应用功率", value: "8.15", unit: "W", secondary: [
                    .init(id: "uptime", label: "系统运行时间", value: "8", unit: "小时"),
                    .init(id: "coverage", label: "进程测量覆盖率", value: "86", unit: "%")])
            }
        }
    }
    static let metrics: [LightfieldMetric] = [
        .init(id: "used", label: "已用", value: "18.6", unit: "GB"),
        .init(id: "cache", label: "缓存", value: "4.2", unit: "GB"),
        .init(id: "swap", label: "交换", value: "0.8", unit: "GB")]
    static let samples: [LightfieldTrendSample] = (0..<25).map { index in
        .init(time: MiniWindowDemoData.referenceDate.addingTimeInterval(Double(index - 24) * 5),
              value: 0.48 + Double(index % 8) * 0.025)
    }
    static let cpuSamples: [LightfieldTrendSample] = [0.24, 0.31, 0.46, 0.61, 0.72, 0.77, 0.79, 0.80, 0.81, 0.82, 0.83, 0.82]
        .enumerated().map { .init(time: MiniWindowDemoData.referenceDate.addingTimeInterval(Double($0.offset - 11) * 120 / 11), value: $0.element) }
    static let gpuSamples: [LightfieldTrendSample] = cpuSamples.map { .init(time: $0.time, value: 0.04) }
    static let chartItems: [LightfieldChartItem] = [
        .init(id: "media", label: "媒体", value: 20, formattedValue: "20 GB", module: .memory, icon: .fileanalysisMedia),
        .init(id: "documents", label: "文档", value: 10, formattedValue: "10 GB", module: .duplicates, icon: .fileanalysisDocuments),
        .init(id: "archives", label: "归档", value: 5, formattedValue: "5 GB", module: .devCaches, icon: .fileanalysisArchives),
        .init(id: "other", label: "其他", value: 1.2, formattedValue: "1.2 GB", module: .startup, icon: .fileanalysisOther)]
}
#endif
