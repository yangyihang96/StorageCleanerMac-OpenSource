import SwiftUI

typealias GeekPanelHoverActivityHandler = @MainActor @Sendable (UUID, Bool) -> Void
typealias GeekInlineTertiaryEventHandler = @MainActor @Sendable (GeekInlineTertiaryEvent) -> Bool
typealias GeekTertiaryHoverHandler = @MainActor @Sendable (Bool) -> Void

@MainActor
final class GeekInlineTertiaryContentStore: ObservableObject {
    @Published private(set) var content = AnyView(EmptyView())
    let identity = UUID()
    private(set) var lastPublishedAt: Date?

    func update(_ content: AnyView, now: Date = Date(), force: Bool = false) {
        guard GeekInlineTertiaryContentRefreshPolicy.shouldPublish(
            lastPublishedAt: lastPublishedAt,
            now: now,
            force: force
        ) else { return }
        self.content = content
        lastPublishedAt = now
    }
}

enum GeekInlineTertiaryContentRefreshPolicy {
    static let minimumInterval: TimeInterval = 0.9
    private static let comparisonEpsilon: TimeInterval = 0.000_001

    static func shouldPublish(
        lastPublishedAt: Date?,
        now: Date,
        force: Bool = false
    ) -> Bool {
        force || lastPublishedAt.map {
            now.timeIntervalSince($0) + comparisonEpsilon >= minimumInterval
        } ?? true
    }
}

struct GeekInlineTertiaryRequest: Identifiable {
    let id: UUID
    let accessibilityLabel: String
    let chartRangeMetric: GeekChartRangeMetric?
    let preferredSize: CGSize
    let isPinned: Bool
    /// Vertical distance from the top of the secondary content to the row
    /// that opened this request. The attached shell adds the secondary
    /// column's own offset before clamping the tertiary column to the panel.
    let sourceOffset: CGFloat?
    let contentStore: GeekInlineTertiaryContentStore
    let hoverChanged: GeekTertiaryHoverHandler

    init(
        id: UUID,
        accessibilityLabel: String,
        chartRangeMetric: GeekChartRangeMetric? = nil,
        preferredSize: CGSize = GeekPanelPresentationMetrics.tertiarySize,
        isPinned: Bool = false,
        sourceOffset: CGFloat? = nil,
        contentStore: GeekInlineTertiaryContentStore,
        hoverChanged: @escaping GeekTertiaryHoverHandler
    ) {
        self.id = id
        self.accessibilityLabel = accessibilityLabel
        self.chartRangeMetric = chartRangeMetric
        self.preferredSize = GeekPanelPresentationMetrics.normalizedTertiarySize(preferredSize)
        self.isPinned = isPinned
        self.sourceOffset = GeekPanelPresentationMetrics.normalizedTertiarySourceOffset(sourceOffset)
        self.contentStore = contentStore
        self.hoverChanged = hoverChanged
    }
}

enum GeekInlineTertiaryEvent {
    case present(GeekInlineTertiaryRequest)
    case dismiss(UUID)
}

private struct MenuBarCascadeDirectionKey: EnvironmentKey {
    static let defaultValue = MenuBarCascadeDirection.left
}

private struct GeekPanelHoverActivityKey: EnvironmentKey {
    static let defaultValue: GeekPanelHoverActivityHandler? = nil
}

private struct GeekPanelHoverEnvelopeActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MenuBarTertiaryPresentationModeKey: EnvironmentKey {
    static let defaultValue = MenuBarTertiaryPresentationMode.column
}

private struct GeekInlineTertiaryEventKey: EnvironmentKey {
    static let defaultValue: GeekInlineTertiaryEventHandler? = nil
}

private struct GeekInlineTertiaryActiveRequestIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var menuBarCascadeDirection: MenuBarCascadeDirection {
        get { self[MenuBarCascadeDirectionKey.self] }
        set { self[MenuBarCascadeDirectionKey.self] = newValue }
    }

    var geekPanelHoverActivity: GeekPanelHoverActivityHandler? {
        get { self[GeekPanelHoverActivityKey.self] }
        set { self[GeekPanelHoverActivityKey.self] = newValue }
    }

    var geekPanelHoverEnvelopeActive: Bool {
        get { self[GeekPanelHoverEnvelopeActiveKey.self] }
        set { self[GeekPanelHoverEnvelopeActiveKey.self] = newValue }
    }

    var menuBarTertiaryPresentationMode: MenuBarTertiaryPresentationMode {
        get { self[MenuBarTertiaryPresentationModeKey.self] }
        set { self[MenuBarTertiaryPresentationModeKey.self] = newValue }
    }

    var geekInlineTertiaryEvent: GeekInlineTertiaryEventHandler? {
        get { self[GeekInlineTertiaryEventKey.self] }
        set { self[GeekInlineTertiaryEventKey.self] = newValue }
    }

    var geekInlineTertiaryActiveRequestID: UUID? {
        get { self[GeekInlineTertiaryActiveRequestIDKey.self] }
        set { self[GeekInlineTertiaryActiveRequestIDKey.self] = newValue }
    }
}

/// Shared hover affordance for the compact Geek detail cards.
///
/// The delayed reveal mirrors a menu-bar inspector: pointer movement across a
/// card does not flash a new surface, while a short dismissal grace period lets
/// the pointer cross into the attached third column. No extra window or sampler
/// is created.
struct GeekHoverDetailTarget<Target: View, Detail: View>: View {
    @Environment(\.geekPanelHoverActivity) private var panelHoverActivity
    @Environment(\.geekPanelHoverEnvelopeActive) private var isPanelHoverEnvelopeActive
    @Environment(\.geekPanelHoverCoordinator) private var hoverCoordinator
    @Environment(\.menuBarTertiaryPresentationMode) private var tertiaryPresentationMode
    @Environment(\.geekInlineTertiaryEvent) private var inlineTertiaryEvent
    @Environment(\.geekInlineTertiaryActiveRequestID) private var activeInlineRequestID
    @Environment(\.geekChartRangeSelection) private var chartRangeSelection
    @Environment(\.displayScale) private var displayScale

    let accessibilityLabel: String
    let chartRangeMetric: GeekChartRangeMetric?
    let popoverSize: CGSize
    let sourceOffset: CGFloat?
    let usesCardActiveBorder: Bool
    private let target: Target
    private let detail: Detail

    @State private var isTargetHovered = false
    @State private var isDetailHovered = false
    @State private var hoverIntent: GeekPanelCoordinator.HoverIntent?
    @State private var panelActivityID = UUID()
    @State private var isPanelActivityReported = false
    @State private var isInlinePresented = false
    @State private var isPinned = false
    @State private var measuredSourceOffset: CGFloat?
    // A reference stored in State keeps a stable identity without making this
    // source target observe its own content publisher. Only the inline host
    // observes it, preventing a reporter -> source redraw feedback loop.
    @State private var inlineContentStore: GeekInlineTertiaryContentStore

    init(
        accessibilityLabel: String,
        chartRangeMetric: GeekChartRangeMetric? = nil,
        popoverSize: CGSize,
        sourceOffset: CGFloat? = nil,
        usesCardActiveBorder: Bool = false,
        @ViewBuilder target: () -> Target,
        @ViewBuilder detail: () -> Detail
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.chartRangeMetric = chartRangeMetric
        self.popoverSize = popoverSize
        self.sourceOffset = sourceOffset
        self.usesCardActiveBorder = usesCardActiveBorder
        self.target = target()
        self.detail = detail()
        _inlineContentStore = State(initialValue: GeekInlineTertiaryContentStore())
    }

    var body: some View {
        target
            .environment(
                \.geekCombinedCardIsActive,
                false
            )
            .environment(
                \.geekCombinedCardIsSelected,
                usesCardActiveBorder && isInlinePresented
            )
            .overlay {
                if isInlinePresented, !usesCardActiveBorder {
                    RoundedRectangle(
                        cornerRadius: GeekVisualTokens.cardRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        Color.accentColor.opacity(0.9),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    targetHoverChanged(true)
                case .ended:
                    targetHoverChanged(false)
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    revealImmediately()
                }
            )
            .accessibilityAction(named: Text(L10n.text("显示三级详情", "Show Deep Detail"))) {
                revealImmediately()
            }
            .onDisappear {
                cancelHoverIntent()
                dismissDetail()
                reportPanelActivity(false)
            }
            .onChange(of: tertiaryPresentationMode) {
                if tertiaryPresentationMode == .unavailable {
                    dismissDetail()
                }
            }
            .onChange(of: activeInlineRequestID) {
                inlineHostRequestChanged()
            }
            .onChange(of: isPanelHoverEnvelopeActive) {
                guard !isPanelHoverEnvelopeActive,
                      isInlinePresented,
                      !isTargetHovered,
                      !isDetailHovered else { return }
                scheduleDismissal()
            }
            .onChange(of: chartRangeSelection.range) {
                guard isInlinePresented else { return }
                inlineContentStore.update(hostedDetail, force: true)
            }
            .onChange(of: isTargetHovered) { synchronizePanelActivity() }
            .onChange(of: isDetailHovered) { synchronizePanelActivity() }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: GeekTertiarySourceOffsetKey.self,
                        value: proxy.frame(in: .named(GeekTertiarySourceCoordinateSpace.name)).minY
                    )
                }
            }
            .onPreferenceChange(GeekTertiarySourceOffsetKey.self) { offset in
                guard offset.isFinite else { return }
                measuredSourceOffset = max(0, offset)
            }
            .background {
                if isInlinePresented {
                    GeekInlineTertiaryContentReporter(
                        store: inlineContentStore,
                        content: hostedDetail
                    )
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
            }
    }

    private func targetHoverChanged(_ hovering: Bool) {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isCapturingMenuBarPanelSnapshots else { return }
#endif
        guard isTargetHovered != hovering else { return }
        isTargetHovered = hovering
        cancelHoverIntent()

        if hovering {
            guard !isInlinePresented,
                  tertiaryPresentationMode == .column else { return }
            guard let hoverCoordinator else {
                presentDetail(pinned: false)
                return
            }
            hoverIntent = hoverCoordinator.scheduleTertiaryPreview(
                identifier: panelActivityID.uuidString,
                condition: {
                    isTargetHovered
                        && !isInlinePresented
                        && tertiaryPresentationMode == .column
                },
                action: {
                    presentDetail(pinned: false)
                    hoverIntent = nil
                }
            )
        } else {
            hoverCoordinator?.tertiaryHoverExited()
            scheduleDismissal()
        }
    }

    private func detailHoverChanged(_ hovering: Bool) {
        guard isDetailHovered != hovering else { return }
        isDetailHovered = hovering
        cancelHoverIntent()
        if !hovering {
            scheduleDismissal()
        }
    }

    private func revealImmediately() {
        cancelHoverIntent()
        presentDetail(pinned: true)
    }

    private func scheduleDismissal() {
        guard isInlinePresented, !isPinned else { return }
        cancelHoverIntent()
        guard let hoverCoordinator else {
            dismissDetail()
            return
        }
        hoverIntent = hoverCoordinator.scheduleHoverDismissal(
            condition: {
                !isTargetHovered
                    && !isDetailHovered
                    && !isPanelHoverEnvelopeActive
                    && isInlinePresented
                    && !isPinned
            },
            action: {
                dismissDetail()
                hoverIntent = nil
            }
        )
    }

    private func cancelHoverIntent() {
        guard let hoverIntent else { return }
        hoverCoordinator?.invalidateHoverIntent(hoverIntent)
        self.hoverIntent = nil
    }

    private func synchronizePanelActivity() {
        reportPanelActivity(isInlinePresented || isTargetHovered || isDetailHovered)
    }

    private func presentDetail(pinned: Bool) {
        guard tertiaryPresentationMode == .column else { return }
        inlineContentStore.update(hostedDetail, force: true)
        let accepted = inlineTertiaryEvent?(.present(GeekInlineTertiaryRequest(
            id: panelActivityID,
            accessibilityLabel: accessibilityLabel,
            chartRangeMetric: chartRangeMetric,
            preferredSize: popoverSize,
            isPinned: pinned,
            sourceOffset: measuredSourceOffset ?? sourceOffset,
            contentStore: inlineContentStore,
            hoverChanged: detailHoverChanged
        ))) ?? false
        guard accepted else { return }
        isInlinePresented = true
        isPinned = pinned
        synchronizePanelActivity()
    }

    private func dismissDetail() {
        isDetailHovered = false
        isPinned = false
        if isInlinePresented {
            _ = inlineTertiaryEvent?(.dismiss(panelActivityID))
            isInlinePresented = false
        }
        synchronizePanelActivity()
    }

    private func inlineHostRequestChanged() {
        guard isInlinePresented, activeInlineRequestID != panelActivityID else { return }
        isDetailHovered = false
        isInlinePresented = false
        isPinned = false
        synchronizePanelActivity()
    }

    private func reportPanelActivity(_ active: Bool) {
        guard active != isPanelActivityReported else { return }
        isPanelActivityReported = active
        panelHoverActivity?(panelActivityID, active)
    }

    private var hostedDetail: AnyView {
        AnyView(
            detail
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        detailHoverChanged(true)
                    case .ended:
                        detailHoverChanged(false)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityLabel)
        )
    }
}

enum GeekTertiarySourceCoordinateSpace {
    static let name = "geek.secondary.content"
}

private struct GeekTertiarySourceOffsetKey: PreferenceKey {
    static let defaultValue = CGFloat.nan

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next.isFinite { value = next }
    }
}

/// Keeps an inline deep-detail surface connected to the value snapshots from
/// its still-mounted source card. Updating through an AppKit bridge defers the
/// observable-object mutation until after SwiftUI's current render pass.
private struct GeekInlineTertiaryContentReporter: NSViewRepresentable {
    let store: GeekInlineTertiaryContentStore
    let content: AnyView

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let now = Date()
        guard context.coordinator.shouldQueue(now: now) else { return }
        Task { @MainActor in
            store.update(content, now: now)
        }
    }

    final class Coordinator {
        private var lastQueuedAt: Date?

        func shouldQueue(now: Date) -> Bool {
            guard GeekInlineTertiaryContentRefreshPolicy.shouldPublish(
                lastPublishedAt: lastQueuedAt,
                now: now
            ) else { return false }
            lastQueuedAt = now
            return true
        }
    }
}

struct GeekInlineTertiaryLiveContent: View {
    @ObservedObject var store: GeekInlineTertiaryContentStore

    var body: some View {
        store.content.id(store.identity)
    }
}

enum GeekHoverDetailMetrics {
    static let historySize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 216)
    static let cpuHistorySize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 250)
    static let memoryHistorySize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 360)
    static let cpuUsageSize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 270)
    static let compactHistorySize = CGSize(width: MiniWindowStyleTokens.compactHistoryWidth, height: 216)
    static let diskIOSize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 248)
    // Header (20) + capacity ring (154) + six value rows (6 x 16), with the
    // canvas' seven 7-point gaps and 20-point vertical padding.
    static let volumeSize = CGSize(width: 220, height: 339)
    static let vpnWidth: CGFloat = 220
    static let compactSize = CGSize(width: 220, height: 148)
    static let uptimeSize = CGSize(width: 220, height: 136)
}

struct GeekNetworkHistoryHoverDetail: View {
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let uploadValue: String
    let downloadValue: String

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("网络活动", "Network Activity"),
            trailing: L10n.text(
                "最近 \(Int(duration.rounded())) 秒",
                "Last \(Int(duration.rounded())) Seconds"
            ),
            showsRangePicker: true
        ) {
            GeekPrecisionNetworkChart(
                points: points,
                accessibilityLabel: L10n.text(
                    "网络时间柱状图：按时间分桶显示，上方上传、下方下载，左旧右新，缺测留空",
                    "Network time buckets: upload above, download below; oldest on the left, missing periods stay empty"
                ),
                duration: duration,
                showsLegend: false,
                showsTimelineLabels: true,
                showsTooltip: true,
                horizontalInset: 2
            )
            .frame(height: 154)

            HStack(spacing: 18) {
                GeekHoverLegendValue(
                    title: L10n.text("上传", "Upload"),
                    value: uploadValue,
                    color: MenuBarNetworkPalette.upload
                )
                GeekHoverLegendValue(
                    title: L10n.text("下载", "Download"),
                    value: downloadValue,
                    color: MenuBarNetworkPalette.download
                )
            }
        }
    }
}

struct GeekProcessorActivityHoverDetail: View {
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let userValue: String
    let systemValue: String
    var samplingInterval: TimeInterval = 1

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("处理器活动 · 时间历史", "Processor · Time History"),
            showsRangePicker: true
        ) {
            GeekPrecisionLineChart(
                points: points,
                series: [
                    MenuBarTelemetrySeries(
                        id: "cpu-user-hover",
                        title: L10n.text("用户", "User"),
                        channel: .cpuUser,
                        color: AppChartPalette.cpuUser
                    ),
                    MenuBarTelemetrySeries(
                        id: "cpu-system-hover",
                        title: L10n.text("系统", "System"),
                        channel: .cpuSystem,
                        color: AppChartPalette.cpuSystem
                    )
                ],
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text(
                    "CPU 时间柱：用户与系统显示区间加权平均；悬停可查看短暂缺测的估算，长时间未记录保留空档，左旧右新",
                    "CPU time bars show interval-weighted user and system means; hover for estimates across brief missing samples. Unrecorded periods remain gaps, oldest on the left"
                ),
                style: .stackedBars,
                duration: duration,
                showsTimelineLabels: true,
                showsTooltip: true,
                horizontalInset: 2,
                showsValueLabels: true,
                cpuSamplingInterval: samplingInterval
            )
            .frame(height: 154)

            GeekHistoryStatisticsRow(points: points, channel: .cpuTotal, unit: .percent)
            GeekHistoryCoverageRow(points: points, channel: .cpuTotal, duration: duration)

            // Live figures already appear in the parent; keep the third tier
            // focused on the plot. Aggregation semantics remain discoverable.
            Text(L10n.text("固定柱槽 · 时长加权均值 / 峰值", "Fixed slots · Time-weighted mean / peak"))
                .font(.caption2).foregroundStyle(.secondary)
                .help(L10n.text("每柱覆盖所选范围的一段时间；CPU 增量按其测量区间分配。缺测不延展，浅色帽线保留峰值。切换时间范围不改变采样频率。", "Each column covers part of the selected range. CPU deltas are assigned to their measured intervals; gaps are not extended. Pale caps retain peaks. Range selection does not change polling."))
        }
    }
}

struct GeekGPUHoverDetail: View {
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let isAvailable: Bool
    let currentValue: String
    let memoryValue: String?
    let temperatureValue: String?

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("GPU 活动", "GPU Activity"),
            trailing: currentValue,
            showsRangePicker: true
        ) {
            if isAvailable {
                GeekPrecisionLineChart(
                    points: points,
                    series: [
                        MenuBarTelemetrySeries(
                            id: "gpu-hover",
                            title: "GPU",
                            channel: .gpu,
                            color: AppChartPalette.gpu
                        )
                    ],
                    valueRange: 0...100,
                    unit: .percent,
                    accessibilityLabel: L10n.text("GPU 活动时间柱状图", "GPU activity time bars"),
                    style: .stackedBars,
                    duration: duration,
                    showsTimelineLabels: true,
                    showsTooltip: true,
                    horizontalInset: 2,
                    showsValueLabels: true
                )
                .frame(height: 154)
                GeekHistoryStatisticsRow(points: points, channel: .gpu, unit: .percent)
                GeekHistoryCoverageRow(points: points, channel: .gpu, duration: duration)
            } else {
                GeekHoverUnavailableState(
                    text: L10n.text("此机型当前未提供可读取的 GPU 使用率", "GPU utilization is not readable on this Mac")
                )
                .frame(height: 154)
            }

            HStack(spacing: 12) {
                GeekHoverLegendValue(
                    title: L10n.text("GPU 内存", "GPU Memory"),
                    value: memoryValue ?? "--",
                    color: AppChartPalette.memory
                )
                GeekHoverLegendValue(
                    title: L10n.text("温度", "Temperature"),
                    value: temperatureValue ?? "--",
                    color: AppChartPalette.thermal
                )
                GeekHoverValueRow(
                    title: L10n.text("频率 / FPS", "Frequency / FPS"),
                    value: "-- / --"
                )
            }
        }
    }
}

struct GeekProcessorUsageHoverDetail: View {
    let total: Double?
    let applications: Double?
    let system: Double?
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    var samplingInterval: TimeInterval = 1

    var body: some View {
        GeekHoverDetailCanvas(title: L10n.text("CPU 占用", "CPU Usage")) {
            HStack(spacing: 8) {
                usageRing(title: L10n.text("总占用", "Total"), value: total, tint: AppDesignTokens.Palette.technicalLine)
                usageRing(title: L10n.text("用户", "User"), value: applications, tint: AppChartPalette.cpuUser)
                usageRing(title: L10n.text("系统", "System"), value: system, tint: AppChartPalette.cpuSystem)
            }
            .frame(maxWidth: .infinity)
            GeekPrecisionLineChart(
                points: points,
                series: [
                    MenuBarTelemetrySeries(id: "usage-user", title: L10n.text("用户", "User"), channel: .cpuUser, color: AppChartPalette.cpuUser),
                    MenuBarTelemetrySeries(id: "usage-system", title: L10n.text("系统", "System"), channel: .cpuSystem, color: AppChartPalette.cpuSystem)
                ],
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text("总 CPU 时间历史，全机 0–100%", "Total CPU time history, whole Mac 0–100%"),
                style: .stackedBars,
                duration: duration,
                showsTooltip: true,
                showsValueLabels: true,
                cpuSamplingInterval: samplingInterval
            )
            .frame(height: 94)
            Text(L10n.text("全机 0–100% · 区间平均", "Whole Mac 0–100% · Interval means"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func usageRing(title: String, value: Double?, tint: Color) -> some View {
        GeekCombinedRing(
            title: title,
            value: value.map { GeekChartUnit.percent.formatted($0, compact: true) } ?? "—",
            progress: value.map { $0 / 100 },
            tint: tint,
            size: 92
        )
        .frame(maxWidth: .infinity)
    }
}

struct GeekProcessorUptimeHoverDetail: View {
    let uptime: String
    let poweredOnAt: String

    var body: some View {
        GeekHoverDetailCanvas(title: L10n.text("运行时间", "Uptime")) {
            GeekHoverValueRow(title: L10n.text("已开机", "Powered On"), value: uptime)
            GeekHoverValueRow(title: L10n.text("启动时间", "Started"), value: poweredOnAt)
        }
    }
}

struct GeekMemoryHistoryHoverDetail: View {
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let currentValue: String
    let pressure: String
    let snapshot: MemorySnapshot?

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("内存组成", "Memory Composition"),
            trailing: currentValue,
            showsRangePicker: true,
            spacing: 4
        ) {
            GeekPrecisionLineChart(
                points: points,
                series: [
                    MenuBarTelemetrySeries(id: "memory-app", title: L10n.text("应用及其他", "App & Other"), channel: .memoryAppOrOtherBytes, color: AppChartPalette.memory),
                    MenuBarTelemetrySeries(id: "memory-wired", title: L10n.text("有线内存", "Wired"), channel: .memoryWiredBytes, color: AppChartPalette.cpuSystem),
                    MenuBarTelemetrySeries(id: "memory-compressed", title: L10n.text("压缩", "Compressed"), channel: .compressedMemoryBytes, color: AppDesignTokens.Palette.caution)
                ],
                valueRange: 0...Double(snapshot?.measurements.physicalBytes.value ?? points.compactMap(\.memoryPhysicalBytes).last ?? 1),
                unit: .bytes,
                accessibilityLabel: L10n.text("真实内存组成历史：应用及其他、有线内存、压缩，三者互不重复", "Measured memory composition: non-overlapping App & Other, Wired, Compressed"),
                style: .stackedBars,
                duration: duration,
                showsTimelineLabels: true,
                showsTooltip: true,
                horizontalInset: 2,
                showsValueLabels: true
            )
            .frame(height: 174)
            HStack {
                Text(L10n.text("占用", "Used"))
                Text(currentValue).monospacedDigit()
                Spacer(minLength: 4)
                Text(pressure).foregroundStyle(.secondary)
            }.font(.caption)
            GeekHistoryStatisticsRow(points: points, channel: .memory, unit: .percent)
            GeekHistoryCoverageRow(points: points, channel: .memoryAppOrOtherBytes, duration: duration)
            memoryBytesChart(channel: .swapUsedBytes, title: L10n.text("交换 · 单独计量", "Swap · Separate"), color: AppDesignTokens.Palette.diagnostic)
        }
    }

    private func memoryBytesChart(channel: MenuBarTelemetryChannel, title: String, color: Color) -> some View {
        let values = points.compactMap { channel.value(in: $0) }
        let maximum = max(1, values.filter(\.isFinite).max() ?? 1)
        return VStack(spacing: 1) {
            HStack {
                Label(title, systemImage: "square.fill")
                    .foregroundStyle(color)
                Spacer(minLength: 4)
                Text(points.last.flatMap { channel.value(in: $0) }.map { GeekChartUnit.bytes.formatted($0) } ?? "—")
                    .monospacedDigit()
            }
            .font(.caption)
            GeekPrecisionLineChart(
                points: points,
                series: [MenuBarTelemetrySeries(id: title, title: title, channel: channel, color: color)],
                valueRange: 0...maximum,
                unit: .bytes,
                accessibilityLabel: title,
                style: .stackedBars,
                duration: duration,
                showsLegend: false,
                showsTooltip: true,
                horizontalInset: 2,
                showsValueLabels: true
            )
            .frame(height: 50)
        }
    }
}

struct GeekSwapHoverDetail: View {
    let snapshot: MemorySnapshot?

    var body: some View {
        GeekHoverDetailCanvas(title: L10n.text("交换内存", "Swap Memory")) {
            if let snapshot {
                if let used = snapshot.measurements.swapUsedBytes.value {
                    HStack(spacing: 8) {
                        GeekHoverLargeValue(
                            title: L10n.text("已用", "Used"),
                            value: ByteFormat.string(Int64(clamping: used))
                        )
                        GeekHoverLargeValue(
                            title: L10n.text("总计", "Total"),
                            value: snapshot.swapTotalBytes > 0
                                ? ByteFormat.string(snapshot.swapTotalBytes)
                                : L10n.text("按需分配", "On Demand")
                        )
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    GeekHoverUnavailableState(
                        text: snapshot.measurements.swapUsedBytes.unavailableDetail
                            ?? L10n.text("交换内存数据不可用", "Swap memory data unavailable")
                    )
                }

                GeekHoverValueRow(
                    title: L10n.text("历史趋势", "History Trend"),
                    value: L10n.text("尚未采集", "Not Collected")
                )
            } else {
                GeekHoverUnavailableState(text: L10n.text("正在读取交换使用情况", "Reading swap usage"))
            }
        }
    }
}

struct GeekDiskVolumeHoverDetail: View {
    let snapshot: StorageCapacitySnapshot?
    let volumeName: String
    let status: String
    let temperature: String?
    var healthCheckedAt: Date? = nil
    var showsHealthTimestamp = true

    var body: some View {
        GeekHoverDetailCanvas(title: volumeName.isEmpty ? L10n.text("系统磁盘", "System Disk") : volumeName) {
            if let snapshot {
                GeekDiskCapacityRing(
                    breakdown: GeekDiskCapacityBreakdown(snapshot: snapshot)
                )
                .frame(maxWidth: .infinity)

                GeekHoverValueRow(
                    title: L10n.text("系统可用", "System Available"),
                    value: ByteFormat.storageString(snapshot.userAvailableBytes)
                )
                GeekHoverValueRow(
                    title: L10n.text("当前严格空闲", "Current Strict Free"),
                    value: ByteFormat.storageString(snapshot.availableBytes)
                )
                GeekHoverValueRow(
                    title: L10n.text("可回收估算", "Reclaimable Estimate"),
                    value: ByteFormat.storageString(snapshot.reclaimableEstimateBytes)
                )

                GeekHoverValueRow(title: L10n.text("SSD 状态", "SSD Status"), value: status)
                if showsHealthTimestamp {
                    GeekHoverValueRow(
                        title: L10n.text("健康读取", "Health read"),
                        value: GeekDiskHealthTimestamp.ageText(healthCheckedAt)
                    )
                    .help(GeekDiskHealthTimestamp.detailText(healthCheckedAt))
                    .accessibilityValue(GeekDiskHealthTimestamp.detailText(healthCheckedAt))
                }
                GeekHoverValueRow(
                    title: L10n.text("温度", "Temperature"),
                    value: temperature ?? L10n.text("未采集", "Not Collected")
                )
            } else {
                GeekHoverUnavailableState(text: L10n.text("正在读取磁盘容量", "Reading disk capacity"))
            }
        }
    }
}

struct GeekDiskCapacityBreakdown: Equatable, Sendable {
    let totalBytes: Int64
    let usedBytes: Int64
    let reclaimableBytes: Int64
    let freeBytes: Int64

    init(snapshot: StorageCapacitySnapshot) {
        let total = max(0, snapshot.totalBytes)
        let free = min(total, max(0, snapshot.availableBytes))
        let reclaimable = min(
            max(0, total - free),
            max(0, snapshot.reclaimableEstimateBytes)
        )

        totalBytes = total
        freeBytes = free
        reclaimableBytes = reclaimable
        usedBytes = min(total, max(0, snapshot.userUsedBytes))
    }

    var usedRatio: Double { ratio(usedBytes) }
    var reclaimableRatio: Double { ratio(reclaimableBytes) }

    private func ratio(_ bytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }
}

private struct GeekDiskCapacityRing: View {
    let breakdown: GeekDiskCapacityBreakdown

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.26), lineWidth: 10)

            GeekDiskCapacityArc(
                start: 0,
                end: breakdown.usedRatio,
                color: AppChartPalette.storageUsed
            )
            GeekDiskCapacityArc(
                start: breakdown.usedRatio,
                end: breakdown.usedRatio + breakdown.reclaimableRatio,
                color: AppChartPalette.cpuSystem
            )

            VStack(spacing: 5) {
                GeekDiskCapacityValue(
                    title: L10n.text("不可回收已用", "Used"),
                    value: ByteFormat.storageString(breakdown.usedBytes),
                    color: AppChartPalette.storageUsed
                )
                GeekDiskCapacityValue(
                    title: L10n.text("可回收估算", "Reclaimable Estimate"),
                    value: ByteFormat.storageString(breakdown.reclaimableBytes),
                    color: AppChartPalette.cpuSystem
                )
                GeekDiskCapacityValue(
                    title: L10n.text("当前严格空闲", "Current Strict Free"),
                    value: ByteFormat.storageString(breakdown.freeBytes),
                    color: Color.secondary.opacity(0.42)
                )
            }
            .padding(.horizontal, 18)
        }
        .frame(width: 154, height: 154)
        .accessibilityHint(L10n.text(
            "系统可用 = 当前严格空闲 + 可回收估算；这是容量估算，不等同于已扫描的安全清理结果。",
            "System available = current strict free + reclaimable estimate; this capacity estimate is not a scanned safe-cleanup result."
        ))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("磁盘容量构成", "Disk capacity composition"))
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct GeekDiskCapacityArc: View {
    let start: Double
    let end: Double
    let color: Color

    var body: some View {
        Circle()
            .trim(
                from: min(1, max(0, start)),
                to: min(1, max(0, end))
            )
            .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .butt))
            .rotationEffect(.degrees(-90))
    }
}

private struct GeekDiskCapacityValue: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct GeekDiskIOHoverDetail: View {
    let points: [NativeDiskIOPoint]
    let counters: NativeDiskIOCounters?
    let duration: TimeInterval

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("磁盘 I/O", "Disk I/O"),
            trailing: L10n.text(
                "最近 \(Int(duration.rounded())) 秒",
                "Last \(Int(duration.rounded())) Seconds"
            ),
            showsRangePicker: true
        ) {
            GeekDiskIOChart(
                points: points,
                accessibilityLabel: L10n.text("磁盘读取与写入趋势", "Disk read and write trend"),
                duration: duration,
                showsTimelineLabels: true,
                showsTooltip: true,
                horizontalInset: 2
            )
            .frame(height: 164)

            if let counters {
                HStack(spacing: 16) {
                    GeekHoverLegendValue(
                        title: L10n.text("累计读取", "Data Read"),
                        value: ByteFormat.string(Int64(clamping: counters.readBytes)),
                        color: AppChartPalette.cpuSystem
                    )
                    GeekHoverLegendValue(
                        title: L10n.text("累计写入", "Data Written"),
                        value: ByteFormat.string(Int64(clamping: counters.writtenBytes)),
                        color: AppChartPalette.primary
                    )
                }
            } else {
                GeekHoverValueRow(title: L10n.text("累计计数", "Cumulative Counters"), value: "--")
            }
        }
    }
}

struct GeekHistoryStatisticsRow: View {
    let points: [MenuBarTelemetryPoint]
    let channel: MenuBarTelemetryChannel
    let unit: GeekChartUnit

    var body: some View {
        let stats = GeekSeriesStatistics(values: points.compactMap { channel.value(in: $0) })
        let current = points.last.flatMap { channel.value(in: $0) }.flatMap { $0.isFinite ? $0 : nil }
        return HStack(spacing: 8) {
            readout(L10n.text("当前", "Now"), value: current)
            Spacer(minLength: 0)
            readout(L10n.text("平均", "Mean"), value: stats?.average)
            Spacer(minLength: 0)
            readout(L10n.text("峰值", "Peak"), value: stats?.maximum)
        }
        .font(.system(size: 11))
        .monospacedDigit()
    }

    private func readout(_ title: String, value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value.map { unit.formatted($0) } ?? "—")
        }
    }
}

struct GeekHistoryCoverageRow: View {
    let points: [MenuBarTelemetryPoint]
    let channel: MenuBarTelemetryChannel
    let duration: TimeInterval

    var body: some View {
        let dates = points.filter { channel.value(in: $0)?.isFinite == true }.map(\.date)
        let first = dates.min()
        let last = dates.max()
        let span = first.flatMap { start in last.map { max(0, $0.timeIntervalSince(start)) } } ?? 0
        let detail = L10n.text("有效样本 \(dates.count)/\(points.count) · 缺测留空", "Valid samples \(dates.count)/\(points.count) · Gaps remain empty")
        return HStack {
            Label(first == nil ? L10n.text("等待采样", "Waiting for samples")
                : L10n.text("已有 \(Self.spanText(span))", "Available: \(Self.spanText(span))"), systemImage: "clock")
            Spacer(minLength: 4)
            if let first, let last {
                Text("\(PanelChartDateFormatting.string(for: first, visibleDuration: duration)) – \(PanelChartDateFormatting.string(for: last, visibleDuration: duration))")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .help(detail)
        .accessibilityHint(detail)
    }

    static func spanText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return L10n.text("\(Int(seconds)) 秒", "\(Int(seconds)) s") }
        if seconds < 3_600 { return L10n.text(String(format: "%.1f 分钟", seconds / 60), String(format: "%.1f min", seconds / 60)) }
        return L10n.text(String(format: "%.1f 小时", seconds / 3_600), String(format: "%.1f h", seconds / 3_600))
    }
}

struct TimeRangeSelector: View {
    static let rangeChangeAnimationDuration: TimeInterval = 0.1

    let selectedRange: GeekChartRange
    let availableRanges: [GeekChartRange]
    let onChange: (GeekChartRange) -> Void
    let appearance: ColorScheme
    let isEnabled: Bool
    let accessibilityLabel: String

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(availableRanges) { range in
                Button {
                    onChange(range)
                } label: {
                    if range == selectedRange {
                        Label(range.title, systemImage: "checkmark")
                    } else {
                        Text(range.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(selectedRange.title)
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(appearance == .dark ? Color.white.opacity(0.92) : .primary)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .frame(minWidth: 28, minHeight: 22)
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(isHovered && isEnabled ? 0.06 : 0))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selectedRange.title)
        .accessibilityHint(L10n.text("打开时间范围菜单", "Open time range menu"))
    }
}

struct GeekHoverDetailCanvas<Content: View>: View {
    let title: String
    let trailing: String?
    let showsRangePicker: Bool
    let availableRanges: [GeekChartRange]
    let spacing: CGFloat
    let content: Content

    @Environment(\.geekChartRangeSelection) private var chartRangeSelection
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        trailing: String? = nil,
        showsRangePicker: Bool = false,
        availableRanges: [GeekChartRange] = GeekChartRange.allCases,
        spacing: CGFloat = 7,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.showsRangePicker = showsRangePicker
        self.availableRanges = availableRanges
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsRangePicker {
                    if let trailing {
                        Text(trailing)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    TimeRangeSelector(
                        selectedRange: chartRangeSelection.range,
                        availableRanges: availableRanges,
                        onChange: chartRangeSelection.select,
                        appearance: colorScheme,
                        isEnabled: true,
                        accessibilityLabel: "\(title) \(L10n.text("历史时间范围", "History time range"))"
                    )
                } else if let trailing {
                    Text(trailing)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Group {
                if showsRangePicker {
                    content
                        .id(chartRangeSelection.range)
                        .transition(.opacity)
                } else {
                    content
                }
            }
            .animation(
                .easeInOut(duration: TimeRangeSelector.rangeChangeAnimationDuration),
                value: chartRangeSelection.range
            )
        }
        .padding(GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct GeekHoverValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

struct GeekHoverLegendValue: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .font(.footnote)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

struct GeekHoverLargeValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct GeekHoverUnavailableState: View {
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
