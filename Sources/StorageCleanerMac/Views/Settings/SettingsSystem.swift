import AppKit
import ServiceManagement
import SwiftUI

extension SettingsView {
    @ViewBuilder
    var fanControlSection: some View {
        LightfieldSettingsSection {
            SettingsValueRow(title: L10n.text("系统助手", "System Helper"), caption: fanHelperCaption,
                             value: fanControl.helperStatus.title)

            if isLoadingFanCapability {
                ProgressView(L10n.text("正在读取真实风扇范围…", "Reading hardware fan ranges…"))
                    .controlSize(.small)
            } else {
                switch fanControl.helperStatus {
                case .notRegistered:
                    if fanControlCapability.requiresPrivilegedHelper {
                        SettingsLinkRow(title: LegacyFanControlHelperInstaller.installedArtifactsPresent()
                            ? L10n.text("更新系统控制", "Update System Control")
                            : L10n.text("启用系统控制", "Enable System Control")) {
                            Task {
                                await fanControl.registerHelper()
                            }
                        }
                    } else {
                        fanControlReadOnlyNotice
                    }
                case .unavailable:
                    fanControlReadOnlyNotice
                case .needsMigration:
                    if fanControlCapability.requiresPrivilegedHelper {
                        SettingsLinkRow(title: L10n.text("迁移旧版系统控制", "Migrate Legacy System Control")) {
                            Task {
                                await fanControl.migrateLegacyHelper()
                            }
                        }
                    }
                case .requiresApproval:
                    if fanControlCapability.requiresPrivilegedHelper {
                        SettingsLinkRow(title: L10n.text("在系统设置中批准", "Approve in System Settings")) {
                            fanControl.openApprovalSettings()
                        }
                    } else {
                        fanControlReadOnlyNotice
                    }
                case .enabled:
                    if fanControlCapability.supportsWriting {
                        SettingsPickerRow(title: L10n.text("风扇模式", "Fan Mode"), selection: fanControlModeBinding) {
                            ForEach(
                                GeekFanControlAvailability.availableModes(
                                    capability: fanControlCapability
                                )
                            ) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        SettingsValueRow(
                            title: L10n.text("当前硬件模式", "Current Hardware Mode"),
                            value: fanControlCapability.observedMode?.title
                                ?? L10n.text("未验证", "Unknown")
                        )

                        fanControlConfiguration
                    } else {
                        fanControlReadOnlyNotice
                    }

                    if !fanControl.isHelperReachable, fanControl.offersHelperReconnect {
                        SettingsLinkRow(title: fanControl.helperReconnectTitle) {
                            Task { await fanControl.reconnectHelper() }
                        }
                        .disabled(fanControl.isPreparingHelper || fanControl.isRefreshingConnection || fanControl.helperReconnectWaitSeconds > 0)

                        if fanControl.helperConnectionNeedsAttention {
                            SettingsLinkRow(title: L10n.text("在系统设置中重新批准", "Approve Again in System Settings")) {
                                fanControl.openApprovalSettings()
                            }
                        }
                    }

                    SettingsLinkRow(title: L10n.text("停用并恢复系统控制", "Disable and Restore System Control"), role: .destructive) {
                        Task {
                            await fanControl.unregisterHelper()
                        }
                    }
                }
            }

            if let message = fanControl.lastMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            }
        } header: {
            Text(L10n.text("状态与模式", "Status & Mode"))
        } footer: {
            // D272: when the helper is unavailable its row already says why.
            if fanControl.helperStatus != .unavailable {
                Text(L10n.text(
                    "首次需管理员批准；失联或过热时恢复 macOS 控制。",
                    "Administrator approval once; macOS control resumes on disconnect or overheating."
                ))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }

        // D272: its own group, so the red action stays beside the status rows
        // instead of under a tall editor.
        if showsFanCurveEditor {
            LightfieldSettingsSection {
                FanCurveEditor(
                    fanControl: fanControl,
                    fanReadings: fanHardwareReadings.fanReadings,
                    inSettings: true
                )
                .padding(.vertical, 12)
            } header: {
                Text(L10n.text("风扇曲线", "Fan Curve"))
            }
        }
    }

    private var showsFanCurveEditor: Bool {
        !isLoadingFanCapability
            && fanControl.helperStatus == .enabled
            && fanControlCapability.supportsWriting
            && fanControl.selectedMode == .customCurve
    }

    private var fanHelperCaption: String? {
        switch fanControl.helperStatus {
        case .unavailable:
            FanControlHelperStatus.unavailableReadOnlyDetail
        case .needsMigration:
            L10n.text(
                "检测到旧版系统助手；迁移完成前不会启用风扇写入。",
                "A legacy system helper was found; fan writes stay disabled until migration completes."
            )
        default:
            nil
        }
    }

    var fanControlCapability: HardwareFanCapability {
        HardwareFanCapabilityProbe.probe(
            fanReadings: fanHardwareReadings.fanReadings,
            temperatureReadings: fanHardwareReadings.temperatureReadings,
            hasTrustedHelper: fanControl.hasTrustedHelper,
            observedMode: fanControl.observedMode
        )
    }

    var fanControlReadOnlyNotice: some View {
        SettingsValueRow(
            title: L10n.text("硬件模式", "Hardware Mode"),
            caption: fanControlReadOnlyReason,
            value: L10n.text("只读 · 未验证", "Read Only · Unknown")
        )
    }

    var fanControlReadOnlyReason: String {
        if !fanControlCapability.supportsReading {
            return L10n.text(
                "当前硬件未提供可验证的风扇读数，不支持写入控制。",
                "This hardware does not expose verifiable fan readings, so write control is unsupported."
            )
        }
        if !fanControlCapability.hasWritableRanges {
            return L10n.text(
                "未读取到所有风扇的有效硬件最小/最大 RPM，已隐藏写入模式。",
                "Valid hardware minimum/maximum RPM is unavailable for every fan, so write modes are hidden."
            )
        }
        return L10n.text(
            "系统助手尚未完成受信任连接，写入模式保持隐藏。",
            "The system helper has not completed a trusted connection, so write modes remain hidden."
        )
    }

    @ViewBuilder
    var fanControlConfiguration: some View {
        switch fanControl.selectedMode {
        case .systemAutomatic:
            SettingsValueRow(title: L10n.text("控制方", "Controlled By"), value: "macOS")
        case .fanSet:
            SettingsPickerRow(title: L10n.text("风扇组", "Fan Set"), selection: $fanControl.selectedFanSet) {
                ForEach(FanControlSet.allCases) { fanSet in
                    Text(fanSet.title).tag(fanSet)
                }
            }
        case .customCurve:
            EmptyView()
        case .manual:
            VStack(alignment: .leading, spacing: 8) {
                fanControlSlider(
                    title: L10n.text("临时目标", "Temporary Target"),
                    value: Binding(
                        get: { fanControl.manualFraction * 100 },
                        set: {
                            fanControl.manualFraction = min(1, max(0, $0 / 100))
                        }
                    ),
                    range: 0...100,
                    suffix: "%"
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(
                        "0% 对应每个风扇的硬件最小 RPM，100% 对应硬件最大 RPM。",
                        "0% maps to each fan's hardware minimum RPM; 100% maps to its hardware maximum RPM."
                    ))
                    ForEach(fanHardwareReadings.fanReadings) { reading in
                        if let minimumRPM = reading.minimumRPM,
                           let maximumRPM = reading.maximumRPM {
                            let targetRPM = FanControlPlanner.targetRPM(
                                minimumRPM: minimumRPM,
                                maximumRPM: maximumRPM,
                                fraction: fanControl.manualFraction
                            )
                            Text(L10n.text(
                                "\(reading.displayName)：目标 \(targetRPM) · 范围 \(minimumRPM)–\(maximumRPM) RPM",
                                "\(reading.displayName): target \(targetRPM) · range \(minimumRPM)–\(maximumRPM) RPM"
                            ))
                            .monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
            }
            .padding(.vertical, 8)
        case .maximum:
            SettingsValueRow(
                title: L10n.text("目标", "Target"),
                value: L10n.text("所有风扇的硬件最大 RPM", "Hardware maximum RPM for every fan")
            )
        }
    }

    func fanControlSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            Text(title)
            // Rounded here because `step:` draws a tick for every value.
            Slider(
                value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }),
                in: range
            )
            Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                .monospacedDigit()
                .foregroundStyle(.readableSecondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    var fanControlModeBinding: Binding<GeekFanControlMode> {
        Binding {
            fanControl.selectedMode
        } set: { mode in
            if mode == .maximum {
                confirmsMaximumFanMode = true
                return
            }
            Task {
                await fanControl.selectMode(mode)
            }
        }
    }

}
