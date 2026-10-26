import SwiftUI

/// The main window sidebar, laid out as CleanMyMac 5.7.2's (D154): its ten
/// modules in its order, eight at the top and My Tools / My Activity at the
/// foot, without group titles. A row opens the module's first page and
/// stays selected on every page of the module (`CareStudioFamily`). On a
/// studio page the sidebar sits on the module gradient (D141); pages not yet
/// moved to the studio keep the classic surface. Below 960 pt, and while a
/// studio page scans or shows results, it folds to icons.
struct SidebarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The classic pages keep the classic sidebar.
    @Environment(\.careStudioClassicResults) private var usesClassicPages
    @AppStorage(AppCanvasTheme.defaultsKey) private var canvasThemeRawValue = AppCanvasTheme.defaultTheme.rawValue
    @ObservedObject var store: ScanStore
    @ObservedObject private var navigationState: AppNavigationState
    @ObservedObject private var largeFilesWorkspace: LargeFilesStore
    @ObservedObject private var duplicateFilesWorkspace: DuplicateFilesStore
    /// Report §4 item 16: what the module marks read besides the store.
    @ObservedObject private var smartCare: SmartCareCoordinator
    @ObservedObject private var privacy: BrowserPrivacyStore
    @ObservedObject private var malware: MalwareScanStore
    @ObservedObject private var cloud: CloudCleanupModel
    /// Report §4 item 20: the new tools opened from My Tools.
    @AppStorage(MyToolsCatalog.triedDefaultsKey) private var triedToolsRaw = ""
    @Binding var selection: ReviewFilter
    private let presentation: SidebarPresentation
    private let onTogglePresentation: (() -> Void)?
    @Namespace private var selectionNamespace
    /// The drawn selection. It follows the real selection inside an
    /// animation so the block slides; Reduce Motion places it at once.
    @State private var highlightedFamily: CareStudioFamily?

    init(
        store: ScanStore,
        selection: Binding<ReviewFilter>,
        presentation: SidebarPresentation = .full,
        onTogglePresentation: (() -> Void)? = nil,
        privacy: BrowserPrivacyStore? = nil,
        malware: MalwareScanStore? = nil
    ) {
        self.store = store
        _navigationState = ObservedObject(wrappedValue: store.navigationState)
        _largeFilesWorkspace = ObservedObject(wrappedValue: store.largeFilesWorkspace)
        _duplicateFilesWorkspace = ObservedObject(wrappedValue: store.duplicateFilesWorkspace)
        _smartCare = ObservedObject(wrappedValue: SmartCareCoordinator.of(store))
        _privacy = ObservedObject(wrappedValue: privacy ?? BrowserPrivacyStore())
        _malware = ObservedObject(wrappedValue: malware ?? MalwareScanStore())
        _cloud = ObservedObject(wrappedValue: CloudCleanupModel.shared)
        _selection = selection
        self.presentation = presentation
        self.onTogglePresentation = onTogglePresentation
    }

    private var isRail: Bool { presentation == .rail }

    /// The module of the page on screen; a page Smart Care's Review opened
    /// is Smart Care's (D202).
    private var currentFamily: CareStudioFamily {
        if navigationState.smartCareReview != nil { return .smartCare }
        return CareStudioFamily(route: navigationState.selectedFilter, utility: navigationState.selectedUtilityFilter)
    }

    /// The gradient under the sidebar: the module's, on a studio page.
    private var studioFamily: CareStudioFamily? {
        guard !usesClassicPages else { return nil }
        return CareStudioModule(route: navigationState.selectedFilter,
                                utility: navigationState.selectedUtilityFilter)?.family
    }

    var body: some View {
        SidebarChrome(isRail: isRail, family: studioFamily,
                      usesLightfield: FeatureLightfield.owns(navigationState.selectedFilter)) {
            GeometryReader { proxy in
                let metrics = SidebarRowMetrics(height: proxy.size.height, isRail: isRail)
                VStack(spacing: 0) {
                    // The rows fit at any supported window height; a window
                    // tiled below the minimum scrolls them instead, with the
                    // list fading above the foot (§2.2).
                    ViewThatFits(in: .vertical) {
                        moduleList(metrics)
                        ScrollView(.vertical) { moduleList(metrics) }
                            .scrollIndicators(.never)
                            .mask { SidebarScrollFade() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)

                    VStack(alignment: isRail ? .center : .leading, spacing: metrics.spacing) {
                        ForEach(CareStudioFamily.allCases.filter(\.isFooter)) { family in
                            row(family, metrics: metrics)
                        }
                        footerLine
                    }
                    .padding(.horizontal, isRail ? 8 : 12)
                    .padding(.bottom, 10)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .environment(\.canvasTheme, AppCanvasTheme.resolve(rawValue: canvasThemeRawValue))
        .onAppear { highlightedFamily = currentFamily }
        .onChange(of: currentFamily) { _, family in
            withAnimation(AppMotion.selection(reduceMotion: reduceMotion)) {
                highlightedFamily = family
            }
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.smartScanSidebar)
#endif
    }

    private func moduleList(_ metrics: SidebarRowMetrics) -> some View {
        VStack(alignment: isRail ? .center : .leading, spacing: metrics.spacing) {
            ForEach(CareStudioFamily.allCases.filter { !$0.isFooter }) { family in
                row(family, metrics: metrics)
            }
        }
        .padding(.horizontal, isRail ? 8 : 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
    }

    private func row(_ family: CareStudioFamily, metrics: SidebarRowMetrics) -> some View {
        SidebarModuleRow(
            family: family,
            isSelected: currentFamily == family,
            isHighlighted: highlightedFamily == family,
            badge: badge(family),
            showsNewTag: family == .myTools
                && MyToolsCatalog.hasUntriedNewTool(tried: MyToolsCatalog.ids(from: triedToolsRaw)),
            onStudio: studioFamily != nil,
            isRail: isRail,
            rowHeight: metrics.rowHeight,
            namespace: selectionNamespace
        ) {
            select(family)
        }
    }

    /// The version line, with the fold button (CleanMyMac has no fold
    /// button; ours stays at the foot, out of the module list).
    @ViewBuilder
    private var footerLine: some View {
        if isRail {
            sidebarToggleButton
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 6) {
                Text(SidebarVersionLabel.text)
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(studioFamily != nil ? CareStudioInk.tertiary : AppDesignTokens.Palette.sidebarSecondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(SidebarVersionLabel.text)
                Spacer(minLength: 0)
                sidebarToggleButton
            }
            .padding(.leading, 10)
        }
    }

    @ViewBuilder
    private var sidebarToggleButton: some View {
        if let onTogglePresentation {
            let title = isRail
                ? L10n.text("展开侧栏", "Expand Sidebar")
                : L10n.text("收成图标栏", "Collapse to Icons")
            AppIconButton(
                title: title,
                systemImage: isRail ? "sidebar.leading" : "sidebar.squares.leading",
                tint: studioFamily != nil ? CareStudioInk.secondary : AppDesignTokens.Palette.sidebarSecondaryText
            ) {
                onTogglePresentation()
            }
            .help(title)
            .accessibilityLabel(title)
        }
    }

    private func select(_ family: CareStudioFamily) {
        Task { @MainActor in
            let route = family.primaryRoute
            // D202: a row ends Smart Care's Review, its own page's row too.
            navigationState.endSmartCareReview()
            if route == .duplicates {
                duplicateFilesWorkspace.resultFilter = .all
            }
            selection = route
        }
    }

    /// Report §4 item 16: CleanMyMac's marks on the module icons — how far a
    /// scan is, Smart Scan's results waiting, a module's results (was: a
    /// turning ring while a module scanned).
    private func badge(_ family: CareStudioFamily) -> SidebarBadge? {
        SidebarBadge.badge(for: family, SidebarBadgeInputs(store: store, smartCare: smartCare, privacy: privacy,
                                                           malware: malware, cloud: cloud))
    }
}

/// Row height and spacing: CleanMyMac's 50 pt pitch where the window is tall
/// enough, tighter in short windows so all ten modules stay visible.
struct SidebarRowMetrics: Equatable {
    let rowHeight: CGFloat
    let spacing: CGFloat

    static let pitch: CGFloat = 50
    static let minimumPitch: CGFloat = 36

    init(height: CGFloat, isRail: Bool) {
        // The foot keeps the version line (or the fold button) and padding.
        let reserved: CGFloat = isRail ? 64 : 52
        let rows = CGFloat(CareStudioFamily.allCases.count)
        let available = max(0, height - reserved) / rows
        let pitch = min(Self.pitch, max(Self.minimumPitch, available.rounded(.down)))
        spacing = pitch >= 44 ? 6 : 2
        rowHeight = pitch - spacing
    }
}

/// Sidebar canvas and its trailing edge.
private struct SidebarChrome<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.canvasTheme) private var canvasTheme
    @AppSurfaces private var surfaces
    let isRail: Bool
    /// D141/D154: the module whose gradient the sidebar sits on.
    let family: CareStudioFamily?
    /// D67 pages always use the light-field sidebar tokens. V1 pages follow
    /// the chosen canvas theme, so pure black keeps its own sidebar colour.
    var usesLightfield = true
    @ViewBuilder let content: Content

    private var followsPureBlack: Bool { !usesLightfield && scheme == .dark && canvasTheme == .pureBlack }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                Group {
                    if let family {
                        // CleanMyMac's sidebar is transparent over the module
                        // colour; a light veil keeps its rows apart from the page.
                        ZStack {
                            CareStudioBackdrop(family: family)
                            CareStudioInk.sidebarVeil
                        }
                    } else if followsPureBlack { surfaces.sidebar }
                    else { FeatureLightfieldPalette.color(FeatureLightfieldPalette.resolve(scheme).sidebar) }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(family != nil ? Color.white.opacity(0.08)
                        : followsPureBlack ? surfaces.divider
                        : FeatureLightfieldPalette.color(scheme == .dark ? 0xFFFFFF : 0x162850).opacity(FeatureLightfieldPalette.resolve(scheme).sidebarLine))
                    .frame(width: 1)
                    .accessibilityHidden(true)
            }
    }
}

/// Fades the list above the foot (§2.2).
private struct SidebarScrollFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 6)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
        }
        .accessibilityHidden(true)
    }
}

/// One module: its glossy mark and name. CleanMyMac draws the idle marks as
/// pale glass and the current one in colour, on a translucent block.
private struct SidebarModuleRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppSurfaces private var surfaces

    let family: CareStudioFamily
    /// The real selection (accessibility).
    let isSelected: Bool
    /// The drawn selection, which slides in an animation.
    let isHighlighted: Bool
    let badge: SidebarBadge?
    /// Report §4 item 20: CleanMyMac's "New" on My Tools while a new tool
    /// is untried (`cmm/09`).
    let showsNewTag: Bool
    let onStudio: Bool
    let isRail: Bool
    let rowHeight: CGFloat
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    private var textColor: Color {
        if onStudio { return CareStudioInk.primary }
        return isHighlighted ? .white : surfaces.textPrimary
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isRail {
                    markedGlyph
                        .frame(width: 44, height: rowHeight)
                } else {
                    HStack(spacing: 12) {
                        markedGlyph
                        Text(family.title)
                            .font(.system(size: 15, weight: isHighlighted ? .medium : .regular))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: rowHeight)
                }
            }
            .foregroundStyle(textColor)
            .contentShape(RoundedRectangle(cornerRadius: SidebarModuleRow.corner, style: .continuous))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .background {
            ZStack {
                if !isHighlighted {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .fill(isHovered ? (onStudio ? CareStudioInk.sidebarHover : surfaces.hover) : .clear)
                }
                if isHighlighted {
                    SidebarSelectionBlock(family: family, onStudio: onStudio)
                        .matchedGeometryEffect(id: "sidebar.selection", in: namespace)
                }
            }
        }
        .frame(maxWidth: isRail ? nil : .infinity, alignment: .leading)
        .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .help(isRail ? family.title : family.summary)
        .accessibilityLabel(family.title)
        .accessibilityHint(family.summary)
        .accessibilityValue(accessibilityStatus)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The selection and the mark, as VoiceOver reads them.
    private var accessibilityStatus: String {
        [isSelected ? L10n.text("已选择", "Selected") : nil, badge?.accessibilityText,
         showsNewTag ? L10n.text("有新工具", "New tools") : nil]
            .compactMap { $0 }
            .joined(separator: L10n.text("，", ", "))
    }

    static let corner: CGFloat = 12
    static let glyphSide: CGFloat = 26

    /// Our D58 mark turned to the module colour; idle marks drop most of
    /// their colour on the dark gradient, as CleanMyMac's do.
    private var glyph: some View {
        let idleOnNight = onStudio && colorScheme == .dark
        return FeatureLightfieldArtwork(art: family.art, variant: .header)
            .hueRotation(family.artHueRotation)
            .saturation(isHighlighted ? 1 : (idleOnNight ? 0.18 : 0.75))
            .brightness(isHighlighted || !idleOnNight ? 0 : 0.06)
            .frame(width: Self.glyphSide, height: Self.glyphSide)
            .accessibilityHidden(true)
    }

    /// The mark with its badge on the corner, in the rail and the full
    /// sidebar alike (CleanMyMac, `cmm/15`–`24`): the badge's centre on the
    /// mark's trailing edge, 6 pt above its top. "New" is centred on the
    /// mark's top-leading corner (`cmm/09`).
    private var markedGlyph: some View {
        glyph
            .overlay(alignment: .topTrailing) {
                if let badge {
                    SidebarBadgeMark(badge: badge)
                        .offset(x: SidebarBadgeMark.diameter / 2, y: -(SidebarBadgeMark.diameter / 2 + 6))
                }
            }
            .overlay(alignment: .topLeading) {
                if showsNewTag {
                    CareStudioNewTag()
                        .alignmentGuide(.leading) { $0.width / 2 }
                        .alignmentGuide(.top) { $0.height / 2 }
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The current module. On a studio gradient it is CleanMyMac's translucent
/// block; on the classic surface it keeps D3's module-colour block.
private struct SidebarSelectionBlock: View {
    @AppSurfaces private var surfaces
    let family: CareStudioFamily
    let onStudio: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarModuleRow.corner, style: .continuous)
        Group {
            if onStudio {
                shape
                    .fill(CareStudioInk.sidebarSelection)
                    .overlay { shape.strokeBorder(CareStudioInk.hairline, lineWidth: 1) }
            } else {
                let pigment = family.primaryRoute.moduleTheme.pigment
                shape
                    .fill(LinearGradient(colors: pigment.gradientStops, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        shape.strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                    }
                    .shadow(color: surfaces.isNight ? pigment.brightColor.opacity(0.32) : .black.opacity(0.10),
                            radius: surfaces.isNight ? 10 : 4, y: surfaces.isNight ? 0 : 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The Settings sidebar row surface (DECISIONS D3 补充): a themed fill and
/// stroke when selected, the shared hover fill otherwise. `isEmphasized`
/// marks the selection of a sidebar that has keyboard focus.
struct SidebarRowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let isSelected: Bool
    let isHovered: Bool
    let selectionColor: Color
    var isEmphasized = false

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: AppDesignTokens.Radius.sidebarRow,
            style: .continuous
        )
        if isSelected {
            shape
                .fill(selectionColor.opacity(colorScheme == .dark ? 0.26 : 0.14))
                .overlay {
                    shape.strokeBorder(selectionColor.opacity(isEmphasized ? 0.9 : 0.54),
                                       lineWidth: isEmphasized ? 1.5 : 1)
                }
        } else {
            shape.fill(isHovered ? AppDesignTokens.Palette.sidebarHover : .clear)
        }
    }
}

/// One version label for the main window and Settings sidebars.
enum SidebarVersionLabel {
    static var text: String {
        // A run without bundle information (e.g. `swift run`) has no version
        // to show; never fall back to a stale hard-coded number.
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return L10n.text("开发构建", "Development Build")
        }
        let base = "\(L10n.text("版本", "Version")) \(version)"
        return L10n.showsBetaBadge
            ? "\(base) · \(L10n.text("测试版", "Beta"))"
            : base
    }
}
