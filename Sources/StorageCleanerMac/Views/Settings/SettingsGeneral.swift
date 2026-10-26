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
            Picker(L10n.text("界面语言", "Interface Language"), selection: selectedLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title)
                        .tag(language)
                }
            }
            .pickerStyle(.menu)

            Picker(L10n.text("外观", "Appearance"), selection: selectedAppearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title)
                        .tag(appearance)
                }
            }
            .pickerStyle(.menu)

            Picker(L10n.text("底色主题", "Night Canvas"), selection: selectedCanvasTheme) {
                ForEach(AppCanvasTheme.allCases) { theme in
                    Text(theme.title)
                        .tag(theme)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text(L10n.text("界面", "Interface"))
        }
    }

    var launchBehaviorSection: some View {
        LightfieldSettingsSection {
            Toggle(
                L10n.text("登录后自动打开存储清理助手", "Open Storage Cleaner at Login"),
                isOn: launchAtLoginBinding
            )
            .disabled(isChangingLaunchAtLogin || launchAtLoginStatus == nil)

            LabeledContent(
                L10n.text("系统状态", "System Status"),
                value: launchAtLoginStatusTitle
            )

            Button {
                SMAppService.openSystemSettingsLoginItems()
            } label: {
                Text(
                    L10n.text("打开登录项设置", "Open Login Item Settings")
                )
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())

            if let launchAtLoginNotice {
                SettingsNoticeView(notice: launchAtLoginNotice)
            }
        } header: {
            Text(L10n.text("启动行为", "Launch Behavior"))
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

    var generalSettings: some View {
        SettingsPreviewColumns {
            VStack(alignment: .leading, spacing: 20) {
                LightfieldExpandableRow(title: L10n.text("界面", "Interface"),
                    metadata: selectedAppearance.wrappedValue.title + " · " + selectedLanguage.wrappedValue.title,
                    expanded: $settingsInterfaceExpanded) { EmptyView() } content: { interfaceSection }
                panelAppearanceSection
                CombinedStatusIconSettingsSection()
                launchBehaviorSection
            }
        } preview: {
            SettingsMiniWindowPreview(configuration: settingsConfiguration.configuration)
        } actions: {
            Text(L10n.text("偏好更改即时保存", "Preferences save immediately"))
                .font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
        }
    }

    var panelAppearanceSection: some View {
        LightfieldSettingsSection {
            // D135: iStat's menu themes, one for the dark appearance and one
            // for the light (both indigo by default); 匹配系统外观 picks dark
            // or light, transparent while 透明效果 is on.
            SettingsPalettePicker(title: L10n.text("深色外观主题", "Dark Appearance Theme"),
                items: IStatMenuThemeChoice.all, selection: menuThemeBinding($menuThemeDarkID, isDark: true),
                name: { $0.name }, color: { $0.swatch(isDark: true, vibrancy: menuThemeVibrancy) })
            SettingsPalettePicker(title: L10n.text("浅色外观主题", "Light Appearance Theme"),
                items: IStatMenuThemeChoice.all, selection: menuThemeBinding($menuThemeLightID, isDark: false),
                name: { $0.name }, color: { $0.swatch(isDark: false, vibrancy: menuThemeVibrancy) })
            Toggle(L10n.text("透明效果", "Vibrancy"), isOn: $menuThemeVibrancy)
                .help(L10n.text("选“匹配系统外观”时使用透明主题。", "Uses the transparent theme with System Appearance."))
            SettingsPalettePicker(title: L10n.text("菜单栏项目颜色", "Menu Bar Item Colors"),
                items: PanelStatusColorPreset.allCases, selection: selectedStatusPreset,
                name: { $0.title }, color: {
                    $0.ink(dark: colorScheme == .dark, customDayHex: statusCustomDayHex, customNightHex: statusCustomNightHex)
                        .map(Color.init(nsColor:)) ?? MiniWindowColorPalette.secondaryText
                }, isCustom: { $0 == .custom })
            if selectedStatusPreset.wrappedValue == .custom {
                ColorPicker(L10n.text("菜单栏日间颜色", "Menu Bar Day Color"),
                    selection: statusColorBinding(storedValue: $statusCustomDayHex, dark: false), supportsOpacity: false)
                ColorPicker(L10n.text("菜单栏夜间颜色", "Menu Bar Night Color"),
                    selection: statusColorBinding(storedValue: $statusCustomNightHex, dark: true), supportsOpacity: false)
            }
            LightfieldExpandableRow(title: L10n.text("各指标独立颜色", "Individual Metric Colors"),
                metadata: L10n.text("18 项", "18 metrics"), expanded: $settingsMetricColorsExpanded) { EmptyView() } content: {
                ForEach(PanelMetricColorRole.allCases) { role in PanelMetricColorPicker(role: role) }
            }
            // D136: iStat's Statistics › Reset Disk Filtering shows every
            // hidden volume again.
            LabeledContent(L10n.text("隐藏的磁盘", "Hidden Disks"), value: hiddenDiskCountTitle)
                .help(L10n.text("在小窗磁盘卷详情的右上角隐藏磁盘卷。", "Hide a volume from the top-right corner of its detail in the panel."))
            Button {
                hiddenDiskKeysRaw = ""
            } label: {
                Text(L10n.text("显示隐藏的磁盘", "Show Hidden Disks"))
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .disabled(hiddenDiskCount == 0)
        } header: { Text(L10n.text("菜单栏小窗", "Menu-Bar Panel")) }
    }

    var hiddenDiskCount: Int {
        MiniWindowHiddenItems.keys(from: hiddenDiskKeysRaw).count
    }

    var hiddenDiskCountTitle: String {
        hiddenDiskCount == 0
            ? L10n.text("无", "None")
            : L10n.text("\(ByteFormat.count(hiddenDiskCount)) 个", ByteFormat.count(hiddenDiskCount))
    }

    var selectedStatusPreset: Binding<PanelStatusColorPreset> {
        Binding {
            PanelStatusColorPreset(rawValue: panelStatusPresetRaw) ?? .original
        } set: { panelStatusPresetRaw = $0.rawValue }
    }

    func statusColorBinding(storedValue: Binding<String>, dark: Bool) -> Binding<Color> {
        Binding {
            PanelAppearancePreferences.color(from: storedValue.wrappedValue)
                ?? Color(nsColor: PanelStatusColorPreset.blue.ink(dark: dark) ?? .systemBlue)
        } set: { color in
            if let value = PanelAppearancePreferences.hexString(from: color) {
                storedValue.wrappedValue = value
            }
        }
    }

}
