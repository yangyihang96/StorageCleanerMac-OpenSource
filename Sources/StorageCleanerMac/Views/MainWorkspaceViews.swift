import SwiftUI

struct SmartCareLandingView: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    @AppSurfaces private var surfaces
    @ObservedObject var store: ScanStore
    let latestStatus: LastScanStatusSummary?
    /// D168: the five modules Smart Care scans.
    @ObservedObject private var smartCare: SmartCareCoordinator

    /// Tests of the D70 landing set `careStudioClassicResults`.
    @Environment(\.careStudioClassicResults) private var usesClassicLanding

    init(store: ScanStore, latestStatus: LastScanStatusSummary?) {
        self.store = store
        self.latestStatus = latestStatus
        _smartCare = ObservedObject(wrappedValue: SmartCareCoordinator.of(store))
    }

    /// D141: the CleanMyMac Smart Care landing — picture, title, the list
    /// (D168: the five modules, each can be turned off; was the three scan
    /// scopes), round Scan. The D70 landing stays as the classic view.
    var body: some View {
        if usesClassicLanding {
            classicLanding
        } else {
            studioLanding
        }
    }

    private var classicLanding: some View {
        FileToolLandingPage(
            title: L10n.text("智能扫描", "Smart Scan"),
            systemImage: ReviewFilter.overview.systemImage,
            configurationTitle: L10n.text("扫描内容", "Scan Contents"),
            actionTitle: scanActionTitle,
            actionDetail: "",
            actionSystemImage: scanActionSystemImage,
            status: heroStatus,
            isLoading: store.isPreparingMainScan,
            isActionDisabled: store.isPreparingScan || store.selectedSmartScanScopes.isEmpty,
            trustText: L10n.text(
                "只读扫描 · 清理前逐项确认",
                "Read-only scan · Review every item before cleanup"
            ),
            action: store.startScanRespectingAccessGuide
        ) {
            scanScope
        }
    }

    private var studioLanding: some View {
        CareStudioLandingPage(
            module: .smartScan,
            title: welcome?.title,
            subtitle: welcome?.subtitle,
            bullets: SmartCareModule.allCases.map { module in
                CareStudioBullet(
                    id: module.rawValue,
                    title: module.title,
                    systemImage: module.landingSymbol,
                    hint: module.scope,
                    isSelected: smartCare.selection.contains(module),
                    toggle: store.isPreparingScan ? nil : { smartCare.toggle(module) })
            },
            status: studioStatusText,
            footnote: L10n.text("只读扫描 · 清理前逐项确认", "Read-only scan · Review every item before cleanup"),
            actionTitle: store.isPreparingMainScan ? L10n.text("准备中", "Preparing") : L10n.text("扫描", "Scan"),
            actionEnabled: !store.isPreparingScan && !smartCare.selection.isEmpty,
            actionHint: L10n.text("依次只读扫描所选模块，不会删除任何文件",
                                  "Scans the selected modules one after another, read-only; nothing is removed"),
            action: smartCare.start)
    }

    private var welcome: (title: String, subtitle: String)? {
        Self.welcome(latestStatus: latestStatus, hasStartedScan: smartCare.hasStartedScan)
    }

    /// D154 batch 3O: CleanMyMac's landing greets a first visit with the
    /// app's name in place of the module's; ours does until the first scan
    /// (none in the history, and Smart Care never started).
    static func welcome(latestStatus: LastScanStatusSummary?,
                        hasStartedScan: Bool) -> (title: String, subtitle: String)? {
        guard latestStatus == nil, !hasStartedScan else { return nil }
        return (L10n.text("欢迎使用\(L10n.productName)", "Welcome to \(L10n.productName)"),
                L10n.text("选好要检查的内容，点“扫描”，看看有哪些可以整理。",
                          "Choose what to check, then click Scan to see what can be tidied up."))
    }

    private var studioStatusText: String? {
        if smartCare.selection.isEmpty {
            return L10n.text("请至少选择一项扫描内容", "Select at least one thing to scan")
        }
        switch heroStatus {
        case .neverScanned: return nil
        default: return heroStatus.title
        }
    }

    static func symbol(for scope: SmartScanScope) -> String {
        switch scope {
        case .cleanupCandidates: "trash.fill"
        case .filesToReview: "doc.text.fill"
        case .health: "checkmark.shield.fill"
        }
    }

    private var statusText: String? {
        if store.selectedSmartScanScopes.isEmpty {
            return L10n.text("请至少选择一项扫描内容", "Select at least one thing to scan")
        }
        switch heroStatus {
        case .neverScanned: return nil
        default: return heroStatus.title
        }
    }

    private var scanScope: some View {
        FeatureOptionList {
            ForEach(SmartScanScope.allCases) { scope in
                SmartScanScopeButton(scope: scope, isSelected: store.selectedSmartScanScopes.contains(scope)) {
                    store.toggleSmartScanScope(scope)
                }
                .disabled(store.isPreparingScan)
            }
        }
    }

    private var scanActionTitle: String {
        latestStatus == nil
            ? L10n.text("开始扫描", "Start Scan")
            : L10n.text("重新扫描", "Scan Again")
    }

    private var scanActionSystemImage: String {
        latestStatus == nil ? "magnifyingglass" : "arrow.clockwise"
    }

    private var heroStatus: ScanStatusPresentation {
        if let activity = store.activeScanStatusText {
            return store.isPreparingMainScan ? .scanning(activity) : .idle(activity)
        }
        guard let latestStatus else { return .neverScanned }

        switch latestStatus.attentionLevel {
        case .permissionLimited:
            return .idle(L10n.text("部分位置需要授权", "Some locations need permission"))
        case .current:
            return .completed(L10n.text("扫描结果已准备就绪", "Scan results are ready"))
        case .rescanRecommended:
            return .expired
        }
    }
}

/// Same selectable tile family as Safe Cleanup; every icon performs a real toggle.
struct SmartScanScopeButton: View {
    @Environment(\.moduleTheme) private var theme
    @AppSurfaces private var surfaces
    let scope: SmartScanScope
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            FeatureOptionCard(isSelected: isSelected, padding: 0) {
                HStack(spacing: 12) {
                    IconTile(systemImage: symbol, side: FeaturePageTokens.optionIconSide,
                             pigment: pigment, shape: .circle)
#if DEBUG
                    .layoutProbe("smartScope.icon.\(scope.probeID)")
#endif
                    Text(scope.title).font(FeaturePageTokens.optionTitleFont)
                        .foregroundStyle(surfaces.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
#if DEBUG
                        .layoutProbe("smartScope.copy.\(scope.probeID)")
#endif
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? theme.actionFill : surfaces.textSecondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(minHeight: FeaturePageTokens.optionRowMinimumHeight)
            }
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .accessibilityLabel(scope.title)
        .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not selected"))
#if DEBUG
        .layoutProbe("smartScope.\(scope.probeID)")
#endif
    }
    private var symbol: String {
        switch scope {
        case .cleanupCandidates: "trash.fill"
        case .filesToReview: "doc.text.fill"
        case .health: "checkmark.shield.fill"
        }
    }
    private var pigment: ModulePigment {
        switch scope {
        case .cleanupCandidates: .smartScan
        case .filesToReview: .memory
        case .health: .files
        }
    }
}
