import SwiftUI

/// D272: the menu bar page's three parts: what the menu bar shows, what the
/// panel shows and how the panel looks. Everything about the menu bar is on
/// this page (the icon and the panel's look were on General, beside the
/// language and the login item).
enum SettingsMenuBarPage: String, CaseIterable, Identifiable {
    case icon
    case panelContent
    case panelAppearance

    static let defaultsKey = "settings.menu-bar-page.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: L10n.text("图标", "Icon")
        case .panelContent: L10n.text("小窗内容", "Panel Content")
        case .panelAppearance: L10n.text("小窗外观", "Panel Appearance")
        }
    }
}

extension SettingsView {
    var miniWindowSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L10n.text("菜单栏设置", "Menu bar settings"), selection: $menuBarPage) {
                ForEach(SettingsMenuBarPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .lightfieldComponentProbe("settings.menuBarPages")
            switch menuBarPage {
            case .icon:
                SettingsColumn { CombinedStatusIconSettingsSection() }
            case .panelContent:
                MiniWindowConfigurationSettingsView(draft: $miniWindowDraft)
            case .panelAppearance:
                SettingsPreviewColumns {
                    VStack(alignment: .leading, spacing: 24) { panelAppearanceSection }
                } preview: {
                    SettingsMiniWindowPreview(configuration: miniWindowDraft.value)
                } actions: {
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
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
            SettingsToggleRow(title: L10n.text("透明效果", "Vibrancy"),
                caption: L10n.text("选“匹配系统外观”时使用透明主题。", "Uses the transparent theme with System Appearance."),
                isOn: $menuThemeVibrancy)
        } header: { Text(L10n.text("主题", "Theme")) }
        LightfieldSettingsSection {
            SettingsExpandableRow(title: L10n.text("各指标独立颜色", "Individual Metric Colors"),
                metadata: L10n.text("18 项", "18 metrics"), expanded: $settingsMetricColorsExpanded) {
                ForEach(PanelMetricColorRole.allCases) { role in PanelMetricColorPicker(role: role) }
            }
        } header: { Text(L10n.text("颜色", "Colors")) }
    }
}
