import SwiftUI

typealias GeekPanelHoverActivityHandler = @MainActor @Sendable (UUID, Bool) -> Void
typealias GeekInlineTertiaryEventHandler = @MainActor @Sendable (GeekInlineTertiaryEvent) -> Bool
typealias GeekTertiaryHoverHandler = @MainActor @Sendable (Bool) -> Void

enum GeekInlineTertiaryContentRefreshPolicy {
    // Coalesce updates within a short display budget, without holding a new
    // reading for almost an entire sampling interval.
    static let minimumInterval = MenuBarPerformancePolicy.contentCoalescingInterval
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
    private(set) var sourceOffset: CGFloat?
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

    /// Update geometry without opening a new history request or replacing its
    /// live content. The route check also rejects a callback delivered between
    /// closing the route and clearing the host's request state.
    @discardableResult
    static func updateSourceOffset(
        id: UUID,
        offset: CGFloat,
        currentRequest: inout Self?,
        route: GeekPanelRoute
    ) -> Bool {
        guard offset.isFinite,
              case let .history(_, .inline(routeID)) = route,
              routeID == id,
              var request = currentRequest,
              request.id == id,
              let normalized = GeekPanelPresentationMetrics.normalizedTertiarySourceOffset(offset),
              request.sourceOffset != normalized else { return false }
        request.sourceOffset = normalized
        currentRequest = request
        return true
    }
}

enum GeekInlineTertiaryEvent {
    case present(GeekInlineTertiaryRequest)
    case dismiss(UUID)
    case updateSourceOffset(id: UUID, offset: CGFloat)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.menuBarChartContext) private var chartContext

    let accessibilityLabel: String
    let chartRangeMetric: GeekChartRangeMetric?
    let popoverSize: CGSize
    let sourceOffset: CGFloat?
    let usesCardActiveBorder: Bool
    /// Row-sized targets (a fan or temperature row inside a card) draw the
    /// inline-selection stroke this far outside their bounds horizontally,
    /// so the stroke never sits on the row's first or last glyph. The row's
    /// layout and hover area are unchanged.
    let selectionOutset: CGFloat
    private let target: Target
    private let detail: () -> Detail

    @State private var isTargetHovered = false
    @State private var isDetailHovered = false
    @State private var hoverIntent: GeekPanelCoordinator.HoverIntent?
    @State private var panelActivityID = UUID()
    @State private var isPanelActivityReported = false
    @State private var isInlinePresented = false
    @State private var isPinned = false
    @State private var measuredSourceOffset: CGFloat?
    @State private var sourceOffsetUpdateTask: Task<Void, Never>?
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
        selectionOutset: CGFloat = 0,
        @ViewBuilder target: () -> Target,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.chartRangeMetric = chartRangeMetric
        self.popoverSize = popoverSize
        self.sourceOffset = sourceOffset
        self.usesCardActiveBorder = usesCardActiveBorder
        self.selectionOutset = selectionOutset
        self.target = target()
        self.detail = detail
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
                        panelChromePalette?.accent ?? GeekVisualTokens.cardBorder(
                            for: colorScheme,
                            visualMode: visualMode,
                            isSelected: true
                        ),
                        lineWidth: GeekVisualTokens.cardBorderLineWidth(
                            isActive: false,
                            isSelected: true,
                            displayScale: displayScale
                        )
                    )
                    .padding(.horizontal, -selectionOutset)
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
            .onChange(of: resolvedChartRange) {
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
                sourceOffsetChanged(offset)
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

    private func selectChartRange(_ range: GeekChartRange) {
        // A native menu moves the pointer away from its tertiary surface while
        // the selection is being committed. Keep the current detail attached
        // before that pointer movement can reveal a different source card.
        if isInlinePresented && !isPinned {
            revealImmediately()
        }
        chartRangeSelection.apply(range, to: chartRangeMetric)
    }

    private var resolvedChartRange: GeekChartRange {
        chartRangeSelection.resolvedRange(for: chartRangeMetric)
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

    private func sourceOffsetChanged(_ offset: CGFloat) {
        guard offset.isFinite else { return }
        let normalized = max(0, offset)
        guard measuredSourceOffset != normalized else { return }
        measuredSourceOffset = normalized
        scheduleSourceOffsetUpdate()
    }

    private func scheduleSourceOffsetUpdate() {
        sourceOffsetUpdateTask?.cancel()
        sourceOffsetUpdateTask = nil
        guard isInlinePresented, activeInlineRequestID == panelActivityID else { return }
        // Preference delivery occurs during layout. Defer native placement to
        // the next main-actor job and read the latest measured position there.
        sourceOffsetUpdateTask = Task { @MainActor in
            guard !Task.isCancelled,
                  isInlinePresented,
                  activeInlineRequestID == panelActivityID,
                  let latestOffset = measuredSourceOffset else { return }
            _ = inlineTertiaryEvent?(.updateSourceOffset(
                id: panelActivityID,
                offset: latestOffset
            ))
            sourceOffsetUpdateTask = nil
        }
    }

    private func cancelSourceOffsetUpdate() {
        sourceOffsetUpdateTask?.cancel()
        sourceOffsetUpdateTask = nil
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
        cancelSourceOffsetUpdate()
        isDetailHovered = false
        isPinned = false
        if isInlinePresented {
            _ = inlineTertiaryEvent?(.dismiss(panelActivityID))
            isInlinePresented = false
        }
        synchronizePanelActivity()
    }

    private func inlineHostRequestChanged() {
        guard isInlinePresented else { return }
        guard activeInlineRequestID != panelActivityID else {
            // The first geometry preference can arrive before the host's new
            // request ID reaches this source. Catch up once that ID is active.
            scheduleSourceOffsetUpdate()
            return
        }
        cancelSourceOffsetUpdate()
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
            detail()
                .environment(\.menuBarChartContext, chartContext)
                .environment(
                    \.geekChartRangeSelection,
                    GeekChartRangeSelection(
                        range: resolvedChartRange,
                        select: selectChartRange
                    )
                )
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

    func updateNSView(_ nsView: NSView, context: Context) {
        let now = Date()
        Task { @MainActor in
            store.update(content, now: now)
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
    static let historySize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: MiniWindowStyleTokens.historyHeight)
    static let cpuHistorySize = historySize
    static let memoryHistorySize = historySize
    static let cpuUsageSize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 270)
    static let compactHistorySize = CGSize(width: MiniWindowStyleTokens.compactHistoryWidth, height: MiniWindowStyleTokens.historyHeight)
    static let diskIOSize = historySize
    // Header (20) + capacity ring (154) + six value rows (6 x 16), with the
    // canvas' seven 7-point gaps and 20-point vertical padding.
    static let volumeSize = CGSize(width: 220, height: 339)
    static let vpnWidth: CGFloat = 220
    static let compactSize = CGSize(width: 220, height: 148)
    static let uptimeSize = CGSize(width: 220, height: 106)
    /// Horizontal clearance between a selected row's text and its selection
    /// stroke; stays inside the card's 8-point content inset.
    static let rowSelectionOutset = MiniWindowStyleTokens.rowSpacing
}

struct GeekNetworkHistoryHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let uploadValue: String
    let downloadValue: String

    /// The history still draws the previous window (`MenuBarDisplayedHistory.isUpdating`).
    var isUpdating = false

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("网络活动", "Network Activity"),
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
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: 2
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, isUpdating: isUpdating))

            HStack(spacing: 18) {
                GeekHoverLegendValue(
                    title: L10n.text("上传", "Upload"),
                    value: uploadValue,
                    color: metricColors.networkUpload
                )
                GeekHoverLegendValue(
                    title: L10n.text("下载", "Download"),
                    value: downloadValue,
                    color: metricColors.networkDownload
                )
            }
        }
    }
}

struct GeekProcessorActivityHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let userValue: String
    let systemValue: String
    var samplingInterval: TimeInterval = 1

    /// The history still draws the previous window (`MenuBarDisplayedHistory.isUpdating`).
    var isUpdating = false

    var body: some View {
        GeekHoverDetailCanvas(
            title: "CPU",
            showsRangePicker: true
        ) {
            GeekPrecisionLineChart(
                points: points,
                series: [
                    MenuBarTelemetrySeries(
                        id: "cpu-user-hover",
                        title: L10n.text("用户", "User"),
                        channel: .cpuUser,
                        color: metricColors.cpuUser
                    ),
                    MenuBarTelemetrySeries(
                        id: "cpu-system-hover",
                        title: L10n.text("系统", "System"),
                        channel: .cpuSystem,
                        color: metricColors.cpuSystem
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
                showsLegend: false,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: 2,
                cpuSamplingInterval: samplingInterval
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, valueRange: "0–100%", isUpdating: isUpdating))
        }
    }
}

struct GeekGPUHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let isAvailable: Bool
    let currentValue: String
    let memoryValue: String?
    let temperatureValue: String?
    /// Pass the GPU card's ring colors so each legend dot matches its ring.
    var memoryTint: Color?
    var temperatureTint: Color?

    /// The history still draws the previous window (`MenuBarDisplayedHistory.isUpdating`).
    var isUpdating = false
    var sampledAt: Date? = nil

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
                            // The GPU ring's color exit (resolvedGPUTint).
                            color: metricColors.gpu(chartAccent: panelChartAccentColor)
                        )
                    ],
                    valueRange: 0...100,
                    unit: .percent,
                    accessibilityLabel: L10n.text("GPU 活动时间柱状图", "GPU activity time bars"),
                    style: .stackedBars,
                    duration: duration,
                    showsTimelineLabels: false,
                    showsTooltip: true,
                    horizontalInset: 2,
                    showsSamplingDetails: false
                )
                .environment(\.panelChartAccentColor, nil)
                .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, valueRange: "0–100%", isUpdating: isUpdating))
            } else {
                // No chart and no axis row: the state fills the whole plot
                // block so the shell keeps the available state's height.
                GeekHoverUnavailableState(
                    text: L10n.text("此机型当前未提供可读取的 GPU 使用率", "GPU utilization is not readable on this Mac")
                )
                .frame(height: MiniWindowStyleTokens.historyPlotHeight)
            }

            HStack(spacing: 12) {
                GeekHoverLegendValue(
                    title: GeekGPUVocabulary.memory,
                    value: memoryValue ?? "--",
                    color: memoryTint ?? metricColors.memoryApp
                )
                GeekHoverLegendValue(
                    title: L10n.text("温度", "Temperature"),
                    value: temperatureValue ?? "--",
                    color: temperatureTint ?? metricColors.sensorGraph(chartAccent: panelChartAccentColor)
                )
            }
            if let sampledAt {
                Text(L10n.text("采样 \(sampledAt.formatted(date: .omitted, time: .standard))",
                               "Sampled \(sampledAt.formatted(date: .omitted, time: .standard))"))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct GeekProcessorUsageHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
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
                usageRing(title: L10n.text("用户", "User"), value: applications, tint: metricColors.cpuUser)
                usageRing(title: L10n.text("系统", "System"), value: system, tint: metricColors.cpuSystem)
            }
            .frame(maxWidth: .infinity)
            GeekPrecisionLineChart(
                points: points,
                series: [
                    MenuBarTelemetrySeries(id: "usage-user", title: L10n.text("用户", "User"), channel: .cpuUser, color: metricColors.cpuUser),
                    MenuBarTelemetrySeries(id: "usage-system", title: L10n.text("系统", "System"), channel: .cpuSystem, color: metricColors.cpuSystem)
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
                .font(AdvancedPanelTypography.caption)
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
            Text(uptime == "--" ? "—" : uptime)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L10n.text("已运行", "Running for"))
                .accessibilityValue(uptime)
            GeekHoverValueRow(title: L10n.text("上次启动", "Last Boot"), value: poweredOnAt)
        }
    }
}

struct GeekMemoryHistoryHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    let currentValue: String
    let pressure: String
    let snapshot: MemorySnapshot?

    /// The history still draws the previous window (`MenuBarDisplayedHistory.isUpdating`).
    var isUpdating = false

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("内存压力", "Memory Pressure"),
            trailing: snapshot?.pressureEstimatePercent.map { "\($0)%" } ?? pressure,
            showsRangePicker: true,
            spacing: 4
        ) {
            GeekPrecisionLineChart(
                points: points,
                series: [
                    MenuBarTelemetrySeries(
                        id: "memory-pressure",
                        title: L10n.text("压力评估", "Pressure"),
                        channel: .memoryPressure,
                        // The legend takes the pressure ring's color: the
                        // current level through the same color exit.
                        color: metricColors.memoryPressure(for: snapshot?.reportablePressureLevel)
                    )
                ],
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text("内存压力评估变化", "Memory pressure history"),
                style: .stackedBars,
                duration: duration,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: 2,
                showsSamplingDetails: false,
                // Each bar has the color of its own sample's level, through
                // the same exit; an earlier normal period stays normal while
                // the ring is elevated.
                pressureLevelColor: { metricColors.memoryPressure(for: $0) }
            )
            .environment(\.panelChartAccentColor, nil)
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, valueRange: "0–100%", isUpdating: isUpdating))
            GeekHoverValueRow(
                title: L10n.text("当前状态", "Current Status"),
                value: pressure
            )
        }
    }
}

struct GeekSwapDetailData: Equatable {
    let usedBytes: UInt64?
    let totalBytes: UInt64?

    init(usedBytes: UInt64?, totalBytes: UInt64?) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    init(snapshot: MemorySnapshot?) {
        self.init(
            usedBytes: snapshot?.measurements.swapUsedBytes.value,
            totalBytes: snapshot.flatMap { $0.swapTotalBytes > 0 ? UInt64($0.swapTotalBytes) : nil }
        )
    }

    var fraction: Double? {
        guard let usedBytes, let totalBytes else { return nil }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    var summary: String {
        guard let usedBytes else { return "—" }
        let used = ByteFormat.string(Int64(clamping: usedBytes))
        guard let totalBytes else {
            return L10n.text("\(used) · 按需分配", "\(used) · On Demand")
        }
        return "\(used) / \(ByteFormat.string(Int64(clamping: totalBytes)))"
    }

    func chartMaximum(for points: [MenuBarTelemetryPoint]) -> Double {
        let observedMaximum = points.lazy.compactMap(\.swapUsedBytes).max() ?? 0
        return Double(max(1, max(max(totalBytes ?? 0, usedBytes ?? 0), observedMaximum)))
    }
}

struct GeekSwapHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    let snapshot: MemorySnapshot?
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval

    private var display: GeekSwapDetailData { GeekSwapDetailData(snapshot: snapshot) }

    /// The history still draws the previous window (`MenuBarDisplayedHistory.isUpdating`).
    var isUpdating = false

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("交换内存", "Swap Memory"),
            trailing: display.summary,
            showsRangePicker: true
        ) {
            if let fraction = display.fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25))
                        Capsule().fill(metricColors.swap)
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 6)
                .accessibilityLabel(L10n.text("交换内存已用比例", "Swap memory used fraction"))
                .accessibilityValue("\(Int((fraction * 100).rounded()))%")
            } else if display.usedBytes == nil {
                Text(snapshot?.measurements.swapUsedBytes.unavailableDetail
                    ?? L10n.text("正在读取交换使用情况", "Reading swap usage"))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            GeekPrecisionLineChart(
                points: points,
                series: [MenuBarTelemetrySeries(
                    id: "swap-used",
                    title: L10n.text("已用", "Used"),
                    channel: .swapUsedBytes,
                    color: metricColors.swap
                )],
                valueRange: 0...display.chartMaximum(for: points),
                unit: .bytes,
                accessibilityLabel: L10n.text("交换内存已用量历史", "Swap memory used history"),
                duration: duration,
                showsLegend: false,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: 2,
                fillOpacity: 0.12,
                showsSamplingDetails: false
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, showsGapLegend: false, isUpdating: isUpdating))
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
    var isNetwork = false

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
                .help(GeekDiskCapacityWording.availableHelp)
                GeekHoverValueRow(
                    title: L10n.text("当前严格空闲", "Current Strict Free"),
                    value: ByteFormat.storageString(snapshot.availableBytes)
                )
                GeekHoverValueRow(
                    title: L10n.text("可回收估算", "Reclaimable Estimate"),
                    value: ByteFormat.storageString(snapshot.reclaimableEstimateBytes)
                )

                GeekHoverValueRow(title: isNetwork ? L10n.text("连接", "Connection") : L10n.text("SSD 状态", "SSD Status"), value: status)
                if showsHealthTimestamp {
                    GeekHoverValueRow(
                        title: L10n.text("健康读取", "Health read"),
                        value: GeekDiskHealthTimestamp.ageText(healthCheckedAt)
                    )
                    .help(GeekDiskHealthTimestamp.detailText(healthCheckedAt))
                    .accessibilityValue(GeekDiskHealthTimestamp.detailText(healthCheckedAt))
                }
                if let temperature {
                    GeekHoverValueRow(title: L10n.text("温度", "Temperature"), value: temperature)
                }
            } else if isNetwork {
                GeekHoverValueRow(title: L10n.text("连接", "Connection"), value: status)
                GeekHoverValueRow(title: L10n.text("容量", "Capacity"), value: "—")
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
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    let breakdown: GeekDiskCapacityBreakdown

    var body: some View {
        ZStack {
            Circle()
                .stroke(GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode), lineWidth: 10)

            GeekDiskCapacityArc(
                start: 0,
                end: breakdown.usedRatio,
                color: metricColors.diskWrite
            )
            GeekDiskCapacityArc(
                start: breakdown.usedRatio,
                end: breakdown.usedRatio + breakdown.reclaimableRatio,
                color: metricColors.diskRead
            )

            VStack(spacing: MiniWindowStyleTokens.rowSpacing) {
                GeekDiskCapacityValue(
                    title: L10n.text("不可回收已用", "Used"),
                    value: ByteFormat.storageString(breakdown.usedBytes),
                    color: metricColors.diskWrite
                )
                GeekDiskCapacityValue(
                    title: L10n.text("可回收估算", "Reclaimable Estimate"),
                    value: ByteFormat.storageString(breakdown.reclaimableBytes),
                    color: metricColors.diskRead
                )
                GeekDiskCapacityValue(
                    title: L10n.text("当前严格空闲", "Current Strict Free"),
                    value: ByteFormat.storageString(breakdown.freeBytes),
                    color: Color.secondary.opacity(0.42)
                )
            }
            .frame(width: 118)
            .clipped()
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
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.6)
            }
            Text(value)
                .font(AdvancedPanelTypography.value)
                .monospacedDigit()
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }
}

struct GeekDiskIOHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    let points: [NativeDiskIOPoint]
    let counters: NativeDiskIOCounters?
    let duration: TimeInterval

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("磁盘 I/O", "Disk I/O"),
            showsRangePicker: true
        ) {
            GeekDiskIOChart(
                points: points,
                accessibilityLabel: L10n.text("磁盘读取与写入趋势", "Disk read and write trend"),
                duration: duration,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: 2
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration))

            if let counters {
                HStack(spacing: 16) {
                    // Disk byte totals use the decimal file style of the
                    // capacities on the same pages (GB/TB, as in Finder).
                    GeekHoverLegendValue(
                        title: L10n.text("累计读取", "Data Read"),
                        value: ByteFormat.storageString(Int64(clamping: counters.readBytes)),
                        color: metricColors.diskRead
                    )
                    GeekHoverLegendValue(
                        title: L10n.text("累计写入", "Data Written"),
                        value: ByteFormat.storageString(Int64(clamping: counters.writtenBytes)),
                        color: metricColors.diskWrite
                    )
                }
            } else {
                GeekHoverValueRow(title: L10n.text("累计计数", "Cumulative Counters"), value: "--")
            }
        }
    }
}

struct GeekDiskThroughputHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    let points: [NativeDiskIOPoint]
    let counters: NativeDiskIOCounters?
    let duration: TimeInterval
    let mode: GeekDiskIOChartMode

    var body: some View {
        GeekHoverDetailCanvas(
            title: mode == .read ? L10n.text("磁盘读取", "Disk Read") : L10n.text("磁盘写入", "Disk Write"),
            showsRangePicker: true
        ) {
            GeekDiskIOChart(
                points: points,
                accessibilityLabel: mode == .read
                    ? L10n.text("磁盘读取柱状图", "Disk read bar chart")
                    : L10n.text("磁盘写入柱状图", "Disk write bar chart"),
                mode: mode,
                duration: duration,
                showsLegend: false,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: 2
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration))

            GeekHoverLegendValue(
                title: mode == .read ? L10n.text("累计读取", "Data Read") : L10n.text("累计写入", "Data Written"),
                value: counters.map {
                    ByteFormat.storageString(Int64(clamping: mode == .read ? $0.readBytes : $0.writtenBytes))
                } ?? "—",
                color: mode == .read ? metricColors.diskRead : metricColors.diskWrite
            )
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
        .font(AdvancedPanelTypography.body)
        .monospacedDigit()
    }

    private func readout(_ title: String, value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value.map { unit.formatted($0) } ?? "—")
        }
    }
}

struct GeekHoverDetailCanvas<Content: View>: View {
    @Environment(\.miniWindowPageProvidesInset) private var pageProvidesInset
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.displayScale) private var displayScale
    let title: String
    let trailing: String?
    let showsRangePicker: Bool
    let stacksRangePicker: Bool
    let availableRanges: [GeekChartRange]
    let spacing: CGFloat
    let content: Content

    @Environment(\.geekChartRangeSelection) private var chartRangeSelection
    @Environment(\.geekPanelHoverCoordinator) private var hoverCoordinator
    @State private var historyInteractionToken: UUID?
    @State private var isChoosingRange = false

    init(
        title: String,
        trailing: String? = nil,
        showsRangePicker: Bool = false,
        stacksRangePicker: Bool = false,
        availableRanges: [GeekChartRange] = GeekChartRange.allCases,
        spacing: CGFloat = MiniWindowStyleTokens.cardSpacing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.showsRangePicker = showsRangePicker
        self.stacksRangePicker = stacksRangePicker
        self.availableRanges = availableRanges
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            header

            if showsRangePicker {
                Spacer(minLength: 0)
            }

            Group {
                if showsRangePicker && isChoosingRange {
                    rangeChoices
                        .frame(minHeight: MiniWindowStyleTokens.historyPlotHeight)
                } else if showsRangePicker {
                    content
                } else {
                    content
                }
            }
            .transaction { $0.animation = nil }
        }
        .frame(minHeight: showsRangePicker ? MiniWindowStyleTokens.historyContentHeight : 0)
        .padding(pageProvidesInset ? 0 : GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: isChoosingRange) {
            if isChoosingRange {
                historyInteractionToken = hoverCoordinator?.beginHistoryInteraction()
            } else {
                hoverCoordinator?.endHistoryInteraction(historyInteractionToken)
                historyInteractionToken = nil
            }
        }
        .onDisappear {
            hoverCoordinator?.endHistoryInteraction(historyInteractionToken)
            historyInteractionToken = nil
        }
    }

    @ViewBuilder
    private var header: some View {
        if showsRangePicker && stacksRangePicker {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(metricColors.sectionHeader)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let trailing {
                        Text(trailing)
                            .font(AdvancedPanelTypography.body)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    rangePicker
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(AdvancedPanelTypography.captionStrong)
                    .foregroundStyle(metricColors.sectionHeader)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsRangePicker {
                    if let trailing {
                        Text(trailing)
                            .font(AdvancedPanelTypography.body)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    rangePicker
                } else if let trailing {
                    Text(trailing)
                        .font(AdvancedPanelTypography.body)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    private var rangePicker: some View {
        Button {
            isChoosingRange.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(chartRangeSelection.range.title)
                    .monospacedDigit()
                Image(systemName: isChoosingRange ? "chevron.up" : "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(AdvancedPanelTypography.captionStrong)
            .foregroundStyle(panelChromePalette?.accent ?? metricColors.sectionHeader)
            .padding(.horizontal, MiniWindowStyleTokens.inlineSpacing)
            .frame(minHeight: MiniWindowStyleTokens.controlRowHeight)
            .contentShape(Rectangle())
        }
        .appButtonChrome(.metric)
        .accessibilityLabel("\(title) \(L10n.text("历史时间范围", "History time range"))")
        .accessibilityValue(chartRangeSelection.range.title)
        .accessibilityHint(L10n.text("在本页选择时间范围", "Choose a range in this panel"))
        .accessibilityIdentifier("geek.history.range.toggle")
    }

    private var rangeChoices: some View {
        GeometryReader { geometry in
            let columnCount = geometry.size.width < 300 ? 3 : 4
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: 4),
                count: columnCount
            )
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(availableRanges) { range in
                    let selected = range == chartRangeSelection.range
                    Button {
                        isChoosingRange = false
                        chartRangeSelection.select(range)
                    } label: {
                        Text(range.title)
                            .font(AdvancedPanelTypography.captionStrong)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .contentShape(RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius))
                    }
                    .appButtonChrome(.metric)
                    .foregroundStyle(selected ? (panelChromePalette?.accent ?? metricColors.sectionHeader) : Color.primary)
                    .background {
                        RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius)
                            .fill(selected ? (panelChromePalette?.selection ?? Color.accentColor.opacity(0.15)) : Color.primary.opacity(0.05))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius)
                            .strokeBorder(
                                selected ? (panelChromePalette?.accent ?? metricColors.sectionHeader) : (panelChromePalette?.border ?? Color.primary.opacity(0.14)),
                                lineWidth: MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
                            )
                    }
                    .accessibilityValue(selected ? L10n.text("已选", "Selected") : "")
                    .accessibilityIdentifier("geek.history.range.option.\(range.rawValue)")
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

struct GeekHoverValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MiniWindowStyleTokens.inlineSpacing) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(AdvancedPanelTypography.body)
        .frame(minHeight: MiniWindowStyleTokens.dataRowHeight)
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
        .font(AdvancedPanelTypography.body)
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
                .font(AdvancedPanelTypography.caption)
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
            Text(text)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
