import AppKit
import ServiceManagement
import SwiftUI

extension SettingsView {
    var fanControlSection: some View {
        LightfieldSettingsSection {
            LabeledContent(
                L10n.text("辅助程序", "Helper"),
                value: fanControl.helperStatus.title
            )

            if isLoadingFanCapability {
                ProgressView(L10n.text("正在读取真实风扇范围…", "Reading hardware fan ranges…"))
                    .controlSize(.small)
            } else {
                switch fanControl.helperStatus {
                case .notRegistered:
                    if fanControlCapability.requiresPrivilegedHelper {
                        Button {
                            Task {
                                await fanControl.registerHelper()
                            }
                        } label: {
                            Text(
                                LegacyFanControlHelperInstaller.installedArtifactsPresent()
                                    ? L10n.text("更新系统控制", "Update System Control")
                                    : L10n.text("启用系统控制", "Enable System Control")
                            )
                        }
                    } else {
                        fanControlReadOnlyNotice
                    }
                case .unavailable:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FanControlHelperStatus.unavailableReadOnlyDetail)
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        fanControlReadOnlyNotice
                    }
                case .needsMigration:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text(
                            "检测到旧版系统控制辅助程序；迁移完成前不会启用风扇写入。",
                            "A legacy system-control helper was found; fan writes stay disabled until migration completes."
                        ))
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if fanControlCapability.requiresPrivilegedHelper {
                            Button {
                                Task {
                                    await fanControl.migrateLegacyHelper()
                                }
                            } label: {
                                Text(
                                    L10n.text("迁移旧版系统控制", "Migrate Legacy System Control")
                                )
                            }
                        }
                    }
                case .requiresApproval:
                    if fanControlCapability.requiresPrivilegedHelper {
                        Button {
                            fanControl.openApprovalSettings()
                        } label: {
                            Text(
                                L10n.text("在系统设置中批准", "Approve in System Settings")
                            )
                        }
                    } else {
                        fanControlReadOnlyNotice
                    }
                case .enabled:
                    if fanControlCapability.supportsWriting {
                        Picker(
                            L10n.text("请求模式", "Requested Mode"),
                            selection: fanControlModeBinding
                        ) {
                            ForEach(
                                GeekFanControlAvailability.availableModes(
                                    capability: fanControlCapability
                                )
                            ) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)

                        LabeledContent(
                            L10n.text("已观察硬件模式", "Observed Hardware Mode"),
                            value: fanControlCapability.observedMode?.title
                                ?? L10n.text("未验证", "Unknown")
                        )

                        fanControlConfiguration
                    } else {
                        fanControlReadOnlyNotice
                    }

                    if !fanControl.isHelperReachable, fanControl.offersHelperReconnect {
                        Button(fanControl.helperReconnectTitle) {
                            Task { await fanControl.reconnectHelper() }
                        }
                        .disabled(fanControl.isPreparingHelper || fanControl.isRefreshingConnection || fanControl.helperReconnectWaitSeconds > 0)

                        if fanControl.helperConnectionNeedsAttention {
                            Button(L10n.text("在系统设置中重新批准", "Approve Again in System Settings")) {
                                fanControl.openApprovalSettings()
                            }
                        }
                    }

                    Button(role: .destructive) {
                        Task {
                            await fanControl.unregisterHelper()
                        }
                    } label: {
                        Text(
                            L10n.text("停用并恢复系统控制", "Disable and Restore System Control")
                        )
                    }
                }
            }

            if let message = fanControl.lastMessage {
                Text(message)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L10n.text("系统控制辅助程序", "System Control Helper"))
        } footer: {
            Text(
                fanControl.helperStatus == .unavailable
                    ? L10n.text(
                        "当前构建未被 macOS 识别为可注册的控制服务；请使用包含有效 Helper 且经 Developer ID 签名、公证的构建。",
                        "macOS does not recognize this build as a registrable control service. Use a build with a valid helper that is Developer ID signed and notarized."
                    )
                    : L10n.text(
                        "首次需管理员批准；失联或过热时恢复 macOS 控制。",
                        "Administrator approval once; macOS control resumes on disconnect or overheating."
                    )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder
    var fanControlReadOnlyNotice: some View {
        LabeledContent(
            L10n.text("硬件模式", "Hardware Mode"),
            value: L10n.text("只读 · 未验证", "Read Only · Unknown")
        )
        Text(fanControlReadOnlyReason)
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
            "辅助程序尚未完成受信任连接，写入模式保持隐藏。",
            "The helper has not completed a trusted connection, so write modes remain hidden."
        )
    }

    @ViewBuilder
    var fanControlConfiguration: some View {
        switch fanControl.selectedMode {
        case .systemAutomatic:
            LabeledContent(
                L10n.text("请求来源", "Requested Source"),
                value: "macOS"
            )
        case .fanSet:
            Picker(
                L10n.text("风扇组", "Fan Set"),
                selection: $fanControl.selectedFanSet
            ) {
                ForEach(FanControlSet.allCases) { fanSet in
                    Text(fanSet.title).tag(fanSet)
                }
            }
            .pickerStyle(.menu)
        case .customCurve:
            FanCurveEditor(
                fanControl: fanControl,
                fanReadings: fanHardwareReadings.fanReadings
            )
        case .manual:
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
            Text(L10n.text(
                "0% 对应每个风扇的硬件最小 RPM，100% 对应硬件最大 RPM。",
                "0% maps to each fan's hardware minimum RPM; 100% maps to its hardware maximum RPM."
            ))
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
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
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        case .maximum:
            LabeledContent(
                L10n.text("目标", "Target"),
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
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
