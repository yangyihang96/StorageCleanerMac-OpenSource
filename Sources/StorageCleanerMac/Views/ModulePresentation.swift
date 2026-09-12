import AppKit
import SwiftUI

struct AppWindowLayoutPolicy {
    static let referenceContentSize = NSSize(width: 980, height: 640)
    static let minimumReferenceContentSize = NSSize(width: 820, height: 520)
    static let unboundedContentSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    static let screenMargin: CGFloat = 24
    static let compactBreakpoint: CGFloat = 900

    static func availableFrame(in visibleFrame: NSRect) -> NSRect {
        let horizontalInset = min(screenMargin, max(0, visibleFrame.width / 2 - 1))
        let verticalInset = min(screenMargin, max(0, visibleFrame.height / 2 - 1))
        return visibleFrame.insetBy(dx: horizontalInset, dy: verticalInset)
    }

    static func maximumContentSize(in visibleFrame: NSRect) -> NSSize {
        let available = availableFrame(in: visibleFrame)
        guard available.width > 0, available.height > 0 else { return referenceContentSize }
        return available.size
    }

    static func minimumContentSize(in visibleFrame: NSRect) -> NSSize {
        let maximum = maximumContentSize(in: visibleFrame)
        return NSSize(
            width: min(minimumReferenceContentSize.width, maximum.width),
            height: min(minimumReferenceContentSize.height, maximum.height)
        )
    }

    static func fittedContentSize(
        _ proposed: NSSize,
        in visibleFrame: NSRect
    ) -> NSSize {
        let maximum = maximumContentSize(in: visibleFrame)
        let minimum = minimumContentSize(in: visibleFrame)
        let proposedWidth = proposed.width.isFinite && proposed.width > 0
            ? proposed.width
            : referenceContentSize.width
        let proposedHeight = proposed.height.isFinite && proposed.height > 0
            ? proposed.height
            : referenceContentSize.height
        return NSSize(
            width: min(maximum.width, max(minimum.width, proposedWidth)),
            height: min(maximum.height, max(minimum.height, proposedHeight))
        )
    }

    static func isFullyVisible(_ frame: NSRect, in visibleFrame: NSRect) -> Bool {
        availableFrame(in: visibleFrame).contains(frame)
    }

    static func centeredOrigin(
        for size: NSSize,
        in visibleFrame: NSRect
    ) -> NSPoint {
        let available = availableFrame(in: visibleFrame)
        return NSPoint(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2
        )
    }

    static func clampedOrigin(
        _ origin: NSPoint,
        size: NSSize,
        in visibleFrame: NSRect
    ) -> NSPoint {
        let available = availableFrame(in: visibleFrame)
        return NSPoint(
            x: min(max(origin.x, available.minX), available.maxX - size.width),
            y: min(max(origin.y, available.minY), available.maxY - size.height)
        )
    }
}

struct WindowLayoutMetrics {
    enum Density: Equatable {
        case compact
        case regular
    }

    let density: Density
    let isShort: Bool
    let sidebarMinimumWidth: CGFloat
    let sidebarIdealWidth: CGFloat
    let sidebarMaximumWidth: CGFloat
    let contentPadding: CGFloat
    let cardSpacing: CGFloat
    let cardPadding: CGFloat
    let sectionSpacing: CGFloat
    let rowHeight: CGFloat
    let titleFont: Font
    let valueFont: Font
    let secondaryFont: Font
    let iconSize: CGFloat
    let cornerRadius: CGFloat
    let chartHeight: CGFloat
    let footerHeight: CGFloat

    init(contentSize: CGSize) {
        let compact = contentSize.width < AppWindowLayoutPolicy.compactBreakpoint
        density = compact ? .compact : .regular
        isShort = contentSize.height < 560
        sidebarMinimumWidth = compact ? 158 : AppDesignTokens.Layout.sidebarMinimumWidth
        sidebarIdealWidth = compact ? 164 : AppDesignTokens.Layout.sidebarExpandedWidth
        sidebarMaximumWidth = compact ? 172 : AppDesignTokens.Layout.sidebarMaximumWidth
        contentPadding = compact ? 16 : AppDesignTokens.Layout.pagePadding
        cardSpacing = compact ? 8 : AppDesignTokens.Spacing.small
        cardPadding = compact ? 12 : AppDesignTokens.Layout.sectionPadding
        sectionSpacing = compact ? 16 : AppDesignTokens.Spacing.large
        rowHeight = 32
        titleFont = AppTypography.pageTitle
        valueFont = AppDesignTokens.Typography.inlineTitle
        secondaryFont = AppDesignTokens.Typography.metadata
        iconSize = compact ? 16 : 18
        cornerRadius = AppDesignTokens.Layout.cardRadius
        chartHeight = compact ? 120 : 150
        // Reserve one identical slot for every scan state. The cleanup action
        // bar is the tallest footer, so shorter read-only notes must not
        // collapse the shell and make the window appear to jump.
        footerHeight = 72
    }

    static let reference = WindowLayoutMetrics(
        contentSize: CGSize(
            width: AppWindowLayoutPolicy.referenceContentSize.width,
            height: AppWindowLayoutPolicy.referenceContentSize.height
        )
    )
}

private struct WindowLayoutMetricsKey: EnvironmentKey {
    static let defaultValue = WindowLayoutMetrics.reference
}

extension EnvironmentValues {
    var windowLayoutMetrics: WindowLayoutMetrics {
        get { self[WindowLayoutMetricsKey.self] }
        set { self[WindowLayoutMetricsKey.self] = newValue }
    }
}

/// One fixed Smart Scan skeleton shared by idle, scanning, and results.
/// Only the middle slot changes its contents; header/footer geometry stays put.
struct SmartScanPageShell<Header: View, Content: View, Footer: View>: View {
    @Environment(\.windowLayoutMetrics) private var layout
    private let header: Header
    private let content: Content
    private let footer: Footer

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
#if DEBUG
                    .layoutProbe(LayoutProbeID.smartScanHeader)
#endif

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .layoutPriority(1)
#if DEBUG
                    .layoutProbe(LayoutProbeID.smartScanContent)
#endif

                footer
                    .frame(height: layout.footerHeight)
                    .frame(maxWidth: .infinity)
#if DEBUG
                    .layoutProbe(LayoutProbeID.smartScanFooter)
#endif
            }
            .padding(.horizontal, layout.contentPadding)
            .padding(.top, AppDesignTokens.Spacing.small)
            .padding(.bottom, layout.contentPadding)
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .top
            )
#if DEBUG
            .layoutProbe(LayoutProbeID.smartScanRoot)
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Configures only the primary app window.  Settings and popovers retain their
/// own native window behavior and restored placement.
struct MainWindowChromeConfigurator: NSViewRepresentable {
    @MainActor
    final class Coordinator: NSObject {
        private weak var window: NSWindow?
        private var didApplyInitialLayout = false

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            NotificationCenter.default.removeObserver(self)
            self.window = window
            didApplyInitialLayout = false

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenParametersDidChange(_:)),
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillEnterFullScreen(_:)),
                name: NSWindow.willEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidExitFullScreen(_:)),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
        }

        func apply() {
            guard !didApplyInitialLayout else { return }
            didApplyInitialLayout = true
            applyLayout(centerWhenResized: true)
        }

        @objc private func windowDidChangeScreen(_ notification: Notification) {
            applyLayout(centerWhenResized: true)
        }

        @objc private func screenParametersDidChange(_ notification: Notification) {
            applyLayout(centerWhenResized: false)
        }

        @objc private func windowWillEnterFullScreen(_ notification: Notification) {
            window?.contentMaxSize = AppWindowLayoutPolicy.unboundedContentSize
        }

        @objc private func windowDidExitFullScreen(_ notification: Notification) {
            applyLayout(centerWhenResized: false)
        }

        private func applyLayout(centerWhenResized: Bool) {
            guard let window,
                  let visibleFrame = window.screen?.visibleFrame
                    ?? NSScreen.main?.visibleFrame
                    ?? NSScreen.screens.first?.visibleFrame else { return }

            let maximumContentSize = AppWindowLayoutPolicy.maximumContentSize(in: visibleFrame)
            let minimumContentSize = AppWindowLayoutPolicy.minimumContentSize(in: visibleFrame)
            window.contentMinSize = minimumContentSize
            if window.styleMask.contains(.fullScreen) {
                window.contentMaxSize = AppWindowLayoutPolicy.unboundedContentSize
                return
            }
            window.contentMaxSize = maximumContentSize

            let currentContentSize = window.contentRect(forFrameRect: window.frame).size
            let targetContentSize = AppWindowLayoutPolicy.fittedContentSize(
                currentContentSize,
                in: visibleFrame
            )
            var targetFrame = window.frameRect(forContentRect: NSRect(
                origin: .zero,
                size: targetContentSize
            ))
            let sizeChanged = abs(targetFrame.width - window.frame.width) > 0.5
                || abs(targetFrame.height - window.frame.height) > 0.5
            let currentFrameIsVisible = AppWindowLayoutPolicy.isFullyVisible(
                window.frame,
                in: visibleFrame
            )
            guard sizeChanged || !currentFrameIsVisible else { return }

            targetFrame.origin = sizeChanged && centerWhenResized
                ? AppWindowLayoutPolicy.centeredOrigin(
                    for: targetFrame.size,
                    in: visibleFrame
                )
                : AppWindowLayoutPolicy.clampedOrigin(
                    window.frame.origin,
                    size: targetFrame.size,
                    in: visibleFrame
                )
            window.setFrame(targetFrame, display: true, animate: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassthroughWindowConfigurationView {
        let coordinator = context.coordinator
        return PassthroughWindowConfigurationView { window in
            configure(window, coordinator: coordinator)
        }
    }

    func updateNSView(_ view: PassthroughWindowConfigurationView, context: Context) {
        let coordinator = context.coordinator
        view.updateConfiguration { window in
            configure(window, coordinator: coordinator)
        }
    }

    private func configure(_ window: NSWindow, coordinator: Coordinator) {
        // SwiftUI may reinstate the window title after applying a toolbar.
        // The integrated titlebar is the sole visible and accessible app title.
        window.title = ""
        window.setAccessibilityTitle(L10n.appName)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        // Keep a real backing surface while SwiftUI switches feature content.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor

        coordinator.attach(to: window)
        coordinator.apply()

        if let sidebarToggleIndex = window.toolbar?.items.firstIndex(
            where: { $0.itemIdentifier == .toggleSidebar }
        ) {
            window.toolbar?.removeItem(at: sidebarToggleIndex)
        }
    }
}

struct ModuleBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let theme: ModuleTheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.startColor(for: colorScheme), theme.endColor(for: colorScheme)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if theme.isImmersive {
                RadialGradient(
                    colors: [colorScheme == .dark ? theme.darkRadialHighlight : theme.radialHighlight, .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 720
                )
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityHidden(true)
    }
}

struct IntegratedTitlebar: View {
    let theme: ModuleTheme

    var body: some View {
        ZStack {
            TitlebarDragRegion()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            HStack(spacing: AppDesignTokens.Spacing.small) {
                Text(L10n.productName)
                    .font(AppTypography.integratedTitlebar)
                    .foregroundStyle(theme.primaryText.opacity(0.94))

                if L10n.showsBetaBadge {
                    Text(L10n.text("测试版", "Beta"))
                        .font(AppTypography.sidebarVersion)
                        .foregroundStyle(theme.primaryText.opacity(0.88))
                        .padding(.horizontal, AppDesignTokens.Spacing.tight)
                        .padding(.vertical, AppDesignTokens.Spacing.hairline)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.14))
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(titlebarAccessibilityLabel)
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppDesignTokens.Layout.integratedTitlebarHeight)
    }

    private var titlebarAccessibilityLabel: String {
        L10n.showsBetaBadge
            ? "\(L10n.productName) \(L10n.text("测试版", "Beta"))"
            : L10n.productName
    }
}

/// AppKit keeps this header draggable on the app's macOS 14 deployment target.
struct TitlebarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarDragView {
        TitlebarDragView()
    }

    func updateNSView(_ view: TitlebarDragView, context: Context) {}
}

final class TitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}

struct MainContentHost<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let route: ReviewFilter
    let showsIntegratedTitlebar: Bool
    private let content: Content

    init(
        route: ReviewFilter,
        showsIntegratedTitlebar: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.route = route
        self.showsIntegratedTitlebar = showsIntegratedTitlebar
        self.content = content()
    }

    var body: some View {
        let theme = route.moduleTheme

        VStack(spacing: 0) {
            if showsIntegratedTitlebar {
                IntegratedTitlebar(theme: theme)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ModuleBackground(theme: theme))
        .environment(\.moduleTheme, theme)
        // The golden main-window surface is dark even when macOS is light.
        // Scope native label/control contrast here; neutral settings stay native.
        .environment(\.colorScheme, theme.isImmersive ? .dark : colorScheme)
        .tint(theme.accent)
        .foregroundStyle(theme.primaryText)

    }
}

struct ContentPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.moduleTheme) private var theme

    private let cornerRadius: CGFloat
    private let content: Content

    init(
        cornerRadius: CGFloat = AppDesignTokens.Radius.modulePanel,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                theme.panelFill(
                    for: colorScheme,
                    reduceTransparency: reduceTransparency
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        theme.panelBorder(for: colorSchemeContrast),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

private struct FullBleedSectionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension View {
    func fullBleedSection() -> some View {
        modifier(FullBleedSectionModifier())
    }
}

/// A page-level content surface that deliberately adds no second background,
/// border, corner radius, or shadow. Feature pages use the window's module
/// background as their canvas; smaller semantic cards can still use
/// `ContentPanel` or `glassPanel` inside this surface.
struct FeatureWorkspaceSurface<Content: View>: View {

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                maxWidth: .infinity,
                minHeight: 0,
                maxHeight: .infinity,
                alignment: .topLeading
            )
    }
}

struct GlassToolbarButton: View {
    let title: String
    let systemImage: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppDesignTokens.Spacing.tight) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isDisabled || isLoading)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Compatibility vocabulary for feature modules; styling stays owned by the
/// existing glass toolbar implementation.
typealias UnifiedToolbarButton = GlassToolbarButton

struct GlassSegmentedControl<Selection: Hashable & Identifiable>: View {
    @Binding var selection: Selection
    let options: [Selection]
    let title: (Selection) -> String

    init(
        selection: Binding<Selection>,
        options: [Selection],
        title: @escaping (Selection) -> String
    ) {
        _selection = selection
        self.options = options
        self.title = title
    }

    var body: some View {
        Picker(L10n.text("选项", "Options"), selection: $selection) {
            ForEach(options) { option in
                Text(title(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
    }
}

typealias UnifiedSegmentedControl<Selection: Hashable & Identifiable> = GlassSegmentedControl<Selection>

enum ScanStatusPresentation: Equatable {
    case idle(String)
    case neverScanned
    case expired
    case scanning(String)
    case completed(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle(let text), .scanning(let text), .completed(let text), .failed(let text):
            text
        case .neverScanned:
            L10n.text("尚未扫描", "Not scanned")
        case .expired:
            L10n.text("上次扫描已过期", "Last scan is out of date")
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            "circle"
        case .neverScanned:
            "clock"
        case .expired:
            "clock.arrow.circlepath"
        case .scanning:
            "arrow.triangle.2.circlepath"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}

struct ScanStatusView: View {
    let status: ScanStatusPresentation

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(AppTypography.metadata)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(status.title)
    }
}

typealias StatusMessageRow = ScanStatusView

struct HeroScanPage<Accessory: View>: View {
    let title: String
    let subtitle: String
    let headerSystemImage: String?
    let configurationTitle: String?
    let actionTitle: String
    let actionDetail: String
    let actionSystemImage: String
    let status: ScanStatusPresentation
    let isLoading: Bool
    let isActionDisabled: Bool
    let trustText: String?
    let action: () -> Void
    private let showsAccessory: Bool
    private let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        headerSystemImage: String? = nil,
        configurationTitle: String? = nil,
        actionTitle: String,
        actionDetail: String,
        actionSystemImage: String,
        status: ScanStatusPresentation,
        isLoading: Bool = false,
        isActionDisabled: Bool = false,
        trustText: String? = nil,
        showsAccessory: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.headerSystemImage = headerSystemImage
        self.configurationTitle = configurationTitle
        self.actionTitle = actionTitle
        self.actionDetail = actionDetail
        self.actionSystemImage = actionSystemImage
        self.status = status
        self.isLoading = isLoading
        self.isActionDisabled = isActionDisabled
        self.trustText = trustText
        self.action = action
        self.showsAccessory = showsAccessory
        self.accessory = accessory()
    }

    var body: some View {
        FileToolLandingPage(
            title: title,
            subtitle: subtitle,
            systemImage: headerSystemImage ?? actionSystemImage,
            configurationTitle: showsAccessory
                ? configurationTitle ?? L10n.text("扫描选项", "Scan Options")
                : nil,
            actionTitle: actionTitle,
            actionDetail: actionDetail,
            actionSystemImage: actionSystemImage,
            status: status,
            isLoading: isLoading,
            isActionDisabled: isActionDisabled,
            trustText: trustText ?? "",
            action: action
        ) {
            accessory
        }
    }
}

extension HeroScanPage where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String,
        headerSystemImage: String? = nil,
        configurationTitle: String? = nil,
        actionTitle: String,
        actionDetail: String,
        actionSystemImage: String,
        status: ScanStatusPresentation,
        isLoading: Bool = false,
        isActionDisabled: Bool = false,
        trustText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            headerSystemImage: headerSystemImage,
            configurationTitle: configurationTitle,
            actionTitle: actionTitle,
            actionDetail: actionDetail,
            actionSystemImage: actionSystemImage,
            status: status,
            isLoading: isLoading,
            isActionDisabled: isActionDisabled,
            trustText: trustText,
            showsAccessory: false,
            action: action,
            accessory: { EmptyView() }
        )
    }
}

typealias FeatureLandingPageShell<Accessory: View> = HeroScanPage<Accessory>

struct ModulePageHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    @ViewBuilder let actions: Actions

    var body: some View {
        AppPageHeader(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            isHero: [ReviewFilter.privacy.systemImage, ReviewFilter.startup.systemImage, ReviewFilter.performance.systemImage, "speedometer"].contains(systemImage)
        ) {
            actions
        }
    }
}

typealias PageHeader<Actions: View> = ModulePageHeader<Actions>

struct ManagementListPage<Actions: View, Controls: View, Content: View>: View {
    @Environment(\.windowLayoutMetrics) private var layout

    let title: String
    let subtitle: String?
    let systemImage: String
    @ViewBuilder private let actions: Actions
    private let summary: AnyView?
    @ViewBuilder private let controls: Controls
    @ViewBuilder private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.actions = actions()
        self.summary = nil
        self.controls = controls()
        self.content = content()
    }

    init<Summary: View>(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.actions = actions()
        self.summary = AnyView(summary())
        self.controls = controls()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage
            ) {
                actions
            }
            .padding(.bottom, AppDesignTokens.Spacing.small)

            if let summary {
                summary
                    .padding(.bottom, AppDesignTokens.Spacing.small)
            }

            controls
                .padding(.bottom, AppDesignTokens.Spacing.medium)

            FeatureWorkspaceSurface {
                content
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, layout.contentPadding)
        .padding(.top, AppDesignTokens.Spacing.compact)
        .padding(.bottom, layout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

typealias FeatureDataPageShell<Actions: View, Controls: View, Content: View> =
    ManagementListPage<Actions, Controls, Content>

struct DashboardPage<Actions: View, Content: View>: View {
    @Environment(\.windowLayoutMetrics) private var layout

    let title: String
    let subtitle: String?
    let systemImage: String
    @ViewBuilder private let actions: Actions
    @ViewBuilder private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage
            ) {
                actions
            }
            .padding(.bottom, AppDesignTokens.Spacing.small)

            FeatureWorkspaceSurface {
                content
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, layout.contentPadding)
        .padding(.top, AppDesignTokens.Spacing.compact)
        .padding(.bottom, layout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

typealias EmptyStateView<Action: View> = AppEmptyState<Action>
