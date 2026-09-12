import SwiftUI

struct SmartCareLandingView: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    @ObservedObject var store: ScanStore
    let latestStatus: LastScanStatusSummary?

    var body: some View {
        FileToolLandingPage(
            title: L10n.text("智能扫描", "Smart Scan"),
            subtitle: L10n.text(
                "检查可清理垃圾与需要人工判断的文件",
                "Check cleanup candidates and files that need review"
            ),
            systemImage: ReviewFilter.overview.systemImage,
            configurationTitle: L10n.text("扫描内容", "Scan Contents"),
            actionTitle: scanActionTitle,
            actionDetail: "",
            actionSystemImage: scanActionSystemImage,
            status: heroStatus,
            isLoading: store.isPreparingMainScan,
            isActionDisabled: store.isPreparingScan,
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
        ViewThatFits(in: .horizontal) {
            VStack(spacing: AppDesignTokens.Spacing.small) {
                scopeRow(
                    L10n.text("可清理垃圾", "Cleanup Candidates"),
                    detail: L10n.text(
                        "系统缓存、日志、临时文件与可再生成内容",
                        "System caches, logs, temporary files, and regenerable content"
                    ),
                    systemImage: "trash",
                    tint: theme.accent
                )
                scopeRow(
                    L10n.text("需确认文件", "Files to Review"),
                    detail: L10n.text(
                        "大型文件、重复文件与下载内容",
                        "Large files, duplicates, and downloads"
                    ),
                    systemImage: "doc.text.magnifyingglass",
                    tint: ModuleThemeCatalog.theme(for: .files).accent
                )
                scopeRow(
                    L10n.text("健康状态检查", "Health Status"),
                    detail: L10n.text(
                        "磁盘、电池与关键系统状态",
                        "Disk, battery, and key system state"
                    ),
                    systemImage: "shield",
                    tint: ModuleThemeCatalog.theme(for: .protection).accent
                )
            }

            Text(L10n.text(
                "可清理垃圾 · 需确认文件 · 健康状态",
                "Cleanup Candidates · Files to Review · Health Status"
            ))
            .font(AppDesignTokens.Typography.compactLabel)
            .foregroundStyle(.secondary)
        }
    }

    private func scopeRow(
        _ title: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: layout.isShort ? 23 : 28, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: layout.isShort ? 40 : 48, height: layout.isShort ? 40 : 48)
                .background(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.65), lineWidth: 1))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppDesignTokens.Spacing.small)

            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
