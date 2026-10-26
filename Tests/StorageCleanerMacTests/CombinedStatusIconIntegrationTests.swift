import AppKit
import CombinedStatusIcon
import XCTest
@testable import StorageCleanerMac

/// D153: the app's side of the combined status icon — its stored settings,
/// the battery it hands the icon, the VoiceOver value in Status Trio's words,
/// the still frame the renderer draws for the mode and its sampling demand.
@MainActor
final class CombinedStatusIconIntegrationTests: XCTestCase {
    private typealias Keys = CombinedStatusIconPreferences

    // MARK: - Preferences

    func testEmptyPreferencesAreStatusTriosDefaults() throws {
        let defaults = try XCTUnwrap(TestPreferenceDomain.make(for: self))
        XCTAssertEqual(CombinedStatusIconPreferences.stored(in: defaults), .standard)
    }

    func testEveryPreferenceIsReadFromItsOwnKey() throws {
        let defaults = try XCTUnwrap(TestPreferenceDomain.make(for: self))
        let values: [String: Any] = [
            Keys.iconSizeKey: 30, Keys.showsBatteryPercentageKey: false, Keys.showsChargingIndicatorKey: false,
            Keys.showsChargingEffectKey: false, Keys.showsChargingBoltHeartbeatKey: false,
            Keys.showsPercentageWhenConnectedKey: true, Keys.usesBatteryStatusColorsKey: false,
            Keys.batteryCriticalThresholdKey: 15, Keys.batteryFullThresholdKey: 80, Keys.batterySymbolScaleKey: 1.05,
            Keys.showsWiFiIconForEthernetKey: true, Keys.showsWiFiIconForHotspotKey: true,
            Keys.showsWiFiIconForTemporaryConnectionKey: true, Keys.showsWiFiIconForInternetSharingKey: true,
            Keys.showsBatteryPercentageInConnectionSlotKey: true, Keys.wifiSymbolScaleKey: 1.2,
            Keys.volumeDisplayStyleKey: "arc", Keys.ringStrokeStyleKey: "bold",
            Keys.replacesNetworkIconWithBluetoothAudioKey: true, Keys.usesBluetoothAudioVolumeColorKey: true,
            Keys.prioritizesNetworkErrorsOverBluetoothAudioKey: false, Keys.bluetoothSymbolScaleKey: 1.4,
            Keys.bluetoothAudioIconChoiceKey: "headphones"
        ]
        XCTAssertEqual(values.count, 23, "one key for each icon setting")
        XCTAssertTrue(values.keys.allSatisfy { $0.hasPrefix("menuBar.combinedStatus.") })
        for (key, value) in values { defaults.set(value, forKey: key) }
        XCTAssertEqual(CombinedStatusIconPreferences.stored(in: defaults), CombinedStatusIconSettings(
            iconSize: 30, showsBatteryPercentage: false, showsChargingIndicator: false, showsChargingEffect: false,
            showsChargingBoltHeartbeat: false, showsPercentageWhenConnected: true, usesBatteryStatusColors: false,
            batteryCriticalThreshold: 15, batteryFullThreshold: 80, batterySymbolScale: 1.05,
            showsWiFiIconForEthernet: true, showsWiFiIconForHotspot: true, showsWiFiIconForTemporaryConnection: true,
            showsWiFiIconForInternetSharing: true, showsBatteryPercentageInConnectionSlot: true, wifiSymbolScale: 1.2,
            volumeDisplayStyle: .arc, ringStrokeStyle: .bold, replacesNetworkIconWithBluetoothAudio: true,
            usesBluetoothAudioVolumeColor: true, prioritizesNetworkErrorsOverBluetoothAudio: false,
            bluetoothSymbolScale: 1.4, bluetoothAudioIconChoice: .headphones
        ))
    }

    /// A renamed key would drop what the user saved, so the names are fixed:
    /// this app's prefix and Status Trio's setting names.
    func testPreferenceKeysAreFixed() {
        let keys = [Keys.iconSizeKey, Keys.showsBatteryPercentageKey, Keys.showsChargingIndicatorKey,
                    Keys.showsChargingEffectKey, Keys.showsChargingBoltHeartbeatKey,
                    Keys.showsPercentageWhenConnectedKey, Keys.usesBatteryStatusColorsKey,
                    Keys.batteryCriticalThresholdKey, Keys.batteryFullThresholdKey, Keys.batterySymbolScaleKey,
                    Keys.showsWiFiIconForEthernetKey, Keys.showsWiFiIconForHotspotKey,
                    Keys.showsWiFiIconForTemporaryConnectionKey, Keys.showsWiFiIconForInternetSharingKey,
                    Keys.showsBatteryPercentageInConnectionSlotKey, Keys.wifiSymbolScaleKey,
                    Keys.volumeDisplayStyleKey, Keys.ringStrokeStyleKey,
                    Keys.replacesNetworkIconWithBluetoothAudioKey, Keys.usesBluetoothAudioVolumeColorKey,
                    Keys.prioritizesNetworkErrorsOverBluetoothAudioKey, Keys.bluetoothSymbolScaleKey,
                    Keys.bluetoothAudioIconChoiceKey]
        XCTAssertEqual(keys, [
            "iconSize", "showsBatteryPercentage", "showsChargingIndicator", "showsChargingEffect",
            "showsChargingBoltHeartbeat", "showsPercentageWhenConnected", "usesBatteryStatusColors",
            "batteryCriticalThreshold", "batteryFullThreshold", "batterySymbolScale", "showsWiFiIconForEthernet",
            "showsWiFiIconForHotspot", "showsWiFiIconForTemporaryConnection", "showsWiFiIconForInternetSharing",
            "showsBatteryPercentageInConnectionSlot", "wifiSymbolScale", "volumeDisplayStyle", "ringStrokeStyle",
            "replacesNetworkIconWithBluetoothAudio", "usesBluetoothAudioVolumeColor",
            "prioritizesNetworkErrorsOverBluetoothAudio", "bluetoothSymbolScale", "bluetoothAudioIconChoice"
        ].map { "menuBar.combinedStatus." + $0 })
    }

    func testUnreadableOrOutOfRangePreferencesKeepTheDefaultOrClamp() throws {
        let defaults = try XCTUnwrap(TestPreferenceDomain.make(for: self))
        defaults.set("large", forKey: Keys.iconSizeKey)
        defaults.set("yes", forKey: Keys.showsChargingEffectKey)
        defaults.set(10, forKey: Keys.batteryFullThresholdKey)
        defaults.set(5, forKey: Keys.wifiSymbolScaleKey)
        defaults.set("spiral", forKey: Keys.volumeDisplayStyleKey)
        defaults.set("heavy", forKey: Keys.ringStrokeStyleKey)
        defaults.set("not.a.glyph", forKey: Keys.bluetoothAudioIconChoiceKey)
        let settings = CombinedStatusIconPreferences.stored(in: defaults)
        XCTAssertEqual(settings.iconSize, 24)
        XCTAssertTrue(settings.showsChargingEffect)
        XCTAssertEqual(settings.batteryFullThreshold, 50)
        XCTAssertEqual(settings.wifiSymbolScale, 1.8)
        XCTAssertEqual(settings.volumeDisplayStyle, .dots)
        XCTAssertEqual(settings.ringStrokeStyle, .bold, "Status Trio's legacy stroke names still read")
        XCTAssertEqual(settings.bluetoothAudioIconChoice, .automatic)
    }

    // MARK: - Battery

    func testTheIconsBatteryIsTheAppsPowerReading() {
        func status(_ snapshot: BatteryPowerSnapshot?, _ availability: InternalBatteryAvailability = .present,
                    lowPower: Bool = false) -> BatteryStatus {
            CombinedStatusIconBattery.status(snapshot: snapshot, availability: availability, lowPowerMode: lowPower)
        }
        let charging = BatteryPowerSnapshot(chargePercent: 48, isCharging: true, powerSource: .acPower,
                                            timeToEmptyMinutes: nil, timeToFullChargeMinutes: 70, isFullyCharged: false)
        XCTAssertEqual(status(charging), BatteryStatus(rawPercentage: 48, isPresent: true, isCharging: true,
                                                       isCharged: false, timeToFullChargeMinutes: 70,
                                                       isLowPowerMode: false, isConnectedToPower: true))
        let estimating = BatteryPowerSnapshot(chargePercent: 48, isCharging: true, powerSource: .acPower,
                                              timeToEmptyMinutes: nil, timeToFullChargeMinutes: 0)
        XCTAssertNil(status(estimating).timeToFullChargeMinutes)
        let held = BatteryPowerSnapshot(chargePercent: 80, isCharging: false, powerSource: .acPower,
                                        timeToEmptyMinutes: nil, timeToFullChargeMinutes: 25)
        XCTAssertEqual(status(held), BatteryStatus(rawPercentage: 80, isPresent: true, isCharging: false,
                                                   isLowPowerMode: false, isConnectedToPower: true),
                       "a time to full is only kept while charging, as upstream")
        let full = BatteryPowerSnapshot(chargePercent: 100, isCharging: false, powerSource: .acPower,
                                        timeToEmptyMinutes: nil, timeToFullChargeMinutes: nil, isFullyCharged: true)
        XCTAssertTrue(status(full).isCharged)
        let onBattery = BatteryPowerSnapshot(chargePercent: 31, isCharging: false, powerSource: .batteryPower,
                                             timeToEmptyMinutes: 190, timeToFullChargeMinutes: nil)
        XCTAssertEqual(status(onBattery, lowPower: true), BatteryStatus(rawPercentage: 31, isPresent: true,
                                                                        isCharging: false, isLowPowerMode: true,
                                                                        isConnectedToPower: false))
        XCTAssertTrue(status(onBattery, .unknown).isPresent, "a reading before the presence check counts")
        XCTAssertEqual(status(nil, .absent, lowPower: true), BatteryStatus(rawPercentage: nil, isPresent: false,
                                                                           isCharging: false, isLowPowerMode: true,
                                                                           isConnectedToPower: false))
        XCTAssertFalse(status(onBattery, .absent).isPresent, "a desktop's UPS reading is not its battery")
        XCTAssertFalse(status(nil, .unknown).isPresent)
    }

    // MARK: - VoiceOver value

    func testVoiceOverValueIsStatusTriosChineseWording() {
        let languagePreferences = TestVolatilePreferences()
        defer { languagePreferences.restore() }
        languagePreferences.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(CombinedStatusIconSummary.text(Self.ordinary), "电池 76%，Wi-Fi 3 格，音量 50% · 2 格")
        XCTAssertEqual(CombinedStatusIconSummary.text(Self.snapshot(
            battery: BatteryStatus(rawPercentage: 48, isPresent: true, isCharging: true, timeToFullChargeMinutes: 70,
                                   isLowPowerMode: false, isConnectedToPower: true),
            connection: .ethernet, volume: VolumeStatus(scalar: 0.5, isMuted: true, deviceName: nil))),
            "电池 48%（预计 1 小时 10 分钟充满），以太网已连接，音量 静音")
        XCTAssertEqual(CombinedStatusIconSummary.text(Self.snapshot(
            battery: BatteryStatus(rawPercentage: nil, isPresent: false, isCharging: false,
                                   isLowPowerMode: false, isConnectedToPower: false),
            wifi: WiFiStatus(state: .off, rssi: nil), volume: .placeholder)),
            "无电池设备，Wi-Fi 关闭，音量 —")
        XCTAssertEqual(CombinedStatusIconSummary.timeToFull(45), "预计 45 分钟充满")
        XCTAssertEqual(CombinedStatusIconSummary.timeToFull(120), "预计 2 小时充满")
        XCTAssertEqual(CombinedStatusIconSummary.timeToFull(nil), "正在计算充满时间")
        XCTAssertEqual(CombinedStatusIconSummary.battery(Self.battery(20, lowPower: true)), "电池 20%（低电量模式）")
        XCTAssertEqual(CombinedStatusIconSummary.battery(BatteryStatus(
            rawPercentage: 100, isPresent: true, isCharging: false, isCharged: true,
            isLowPowerMode: false, isConnectedToPower: true)), "电池 100%（已充满）")
        XCTAssertEqual(CombinedStatusIconSummary.battery(Self.battery(80, connected: true)), "电池 80%（已连接电源）")
        let states: [(WiFiState, String)] = [(.notAssociated, "未关联"), (.off, "关闭"), (.noInternet, "无互联网"),
                                             (.hotspot, "iPhone 热点"), (.temporary, "临时连接"),
                                             (.shared, "正在共享"), (.unavailable, "不可用")]
        for (state, text) in states {
            XCTAssertEqual(CombinedStatusIconSummary.wifiValue(WiFiStatus(state: state, rssi: -50)), text)
        }
    }

    func testVoiceOverValueIsStatusTriosEnglishWording() {
        let languagePreferences = TestVolatilePreferences()
        defer { languagePreferences.restore() }
        languagePreferences.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(CombinedStatusIconSummary.text(Self.ordinary), "Battery 76%, Wi-Fi, 3 bars, Volume 50% · 2 bars")
        XCTAssertEqual(CombinedStatusIconSummary.text(Self.snapshot(
            battery: BatteryStatus(rawPercentage: 48, isPresent: true, isCharging: true, timeToFullChargeMinutes: 70,
                                   isLowPowerMode: false, isConnectedToPower: true),
            connection: .ethernet, volume: VolumeStatus(scalar: 0.5, isMuted: true, deviceName: nil))),
            "Battery 48% (About 1 h 10 min to full), Ethernet connected, Volume Muted")
        XCTAssertEqual(CombinedStatusIconSummary.timeToFull(45), "About 45 min to full")
        XCTAssertEqual(CombinedStatusIconSummary.timeToFull(nil), "Calculating time to full")
        XCTAssertEqual(CombinedStatusIconSummary.battery(Self.battery(20, lowPower: true)), "Battery 20% (Low Power Mode)")
        XCTAssertEqual(CombinedStatusIconSummary.wifiValue(WiFiStatus(state: .hotspot, rssi: nil)), "iPhone hotspot")
        XCTAssertEqual(CombinedStatusIconSummary.wifiValue(WiFiStatus(state: .connected, rssi: -80)), "1 bars")
    }

    // MARK: - Renderer and settings

    func testRendererDrawsTheCombinedIconAsAColouredSquare() throws {
        let image = MenuBarStatusRenderer.image(for: nil, mode: .combinedStatus, combinedStatus: Self.ordinary)
        XCTAssertEqual(image.size, NSSize(width: 24, height: 24))
        XCTAssertFalse(image.isTemplate)
        let larger = MenuBarStatusRenderer.image(for: nil, mode: .combinedStatus, combinedStatus: Self.ordinary,
                                                 combinedStatusSettings: CombinedStatusIconSettings(iconSize: 32))
        XCTAssertEqual(larger.size, NSSize(width: 32, height: 32))
        let blue = MenuBarStatusRenderer.image(for: nil, mode: .combinedStatus,
                                               appearance: NSAppearance(named: .aqua), statusPreset: .blue,
                                               combinedStatus: Self.ordinary)
        // The still frame is drawn at the main screen's scale.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let rep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(blue.tiffRepresentation)))
        XCTAssertEqual(rep.pixelsWide, Int(24 * scale))
        var inked = 0, blueInk = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                inked += 1
                if color.blueComponent > color.redComponent + 0.3 { blueInk += 1 }
            }
        }
        XCTAssertGreaterThan(inked, 0)
        XCTAssertEqual(blueInk, inked, "the item colour preset draws the icon")
    }

    func testSettingsNameTheBluetoothChoicesLikeStatusTrio() {
        let languagePreferences = TestVolatilePreferences()
        defer { languagePreferences.restore() }
        languagePreferences.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.automatic), "自动")
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.earbuds), "入耳式耳机")
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.overEarHeadphones), "头戴式耳机")
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.homePod2), "HomePod (立体声组合)")
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.hiFiSpeaker2), "高保真扬声器 (立体声组合)")
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.airpodsPro), "AirPods Pro")
        languagePreferences.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.headset), "Headset")
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.speakerWave2), "Speaker")
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.homePodMini2), "HomePod mini (Stereo Pair)")
        XCTAssertEqual(CombinedStatusIconSettingsSection.displayName(.beatsStudioBudsPlus), "Beats Studio Buds +")
    }

    /// Status Trio's slider steps, ranges and labels (`BatterySectionView`,
    /// `NetworkSectionView`, `BluetoothSectionView`, `AppIconSectionView`).
    func testSettingsSlidersStepAndLabelLikeStatusTrio() {
        typealias Section = CombinedStatusIconSettingsSection
        let size = Section.iconSizeSlider
        XCTAssertEqual(size.range, 16...36)
        XCTAssertEqual(size.written(23.6), 24)
        XCTAssertEqual(size.written(40), 36)
        XCTAssertEqual(size.label(24), "24 pt")
        XCTAssertEqual(size.label(.nan), "24 pt")
        let battery = Section.batterySymbolScaleSlider
        XCTAssertEqual(battery.range, 0.9...1.1)
        XCTAssertEqual(battery.written(1.07), 1.05, accuracy: 1e-9)
        XCTAssertEqual(battery.written(1.03), 1.05, accuracy: 1e-9)
        XCTAssertEqual(battery.written(1.02), 1.0, accuracy: 1e-9)
        XCTAssertEqual(battery.written(0.5), 0.9, accuracy: 1e-9)
        XCTAssertEqual(battery.label(1.05), "105%")
        XCTAssertEqual(battery.label(0.95), "95%")
        let critical = Section.batteryCriticalThresholdSlider
        XCTAssertEqual(critical.range, 0...100)
        XCTAssertEqual(critical.written(19.5), 20)
        XCTAssertEqual(critical.label(20), "20%")
        let full = Section.batteryFullThresholdSlider
        XCTAssertEqual(full.range, 50...100)
        XCTAssertEqual(full.written(80.4), 80)
        XCTAssertEqual(full.written(12), 50)
        XCTAssertEqual(full.label(100), "100%")
        let center = Section.centerSymbolScaleSlider
        XCTAssertEqual(center.range, 1.0...1.8)
        XCTAssertEqual(center.written(1.62), 1.6, accuracy: 1e-9)
        XCTAssertEqual(center.written(1.63), 1.65, accuracy: 1e-9)
        XCTAssertEqual(center.written(2), 1.8, accuracy: 1e-9)
        XCTAssertEqual(center.label(1.15), "115%")
        XCTAssertEqual(center.label(1.6), "160%")
        XCTAssertEqual(center.label(0), "100%")
    }

    func testAnUnknownOrUnsupportedIconChoiceShowsAsAutomatic() {
        typealias Section = CombinedStatusIconSettingsSection
        XCTAssertEqual(Section.shownChoice("headphones"), .headphones)
        XCTAssertEqual(Section.shownChoice("airpods.pro"), .airpodsPro)
        XCTAssertEqual(Section.shownChoice("not.a.glyph"), .automatic)
        XCTAssertEqual(Section.shownChoice(""), .automatic)
        XCTAssertEqual(Section.shownChoice("airpodsmax", available: [.automatic, .headphones]), .automatic,
                       "a glyph this macOS lacks shows as Automatic")
        XCTAssertEqual(Section.shownChoice("headphones", available: [.automatic, .headphones]), .headphones)
    }

    func testTheCombinedIconNeedsTheStatusBatteryOnlyWhileShown() {
        func plan(visible: Bool = true, paused: Bool = false, suspended: Bool = false) -> MenuBarSamplingPlan {
            .resolve(statusMode: .combinedStatus, statusVisible: visible, panelVisible: false, visibleKinds: [],
                     customFanControlActive: false, paused: paused, suspended: suspended)
        }
        XCTAssertTrue(plan().needsStatusBattery)
        XCTAssertFalse(plan().needsStatusWiFi, "its Wi-Fi comes from its own monitor")
        XCTAssertFalse(plan(visible: false).needsStatusBattery)
        XCTAssertFalse(plan(paused: true).needsStatusBattery)
        XCTAssertFalse(plan(suspended: true).needsStatusBattery)
    }

    // MARK: - Fixtures

    static func battery(_ percent: Int, lowPower: Bool = false, connected: Bool = false) -> BatteryStatus {
        BatteryStatus(rawPercentage: percent, isPresent: true, isCharging: false,
                      isLowPowerMode: lowPower, isConnectedToPower: connected)
    }

    static func snapshot(battery: BatteryStatus, wifi: WiFiStatus = WiFiStatus(state: .connected, rssi: -55),
                         connection: NetworkConnection = .wifi,
                         volume: VolumeStatus = VolumeStatus(scalar: 0.5, isMuted: false, deviceName: nil)) -> StatusSnapshot {
        StatusSnapshot(battery: battery, wifi: wifi, connection: connection, volume: volume)
    }

    static let ordinary = snapshot(battery: battery(76))
}
