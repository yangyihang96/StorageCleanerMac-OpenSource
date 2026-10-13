import AppKit
import ServiceManagement
import SwiftUI

extension SettingsView {
    var updateAutomationSection: some View {
        LightfieldSettingsSection {
            Toggle(
                L10n.text("自动检查更新", "Automatically Check for Updates"),
                isOn: updatePreferenceBinding(\.automaticallyChecks)
            )

            Picker(
                L10n.text("检查频率", "Check Frequency"),
                selection: updateFrequencyBinding
            ) {
                ForEach(ApplicationUpdateCheckFrequency.allCases) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
            .pickerStyle(.menu)
            .disabled(!applicationUpdatePreferences.automaticallyChecks)

            Toggle(
                L10n.text("自动安装可静默更新项目", "Automatically Install Silent Updates"),
                isOn: automaticSilentUpdateBinding
            )

            Toggle(
                L10n.text("应用退出后更新", "Update After an App Quits"),
                isOn: updatePreferenceBinding(\.updatesAfterApplicationQuits)
            )

            Toggle(
                L10n.text("更新完成后通知", "Notify When Updates Finish"),
                isOn: updatePreferenceBinding(\.notifiesOnCompletion)
            )
        } header: {
            Text(L10n.text("自动化", "Automation"))
        }
    }

    var updateSourceSection: some View {
        LightfieldSettingsSection {
            LabeledContent(
                L10n.text("Homebrew Formula", "Homebrew Formulae"),
                value: L10n.text("始终包含", "Always Included")
            )

            LabeledContent(
                L10n.text("带有自身更新器的 Homebrew Cask", "Self-updating Homebrew Casks"),
                value: L10n.text("始终检查", "Always Checked")
            )

            Text(L10n.text(
                "全部更新的检查范围包含字体、命令行工具和带有自身更新器的 Homebrew 软件。",
                "Update All checks include fonts, command-line tools and self-updating Homebrew software."
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                L10n.text("扫描外置磁盘中的应用", "Scan Applications on External Volumes"),
                isOn: updatePreferenceBinding(\.scansExternalVolumes)
            )

            DisclosureGroup(L10n.text("更新来源", "Update Sources")) {
                LabeledContent(
                    L10n.text("远程检查已启用", "Remote Checks Enabled"),
                    value: "\(updateSourceConfiguration.enabledCount)/\(AppUpdateMethod.allCases.count)"
                )

                ForEach(AppUpdateMethod.allCases) { method in
                    UpdateSourceOptionRow(
                        method: method,
                        isEnabled: Binding(
                            get: { updateSourceConfiguration.includes(method) },
                            set: { setUpdateSource(method, isEnabled: $0) }
                        )
                    )
                }

                if updateSourceConfiguration != .all {
                    Button {
                        resetUpdateSources()
                    } label: {
                        Text(L10n.text("恢复全部来源", "Enable All Sources"))
                    }
                }
            }

            Text(L10n.text(
                "关闭来源仅停止该来源的远程检查，不改变权限，也不影响存储清理助手自身的 Sparkle 更新。",
                "Disabling a source only stops its remote checks; permissions and Storage Cleaner's own Sparkle updates are unchanged."
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            SettingsNoticeView(
                notice: SettingsNotice(
                    text: L10n.text(
                        "App Store、官网与需授权的项目始终要求确认；签名变化会阻止自动安装。",
                        "App Store, website, and authorization flows always require confirmation; signing changes block automatic installation."
                    ),
                    systemImage: "lock.shield",
                    tint: AppDesignTokens.Palette.information,
                    severity: .information
                )
            )
        } header: {
            Text(
                L10n.text("范围与来源", "Coverage & Sources")
            )
        }
    }

    func updatePreferenceBinding(
        _ keyPath: WritableKeyPath<ApplicationUpdatePreferencesSnapshot, Bool>
    ) -> Binding<Bool> {
        Binding {
            applicationUpdatePreferences[keyPath: keyPath]
        } set: { newValue in
            applicationUpdatePreferences[keyPath: keyPath] = newValue
            ApplicationUpdatePreferences.set(applicationUpdatePreferences)
            if keyPath == \.notifiesOnCompletion, newValue {
                Task {
                    let granted = await ApplicationUpdateNotificationService.requestAuthorization()
                    guard !granted else { return }
                    await MainActor.run {
                        applicationUpdatePreferences.notifiesOnCompletion = false
                        ApplicationUpdatePreferences.set(applicationUpdatePreferences)
                    }
                }
            }
        }
    }

    var automaticSilentUpdateBinding: Binding<Bool> {
        Binding {
            applicationUpdatePreferences.automaticallyExecutesSilentUpdates
        } set: { isEnabled in
            applicationUpdatePreferences.setAutomaticSilentUpdateExecution(isEnabled)
            ApplicationUpdatePreferences.set(applicationUpdatePreferences)
        }
    }

    var updateFrequencyBinding: Binding<ApplicationUpdateCheckFrequency> {
        Binding {
            applicationUpdatePreferences.checkFrequency
        } set: { newValue in
            applicationUpdatePreferences.checkFrequency = newValue
            ApplicationUpdatePreferences.set(applicationUpdatePreferences)
        }
    }

    func setUpdateSource(_ method: AppUpdateMethod, isEnabled: Bool) {
        updateSourceConfiguration.set(method, isEnabled: isEnabled)
        AppUpdateSourcePreferences.setConfiguration(updateSourceConfiguration)
    }

    func resetUpdateSources() {
        AppUpdateSourcePreferences.reset()
        updateSourceConfiguration = AppUpdateSourcePreferences.configuration()
    }

}
