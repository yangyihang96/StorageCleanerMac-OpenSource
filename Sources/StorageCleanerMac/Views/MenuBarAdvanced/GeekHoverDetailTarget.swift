import AppKit
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
    // D123: iStat's default side (was left).
    static let defaultValue = MenuBarCascadeDirection.right
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

private struct GeekKeyboardHighlightKey: EnvironmentKey {
    static let defaultValue: GeekPanelCoordinator.KeyboardHighlight? = nil
}

private struct GeekKeyboardRowOpenRequestKey: EnvironmentKey {
    static let defaultValue: GeekPanelCoordinator.RowOpenRequest? = nil
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

    /// D123: the arrow keys' highlight (`GeekPanelCoordinator.keyboardHighlight`).
    var geekKeyboardHighlight: GeekPanelCoordinator.KeyboardHighlight? {
        get { self[GeekKeyboardHighlightKey.self] }
        set { self[GeekKeyboardHighlightKey.self] = newValue }
    }

    /// D123: → on a highlighted row (`GeekPanelCoordinator.rowOpenRequest`).
    var geekKeyboardRowOpenRequest: GeekPanelCoordinator.RowOpenRequest? {
        get { self[GeekKeyboardRowOpenRequestKey.self] }
        set { self[GeekKeyboardRowOpenRequestKey.self] = newValue }
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
    @Environment(\.geekKeyboardHighlight) private var keyboardHighlight
    @Environment(\.geekKeyboardRowOpenRequest) private var rowOpenRequest

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
                usesCardActiveBorder && isHighlighted
            )
            .overlay {
                if isHighlighted, !usesCardActiveBorder {
                    // D118: the row highlight is the card highlight, rounded
                    // at 8 pt from a 20 pt row and at 6 pt below (iStat).
                    GeometryReader { proxy in
                        GeekCardHighlight(
                            color: panelChromePalette?.accent ?? GeekVisualTokens.cardBorder(
                                for: colorScheme,
                                visualMode: visualMode,
                                isSelected: true
                            ),
                            cornerRadius: GeekVisualTokens.highlightRadius(rowHeight: proxy.size.height)
                        )
                    }
                    .padding(.horizontal, -selectionOutset)
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
                hoverCoordinator?.registerTertiaryTarget(panelActivityID.uuidString, offset: nil)
                if isTargetHovered {
                    isTargetHovered = false
                    hoverCoordinator?.tertiaryTargetHoverChanged(panelActivityID.uuidString, hovering: false)
                }
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
            .onChange(of: rowOpenRequest) {
                // D123: → on this row while it has the arrow keys' highlight.
                guard rowOpenRequest?.identifier == panelActivityID.uuidString else { return }
                revealImmediately()
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
        // D123: the coordinator tells a gap from another row by the rows
        // under the pointer.
        hoverCoordinator?.tertiaryTargetHoverChanged(panelActivityID.uuidString, hovering: hovering)

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
            // D123: reaching a gap or a row without a page closes this page
            // (iStat Menus 7.30 `mouseMoved:`), held while the pointer heads
            // for it.
            scheduleDismissal()
        }
    }

    private func detailHoverChanged(_ hovering: Bool) {
        guard isDetailHovered != hovering else { return }
        isDetailHovered = hovering
        cancelHoverIntent()
        // D123: leaving the page itself closes nothing, as in iStat Menus 7.30
        // (was a close after the hover delay); the pointer coming back into
        // the module column decides (`GeekPanelCoordinator.pointerMoved`).
    }

    /// D123: a click or VoiceOver press opens the page as hover does,
    /// unpinned (was pinned). It also opens after Escape, and changes nothing
    /// while the page is open.
    private func revealImmediately() {
        cancelHoverIntent()
        guard !isInlinePresented else { return }
        hoverCoordinator?.prepareExplicitTertiaryOpen()
        presentDetail(pinned: false)
    }

    private func selectChartRange(_ range: GeekChartRange) {
        // A native menu moves the pointer away from its tertiary surface while
        // the selection is being committed. Keep the current detail attached
        // before that pointer movement can reveal a different source card.
        if isInlinePresented && !isPinned {
            cancelHoverIntent()
            presentDetail(pinned: true)
        }
        chartRangeSelection.apply(range, to: chartRangeMetric)
    }

    private var resolvedChartRange: GeekChartRange {
        chartRangeSelection.resolvedRange(for: chartRangeMetric)
    }

    private func scheduleDismissal() {
        guard isInlinePresented, !isPinned else { return }
        // D123: a row already under the pointer made the latest change of
        // target; its own open must not be replaced by this close.
        guard hoverCoordinator?.hoveredTertiaryTargets.isEmpty != false else { return }
        cancelHoverIntent()
        guard let hoverCoordinator else {
            dismissDetail()
            return
        }
        hoverIntent = hoverCoordinator.scheduleHoverDismissal(
            condition: {
                // D123: a gap in the module column closes the page too (was
                // only once the pointer had left the whole envelope).
                !isTargetHovered
                    && !isDetailHovered
                    && isInlinePresented
                    && !isPinned
                    && hoverCoordinator.allowsTertiaryGapClose
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
        hoverCoordinator?.registerTertiaryTarget(panelActivityID.uuidString, offset: normalized)
        scheduleSourceOffsetUpdate()
    }

    /// The row highlight: its page is open, or the arrow keys are on it.
    private var isHighlighted: Bool {
        isInlinePresented || keyboardHighlight == .row(panelActivityID.uuidString)
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
    /// D121: a history page without sections below its graph card
    /// (`GeekIStatHistoryGeometry`), 391 × 216.
    static let historySize = GeekIStatHistoryGeometry.pageSize(rowCount: 0)
    static let cpuHistorySize = GeekProcessorActivityHoverDetail.popoverSize
    static let memoryHistorySize = GeekMemoryHistoryHoverDetail.popoverSize
    /// D122: the usage page is a history page with three rows below the
    /// graph card (was 270), four from the load row (was 293).
    static let cpuUsageSize = GeekProcessorUsageHoverDetail.popoverSize(showsLoad: false)
    static let cpuLoadSize = GeekProcessorUsageHoverDetail.popoverSize(showsLoad: true)
    static let compactHistorySize = historySize
    static let diskIOSize = GeekDiskIOHoverDetail.popoverSize
    static let compactSize = CGSize(width: 220, height: 148)
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

    /// D121: the graph card and the upload and download rows below it.
    nonisolated static let popoverSize = GeekIStatHistoryGeometry.pageSize(rowCount: 2)

    var body: some View {
        GeekHoverDetailCanvas(
            // D138: iStat's 'Network.Network' (was 网络活动 / Network Activity).
            title: L10n.text("网络", "Network"),
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
                horizontalInset: MiniWindowStyleTokens.historyChartInset,
                verticalInset: 0,
                mirroredHalfInset: 0,
                easesScale: false,
                // D130: iStat's history buckets.
                bucketing: .history
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, halvesScaleSeparately: true,
                                                   isUpdating: isUpdating))
        } below: {
            GeekIStatRowsCard(rowCount: 2) {
                GeekIStatRow(
                    title: L10n.text("上传", "Upload"),
                    value: uploadValue,
                    dotColor: metricColors.networkUpload
                )
                GeekIStatRow(
                    title: L10n.text("下载", "Download"),
                    value: downloadValue,
                    dotColor: metricColors.networkDownload
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

    /// D121: the graph card alone, as iStat's CPU history.
    nonisolated static let popoverSize = GeekIStatHistoryGeometry.pageSize(rowCount: 0)

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
                horizontalInset: MiniWindowStyleTokens.historyChartInset,
                verticalInset: 0,
                cpuSamplingInterval: samplingInterval,
                // D130: iStat's history buckets.
                bucketing: .history
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

    /// D121: the graph card and the memory, temperature and sample-time
    /// rows below it; the rows stay when a reading is missing ("--"), so
    /// the page keeps one size.
    nonisolated static let popoverSize = GeekIStatHistoryGeometry.pageSize(rowCount: 3)

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
                            // D138: iStat's tooltip row, 'GPU.Processor' (was GPU).
                            title: L10n.text("处理器", "Processor"),
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
                    // D121: the title row names the series; the plot block
                    // keeps its full height (no legend row).
                    showsLegend: false,
                    showsTimelineLabels: false,
                    showsTooltip: true,
                    horizontalInset: MiniWindowStyleTokens.historyChartInset,
                    verticalInset: 0,
                    showsSamplingDetails: false,
                    // D130: iStat's history buckets.
                    bucketing: .history
                )
                .environment(\.panelChartAccentColor, nil)
                .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, valueRange: "0–100%", isUpdating: isUpdating))
            } else {
                // No chart and no axis row: the state fills the whole plot
                // block so the card keeps the available state's height.
                GeekHoverUnavailableState(
                    text: L10n.text("此机型当前未提供可读取的 GPU 使用率", "GPU utilization is not readable on this Mac")
                )
                .frame(height: MiniWindowStyleTokens.historyPlotHeight)
            }
        } below: {
            GeekIStatRowsCard(rowCount: 3) {
                GeekIStatRow(
                    title: GeekGPUVocabulary.memory,
                    value: memoryValue ?? "--",
                    dotColor: memoryTint ?? metricColors.memoryApp
                )
                GeekIStatRow(
                    title: L10n.text("温度", "Temperature"),
                    value: temperatureValue ?? "--",
                    dotColor: temperatureTint ?? metricColors.sensorGraph(chartAccent: panelChartAccentColor)
                )
                GeekIStatRow(
                    title: L10n.text("采样", "Sampled"),
                    value: sampledAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "--",
                    valueColor: .secondary
                )
            }
        }
    }
}

/// D122: opened from the load row, a history page as on the other level
/// three pages: the graph card of the user and system time with the range
/// menu in its title row, the current shares and the load averages below.
/// (iStat's load row opens a load-average history; we keep no load history,
/// so the page shows the CPU time the load summarizes.)
struct GeekProcessorUsageHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    let total: Double?
    let applications: Double?
    let system: Double?
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval
    var samplingInterval: TimeInterval = 1
    /// D119: opened from the load row, the 1, 5 and 15 minute averages.
    var loadAverage: String? = nil

    /// The graph card, the user, system and total rows and the load row.
    nonisolated static func popoverSize(showsLoad: Bool) -> CGSize {
        GeekIStatHistoryGeometry.pageSize(rowCount: showsLoad ? 4 : 3)
    }

    var body: some View {
        GeekHoverDetailCanvas(title: L10n.text("CPU 占用", "CPU Usage"), showsRangePicker: true) {
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
                // D121: the rows below the card name the colors.
                showsLegend: false,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: MiniWindowStyleTokens.historyChartInset,
                verticalInset: 0,
                cpuSamplingInterval: samplingInterval,
                // D130: iStat's history buckets.
                bucketing: .history
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, valueRange: "0–100%"))
        } below: {
            GeekIStatRowsCard(rowCount: loadAverage == nil ? 3 : 4) {
                GeekIStatRow(title: L10n.text("用户", "User"), value: percentText(applications), dotColor: metricColors.cpuUser)
                GeekIStatRow(title: L10n.text("系统", "System"), value: percentText(system), dotColor: metricColors.cpuSystem)
                GeekIStatRow(title: L10n.text("总占用", "Total"), value: percentText(total))
                if let loadAverage {
                    GeekIStatRow(title: L10n.text("负载（1、5、15 分钟）", "Load (1, 5, 15 min)"), value: loadAverage)
                }
            }
        }
    }

    private func percentText(_ value: Double?) -> String {
        value.map { GeekChartUnit.percent.formatted($0, compact: true) } ?? "—"
    }
}

/// D122: iStat's uptime menu (`-[CPUMenu updateUptimeSubmenu]`): one
/// untitled card of three groups, when the Mac started, how long it has
/// been awake since and how long it slept; awake and asleep add up to the
/// uptime row's value.
struct GeekProcessorUptimeHoverDetail: View {
    @Environment(\.miniWindowPageProvidesInset) private var pageProvidesInset
    let poweredOnAt: String
    let awake: String
    let asleep: String

    /// D122: the card's three groups (was 106 tall). D137: as wide as the
    /// card's section + 20 (`-[CPUMenu updateUptimeSubmenu]`), the section
    /// its widest title or value + 16, from 150 (`setMinimumWidth: 150`) to
    /// 350; the titles count upper case, as the card draws them and iStat
    /// measures them (was 220 for any text).
    var popoverSize: CGSize {
        let texts = groups.flatMap { [$0.title.uppercased(), $0.value] }
        let section = GeekIStatContentWidth.section(rows: texts.map(GeekIStatContentWidth.text),
                                                    minimum: GeekIStatTextSectionGeometry.minimumWidth)
        return GeekIStatDetailGeometry.pageSize(
            cards: [GeekIStatDetailGeometry.stackedHeight(groupCount: groups.count)],
            width: GeekIStatContentWidth.page(sections: [section])
        )
    }

    /// Internal for the wording test (D138).
    var groups: [GeekIStatStackedGroupsCard.Entry] {
        [
            // D138: iStat's 'CPU.Powered On', 'CPU.Awake' and 'CPU.Sleeping'
            // (were 开机于 / Started, 唤醒时长 / Awake Time, 睡眠时长 / Sleep Time).
            .init(title: L10n.text("开机", "Powered On"), value: poweredOnAt),
            .init(
                title: L10n.text("活跃", "Awake"),
                value: awake,
                help: L10n.text("自开机以来 Mac 处于唤醒状态的时间", "Time this Mac has been awake since it started")
            ),
            .init(
                title: L10n.text("正在睡眠", "Sleeping"),
                value: asleep,
                help: L10n.text("自开机以来 Mac 处于睡眠状态的时间", "Time this Mac has slept since it started")
            ),
        ]
    }

    var body: some View {
        GeekIStatStackedGroupsCard(groups: groups)
        .padding(pageProvidesInset ? 0 : GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("电脑开启时间", "Uptime"))
    }
}

/// D122: the uptime page's durations.
enum GeekUptimeFormat {
    /// "5 天 3 小时", "3 小时 20 分", "12 分钟"; "—" before a reading.
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let minutes = Int(seconds) / 60
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let remainingMinutes = minutes % 60
        if days > 0 {
            return L10n.text("\(days) 天 \(hours) 小时", "\(days)d \(hours)h")
        }
        if hours > 0 {
            return L10n.text("\(hours) 小时 \(remainingMinutes) 分", "\(hours)h \(remainingMinutes)m")
        }
        return L10n.text("\(remainingMinutes) 分钟", "\(remainingMinutes)m")
    }

    /// The time asleep: the time since the boot less the time awake; unknown
    /// without the boot time (the uptime then falls back to the awake time).
    static func asleepSeconds(bootAt: Date?, sinceBootSeconds: TimeInterval?, awakeSeconds: TimeInterval?) -> TimeInterval? {
        guard bootAt != nil, let sinceBootSeconds, let awakeSeconds,
              sinceBootSeconds.isFinite, awakeSeconds.isFinite else { return nil }
        return max(0, sinceBootSeconds - awakeSeconds)
    }

    /// The Mac's awake time since it started (`systemUptime` stops while
    /// asleep); the demo fixture's on demo data. D147: the fixture is only
    /// compiled with DEBUG or STORAGE_CLEANER_BETA; the release build always
    /// reads the system's (it failed to compile).
    static func awakeSeconds(usesDemoData: Bool) -> TimeInterval {
#if DEBUG || STORAGE_CLEANER_BETA
        if usesDemoData { return MiniWindowDemoData.systemAwakeSeconds }
#endif
        return ProcessInfo.processInfo.systemUptime
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

    /// D121: the graph card and the current status row below it.
    nonisolated static let popoverSize = GeekIStatHistoryGeometry.pageSize(rowCount: 1)

    var body: some View {
        GeekHoverDetailCanvas(
            // D138: iStat's pressure mode, 'Memory.Pressure', for the title
            // and the tooltip row (were 内存压力 / Memory Pressure and 压力评估).
            title: L10n.text("压力", "Pressure"),
            trailing: snapshot?.pressureEstimatePercent.map { "\($0)%" } ?? pressure,
            showsRangePicker: true
        ) {
            GeekPrecisionLineChart(
                points: points,
                series: [
                    MenuBarTelemetrySeries(
                        id: "memory-pressure",
                        title: L10n.text("压力", "Pressure"),
                        channel: .memoryPressure,
                        // The pressure ring's color: the current level
                        // through the same color exit (the tooltip's dot).
                        color: metricColors.memoryPressure(for: snapshot?.reportablePressureLevel)
                    )
                ],
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text("内存压力评估变化", "Memory pressure history"),
                style: .stackedBars,
                duration: duration,
                // D121: the title row names the series; the plot block
                // keeps its full height (no legend row).
                showsLegend: false,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: MiniWindowStyleTokens.historyChartInset,
                verticalInset: 0,
                showsSamplingDetails: false,
                // Each bar has the color of its own sample's level, through
                // the same exit; an earlier normal period stays normal while
                // the ring is elevated.
                pressureLevelColor: { metricColors.memoryPressure(for: $0) },
                // D130: iStat's history buckets.
                bucketing: .history,
                // D133: no bar for a zero bucket, as iStat's pressure history.
                drawsZero: false
            )
            .environment(\.panelChartAccentColor, nil)
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, valueRange: "0–100%", isUpdating: isUpdating))
        } below: {
            GeekIStatRowsCard(rowCount: 1) {
                GeekIStatRow(
                    title: L10n.text("当前状态", "Current Status"),
                    value: pressure
                )
            }
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
        // D128: iStat's memory format, as its swap section.
        let used = IStatNumberFormat.memory(usedBytes)
        guard let totalBytes else {
            return L10n.text("\(used) · 按需分配", "\(used) · On Demand")
        }
        return "\(used) / \(IStatNumberFormat.memory(totalBytes))"
    }

    /// The byte scale the swap history drew before D133 (it draws the used
    /// share now); kept with its test.
    func chartMaximum(for points: [MenuBarTelemetryPoint]) -> Double {
        let observedMaximum = points.lazy.compactMap(\.swapUsedBytes).max() ?? 0
        return Double(max(1, max(max(totalBytes ?? 0, usedBytes ?? 0), observedMaximum)))
    }
}

struct GeekSwapHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode
    let snapshot: MemorySnapshot?
    let points: [MenuBarTelemetryPoint]
    let duration: TimeInterval

    private var display: GeekSwapDetailData { GeekSwapDetailData(snapshot: snapshot) }

    /// The history still draws the previous window (`MenuBarDisplayedHistory.isUpdating`).
    var isUpdating = false

    /// D121: the graph card and the 40 pt used-share bar section below it
    /// (the swap section of iStat's memory menu).
    nonisolated static let popoverSize = CGSize(
        width: MiniWindowStyleTokens.historyWidth,
        height: GeekIStatHistoryGeometry.pageHeight(belowGraph: [GeekIStatSectionGeometry.barSectionHeight])
    )

    var body: some View {
        GeekHoverDetailCanvas(
            // D138: iStat's 'Memory.Swap' for the title and the tooltip row
            // (were 交换内存 / Swap Memory and 已用 / Used).
            title: L10n.text("已使用的交换", "Swap"),
            trailing: display.summary,
            showsRangePicker: true
        ) {
            // D133: iStat's swap history (`BBRMenuSwapHistoryGraphSection`):
            // bars of the swap files' used share, 0–100 %, none for a zero
            // bucket (was the used bytes as a line on an automatic scale).
            GeekPrecisionLineChart(
                points: points,
                series: [MenuBarTelemetrySeries(
                    id: "swap-used",
                    title: L10n.text("已使用的交换", "Swap"),
                    channel: .swapUsedPercent,
                    color: metricColors.swap
                )],
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text("交换内存已用比例历史", "Swap memory used share history"),
                style: .stackedBars,
                duration: duration,
                showsLegend: false,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: MiniWindowStyleTokens.historyChartInset,
                verticalInset: 0,
                showsSamplingDetails: false,
                // D130: iStat's history buckets.
                bucketing: .history,
                drawsZero: false
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, valueRange: "0–100%", showsGapLegend: false,
                                                   isUpdating: isUpdating))
        } below: {
            usedShareSection
        }
    }

    /// The used share of the swap size; without a fixed size (on demand) or
    /// before the first reading the bar stays empty and the row says why.
    private var usedShareSection: some View {
        GeekIStatCard(height: GeekIStatSectionGeometry.barSectionHeight) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                Text(L10n.text("已用比例", "Used Share")).geekIStatLabelText()
                Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
                Text(usedShareText).geekIStatValueText(display.fraction == nil ? .secondary : .primary)
            }
            .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)
            GeekIStatBar(
                progress: display.fraction,
                tint: metricColors.swap,
                track: GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode, palette: panelChromePalette)
            )
            .geekIStatLayer(top: GeekIStatCardGeometry.batteryBarTop, height: GeekIStatCardGeometry.batteryBarHeight)
        }
        .help(display.usedBytes == nil
            ? (snapshot?.measurements.swapUsedBytes.unavailableDetail ?? L10n.text("正在读取交换使用情况", "Reading swap usage"))
            : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("交换内存已用比例", "Swap memory used fraction"))
        .accessibilityValue(usedShareText)
    }

    private var usedShareText: String {
        if let fraction = display.fraction {
            return "\(Int((fraction * 100).rounded()))%"
        }
        return display.usedBytes == nil ? "—" : L10n.text("按需分配", "On Demand")
    }
}

/// D122: iStat's disk space menu (`BBRDisksMenuSpaceBarSection`, 220
/// wide): a 200 pt card with the capacity ring and its legend inside, then
/// a card of our readings (system available, health, temperature). The
/// space card has no title, as iStat's: the volume card it opens from stays
/// selected; VoiceOver reads the volume's name.
struct GeekDiskVolumeHoverDetail: View {
    @Environment(\.miniWindowPageProvidesInset) private var pageProvidesInset
    let snapshot: StorageCapacitySnapshot?
    let volumeName: String
    let status: String
    let temperature: String?
    var healthCheckedAt: Date? = nil
    var showsHealthTimestamp = true
    var isNetwork = false
    /// D136: the space section's Finder and hide buttons.
    var actions: GeekDiskVolumeActions? = nil

    /// The space card and `rowCount` reading rows below it.
    nonisolated static func popoverSize(rowCount: Int) -> CGSize {
        GeekIStatDetailGeometry.pageSize(cards: [
            GeekIStatDetailGeometry.spaceCardHeight,
            GeekIStatSectionGeometry.rowsHeight(rowCount, titled: false),
        ])
    }

    /// A network volume before its capacity is read: its two rows.
    nonisolated static let networkWithoutCapacitySize = GeekIStatDetailGeometry.pageSize(
        cards: [GeekIStatSectionGeometry.rowsHeight(2, titled: false)]
    )

    private var displayName: String {
        volumeName.isEmpty ? L10n.text("系统磁盘", "System Disk") : volumeName
    }

    private var readingRowCount: Int {
        2 + (showsHealthTimestamp ? 1 : 0) + (temperature == nil ? 0 : 1)
    }

    /// D122: the page for these readings: the space card and its rows, a
    /// network volume's two rows before its capacity is read, or the space
    /// card while it is read (was the fixed 220 × 339 `volumeSize`).
    var popoverSize: CGSize {
        if snapshot != nil {
            return Self.popoverSize(rowCount: readingRowCount)
        }
        return isNetwork
            ? Self.networkWithoutCapacitySize
            : GeekIStatDetailGeometry.pageSize(cards: [GeekIStatDetailGeometry.spaceCardHeight])
    }

    var body: some View {
        VStack(spacing: MiniWindowStyleTokens.cardSpacing) {
            if let snapshot {
                GeekDiskSpaceCard(breakdown: GeekDiskCapacityBreakdown(snapshot: snapshot))
                    .overlay(alignment: .top) { spaceActionButtons }
                GeekIStatRowsCard(rowCount: readingRowCount) {
                    GeekIStatRow(
                        title: L10n.text("系统可用", "System Available"),
                        value: IStatNumberFormat.space(snapshot.userAvailableBytes)
                    )
                    .help(GeekDiskCapacityWording.availableHelp)
                    GeekIStatRow(
                        title: isNetwork ? L10n.text("连接", "Connection") : L10n.text("SSD 状态", "SSD Status"),
                        value: status
                    )
                    if showsHealthTimestamp {
                        GeekIStatRow(
                            title: L10n.text("健康读取", "Health read"),
                            value: GeekDiskHealthTimestamp.ageText(healthCheckedAt)
                        )
                        .help(GeekDiskHealthTimestamp.detailText(healthCheckedAt))
                        .accessibilityValue(GeekDiskHealthTimestamp.detailText(healthCheckedAt))
                    }
                    if let temperature {
                        GeekIStatRow(title: L10n.text("温度", "Temperature"), value: temperature)
                    }
                }
            } else if isNetwork {
                GeekIStatRowsCard(rowCount: 2) {
                    GeekIStatRow(title: L10n.text("连接", "Connection"), value: status)
                    GeekIStatRow(title: L10n.text("容量", "Capacity"), value: "—")
                }
            } else {
                // The space card keeps its place while the capacity is read.
                GeekIStatCard(height: GeekIStatDetailGeometry.spaceCardHeight) {
                    GeekHoverUnavailableState(text: L10n.text("正在读取磁盘容量", "Reading disk capacity"))
                }
                .overlay(alignment: .top) { spaceActionButtons }
            }
        }
        .padding(pageProvidesInset ? 0 : GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(displayName)
    }

    @ViewBuilder private var spaceActionButtons: some View {
        if let actions {
            GeekDiskSpaceActionButtons(volumeName: displayName, actions: actions)
        }
    }
}

/// D136: what the disk space section's two buttons do (iStat's Finder icon
/// opens the volume; its visibility icon hides the volume from the menu).
struct GeekDiskVolumeActions: Sendable {
    let showInFinder: @MainActor () -> Void
    let hide: @MainActor () -> Void

    /// Draws the buttons without acting (demo data, previews).
    static let inert = GeekDiskVolumeActions(showInFinder: {}, hide: {})
}

/// D136: iStat's space section draws the Finder icon at (8, 8) and its
/// visibility icon, tinted with the value color, at (W − 24, 8), 16 pt
/// each; a click inside the 32 pt square at either top corner runs the
/// action 0.1 s later (`-[BBRDisksMenuSpaceBarSection mouseDown:]`). The
/// visibility icon is the system's eye symbol, not iStat's image.
struct GeekDiskSpaceActionButtons: View {
    let volumeName: String
    let actions: GeekDiskVolumeActions

    static let finderPath = "/System/Library/CoreServices/Finder.app"
    static let hideSymbol = "eye.slash"
    private static let finderIcon = NSWorkspace.shared.icon(forFile: finderPath)

    var body: some View {
        HStack(spacing: 0) {
            corner(
                title: L10n.text("在 Finder 中打开“\(volumeName)”", "Open “\(volumeName)” in Finder"),
                action: actions.showInFinder
            ) {
                Image(nsImage: Self.finderIcon)
                    .resizable()
                    .interpolation(.high)
            }
            Spacer(minLength: 0)
            corner(
                title: L10n.text("在小窗中隐藏“\(volumeName)”", "Hide “\(volumeName)” in the Panel"),
                action: actions.hide
            ) {
                Image(systemName: Self.hideSymbol)
                    .resizable()
                    .scaledToFit()
                    .modifier(GeekIStatTextColor(role: .value))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func corner<Icon: View>(
        title: String,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button {
            DispatchQueue.main.asyncAfter(deadline: .now() + MiniWindowHiddenItems.actionDelay) {
                MainActor.assumeIsolated { action() }
            }
        } label: {
            icon()
                .frame(width: GeekIStatDetailGeometry.spaceActionIconSize,
                       height: GeekIStatDetailGeometry.spaceActionIconSize)
                .frame(width: GeekIStatDetailGeometry.spaceActionHitSize,
                       height: GeekIStatDetailGeometry.spaceActionHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .help(title)
        .accessibilityLabel(title)
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

/// D122: iStat's disk space section on its 200 pt card: the 10 pt ring
/// centered at (W/2, W/2) with radius W/2 − 20 (the track, the used space
/// from 12 o'clock clockwise, then the reclaimable estimate), and the
/// legend centered inside it: a label row (7 pt dot) above its value row,
/// 37 pt apart; the reclaimable entry only when there is an estimate.
private struct GeekDiskSpaceCard: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.displayScale) private var displayScale
    let breakdown: GeekDiskCapacityBreakdown

    private struct Entry: Identifiable {
        let title: String
        let value: String
        let color: Color
        var hasOutline = false
        var id: String { title }
    }

    private var track: Color {
        GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode, palette: panelChromePalette)
    }

    private var entries: [Entry] {
        var entries = [Entry(
            title: L10n.text("不可回收已用", "Used"),
            value: IStatNumberFormat.space(breakdown.usedBytes),
            color: metricColors.diskWrite
        )]
        if breakdown.reclaimableBytes > 0 {
            entries.append(Entry(
                title: L10n.text("可回收估算", "Reclaimable Estimate"),
                value: IStatNumberFormat.space(breakdown.reclaimableBytes),
                color: metricColors.diskRead
            ))
        }
        entries.append(Entry(
            title: L10n.text("当前严格空闲", "Current Strict Free"),
            value: IStatNumberFormat.space(breakdown.freeBytes),
            color: track,
            hasOutline: true
        ))
        return entries
    }

    var body: some View {
        GeekIStatCard(height: GeekIStatDetailGeometry.spaceCardHeight) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let radius = GeekIStatDetailGeometry.spaceRingRadius(cardWidth: width)
                let entries = entries
                ZStack(alignment: .topLeading) {
                    Group {
                        GeekDiskCapacityArc(start: 0, end: 1, color: track)
                        GeekDiskCapacityArc(start: 0, end: breakdown.usedRatio, color: metricColors.diskWrite)
                        GeekDiskCapacityArc(
                            start: breakdown.usedRatio,
                            end: breakdown.usedRatio + breakdown.reclaimableRatio,
                            color: metricColors.diskRead
                        )
                    }
                    .frame(width: 2 * radius, height: 2 * radius)
                    .position(x: width / 2, y: width / 2)

                    VStack(spacing: GeekIStatDetailGeometry.spaceLegendPitch - GeekIStatDetailGeometry.stackedGroupHeight) {
                        ForEach(entries) { entry in
                            legendEntry(entry, valueWidth: width - 2 * GeekIStatDetailGeometry.spaceLegendValueInset)
                        }
                    }
                    .frame(width: width)
                    .padding(.top, GeekIStatDetailGeometry.spaceLegendTop(entryCount: entries.count))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("磁盘容量构成", "Disk capacity composition"))
        .accessibilityHint(L10n.text(
            "系统可用 = 当前严格空闲 + 可回收估算；这是容量估算，不等同于已扫描的安全清理结果。",
            "System available = current strict free + reclaimable estimate; this capacity estimate is not a scanned safe-cleanup result."
        ))
        .transaction { $0.animation = nil }
    }

    private func legendEntry(_ entry: Entry, valueWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: GeekIStatCardGeometry.legendDotSpacing) {
                Circle()
                    .fill(entry.color)
                    .overlay {
                        if entry.hasOutline {
                            Circle().strokeBorder(
                                .tertiary,
                                lineWidth: MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
                            )
                        }
                    }
                    .frame(width: GeekIStatDetailGeometry.spaceLegendDotSize, height: GeekIStatDetailGeometry.spaceLegendDotSize)
                    .accessibilityHidden(true)
                Text(entry.title)
                    .geekIStatLabelText()
                    .allowsTightening(true)
                    .minimumScaleFactor(0.8)
            }
            .frame(height: GeekIStatSectionGeometry.rowHeight)
            Text(entry.value)
                .geekIStatValueText()
                .allowsTightening(true)
                .minimumScaleFactor(0.8)
                .frame(width: max(0, valueWidth), height: GeekIStatSectionGeometry.rowHeight)
        }
        .accessibilityElement(children: .combine)
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
            .stroke(color, style: StrokeStyle(lineWidth: GeekIStatDetailGeometry.spaceRingLineWidth, lineCap: .butt))
            .rotationEffect(.degrees(-90))
    }
}

struct GeekDiskIOHoverDetail: View {
    @Environment(\.panelMetricColors) private var metricColors
    let points: [NativeDiskIOPoint]
    let counters: NativeDiskIOCounters?
    let duration: TimeInterval

    /// D121: the graph card and the two cumulative counters below it; the
    /// rows show "—" until the counters are read, so the page keeps its size.
    nonisolated static let popoverSize = GeekIStatHistoryGeometry.pageSize(rowCount: 2)

    var body: some View {
        GeekHoverDetailCanvas(
            // D138: iStat's 'Disks.Disk Activity' (was 磁盘 I/O).
            title: L10n.text("硬盘活动", "Disk Activity"),
            showsRangePicker: true
        ) {
            GeekDiskIOChart(
                points: points,
                accessibilityLabel: L10n.text("磁盘读取与写入趋势", "Disk read and write trend"),
                duration: duration,
                // D121: the read and write rows below the card name the
                // colors; the plot block keeps its full height.
                showsLegend: false,
                showsTimelineLabels: false,
                showsTooltip: true,
                horizontalInset: MiniWindowStyleTokens.historyChartInset,
                verticalInset: 0,
                mirroredHalfInset: 0,
                easesScale: false,
                // D130: iStat's history buckets.
                bucketing: .history
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration, halvesScaleSeparately: true))
        } below: {
            // D128: iStat's transferred totals (`BBRMenuDiskActivityTotals`),
            // disk space with two GB decimals (was the decimal file style).
            GeekIStatRowsCard(rowCount: 2) {
                GeekIStatRow(
                    title: L10n.text("累计读取", "Data Read"),
                    value: counters.map { IStatNumberFormat.space($0.readBytes, style: .totals) } ?? "—",
                    dotColor: metricColors.diskRead
                )
                GeekIStatRow(
                    title: L10n.text("累计写入", "Data Written"),
                    value: counters.map { IStatNumberFormat.space($0.writtenBytes, style: .totals) } ?? "—",
                    dotColor: metricColors.diskWrite
                )
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

    /// D121: the graph card and the direction's cumulative counter below it.
    nonisolated static let popoverSize = GeekIStatHistoryGeometry.pageSize(rowCount: 1)

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
                horizontalInset: MiniWindowStyleTokens.historyChartInset,
                verticalInset: 0,
                easesScale: false,
                // D130: iStat's history buckets.
                bucketing: .history
            )
            .geekHistoryAxis(GeekHistoryAxisFooter(duration: duration))
        } below: {
            GeekIStatRowsCard(rowCount: 1) {
                GeekIStatRow(
                    title: mode == .read ? L10n.text("累计读取", "Data Read") : L10n.text("累计写入", "Data Written"),
                    value: counters.map {
                        IStatNumberFormat.space(mode == .read ? $0.readBytes : $0.writtenBytes, style: .totals)
                    } ?? "—",
                    dotColor: mode == .read ? metricColors.diskRead : metricColors.diskWrite
                )
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

struct GeekHoverDetailCanvas<Content: View, Below: View>: View {
    @Environment(\.miniWindowPageProvidesInset) private var pageProvidesInset
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.displayScale) private var displayScale
    let title: String
    let trailing: String?
    let showsRangePicker: Bool
    /// D121: a history page whose history is unavailable keeps the graph
    /// card (the state in the plot block) without the range menu.
    let historyCard: Bool
    let availableRanges: [GeekChartRange]
    let spacing: CGFloat
    /// D132: the graph card's height and where its plot block starts (the
    /// battery history's 180 and 30; the other histories' 200 and 25). The
    /// plot block ends 8 pt above the card's bottom.
    let cardHeight: CGFloat
    let plotTop: CGFloat
    let content: Content
    /// D121: the sections below a history's graph card (current values,
    /// totals, hardware ranges), 7 pt apart.
    let below: Below

    @Environment(\.geekChartRangeSelection) private var chartRangeSelection
    @Environment(\.geekPanelHoverCoordinator) private var hoverCoordinator
    @State private var historyInteractionToken: UUID?
    @State private var isChoosingRange = false

    init(
        title: String,
        trailing: String? = nil,
        showsRangePicker: Bool = false,
        historyCard: Bool = false,
        availableRanges: [GeekChartRange] = GeekChartRange.allCases,
        spacing: CGFloat = MiniWindowStyleTokens.cardSpacing,
        cardHeight: CGFloat = MiniWindowStyleTokens.historyCardHeight,
        plotTop: CGFloat = MiniWindowStyleTokens.historyPlotTop,
        @ViewBuilder content: () -> Content,
        @ViewBuilder below: () -> Below
    ) {
        self.title = title
        self.trailing = trailing
        self.showsRangePicker = showsRangePicker
        self.historyCard = historyCard
        self.availableRanges = availableRanges
        self.spacing = spacing
        self.cardHeight = cardHeight
        self.plotTop = plotTop
        self.content = content()
        self.below = below()
    }

    var body: some View {
        Group {
            if showsRangePicker || historyCard {
                historyBody
            } else {
                VStack(alignment: .leading, spacing: spacing) {
                    header
                    content
                        .transaction { $0.animation = nil }
                }
            }
        }
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

    /// D121: iStat's history submenu: one 375 × 200 graph card, its title
    /// row at (8, 5) with the range menu on the right and the plot block
    /// from 25 to 8 pt above the bottom; the range choices take the plot
    /// block's place. Our sections follow below the card. D132: the
    /// battery page's card is iStat's 180 pt one, its plot from 30 pt
    /// (`cardHeight`, `plotTop`).
    private var historyBody: some View {
        VStack(alignment: .leading, spacing: MiniWindowStyleTokens.cardSpacing) {
            GeekIStatCard(height: cardHeight) {
                historyHeader
                    .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)
                Group {
                    if isChoosingRange {
                        rangeChoices
                            .padding(.horizontal, GeekIStatCardGeometry.inset)
                    } else {
                        content
                    }
                }
                .transaction { $0.animation = nil }
                .geekIStatLayer(
                    top: plotTop,
                    height: max(0, cardHeight - plotTop - MiniWindowStyleTokens.contentInset),
                    leading: 0,
                    trailing: 0,
                    alignment: .top
                )
            }
            below
        }
    }

    /// The card title (12 pt, uppercase, the section color) truncates first;
    /// the current value and the range menu keep their width.
    private var historyHeader: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            Text(title)
                .font(AdvancedPanelTypography.header)
                .textCase(.uppercase)
                .foregroundStyle(metricColors.sectionHeader)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
            if let trailing {
                Text(trailing)
                    .geekIStatValueText()
                    .fixedSize()
            }
            if showsRangePicker {
                rangePicker
                    .fixedSize()
            }
        }
        .frame(height: GeekIStatCardGeometry.titleHeight)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(AdvancedPanelTypography.captionStrong)
                .foregroundStyle(metricColors.sectionHeader)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(AdvancedPanelTypography.body)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    /// D121: the range menu sits in the card's 15 pt title row, as iStat's
    /// interval pop-up does; the hit area reaches 4 pt above and below it.
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
            .font(.system(size: GeekIStatCardGeometry.textFontSize))
            .foregroundStyle(panelChromePalette?.accent ?? metricColors.sectionHeader)
            .frame(height: GeekIStatCardGeometry.titleHeight)
            .contentShape(Rectangle().inset(by: -4))
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

extension GeekHoverDetailCanvas where Below == EmptyView {
    init(
        title: String,
        trailing: String? = nil,
        showsRangePicker: Bool = false,
        historyCard: Bool = false,
        availableRanges: [GeekChartRange] = GeekChartRange.allCases,
        spacing: CGFloat = MiniWindowStyleTokens.cardSpacing,
        cardHeight: CGFloat = MiniWindowStyleTokens.historyCardHeight,
        plotTop: CGFloat = MiniWindowStyleTokens.historyPlotTop,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, trailing: trailing, showsRangePicker: showsRangePicker, historyCard: historyCard,
                  availableRanges: availableRanges, spacing: spacing, cardHeight: cardHeight, plotTop: plotTop,
                  content: content) { EmptyView() }
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
