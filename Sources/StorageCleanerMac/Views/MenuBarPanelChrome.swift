import AppKit
import SwiftUI

enum PanelTimestampFormat {
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let chineseMonthDayAndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M月d日 HH:mm:ss"
        return formatter
    }()

    private static let englishMonthDayAndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MMM d HH:mm:ss"
        return formatter
    }()

    private static let chineseShortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.timeZone = .autoupdatingCurrent
        formatter.timeStyle = .short
        return formatter
    }()

    private static let englishShortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.timeStyle = .short
        return formatter
    }()

    static func display(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    static func detail(_ date: Date) -> String {
        detailFormatter.string(from: date)
    }

    static func monthDayAndTime(_ date: Date) -> String {
        let formatter = L10n.usesChinese
            ? chineseMonthDayAndTimeFormatter
            : englishMonthDayAndTimeFormatter
        return formatter.string(from: date)
    }

    static func shortTime(_ date: Date) -> String {
        let formatter = L10n.usesChinese
            ? chineseShortTimeFormatter
            : englishShortTimeFormatter
        return formatter.string(from: date)
    }
}

enum PanelLayoutMetrics {
    static let navigationWidth: CGFloat = 44
    static let primaryChartHeight: CGFloat = GeekPanelLayout.primaryChartHeight
}

enum GeekAttachedPanelRegion: Hashable {
    case overview
    case detail
    case tertiary
}

struct GeekPanelHoverActivityState: Equatable {
    private(set) var activeShellRegions: Set<GeekAttachedPanelRegion> = []
    private(set) var activeDetailTargets: Set<UUID> = []

    var isShellHovered: Bool { !activeShellRegions.isEmpty }

    var keepsPanelExpanded: Bool {
        isShellHovered || !activeDetailTargets.isEmpty
    }

    mutating func setShellHovered(_ hovered: Bool) {
        setShellRegion(.overview, hovered: hovered)
    }

    mutating func setShellRegion(_ region: GeekAttachedPanelRegion, hovered: Bool) {
        if hovered {
            activeShellRegions.insert(region)
        } else {
            activeShellRegions.remove(region)
        }
    }

    mutating func setDetailTarget(_ id: UUID, active: Bool) {
        if active {
            activeDetailTargets.insert(id)
        } else {
            activeDetailTargets.remove(id)
        }
    }

    mutating func reset() {
        activeShellRegions.removeAll()
        activeDetailTargets.removeAll()
    }
}

struct PanelShell<Header: View, Navigation: View, Content: View>: View {
    let density: PanelDensity
    var preferredSize: CGSize? = nil
    var showsHeader = true
    let showsNavigation: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let navigation: Navigation
    @ViewBuilder let content: Content

    var body: some View {
        let size = preferredSize ?? density.idealSize
        VStack(spacing: 0) {
            if showsHeader {
                header
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }

            HStack(spacing: 0) {
                if showsNavigation {
                    PanelNavigation { navigation }
                    Divider()
                }
                PanelContent { content }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        .metricPanelShell()
    }
}

/// Attached levels touch without a layout gap, but remain independent rounded
/// surfaces so every menu level keeps the same silhouette.
enum GeekAttachedPanelChromeGeometry {
    static func cornerRadii(
        for _: CGRect,
        neighbors _: [CGRect],
        radius: CGFloat
    ) -> RectangleCornerRadii {
        return RectangleCornerRadii(
            topLeading: radius,
            bottomLeading: radius,
            bottomTrailing: radius,
            topTrailing: radius
        )
    }

    /// Each attached shell owns its complete one-pixel border. This preserves
    /// the rounded outline when neighboring levels have different heights.
    static func exposedBorderEdges(
        for _: CGRect,
        neighbors _: [CGRect]
    ) -> MiniWindowBorderEdges {
        .all
    }
}

struct GeekAttachedPanelShell<Detail: View, Overview: View, Tertiary: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let section: PanelSection
    let density: PanelDensity
    let overviewSize: CGSize
    let direction: MenuBarCascadeDirection
    let presentationMode: MenuBarSecondaryPresentationMode
    let tertiaryPresentationMode: MenuBarTertiaryPresentationMode
    let cascadeLayout: MenuBarCascadeLayout?
    let detailPreferredSize: CGSize
    let showsTertiary: Bool
    let tertiaryPreferredSize: CGSize
    let tertiarySourceOffset: CGFloat?
    let onHoverChange: (GeekAttachedPanelRegion, Bool) -> Void
    @ViewBuilder let detail: Detail
    @ViewBuilder let overview: Overview
    @ViewBuilder let tertiary: Tertiary

#if DEBUG
    @State private var debugActiveRegions: Set<GeekAttachedPanelRegion> = []
    @State private var debugPointerLocation: CGPoint?
#endif

    var body: some View {
        let detailSize = GeekPanelPresentationMetrics.normalizedDetailSize(
            detailPreferredSize,
            for: section,
            density: density
        )
        let tertiarySize = GeekPanelPresentationMetrics.normalizedTertiarySize(
            tertiaryPreferredSize
        )
        Group {
            if presentationMode == .unavailable {
                MetricPanelShell {
                    overview
                        .frame(
                            width: overviewSize.width,
                            height: overviewSize.height,
                            alignment: .top
                        )
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        onHoverChange(.overview, true)
                        recordDebugHover(.overview, hovering: true, location: location)
                    case .ended:
                        onHoverChange(.overview, false)
                        recordDebugHover(.overview, hovering: false)
                    }
                }
#if DEBUG
                .overlay {
                    if MiniWindowDebugSupport.isEnabled {
                        MiniWindowDebugOverlay(
                            frames: [CGRect(
                                origin: .zero,
                                size: overviewSize
                            )],
                            activeRegions: debugActiveRegions,
                            localPointerLocation: debugPointerLocation
                        )
                    }
                }
#endif
            } else {
                let showsTertiaryColumn = showsTertiary
                    && tertiaryPresentationMode == .column
                let gap = MiniWindowStyleTokens.cascadeGap
                let expandedSize = GeekPanelPresentationMetrics.expandedSize(
                    for: section,
                    density: density,
                    includesTertiaryColumn: showsTertiaryColumn,
                    detailSize: detailSize,
                    tertiarySize: tertiarySize,
                    overviewSize: overviewSize
                )
                let defaultOverviewFrame = CGRect(
                    x: direction == .left
                        ? detailSize.width
                            + gap
                            + (showsTertiaryColumn ? tertiarySize.width + gap : 0)
                        : 0,
                    y: expandedSize.height - overviewSize.height,
                    width: overviewSize.width,
                    height: overviewSize.height
                )
                let defaultDetailFrame = CGRect(
                    x: direction == .left
                        ? (showsTertiaryColumn ? tertiarySize.width + gap : 0)
                        : overviewSize.width + gap,
                    y: expandedSize.height - detailSize.height,
                    width: detailSize.width,
                    height: detailSize.height
                )
                let defaultTertiaryFrame = showsTertiaryColumn
                    ? CGRect(
                        x: direction == .left
                            ? 0
                            : overviewSize.width + gap + detailSize.width + gap,
                        y: expandedSize.height - tertiarySize.height,
                        width: tertiarySize.width,
                        height: tertiarySize.height
                    )
                    : nil
                let usableCascadeLayout: MenuBarCascadeLayout? = {
                    guard let cascadeLayout,
                          cascadeLayout.childFrames.count == (showsTertiaryColumn ? 2 : 1) else {
                        return nil
                    }
                    return cascadeLayout
                }()
                let overviewFrame = usableCascadeLayout.map {
                    $0.localFrame(for: $0.parentFrame)
                } ?? defaultOverviewFrame
                let detailFrame = usableCascadeLayout.map {
                    $0.localFrame(for: $0.childFrames[0])
                } ?? defaultDetailFrame
                let tertiaryFrame = showsTertiaryColumn
                    ? usableCascadeLayout.map { $0.localFrame(for: $0.childFrames[1]) }
                        ?? defaultTertiaryFrame
                    : nil
                let panelSize = usableCascadeLayout?.containerFrame.size ?? expandedSize
                let frames = [detailFrame, overviewFrame] + [tertiaryFrame].compactMap { $0 }
                let detailCornerRadii = GeekAttachedPanelChromeGeometry.cornerRadii(
                    for: detailFrame,
                    neighbors: frames.filter { $0 != detailFrame },
                    radius: MiniWindowStyleTokens.outerCornerRadius
                )
                let overviewCornerRadii = GeekAttachedPanelChromeGeometry.cornerRadii(
                    for: overviewFrame,
                    neighbors: frames.filter { $0 != overviewFrame },
                    radius: MiniWindowStyleTokens.outerCornerRadius
                )
                let detailBorderEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
                    for: detailFrame,
                    neighbors: frames.filter { $0 != detailFrame }
                )
                let overviewBorderEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
                    for: overviewFrame,
                    neighbors: frames.filter { $0 != overviewFrame }
                )
                ZStack(alignment: .topLeading) {
                    MetricPanelShell(
                        cornerRadii: detailCornerRadii,
                        borderEdges: detailBorderEdges,
                        showsShadow: false
                    ) {
                        MiniWindowFittedPage(contentSize: detailSize, availableSize: detailFrame.size) {
                            detail
                        }
                        }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                onHoverChange(.detail, true)
                                recordDebugHover(.detail, hovering: true, location: location)
                            case .ended:
                                onHoverChange(.detail, false)
                                recordDebugHover(.detail, hovering: false)
                            }
                        }
                        .offset(x: detailFrame.minX, y: detailFrame.minY)

                    MetricPanelShell(
                        cornerRadii: overviewCornerRadii,
                        borderEdges: overviewBorderEdges,
                        showsShadow: false
                    ) {
                        overview
                            .frame(
                                width: overviewSize.width,
                                height: overviewSize.height,
                                alignment: .top
                            )
                        }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                onHoverChange(.overview, true)
                                recordDebugHover(.overview, hovering: true, location: location)
                            case .ended:
                                onHoverChange(.overview, false)
                                recordDebugHover(.overview, hovering: false)
                            }
                        }
                        .offset(x: overviewFrame.minX, y: overviewFrame.minY)

                    if let tertiaryFrame {
                        let tertiaryCornerRadii = GeekAttachedPanelChromeGeometry.cornerRadii(
                            for: tertiaryFrame,
                            neighbors: frames.filter { $0 != tertiaryFrame },
                            radius: MiniWindowStyleTokens.outerCornerRadius
                        )
                        let tertiaryBorderEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
                            for: tertiaryFrame,
                            neighbors: frames.filter { $0 != tertiaryFrame }
                        )
                        MetricPanelShell(
                            cornerRadii: tertiaryCornerRadii,
                            borderEdges: tertiaryBorderEdges,
                            showsShadow: false
                        ) {
                            MiniWindowFittedPage(contentSize: tertiarySize, availableSize: tertiaryFrame.size) {
                                tertiary
                            }
                            }
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(location):
                                    onHoverChange(.tertiary, true)
                                    recordDebugHover(.tertiary, hovering: true, location: location)
                                case .ended:
                                    onHoverChange(.tertiary, false)
                                    recordDebugHover(.tertiary, hovering: false)
                                }
                            }
                            .offset(x: tertiaryFrame.minX, y: tertiaryFrame.minY)
                    }
                }
                .frame(
                    width: panelSize.width,
                    height: panelSize.height,
                    alignment: .topLeading
                )
                .compositingGroup()
                .shadow(
                    color: .black.opacity(
                        colorScheme == .dark
                            ? MiniWindowStyleTokens.darkShellShadowOpacity
                            : MiniWindowStyleTokens.lightShellShadowOpacity
                    ),
                    radius: colorScheme == .dark
                        ? MiniWindowStyleTokens.darkShellShadowRadius
                        : MiniWindowStyleTokens.lightShellShadowRadius,
                    y: MiniWindowStyleTokens.shellShadowYOffset
                )
#if DEBUG
                .overlay {
                    if MiniWindowDebugSupport.isEnabled {
                        MiniWindowDebugOverlay(
                            frames: [detailFrame, overviewFrame] + [tertiaryFrame].compactMap { $0 },
                            activeRegions: debugActiveRegions,
                            localPointerLocation: debugPointerLocation
                        )
                    }
                }
#endif
            }
        }
    }

    private func recordDebugHover(
        _ region: GeekAttachedPanelRegion,
        hovering: Bool,
        location: CGPoint? = nil
    ) {
#if DEBUG
        guard MiniWindowDebugSupport.isEnabled else { return }
        if hovering {
            if debugActiveRegions.insert(region).inserted {
                MiniWindowDebugSupport.log("entered \(debugName(for: region))")
            }
            debugPointerLocation = location
        } else if debugActiveRegions.remove(region) != nil {
            MiniWindowDebugSupport.log("exited \(debugName(for: region))")
        }
#endif
    }

#if DEBUG
    private func debugName(for region: GeekAttachedPanelRegion) -> String {
        switch region {
        case .overview: "main"
        case .detail: "detail"
        case .tertiary: "history"
        }
    }
#endif
}

private extension View {
    func metricPanelShell() -> some View {
        MetricPanelShell { self }
    }
}

struct PanelNavigation<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.bar)
    }
}

struct PanelContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelRefreshControl: View {
    @ObservedObject var store: ScanStore
    let isRefreshing: Bool
    var controlSize: ControlSize = .regular
    let refresh: () -> Void

    var body: some View {
        Menu {
            menuContents
        } label: {
            AppSymbolIcon(systemImage: AppSymbols.Action.refresh, role: .toolbar)
                .opacity(isRefreshing ? 0.45 : 1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(controlSize)
        .help(L10n.text("打开菜单以刷新或更改频率", "Open menu to refresh or change rate"))
        .accessibilityLabel(L10n.text("刷新与刷新频率", "Refresh and Refresh Rate"))
    }

    @ViewBuilder
    var menuContents: some View {
        Button {
            refresh()
        } label: {
            Label(
                L10n.text("立即刷新", "Refresh Now"),
                systemImage: AppSymbols.Action.refresh
            )
        }
        .disabled(isRefreshing)

        Divider()

        Text(L10n.text("刷新频率", "Refresh Rate"))
        ForEach(MenuBarRefreshInterval.allCases) { interval in
            Toggle(interval.pickerTitle, isOn: Binding(
                get: { store.menuBarRefreshInterval == interval },
                set: { selected in
                    if selected { store.setMenuBarRefreshInterval(interval) }
                }
            ))
        }
    }

}

struct PanelToolbarActions: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var state: MenuBarPanelSettingsState
    let isRefreshing: Bool
    var showsLiveActions = true
    var hostsEditorPopover = true
    let showMainWindow: () -> Void
    let togglePause: () -> Void
    let refresh: () -> Void

    private var pauseTitle: String {
        store.isMenuBarRefreshPaused
            ? L10n.text("继续刷新", "Resume Refresh")
            : L10n.text("暂停刷新", "Pause Refresh")
    }

    private var pauseSystemImage: String {
        store.isMenuBarRefreshPaused ? AppSymbols.Action.resume : AppSymbols.Action.pause
    }

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.compact) {
            if showsLiveActions {
                AppIconButton(
                    title: pauseTitle,
                    systemImage: pauseSystemImage,
                    kind: .toolbar,
                    controlSize: .regular,
                    isSelected: store.isMenuBarRefreshPaused,
                    action: togglePause
                )

                refreshControl
            }

            Menu {
                moreMenuContents
            } label: {
                AppSymbolIcon(systemImage: AppSymbols.Action.more, role: .toolbar)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.regular)
            .help(L10n.text("更多小窗操作", "More Panel Actions"))
            .accessibilityLabel(L10n.text("更多小窗操作", "More Panel Actions"))
            .popover(isPresented: geekEditorBinding, arrowEdge: .trailing) {
                GeekDashboardEditor(state: state)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("小窗工具栏", "Panel Toolbar"))
    }

    @ViewBuilder
    var contextMenuContents: some View {
        if showsLiveActions {
            Button(action: togglePause) {
                Label(pauseTitle, systemImage: pauseSystemImage)
            }
            refreshControl.menuContents
            Divider()
        }
        moreMenuContents
    }

    private var refreshControl: PanelRefreshControl {
        PanelRefreshControl(
            store: store,
            isRefreshing: isRefreshing,
            controlSize: .regular,
            refresh: refresh
        )
    }

    @ViewBuilder
    private var moreMenuContents: some View {
        Button {
            state.presentGeekEditor()
        } label: {
            Label(
                L10n.text("自定义极客概览…", "Customize Geek Overview…"),
                systemImage: AppSymbols.Panel.settings
            )
        }

        Toggle(
            L10n.text("窗口置顶", "Keep Window on Top"),
            isOn: alwaysOnTopBinding
        )

        Toggle(
            L10n.text("启动时恢复小窗", "Restore Panel at Launch"),
            isOn: restoreOnLaunchBinding
        )

        Picker(
            L10n.text("菜单栏常驻显示", "Menu Bar Display"),
            selection: statusDisplayBinding
        ) {
            ForEach(MenuBarStatusDisplayMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }

        Divider()

        Button(action: showMainWindow) {
            Label(
                L10n.text("打开主窗口", "Open Main Window"),
                systemImage: AppSymbols.Action.showMainWindow
            )
        }

        Button {
            MenuBarStatusController.shared.dismissPanel()
        } label: {
            Label(
                L10n.text("关闭小窗", "Close Panel"),
                systemImage: AppSymbols.Action.dismiss
            )
        }
    }

    private var geekEditorBinding: Binding<Bool> {
        Binding {
            hostsEditorPopover && state.isGeekEditorPresented
        } set: { isPresented in
            if isPresented {
                state.presentGeekEditor()
            } else {
                state.cancelGeekEditor()
            }
        }
    }

    private var alwaysOnTopBinding: Binding<Bool> {
        Binding {
            state.isAlwaysOnTop
        } set: { value in
            state.setAlwaysOnTop(value)
            setAlwaysOnTop(value)
        }
    }

    private var restoreOnLaunchBinding: Binding<Bool> {
        Binding {
            state.restoresOnLaunch
        } set: { value in
            state.setRestoresOnLaunch(value)
        }
    }

    private var statusDisplayBinding: Binding<MenuBarStatusDisplayMode> {
        Binding {
            MenuBarStatusController.shared.statusDisplayMode
        } set: { mode in
            MenuBarStatusController.shared.setStatusDisplayMode(mode)
        }
    }

    private func setAlwaysOnTop(_ value: Bool) {
        MenuBarStatusController.shared.setPanelAlwaysOnTop(value)
    }
}

struct PanelCircularGauge: View {
    let title: String
    let value: String
    let progress: Double?
    let tint: Color
    let detail: String?
    let size: CGFloat

    init(
        title: String,
        value: String,
        progress: Double?,
        tint: Color = .accentColor,
        detail: String? = nil,
        size: CGFloat = 64
    ) {
        self.title = title
        self.value = value
        self.progress = progress
        self.tint = tint
        self.detail = detail
        self.size = size
    }

    var body: some View {
        VStack(spacing: 3) {
            Gauge(value: resolvedProgress ?? 0, in: 0...1) {
                Text(title)
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Text(displayValue)
                        .font(AppPanelTypography.value)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)

                    Text(title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(resolvedProgress == nil ? Color.secondary : tint)
            .frame(width: size, height: size)

            if let displayDetail {
                Text(displayDetail)
                    .font(AppPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(displayDetail ?? "")
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    nonisolated static func normalizedProgress(_ progress: Double?) -> Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(1, max(0, progress))
    }

    private var resolvedProgress: Double? {
        Self.normalizedProgress(progress)
    }

    private var displayValue: String {
        resolvedProgress == nil ? "—" : value
    }

    private var displayDetail: String? {
        resolvedProgress == nil ? unavailableText : detail
    }

    private var accessibilityValue: String {
        resolvedProgress == nil ? unavailableText : value
    }

    private var unavailableText: String {
        L10n.text("不可用", "Unavailable")
    }

    private var helpText: String {
        guard let displayDetail else { return "\(title): \(accessibilityValue)" }
        return "\(title): \(accessibilityValue) · \(displayDetail)"
    }
}

struct PanelHeader: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var state: MenuBarPanelSettingsState
    let title: String
    let updatedAt: Date?
    let unavailableText: String
    let systemImage: String
    let isConnected: Bool
    let isRefreshing: Bool
    let simpleSectionSelection: Binding<PanelSection>?
    let showMainWindow: () -> Void
    let togglePause: () -> Void
    let refresh: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showsStatusTitle: true)
            headerRow(showsStatusTitle: false)
        }
        .padding(.horizontal, AppDesignTokens.Spacing.small)
        .padding(.vertical, AppDesignTokens.Spacing.compact)
        .frame(minHeight: 50)
        .background(.bar)
    }

    private func headerRow(showsStatusTitle: Bool) -> some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            AppSymbolIcon(systemImage: systemImage, role: .panelHeader)
                .accessibilityHidden(true)

            identityBlock
                .layoutPriority(1)

            Spacer(minLength: AppDesignTokens.Spacing.small)

            if showsStatusTitle {
                Label(statusTitle, systemImage: statusImage)
                    .font(AppPanelTypography.caption)
                    .foregroundStyle(statusForeground)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(statusAccessibilityLabel)
            } else {
                AppSymbolIcon(
                    systemImage: statusImage,
                    role: .toolbar,
                    tint: statusForeground
                )
                .help(statusAccessibilityLabel)
                .accessibilityLabel(statusAccessibilityLabel)
            }

            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel(L10n.text("正在刷新本机数据", "Refreshing local data"))
            }

            PanelToolbarActions(
                store: store,
                state: state,
                isRefreshing: isRefreshing,
                showMainWindow: showMainWindow,
                togglePause: togglePause,
                refresh: refresh
            )
        }
    }

    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let simpleSectionSelection {
                Picker(
                    L10n.text("小窗分区", "Panel Section"),
                    selection: simpleSectionSelection
                ) {
                    ForEach(PanelSection.simpleChoices) { section in
                        Text(section.simpleTitle).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L10n.text("小窗分区", "Panel Section"))
            } else {
                Text(title)
                    .font(AppPanelTypography.header)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(updatedText)
                .font(AppPanelTypography.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .help(updatedDetailText)
        }
    }

    private var updatedText: String {
        guard let updatedAt else { return unavailableText }
        return L10n.text(
            "更新于 \(PanelTimestampFormat.display(updatedAt))",
            "Updated \(PanelTimestampFormat.display(updatedAt))"
        )
    }

    private var updatedDetailText: String {
        guard let updatedAt else { return unavailableText }
        return L10n.text(
            "最后更新 \(PanelTimestampFormat.detail(updatedAt))",
            "Last updated \(PanelTimestampFormat.detail(updatedAt))"
        )
    }

    private var statusTitle: String {
        if !isConnected { return L10n.text("已断开", "Disconnected") }
        return store.isMenuBarRefreshPaused
            ? L10n.text("已暂停", "Paused")
            : L10n.text("实时", "Live")
    }

    private var statusImage: String {
        if !isConnected { return "wifi.slash" }
        return store.isMenuBarRefreshPaused ? AppSymbols.Action.pause : AppSymbols.Status.live
    }

    private var statusForeground: Color {
        isConnected ? AppDesignTokens.Palette.secondaryText : AppDesignTokens.Palette.warning
    }

    private var statusAccessibilityLabel: String {
        if !isConnected { return L10n.text("实时数据已断开", "Live data disconnected") }
        return store.isMenuBarRefreshPaused
            ? L10n.text("监控已暂停", "Monitoring paused")
            : L10n.text("实时数据", "Live data")
    }
}
