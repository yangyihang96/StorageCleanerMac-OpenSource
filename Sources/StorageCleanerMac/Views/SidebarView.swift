import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var navigationState: AppNavigationState
    @ObservedObject private var largeFilesWorkspace: LargeFilesStore
    @ObservedObject private var duplicateFilesWorkspace: DuplicateFilesStore
    @Binding var selection: ReviewFilter

    init(
        store: ScanStore,
        selection: Binding<ReviewFilter>
    ) {
        self.store = store
        _navigationState = ObservedObject(wrappedValue: store.navigationState)
        _largeFilesWorkspace = ObservedObject(wrappedValue: store.largeFilesWorkspace)
        _duplicateFilesWorkspace = ObservedObject(wrappedValue: store.duplicateFilesWorkspace)
        _selection = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: AppDesignTokens.Layout.sidebarTrafficLightClearance)
                .accessibilityHidden(true)

            workspaceHeader

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    SidebarNavigationRow(
                        filter: .overview,
                        isSelected: isSelected(.overview),
                        isActivityActive: isActivityActive(for: .overview),
                        detail: accessibilityDetail(for: .overview)
                    ) {
                        select(.overview)
                    }

                    ForEach(SidebarGroup.allCases) { group in
                        SidebarSectionView(
                            group: group,
                            isCurrent: isCurrent(group)
                        ) {
                            VStack(spacing: 2) {
                                ForEach(sidebarItems(in: group)) { filter in
                                    SidebarNavigationRow(
                                        filter: filter,
                                        isSelected: isSelected(filter),
                                        isActivityActive: isActivityActive(for: filter),
                                        detail: accessibilityDetail(for: filter)
                                    ) {
                                        select(filter)
                                    }
                                }
                            }
                        }
                    }

                    SidebarFooter()
                        .padding(.top, AppDesignTokens.Spacing.small)
                        .padding(.bottom, AppDesignTokens.Spacing.medium)
                }
                .padding(.horizontal, 9)
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            sidebarBackground
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppDesignTokens.Palette.sidebarEdge)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.smartScanSidebar)
#endif
    }

    private var sidebarBackground: some View {
        LinearGradient(
            colors: [
                AppAppearanceColors.sidebarTop,
                AppAppearanceColors.sidebarBottom
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var workspaceHeader: some View {
        Text(L10n.productName)
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            .foregroundStyle(AppDesignTokens.Palette.sidebarPrimaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 17)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
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
                "只扫描可能敏感的网站记录并在浏览器中确认删除",
                "Scan only possibly sensitive-site history and confirm deletion in the browser"
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
            return filter.pageSubtitle
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
            return L10n.text("磁盘、电池与关键系统状态", "Disk, battery, and essential system status")
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

private struct SidebarSectionView<Content: View>: View {
    let group: SidebarGroup
    let isCurrent: Bool
    private let content: Content
    @AppStorage private var isExpanded: Bool

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
        VStack(alignment: .leading, spacing: 3) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.systemImage)
                        .font(.system(
                            size: AppDesignTokens.Icon.sidebarNavigationGlyph,
                            weight: .semibold
                        ))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)

                    Text(group.title)
                        .font(AppTypography.sidebarItem)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(
                            size: AppDesignTokens.Icon.sidebarDisclosureGlyph,
                            weight: .bold
                        ))
                        .frame(width: 10, height: 14)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(
                    isCurrent
                        ? AppDesignTokens.Palette.sidebarPrimaryText
                        : AppDesignTokens.Palette.sidebarSecondaryText
                )
                .padding(.horizontal, 8)
                .frame(
                    maxWidth: .infinity,
                    minHeight: AppDesignTokens.Layout.sidebarRowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .accessibilityLabel(group.title)
            .accessibilityValue(
                isExpanded
                    ? L10n.text("已展开", "Expanded")
                    : L10n.text("已收起", "Collapsed")
            )

            if isExpanded {
                content
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .onAppear {
            if isCurrent {
                isExpanded = true
            }
        }
        .onChange(of: isCurrent) { _, isCurrent in
            if isCurrent {
                isExpanded = true
            }
        }
    }
}

private struct SidebarNavigationRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let filter: ReviewFilter
    let isSelected: Bool
    let isActivityActive: Bool
    let detail: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: filter.systemImage)
                    .font(.system(
                        size: AppDesignTokens.Icon.sidebarNavigationGlyph,
                        weight: .semibold
                    ))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                Text(filter.sidebarTitle)
                    .font(AppTypography.sidebarItem)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if isActivityActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(iconColor)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(
                isSelected
                    ? (colorScheme == .dark ? .white : AppAppearanceColors.ink)
                    : AppDesignTokens.Palette.sidebarPrimaryText
            )
            .padding(.horizontal, 8)
            .padding(.vertical, AppDesignTokens.Spacing.micro)
            .frame(minHeight: AppDesignTokens.Layout.sidebarRowHeight)
            .contentShape(RoundedRectangle(
                cornerRadius: AppDesignTokens.Radius.sidebarRow,
                style: .continuous
            ))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .background(rowBackground)
        .scaleEffect(isHovered && !reduceMotion ? 1.005 : 1)
        .animation(reduceMotion ? nil : AppMotionTokens.hover, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel(filter.sidebarTitle)
        .accessibilityHint(detail)
        .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var iconColor: Color {
        isSelected && colorScheme == .dark ? .white : filter.moduleTheme.sidebarIconColor
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: AppDesignTokens.Radius.sidebarRow,
            style: .continuous
        )
        if isSelected {
            shape
                .fill(filter.moduleTheme.accent.opacity(colorScheme == .dark ? 0.30 : 0.12))
                .overlay {
                    shape.strokeBorder(filter.moduleTheme.accent.opacity(0.54), lineWidth: 1)
                }
        } else {
            shape.fill(isHovered ? AppDesignTokens.Palette.sidebarHover : .clear)
        }
    }
}

private struct SidebarFooter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.9.13"
        let base = "\(L10n.text("版本", "Version")) \(version)"
        return L10n.showsBetaBadge
            ? "\(base) · \(L10n.text("测试版", "Beta"))"
            : base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsLink {
                HStack(spacing: 8) {
                    Image(systemName: AppSymbols.Action.settings)
                        .font(.system(
                            size: AppDesignTokens.Icon.sidebarSettingsGlyph,
                            weight: .semibold
                        ))
                        .foregroundStyle(
                            ModuleThemeCatalog.theme(for: .settings).sidebarIconColor
                        )
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)

                    Text(L10n.text("设置", "Settings"))
                        .font(AppTypography.sidebarItem)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppDesignTokens.Palette.sidebarPrimaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, AppDesignTokens.Spacing.micro)
                .frame(minHeight: AppDesignTokens.Layout.sidebarRowHeight)
                .contentShape(RoundedRectangle(
                    cornerRadius: AppDesignTokens.Radius.sidebarRow,
                    style: .continuous
                ))
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .background(
                RoundedRectangle(
                    cornerRadius: AppDesignTokens.Radius.sidebarRow,
                    style: .continuous
                )
                .fill(isHovered ? AppDesignTokens.Palette.sidebarHover : .clear)
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.005 : 1)
            .animation(reduceMotion ? nil : AppMotionTokens.hover, value: isHovered)
            .onHover { isHovered = $0 }
            .accessibilityLabel(L10n.text("设置", "Settings"))
            .accessibilityHint(L10n.text("打开独立设置窗口", "Open the separate settings window"))

            Text(versionLabel)
                .font(AppTypography.sidebarVersion)
                .foregroundStyle(AppDesignTokens.Palette.sidebarSecondaryText)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(versionLabel)
        }
    }
}
