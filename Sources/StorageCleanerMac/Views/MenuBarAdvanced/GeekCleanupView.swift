import SwiftUI

extension MenuBarAdvancedStatusView {
    var geekCleanupPage: some View {
        VStack(spacing: GeekPanelLayout.sectionSpacing) {
            GeekMetricSummaryGrid(
                tiles: showsExtendedGeekDetails
                    ? geekCleanupTiles
                    : Array(geekCleanupTiles.prefix(3))
            )

            if showsExtendedGeekDetails {
                GeekResponsiveColumns {
                    geekCleanupStatusCard
                } secondary: {
                    geekCleanupActionableItemsCard
                }
            } else {
                geekCleanupStatusCard
            }

            HStack(spacing: 8) {
                AppButton(
                    title: L10n.text("查看安全清理", "Review Safe Cleanup"),
                    systemImage: AppSymbols.Panel.nonDestructiveCleanup,
                    controlSize: .small,
                    fillsWidth: true
                ) {
                    openApp(filter: .green)
                }
                AppButton(
                    title: L10n.text("查看大型文件", "Review Large Files"),
                    systemImage: AppSymbols.Navigation.fileAnalysis,
                    controlSize: .small,
                    fillsWidth: true
                ) {
                    openApp(filter: .largeFiles)
                }
                if showsExtendedGeekDetails {
                    AppButton(
                        title: L10n.text("打开内存管理", "Open Memory Management"),
                        systemImage: AppSymbols.Monitor.memory,
                        controlSize: .small,
                        fillsWidth: true
                    ) {
                        openApp(filter: .memory)
                    }
                }
            }
        }
    }

    private var geekCleanupStatusCard: some View {
        AdvancedPanelCard(
            title: cleanupSummaryTitle,
            systemImage: AppSymbols.Monitor.cleanup,
            tint: AppDesignTokens.Palette.success
        ) {
            GeekTelemetryRow(title: L10n.text("可安全清理", "Safe Cleanup"), value: safeCleanupBytesText, tint: AppDesignTokens.Palette.success)
            GeekTelemetryRow(title: L10n.text("项目数", "Items"), value: safeCleanupCountText, tint: AppDesignTokens.Palette.success)
            GeekTelemetryRow(title: L10n.text("启动卷可用", "Startup Disk Available"), value: storageSnapshot.map { ByteFormat.storageString($0.userAvailableBytes) } ?? "--", tint: AppDesignTokens.Palette.information)
        }
    }

    private var geekCleanupActionableItemsCard: some View {
        AdvancedPanelCard(
            title: L10n.text("可操作项目", "Actionable Items"),
            systemImage: AppSymbols.Panel.details,
            tint: AppDesignTokens.Palette.success
        ) {
            if actionableCleanupItems.isEmpty {
                AdvancedUnavailableRow(title: staleCleanupSummaryNotice)
            } else {
                ForEach(actionableCleanupItems) { item in
                    AdvancedCleanupItemRow(item: item)
                }
            }
        }
    }
}
