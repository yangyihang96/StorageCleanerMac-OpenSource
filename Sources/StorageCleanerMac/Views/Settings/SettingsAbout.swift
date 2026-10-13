import AppKit
import ServiceManagement
import SwiftUI

extension SettingsView {
    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 26) {
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
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 8)
            LightfieldSettingsSection {
            DisclosureGroup(L10n.text("构建与运行信息", "Build & Runtime")) {
                if let buildInfo = runtimeInfo.buildInfo, buildInfo.isBeta {
                    LabeledContent("Build", value: buildInfo.build)
                    LabeledContent("Commit", value: buildInfo.commitDisplay)
                    LabeledContent(
                        L10n.text("构建日期", "Built"),
                        value: buildInfo.buildDate
                    )
                    LabeledContent(
                        L10n.text("构建配置", "Configuration"),
                        value: buildInfo.configuration
                    )
                }
                LabeledContent("Bundle ID", value: runtimeInfo.bundleIdentifier)
                LabeledContent(L10n.text("运行位置", "Runtime"), value: runtimeInfo.kind.detail)
                LabeledContent(
                    L10n.text("清理架构", "Cleanup Architecture"),
                    value: CleanupFeatureConfiguration(
                        mode: cleanupArchitectureMode
                    ).diagnosticValue
                )

            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                    LabeledContent(
                        L10n.text("分发状态", "Distribution"),
                        value: runtimeInfo.distributionStatus
                    )
                    LabeledContent(
                        L10n.text("授权稳定性", "Access Stability"),
                        value: runtimeInfo.authorizationStabilityStatus
                    )
                }
                .padding(.top, AppDesignTokens.Spacing.small)
            } label: {
                Text(
                    L10n.text("安装与授权详情", "Installation & Access Details")
                )
            }

            Button {
                copyRuntimeDiagnostics()
            } label: {
                Text(
                    runtimeInfo.buildInfo?.isBeta == true
                        ? L10n.text("复制测试版信息", "Copy Beta Information")
                        : L10n.text("复制诊断信息", "Copy Diagnostics")
                )
            }

            Button {
                supportSnapshot = RedactedSupportSnapshot(runtime: runtimeInfo,
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersion,
                    reports: scanStore?.operationReports ?? [])
                showsSupportExport = true
            } label: {
                Text(L10n.text("支持包预览与导出", "Preview & Export Support Bundle"))
            }
            .sheet(isPresented: $showsSupportExport) {
                if let supportSnapshot { RedactedSupportExportView(snapshot: supportSnapshot) }
            }

            if let diagnosticNotice {
                SettingsNoticeView(notice: diagnosticNotice)
            }
            } header: {
                Text(L10n.text("版本与诊断", "Version & Diagnostics"))
            }
        }
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
