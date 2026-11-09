import AppKit
import ServiceManagement
import SwiftUI

extension SettingsView {
    var selectedLanguage: Binding<AppLanguage> {
        Binding {
            AppLanguage(rawValue: languageRawValue) ?? .system
        } set: { newValue in
            languageRawValue = newValue.rawValue
        }
    }

    var selectedAppearance: Binding<AppAppearance> {
        Binding {
            AppAppearance(rawValue: appearanceRawValue) ?? .system
        } set: { newValue in
            appearanceRawValue = newValue.rawValue
            newValue.applyAppKitPreference()
        }
    }

    /// D53: the night canvas of the main window (pure black by default,
    /// deep space as the optional comparison theme).
    var selectedCanvasTheme: Binding<AppCanvasTheme> {
        Binding {
            AppCanvasTheme.resolve(rawValue: canvasThemeRawValue)
        } set: { newValue in
            canvasThemeRawValue = newValue.rawValue
        }
    }

    /// D135: iStat's theme for each appearance (`Menu.Theme.Dark`,
    /// `Menu.Theme.Light`); they replace the former mini-window appearance,
    /// dropdown surface and chart color choices.
    func menuThemeBinding(_ storedID: Binding<String>, isDark: Bool) -> Binding<IStatMenuThemeChoice> {
        Binding {
            IStatMenuThemeChoice.stored(storedID.wrappedValue, isDark: isDark)
        } set: { choice in
            storedID.wrappedValue = choice.id
        }
    }

    var interfaceSection: some View {
        LightfieldSettingsSection {
            SettingsPickerRow(title: L10n.text("界面语言", "Interface Language"), selection: selectedLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title)
                        .tag(language)
                }
            }

            SettingsPickerRow(title: L10n.text("外观", "Appearance"), selection: selectedAppearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title)
                        .tag(appearance)
                }
            }

            SettingsPickerRow(title: L10n.text("夜间底色", "Night Canvas"), selection: selectedCanvasTheme) {
                ForEach(AppCanvasTheme.allCases) { theme in
                    Text(theme.title)
                        .tag(theme)
                }
            }
        } header: {
            Text(L10n.text("界面", "Interface"))
        }
    }

    var launchBehaviorSection: some View {
        LightfieldSettingsSection {
            SettingsToggleRow(
                title: L10n.text("登录后自动打开存储清理助手", "Open Storage Cleaner at Login"),
                caption: launchAtLoginCaption,
                isOn: launchAtLoginBinding
            )
            .disabled(isChangingLaunchAtLogin || launchAtLoginStatus == nil)

            KeepMenuBarPanelAfterQuitToggle()

            if launchAtLoginStatus == .requiresApproval {
                SettingsLinkRow(title: L10n.text("打开登录项设置", "Open Login Item Settings")) {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }

            if let launchAtLoginNotice {
                SettingsNoticeView(notice: launchAtLoginNotice)
            }
        } header: {
            Text(L10n.text("启动与退出", "Startup & Quit"))
        }
    }

    /// The switch already says on or off; the system's state is shown only
    /// while it says something else.
    var launchAtLoginCaption: String? {
        switch launchAtLoginStatus {
        case .requiresApproval?, .notFound?: launchAtLoginStatusTitle
        default: nil
        }
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding {
            launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
        } set: { shouldLaunch in
            setLaunchAtLogin(shouldLaunch)
        }
    }

    var launchAtLoginStatusTitle: String {
        guard let launchAtLoginStatus else { return L10n.text("正在读取…", "Reading…") }
        return switch launchAtLoginStatus {
        case .enabled:
            L10n.text("已开启", "Enabled")
        case .requiresApproval:
            L10n.text("等待系统批准", "Awaiting System Approval")
        case .notRegistered:
            L10n.text("已关闭", "Disabled")
        case .notFound:
            L10n.text("当前构建不可用", "Unavailable in This Build")
        @unknown default:
            L10n.text("未知", "Unknown")
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginReadTask?.cancel()
        launchAtLoginReadTask = Task { @MainActor in
            // SMAppService.status is a synchronous XPC query. In particular,
            // never evaluate it in a State initializer when the App rebuilds
            // its hidden Settings scene in response to monitoring updates.
            let status = await Task.detached(priority: .utility) {
                SMAppService.mainApp.status
            }.value
            guard !Task.isCancelled else { return }
            launchAtLoginStatus = status
        }
    }

    func setLaunchAtLogin(_ shouldLaunch: Bool) {
        guard !isChangingLaunchAtLogin, launchAtLoginStatus != nil else { return }
        // D106: macOS announces a login item change on the menu-bar display,
        // and an acceptance session changes no system setting.
        guard DisplayConfinementGate.shared.permitsExternal(
            "SMAppService.mainApp", detail: shouldLaunch ? "register" : "unregister"
        ) else {
            launchAtLoginNotice = SettingsNotice.launchAtLoginFailure(
                L10n.text("验收模式不更改登录项。", "Acceptance mode does not change login items.")
            )
            return
        }
        launchAtLoginReadTask?.cancel()
        isChangingLaunchAtLogin = true
        launchAtLoginNotice = nil

        Task { @MainActor in
            let service = SMAppService.mainApp
            do {
                switch (shouldLaunch, service.status) {
                case (true, .notRegistered), (true, .notFound):
                    try service.register()
                case (false, .enabled), (false, .requiresApproval):
                    try service.unregister()
                default:
                    break
                }
                launchAtLoginStatus = service.status
                launchAtLoginNotice = SettingsNotice.launchAtLoginResult(
                    requiresApproval: launchAtLoginStatus == .requiresApproval,
                    shouldLaunch: shouldLaunch
                )
            } catch {
                launchAtLoginStatus = service.status
                launchAtLoginNotice = SettingsNotice.launchAtLoginFailure(error.localizedDescription)
            }
            isChangingLaunchAtLogin = false
        }
    }
}

/// D256: General → Launch Behavior. On by default: quitting closes the main
/// program and the menu-bar panel keeps running; Quit Completely is in the
/// panel's More menu. A login launch then opens the panel alone (D258).
struct KeepMenuBarPanelAfterQuitToggle: View {
    @AppStorage(AppQuitPreferences.keepsMenuBarPanelKey) private var keepsPanel = true

    var body: some View {
        SettingsToggleRow(
            title: L10n.text("退出主程序后保留菜单栏小窗", "Keep the Menu Bar Panel After Quitting"),
            caption: L10n.text(
                "退出主程序后小窗继续在菜单栏运行；要连小窗一起退出，用小窗“更多”菜单里的“完全退出”。",
                "The panel keeps running in the menu bar after you quit. To quit it too, choose Quit Completely in the panel's More menu."),
            isOn: $keepsPanel)
    }
}
