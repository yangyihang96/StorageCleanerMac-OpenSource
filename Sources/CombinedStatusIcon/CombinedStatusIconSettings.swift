// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Settings/SettingsStore.swift,
// SettingsStore+IconAppearance.swift and SettingsStore+IconPresentation.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): the icon
// settings with their defaults, ranges and clamping as one value the app
// stores itself; it assembles the presentation settings the way the upstream
// publishers do. No per-device Bluetooth icon (the Bluetooth panel is not
// part of the icon) and no charging-effect test mode.

import AppKit

/// Everything the combined status icon is drawn from apart from the status.
public struct CombinedStatusIconSettings: Equatable, Sendable {
    public static let iconSizeRange: ClosedRange<Double> = 16...36
    public static let defaultIconSize: Double = 24
    public static let batteryCriticalThresholdRange: ClosedRange<Double> = 0...100
    public static let defaultBatteryCriticalThreshold: Double = 20
    /// The ring closes at the level the user picks. The floor keeps the arc a
    /// usable fraction of the circle instead of a hairline at 1%.
    public static let batteryFullThresholdRange: ClosedRange<Double> = 50...100
    public static let defaultBatteryFullThreshold = Double(BatteryIconOptions.defaultFullThreshold)
    public static let batterySymbolScaleRange: ClosedRange<Double> = 0.9...1.1
    public static let defaultBatterySymbolScale: Double = 1
    public static let centerSymbolScaleRange: ClosedRange<Double> = 1.0...1.8
    public static let defaultCenterSymbolScale: Double = 1.6

    public var iconSize: Double
    public var showsBatteryPercentage: Bool
    public var showsChargingIndicator: Bool
    public var showsChargingEffect: Bool
    public var showsChargingBoltHeartbeat: Bool
    public var showsPercentageWhenConnected: Bool
    public var usesBatteryStatusColors: Bool
    public var batteryCriticalThreshold: Double
    public var batteryFullThreshold: Double
    public var batterySymbolScale: Double
    public var showsWiFiIconForEthernet: Bool
    public var showsWiFiIconForHotspot: Bool
    public var showsWiFiIconForTemporaryConnection: Bool
    public var showsWiFiIconForInternetSharing: Bool
    public var showsBatteryPercentageInConnectionSlot: Bool
    public var wifiSymbolScale: Double
    public var volumeDisplayStyle: VolumeDisplayStyle
    public var ringStrokeStyle: RingStrokeStyle
    public var replacesNetworkIconWithBluetoothAudio: Bool
    public var usesBluetoothAudioVolumeColor: Bool
    public var prioritizesNetworkErrorsOverBluetoothAudio: Bool
    public var bluetoothSymbolScale: Double
    public var bluetoothAudioIconChoice: BluetoothAudioIconChoice

    /// Status Trio's first-launch values.
    public static let standard = CombinedStatusIconSettings()

    public init(
        iconSize: Double = defaultIconSize,
        showsBatteryPercentage: Bool = true,
        showsChargingIndicator: Bool = true,
        showsChargingEffect: Bool = true,
        showsChargingBoltHeartbeat: Bool = true,
        showsPercentageWhenConnected: Bool = false,
        usesBatteryStatusColors: Bool = true,
        batteryCriticalThreshold: Double = defaultBatteryCriticalThreshold,
        batteryFullThreshold: Double = defaultBatteryFullThreshold,
        batterySymbolScale: Double = defaultBatterySymbolScale,
        showsWiFiIconForEthernet: Bool = false,
        showsWiFiIconForHotspot: Bool = false,
        showsWiFiIconForTemporaryConnection: Bool = false,
        showsWiFiIconForInternetSharing: Bool = false,
        showsBatteryPercentageInConnectionSlot: Bool = false,
        wifiSymbolScale: Double = defaultCenterSymbolScale,
        volumeDisplayStyle: VolumeDisplayStyle = .dots,
        ringStrokeStyle: RingStrokeStyle = .regular,
        replacesNetworkIconWithBluetoothAudio: Bool = false,
        usesBluetoothAudioVolumeColor: Bool = false,
        prioritizesNetworkErrorsOverBluetoothAudio: Bool = true,
        bluetoothSymbolScale: Double = defaultCenterSymbolScale,
        bluetoothAudioIconChoice: BluetoothAudioIconChoice = .automatic
    ) {
        self.iconSize = Self.clamped(iconSize, to: Self.iconSizeRange, default: Self.defaultIconSize)
        self.showsBatteryPercentage = showsBatteryPercentage
        self.showsChargingIndicator = showsChargingIndicator
        self.showsChargingEffect = showsChargingEffect
        self.showsChargingBoltHeartbeat = showsChargingBoltHeartbeat
        self.showsPercentageWhenConnected = showsPercentageWhenConnected
        self.usesBatteryStatusColors = usesBatteryStatusColors
        self.batteryCriticalThreshold = Self.clamped(batteryCriticalThreshold, to: Self.batteryCriticalThresholdRange,
                                                     default: Self.defaultBatteryCriticalThreshold)
        self.batteryFullThreshold = Self.clamped(batteryFullThreshold, to: Self.batteryFullThresholdRange,
                                                 default: Self.defaultBatteryFullThreshold)
        self.batterySymbolScale = Self.clamped(batterySymbolScale, to: Self.batterySymbolScaleRange,
                                               default: Self.defaultBatterySymbolScale)
        self.showsWiFiIconForEthernet = showsWiFiIconForEthernet
        self.showsWiFiIconForHotspot = showsWiFiIconForHotspot
        self.showsWiFiIconForTemporaryConnection = showsWiFiIconForTemporaryConnection
        self.showsWiFiIconForInternetSharing = showsWiFiIconForInternetSharing
        self.showsBatteryPercentageInConnectionSlot = showsBatteryPercentageInConnectionSlot
        self.wifiSymbolScale = Self.clamped(wifiSymbolScale, to: Self.centerSymbolScaleRange,
                                            default: Self.defaultCenterSymbolScale)
        self.volumeDisplayStyle = volumeDisplayStyle
        self.ringStrokeStyle = ringStrokeStyle
        self.replacesNetworkIconWithBluetoothAudio = replacesNetworkIconWithBluetoothAudio
        self.usesBluetoothAudioVolumeColor = usesBluetoothAudioVolumeColor
        self.prioritizesNetworkErrorsOverBluetoothAudio = prioritizesNetworkErrorsOverBluetoothAudio
        self.bluetoothSymbolScale = Self.clamped(bluetoothSymbolScale, to: Self.centerSymbolScaleRange,
                                                 default: Self.defaultCenterSymbolScale)
        self.bluetoothAudioIconChoice = bluetoothAudioIconChoice
    }

    /// SettingsStore's clamping: a finite value is pulled into the range, a
    /// non-finite one falls back to the default.
    public static func clamped(_ value: Double, to range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// The upstream `iconAppearancePublisher` assembly: the battery text and
    /// bolt share one scale (× 1.8), the ring stroke style feeds the battery
    /// ring and the volume indicator, and a Bluetooth glyph this macOS lacks
    /// falls back to Automatic without rewriting the choice.
    @MainActor
    var configuration: IconPresentationConfiguration {
        IconPresentationConfiguration(
            battery: BatteryIconOptions(
                showsPercentage: showsBatteryPercentage,
                showsChargingIndicator: showsChargingIndicator,
                showsChargingEffect: showsChargingEffect,
                showsChargingBoltHeartbeat: showsChargingBoltHeartbeat,
                usesStatusColors: usesBatteryStatusColors,
                criticalThreshold: Int(batteryCriticalThreshold.rounded()),
                showsPercentageWhenConnected: showsPercentageWhenConnected,
                fullThreshold: Int(batteryFullThreshold.rounded()),
                textScale: batterySymbolScale * BatteryIconOptions.defaultTextScale,
                ringStrokeScale: ringStrokeStyle.scale
            ),
            connection: ConnectionIconOptions(
                showsWiFiIconForEthernet: showsWiFiIconForEthernet,
                showsWiFiIconForHotspot: showsWiFiIconForHotspot,
                showsWiFiIconForTemporaryConnection: showsWiFiIconForTemporaryConnection,
                showsWiFiIconForInternetSharing: showsWiFiIconForInternetSharing,
                showsBatteryPercentageInConnectionSlot: showsBatteryPercentageInConnectionSlot,
                wifiScale: wifiSymbolScale
            ),
            volume: VolumeIconOptions(displayStyle: volumeDisplayStyle, ringStrokeScale: ringStrokeStyle.scale),
            bluetooth: BluetoothAudioIconOptions(
                replacesNetworkIcon: replacesNetworkIconWithBluetoothAudio,
                usesVolumeColor: usesBluetoothAudioVolumeColor,
                prioritizesNetworkErrors: prioritizesNetworkErrorsOverBluetoothAudio,
                symbolScale: bluetoothSymbolScale,
                networkIconSymbolOverride: nil,
                iconChoice: BluetoothAudioIconChoice.persisted(bluetoothAudioIconChoice.rawValue) { symbol in
                    NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
                }
            )
        )
    }

    @MainActor
    var presentationSettings: IconPresentationSettings {
        IconPresentationSettings(configuration: configuration, menuBarSize: iconSize, testsChargingEffect: false)
    }
}
