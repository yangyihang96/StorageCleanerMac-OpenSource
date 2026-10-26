import SwiftUI

enum FeatureLandingOptionsLayout: Equatable, Sendable {
    case scrolling
    /// The dashboard fills the slot; only its process list scrolls.
    case dashboard
}

/// The initial-state compatibility entry shared by all fourteen modules.
/// Routes owned by D67 reuse the Lightfield skeleton and options container.
///
/// The scanner and its state stay owned by the feature Store. This view owns
/// the initial-state composition; result pages keep their complete data lists.
struct FeatureLandingTemplate<Accessory: View>: View {
#if DEBUG
    @Environment(\.featureDemoPrimaryAction) private var demoPrimaryAction
#endif
    @Environment(\.landingHeaderAction) private var headerAction
    @Environment(\.featureLightfieldModule) private var providedLightfieldModule
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    @Environment(\.smartScanFlowNamespace) private var flowNamespace
    @Environment(\.landingStateArt) private var stateArt
    @AppSurfaces private var surfaces

    let title: String
    let systemImage: String
    let configurationTitle: String?
    let actionTitle: String
    let status: ScanStatusPresentation
    let isLoading: Bool
    let isActionDisabled: Bool
    let allowsActionWhileLoading: Bool
    let trustText: String
    let action: () -> Void
    private let optionsLayout: FeatureLandingOptionsLayout
    private let accessory: Accessory

    init(
        title: String,
        subtitle: String = "",
        systemImage: String,
        configurationTitle: String?,
        actionTitle: String,
        actionDetail: String = "",
        actionSystemImage: String = "",
        status: ScanStatusPresentation,
        isLoading: Bool = false,
        isActionDisabled: Bool = false,
        allowsActionWhileLoading: Bool = false,
        optionsLayout: FeatureLandingOptionsLayout = .scrolling,
        trustText: String,
        action: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.configurationTitle = configurationTitle
        self.actionTitle = actionTitle
        self.status = status
        self.isLoading = isLoading
        self.isActionDisabled = isActionDisabled
        self.allowsActionWhileLoading = allowsActionWhileLoading
        self.optionsLayout = optionsLayout
        self.trustText = trustText
        self.action = action
        self.accessory = accessory()
    }

    /// D63: bounded content and artwork share one canvas and form a centered
    /// composition. Only options scroll; the primary action and integrated
    /// status line remain visible down to the 338 pt tiled detail viewport.
    var body: some View {
        Group {
            if let module = lightfieldModule {
                FeatureLightfieldPage(module: module, phase: .landing, title: title,
                    status: status.title, safety: trustText, actionTitle: actionTitle,
                    actionEnabled: !isActionDisabled && (!isLoading || allowsActionWhileLoading),
                    artwork: systemImage == GeneratedArt.similarPhotosSystemImage ? .similarPhotos : nil,
                    action: primaryAction) {
                    FeatureLightfieldOptions(title: configurationTitle ?? defaultConfigurationTitle) {
                        accessory
                    }
                }
            } else {
                FeaturePageScaffold(systemImage: systemImage, status: status, trustText: trustText) {
                    landingHeader
                } panel: { metrics in
                    configurationPanel(availableWidth: metrics.actionWidth, metrics: metrics)
                } artwork: {
                    landingArtwork
                }
            }
        }
        .tint(theme.actionFill)
        .environment(\.landingHeaderAction, nil)
    }

    private var lightfieldModule: ReviewFilter? {
        if let module = providedLightfieldModule {
            return FeatureLightfield.owns(module) ? module : nil
        }
        // B7 file entries also accept a symbol without ModulePageContainer.
        // Keep the pilots' explicit V1 compatibility fixtures on their old
        // template unless a container supplies a Lightfield route.
        if systemImage == GeneratedArt.similarPhotosSystemImage && FeatureLightfield.owns(.duplicates) { return .duplicates }
        return ReviewFilter.fileWorkspaceCases.first { FeatureLightfield.owns($0) && $0.systemImage == systemImage }
    }

    @ViewBuilder
    private var landingHeader: some View {
        if let headerAction {
            AppPageHeader(title: title,
                          isHero: true, role: .landing) {
                headerAction
            }
        } else {
            // No header action: an EmptyView header reserves no action row.
            AppPageHeader(title: title,
                          isHero: true, role: .landing) {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var landingArtwork: some View {
        if let stateArt {
            StateLandingArtwork(art: stateArt, fallbackSystemImage: systemImage)
        } else if theme.featureGroup == .smartScan {
            OrbitLandingArtwork.smartScan()
        } else {
            // D58: the module's generated mark at the center of the shared
            // orbit drawing; its nodes are the page's scope items. The sweep
            // turns only while the page works (§3.3).
            OrbitLandingArtwork.module(
                systemImage: systemImage,
                isActive: false
            )

        }
    }

    private func configurationPanel(availableWidth: CGFloat, metrics: LandingMetrics) -> some View {
        let inset = metrics.cardInset
        return VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            if optionsLayout == .dashboard {
                // Keep the same scroll host and geometry as the options
                // template, but constrain its complete dashboard to the slot.
                // The outer host has no overflow; the nested list owns it.
                GeometryReader { proxy in
                    ScrollView {
                        accessory
                            .frame(width: proxy.size.width, height: proxy.size.height)
#if DEBUG
                            .layoutProbe("landing.optionsContent")
                            .overlay(alignment: .bottom) {
                                Color.clear.frame(height: 1).layoutProbe("landing.optionsEnd")
                            }
#endif
                    }
                    .scrollIndicators(.hidden)
#if DEBUG
                    .layoutProbe("landing.optionsViewport")
#endif
                }
            } else {
                GeometryReader { _ in
                    VStack(alignment: .leading, spacing: metrics.cardSpacing) {
                        HStack(spacing: AppDesignTokens.Grid.x1) {
                            Text(configurationTitle ?? defaultConfigurationTitle)
                                .font(AppDesignTokens.TypeScale.sectionTitle)
                                .foregroundStyle(surfaces.textPrimary).accessibilityAddTraits(.isHeader)
                        }
                        Rectangle().fill(surfaces.divider).frame(height: 1).accessibilityHidden(true)
                        FeatureOptionsScrollView(probePrefix: "landing") {
                            VStack(alignment: .leading, spacing: metrics.cardSpacing) {
                                if showsBuiltInScopeGrid {
                                    builtInScopeGrid(availableWidth: availableWidth - inset * 2)
                                }
                                accessory

                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
#if DEBUG
                            .layoutProbe("landing.optionsContent")
                            .overlay(alignment: .bottom) { Color.clear.frame(height: 1).layoutProbe("landing.optionsEnd") }
#endif
                        }
#if DEBUG
                        .layoutProbe("landing.optionsViewport")
#endif
                    }
                }
                .environment(\.featureCardPresentation, .landing)
            }

            landingActionButton(metrics: metrics)
                .frame(height: FeaturePageTokens.primaryHeight)
        }
        .padding(inset)
#if DEBUG
        .layoutProbe("landing.configurationCard")
#endif
    }

    private func landingActionButton(metrics: LandingMetrics) -> some View {
        return Button(action: primaryAction) {
            Text(actionTitle)
#if DEBUG
                .layoutProbe("landing.actionText")
#endif
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(GradientButtonStyle(kind: .primary, size: FeaturePageTokens.primarySize, fillsWidth: true))
        .modifier(SmartScanFlowMatchModifier(namespace: flowNamespace))
        .disabled(isActionDisabled || (isLoading && !allowsActionWhileLoading))
        .accessibilityLabel(actionTitle)
#if DEBUG
        .layoutProbe(LayoutProbeID.landingActionButton)
#endif
    }

    private var primaryAction: () -> Void {
#if DEBUG
        if let demoPrimaryAction { return demoPrimaryAction }
#endif
        return action
    }

    private func builtInScopeGrid(availableWidth: CGFloat) -> some View {
        let nodes = builtInScopeNodes
        let isUpdateSourceList = systemImage == ReviewFilter.updater.systemImage
        let isApplicationScope = systemImage == ReviewFilter.uninstall.systemImage
        let usesInlineNodes = isUpdateSourceList || isApplicationScope
        let usesUpdateSourceRows = isUpdateSourceList && !layout.isCompactLanding && availableWidth >= 320
        let preferredColumns = usesUpdateSourceRows ? 1 : (usesInlineNodes ? 2 : min(2, max(1, nodes.count)))
        // The wider developer action column must not create four cramped
        // cards at intermediate widths. Keep complete rows at readable size.
        // 160 pt keeps an icon, a 100 pt title and the card padding under the
        // v2 page paddings (two update sources per row from 390 pt).
        let minimumNodeWidth: CGFloat = usesInlineNodes ? 160
            : (systemImage == ReviewFilter.devCaches.systemImage ? 108 : 92)
        let spacing = AppDesignTokens.Spacing.small
        let fittingColumns = max(1, Int((availableWidth + spacing) / (minimumNodeWidth + spacing)))
        // Four categories form complete rows. A three-column transition would
        // leave the final category isolated while the other row remains full.
        let fittedColumnCount = min(preferredColumns, fittingColumns)
        let columnCount = !usesInlineNodes && nodes.count == 4 && fittedColumnCount == 3
            ? 2 : fittedColumnCount
        return Grid(
            horizontalSpacing: AppDesignTokens.Spacing.small,
            verticalSpacing: isUpdateSourceList ? 6 : AppDesignTokens.Spacing.small
        ) {
            ForEach(0..<((nodes.count + columnCount - 1) / columnCount), id: \.self) { row in
                GridRow {
                    ForEach(Array(nodes.enumerated()).filter { $0.offset / columnCount == row }, id: \.offset) { index, node in
                let nodeLayout = usesInlineNodes
                    ? AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                    : AnyLayout(VStackLayout(alignment: .center, spacing: 8))
                // D64: display-only sources retain their labels without an icon slot.
                FeatureOptionCard(padding: isUpdateSourceList ? 0 : 12) {
                nodeLayout {
                    VStack(alignment: usesInlineNodes ? .leading : .center, spacing: 4) {
                    Text(node.title)
                        .font(AppDesignTokens.TypeScale.bodyEmphasis)
                        .foregroundStyle(surfaces.textPrimary)
                        .multilineTextAlignment(usesInlineNodes ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: usesInlineNodes ? .leading : .center)
#if DEBUG
                        .layoutProbe(LayoutProbeID.landingScopeTitle(index))
#endif

                    }
                    .frame(maxWidth: .infinity, alignment: usesInlineNodes ? .leading : .center)
                }
                // 80 pt fitted the icon above the title. Since D64 a card holds
                // one title, like the inline nodes, and the taller cards pushed
                // the page's real controls below the fold.
                .frame(maxWidth: .infinity, minHeight: 28)
                }
                .help(node.detail ?? node.title)
#if DEBUG
                .layoutProbe(LayoutProbeID.landingScopeCard(index))
#endif
                    }
                }
            }
        }
        // Scope sets contain at most four display-only categories. Lay them
        // all out so column changes preserve complete natural measurements.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var builtInScopeNodes: [FeatureScopeItem] {
        FeatureScopeCatalog(systemImage: systemImage, featureGroup: theme.featureGroup).items
    }

    private var showsBuiltInScopeGrid: Bool {
        switch theme.featureGroup {
        case .cleanup:
            !(systemImage == ReviewFilter.green.systemImage && configurationTitle != nil)
        case .protection:
            configurationTitle == nil
        case .applications:
            true
        case .performance:
            configurationTitle == nil && systemImage != ReviewFilter.energy.systemImage
        case .smartScan, .files, .settings:
            false
        }
    }

    private var defaultConfigurationTitle: String {
        switch theme.featureGroup {
        case .smartScan:
            L10n.text("扫描内容", "Scan Contents")
        case .cleanup:
            L10n.text("选择要扫描的项目", "Choose Items to Scan")
        case .protection:
            L10n.text("检查范围", "Check Scope")
        case .performance:
            L10n.text("检测项目", "Inspection Items")
        case .applications:
            systemImage == ReviewFilter.updater.systemImage
                ? L10n.text("更新来源", "Update Sources")
                : L10n.text("扫描范围", "Scan Scope")
        case .files:
            L10n.text("文件范围", "File Scope")
        case .settings:
            L10n.text("设置内容", "Settings")
        }
    }
}

// Source compatibility for existing callers and terminal pages. All initial
// pages use the same implementation; there is no per-feature layout profile.
typealias FileToolLandingPage<Accessory: View> = FeatureLandingTemplate<Accessory>

/// Geometry of the landing composition for one size class (UI-V2-SPEC
/// §2.3–2.4, adjusted by the main session's review of the V0 samples).
/// Pure values, so tests can check the breakpoints.
struct LandingMetrics: Equatable {
    let page: PageLayout
    let horizontalPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    /// Between the page header and the composition: 24 pt, 32 pt in large
    /// windows, 4 pt in short ones to preserve the dashboard's list row.
    let headerGap: CGFloat
    let sectionSpacing: CGFloat
    let columnSpacing: CGFloat
    let actionWidth: CGFloat
    let showsArtwork: Bool
    let artworkMaximumSide: CGFloat
    let cardInset: CGFloat
    let cardSpacing: CGFloat
    let minimumOptionsHeight: CGFloat
    let compactFooter: Bool
    let compactAction: Bool
    let actionSize: GradientButtonStyle.Size

    var headerHeight: CGFloat { page.heroForm(for: .landing).titleHeaderHeight }
    var footerHeight: CGFloat { compactFooter ? 36 : 56 }

    func compositionAreaSize(in size: CGSize) -> CGSize {
        CGSize(width: max(0, min(PageLayout.landingMaxWidth, size.width) - horizontalPadding * 2),
               height: max(0, size.height - topPadding - bottomPadding - footerHeight - sectionSpacing))
    }

    func compositionHeight(available: CGFloat) -> CGFloat {
        let chrome = 20 + 1 + cardSpacing * 3 + cardInset * 2 + FeaturePageTokens.primaryHeight
        let preferred = chrome + FeaturePageTokens.commonOptionsHeight
        return min(max(0, available), preferred, FeaturePageTokens.maximumColumnHeight)
    }

    /// The illustration column never drops below this width; under it the
    /// options card takes the full width (audit 6.1).
    static let artworkColumnMinimumWidth: CGFloat = 160

    init(page: PageLayout, size: CGSize, systemImage: String) {
        self.page = page
        let isShort = page.height == .short
        // §2.3: the large composition needs a wide or tall window *and* the
        // full-header height (680 pt); 560–679 pt keeps the regular sizes.
        let isLarge = page.usesLargeComposition
        horizontalPadding = page.pagePadding
        topPadding = isShort ? AppDesignTokens.Grid.x0_5 : AppDesignTokens.Grid.x1
        bottomPadding = isShort ? AppDesignTokens.Grid.x1 : page.pagePadding * 0.75
        headerGap = isShort ? AppDesignTokens.Grid.x0_5 : (isLarge ? AppDesignTokens.Grid.x4 : AppDesignTokens.Grid.x3)
        sectionSpacing = isShort ? AppDesignTokens.Grid.x0_5 : page.cardSpacing
        columnSpacing = isLarge ? AppDesignTokens.Grid.x5 : AppDesignTokens.Grid.x3
        let available = max(0, min(PageLayout.landingMaxWidth, size.width) - horizontalPadding * 2)
        // D62: geometry is solely a function of the viewport. Every feature
        // gets the same option card, primary action and illustration slot.
        showsArtwork = available >= FeaturePageTokens.twoColumnMinimumWidth
        actionWidth = showsArtwork ? min(600, available * 0.58) : available
        artworkMaximumSide = isShort ? 220 : (isLarge ? 560 : 420)
        cardInset = isShort ? AppDesignTokens.Grid.x1 : (isLarge ? AppDesignTokens.Grid.x3 : AppDesignTokens.Grid.x2)
        cardSpacing = isShort ? AppDesignTokens.Grid.x0_5 : (isLarge ? AppDesignTokens.Grid.x2 : AppDesignTokens.Grid.x1_5)
        minimumOptionsHeight = isShort ? 80 : 96
        compactFooter = isShort || page.width == .compact
        compactAction = false
        actionSize = .large
    }
}

/// The Smart Scan primary action and the progress card share one geometry
/// identity so the button morphs into the card when a scan starts (§3.2.3).
private struct SmartScanFlowNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var smartScanFlowNamespace: Namespace.ID? {
        get { self[SmartScanFlowNamespaceKey.self] }
        set { self[SmartScanFlowNamespaceKey.self] = newValue }
    }
}

struct SmartScanFlowMatchModifier: ViewModifier {
    static let identifier = "smartscan.primary-to-progress"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        // §3.1: under Reduce Motion the button and the card are not matched;
        // the page change is the plain fade.
        if let namespace, AppMotion.morphsGeometry(reduceMotion: reduceMotion) {
            content.matchedGeometryEffect(id: Self.identifier, in: namespace, properties: .frame, isSource: true)
        } else {
            content
        }
    }
}


/// Display-only option vocabulary. D64 deletes the obsolete drawing tree;
/// these labels still identify real supported sources in the option column.
private struct FeatureScopeCatalog {
    let systemImage: String
    let featureGroup: FeatureGroup
    var items: [FeatureScopeItem] {
        switch featureGroup {
        case .smartScan:
            return [
                node("trash.fill", L10n.text("可清理", "Cleanup"), .blue),
                node("doc.text.fill", L10n.text("需复核", "Review"), .purple),
                node("checkmark.shield.fill", L10n.text("健康状态", "Health"), .mint),
            ]
        case .cleanup:
            return featureGroup == .cleanup && systemImage == AppSymbols.Navigation.developerArtifacts
                ? [
                    node("chevron.left.forwardslash.chevron.right", L10n.text("代码工程", "Projects"), .orange),
                    node("terminal.fill", L10n.text("Agent", "Agents"), .purple),
                    node("bubble.left.and.bubble.right.fill", L10n.text("会话", "Sessions"), .cyan),
                    node("internaldrive.fill", L10n.text("产物", "Artifacts"), .green),
                ]
                : [
                    node("internaldrive.fill", L10n.text("缓存", "Caches"), .orange),
                    node("doc.text.fill", L10n.text("日志", "Logs"), .yellow),
                    node("clock.fill", L10n.text("临时文件", "Temporary"), .pink),
                    node("arrow.down.circle.fill", L10n.text("下载残留", "Download Remnants"), .blue),
                ]
        case .protection:
            if systemImage == ReviewFilter.healthHub.systemImage {
                return [
                    node("internaldrive.fill", L10n.text("磁盘", "Disk"), .mint, detail: L10n.text("健康状态、容量与错误记录", "Health, capacity, and errors")),
                    node("battery.75", L10n.text("电池", "Battery"), .green, detail: L10n.text("健康容量、循环与供电状态", "Capacity, cycles, and power source")),
                    node("waveform.path.ecg", L10n.text("系统状态", "System"), .cyan, detail: L10n.text("温度与关键系统状态", "Thermals and key system state")),
                ]
            }
            return [
                node("lock.shield.fill", L10n.text("隐私", "Privacy"), .green),
                node("globe", L10n.text("网站", "Websites"), .mint),
                node("clock.fill", L10n.text("时间", "Timeline"), .cyan),
                node("trash.fill", L10n.text("确认", "Review"), .teal),
            ]
        case .performance:
            if systemImage == ReviewFilter.startup.systemImage {
                return [
                    node("app.badge", L10n.text("登录项", "Login Items"), .pink),
                    node("bolt.horizontal.circle.fill", L10n.text("后台项", "Background"), .purple),
                    node("gearshape.2.fill", L10n.text("代理", "Agents"), .orange),
                    node("shield.fill", L10n.text("系统项", "System"), .cyan),
                ]
            }
            if systemImage == ReviewFilter.memory.systemImage {
                return [
                    node("memorychip.fill", L10n.text("内存", "Memory"), .purple),
                    node("app.fill", L10n.text("应用", "Apps"), .pink),
                    node("gauge.with.dots.needle.67percent", L10n.text("压力", "Pressure"), .orange),
                    node("arrow.left.arrow.right", L10n.text("交换", "Swap"), .cyan),
                ]
            }
            if systemImage == ReviewFilter.energy.systemImage {
                return [
                    node("bolt.fill", L10n.text("能耗", "Energy"), .pink),
                    node("battery.75", L10n.text("续航", "Battery"), .purple),
                    node("thermometer.medium", L10n.text("发热", "Thermals"), .orange),
                    node("moon.zzz.fill", L10n.text("后台", "Background"), .cyan),
                ]
            }
            return [
                node("cpu.fill", "CPU", .pink),
                node("rectangle.3.group.fill", "GPU", .purple),
                node("memorychip", L10n.text("内存", "Memory"), .cyan),
                node("internaldrive", L10n.text("存储", "Storage"), .orange),
            ]
        case .applications:
            if systemImage == ReviewFilter.updater.systemImage {
                return [
                    node("bag.fill", L10n.text("App Store", "App Store"), .cyan, detail: L10n.text("由系统商店管理的应用", "Apps managed by the system store")),
                    node("arrow.triangle.2.circlepath", L10n.text("Sparkle", "Sparkle"), .purple, detail: L10n.text("读取应用提供的更新源", "Read the app-provided update feed")),
                    node("globe", L10n.text("官网", "Website"), .teal, detail: L10n.text("检查可识别的官方版本信息", "Check recognized official version information")),
                    node("shippingbox.fill", L10n.text("Homebrew", "Homebrew"), .blue, detail: L10n.text("检查已安装的软件包来源", "Check installed package sources")),
                ]
            }
            return [
                node("app.fill", L10n.text("应用本体", "App Bundle"), .cyan),
                node("folder.fill", L10n.text("关联文件", "Related"), .blue),
                node("doc.fill", L10n.text("支持文件", "Support"), .teal),
                node("shippingbox.fill", L10n.text("容器", "Containers"), .mint),
            ]
        case .files:
            if systemImage == ReviewFilter.migration.systemImage {
                return [
                    node("folder.fill", L10n.text("来源", "Source"), .purple),
                    node("checkmark.shield.fill", L10n.text("验证", "Verify"), .cyan),
                    node("arrow.right", L10n.text("搬移", "Move"), .mint),
                    node("externaldrive.fill", L10n.text("目标", "Destination"), .orange),
                ]
            }
            if systemImage == ReviewFilter.duplicates.systemImage {
                return [
                    node("doc.on.doc.fill", L10n.text("文档", "Documents"), .purple),
                    node("photo.on.rectangle.angled", L10n.text("照片", "Photos"), .pink),
                    node("video.fill", L10n.text("视频", "Videos"), .blue),
                    node("waveform", L10n.text("音频", "Audio"), .orange),
                ]
            }
            return [
                node("doc.fill", L10n.text("文档", "Documents"), .blue),
                node("photo.fill", L10n.text("媒体", "Media"), .pink),
                node("archivebox.fill", L10n.text("归档", "Archives"), .orange),
                node("puzzlepiece.fill", L10n.text("其他", "Other"), .green),
            ]
        case .settings:
            return [
                node("gearshape.fill", L10n.text("通用", "General"), .gray),
                node("paintpalette.fill", L10n.text("外观", "Appearance"), .purple),
                node("bell.fill", L10n.text("通知", "Alerts"), .orange),
                node("arrow.up.circle.fill", L10n.text("更新", "Updates"), .blue),
            ]
        }
    }


    private func node(_ systemImage: String, _ title: String, _ tint: Color,
                      detail: String? = nil) -> FeatureScopeItem {
        FeatureScopeItem(systemImage: systemImage, title: title, tint: tint, detail: detail)
    }
}
private struct FeatureScopeItem {
    let systemImage: String
    let title: String
    let tint: Color
    let detail: String?
}

private struct LandingHeaderActionKey: EnvironmentKey {
    static var defaultValue: AnyView? { nil }
}

extension EnvironmentValues {
    var landingHeaderAction: AnyView? {
        get { self[LandingHeaderActionKey.self] }
        set { self[LandingHeaderActionKey.self] = newValue }
    }
}

// Frozen V0 compatibility for SmartScanTerminalPage only. D62 explicitly
// excludes cancellation/failure/completion pages; V2–V4 can migrate/remove it.
struct LegacyTerminalLandingPage<Accessory: View>: View {
    @Environment(\.landingHeaderAction) private var headerAction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    @Environment(\.smartScanFlowNamespace) private var flowNamespace
    @Environment(\.landingStateArt) private var stateArt
    @AppSurfaces private var surfaces
    @State private var optionsContentHeight: CGFloat?

    let title: String
    let subtitle: String
    let systemImage: String
    let configurationTitle: String?
    let actionTitle: String
    let actionDetail: String
    let actionSystemImage: String
    let status: ScanStatusPresentation
    let isLoading: Bool
    let isActionDisabled: Bool
    let allowsActionWhileLoading: Bool
    let trustText: String
    let action: () -> Void
    private let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        configurationTitle: String?,
        actionTitle: String,
        actionDetail: String,
        actionSystemImage: String,
        status: ScanStatusPresentation,
        isLoading: Bool = false,
        isActionDisabled: Bool = false,
        allowsActionWhileLoading: Bool = false,
        trustText: String,
        action: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.configurationTitle = configurationTitle
        self.actionTitle = actionTitle
        self.actionDetail = actionDetail
        self.actionSystemImage = actionSystemImage
        self.status = status
        self.isLoading = isLoading
        self.isActionDisabled = isActionDisabled
        self.allowsActionWhileLoading = allowsActionWhileLoading
        self.trustText = trustText
        self.action = action
        self.accessory = accessory()
    }

    /// D63: bounded content and artwork share one canvas and form a centered
    /// composition. Only options scroll; the primary action and integrated
    /// status line remain visible down to the 338 pt tiled detail viewport.
    var body: some View {
        GeometryReader { proxy in
            let page = pageLayout ?? PageLayout.resolve(size: proxy.size)
            let metrics = LegacyTerminalLandingMetrics(page: page, size: proxy.size, systemImage: systemImage)
            VStack(alignment: .leading, spacing: 0) {
                landingHeader
#if DEBUG
                .layoutProbe(LayoutProbeID.landingHeader)
#endif

                landingBody(metrics: metrics)
                    .padding(.top, metrics.headerGap)
                    .padding(.bottom, metrics.sectionSpacing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                StatusFooter(status: status, trustText: trustText, isCompact: metrics.compactFooter)
#if DEBUG
                    .layoutProbe(LayoutProbeID.landingFooter)
#endif
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, metrics.topPadding)
            .padding(.bottom, metrics.bottomPadding)
            .frame(maxWidth: PageLayout.landingMaxWidth, maxHeight: .infinity, alignment: .top)
#if DEBUG
            .layoutProbe(LayoutProbeID.landingCanvas)
#endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .pageOwnsScrolling()
        .tint(theme.actionFill)
        // The action belongs to this page's header only; a landing page
        // nested in the accessory must not show it a second time.
        .environment(\.landingHeaderAction, nil)
#if DEBUG
        .layoutProbe(LayoutProbeID.landingRoot)
#endif
    }

    @ViewBuilder
    private var landingHeader: some View {
        if let headerAction {
            AppPageHeader(title: title, subtitle: subtitle, systemImage: systemImage,
                          isHero: true, role: .landing) {
                headerAction
            }
        } else {
            // No header action: an EmptyView header reserves no action row.
            AppPageHeader(title: title, subtitle: subtitle, systemImage: systemImage,
                          isHero: true, role: .landing) {
                EmptyView()
            }
        }
    }

    private func landingBody(metrics: LegacyTerminalLandingMetrics) -> some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            configurationPanel(availableWidth: metrics.actionWidth, metrics: metrics)
                .frame(width: metrics.actionWidth)
                .layoutPriority(1)

            if metrics.showsArtwork {
                landingArtwork
                    .frame(maxWidth: metrics.artworkMaximumSide, maxHeight: metrics.artworkMaximumSide)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
#if DEBUG
                    .layoutProbe(LayoutProbeID.landingArtwork)
#endif
            }
        }
        // The composition sits right under the header; the illustration
        // takes the free height it can use (review 2: no centering between
        // the header and the status bar).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var landingArtwork: some View {
        if let stateArt {
            StateLandingArtwork(art: stateArt, fallbackSystemImage: systemImage)
        } else if theme.featureGroup == .smartScan {
            OrbitLandingArtwork.smartScan()
        } else {
            // D58: the module's generated mark at the center of the shared
            // orbit drawing; its nodes are the page's scope items. The sweep
            // turns only while the page works (§3.3).
            OrbitLandingArtwork.module(
                systemImage: systemImage,
                isActive: isLoading
            )
            .overlay(alignment: .topTrailing) {
                if systemImage == ReviewFilter.duplicates.systemImage {
                    GoldenUnmeasuredCapacity().padding(.top, 6)
                }
            }
        }
    }

    private func configurationPanel(availableWidth: CGFloat, metrics: LegacyTerminalLandingMetrics) -> some View {
        let separateAction = systemImage == ReviewFilter.largeFiles.systemImage
        let inset = metrics.cardInset
        return VStack(spacing: separateAction ? 16 : 0) {
            VStack(alignment: .leading, spacing: metrics.cardSpacing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.cardSpacing) {
                        if configurationTitle != nil || showsBuiltInScopeGrid {
                            HStack(spacing: AppDesignTokens.Grid.x1) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(surfaces.textSecondary)
                                    .accessibilityHidden(true)
                                Text(configurationTitle ?? defaultConfigurationTitle)
                                    .font(AppDesignTokens.TypeScale.sectionTitle)
                                    .foregroundStyle(surfaces.textPrimary)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            Rectangle()
                                .fill(surfaces.divider)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                            if showsBuiltInScopeGrid {
                                builtInScopeGrid(availableWidth: availableWidth - inset * 2)
                            }
                            if configurationTitle != nil { accessory }
                        }
                        if !actionDetail.isEmpty {
                            Text(actionDetail)
                                .font(AppDesignTokens.TypeScale.secondary)
                                .foregroundStyle(surfaces.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 2)
                    .background {
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: LandingOptionsHeightPreferenceKey.self,
                                value: contentProxy.size.height
                            )
                        }
                    }
#if DEBUG
                    .layoutProbe("landing.optionsContent")
#endif
                }
                .scrollIndicators(.automatic)
                // Keep one scroll container across resizes. Its content supplies
                // the ideal height; the parent can still reduce the viewport
                // without moving the action into the scrollable region.
                .frame(minHeight: metrics.minimumOptionsHeight,
                       maxHeight: optionsContentHeight.map { max(metrics.minimumOptionsHeight, $0) })
                .onPreferenceChange(LandingOptionsHeightPreferenceKey.self) { height in
                    guard height.isFinite, height >= 0,
                          optionsContentHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
                    optionsContentHeight = height
                }
#if DEBUG
                .layoutProbe("landing.optionsViewport")
#endif
                if !separateAction {
                    landingActionButton(metrics: metrics)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(inset)
            .background {
                SurfaceBackground(level: .card, cornerRadius: AppDesignTokens.Corner.card)
            }
            .frame(maxWidth: .infinity, minHeight: 0)
#if DEBUG
            .layoutProbe("landing.configurationCard")
#endif
            if separateAction {
                landingActionButton(metrics: metrics)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.landingContent)
        .layoutProbe(LayoutProbeID.landingActionPanel)
#endif
    }

    private func landingActionButton(metrics: LegacyTerminalLandingMetrics) -> some View {
        let usesEmblem = systemImage == ReviewFilter.overview.systemImage && actionSystemImage == "magnifyingglass"
        return Button(action: action) {
            PrimaryActionLabel(
                title: actionTitle,
                systemImage: actionSystemImage,
                isLoading: isLoading && !allowsActionWhileLoading,
                usesSmartScanEmblem: usesEmblem,
                isCompact: metrics.compactAction
            )
        }
        .buttonStyle(GradientButtonStyle(kind: .primary, size: metrics.actionSize, fillsWidth: true))
        .modifier(SmartScanFlowMatchModifier(namespace: theme.featureGroup == .smartScan ? flowNamespace : nil))
        .disabled(isActionDisabled || (isLoading && !allowsActionWhileLoading))
        .accessibilityLabel(actionTitle)
#if DEBUG
        .layoutProbe(LayoutProbeID.landingActionButton)
#endif
    }

    private func builtInScopeGrid(availableWidth: CGFloat) -> some View {
        let nodes = builtInScopeNodes
        let isUpdateSourceList = systemImage == ReviewFilter.updater.systemImage
        let isApplicationScope = systemImage == ReviewFilter.uninstall.systemImage
        let usesInlineNodes = isUpdateSourceList || isApplicationScope
        let usesUpdateSourceRows = isUpdateSourceList && !layout.isCompactLanding && availableWidth >= 320
        let preferredColumns = usesUpdateSourceRows ? 1 : (usesInlineNodes ? 2 : min(4, max(1, nodes.count)))
        // The wider developer action column must not create four cramped
        // cards at intermediate widths. Keep complete rows at readable size.
        // 160 pt keeps an icon, a 100 pt title and the card padding under the
        // v2 page paddings (two update sources per row from 390 pt).
        let minimumNodeWidth: CGFloat = usesInlineNodes ? 160
            : (systemImage == ReviewFilter.devCaches.systemImage ? 100 : 92)
        let spacing = AppDesignTokens.Spacing.small
        let fittingColumns = max(1, Int((availableWidth + spacing) / (minimumNodeWidth + spacing)))
        // Four categories form complete rows. A three-column transition would
        // leave the final category isolated while the other row remains full.
        let fittedColumnCount = min(preferredColumns, fittingColumns)
        let columnCount = !usesInlineNodes && nodes.count == 4 && fittedColumnCount == 3
            ? 2 : fittedColumnCount
        return Grid(
            horizontalSpacing: AppDesignTokens.Spacing.small,
            verticalSpacing: isUpdateSourceList ? 6 : AppDesignTokens.Spacing.small
        ) {
            ForEach(0..<((nodes.count + columnCount - 1) / columnCount), id: \.self) { row in
                GridRow {
                    ForEach(Array(nodes.enumerated()).filter { $0.offset / columnCount == row }, id: \.offset) { index, node in
                let nodeLayout = usesInlineNodes
                    ? AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                    : AnyLayout(VStackLayout(alignment: .center, spacing: 8))
                let tileSide: CGFloat = isUpdateSourceList ? 30 : (usesInlineNodes ? 36 : 44)
                nodeLayout {
                    IconTile(
                        systemImage: node.systemImage,
                        side: tileSide,
                        pigment: scopePigment(index: index)
                    )
#if DEBUG
                        .layoutProbe(LayoutProbeID.landingScopeIcon(index))
#endif
                    VStack(alignment: usesInlineNodes ? .leading : .center, spacing: 4) {
                    Text(node.title)
                        .font(AppDesignTokens.TypeScale.bodyEmphasis)
                        .foregroundStyle(surfaces.textPrimary)
                        .multilineTextAlignment(usesInlineNodes ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: usesInlineNodes ? .leading : .center)
#if DEBUG
                        .layoutProbe(LayoutProbeID.landingScopeTitle(index))
#endif
                    if let detail = node.detail, !isUpdateSourceList {
                        Text(detail)
                            .font(AppDesignTokens.TypeScale.caption)
                            .foregroundStyle(surfaces.textSecondary)
                            .multilineTextAlignment(usesInlineNodes ? .leading : .center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: usesInlineNodes ? .leading : .center)
                }
                .padding(.horizontal, AppDesignTokens.Spacing.small)
                .padding(.vertical, usesInlineNodes ? 6 : 10)
                .frame(maxWidth: .infinity, minHeight: isUpdateSourceList ? (usesUpdateSourceRows ? 56 : 42) : (usesInlineNodes ? 52 : (systemImage == ReviewFilter.devCaches.systemImage ? 114 : 104)))
                .help(node.detail ?? node.title)
                .background {
                    SurfaceBackground(level: .inset, cornerRadius: AppDesignTokens.Corner.inset)
                }
#if DEBUG
                .layoutProbe(LayoutProbeID.landingScopeCard(index))
#endif
                    }
                }
            }
        }
        // Scope sets contain at most four display-only categories. Lay them
        // all out so column changes preserve complete natural measurements.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Scope tiles share the page's pigment family: the module gradient for
    /// the first tile, neighbouring module pigments for the rest (audit 4.2
    /// item 3: tile colors must relate to the module, not random hues).
    private func scopePigment(index: Int) -> ModulePigment {
        let base = theme.isImmersive ? theme.pigment : .neutral
        let companions: [ModulePigment] = [base, .memory, .files, .protection]
        return companions[max(0, index) % companions.count]
    }

    private var builtInScopeNodes: [FeatureScopeItem] {
        FeatureScopeCatalog(systemImage: systemImage, featureGroup: theme.featureGroup).items
    }

    private var showsBuiltInScopeGrid: Bool {
        switch theme.featureGroup {
        case .cleanup:
            !(systemImage == ReviewFilter.green.systemImage && configurationTitle != nil)
        case .protection:
            configurationTitle == nil
        case .applications:
            true
        case .performance:
            systemImage != ReviewFilter.energy.systemImage
        case .smartScan, .files, .settings:
            false
        }
    }

    private var defaultConfigurationTitle: String {
        switch theme.featureGroup {
        case .smartScan:
            L10n.text("扫描内容", "Scan Contents")
        case .cleanup:
            L10n.text("选择要扫描的项目", "Choose Items to Scan")
        case .protection:
            L10n.text("检查范围", "Check Scope")
        case .performance:
            L10n.text("检测项目", "Inspection Items")
        case .applications:
            systemImage == ReviewFilter.updater.systemImage
                ? L10n.text("更新来源", "Update Sources")
                : L10n.text("扫描范围", "Scan Scope")
        case .files:
            L10n.text("文件范围", "File Scope")
        case .settings:
            L10n.text("设置内容", "Settings")
        }
    }
}

/// Geometry of the landing composition for one size class (UI-V2-SPEC
/// §2.3–2.4, adjusted by the main session's review of the V0 samples).
/// Pure values, so tests can check the breakpoints.
struct LegacyTerminalLandingMetrics: Equatable {
    let page: PageLayout
    let horizontalPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    /// Between the page header and the composition: 24 pt, 32 pt in large
    /// windows, 8 pt in short ones.
    let headerGap: CGFloat
    let sectionSpacing: CGFloat
    let columnSpacing: CGFloat
    let actionWidth: CGFloat
    let showsArtwork: Bool
    let artworkMaximumSide: CGFloat
    let cardInset: CGFloat
    let cardSpacing: CGFloat
    let minimumOptionsHeight: CGFloat
    let compactFooter: Bool
    let compactAction: Bool
    let actionSize: GradientButtonStyle.Size

    /// The illustration column never drops below this width; under it the
    /// options card takes the full width (audit 6.1).
    static let artworkColumnMinimumWidth: CGFloat = 240

    init(page: PageLayout, size: CGSize, systemImage: String) {
        self.page = page
        let isShort = page.height == .short
        // §2.3: the large composition needs a wide or tall window *and* the
        // full-header height (680 pt); 560–679 pt keeps the regular sizes.
        let isLarge = page.usesLargeComposition
        horizontalPadding = page.pagePadding
        topPadding = isShort ? AppDesignTokens.Grid.x0_5 : AppDesignTokens.Grid.x1
        bottomPadding = isShort ? AppDesignTokens.Grid.x1_5 : page.pagePadding * 0.75
        headerGap = isShort ? AppDesignTokens.Grid.x1 : (isLarge ? AppDesignTokens.Grid.x4 : AppDesignTokens.Grid.x3)
        sectionSpacing = isShort ? AppDesignTokens.Grid.x1 : page.cardSpacing
        let profile = GoldenLandingMetrics.profile(for: systemImage)
        columnSpacing = isLarge ? AppDesignTokens.Grid.x5 : AppDesignTokens.Grid.x3
        let contentWidth = min(PageLayout.landingMaxWidth, max(0, size.width)) - horizontalPadding * 2
        let available = max(0, contentWidth)
        // Large windows: the card grows to 560–600 pt (review 3).
        let fraction = isLarge ? max(profile.actionFraction, 0.46) : profile.actionFraction
        let maximum = isLarge
            ? max(600, GoldenLandingMetrics.actionColumnMaximumWidth(for: systemImage))
            : GoldenLandingMetrics.actionColumnMaximumWidth(for: systemImage)
        let preferred = max(profile.minimumActionWidth, min(maximum, available * fraction))
        let artworkColumn = available - preferred - columnSpacing
        // §2.3: no illustration when the options need the width (compact
        // class, or a column under 240 pt). Short windows keep it beside the
        // card, where it takes no height from the options.
        showsArtwork = page.width >= .regular
            && artworkColumn >= Self.artworkColumnMinimumWidth
        actionWidth = showsArtwork ? preferred : available
        // Review 1: 380–420 pt in regular windows, 480–560 pt when wide or
        // tall, at most 220 pt when short (§2.3 keeps the regular size
        // small); the column and the free height still bound it.
        artworkMaximumSide = isShort ? 220 : (isLarge ? 560 : 420)
        cardInset = isShort ? AppDesignTokens.Grid.x1_5 : (isLarge ? AppDesignTokens.Grid.x3 : AppDesignTokens.Grid.x2)
        cardSpacing = isShort ? AppDesignTokens.Grid.x1 : (isLarge ? AppDesignTokens.Grid.x2 : AppDesignTokens.Grid.x1_5)
        minimumOptionsHeight = isShort ? 80 : 96
        compactFooter = isShort || page.width == .compact
        compactAction = isShort
        actionSize = isShort ? .medium : (isLarge ? .hero : .large)
    }
}

private struct LandingOptionsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
