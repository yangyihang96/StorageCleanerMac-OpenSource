import AppKit
import ServiceManagement
import SwiftUI

extension SettingsView {
    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                AppIconView(
                    asset: .appMain,
                    size: 76,
                    cornerRadius: 9,
                    showsShadow: false
                )

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.compact) {
                    Text(aboutAppTitle)
                        .font(.system(size: 28, weight: .bold))
                    Text(runtimeInfo.versionDisplay)
                        .font(.system(size: 15))
                        .foregroundStyle(.readableSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 8)
            LightfieldSettingsSection {
                SettingsLinkRow(title: runtimeInfo.buildInfo?.isBeta == true
                    ? L10n.text("复制测试版信息", "Copy Beta Information")
                    : L10n.text("复制诊断信息", "Copy Diagnostics")) {
                    copyRuntimeDiagnostics()
                }

                SettingsLinkRow(title: L10n.text("支持包预览与导出", "Preview & Export Support Bundle")) {
                    supportSnapshot = RedactedSupportSnapshot(runtime: runtimeInfo,
                        systemVersion: ProcessInfo.processInfo.operatingSystemVersion,
                        reports: scanStore?.operationReports ?? [])
                    showsSupportExport = true
                }
                .sheet(isPresented: $showsSupportExport) {
                    if let supportSnapshot { RedactedSupportExportView(snapshot: supportSnapshot) }
                }

                SettingsExpandableRow(title: L10n.text("详细信息", "Details"), expanded: $aboutDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 0) { aboutDetailRows }
                }

                if let diagnosticNotice {
                    SettingsNoticeView(notice: diagnosticNotice)
                }
            } header: {
                Text(L10n.text("诊断与支持", "Diagnostics & Support"))
            }
        }
    }

    /// D272: the build, the install and the access details in one place, behind
    /// one row (were two disclosure groups).
    @ViewBuilder
    private var aboutDetailRows: some View {
        if let buildInfo = runtimeInfo.buildInfo, buildInfo.isBeta {
            aboutDetailRow("Build", buildInfo.build)
            aboutDetailRow("Commit", buildInfo.commitDisplay)
            aboutDetailRow(L10n.text("构建日期", "Built"), buildInfo.buildDate)
            aboutDetailRow(L10n.text("构建配置", "Configuration"), buildInfo.configuration)
        }
        aboutDetailRow("Bundle ID", runtimeInfo.bundleIdentifier)
        aboutDetailRow(L10n.text("运行位置", "Runtime"), runtimeInfo.kind.detail)
        aboutDetailRow(L10n.text("清理架构", "Cleanup Architecture"),
                       CleanupFeatureConfiguration(mode: cleanupArchitectureMode).diagnosticValue)
        aboutDetailRow(L10n.text("分发状态", "Distribution"), runtimeInfo.distributionStatus)
        aboutDetailRow(L10n.text("授权稳定性", "Access Stability"), runtimeInfo.authorizationStabilityStatus)
    }

    private func aboutDetailRow(_ title: String, _ value: String) -> some View {
        LightfieldSettingsRow { SettingsValueRow(title: title, value: value) }
    }

    func copyRuntimeDiagnostics() {
        runtimeInfo = AppRuntimeLocationService.current()
        let diagnostics = runtimeInfo.buildInfo?.isBeta == true
            ? runtimeInfo.buildInfo?.betaDiagnosticsMarkdown(
                helperStatus: fanControl.helperStatus.title,
                advancedControlStatus: fanControl.helperState.title
            ) ?? runtimeInfo.diagnosticsMarkdown
            : runtimeInfo.diagnosticsMarkdown
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        diagnosticNotice = SettingsNotice(
            text: L10n.text("诊断信息已复制。", "Diagnostics copied."),
            systemImage: "doc.on.doc.fill",
            tint: AppDesignTokens.Palette.success,
            severity: .success
        )
    }

    var aboutAppTitle: String {
        guard let buildInfo = runtimeInfo.buildInfo, buildInfo.isBeta else {
            return L10n.appName
        }
        return L10n.text(
            "存储清理助手 \(buildInfo.version) 测试版",
            "Storage Cleaner \(buildInfo.version) Beta"
        )
    }

}
