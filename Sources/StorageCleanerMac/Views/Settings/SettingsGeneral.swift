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

    var selectedMiniWindowAppearance: Binding<MiniWindowAppearance> {
        Binding {
            MiniWindowAppearance(rawValue: miniWindowAppearanceRawValue) ?? .system
        } set: { appearance in
            miniWindowAppearanceRawValue = appearance.rawValue
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
            Picker(L10n.text("小窗外观", "Mini Window Appearance"), selection: selectedMiniWindowAppearance) {
                ForEach(MiniWindowAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
            }.pickerStyle(.segmented)
            SettingsPalettePicker(title: L10n.text("菜单栏项目颜色", "Menu Bar Item Colors"),
                items: PanelStatusColorPreset.allCases, selection: selectedStatusPreset,
                name: { $0.title }, color: {
                    $0.ink(dark: colorScheme == .dark, customDayHex: statusCustomDayHex, customNightHex: statusCustomNightHex)
                        .map(Color.init(nsColor:)) ?? MiniWindowColorPalette.secondaryText
                })
            if selectedStatusPreset.wrappedValue == .custom {
                ColorPicker(L10n.text("菜单栏日间颜色", "Menu Bar Day Color"),
                    selection: statusColorBinding(storedValue: $statusCustomDayHex, dark: false), supportsOpacity: false)
                ColorPicker(L10n.text("菜单栏夜间颜色", "Menu Bar Night Color"),
                    selection: statusColorBinding(storedValue: $statusCustomNightHex, dark: true), supportsOpacity: false)
            }
            SettingsPalettePicker(title: L10n.text("展开菜单底色", "Expanded Menu Background"),
                items: PanelSurfacePreset.allCases, selection: selectedSurfacePreset,
                name: { $0.title }, color: { $0.palette(for: colorScheme == .dark ? .black : .graphite)?.shell ?? MiniWindowColorPalette.secondaryText })
            SettingsPalettePicker(title: L10n.text("图表颜色", "Chart Colors"),
                items: PanelColorTheme.allCases, selection: selectedPanelColorTheme,
                name: panelColorThemeTitle, color: {
                    PanelAppearancePreferences.color(from: $0.chartHex ?? $0.backgroundHex ?? "") ?? MiniWindowColorPalette.blue
                })
            if selectedPanelColorTheme.wrappedValue == .custom {
                if selectedSurfacePreset.wrappedValue == .original {
                    ColorPicker(L10n.text("小窗背景色", "Panel Background Color"),
                        selection: panelBackgroundColorBinding, supportsOpacity: false)
                }
                ColorPicker(L10n.text("柱状图颜色", "Bar Chart Color"),
                    selection: panelChartColorBinding, supportsOpacity: false)
            }
            LightfieldExpandableRow(title: L10n.text("各指标独立颜色", "Individual Metric Colors"),
                metadata: L10n.text("18 项", "18 metrics"), expanded: $settingsMetricColorsExpanded) { EmptyView() } content: {
                ForEach(PanelMetricColorRole.allCases) { role in PanelMetricColorPicker(role: role) }
            }
        } header: { Text(L10n.text("菜单栏小窗", "Menu-Bar Panel")) }
    }

    var selectedPanelColorTheme: Binding<PanelColorTheme> {
        Binding {
            PanelColorTheme.resolved(
                storedTheme: panelColorThemeRawValue,
                backgroundHex: panelBackgroundColor,
                chartHex: panelChartColor
            )
        } set: { theme in
            panelColorThemeRawValue = theme.rawValue
            guard theme != .custom else {
                seedCustomPanelColorsIfNeeded()
                return
            }
            panelBackgroundColor = theme.backgroundHex ?? ""
            panelChartColor = theme.chartHex ?? ""
        }
    }

    var selectedStatusPreset: Binding<PanelStatusColorPreset> {
        Binding {
            PanelStatusColorPreset(rawValue: panelStatusPresetRaw) ?? .original
        } set: { panelStatusPresetRaw = $0.rawValue }
    }

    var selectedSurfacePreset: Binding<PanelSurfacePreset> {
        Binding {
            PanelSurfacePreset(rawValue: panelSurfacePresetRaw) ?? .original
        } set: { panelSurfacePresetRaw = $0.rawValue }
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

    func panelColorThemeTitle(_ theme: PanelColorTheme) -> String {
        switch theme {
        case .system:
            L10n.text("跟随系统", "System")
        case .ocean:
            L10n.text("海洋蓝", "Ocean")
        case .violet:
            L10n.text("紫罗兰", "Violet")
        case .mint:
            L10n.text("薄荷绿", "Mint")
        case .graphite:
            L10n.text("石墨底 · 彩色数据", "Graphite · Data Colors")
        case .custom:
            L10n.text("自定义", "Custom")
        }
    }

    func seedCustomPanelColorsIfNeeded() {
        if PanelAppearancePreferences.normalizedHex(panelBackgroundColor) == nil {
            panelBackgroundColor = "#48484A"
        }
        if PanelAppearancePreferences.normalizedHex(panelChartColor) == nil {
            panelChartColor = "#0A84FF"
        }
    }

    var panelBackgroundColorBinding: Binding<Color> {
        colorBinding(
            storedValue: $panelBackgroundColor,
            fallback: Color(nsColor: .windowBackgroundColor)
        )
    }

    var panelChartColorBinding: Binding<Color> {
        colorBinding(
            storedValue: $panelChartColor,
            fallback: AppChartPalette.cpuUser
        )
    }

    func colorBinding(
        storedValue: Binding<String>,
        fallback: Color
    ) -> Binding<Color> {
        Binding {
            PanelAppearancePreferences.color(from: storedValue.wrappedValue) ?? fallback
        } set: { color in
            if let value = PanelAppearancePreferences.hexString(from: color) {
                panelColorThemeRawValue = PanelColorTheme.custom.rawValue
                storedValue.wrappedValue = value
            }
        }
    }

}
