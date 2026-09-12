import SwiftUI

struct GeekDashboardEditor: View {
    @ObservedObject var state: MenuBarPanelSettingsState

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 12) {
                GroupBox(L10n.text("模块与顺序", "Modules & Order")) {
                    VStack(spacing: 0) {
                        ForEach(editableModules) { item in
                            moduleRow(item)
                                .frame(height: 38)
                        }
                    }
                    .padding(.horizontal, 8)
                }

                GroupBox(L10n.text("趋势范围", "Trend Range")) {
                    Picker(L10n.text("图表范围", "Chart Range"), selection: chartRangeBinding) {
                        ForEach(GeekChartRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(8)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .controlSize(.small)

            footer
        }
        .frame(width: 320, height: 500)
        .background(AppDesignTokens.Palette.contentBackground)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            AppSymbolIcon(systemImage: AppSymbols.Panel.settings, role: .panelHeader)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("自定义极客概览", "Customize Geek Overview"))
                    .font(AppPanelTypography.header)
                Text(L10n.text(
                    "\(editableModules.count) 个模块 · 拖动调整",
                    "\(editableModules.count) modules · Drag to arrange"
                ))
                    .font(AppPanelTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            AppIconButton(
                title: L10n.text("关闭自定义界面", "Close Customization"),
                systemImage: AppSymbols.Action.close,
                kind: .toolbar,
                action: state.cancelGeekEditor
            )
        }
        .padding(.horizontal, AppDesignTokens.Spacing.small)
        .frame(minHeight: 48)
        .background(.bar)
    }

    private var footer: some View {
        HStack {
            Button(L10n.text("恢复默认布局", "Restore Default Layout")) {
                state.resetGeekDashboardConfiguration()
            }
            .appButtonChrome(.tertiary)
            .help(L10n.text("恢复极客概览的默认模块、顺序和图表范围", "Restore the default Geek overview modules, order, and chart range"))

            Spacer()

            Button(L10n.text("完成", "Done")) {
                state.dismissGeekEditor()
            }
            .appButtonChrome(.primary)
            .keyboardShortcut(.defaultAction)
        }
        .padding(AppDesignTokens.Spacing.small)
        .background(.bar)
    }

    private var editableModules: [GeekDashboardModuleConfiguration] {
        state.geekDashboardConfiguration.modules.filter {
            $0.module.isAvailableInOverview
        }
    }

    private func moduleRow(_ item: GeekDashboardModuleConfiguration) -> some View {
        HStack(spacing: 8) {
            Image(systemName: AppSymbols.Panel.reorder)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .help(L10n.text("拖动调整顺序", "Drag to reorder"))
                .draggable(item.module.rawValue)
                .accessibilityHidden(true)

            Toggle(item.module.title, isOn: moduleVisibilityBinding(item.module))
                .toggleStyle(.checkbox)

            Spacer(minLength: 6)
        }
        .dropDestination(for: String.self) { values, _ in
            guard let rawValue = values.first,
                  let source = GeekDashboardModule(rawValue: rawValue),
                  source != item.module else { return false }
            state.updateGeekDashboardConfiguration { configuration in
                configuration.moveModule(source, before: item.module)
            }
            return true
        }
    }

    private func moduleVisibilityBinding(_ module: GeekDashboardModule) -> Binding<Bool> {
        Binding {
            state.geekDashboardConfiguration.modules.first(where: { $0.module == module })?.isVisible == true
        } set: { isVisible in
            state.updateGeekDashboardConfiguration { configuration in
                configuration.setModule(module, isVisible: isVisible)
            }
        }
    }

    private var chartRangeBinding: Binding<GeekChartRange> {
        Binding {
            state.geekDashboardConfiguration.chartRange
        } set: { range in
            state.updateGeekDashboardConfiguration { configuration in
                configuration.chartRange = range
            }
        }
    }

}
