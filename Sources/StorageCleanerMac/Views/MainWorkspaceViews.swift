import SwiftUI

struct SmartCareLandingView: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    @AppSurfaces private var surfaces
    @ObservedObject var store: ScanStore
    let latestStatus: LastScanStatusSummary?

    var body: some View {
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
