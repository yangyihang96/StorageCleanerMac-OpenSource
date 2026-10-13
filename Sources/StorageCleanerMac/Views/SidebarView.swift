import SwiftUI

/// The main window sidebar (D53, UI-V2-SPEC §2.2, §3.2.2): gradient icon
/// tiles, one selection block that slides between rows, a fixed title area
/// with the list fading beneath it, and an icon rail below 960 pt.
struct SidebarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppCanvasTheme.defaultsKey) private var canvasThemeRawValue = AppCanvasTheme.defaultTheme.rawValue
    @ObservedObject var store: ScanStore
    @ObservedObject private var navigationState: AppNavigationState
    @ObservedObject private var largeFilesWorkspace: LargeFilesStore
    @ObservedObject private var duplicateFilesWorkspace: DuplicateFilesStore
    @Binding var selection: ReviewFilter
    private let presentation: SidebarPresentation
    private let onTogglePresentation: (() -> Void)?
    @Namespace private var selectionNamespace
    /// The drawn selection. It follows the real selection inside an
    /// animation so the block slides; Reduce Motion places it at once.
    @State private var highlightedKey: String?

    init(
        store: ScanStore,
        selection: Binding<ReviewFilter>,
        presentation: SidebarPresentation = .full,
        onTogglePresentation: (() -> Void)? = nil
    ) {
        self.store = store
        _navigationState = ObservedObject(wrappedValue: store.navigationState)
        _largeFilesWorkspace = ObservedObject(wrappedValue: store.largeFilesWorkspace)
        _duplicateFilesWorkspace = ObservedObject(wrappedValue: store.duplicateFilesWorkspace)
        _selection = selection
        self.presentation = presentation
        self.onTogglePresentation = onTogglePresentation
    }

    private var isRail: Bool { presentation == .rail }

    var body: some View {
        SidebarChrome(isRail: isRail, usesLightfield: FeatureLightfield.owns(selection)) {
            VStack(spacing: 0) {
                // The traffic lights sit in the 52 pt toolbar band, which the
                // sidebar already clears; the old extra 44 pt left about
                // 96 pt empty above the title (audit 2.16).
                Color.clear
                    .frame(height: AppDesignTokens.Layout.sidebarTopInset)
                    .accessibilityHidden(true)

                workspaceHeader

                ScrollView(.vertical) {
                    VStack(alignment: isRail ? .center : .leading, spacing: isRail ? 2 : 4) {
                        navigationRow(.overview)

                        ForEach(SidebarGroup.allCases) { group in
                            if isRail {
                                SidebarRailSeparator()
                                ForEach(ReviewFilter.sidebarItems(in: group)) { filter in
                                    rows(for: filter)
                                }
                            } else {
                                SidebarSectionView(
                                    group: group,
                                    isCurrent: isCurrent(group)
                                ) {
                                    VStack(spacing: 2) {
                                        ForEach(sidebarItems(in: group)) { filter in
                                            rows(for: filter)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, isRail ? 8 : 10)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
                }
                // §2.2: the title stays put; the list fades beneath it and
                // above the footer instead of being clipped mid-row.
                .mask { SidebarScrollFade() }
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)

                SidebarFooter(isRail: isRail)
                    .padding(.horizontal, isRail ? 8 : 10)
                    .padding(.vertical, AppDesignTokens.Spacing.small)
            }
        }
        .environment(\.canvasTheme, AppCanvasTheme.resolve(rawValue: canvasThemeRawValue))
        .onAppear { highlightedKey = currentSelectionKey }
        .onChange(of: currentSelectionKey) { _, key in
            withAnimation(AppMotion.selection(reduceMotion: reduceMotion)) {
                highlightedKey = key
            }
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.smartScanSidebar)
#endif
    }

    @ViewBuilder
    private func rows(for filter: ReviewFilter) -> some View {
        navigationRow(filter)
        if filter == .duplicates {
            SidebarNavigationRow(
                filter: .duplicates,
                isSelected: isSelected(.duplicates)
                    && duplicateFilesWorkspace.resultFilter == .similarImage,
                isHighlighted: highlightedKey == Self.similarPhotosKey,
                isActivityActive: false,
                detail: L10n.text(
                    "只读对照视觉相似的照片，逐张人工确认",
                    "Read-only comparison of visually similar photos"
                ),
                title: L10n.text("相似照片", "Similar Photos"),
                systemImage: "photo.on.rectangle.angled",
                isRail: isRail,
                namespace: selectionNamespace
            ) {
                selectSimilarPhotos()
            }
        }
    }

    private func navigationRow(_ filter: ReviewFilter) -> some View {
        SidebarNavigationRow(
            filter: filter,
            isSelected: isSelected(filter)
                && (filter != .duplicates
                    || duplicateFilesWorkspace.resultFilter != .similarImage),
            isHighlighted: highlightedKey == filter.rawValue,
            isActivityActive: isActivityActive(for: filter),
            detail: accessibilityDetail(for: filter),
            isRail: isRail,
            namespace: selectionNamespace
        ) {
            select(filter)
        }
    }

    private static let similarPhotosKey = "similarPhotos"

    /// The row that is selected now: the sidebar anchor of the route, or the
    /// similar-photos row of the duplicates page.
    private var currentSelectionKey: String? {
        let selected = navigationState.selectedFilter == .utilityHub
            ? navigationState.selectedUtilityFilter
            : navigationState.selectedFilter
        if selected == .duplicates, duplicateFilesWorkspace.resultFilter == .similarImage {
            return Self.similarPhotosKey
        }
        return selected.rawValue
    }

    @ViewBuilder
    private var workspaceHeader: some View {
        if isRail {
            sidebarToggleButton
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
        } else {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Text(L10n.productName)
                    .font(AppDesignTokens.TypeScale.bodyEmphasis)
                    .foregroundStyle(AppDesignTokens.Palette.sidebarPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                sidebarToggleButton
            }
            .padding(.leading, 17)
            .padding(.trailing, 8)
            .padding(.bottom, 4)
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
                tint: AppDesignTokens.Palette.sidebarSecondaryText
            ) {
                onTogglePresentation()
            }
        }
    }

    private func isSelected(_ filter: ReviewFilter) -> Bool {
        if ReviewFilter.utilityToolCases.contains(filter) {
            return navigationState.selectedFilter == .utilityHub
                && navigationState.selectedUtilityFilter == filter
        }
        return navigationState.selectedFilter.sidebarGroupAnchor == filter
    }

    private func sidebarItems(in group: SidebarGroup) -> [ReviewFilter] {
        ReviewFilter.sidebarItems(in: group)
    }

    private func isCurrent(_ group: SidebarGroup) -> Bool {
        let activeFilter = navigationState.selectedFilter == .utilityHub
            ? navigationState.selectedUtilityFilter
            : navigationState.selectedFilter
        return activeFilter.sidebarGroup == group
    }

    private func select(_ filter: ReviewFilter) {
        Task { @MainActor in
            selection = filter
            if filter == .duplicates {
                duplicateFilesWorkspace.resultFilter = .all
            }
        }
    }

    private func selectSimilarPhotos() {
        Task { @MainActor in
            duplicateFilesWorkspace.resultFilter = .similarImage
            selection = .duplicates
        }
    }

    private func isActivityActive(for filter: ReviewFilter) -> Bool {
        switch filter {
        case .largeFiles:
            return largeFilesWorkspace.isAnalyzingStorage
        case .migration:
            return largeFilesWorkspace.isScanning
        case .duplicates:
            return duplicateFilesWorkspace.isScanning
        default:
            break
        }
        return store.isScanning && store.scanPresentationRoute == filter
    }

    private func accessibilityDetail(for filter: ReviewFilter) -> String {
        switch filter {
        case .overview:
            if let result = store.result {
                return L10n.usedSpace(ByteFormat.string(result.system.diskUsedBytes))
            }
        case .green:
            if let result = store.result {
                return L10n.itemBytes(result.items(for: .green).count, ByteFormat.string(result.greenBytes))
            }
        case .privacy:
            return L10n.text(
                "读取本机全部浏览记录，逐页列出网站和页面；删除前确认",
                "Reads all local browsing history and lists every site and page; deletion requires confirmation"
            )
        case .devCaches:
            if let session = store.cleanupScanSession,
               let category = session.categories.first(where: { $0.id == "developer" }) {
                return L10n.itemBytes(
                    category.candidates.count,
                    ByteFormat.string(category.candidates.reduce(0) {
                        CleanupByteCount.adding($1.estimatedSizeBytes, to: $0)
                    })
                )
            }
            return filter.sidebarTitle
        case .largeFiles:
            if largeFilesWorkspace.isAnalyzingStorage {
                let count = largeFilesWorkspace.storageAnalysisProgress?.inspectedItemCount ?? 0
                return L10n.text("正在分析磁盘 · 已读取 \(count) 项", "Analyzing disk · \(count) items read")
            }
            if let analysis = largeFilesWorkspace.storageAnalysis {
                return L10n.itemBytes(
                    analysis.inspectedItemCount,
                    ByteFormat.string(analysis.rootSnapshot.measuredBytes)
                )
            }
        case .migration:
            let items = largeFilesWorkspace.items
            if largeFilesWorkspace.isScanning {
                return L10n.text("正在扫描可搬移文件", "Scanning movable files")
            }
            if largeFilesWorkspace.hasScanned {
                return L10n.itemBytes(
                    items.count,
                    ByteFormat.string(items.reduce(0) { $0 + $1.sizeBytes })
                )
            }
            return L10n.text("迁移文件或应用到外接硬盘", "Move files or applications to an external drive")
        case .duplicates:
            if duplicateFilesWorkspace.isScanning, let progress = duplicateFilesWorkspace.scanProgress {
                return L10n.text(
                    "已扫描 \(progress.scannedFiles) 个文件，已完整哈希 \(progress.hashedFiles) 个",
                    "\(progress.scannedFiles) files scanned; \(progress.hashedFiles) fully hashed"
                )
            }
            if duplicateFilesWorkspace.hasScanned || !duplicateFilesWorkspace.items.isEmpty {
                return L10n.itemBytes(
                    duplicateFilesWorkspace.items.count,
                    ByteFormat.string(duplicateFilesWorkspace.items.reduce(0) { $0 + $1.sizeBytes })
                )
            }
        case .healthHub:
            return L10n.text("磁盘与硬件状态", "Disk and hardware status")
        case .performance:
            return L10n.text("CPU、图形、媒体与持续性能测试", "CPU, graphics, media, and sustained performance tests")
        case .startup:
            return L10n.text("登录项、后台代理和系统守护进程", "Login apps, background agents, and system daemons")
        case .memory:
            return L10n.text("进程内存与安全优化建议", "Process memory and safe optimization guidance")
        case .energy:
            return L10n.text("能耗、热状态与续航影响", "Energy, thermal state, and battery impact")
        case .uninstall:
            return L10n.text("审阅应用与关联文件", "Review apps and related files")
        case .updater:
            return L10n.text("可信来源的可用更新", "Available updates from trusted sources")
        case .utilityHub:
            break
        }
        return filter.sidebarTitle
    }
}


/// Sidebar canvas and its trailing edge.
private struct SidebarChrome<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.canvasTheme) private var canvasTheme
    @AppSurfaces private var surfaces
    let isRail: Bool
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
                    if followsPureBlack { surfaces.sidebar }
                    else { FeatureLightfieldPalette.color(FeatureLightfieldPalette.resolve(scheme).sidebar) }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(followsPureBlack ? surfaces.divider
                        : FeatureLightfieldPalette.color(scheme == .dark ? 0xFFFFFF : 0x162850).opacity(FeatureLightfieldPalette.resolve(scheme).sidebarLine))
                    .frame(width: 1)
                    .accessibilityHidden(true)
            }
    }
}

/// Fades the list under the fixed title and above the footer (§2.2).
private struct SidebarScrollFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 12)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
        }
        .accessibilityHidden(true)
    }
}

/// In the icon rail, group titles become separators (§2.2).
private struct SidebarRailSeparator: View {
    @AppSurfaces private var surfaces

    var body: some View {
        Rectangle()
            .fill(surfaces.divider)
            .frame(width: 28, height: 1)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}

private struct SidebarSectionView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    let group: SidebarGroup
    let isCurrent: Bool
    private let content: Content
    @AppStorage private var isExpanded: Bool
    @State private var isHovered = false

    init(
        group: SidebarGroup,
        isCurrent: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.group = group
        self.isCurrent = isCurrent
        _isExpanded = AppStorage(
            wrappedValue: false,
            group.expansionDefaultsKey
        )
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(AppMotion.layout(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    // A group title is a neutral label (UI-V2-SPEC 1.3:
                    // 11 pt semibold, +0.3 tracking); module pigments stay
                    // with the destinations inside it.
                    Text(group.title)
                        .font(AppDesignTokens.TypeScale.sidebarGroup)
                        .tracking(AppDesignTokens.TypeScale.sidebarGroupTracking)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(
                            size: AppDesignTokens.Icon.sidebarDisclosureGlyph,
                            weight: .bold
                        ))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 14)
                        .opacity(isHovered || !isExpanded ? 1 : 0.55)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(isCurrent ? surfaces.textPrimary : surfaces.textSecondary)
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.top, 8)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 26,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .onHover { isHovered = $0 }
            .accessibilityLabel(group.title)
            .accessibilityValue(
                isExpanded
                    ? L10n.text("已展开", "Expanded")
                    : L10n.text("已收起", "Collapsed")
            )

            if isExpanded {
                content
                    .transition(AppMotion.rowTransition(reduceMotion: reduceMotion))
            }
        }
        .onAppear {
            if isCurrent {
                isExpanded = true
            }
        }
        .onChange(of: isCurrent) { _, isCurrent in
            if isCurrent {
                withAnimation(AppMotion.layout(reduceMotion: reduceMotion)) {
                    isExpanded = true
                }
            }
        }
    }
}

private struct SidebarNavigationRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces

    let filter: ReviewFilter
    /// The real selection (accessibility).
    let isSelected: Bool
    /// The drawn selection, which slides in an animation.
    let isHighlighted: Bool
    let isActivityActive: Bool
    let detail: String
    var title: String? = nil
    var systemImage: String? = nil
    var isRail = false
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    private var rowTitle: String { title ?? filter.sidebarTitle }
    private var pigment: ModulePigment { filter.moduleTheme.pigment }

    var body: some View {
        Button(action: action) {
            Group {
                if isRail {
                    FeatureLightfieldArtwork(art: systemImage == GeneratedArt.similarPhotosSystemImage
                        ? .similarPhotos : GeneratedArt.module(for: filter), variant: .header)
                    .frame(width: 20, height: 20)
                    .frame(width: 44, height: 36)
                } else {
                    HStack(spacing: 10) {
                        FeatureLightfieldArtwork(art: systemImage == GeneratedArt.similarPhotosSystemImage
                            ? .similarPhotos : GeneratedArt.module(for: filter), variant: .header)
                            .frame(width: 20, height: 20)

                        Text(rowTitle)
                            .font(isHighlighted
                                  ? AppDesignTokens.TypeScale.sidebarItemSelected
                                  : AppDesignTokens.TypeScale.sidebarItem)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)

                        Spacer(minLength: 0)

                        if isActivityActive {
                            ProgressView()
                                .controlSize(.small)
                                .tint(isHighlighted ? .white : pigment.brightColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(minHeight: AppDesignTokens.Layout.sidebarRowHeight)
                }
            }
            .foregroundStyle(isHighlighted ? Color.white : surfaces.textPrimary)
            .contentShape(RoundedRectangle(cornerRadius: AppDesignTokens.Corner.row, style: .continuous))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .background {
            ZStack {
                if !isHighlighted {
                    RoundedRectangle(cornerRadius: AppDesignTokens.Corner.row, style: .continuous)
                        .fill(isHovered ? surfaces.hover : .clear)
                }
                if isHighlighted {
                    SidebarSelectionBlock(pigment: pigment)
                        .matchedGeometryEffect(id: "sidebar.selection", in: namespace)
                }
            }
        }
        .frame(maxWidth: isRail ? nil : .infinity, alignment: .leading)
        .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .help(isRail ? rowTitle : detail)
        .accessibilityLabel(rowTitle)
        .accessibilityHint(detail)
        .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// DECISIONS D3: the selection follows its module's color, drawn as the
/// module gradient with white text (UI-V2-SPEC 1.2).
private struct SidebarSelectionBlock: View {
    @AppSurfaces private var surfaces
    let pigment: ModulePigment

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppDesignTokens.Corner.row, style: .continuous)
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
            .accessibilityHidden(true)
    }
}

/// The Settings sidebar row surface (DECISIONS D3 补充): a themed fill and
/// stroke when selected, the shared hover fill otherwise. The settings window
/// moves to the v2 rows in V4. `isEmphasized` marks the selection of a
/// sidebar that has keyboard focus.
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

private struct SidebarFooter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    @State private var isHovered = false
    var isRail = false

    private var versionLabel: String { SidebarVersionLabel.text }

    var body: some View {
        VStack(alignment: isRail ? .center : .leading, spacing: 4) {
            SettingsLink {
                Group {
                    if isRail {
                        IconTile(systemImage: AppSymbols.Action.settings, side: 26, pigment: .neutral)
                            .frame(width: 44, height: 36)
                    } else {
                        HStack(spacing: 10) {
                            IconTile(systemImage: AppSymbols.Action.settings, side: 22, pigment: .neutral)
                            Text(L10n.text("设置", "Settings"))
                                .font(AppDesignTokens.TypeScale.sidebarItem)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .frame(minHeight: AppDesignTokens.Layout.sidebarRowHeight)
                    }
                }
                .foregroundStyle(surfaces.textPrimary)
                .contentShape(RoundedRectangle(cornerRadius: AppDesignTokens.Corner.row, style: .continuous))
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .background(
                RoundedRectangle(cornerRadius: AppDesignTokens.Corner.row, style: .continuous)
                    .fill(isHovered ? surfaces.hover : .clear)
            )
            .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
            .help(L10n.text("设置", "Settings"))
            .accessibilityLabel(L10n.text("设置", "Settings"))
            .accessibilityHint(L10n.text("打开独立设置窗口", "Open the separate settings window"))

            if !isRail {
                Text(versionLabel)
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(surfaces.textTertiary)
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(versionLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
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
