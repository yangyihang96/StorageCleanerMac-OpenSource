import AppKit
import Combine
import CombinedStatusIcon
import Foundation

/// D153: where the combined status icon's settings live, one key each: this
/// app's menu-bar prefix and the setting's name in Status Trio's
/// `SettingsStore` (its icon size is stored there as "menuBarIconSize").
/// A missing or invalid value keeps Status Trio's default.
enum CombinedStatusIconPreferences {
    static let prefix = "menuBar.combinedStatus."
    static let iconSizeKey = prefix + "iconSize"
    static let showsBatteryPercentageKey = prefix + "showsBatteryPercentage"
    static let showsChargingIndicatorKey = prefix + "showsChargingIndicator"
    static let showsChargingEffectKey = prefix + "showsChargingEffect"
    static let showsChargingBoltHeartbeatKey = prefix + "showsChargingBoltHeartbeat"
    static let showsPercentageWhenConnectedKey = prefix + "showsPercentageWhenConnected"
    static let usesBatteryStatusColorsKey = prefix + "usesBatteryStatusColors"
    static let batteryCriticalThresholdKey = prefix + "batteryCriticalThreshold"
    static let batteryFullThresholdKey = prefix + "batteryFullThreshold"
    static let batterySymbolScaleKey = prefix + "batterySymbolScale"
    static let showsWiFiIconForEthernetKey = prefix + "showsWiFiIconForEthernet"
    static let showsWiFiIconForHotspotKey = prefix + "showsWiFiIconForHotspot"
    static let showsWiFiIconForTemporaryConnectionKey = prefix + "showsWiFiIconForTemporaryConnection"
    static let showsWiFiIconForInternetSharingKey = prefix + "showsWiFiIconForInternetSharing"
    static let showsBatteryPercentageInConnectionSlotKey = prefix + "showsBatteryPercentageInConnectionSlot"
    static let wifiSymbolScaleKey = prefix + "wifiSymbolScale"
    static let volumeDisplayStyleKey = prefix + "volumeDisplayStyle"
    static let ringStrokeStyleKey = prefix + "ringStrokeStyle"
    static let replacesNetworkIconWithBluetoothAudioKey = prefix + "replacesNetworkIconWithBluetoothAudio"
    static let usesBluetoothAudioVolumeColorKey = prefix + "usesBluetoothAudioVolumeColor"
    static let prioritizesNetworkErrorsOverBluetoothAudioKey = prefix + "prioritizesNetworkErrorsOverBluetoothAudio"
    static let bluetoothSymbolScaleKey = prefix + "bluetoothSymbolScale"
    static let bluetoothAudioIconChoiceKey = prefix + "bluetoothAudioIconChoice"

    static func stored(in defaults: UserDefaults = .standard) -> CombinedStatusIconSettings {
        let standard = CombinedStatusIconSettings.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double {
            (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
        }
        return CombinedStatusIconSettings(
            iconSize: double(iconSizeKey, standard.iconSize),
            showsBatteryPercentage: bool(showsBatteryPercentageKey, standard.showsBatteryPercentage),
            showsChargingIndicator: bool(showsChargingIndicatorKey, standard.showsChargingIndicator),
            showsChargingEffect: bool(showsChargingEffectKey, standard.showsChargingEffect),
            showsChargingBoltHeartbeat: bool(showsChargingBoltHeartbeatKey, standard.showsChargingBoltHeartbeat),
            showsPercentageWhenConnected: bool(showsPercentageWhenConnectedKey, standard.showsPercentageWhenConnected),
            usesBatteryStatusColors: bool(usesBatteryStatusColorsKey, standard.usesBatteryStatusColors),
            batteryCriticalThreshold: double(batteryCriticalThresholdKey, standard.batteryCriticalThreshold),
            batteryFullThreshold: double(batteryFullThresholdKey, standard.batteryFullThreshold),
            batterySymbolScale: double(batterySymbolScaleKey, standard.batterySymbolScale),
            showsWiFiIconForEthernet: bool(showsWiFiIconForEthernetKey, standard.showsWiFiIconForEthernet),
            showsWiFiIconForHotspot: bool(showsWiFiIconForHotspotKey, standard.showsWiFiIconForHotspot),
            showsWiFiIconForTemporaryConnection: bool(showsWiFiIconForTemporaryConnectionKey,
                                                      standard.showsWiFiIconForTemporaryConnection),
            showsWiFiIconForInternetSharing: bool(showsWiFiIconForInternetSharingKey,
                                                  standard.showsWiFiIconForInternetSharing),
            showsBatteryPercentageInConnectionSlot: bool(showsBatteryPercentageInConnectionSlotKey,
                                                         standard.showsBatteryPercentageInConnectionSlot),
            wifiSymbolScale: double(wifiSymbolScaleKey, standard.wifiSymbolScale),
            volumeDisplayStyle: defaults.string(forKey: volumeDisplayStyleKey)
                .flatMap(VolumeDisplayStyle.init(rawValue:)) ?? standard.volumeDisplayStyle,
            ringStrokeStyle: defaults.string(forKey: ringStrokeStyleKey)
                .flatMap(RingStrokeStyle.init(rawValue:)) ?? standard.ringStrokeStyle,
            replacesNetworkIconWithBluetoothAudio: bool(replacesNetworkIconWithBluetoothAudioKey,
                                                        standard.replacesNetworkIconWithBluetoothAudio),
            usesBluetoothAudioVolumeColor: bool(usesBluetoothAudioVolumeColorKey, standard.usesBluetoothAudioVolumeColor),
            prioritizesNetworkErrorsOverBluetoothAudio: bool(prioritizesNetworkErrorsOverBluetoothAudioKey,
                                                             standard.prioritizesNetworkErrorsOverBluetoothAudio),
            bluetoothSymbolScale: double(bluetoothSymbolScaleKey, standard.bluetoothSymbolScale),
            bluetoothAudioIconChoice: defaults.string(forKey: bluetoothAudioIconChoiceKey)
                .flatMap(BluetoothAudioIconChoice.init(rawValue:)) ?? standard.bluetoothAudioIconChoice
        )
    }
}

/// D153: the app's own power-source reading as the icon's battery input.
enum CombinedStatusIconBattery {
    static func status(snapshot: BatteryPowerSnapshot?, availability: InternalBatteryAvailability,
                       lowPowerMode: Bool) -> BatteryStatus {
        let present = availability == .present || (availability == .unknown && snapshot?.chargePercent != nil)
        guard present, let snapshot else {
            return BatteryStatus(rawPercentage: nil, isPresent: false, isCharging: false,
                                 isLowPowerMode: lowPowerMode, isConnectedToPower: false)
        }
        let charging = snapshot.isCharging == true
        return BatteryStatus(
            rawPercentage: snapshot.chargePercent,
            isPresent: true,
            isCharging: charging,
            isCharged: snapshot.isFullyCharged == true,
            timeToFullChargeMinutes: charging ? snapshot.timeToFullChargeMinutes.flatMap { $0 > 0 ? $0 : nil } : nil,
            isLowPowerMode: lowPowerMode,
            isConnectedToPower: snapshot.powerSource == .acPower
        )
    }
}

/// D153: the status item's VoiceOver value, worded as Status Trio's
/// (`AccessibilityPresentation.statusItemValue` with the panel's battery,
/// Wi-Fi and volume values; the same zh-Hans and English strings). The
/// network name is never read, so Wi-Fi is always "label value".
enum CombinedStatusIconSummary {
    static func text(_ snapshot: StatusSnapshot) -> String {
        let network = snapshot.connection == .ethernet
            ? L10n.text("以太网已连接", "Ethernet connected")
            : L10n.text("Wi-Fi \(wifiValue(snapshot.wifi))", "Wi-Fi, \(wifiValue(snapshot.wifi))")
        return L10n.text("\(battery(snapshot.battery))，\(network)，音量 \(volume(snapshot.volume))",
                         "\(battery(snapshot.battery)), \(network), Volume \(volume(snapshot.volume))")
    }

    static func battery(_ battery: BatteryStatus) -> String {
        guard battery.isPresent else { return L10n.text("无电池设备", "No battery") }
        let percentage = L10n.text("电池 \(battery.percentage)%", "Battery \(battery.percentage)%")
        if !battery.isCharged, !battery.isCharging, !battery.isLowPowerMode, !battery.isConnectedToPower {
            return percentage
        }
        return L10n.text("\(percentage)（\(batterySubtitle(battery))）", "\(percentage) (\(batterySubtitle(battery)))")
    }

    static func batterySubtitle(_ battery: BatteryStatus) -> String {
        if battery.isCharged { return L10n.text("已充满", "Fully charged") }
        if battery.isCharging { return timeToFull(battery.timeToFullChargeMinutes) }
        if battery.isLowPowerMode { return L10n.text("低电量模式", "Low Power Mode") }
        if battery.isConnectedToPower { return L10n.text("已连接电源", "Connected to power") }
        return L10n.text("电池供电", "On battery")
    }

    static func timeToFull(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return L10n.text("正在计算充满时间", "Calculating time to full") }
        let hours = minutes / 60
        let remaining = minutes % 60
        if hours == 0 { return L10n.text("预计 \(remaining) 分钟充满", "About \(remaining) min to full") }
        if remaining == 0 { return L10n.text("预计 \(hours) 小时充满", "About \(hours) h to full") }
        return L10n.text("预计 \(hours) 小时 \(remaining) 分钟充满", "About \(hours) h \(remaining) min to full")
    }

    static func wifiValue(_ wifi: WiFiStatus) -> String {
        let bars = CombinedStatusIconMappings.wifiBars(rssi: wifi.rssi)
        return switch wifi.state {
        case .connected: L10n.text("\(bars) 格", "\(bars) bars")
        case .notAssociated: L10n.text("未关联", "Not associated")
        case .off: L10n.text("关闭", "Off")
        case .noInternet: L10n.text("无互联网", "No internet")
        case .hotspot: L10n.text("iPhone 热点", "iPhone hotspot")
        case .temporary: L10n.text("临时连接", "Temporary")
        case .shared: L10n.text("正在共享", "Sharing")
        case .unavailable: L10n.text("不可用", "Unavailable")
        }
    }

    static func volume(_ volume: VolumeStatus) -> String {
        guard let scalar = volume.scalar, scalar.isFinite else { return "—" }
        let clamped = min(1, max(0, scalar))
        let percentage = Int((clamped * 100).rounded())
        guard !volume.isMuted else { return L10n.text("静音", "Muted") }
        let steps = CombinedStatusIconMappings.volumeSteps(scalar: clamped, isMuted: false) ?? 0
        return L10n.text("\(percentage)% · \(steps) 格", "\(percentage)% · \(steps) bars")
    }
}

/// D153: keeps the combined icon on the status button. Its monitors run while
/// the item shows a live status (visible, not paused, the system awake); a
/// hidden, paused or sleeping item keeps a still icon without the charging
/// effect. The presenter draws what the monitors report, and the button's
/// tooltip and VoiceOver value follow it.
@MainActor
final class CombinedStatusItemDriver {
    struct Context {
        var battery: BatteryStatus
        var settings: CombinedStatusIconSettings
        /// The app's menu-bar item colour; nil keeps the label colour.
        var foreground: NSColor?
        var isVisible: Bool
        var isPaused: Bool
        var isSystemSleeping: Bool
        var isDisplaySleeping: Bool

        var runsMonitors: Bool { isVisible && !isPaused && !isSystemSleeping }
        var holdsStill: Bool { !isVisible || isPaused || isSystemSleeping || isDisplaySleeping }
    }

    private let makeMonitor: @MainActor (BatteryStatus) -> CombinedStatusSystemMonitor
    private(set) var monitor: CombinedStatusSystemMonitor?
    private(set) var presenter: CombinedStatusIconStatusItemPresenter?
    private weak var button: NSStatusBarButton?
    private var context: Context?
    private var subscription: AnyCancellable?

    init(makeMonitor: @escaping @MainActor (BatteryStatus) -> CombinedStatusSystemMonitor = {
        CombinedStatusSystemMonitor(battery: $0)
    }) {
        self.makeMonitor = makeMonitor
    }

    var isActive: Bool { presenter != nil || monitor != nil }
    var snapshot: StatusSnapshot? { monitor?.snapshot }

    func update(button: NSStatusBarButton, context: Context) {
        self.button = button
        self.context = context
        let monitor = monitor ?? startObserving(makeMonitor(context.battery))
        monitor.updateBattery(context.battery)
        if context.runsMonitors { monitor.start() } else { monitor.stop() }
        let presenter = presenter ?? CombinedStatusIconStatusItemPresenter(snapshot: monitor.snapshot,
                                                                           settings: context.settings)
        self.presenter = presenter
        presenter.attach(to: button)
        present()
    }

    func tearDown() {
        subscription = nil
        presenter?.detach()
        presenter = nil
        monitor?.stop()
        monitor = nil
        button = nil
        context = nil
    }

    private func startObserving(_ monitor: CombinedStatusSystemMonitor) -> CombinedStatusSystemMonitor {
        self.monitor = monitor
        subscription = Publishers.CombineLatest(monitor.$snapshot, monitor.$isDisplayAsleep)
            .dropFirst()
            .sink { [weak self] _, _ in
                // Published sends before the change is stored.
                Task { @MainActor in self?.present() }
            }
        return monitor
    }

    private func present() {
        guard let monitor, let presenter, let button, let context else { return }
        presenter.update(settings: context.settings)
        presenter.update(foreground: context.foreground)
        presenter.update(snapshot: monitor.snapshot,
                         isDisplayAsleep: monitor.isDisplayAsleep || context.holdsStill)
        let summary = CombinedStatusIconSummary.text(monitor.snapshot)
        button.toolTip = summary
        button.setAccessibilityLabel(L10n.appName)
        button.setAccessibilityValue(summary)
    }
}
