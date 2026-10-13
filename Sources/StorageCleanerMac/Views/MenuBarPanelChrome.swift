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

    /// D74 uses the existing relative-axis wording with the source's date,
    /// never the date when a panel or a cached history window was opened.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed.isFinite, elapsed >= 0 else { return L10n.text("采样时间未知", "Sample time unknown") }
        let seconds = Int(min(elapsed.rounded(.down), Double(Int.max / 2)))
        return L10n.text("\(seconds) 秒前", "\(seconds) s ago")
    }

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

}

enum PanelLayoutMetrics {
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

/// Each touching level keeps its complete rounded outline. One neighbor owns
/// each shared straight separator so that segment is never drawn twice.
enum GeekAttachedPanelChromeGeometry {
    private static let tolerance: CGFloat = 0.01

    static func cornerRadii(
        for frame: CGRect,
        neighbors: [CGRect],
        radius: CGFloat
    ) -> RectangleCornerRadii {
        // Every menu is a complete rounded surface, even when its frame touches
        // another menu. Only a shared straight border is suppressed below.
        let resolvedRadius = max(0, min(radius, min(frame.width, frame.height) / 2))
        return RectangleCornerRadii(
            topLeading: resolvedRadius,
            bottomLeading: resolvedRadius,
            bottomTrailing: resolvedRadius,
            topTrailing: resolvedRadius
        )
    }

    /// In local (top-down) coordinates, the left/top pane owns the seam.
    /// Preserve the entire continuous curve and uncovered edge segments when
    /// the neighbor is shorter; a nominal 12 pt continuous curve extends further
    /// than 12 pt along an edge, so use the actual SwiftUI path extent.
    static func exposedBorderEdges(
        for frame: CGRect,
        neighbors: [CGRect]
    ) -> MiniWindowBorderEdges {
        guard frame.width > 0, frame.height > 0 else { return .all }
        func remaining(_ cuts: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
            var spans: [ClosedRange<CGFloat>] = [0 ... 1]
            for cut in cuts {
                spans = spans.flatMap { span -> [ClosedRange<CGFloat>] in
                    guard cut.upperBound > span.lowerBound, cut.lowerBound < span.upperBound else { return [span] }
                    var pieces: [ClosedRange<CGFloat>] = []
                    if cut.lowerBound > span.lowerBound { pieces.append(span.lowerBound ... cut.lowerBound) }
                    if cut.upperBound < span.upperBound { pieces.append(cut.upperBound ... span.upperBound) }
                    return pieces
                }
            }
            return spans
        }
        var leading: [ClosedRange<CGFloat>] = []
        var top: [ClosedRange<CGFloat>] = []
        for other in neighbors {
            let verticalInset = min(frame.height / 2, MiniWindowStyleTokens.outerCornerExtent)
            let otherVerticalInset = min(other.height / 2, MiniWindowStyleTokens.outerCornerExtent)
            let y0 = max(frame.minY + verticalInset, other.minY + otherVerticalInset)
            let y1 = min(frame.maxY - verticalInset, other.maxY - otherVerticalInset)
            if abs(frame.minX - other.maxX) < tolerance, y1 - y0 > tolerance {
                leading.append((y0 - frame.minY) / frame.height ... (y1 - frame.minY) / frame.height)
            }
            let horizontalInset = min(frame.width / 2, MiniWindowStyleTokens.outerCornerExtent)
            let otherHorizontalInset = min(other.width / 2, MiniWindowStyleTokens.outerCornerExtent)
            let x0 = max(frame.minX + horizontalInset, other.minX + otherHorizontalInset)
            let x1 = min(frame.maxX - horizontalInset, other.maxX - otherHorizontalInset)
            if abs(frame.minY - other.maxY) < tolerance, x1 - x0 > tolerance {
                top.append((x0 - frame.minX) / frame.width ... (x1 - frame.minX) / frame.width)
            }
        }
        return MiniWindowBorderEdges(top: remaining(top), leading: remaining(leading))
    }
}

struct GeekAttachedPanelShell<Detail: View, Overview: View, Tertiary: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.geekPanelHoverCoordinator) private var hoverCoordinator

    private func compactSurface(size: CGSize, detailSize: CGSize, tertiarySize: CGSize) -> some View {
        MetricPanelShell {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        if showsTertiary { hoverCoordinator?.dismissHistory() }
                        else { hoverCoordinator?.reset() }
                    } label: {
                        Label(L10n.text("返回", "Back"), systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .font(AdvancedPanelTypography.captionStrong)
                    .controlSize(.small)
                    Spacer(minLength: 4)
                    Text(showsTertiary ? L10n.text("详情", "Details") : section.title)
                        .font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(L10n.text("总览", "Overview")) { hoverCoordinator?.reset() }
                }
                .controlSize(.small)
                .padding(8)
                Divider()
                // Scrolling is intentional here: never scale a full desktop
                // page into unreadable text just to preserve three columns.
                if detailOwnsScrolling && !showsTertiary {
                    GeometryReader { viewport in
                        detail
                            .environment(\.geekCleanupAvailableHeight,
                                         max(0, viewport.size.height - 2 * GeekPanelLayout.contentPadding))
                            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                    }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Group {
                            if showsTertiary { tertiary } else { detail }
                        }
                        .frame(width: showsTertiary ? tertiarySize.width : detailSize.width,
                               alignment: .topLeading)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .contentShape(Rectangle())
        .onHover { onHoverChange(showsTertiary ? .tertiary : .detail, $0) }
        .accessibilityIdentifier("mini-window-compact-navigation")
    }

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
    var detailOwnsScrolling = false
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
            if let cascadeLayout, cascadeLayout.isCompact {
                compactSurface(size: cascadeLayout.containerFrame.size,
                               detailSize: detailSize, tertiarySize: tertiarySize)
            } else if presentationMode == .unavailable {
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
                        if detailOwnsScrolling {
                            detail
                                .environment(\.geekCleanupAvailableHeight,
                                             max(0, detailFrame.height - 2 * GeekPanelLayout.contentPadding))
                                .frame(width: detailFrame.width, height: detailFrame.height, alignment: .top)
                        } else {
                            MiniWindowFittedPage(contentSize: detailSize, availableSize: detailFrame.size) {
                                detail
                            }
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

extension View {
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
            Text(L10n.text("立即刷新", "Refresh Now"))
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
    @Environment(\.openSettings) private var openSettings
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

        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("小窗工具栏", "Panel Toolbar"))
    }

    @ViewBuilder
    var contextMenuContents: some View {
        if showsLiveActions {
            Button(action: togglePause) {
                Text(pauseTitle)
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
            UserDefaults.standard.set("miniWindow", forKey: "settings.selected-category.v1")
            openSettings()
        } label: {
            Text(L10n.text("小窗设置…", "Panel Settings…"))
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
            Text(L10n.text("打开主窗口", "Open Main Window"))
        }

        Button {
            MenuBarStatusController.shared.dismissPanel()
        } label: {
            Text(L10n.text("关闭小窗", "Close Panel"))
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
