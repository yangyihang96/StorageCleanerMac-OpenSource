import SwiftUI

struct BrowserPrivacyWorkspaceView: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var browserPrivacyStore: BrowserPrivacyStore

    var body: some View {
        Group {
            if shouldUseHeroPresentation {
                GeometryReader { proxy in
                    heroPage
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
#if DEBUG
                .layoutProbe(LayoutProbeID.privacy)
#endif
            } else {
                ManagementListPage(
                    title: ReviewFilter.privacy.title,
                    subtitle: ReviewFilter.privacy.pageSubtitle,
                    systemImage: ReviewFilter.privacy.systemImage
                ) {
                    GlassToolbarButton(
                        title: browserPrivacyStore.state == .scanning
                            ? L10n.text("取消扫描", "Cancel Scan")
                            : L10n.text("重新扫描", "Scan Again"),
                        systemImage: browserPrivacyStore.state == .scanning
                            ? "xmark"
                            : "arrow.clockwise"
                    ) {
                        if browserPrivacyStore.state == .scanning {
                            browserPrivacyStore.cancel()
                        } else {
                            browserPrivacyStore.startScan()
                        }
                    }
                } controls: {
                    EmptyView()
                } content: {
                    privacyContent
                }
            }
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.workspace)
#endif
    }

    private var heroPage: some View {
        HeroScanPage(
            title: ReviewFilter.privacy.title,
            subtitle: ReviewFilter.privacy.pageSubtitle,
            headerSystemImage: ReviewFilter.privacy.systemImage,
            configurationTitle: L10n.text("日期范围", "Date Range"),
            actionTitle: browserPrivacyStore.state == .scanning
                ? L10n.text("取消扫描", "Cancel Scan")
                : L10n.text("扫描浏览器记录", "Scan Browser Records"),
            actionDetail: "",
            actionSystemImage: browserPrivacyStore.state == .scanning ? "xmark" : "viewfinder",
            status: heroStatus,
            isLoading: browserPrivacyStore.state == .scanning,
            trustText: L10n.text("只读扫描 · 删除前确认", "Read-only scan · Confirm before deletion"),
            showsAccessory: true
        ) {
            if browserPrivacyStore.state == .scanning {
                browserPrivacyStore.cancel()
            } else {
                browserPrivacyStore.startScan()
            }
        } accessory: {
            VStack(alignment: .leading, spacing: 12) {
                BrowserPrivacyDateControls(store: browserPrivacyStore, showsSearch: true)
                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.text("网站", "Website"))
                        Spacer()
                        Text(L10n.text("记录", "Records"))
                    }
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    Divider()
                    VStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 28, weight: .light))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92)
                }
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
            }
            if browserPrivacyStore.state == .permissionDenied {
                GlassToolbarButton(
                    title: L10n.text("检查授权", "Check Access"),
                    systemImage: "lock.open"
                ) {
                    PrivacySystemSettingsOpener.openFullDiskAccess()
                }
            }
        }
    }

    private var privacyContent: some View {
        BrowserPrivacyRecordResultsView(store: browserPrivacyStore)
            .padding(.horizontal, AppDesignTokens.Spacing.medium)
            .padding(.vertical, AppDesignTokens.Spacing.compact)
#if DEBUG
            .layoutProbe(LayoutProbeID.privacy)
#endif
    }

    private var shouldUseHeroPresentation: Bool {
        switch browserPrivacyStore.state {
        case .idle, .cancelled, .failed:
            true
        case .scanning:
            !browserPrivacyStore.hasCachedResults
        case .permissionDenied:
            browserPrivacyStore.coverage.isEmpty
        case .completed, .partial:
            false
        }
    }

    private var heroStatus: ScanStatusPresentation {
        switch browserPrivacyStore.state {
        case .idle:
            .neverScanned
        case .scanning:
            .scanning(L10n.text(
                "正在扫描",
                "Scanning"
            ))
        case .permissionDenied:
            .failed(L10n.text("需要检查授权", "Access needs review"))
        case .cancelled:
            .idle(L10n.text("扫描已取消", "Scan cancelled"))
        case .failed:
            .failed(L10n.text("读取失败，请重试", "Read failed; try again"))
        case .completed:
            .completed(L10n.text("扫描完成", "Scan complete"))
        case .partial:
            .completed(L10n.text("部分扫描完成", "Partial scan complete"))
        }
    }

}

struct BrowserPrivacyDateControls: View {
    @ObservedObject var store: BrowserPrivacyStore
    var showsSearch = false
    @Environment(\.moduleTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                ForEach(BrowserPrivacyDatePreset.allCases) { preset in
                    let selected = BrowserPrivacyDatePreset.matching(store.filters, now: Date()) == preset
                    Button {
                        var filters = store.filters
                        preset.apply(to: &filters, now: Date())
                        store.filters = filters
                    } label: {
                        Text(preset.title)
                            .font(AppTypography.body)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(selected ? theme.accent.opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(selected ? theme.accent : .clear, lineWidth: 1))
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("privacy-date-\(preset.rawValue)")
                }
            }
            .padding(2)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))
            HStack {
                Picker(L10n.text("分组", "Grouping"), selection: $store.groupsByWebsite) {
                    Text(L10n.text("按网站分组", "Group by website")).tag(true)
                    Text(L10n.text("记录列表", "Record list")).tag(false)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if showsSearch {
                    TaskSearchField(
                        placeholder: L10n.text("搜索网站或记录", "Search websites or records"),
                        text: $store.filters.query,
                        tint: theme.accent
                    )
                } else {
                    Spacer(minLength: 0)
                }
                if BrowserPrivacyDatePreset.matching(store.filters, now: Date()) == nil,
                   let start = store.filters.startDate {
                    Text(start.formatted(date: .numeric, time: .omitted))
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(store.state == .scanning || store.isProcessing)
    }
}
