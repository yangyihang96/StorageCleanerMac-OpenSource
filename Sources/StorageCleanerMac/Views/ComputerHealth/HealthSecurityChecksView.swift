import SwiftUI

struct HealthSecurityChecksView: View {
    let snapshot: SystemProtectionSnapshot?
    @State private var failedSettingsChecks: Set<SystemProtectionCheck> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(SystemProtectionCheck.healthChecks) { check in
                let finding = snapshot?.findings.first { $0.check == check }
                let state = finding?.state ?? .unknown
                FeatureLightfieldStatusDisclosure(title: check.title,
                    detail: finding?.evidenceRowSummary ?? L10n.text("尚未检查", "Not Checked"),
                    value: state.displayText, status: Self.status(for: state),
                    leadingProbe: "lightfield.health.security.leading.\(check.rawValue)",
                    disclosureProbe: "lightfield.health.security.disclosure.\(check.rawValue)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.advice(for: check))
                        // The row names the evidence in words; the command it
                        // came from is shown here.
                        if let finding, finding.evidenceSummary != finding.evidenceRowSummary {
                            Text(finding.evidenceSummary)
                        }
                        if let checkedAt = snapshot?.checkedAt {
                            Text(checkedAt.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                        }
                        Button(L10n.text("打开系统设置", "Open System Settings")) {
                            if CleanupService.openSecuritySettings(for: check) {
                                failedSettingsChecks.remove(check)
                            } else {
                                failedSettingsChecks.insert(check)
                            }
                        }
                        if failedSettingsChecks.contains(check) {
                            Text(L10n.text("未能打开，请手动打开系统设置。", "Could not open; open System Settings manually."))
                        }
                    }
                }
            }
        }
    }

    nonisolated static func status(for state: SystemProtectionState) -> FeatureLightfieldStatus {
        switch state {
        case .enabled: .normal
        case .disabled, .transitioning: .warning
        case .unknown, .unreadable, .detected: .unknown
        }
    }

    private static func advice(for check: SystemProtectionCheck) -> String {
        switch check {
        case .systemIntegrityProtection:
            L10n.text("建议保持完整性保护；更改需进入恢复环境，系统设置仅供查看相关安全选项。",
                "Keep integrity protection enabled; changes require Recovery, while Settings shows related security options.")
        case .fileVault:
            L10n.text("建议在系统设置中确认磁盘加密，转换过程中请等待系统完成。",
                "Review disk encryption in System Settings and allow any conversion to complete.")
        case .gatekeeper:
            L10n.text("建议保留应用来源验证，在隐私与安全性中查看允许的应用来源。",
                "Keep app source verification enabled and review allowed sources in Privacy & Security.")
        case .firewall:
            L10n.text("建议按网络环境确认防火墙，在网络设置中查看入站连接规则。",
                "Review the firewall for your network and check incoming connection rules in Network settings.")
        case .xProtectInstallation:
            L10n.text("建议保持系统安全更新。", "Keep system security updates current.")
        }
    }
}

/// Recent journal changes in the same lightfield status rows as the checks
/// above (D67/D70①): status symbol, check, old → new and time as the
/// tertiary detail, new state in the value column, evidence behind the
/// row-end disclosure. Journal notices use the same status-row component.
struct HealthRecentChangesView: View {
    @Environment(\.colorScheme) private var scheme
    let events: [ComputerHealthChangeEvent]
    var readFailed = false
    var journalReset = false
    @State private var isExpanded = false

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(alignment: .leading, spacing: 0) {
            if readFailed {
                FeatureLightfieldStatusRow(title: L10n.text("变化日志", "Change Log"),
                    detail: L10n.text("变化日志无法读取或保存；本次检查结果仍可查看。",
                        "The change log could not be read or saved; current check results remain available."),
                    value: L10n.text("无法读取", "Unreadable"), status: .unknown)
            }
            if journalReset {
                FeatureLightfieldStatusRow(title: L10n.text("变化日志", "Change Log"),
                    detail: L10n.text("原变化日志无法识别，已在同一目录备份原文件，并从本次检查重新开始记录。",
                        "The previous change log was not recognized. The original file was kept as a backup and logging restarted with this check."),
                    value: L10n.text("已重新开始", "Restarted"), status: .warning)
            }
            if !events.isEmpty {
                Text(L10n.text("最近变化", "Recent Changes"))
                    .font(.system(size: 13)).tracking(0.26).foregroundStyle(palette.fg2)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 20).padding(.bottom, 14)
                FeatureLightfieldHairline()
                ForEach(Array(events.prefix(isExpanded ? ComputerHealthEventRepository.maximumEntryCount : 5))) { event in
                    FeatureLightfieldStatusDisclosure(title: event.check.title,
                        detail: event.oldState.title(for: event.check) + " → " + event.newState.title(for: event.check)
                            + " · " + event.recordedAt.formatted(date: .abbreviated, time: .shortened),
                        value: event.newState.title(for: event.check), status: Self.status(for: event.newState)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.evidenceSummary)
                            Text(event.recordedAt.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                        }
                    }
                }
                if events.count > 5 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? L10n.text("收起", "Show Less")
                            : L10n.text("查看全部（\(ByteFormat.count(events.count)) 条）", "View All (\(ByteFormat.count(events.count)))"))
                            .font(.system(size: 13)).foregroundStyle(palette.fg2)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(FeatureLightfieldRowButtonStyle())
                    .padding(.leading, 36)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated static func status(for state: ComputerHealthCheckState) -> FeatureLightfieldStatus {
        switch state {
        case .normal, .enabled: .normal
        case .warning, .disabled, .transitioning: .warning
        case .failure: .failure
        case .unknown, .unreadable, .notApplicable: .unknown
        }
    }
}
