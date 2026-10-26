import AppKit
import CombinedStatusIcon
import SwiftUI

/// D153: Status Trio's icon settings for the 组合状态 menu-bar display: its
/// size, ring, battery, connection, volume and Bluetooth-audio options with
/// the same labels, defaults, ranges, steps and conditions. Each value is one
/// key the status item reads again on change (`CombinedStatusIconPreferences`).
/// Not here, as not part of this app: the Dock icon, the popover, the glyph
/// of one picked Bluetooth device, Low Power Mode control and the
/// charging-effect test.
struct CombinedStatusIconSettingsSection: View {
    private typealias Keys = CombinedStatusIconPreferences
    private typealias Limits = CombinedStatusIconSettings

    @Environment(\.colorScheme) private var scheme
    @AppStorage(MenuBarStatusDisplayMode.defaultsKey) private var statusModeRaw = ""
    @AppStorage(PanelPalettePreferences.statusThemeKey) private var statusPresetRaw = ""
    @AppStorage(PanelPalettePreferences.statusCustomDayKey) private var statusCustomDayHex = ""
    @AppStorage(PanelPalettePreferences.statusCustomNightKey) private var statusCustomNightHex = ""
    @AppStorage(Keys.iconSizeKey) private var iconSize = Limits.defaultIconSize
    @AppStorage(Keys.ringStrokeStyleKey) private var ringStrokeStyleRaw = RingStrokeStyle.regular.rawValue
    @AppStorage(Keys.showsBatteryPercentageKey) private var showsBatteryPercentage = true
    @AppStorage(Keys.showsBatteryPercentageInConnectionSlotKey) private var showsBatteryPercentageInConnectionSlot = false
    @AppStorage(Keys.showsChargingIndicatorKey) private var showsChargingIndicator = true
    @AppStorage(Keys.showsChargingEffectKey) private var showsChargingEffect = true
    @AppStorage(Keys.showsChargingBoltHeartbeatKey) private var showsChargingBoltHeartbeat = true
    @AppStorage(Keys.showsPercentageWhenConnectedKey) private var showsPercentageWhenConnected = false
    @AppStorage(Keys.batterySymbolScaleKey) private var batterySymbolScale = Limits.defaultBatterySymbolScale
    @AppStorage(Keys.usesBatteryStatusColorsKey) private var usesBatteryStatusColors = true
    @AppStorage(Keys.batteryCriticalThresholdKey) private var batteryCriticalThreshold = Limits.defaultBatteryCriticalThreshold
    @AppStorage(Keys.batteryFullThresholdKey) private var batteryFullThreshold = Limits.defaultBatteryFullThreshold
    @AppStorage(Keys.wifiSymbolScaleKey) private var wifiSymbolScale = Limits.defaultCenterSymbolScale
    @AppStorage(Keys.showsWiFiIconForEthernetKey) private var showsWiFiIconForEthernet = false
    @AppStorage(Keys.showsWiFiIconForHotspotKey) private var showsWiFiIconForHotspot = false
    @AppStorage(Keys.showsWiFiIconForTemporaryConnectionKey) private var showsWiFiIconForTemporaryConnection = false
    @AppStorage(Keys.showsWiFiIconForInternetSharingKey) private var showsWiFiIconForInternetSharing = false
    @AppStorage(Keys.volumeDisplayStyleKey) private var volumeDisplayStyleRaw = VolumeDisplayStyle.dots.rawValue
    @AppStorage(Keys.bluetoothSymbolScaleKey) private var bluetoothSymbolScale = Limits.defaultCenterSymbolScale
    @AppStorage(Keys.replacesNetworkIconWithBluetoothAudioKey) private var replacesNetworkIconWithBluetoothAudio = false
    @AppStorage(Keys.bluetoothAudioIconChoiceKey) private var bluetoothAudioIconChoiceRaw = BluetoothAudioIconChoice.automatic.rawValue
    @AppStorage(Keys.usesBluetoothAudioVolumeColorKey) private var usesBluetoothAudioVolumeColor = false
    @AppStorage(Keys.prioritizesNetworkErrorsOverBluetoothAudioKey) private var prioritizesNetworkErrorsOverBluetoothAudio = true
    @State private var batteryExpanded: Bool
    @State private var connectionExpanded: Bool
    @State private var bluetoothExpanded: Bool
    @State private var chargeLimitReadable = true

    init(expandsGroups: Bool = false) {
        _batteryExpanded = State(initialValue: expandsGroups)
        _connectionExpanded = State(initialValue: expandsGroups)
        _bluetoothExpanded = State(initialValue: expandsGroups)
    }

    /// The choices this macOS has a glyph for, as Status Trio lists them.
    private static let iconChoices = BluetoothAudioIconChoice.availableChoices { symbol in
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
    }

    /// Shown while the combined icon is not running: every region drawn.
    static let sampleSnapshot = StatusSnapshot(
        battery: BatteryStatus(rawPercentage: 76, isPresent: true, isCharging: false,
                               isLowPowerMode: false, isConnectedToPower: false),
        wifi: WiFiStatus(state: .connected, rssi: -55),
        connection: .wifi,
        volume: VolumeStatus(scalar: 0.5, isMuted: false, deviceName: nil)
    )

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        LightfieldSettingsSection {
            Picker(L10n.text("菜单栏常驻显示", "Menu Bar Display"), selection: statusModeBinding) {
                ForEach(MenuBarStatusDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
#if DEBUG
            .layoutProbe(Self.rowProbe + "mode")
#endif
            preview(palette: palette)
#if DEBUG
                .layoutProbe(Self.rowProbe + "preview")
#endif
            sliderRow(L10n.text("图标渲染范围", "Icon Size"),
                      L10n.text("调整菜单栏图标的渲染尺寸，可选 16–36 pt。",
                                "Adjusts the menu bar icon render size from 16–36 pt."),
                      slider: Self.iconSizeSlider, stored: $iconSize, palette: palette)
            labeledRow(L10n.text("外环线条粗细", "Ring Stroke Width"),
                       L10n.text("调整菜单栏图标状态环线条的粗细。",
                                 "Adjust the line thickness of the status ring in the menu bar icon."),
                       palette: palette) {
                Picker(L10n.text("外环线条粗细", "Ring Stroke Width"), selection: ringStrokeBinding) {
                    Text(L10n.text("细", "Light")).tag(RingStrokeStyle.light)
                    Text(L10n.text("正常", "Regular")).tag(RingStrokeStyle.regular)
                    Text(L10n.text("粗", "Bold")).tag(RingStrokeStyle.bold)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            LightfieldExpandableRow(title: L10n.text("电池显示", "Battery Display"),
                                    expanded: $batteryExpanded) { EmptyView() } content: {
                childRows { batteryRows(palette: palette) }
            }
            LightfieldExpandableRow(title: L10n.text("连接图标样式", "Connection Icon Style"),
                                    expanded: $connectionExpanded) { EmptyView() } content: {
                childRows { connectionRows(palette: palette) }
            }
            labeledRow(L10n.text("音量指示样式", "Volume Indicator Style"),
                       L10n.text("选择在状态环底部显示为四个离散点还是连续圆弧条。",
                                 "Choose whether volume displays as four discrete dots or a continuous bottom arc."),
                       palette: palette) {
                Picker(L10n.text("显示样式", "Display Style"), selection: volumeStyleBinding) {
                    Text(L10n.text("四个点", "Dots")).tag(VolumeDisplayStyle.dots)
                    Text(L10n.text("圆弧条", "Arc")).tag(VolumeDisplayStyle.arc)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            LightfieldExpandableRow(title: L10n.text("蓝牙音频", "Bluetooth Audio"),
                                    expanded: $bluetoothExpanded) { EmptyView() } content: {
                childRows { bluetoothRows(palette: palette) }
            }
        } header: {
            Text(L10n.text("组合状态图标", "Combined Status Icon"))
        }
        .onAppear { chargeLimitReadable = SystemChargeLimitReader.chargeLimit() != nil }
    }

    // MARK: - Rows

    @ViewBuilder
    private func batteryRows(palette: FeatureLightfieldPalette) -> some View {
        toggleRow(L10n.text("显示电量数字", "Show battery percentage"), nil,
                  isOn: $showsBatteryPercentage, palette: palette)
        toggleRow(L10n.text("在连接位置显示电量数字", "Show battery percentage in the connection position"),
                  L10n.text("替换 Wi-Fi 或连接图标；此选项与顶部电池指示器可分别开启。",
                            "Replaces the Wi-Fi or connection symbol. This is independent from the top battery indicator."),
                  isOn: $showsBatteryPercentageInConnectionSlot, palette: palette)
        toggleRow(L10n.text("充电/连接电源时显示指示图标", "Show an indicator while charging or connected to power"),
                  L10n.text("开启后，正在充电或已连接电源时，电量数字会替换为闪电或插头图标；关闭则继续显示数字。",
                            "When enabled, the percentage becomes a bolt or plug while charging or connected to power."),
                  isOn: $showsChargingIndicator, palette: palette)
        toggleRow(L10n.text("充电动效", "Charging effect"),
                  L10n.text("仅在充电时显示动态高光；开启“减弱动态效果”时停止。",
                            "Animate the highlight only while charging. Stops when Reduce Motion is on."),
                  isOn: $showsChargingEffect, palette: palette)
        toggleRow(L10n.text("闪电心跳", "Charging bolt pulse"),
                  L10n.text("关闭后闪电保持原有大小和颜色；充电圆弧动效仍会继续。",
                            "Turn off to keep the bolt at its usual size and color; the charging arc effect continues."),
                  isOn: $showsChargingBoltHeartbeat, palette: palette)
            .disabled(!showsChargingEffect || !showsChargingIndicator)
        if showsChargingIndicator && showsBatteryPercentage {
            toggleRow(L10n.text("已连接电源但未充电时显示电量数字", "Show the percentage while connected without charging"),
                      L10n.text("开启后，已连接电源但未充电时显示电量数字，而不是插头图标。",
                                "When enabled, a connected power source that is not charging shows the percentage instead of the plug."),
                      isOn: $showsPercentageWhenConnected, palette: palette)
        }
        if showsBatteryPercentage || showsChargingIndicator {
            sliderRow(L10n.text("电量数字/闪电大小", "Percentage/bolt size"),
                      L10n.text("数字和闪电使用同一尺寸，调整这里会同步改变两者。", "The percentage and bolt share this size."),
                      slider: Self.batterySymbolScaleSlider, stored: $batterySymbolScale,
                      accessibilityLabel: L10n.text("电量数字和闪电大小", "Battery percentage and bolt size"),
                      palette: palette)
        }
        toggleRow(L10n.text("根据状态改变圆弧颜色", "Color the arc by battery state"),
                  L10n.text("低电量显示红色，省电模式显示黄色，连接电源或正在充电显示绿色。关闭后圆弧使用普通前景色。",
                            "Low battery is red, Low Power Mode is yellow, and charging or connected power is green."),
                  isOn: $usesBatteryStatusColors, palette: palette)
        if usesBatteryStatusColors {
            sliderRow(L10n.text("低电量阈值", "Low battery threshold"),
                      L10n.text("低于该阈值时视为低电量，并使用红色。",
                                "Battery levels below this threshold are treated as low and shown in red."),
                      slider: Self.batteryCriticalThresholdSlider, stored: $batteryCriticalThreshold,
                      palette: palette)
        }
        VStack(alignment: .leading, spacing: 0) {
            sliderRow(L10n.text("圆环满格电量", "Full ring level"),
                      L10n.text("电量达到该值时圆环即视为满格。适合充电上限设置在 100% 以下的场景。",
                                "The battery ring counts as full at this level. Useful when charge limiting holds the battery below 100%."),
                      slider: Self.batteryFullThresholdSlider, stored: $batteryFullThreshold, palette: palette)
            // Status Trio's one-shot link: fills the level in from the limit
            // macOS keeps in powerd's preference; nothing follows it later.
            Button(L10n.text("使用充电上限", "Use the charge limit")) {
                guard let limit = SystemChargeLimitReader.chargeLimit() else {
                    chargeLimitReadable = false
                    return
                }
                batteryFullThreshold = Self.batteryFullThresholdSlider.written(Double(limit))
            }
            .buttonStyle(.link).font(.system(size: 12)).disabled(!chargeLimitReadable)
            if !chargeLimitReadable {
                Text(L10n.text("这台 Mac 未上报充电上限，无法读取该值。",
                               "This Mac does not report its charge limit, so the value cannot be read."))
                    .font(.system(size: 12)).foregroundStyle(palette.fg2).padding(.top, 4)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func connectionRows(palette: FeatureLightfieldPalette) -> some View {
        sliderRow(L10n.text("Wi-Fi 图标大小", "Wi-Fi Icon Size"),
                  L10n.text("调节状态环内的 Wi-Fi 图标缩放比例（100% - 180%）。",
                            "Scales the Wi-Fi icon inside the status ring from 100% to 180%."),
                  slider: Self.centerSymbolScaleSlider, stored: $wifiSymbolScale, palette: palette)
        Text(L10n.text("启用后，对应状态改用普通 Wi‑Fi 信号图标，不再显示其专用标记。",
                       "When enabled, the selected state uses the standard Wi-Fi signal icon instead of its special mark."))
            .font(.system(size: 12)).foregroundStyle(palette.fg2)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
        toggleRow(L10n.text("有线连接使用 Wi‑Fi 图标", "Use Wi-Fi icon for Ethernet"), nil,
                  isOn: $showsWiFiIconForEthernet, palette: palette)
        toggleRow(L10n.text("个人热点使用 Wi‑Fi 图标", "Use Wi-Fi icon for Personal Hotspot"), nil,
                  isOn: $showsWiFiIconForHotspot, palette: palette)
        toggleRow(L10n.text("临时连接使用 Wi‑Fi 图标", "Use Wi-Fi icon for Temporary Connection"), nil,
                  isOn: $showsWiFiIconForTemporaryConnection, palette: palette)
        toggleRow(L10n.text("互联网共享使用 Wi‑Fi 图标", "Use Wi-Fi icon for Internet Sharing"), nil,
                  isOn: $showsWiFiIconForInternetSharing, palette: palette)
    }

    @ViewBuilder
    private func bluetoothRows(palette: FeatureLightfieldPalette) -> some View {
        sliderRow(L10n.text("蓝牙图标大小", "Bluetooth icon size"),
                  L10n.text("调节状态环内蓝牙设备图标的缩放比例（100% - 180%）。",
                            "Scales the Bluetooth device icon inside the status ring from 100% to 180%."),
                  slider: Self.centerSymbolScaleSlider, stored: $bluetoothSymbolScale, palette: palette)
        toggleRow(L10n.text("使用蓝牙设备图标代替网络图标", "Replace the network icon with a Bluetooth device icon"),
                  L10n.text("用当前蓝牙音频设备的蓝色图标替代 Wi‑Fi 图标。",
                            "Replace the Wi-Fi icon with the current Bluetooth audio device's icon in blue."),
                  isOn: $replacesNetworkIconWithBluetoothAudio, palette: palette)
        if replacesNetworkIconWithBluetoothAudio {
            labeledRow(L10n.text("蓝牙音频图标", "Choose Bluetooth audio icon"),
                       L10n.text("选择用于网络连接图标的蓝牙音频符号。“自动”将跟随当前蓝牙音频设备。",
                                 "Choose the Bluetooth audio glyph for the network connection icon. Automatic follows the current Bluetooth audio device."),
                       palette: palette) {
                Picker(L10n.text("蓝牙音频图标", "Choose Bluetooth audio icon"), selection: iconChoiceBinding) {
                    ForEach(Self.iconChoices) { choice in
                        Text(Self.displayName(choice)).tag(choice)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 200)
            }
        }
        toggleRow(L10n.text("蓝牙音量使用蓝色", "Use blue for Bluetooth volume"),
                  L10n.text("蓝牙输出音频时，音量点或圆弧的活动部分显示为蓝色。",
                            "The active volume dots or arc turn blue while audio is playing through Bluetooth."),
                  isOn: $usesBluetoothAudioVolumeColor, palette: palette)
        toggleRow(L10n.text("网络异常优先于蓝牙图标", "Let network errors take priority"),
                  L10n.text("断网或无网络时仍显示网络图标，不显示蓝牙设备图标。",
                            "Connection errors and offline states keep the network icon instead of the Bluetooth device icon."),
                  isOn: $prioritizesNetworkErrorsOverBluetoothAudio, palette: palette)
    }

    // MARK: - Preview

    /// The icon as the item draws it (a still frame), on a light and a dark
    /// menu bar, in the menu-bar item colour chosen above.
    private func preview(palette: FeatureLightfieldPalette) -> some View {
        let settings = currentSettings
        let snapshot = MenuBarStatusController.shared.combinedStatusSnapshot ?? Self.sampleSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                previewTile(dark: false, snapshot: snapshot, settings: settings)
                previewTile(dark: true, snapshot: snapshot, settings: settings)
            }
            Text(L10n.text("实时预览 · 调节下方各项参数即刻在上方呈现",
                           "Live Preview · Adjust settings below to see changes immediately"))
                .font(.system(size: 11)).foregroundStyle(palette.fg3)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("组合状态图标预览", "Combined status icon preview"))
        .accessibilityValue(CombinedStatusIconSummary.text(snapshot))
    }

    private func previewTile(dark: Bool, snapshot: StatusSnapshot, settings: CombinedStatusIconSettings) -> some View {
        let preset = PanelStatusColorPreset(rawValue: statusPresetRaw) ?? .original
        let ink = preset.ink(dark: dark, customDayHex: statusCustomDayHex, customNightHex: statusCustomNightHex)
        let image = CombinedStatusIconStatusItemPresenter.previewImage(
            snapshot: snapshot, settings: settings, size: CGFloat(settings.iconSize), scale: 2,
            appearance: NSAppearance(named: dark ? .darkAqua : .aqua), foreground: ink
        )
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dark ? Color(white: 0.17) : Color(white: 0.93))
            if let image { Image(nsImage: image) }
        }
        .frame(width: 112, height: 44)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// The values above as the status item reads them (the same parsing and
    /// clamping as `CombinedStatusIconPreferences.stored`).
    private var currentSettings: CombinedStatusIconSettings {
        CombinedStatusIconSettings(
            iconSize: iconSize, showsBatteryPercentage: showsBatteryPercentage,
            showsChargingIndicator: showsChargingIndicator, showsChargingEffect: showsChargingEffect,
            showsChargingBoltHeartbeat: showsChargingBoltHeartbeat,
            showsPercentageWhenConnected: showsPercentageWhenConnected, usesBatteryStatusColors: usesBatteryStatusColors,
            batteryCriticalThreshold: batteryCriticalThreshold, batteryFullThreshold: batteryFullThreshold,
            batterySymbolScale: batterySymbolScale, showsWiFiIconForEthernet: showsWiFiIconForEthernet,
            showsWiFiIconForHotspot: showsWiFiIconForHotspot,
            showsWiFiIconForTemporaryConnection: showsWiFiIconForTemporaryConnection,
            showsWiFiIconForInternetSharing: showsWiFiIconForInternetSharing,
            showsBatteryPercentageInConnectionSlot: showsBatteryPercentageInConnectionSlot,
            wifiSymbolScale: wifiSymbolScale, volumeDisplayStyle: volumeStyleBinding.wrappedValue,
            ringStrokeStyle: ringStrokeBinding.wrappedValue,
            replacesNetworkIconWithBluetoothAudio: replacesNetworkIconWithBluetoothAudio,
            usesBluetoothAudioVolumeColor: usesBluetoothAudioVolumeColor,
            prioritizesNetworkErrorsOverBluetoothAudio: prioritizesNetworkErrorsOverBluetoothAudio,
            bluetoothSymbolScale: bluetoothSymbolScale,
            bluetoothAudioIconChoice: BluetoothAudioIconChoice(rawValue: bluetoothAudioIconChoiceRaw) ?? .automatic
        )
    }

    // MARK: - Building blocks

    /// The rows of an expanded group, each with the section's row height and hairline.
    private func childRows<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        Group(content: rows)
            .frame(maxWidth: .infinity, minHeight: FeatureLightfield.rowHeight, alignment: .leading)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }

    private func labeledRow<Control: View>(
        _ title: String, _ subtitle: String?, palette: FeatureLightfieldPalette,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 8)
#if DEBUG
        .layoutProbe(Self.rowProbe + title)
#endif
    }

    /// Each settings row reports its frame under this prefix (tests check
    /// that no two rows overlap).
    static let rowProbe = "combinedStatus.row."

    private func toggleRow(_ title: String, _ subtitle: String?, isOn: Binding<Bool>,
                           palette: FeatureLightfieldPalette) -> some View {
        labeledRow(title, subtitle, palette: palette) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func sliderRow(_ title: String, _ subtitle: String?, slider: SliderSpec, stored: Binding<Double>,
                           accessibilityLabel: String? = nil, palette: FeatureLightfieldPalette) -> some View {
        let display = slider.label(stored.wrappedValue)
        let value = Binding { slider.value(stored.wrappedValue) } set: { stored.wrappedValue = slider.written($0) }
        return labeledRow(title, subtitle, palette: palette) {
            HStack(spacing: 8) {
                Slider(value: value, in: slider.range)
                    .frame(width: 130)
                    .accessibilityLabel(accessibilityLabel ?? title)
                    .accessibilityValue(display)
                Text(display)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.fg2)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    /// One slider as Status Trio has it: the setting's range and default, the
    /// step a written value is rounded to and the text beside the slider.
    struct SliderSpec {
        let range: ClosedRange<Double>
        let fallback: Double
        let step: @Sendable (Double) -> Double
        let text: @Sendable (Double) -> String

        /// The stored value as the icon reads it.
        func value(_ stored: Double) -> Double {
            CombinedStatusIconSettings.clamped(stored, to: range, default: fallback)
        }

        /// A slider position as it is stored.
        func written(_ position: Double) -> Double {
            CombinedStatusIconSettings.clamped(step(position), to: range, default: fallback)
        }

        func label(_ stored: Double) -> String { text(value(stored)) }
    }

    static let iconSizeSlider = SliderSpec(range: Limits.iconSizeRange, fallback: Limits.defaultIconSize,
                                           step: { $0.rounded() }, text: { "\(Int($0)) pt" })
    static let batterySymbolScaleSlider = SliderSpec(range: Limits.batterySymbolScaleRange,
                                                     fallback: Limits.defaultBatterySymbolScale,
                                                     step: { ($0 * 20).rounded() / 20 }, text: { "\(Int($0 * 100))%" })
    static let batteryCriticalThresholdSlider = SliderSpec(range: Limits.batteryCriticalThresholdRange,
                                                           fallback: Limits.defaultBatteryCriticalThreshold,
                                                           step: { $0.rounded() }, text: { "\(Int($0))%" })
    static let batteryFullThresholdSlider = SliderSpec(range: Limits.batteryFullThresholdRange,
                                                       fallback: Limits.defaultBatteryFullThreshold,
                                                       step: { $0.rounded() }, text: { "\(Int($0))%" })
    /// The Wi-Fi and the Bluetooth symbol share one range and step.
    static let centerSymbolScaleSlider = SliderSpec(range: Limits.centerSymbolScaleRange,
                                                    fallback: Limits.defaultCenterSymbolScale,
                                                    step: { ($0 * 20).rounded() / 20 },
                                                    text: { "\(Int(($0 * 100).rounded()))%" })

    private var statusModeBinding: Binding<MenuBarStatusDisplayMode> {
        Binding {
            MenuBarStatusDisplayMode(rawValue: statusModeRaw) ?? .deviceStatus
        } set: { mode in
            MenuBarStatusController.shared.setStatusDisplayMode(mode)
        }
    }

    private var ringStrokeBinding: Binding<RingStrokeStyle> {
        Binding {
            RingStrokeStyle(rawValue: ringStrokeStyleRaw) ?? .regular
        } set: { ringStrokeStyleRaw = $0.rawValue }
    }

    private var volumeStyleBinding: Binding<VolumeDisplayStyle> {
        Binding {
            VolumeDisplayStyle(rawValue: volumeDisplayStyleRaw) ?? .dots
        } set: { volumeDisplayStyleRaw = $0.rawValue }
    }

    private var iconChoiceBinding: Binding<BluetoothAudioIconChoice> {
        Binding { Self.shownChoice(bluetoothAudioIconChoiceRaw) } set: { bluetoothAudioIconChoiceRaw = $0.rawValue }
    }

    /// An unknown or unsupported stored choice shows as Automatic without
    /// being rewritten, as upstream keeps it for a later macOS.
    static func shownChoice(_ rawValue: String,
                            available: [BluetoothAudioIconChoice] = iconChoices) -> BluetoothAudioIconChoice {
        let choice = BluetoothAudioIconChoice(rawValue: rawValue) ?? .automatic
        return available.contains(choice) ? choice : .automatic
    }

    /// Status Trio's names for the choices (zh-Hans and English).
    static func displayName(_ choice: BluetoothAudioIconChoice) -> String {
        let speaker = L10n.text("高保真扬声器", "Hi-Fi Speaker")
        let stereoPair = L10n.text("立体声组合", "Stereo Pair")
        return switch choice {
        case .automatic: L10n.text("自动", "Automatic")
        case .earbuds: L10n.text("入耳式耳机", "Earbuds")
        case .overEarHeadphones: L10n.text("头戴式耳机", "Over-Ear Headphones")
        case .headset: L10n.text("耳麦", "Headset")
        case .earpods: "EarPods"
        case .headphones: L10n.text("耳机", "Headphones")
        case .hiFiSpeaker: speaker
        case .homePod2: "HomePod (\(stereoPair))"
        case .homePodMini2: "HomePod mini (\(stereoPair))"
        case .hiFiSpeaker2: "\(speaker) (\(stereoPair))"
        case .speakerWave2: L10n.text("扬声器", "Speaker")
        default: choice.productName
        }
    }
}
