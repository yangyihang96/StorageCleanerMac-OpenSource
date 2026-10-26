import Foundation
import FanControlShared

#if DEBUG || STORAGE_CLEANER_BETA
/// Fixed monitor values for repeatable menu-bar-panel screenshots. This is
/// intentionally opt-in so normal Debug sessions keep using live telemetry.
enum MiniWindowDemoData {
    static let launchArgument = "--debug-mini-window-demo-data"
    static let menuBarPanelSnapshotCaptureArgumentPrefix = "--capture-menu-bar-panel-directory="
    static let menuBarPanelSnapshotScenarioArgumentPrefix = "--capture-menu-bar-panel-scenario="
    static let menuBarPanelSnapshotPowerArgument = "--capture-menu-bar-panel-power"
    static let menuBarPanelSnapshotPowerModeArgument = "--capture-menu-bar-panel-power-mode"
    static let menuBarPanelSnapshotSectionArgumentPrefix = "--capture-menu-bar-panel-section="
    static let batteryStateArgumentPrefix = "--debug-battery-state="
    static let chargeLimitStateArgumentPrefix = "--debug-charge-limit-state="
    static let hardwareControlStateArgumentPrefix = "--debug-hardware-control-state="
    static let appearanceArgumentPrefix = "--debug-mini-window-appearance="
    static let memoryUsedPercentArgumentPrefix = "--debug-memory-used-percent="
    static let memoryPressureArgumentPrefix = "--debug-memory-pressure="
    static let cpuPatternArgumentPrefix = "--debug-cpu-pattern="
    static let referenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

    enum CPUValidationPattern: String, CaseIterable, Sendable {
        case low, step, spike, missing

        func totalPercent(secondsBeforeCurrent seconds: Int) -> Double? {
            switch self {
            case .low: 6
            case .step: seconds > 90 ? 10 : 70
            case .spike: (36...40).contains(seconds) ? 90 : 10
            case .missing: (21...30).contains(seconds) ? nil : 10
            }
        }
    }

    struct ValidationOptions: Sendable {
        let memoryUsedPercent: Int?
        let memoryPressure: MemoryPressureLevel?
        let cpuPattern: CPUValidationPattern?
    }

    /// These data-only options cannot activate demo mode on their own.
    static func validationOptions(arguments: [String]) -> ValidationOptions? {
        guard arguments.contains(launchArgument) else { return nil }
        func value(_ prefix: String) -> String? {
            let matches = arguments.filter { $0.hasPrefix(prefix) }
            guard matches.count == 1, let argument = matches.first else { return nil }
            return String(argument.dropFirst(prefix.count))
        }
        let used = value(memoryUsedPercentArgumentPrefix).flatMap(Int.init)
            .flatMap { [20, 55, 90].contains($0) ? $0 : nil }
        let pressure: MemoryPressureLevel? = switch value(memoryPressureArgumentPrefix) {
        case "normal": .normal
        case "elevated": .elevated
        case "critical": .critical
        default: nil
        }
        let cpu = value(cpuPatternArgumentPrefix).flatMap(CPUValidationPattern.init(rawValue:))
        guard used != nil || pressure != nil || cpu != nil else { return nil }
        return ValidationOptions(memoryUsedPercent: used, memoryPressure: pressure, cpuPattern: cpu)
    }

    enum MenuBarSnapshotRoute: Equatable {
        case overview
        case secondary(PanelSection)
        case tertiary(PanelSection, MenuBarTertiaryDetail)
        case inline(PanelSection, String)
    }

    enum MenuBarSnapshotScenario: String, CaseIterable {
        case overviewBaseDark = "menu.overview.baseDark"
        case overviewMoreMenu = "menu.overview.moreMenu"
        case overviewRefreshMenu = "menu.overview.refreshMenu"
        case overviewCustomizer = "menu.overview.customizer"
        case memorySecondary = "menu.memory.secondary"
        case memoryHistory = "menu.memory.history"
        case memoryComposition = "menu.memory.composition"
        case memoryProcessesInitial = "menu.memory.processes.initial"
        case memoryProcessesSelected = "menu.memory.processes.selected"
        case memoryProcessesQuitResult = "menu.memory.processes.quitResult"
        case memorySelectionMenu = "menu.memory.selectionMenu"
        case memoryQuitConfirmation = "menu.memory.quitConfirmation"
        case processorSecondary = "menu.processor.secondary"
        case processorSecondaryNoFrequency = "menu.processor.secondary.noFrequency"
        case cpuHistory = "menu.cpu.history"
        case cpuHistoryShortRecording = "menu.cpu.history.shortRecording"
        case cpuUsageInspector = "menu.cpu.usageInspector"
        case cpuUptimeInspector = "menu.cpu.uptimeInspector"
        case gpuActivityHistory = "menu.gpu.activityHistory"
        case diskSecondary = "menu.disk.secondary"
#if DEBUG
        case cleanupAfterSmartScan = "menu.cleanup.afterSmartScan"
#endif
        case diskIOHistory = "menu.disk.ioHistory"
        case diskVolumeInspector = "menu.disk.volumeInspector"
        case networkSecondary = "menu.network.secondary"
        case networkSecondaryUnavailable = "menu.network.secondary.unavailable"
        case networkHistory = "menu.network.history"
        case networkPhysicalInterface = "menu.network.physicalInterface"
        case networkVPNPPP = "menu.network.vpn.pppControllable"
        case networkVPNThirdParty = "menu.network.vpn.thirdPartyManaged"
        case networkVPNSystem = "menu.network.vpn.systemManaged"
        case networkVPNReadOnly = "menu.network.vpn.readOnly"
        case networkVPNDisconnectConfirmation = "menu.network.vpn.disconnectConfirmation"
        case sensorSecondary = "menu.sensor.secondary"
        case sensorSecondaryNoHelper = "menu.sensor.secondary.noHelper"
        case sensorGPUTemperature = "menu.sensor.gpuTemperature"
        case sensorCPUTemperature = "menu.sensor.cpuTemperature"
        case sensorFanSpeedHistory = "menu.sensor.fanSpeedHistory"
        case fanCurveEditor = "menu.fan.curveEditor"
        case fanControlFull = "menu.fan.control.full"
        case fanControlAutoCompact = "menu.fan.control.autoCompact"
        case powerSecondary = "menu.power.secondary"
        case powerSecondaryNoHelper = "menu.power.secondary.noHelper"
        case powerLiveElectricalReadings = "menu.power.liveElectricalReadings"
        case powerModeAndChargeTarget = "menu.power.modeAndChargeTarget"
        // D57: the new third levels.
        case powerChipBreakdown = "menu.power.chipBreakdown"
        case powerBacklightDetail = "menu.power.backlightDetail"
        case powerBatteryDetail = "menu.power.batteryDetail"
        case sensorCPURowDetail = "menu.sensor.cpuRowDetail"
        case sensorPalmRestDetail = "menu.sensor.palmRestDetail"
        case sensorHardwareProbes = "menu.sensor.hardwareProbes"
        case sensorAmbientLightDetail = "menu.sensor.ambientLightDetail"
        // r2-mini-sensors review: the battery row's third level, an Ultra's
        // per-die channel names, an Energy Model without a CPU channel; the
        // "整机" row's third level (incremental review P2-3).
        case powerSystemDetail = "menu.power.systemDetail"
        case powerBatteryRowDetail = "menu.power.batteryRowDetail"
        case powerChipBreakdownUltra = "menu.power.chipBreakdownUltra"
        case powerChipWithoutCPU = "menu.power.chipWithoutCPU"

        var route: MenuBarSnapshotRoute {
            switch self {
            case .overviewBaseDark, .overviewMoreMenu, .overviewRefreshMenu,
                 .overviewCustomizer:
                .overview
            case .memorySecondary, .memoryProcessesInitial,
                 .memoryProcessesSelected, .memoryProcessesQuitResult,
                 .memorySelectionMenu, .memoryQuitConfirmation:
                .secondary(.memory)
            case .processorSecondary, .processorSecondaryNoFrequency:
                .secondary(.processor)
            case .diskSecondary:
                .secondary(.disk)
#if DEBUG
            case .cleanupAfterSmartScan:
                .secondary(.cleanup)
#endif
            case .networkSecondary, .networkSecondaryUnavailable:
                .secondary(.network)
            case .sensorSecondary, .sensorSecondaryNoHelper:
                .secondary(.sensors)
            case .powerSecondary, .powerSecondaryNoHelper:
                .secondary(.power)
            case .memoryHistory:
                .tertiary(.memory, .memory)
            case .memoryComposition:
                .inline(.memory, debugRouteIdentifier)
            case .cpuHistory, .cpuHistoryShortRecording:
                .tertiary(.processor, .processor)
            case .diskIOHistory:
                .tertiary(.disk, .disk)
            case .networkPhysicalInterface:
                .tertiary(.network, .network)
            case .fanCurveEditor:
                .tertiary(.sensors, .fanCurve)
            case .powerLiveElectricalReadings:
                .tertiary(.power, .power)
            case .gpuActivityHistory:
                .inline(.processor, debugRouteIdentifier)
            case .cpuUsageInspector, .cpuUptimeInspector:
                .inline(.processor, debugRouteIdentifier)
            case .diskVolumeInspector:
                .inline(.disk, debugRouteIdentifier)
            case .networkHistory:
                .inline(.network, debugRouteIdentifier)
            case .sensorGPUTemperature, .sensorCPUTemperature,
                 .sensorFanSpeedHistory:
                .inline(.sensors, debugRouteIdentifier)
            case .networkVPNPPP, .networkVPNThirdParty, .networkVPNSystem,
                 .networkVPNReadOnly, .networkVPNDisconnectConfirmation:
                .inline(.network, debugRouteIdentifier)
            case .fanControlFull, .fanControlAutoCompact:
                .inline(.sensors, debugRouteIdentifier)
            case .powerModeAndChargeTarget, .powerChipBreakdown, .powerBacklightDetail,
                 .powerBatteryDetail, .powerBatteryRowDetail, .powerChipBreakdownUltra,
                 .powerChipWithoutCPU, .powerSystemDetail:
                .inline(.power, debugRouteIdentifier)
            case .sensorCPURowDetail, .sensorPalmRestDetail, .sensorHardwareProbes,
                 .sensorAmbientLightDetail:
                .inline(.sensors, debugRouteIdentifier)
            }
        }

        var expectedPanelCount: Int {
            if self == .overviewCustomizer { return 2 }
            return switch route {
            case .overview:
                1
            case .secondary:
                2
            case .tertiary:
                3
            case .inline:
                3
            }
        }

        var captureFileName: String {
            rawValue.replacingOccurrences(of: ".", with: "-") + ".png"
        }

        var debugRouteIdentifier: String {
            "debug.snapshot.\(rawValue)"
        }

        init?(debugRouteIdentifier: String) {
            let prefix = "debug.snapshot."
            guard debugRouteIdentifier.hasPrefix(prefix) else { return nil }
            self.init(rawValue: String(debugRouteIdentifier.dropFirst(prefix.count)))
        }
    }

    static var helperPowerMetricsState: HelperPowerMetricsState {
        helperPowerMetricsState(for: capturedMenuBarPanelScenario(arguments: ProcessInfo.processInfo.arguments))
    }

    /// Snapshot-only data; never configures a monitor or invokes the helper.
    static func helperPowerMetricsState(for scenario: MenuBarSnapshotScenario?) -> HelperPowerMetricsState {
        if scenario == .sensorSecondaryNoHelper || scenario == .powerSecondaryNoHelper
            || scenario == .processorSecondaryNoFrequency { return .needsHelper }
        return .available(PowermetricsSample(cpuMilliwatts: 12_400, gpuMilliwatts: 6_400, aneMilliwatts: 0,
            clusters: [.init(name: "P0", kind: .performance, megahertz: 3_600),
                       .init(name: "E0", kind: .efficiency, megahertz: 1_800)],
            gpuMegahertz: 340, durationSeconds: 1), sampledAt: referenceDate)
    }

    private struct DebugVPNServiceIDVerifier: VPNServiceIDVerifying {
        func isVerifiedPPPServiceID(_ serviceID: String) -> Bool { !serviceID.isEmpty }
    }

    private struct DebugVPNProviderURLVerifier: VPNProviderApplicationURLVerifying {
        func isReliableProviderApplicationURL(_ url: URL) -> Bool { url.isFileURL }
    }

    static var vpnCapabilityResolver: VPNControlCapabilityResolver {
        VPNControlCapabilityResolver(
            serviceIDVerifier: DebugVPNServiceIDVerifier(),
            providerApplicationURLVerifier: DebugVPNProviderURLVerifier()
        )
    }

    static func vpnTunnel(for scenario: MenuBarSnapshotScenario) -> VPNTunnelSnapshot? {
        let attributes: (
            serviceID: String?,
            name: String,
            provider: String?,
            providerBundleID: String?,
            providerURL: URL?,
            protocolKind: VPNProtocolKind,
            bsdName: String
        )
        switch scenario {
        case .networkVPNPPP, .networkVPNDisconnectConfirmation:
            attributes = (
                "debug.ppp.vpn", "Work PPP", nil, nil, nil, .ppp, "ppp0"
            )
        case .networkVPNThirdParty:
            attributes = (
                nil,
                "WireGuard",
                "WireGuard",
                "com.wireguard.macos",
                URL(fileURLWithPath: "/Applications/WireGuard.app"),
                .wireGuard,
                "utun4"
            )
        case .networkVPNSystem:
            attributes = (
                "debug.ikev2.vpn", "Office IKEv2", nil, nil, nil, .ikev2, "ipsec0"
            )
        case .networkVPNReadOnly:
            attributes = (
                nil, "Detected VPN", nil, nil, nil, .packetTunnel, "utun7"
            )
        default:
            return nil
        }

        return VPNTunnelSnapshot(
            stableID: attributes.serviceID.map { "service:\($0)" },
            serviceID: attributes.serviceID,
            displayName: attributes.name,
            providerName: attributes.provider,
            providerBundleIdentifier: attributes.providerBundleID,
            providerApplicationURL: attributes.providerURL,
            protocolKind: attributes.protocolKind,
            bsdName: attributes.bsdName,
            status: .connected,
            tunnelIPv4: ["10.8.0.2"],
            tunnelIPv6: ["fd00:8::2"],
            scopedDNSServers: ["10.8.0.1", "1.1.1.1"],
            gatewayOrRemoteAddress: "198.51.100.24",
            isDefaultRoute: true,
            isSplitTunnel: false,
            // D140: the tunnel's addresses are point-to-point, so iStat lists
            // none of them.
            listedAddresses: []
        )
    }

    enum BatteryDemoState: String, Sendable {
        case charging
        case battery
        case charged
        case connected
        case batteryToExternal
        case externalToBattery
        case missing
    }

    enum ChargeLimitDemoState: String, CaseIterable, Sendable {
        case manual80, optimized80, temporaryFullCharge, unsupported, manySegments
    }

    static func chargeLimitState(arguments: [String] = ProcessInfo.processInfo.arguments) -> BatteryChargeLimitState? {
        let raw = arguments.first { $0.hasPrefix(chargeLimitStateArgumentPrefix) }
            .map { String($0.dropFirst(chargeLimitStateArgumentPrefix.count)) }
        return chargeLimitState(for: ChargeLimitDemoState(rawValue: raw ?? "") ?? .manual80)
    }

    /// Synthetic supported values are fixture-only; production uses the native readback.
    static func chargeLimitState(for state: ChargeLimitDemoState) -> BatteryChargeLimitState? {
        switch state {
        case .manual80:
            return BatteryChargeLimitState.resolve(manualLimitEnabled: true, manualLimit: 80,
                availableLimits: [80, 85, 90, 95, 100], effectiveLimit: 80)
        case .optimized80:
            return BatteryChargeLimitState.resolve(manualLimitEnabled: false, manualLimit: 80,
                availableLimits: [80, 85, 90, 95, 100], effectiveLimit: 80,
                smartChargingRawValue: 1, maxLimited: true)
        case .temporaryFullCharge:
            return BatteryChargeLimitState.resolve(manualLimitEnabled: true, manualLimit: 80,
                availableLimits: [80, 85, 90, 95, 100], effectiveLimit: 100,
                smartChargingRawValue: 3, maxLimited: false)
        case .unsupported:
            return BatteryChargeLimitState(target: .full, availableTargets: [], source: .unknown)
        case .manySegments:
            return BatteryChargeLimitState.resolve(manualLimitEnabled: true, manualLimit: 85,
                availableLimits: [70, 75, 80, 85, 90, 95, 100], effectiveLimit: 85)
        }
    }

    enum HardwareControlDemoState: String, CaseIterable, Sendable {
        case helperNotRegistered
        case awaitingSystemApproval
        case helperEnabled
        case fanAutomatic
        case fanManual65
        case fanMaximum
        case fanReadOnly
        case fanChecking
        case fanless
        case dualFan
        /// Review P2-2: manual control with two fans (shows "双风扇同步").
        case dualFanManual
        case desktopMac
        case noHighPower
        case allPowerModes
        case connectionInterrupted
        case helperUntrusted
        case helperUnavailable
        case thermalSerious
        case thermalCritical
        case fanReadbackFailed
        case curveNotConfigured
        case curveDefault
        case curveActive
        case curveDraftChanges
        case curveSensorUnavailable
        case curveThermalProtection
    }

    struct HardwareControlDemoProfile: Sendable {
        let helperState: HelperState
        let observedMode: GeekFanControlMode?
        let manualPercentage: Double?
        let fanReadings: [SystemFanReading]
        let sensorAvailability: SystemSensorAvailability
        let thermalState: SystemThermalState
        let powerModes: BatteryPowerModes
        let hasInternalBattery: Bool
        let message: String?
        let curveProfile: FanCurveProfile?
        let curveRuntimeState: FanCurveRuntimeState
        let curveHasUnappliedChanges: Bool
    }

    static func chartDate(
        liveDate: Date,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Date {
        arguments.contains(launchArgument) ? referenceDate : liveDate
    }

    static var isEnabled: Bool {
#if DEBUG
        if LightfieldComponentGallery.isRequested { return true }
#endif
        return ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var batteryState: BatteryDemoState {
        let raw = ProcessInfo.processInfo.arguments.first {
            $0.hasPrefix(batteryStateArgumentPrefix)
        }?.dropFirst(batteryStateArgumentPrefix.count)
        return BatteryDemoState(rawValue: String(raw ?? "")) ?? .connected
    }

    static var hardwareControlState: HardwareControlDemoState {
        hardwareControlState(arguments: ProcessInfo.processInfo.arguments)
    }

    static func hardwareControlState(arguments: [String]) -> HardwareControlDemoState {
        let raw = arguments.first {
            $0.hasPrefix(hardwareControlStateArgumentPrefix)
        }?.dropFirst(hardwareControlStateArgumentPrefix.count)
        return HardwareControlDemoState(rawValue: String(raw ?? "")) ?? .fanAutomatic
    }

    static var forcedColorScheme: String? {
        ProcessInfo.processInfo.arguments.first {
            $0.hasPrefix(appearanceArgumentPrefix)
        }.map { String($0.dropFirst(appearanceArgumentPrefix.count)) }
    }

    static var hardwareControlProfile: HardwareControlDemoProfile {
        hardwareControlProfile(for: hardwareControlState)
    }

    static var capturesFanCurveEditor: Bool {
        switch hardwareControlState {
        case .curveNotConfigured, .curveDefault, .curveDraftChanges:
            true
        default:
            false
        }
    }

    static func hardwareControlProfile(
        for state: HardwareControlDemoState
    ) -> HardwareControlDemoProfile {
        let baseFan = SystemFanReading(
            index: 0,
            identity: .cpu,
            actualRPM: 1_620,
            minimumRPM: 1_200,
            maximumRPM: 4_000,
            targetRPM: 1_600
        )
        let allModes = BatteryPowerModes(
            battery: .automatic,
            adapter: .automatic,
            supportedBatteryModes: [.automatic, .lowPower, .highPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .powerMode,
            adapterSetting: .powerMode
        )
        var helperState = HelperState.enabled
        var observedMode: GeekFanControlMode? = .systemAutomatic
        var manualPercentage: Double?
        var fanReadings = [baseFan]
        var sensorAvailability = SystemSensorAvailability.available
        var thermalState = SystemThermalState.nominal
        var powerModes = allModes
        var hasInternalBattery = true
        var message: String?
        var curveProfile: FanCurveProfile?
        var curveRuntimeState = FanCurveRuntimeState.inactive
        var curveHasUnappliedChanges = false

        switch state {
        case .helperNotRegistered:
            helperState = .notRegistered
            observedMode = nil
        case .awaitingSystemApproval:
            helperState = .requiresApproval
            observedMode = nil
        case .helperEnabled:
            observedMode = nil
        case .fanAutomatic, .allPowerModes, .curveNotConfigured:
            break
        case .fanManual65:
            observedMode = .manual
            manualPercentage = 65
            fanReadings = [SystemFanReading(
                index: 0,
                identity: .cpu,
                actualRPM: 3_020,
                minimumRPM: 1_200,
                maximumRPM: 4_000,
                targetRPM: 3_020
            )]
        case .fanMaximum:
            observedMode = .maximum
            fanReadings = [SystemFanReading(index: 0, identity: .cpu, actualRPM: 4_000,
                minimumRPM: 1_200, maximumRPM: 4_000, targetRPM: 4_000)]
        case .fanReadOnly:
            observedMode = nil
            fanReadings = [SystemFanReading(
                index: 0,
                identity: .cpu,
                actualRPM: 1_620,
                minimumRPM: nil,
                maximumRPM: nil,
                targetRPM: nil
            )]
        case .fanChecking:
            observedMode = nil
            fanReadings = []
            sensorAvailability = .sampling
        case .fanless:
            observedMode = nil
            fanReadings = []
        case .dualFan:
            fanReadings = [
                baseFan,
                SystemFanReading(
                    index: 1,
                    identity: .gpu,
                    actualRPM: 1_800,
                    minimumRPM: 1_300,
                    maximumRPM: 4_500,
                    targetRPM: 1_780
                ),
            ]
        case .dualFanManual:
            observedMode = .manual
            manualPercentage = 65
            fanReadings = [
                SystemFanReading(
                    index: 0,
                    identity: .cpu,
                    actualRPM: 3_020,
                    minimumRPM: 1_200,
                    maximumRPM: 4_000,
                    targetRPM: 3_020
                ),
                SystemFanReading(
                    index: 1,
                    identity: .gpu,
                    actualRPM: 3_380,
                    minimumRPM: 1_300,
                    maximumRPM: 4_500,
                    targetRPM: 3_380
                ),
            ]
        case .desktopMac:
            hasInternalBattery = false
        case .noHighPower:
            powerModes = BatteryPowerModes(
                battery: .automatic,
                adapter: .lowPower,
                supportedBatteryModes: [.automatic, .lowPower],
                supportedAdapterModes: [.automatic, .lowPower],
                batterySetting: .lowPowerMode,
                adapterSetting: .lowPowerMode
            )
        case .helperUntrusted:
            helperState = .signatureRejected
            observedMode = nil
        case .helperUnavailable:
            helperState = .unavailable
            observedMode = nil
        case .connectionInterrupted:
            helperState = .connectionInterrupted
            observedMode = nil
            message = L10n.text("高级控制连接已中断。", "Advanced control connection was interrupted.")
        case .thermalSerious:
            thermalState = .serious
            message = L10n.text("系统温度较高，已恢复自动散热。", "Automatic cooling was restored because the thermal state is serious.")
        case .thermalCritical:
            thermalState = .critical
            message = L10n.text("已触发热保护并恢复自动散热。", "Thermal protection restored automatic cooling.")
        case .fanReadbackFailed:
            observedMode = nil
            message = L10n.text("风扇写入回读不一致；恢复系统自动控制尚未确认。", "Fan readback did not match; restoration of automatic system control remains unconfirmed.")
        case .curveDefault:
            curveProfile = FanCurveProfile.balanced(targetFanIDs: [0])
        case .curveActive, .curveDraftChanges:
            let profile = FanCurveProfile.balanced(targetFanIDs: [0])
            curveProfile = profile
            observedMode = .customCurve
            curveHasUnappliedChanges = state == .curveDraftChanges
            fanReadings = [SystemFanReading(
                index: 0,
                identity: .cpu,
                actualRPM: 2_180,
                minimumRPM: 1_200,
                maximumRPM: 4_000,
                targetRPM: 2_180
            )]
            curveRuntimeState = FanCurveRuntimeState(
                status: .active,
                rawTemperature: 53,
                filteredTemperature: 52.7,
                calculatedPercentage: 35,
                appliedPercentage: 35,
                targetRPMByFan: [0: 2_180],
                actualRPMByFan: [0: 2_180],
                activeProfileID: profile.id,
                lastSensorUpdate: referenceDate,
                lastFanWrite: referenceDate,
                lastVerification: referenceDate
            )
        case .curveSensorUnavailable:
            curveProfile = FanCurveProfile.balanced(targetFanIDs: [0])
            observedMode = nil
            curveRuntimeState = FanCurveRuntimeState(
                status: .sensorUnavailable,
                failureReason: .sensorUnavailable
            )
            message = L10n.text(
                "无法读取所选温度传感器，已恢复系统自动散热。",
                "The selected sensor is unavailable; automatic cooling was restored."
            )
        case .curveThermalProtection:
            curveProfile = FanCurveProfile.balanced(targetFanIDs: [0])
            observedMode = nil
            thermalState = .serious
            curveRuntimeState = FanCurveRuntimeState(
                status: .thermalProtection,
                failureReason: .thermalProtectionActivated
            )
            message = L10n.text(
                "系统温度较高，已恢复系统自动散热。",
                "The thermal state is high; automatic cooling was restored."
            )
        }

        return HardwareControlDemoProfile(
            helperState: helperState,
            observedMode: observedMode,
            manualPercentage: manualPercentage,
            fanReadings: fanReadings,
            sensorAvailability: sensorAvailability,
            thermalState: thermalState,
            powerModes: powerModes,
            hasInternalBattery: hasInternalBattery,
            message: message,
            curveProfile: curveProfile,
            curveRuntimeState: curveRuntimeState,
            curveHasUnappliedChanges: curveHasUnappliedChanges
        )
    }

    static func fanTelemetry(for state: HardwareControlDemoState) -> FanTelemetryState {
        let profile = hardwareControlProfile(for: state)
        let readings = profile.fanReadings
        func average(_ values: [Int]) -> Int? {
            guard !values.isEmpty else { return nil }
            return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        }
        return FanTelemetryState(
            actualRPM: average(readings.map(\.actualRPM)),
            minRPM: average(readings.compactMap(\.minimumRPM)),
            maxRPM: average(readings.compactMap(\.maximumRPM)),
            targetRPM: average(readings.compactMap(\.targetRPM)),
            fanCount: readings.count,
            timestamp: referenceDate,
            telemetryAvailable: !readings.isEmpty,
            isSampling: readings.isEmpty && profile.sensorAvailability == .sampling,
            isFanless: state == .fanless,
            readings: readings
        )
    }

#if DEBUG || STORAGE_CLEANER_BETA
    @MainActor private static var hasCompletedMenuBarPanelSnapshots = false

    @MainActor static func finishMenuBarPanelSnapshots() {
        hasCompletedMenuBarPanelSnapshots = true
    }

    @MainActor static var isCapturingMenuBarPanelSnapshots: Bool {
        !hasCompletedMenuBarPanelSnapshots && isCapturingMenuBarPanelSnapshots(
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func isCapturingMenuBarPanelSnapshots(arguments: [String]) -> Bool {
        arguments.contains {
            $0.hasPrefix(menuBarPanelSnapshotCaptureArgumentPrefix)
        }
    }

    static var isCapturingPowerMenuBarPanelSnapshots: Bool {
        isCapturingPowerMenuBarPanelSnapshots(
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func isCapturingPowerMenuBarPanelSnapshots(arguments: [String]) -> Bool {
        arguments.contains(menuBarPanelSnapshotPowerArgument)
    }

    static var isCapturingPowerModeMenuBarPanelSnapshot: Bool {
        ProcessInfo.processInfo.arguments.contains(menuBarPanelSnapshotPowerModeArgument)
    }

    static func capturedMenuBarPanelScenario(
        arguments: [String]
    ) -> MenuBarSnapshotScenario? {
        guard arguments.contains(launchArgument),
              arguments.contains(where: {
                  $0.hasPrefix(menuBarPanelSnapshotCaptureArgumentPrefix)
              }),
              let argument = arguments.first(where: {
                  $0.hasPrefix(menuBarPanelSnapshotScenarioArgumentPrefix)
              }) else { return nil }
        return MenuBarSnapshotScenario(rawValue: String(
            argument.dropFirst(menuBarPanelSnapshotScenarioArgumentPrefix.count)
        ))
    }

    @MainActor
    static func configure(
        store: ScanStore,
        for scenario: MenuBarSnapshotScenario
    ) {
#if DEBUG
        if scenario == .cleanupAfterSmartScan {
            // Use the existing inert Store fixture, so both windows read the
            // same session and existing guards still block every execution.
            store.installDebugSmartScanSessionFixture(.results)
        }
#endif
        store.memorySnapshot = memorySnapshot
        store.memoryOptimizationResult = nil
        store.selectedMemoryProcessIDs = []
        store.pendingMemoryProcessesToQuit = []
        store.pendingMemoryQuitSummary = nil
        store.isMemoryBatchQuitConfirmationPresentedInMenuBar = false

        let selectedIDs: Set<Int32> = [201, 202, 204]
        switch scenario {
        case .memoryProcessesSelected, .memoryQuitConfirmation:
            store.selectedMemoryProcessIDs = selectedIDs
        case .memoryProcessesQuitResult:
            store.memorySnapshot = memoryAfterQuitSnapshot
            store.memoryOptimizationResult = memoryQuitResult
        default:
            break
        }

        guard scenario == .memoryQuitConfirmation else { return }
        let selected = memorySnapshot.selectableQuitProcesses.filter {
            selectedIDs.contains($0.id)
        }
        store.pendingMemoryProcessesToQuit = selected
        store.pendingMemoryQuitSummary = MemoryQuitSelectionSummary(
            appCount: 3,
            estimatedBytes: selected.reduce(0) { $0 + $1.residentBytes }
        )
        store.isMemoryBatchQuitConfirmationPresentedInMenuBar = true
    }

    static func allowsTertiaryPresentation(arguments: [String]) -> Bool {
        guard let scenario = capturedMenuBarPanelScenario(arguments: arguments) else {
            return true
        }
        if case .secondary = scenario.route { return false }
        return true
    }

    static let liveAuditSectionsArgumentPrefix = "--capture-menu-bar-live-audit-sections="

    /// The live audit's pages, all monitoring pages by default; a list
    /// such as `sensors,power` keeps pages with private data (process
    /// lists, addresses) out of a capture.
    static func liveAuditSections(arguments: [String]) -> [PanelSection] {
        let all: [PanelSection] = [.processor, .memory, .disk, .network, .sensors, .power]
        guard let argument = arguments.first(where: { $0.hasPrefix(liveAuditSectionsArgumentPrefix) }) else {
            return all
        }
        let requested = Set(argument.dropFirst(liveAuditSectionsArgumentPrefix.count)
            .split(separator: ",").compactMap { PanelSection(rawValue: String($0)) })
        return all.filter(requested.contains)
    }

    static func capturedMenuBarPanelSection(arguments: [String]) -> PanelSection? {
        guard let argument = arguments.first(where: {
            $0.hasPrefix(menuBarPanelSnapshotSectionArgumentPrefix)
        }) else { return nil }
        let rawValue = String(argument.dropFirst(menuBarPanelSnapshotSectionArgumentPrefix.count))
        guard let section = PanelSection(rawValue: rawValue),
              section.tertiaryDetail != nil else { return nil }
        return section
    }
#endif

    struct Fixture: Sendable {
        let snapshot: SystemMonitorSnapshot
        let telemetry: [MenuBarTelemetryPoint]
    }

    /// D71 freshness applies to live readings. A fixed screenshot's historical date
    /// must not erase its temperatures/fans while the palette uses the same fixture.
    static func presentationSnapshot(live: SystemMonitorSnapshot?, usesDemoData: Bool = isEnabled) -> SystemMonitorSnapshot? {
        usesDemoData ? fixture.snapshot : live
    }

    static let fixture = makeFixture(arguments: ProcessInfo.processInfo.arguments)

    static func makeFixture(arguments: [String]) -> Fixture {
        let validation = validationOptions(arguments: arguments)
        let memory = makeMemorySnapshot(arguments: arguments)
        let hardwareState = hardwareControlState(arguments: arguments)
        let fullTelemetry = telemetryPoints(memorySnapshot: memory, validation: validation, hardwareState: hardwareState)
        let scenario = capturedMenuBarPanelScenario(arguments: arguments)
        let telemetry = scenario == .cpuHistoryShortRecording
            ? shortRecordingPoints(from: fullTelemetry) : fullTelemetry
        let hardware = hardwareControlProfile(for: hardwareState)
        let fan = fanTelemetry(for: hardwareState)
        let hasMemoryOverride = validation?.memoryUsedPercent != nil || validation?.memoryPressure != nil
        let cpuTotal = telemetry.last?.cpuTotal ?? 34
        let cpuUser = telemetry.last?.cpuUser ?? 22
        let cpuSystem = telemetry.last?.cpuSystem ?? 12
        return Fixture(
            snapshot: SystemMonitorSnapshot(
                generatedAt: referenceDate,
                metrics: [
                    SystemMonitorMetric(
                        kind: .cpuUsage,
                        value: String(format: "%.0f%%", cpuTotal),
                        detail: L10n.text("总处理器", "All processors"),
                        isAvailable: true
                    ),
                    SystemMonitorMetric(
                        kind: .gpuUsage,
                        value: "42%",
                        detail: L10n.text("显卡驱动统计", "GPU driver stats"),
                        isAvailable: true
                    ),
                    SystemMonitorMetric(
                        kind: .memoryUsage,
                        value: hasMemoryOverride ? memory.usedPercentText : "81%",
                        detail: hasMemoryOverride
                            ? "\(IStatNumberFormat.memory(memory.usedBytes)) / \(IStatNumberFormat.memory(memory.physicalBytes))"
                            : "38.9 GB / 48 GB",
                        isAvailable: true
                    ),
                    SystemMonitorMetric(
                        kind: .chipTemperature,
                        value: "53°C",
                        detail: L10n.text("实时芯片最高温", "Live chip peak"),
                        isAvailable: true
                    ),
                    SystemMonitorMetric(
                        kind: .fanSpeed,
                        value: fan.actualRPM.map(SystemFanSpeedFormat.string) ?? "—",
                        detail: L10n.text("\(ByteFormat.count(fan.fanCount)) 个风扇", "\(ByteFormat.count(fan.fanCount)) fans"),
                        isAvailable: fan.telemetryAvailable
                    ),
                    SystemMonitorMetric(
                        kind: .networkSpeed,
                        value: "↓ 3.8 MB/s",
                        detail: "↑ 420 KB/s",
                        isAvailable: true
                    ),
                ],
                networkThroughput: NetworkMonitorThroughput(
                    downBytesPerSecond: 3_800_000,
                    upBytesPerSecond: 420_000
                ),
                cpuUsageBreakdown: CPUUsageBreakdown(
                    totalPercent: cpuTotal,
                    userPercent: cpuUser,
                    systemPercent: cpuSystem
                ),
                cpuCoreUsagePercent: validation?.cpuPattern != nil
                    ? Array(repeating: cpuTotal, count: 16) : [
                    18, 21, 25, 29, 35, 42, 31, 26,
                    23, 28, 33, 37, 24, 20, 30, 34,
                ],
                loadAverage: SystemLoadAverage(
                    oneMinute: 3.2,
                    fiveMinutes: 2.8,
                    fifteenMinutes: 2.4
                ),
                systemUptimeSeconds: 734_400,
                systemBootAt: referenceDate.addingTimeInterval(-734_400),
                thermalState: hardware.thermalState,
                fanSpeedsRPM: hardware.fanReadings.map(\.actualRPM),
                fanCount: hardwareState == .fanless ? 0 : nil,
                fanReadings: hardware.fanReadings,
                temperatureReadings: [
                    SystemTemperatureReading(zone: .chip, celsius: 53),
                    SystemTemperatureReading(zone: .gpu, celsius: 49),
                    SystemTemperatureReading(zone: .performanceCores, celsius: 53),
                    SystemTemperatureReading(zone: .efficiencyCores, celsius: 48),
                ] + demoRegionalTemperatures,
                temperatureDetails: demoTemperatureDetails,
                gpuMemoryUsedBytes: 8 * 1_024 * 1_024 * 1_024,
                sensorAvailability: hardware.sensorAvailability,
                fanAvailability: hardware.sensorAvailability,
                inferredTemperatureZones: [.palmRest, .thunderboltLeft, .thunderboltRight],
                ambientLight: .value(161)
            ),
            telemetry: telemetry
        )
    }

    /// D57 demo zones at Mac17,9's measured magnitudes (research §4.1):
    /// SSD `TH0x`, battery `TB0T`, charging circuit `TCHP`, airflow, palm
    /// rest `Ts0P/Ts1P`, Thunderbolt `TaLT/TaRT`, Wi-Fi `TW0P`.
    static let demoRegionalTemperatures: [SystemTemperatureReading] = [
        SystemTemperatureReading(zone: .storage, celsius: 46.3),
        SystemTemperatureReading(zone: .battery, celsius: 31.8),
        SystemTemperatureReading(zone: .chargingCircuit, celsius: 57.1),
        SystemTemperatureReading(zone: .ambient, celsius: 59.8),
        SystemTemperatureReading(zone: .palmRest, celsius: 33.0),
        SystemTemperatureReading(zone: .thunderboltLeft, celsius: 45.7),
        SystemTemperatureReading(zone: .thunderboltRight, celsius: 38.1),
        SystemTemperatureReading(zone: .wifi, celsius: 65.0),
    ]

    /// Hardware probes: CPU cores, GPU regions and the power-management IC.
    static let demoTemperatureDetails: [SystemTemperatureDetailReading] = [
        SystemTemperatureDetailReading(id: "demo.p1", name: L10n.text("性能核心 1", "Performance Core 1"), zone: .performanceCores, celsius: 53),
        SystemTemperatureDetailReading(id: "demo.p2", name: L10n.text("性能核心 2", "Performance Core 2"), zone: .performanceCores, celsius: 51),
        SystemTemperatureDetailReading(id: "demo.p3", name: L10n.text("性能核心 3", "Performance Core 3"), zone: .performanceCores, celsius: 50),
        SystemTemperatureDetailReading(id: "demo.p4", name: L10n.text("性能核心 4", "Performance Core 4"), zone: .performanceCores, celsius: 52),
        SystemTemperatureDetailReading(id: "demo.e1", name: L10n.text("能效核心 1", "Efficiency Core 1"), zone: .efficiencyCores, celsius: 48),
        SystemTemperatureDetailReading(id: "demo.e2", name: L10n.text("能效核心 2", "Efficiency Core 2"), zone: .efficiencyCores, celsius: 47),
        SystemTemperatureDetailReading(id: "demo.gpu1", name: L10n.text("GPU 区域 1 均值", "GPU Region 1 Average"), zone: .gpu, celsius: 49),
        SystemTemperatureDetailReading(id: "demo.gpu2", name: L10n.text("GPU 区域 2 均值", "GPU Region 2 Average"), zone: .gpu, celsius: 50),
        SystemTemperatureDetailReading.powerManagement(celsius: 66.3),
    ]

    /// D57 power card demo at Mac17,9's measured magnitudes (research §4.1,
    /// §4.2 "空闲 2" phase), split into the demo processor's clusters.
    static let powerChannelWatts: [String: Double] = [
        "CPU Energy": 13.33, "PCPU": 11.42, "ECPU": 1.91,
        "GPU Energy": 0.44, "ANE0": 0, "DRAM0": 1.35,
        "AMCC0": 1.01, "DCS0": 1.30, "DISP0": 0.32, "DISPEXT0": 0.12,
        "ISP0": 0.02, "AVE0": 0.02, "MSR0": 0.02, "FAB0": 0.74, "AFR0": 0.13,
    ]

    /// Review P1 scenario: an M2 Ultra names every channel per die
    /// ("DIE_0_CPU Energy", "DIE_1_PCPU0"…; macmon). Same magnitudes as the
    /// demo above, split over the two dies.
    static let ultraPowerChannelWatts: [String: Double] = [
        "DIE_0_CPU Energy": 7.12, "DIE_1_CPU Energy": 6.21,
        "DIE_0_PCPU0": 3.05, "DIE_0_PCPU1": 2.96, "DIE_0_ECPU": 1.11,
        "DIE_1_PCPU0": 2.71, "DIE_1_PCPU1": 2.64, "DIE_1_ECPU": 0.86,
        "GPU Energy": 0.88, "DIE_0_ANE0": 0, "DIE_0_DRAM0": 1.35, "DIE_1_DRAM0": 1.21,
        "DIE_0_AMCC0": 1.01, "DIE_1_AMCC0": 0.94, "DIE_0_DISP0": 0.32, "DIE_0_AVE0": 0.02,
        "DIE_0_FAB0": 0.74, "DIE_1_FAB0": 0.69,
    ]

    /// Review P1 scenario: an Energy Model without any CPU channel.
    static var powerChannelWattsWithoutCPU: [String: Double] {
        powerChannelWatts.filter { !["CPU Energy", "PCPU", "ECPU"].contains($0.key) }
    }

    /// PPBR (only the battery row's third-level reference) as read on
    /// Mac17,9 (5 s means, 43 windows, incremental review): while charging
    /// about 1.4 W whatever the charging power (0.6-2.8 W); while the battery
    /// supplies power about 1.6 × |B0AP| (1.0-2.8 ×).
    static func batteryRailWatts(batteryWatts: Double) -> Double {
        batteryWatts > 0 ? 1.43 : abs(batteryWatts) * 1.59
    }

    static func socPowerReading(channelWatts: [String: Double]) -> SoCPowerReading {
        SoCPowerReading.make(
            channelPowers: channelWatts.mapValues { SoCChannelPower(watts: $0, isUpdating: false) },
            performanceLevelNames: ["Performance", "Efficiency"]
        )
    }

    static var powerTelemetry: MenuBarPowerTelemetry {
        let batteryWatts = batteryElectricalSnapshot.powerWatts ?? 0
        let systemWatts = 38.3
        let soc = socPowerReading(channelWatts: powerChannelWatts)
        let isExternal = [.charging, .charged, .connected, .batteryToExternal].contains(batteryState)
        return MenuBarPowerTelemetry(
            smc: SMCPowerTelemetry(
                systemPowerWatts: .value(systemWatts),
                inputPowerWatts: isExternal ? .value(systemWatts + max(0, batteryWatts) + 0.3) : .value(0),
                inputVoltageVolts: isExternal ? .value(19.6) : .value(0),
                inputCurrentAmps: isExternal ? .value((systemWatts + max(0, batteryWatts) + 0.3) / 19.6) : .value(0),
                batteryPowerWatts: .value(batteryRailWatts(batteryWatts: batteryWatts)),
                chipPowerReferenceWatts: .value(18.8),
                backlight: BacklightPowerReading(
                    sourceKey: "PDBR",
                    reportedWatts: .value(4.67),
                    currentAmps: .value(0.3816),
                    railVoltageVolts: .value(12.247)
                ),
                battery: SMCBatteryTelemetry(
                    currentAmps: .value(batteryWatts / 12.1),
                    voltageVolts: .value(12.1),
                    powerWatts: .value(batteryWatts),
                    temperatureCelsius: .value(31.8),
                    temperatureSourceKey: "TB0T",
                    cellVoltages: [.value(4.032), .value(4.035), .value(4.033)]
                )
            ),
            backlightBrightnessNits: .value(381.8),
            soc: soc,
            generatedAt: referenceDate
        )
    }

    static func processorTelemetry(for scenario: MenuBarSnapshotScenario?) -> CPUPerformanceStateService.Snapshot? {
        scenario == .processorSecondaryNoFrequency ? nil : processorTelemetry
    }

    /// An actual short recording, rather than a one-hour fixture relabelled
    /// as ninety seconds. No history store or live sampler is invoked.
    static func shortRecordingPoints(from points: [MenuBarTelemetryPoint]) -> [MenuBarTelemetryPoint] {
        let recent = Array(points.suffix(90))
        return recent.enumerated().map { index, point in
            let date = referenceDate.addingTimeInterval(-Double(recent.count - 1 - index))
            return MenuBarTelemetryPoint(date: date,
                cpuTotal: point.cpuTotal, cpuUser: point.cpuUser, cpuSystem: point.cpuSystem,
                gpu: point.gpu, memory: point.memory, memoryPressure: point.memoryPressure,
                memoryPressureLevelCode: point.memoryPressureLevelCode,
                memoryAppOrOtherBytes: point.memoryAppOrOtherBytes, memoryWiredBytes: point.memoryWiredBytes,
                memoryPhysicalBytes: point.memoryPhysicalBytes, compressedMemoryBytes: point.compressedMemoryBytes,
                swapUsedBytes: point.swapUsedBytes, swapUsedPercent: point.swapUsedPercent,
                chipTemperature: point.chipTemperature,
                gpuTemperature: point.gpuTemperature, temperatureReadings: point.temperatureReadings,
                fanRPM: point.fanRPM, fanTargetRPM: point.fanTargetRPM, fanReadings: point.fanReadings,
                downBytesPerSecond: point.downBytesPerSecond, upBytesPerSecond: point.upBytesPerSecond,
                sensorSampledAt: point.sensorSampledAt.map { _ in date },
                gpuSampledAt: point.gpuSampledAt.map { _ in date })
        }
    }

    static let processorTelemetry = CPUPerformanceStateService.Snapshot(
        processorModel: "Apple M4 Pro",
        performanceLevels: [
            CPUPerformanceStateService.PerformanceLevel(
                index: 0,
                name: "Performance",
                coreCount: 8,
                coresPerL2: 4
            ),
            CPUPerformanceStateService.PerformanceLevel(
                index: 1,
                name: "Efficiency",
                coreCount: 8,
                coresPerL2: 4
            ),
        ],
        clusters: [
            CPUPerformanceStateService.ClusterReading(
                identifier: "PCPU",
                performanceLevelIndex: 0,
                performanceLevelName: "Performance",
                coreCount: 8,
                frequencyMHz: 3_600,
                voltageVolts: 0.92
            ),
            CPUPerformanceStateService.ClusterReading(
                identifier: "ECPU",
                performanceLevelIndex: 1,
                performanceLevelName: "Efficiency",
                coreCount: 8,
                frequencyMHz: 2_400,
                voltageVolts: 0.74
            ),
        ],
        gpu: CPUPerformanceStateService.GPUReading(
            frequencyMHz: 338,
            activeRatio: 0.6,
            maximumFrequencyMHz: 1_620
        )
    )

    static var preparedProcesses: MenuBarPreparedProcesses {
        MenuBarPreparedProcesses(snapshot: .init(generatedAt: Date(), scanSeconds: 0, sampleSeconds: 1,
            uptimeSeconds: 7_200, apps: energyApps, processCount: energyApps.count,
            measuredProcessCount: energyApps.count, unmeasuredProcessCount: 0,
            measuredTotalEnergyWh: 0.32, estimatedSupplementEnergyWh: 0,
            calibrationWattsPerCore: 1, usesLocalCalibration: false))
    }

    static let energyApps: [EnergyImpactApp] = [
        EnergyImpactApp(
            id: "demo.storage-cleaner",
            name: "Storage Cleaner",
            path: "/Applications/StorageCleanerMac.app",
            iconPath: "",
            bundlePath: "/Applications/StorageCleanerMac.app",
            bundleIdentifier: "com.local.StorageCleanerMac",
            measuredEnergyWh: 0.20,
            estimatedSupplementEnergyWh: 0,
            estimatedEnergyWh: 0.20,
            currentPowerWatts: 1.80,
            averagePowerWatts: 1.50,
            cpuPercent: 12.4,
            diskReadBytesPerSecond: 120_000,
            diskWriteBytesPerSecond: 60_000,
            residentBytes: 420_000_000,
            cumulativeCPUSeconds: 1_200,
            longestRunningSeconds: 7_200,
            processCount: 1,
            measuredProcessCount: 1,
            processIDs: [101],
            isApplication: true
        ),
        EnergyImpactApp(
            id: "demo.preview",
            name: "Preview",
            path: "/System/Applications/Preview.app",
            iconPath: "",
            bundlePath: "/System/Applications/Preview.app",
            bundleIdentifier: "com.apple.Preview",
            measuredEnergyWh: 0.08,
            estimatedSupplementEnergyWh: 0,
            estimatedEnergyWh: 0.08,
            currentPowerWatts: 0.90,
            averagePowerWatts: 0.75,
            cpuPercent: 6.8,
            diskReadBytesPerSecond: 80_000,
            diskWriteBytesPerSecond: 20_000,
            residentBytes: 180_000_000,
            cumulativeCPUSeconds: 760,
            longestRunningSeconds: 5_400,
            processCount: 1,
            measuredProcessCount: 1,
            processIDs: [102],
            isApplication: true
        ),
        EnergyImpactApp(
            id: "demo.safari",
            name: "Safari",
            path: "/Applications/Safari.app",
            iconPath: "",
            bundlePath: "/Applications/Safari.app",
            bundleIdentifier: "com.apple.Safari",
            measuredEnergyWh: 0.04,
            estimatedSupplementEnergyWh: 0,
            estimatedEnergyWh: 0.04,
            currentPowerWatts: 0.45,
            averagePowerWatts: 0.36,
            cpuPercent: 2.7,
            diskReadBytesPerSecond: 30_000,
            diskWriteBytesPerSecond: 10_000,
            residentBytes: 240_000_000,
            cumulativeCPUSeconds: 420,
            longestRunningSeconds: 3_600,
            processCount: 2,
            measuredProcessCount: 2,
            processIDs: [103, 104],
            isApplication: true
        ),
    ]

    static let memorySnapshot = makeMemorySnapshot(arguments: ProcessInfo.processInfo.arguments)

    static func makeMemorySnapshot(arguments: [String]) -> MemorySnapshot {
        guard let validation = validationOptions(arguments: arguments),
              validation.memoryUsedPercent != nil || validation.memoryPressure != nil else {
            return defaultMemorySnapshot
        }
        let base = defaultMemorySnapshot
        let physical = base.physicalBytes
        let used = validation.memoryUsedPercent.map { physical * Int64($0) / 100 } ?? base.usedBytes
        let available = physical - used
        let wired = used / 4
        let compressed = used / 5
        let appBudget = used - wired - compressed
        let cached = available / 2
        let pressure = validation.memoryPressure ?? .elevated
        let sourceProcessBytes = base.topProcesses.reduce(Int64(0)) { $0 + $1.residentBytes }
        let processes = base.topProcesses.map { process in
            let bytes = Int64(Double(process.residentBytes) / Double(sourceProcessBytes) * Double(appBudget))
            return MemoryProcess(
                id: process.id, name: process.name, path: process.path,
                iconPath: process.iconPath, bundlePath: process.bundlePath,
                residentBytes: bytes, percent: Double(bytes) / Double(physical) * 100,
                canQuit: process.canQuit, isActive: process.isActive,
                bundleIdentifier: process.bundleIdentifier, launchDate: process.launchDate,
                userIdentifier: process.userIdentifier, capturedAt: referenceDate,
                dataSource: process.dataSource, availability: process.availability
            )
        }
        return MemorySnapshot(
            generatedAt: referenceDate, physicalBytes: physical,
            freeBytes: available - cached, inactiveBytes: 0, speculativeBytes: 0,
            fileBackedBytes: cached, purgeableBytes: 0, wiredBytes: wired,
            compressedBytes: compressed, swapUsedBytes: 0,
            // A selected fixture grade does not invent a numeric pressure/headroom reading.
            pressureFreePercentage: nil, pressureSummary: "FIXTURE · \(pressure.title)",
            topProcesses: processes,
            measurements: MemoryMeasurements(
                pressure: .available(pressure), physicalBytes: .available(UInt64(physical)),
                availableBytes: .available(UInt64(available)), appBytes: .available(UInt64(appBudget)),
                wiredBytes: .available(UInt64(wired)), compressedBytes: .available(UInt64(compressed)),
                cachedBytes: .available(UInt64(cached)), swapUsedBytes: .available(0),
                swapInRate: .available(0), swapOutRate: .available(0)
            )
        )
    }

    private static let defaultMemorySnapshot = MemorySnapshot(
        generatedAt: referenceDate,
        physicalBytes: 48 * 1_024 * 1_024 * 1_024,
        freeBytes: 4 * 1_024 * 1_024 * 1_024,
        inactiveBytes: 2 * 1_024 * 1_024 * 1_024,
        speculativeBytes: 1 * 1_024 * 1_024 * 1_024,
        fileBackedBytes: 5 * 1_024 * 1_024 * 1_024,
        purgeableBytes: 4 * 1_024 * 1_024 * 1_024,
        wiredBytes: 10 * 1_024 * 1_024 * 1_024,
        compressedBytes: 8 * 1_024 * 1_024 * 1_024,
        swapUsedBytes: Int64(3.6 * 1_024 * 1_024 * 1_024),
        pressureFreePercentage: 51,
        pressureSummary: "Elevated",
        topProcesses: [
            MemoryProcess(
                id: 201,
                name: "ChatGPT",
                path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                iconPath: "",
                bundlePath: "/Applications/ChatGPT.app",
                residentBytes: Int64(14.6 * 1_024 * 1_024 * 1_024),
                percent: 30.4,
                canQuit: true,
                bundleIdentifier: "com.openai.chat",
                capturedAt: referenceDate
            ),
            MemoryProcess(
                id: 202,
                name: "Google Chrome",
                path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                iconPath: "",
                bundlePath: "/Applications/Google Chrome.app",
                residentBytes: Int64(3.7 * 1_024 * 1_024 * 1_024),
                percent: 7.7,
                canQuit: true,
                bundleIdentifier: "com.google.Chrome",
                capturedAt: referenceDate
            ),
            MemoryProcess(
                id: 203,
                name: "node",
                path: "/opt/homebrew/bin/node",
                iconPath: "",
                bundlePath: nil,
                residentBytes: Int64(2.9 * 1_024 * 1_024 * 1_024),
                percent: 6.0,
                canQuit: false,
                bundleIdentifier: nil,
                capturedAt: referenceDate
            ),
            MemoryProcess(
                id: 204,
                name: "WorkBuddy AI",
                path: "/Applications/WorkBuddy AI.app/Contents/MacOS/WorkBuddy AI",
                iconPath: "",
                bundlePath: "/Applications/WorkBuddy AI.app",
                residentBytes: Int64(2.3 * 1_024 * 1_024 * 1_024),
                percent: 4.8,
                canQuit: true,
                bundleIdentifier: "ai.workbuddy.mac",
                capturedAt: referenceDate
            ),
            MemoryProcess(
                id: 205,
                name: "moomoo",
                path: "/Applications/moomoo.app/Contents/MacOS/moomoo",
                iconPath: "",
                bundlePath: "/Applications/moomoo.app",
                residentBytes: Int64(570.9 * 1_024 * 1_024),
                percent: 1.2,
                canQuit: true,
                bundleIdentifier: "com.moomoo.mac",
                capturedAt: referenceDate
            ),
        ],
        swapTotalBytes: 4 * 1_024 * 1_024 * 1_024,
        swappedInBytes: Int64(5.7 * 1_024 * 1_024 * 1_024),
        swappedOutBytes: Int64(9.4 * 1_024 * 1_024 * 1_024),
        measurements: MemoryMeasurements(
            pressure: .available(.elevated),
            physicalBytes: .available(48 * 1_024 * 1_024 * 1_024),
            availableBytes: .available(9 * 1_024 * 1_024 * 1_024),
            appBytes: .available(21 * 1_024 * 1_024 * 1_024),
            wiredBytes: .available(10 * 1_024 * 1_024 * 1_024),
            compressedBytes: .available(8 * 1_024 * 1_024 * 1_024),
            cachedBytes: .available(5 * 1_024 * 1_024 * 1_024),
            swapUsedBytes: .available(UInt64(3.6 * 1_024 * 1_024 * 1_024)),
            swapInRate: .available(0),
            swapOutRate: .available(0)
        )
    )

    static let memoryAfterQuitSnapshot = MemorySnapshot(
        generatedAt: referenceDate.addingTimeInterval(2.4),
        physicalBytes: 48 * 1_024 * 1_024 * 1_024,
        freeBytes: 12 * 1_024 * 1_024 * 1_024,
        inactiveBytes: 2 * 1_024 * 1_024 * 1_024,
        speculativeBytes: 1 * 1_024 * 1_024 * 1_024,
        fileBackedBytes: 5 * 1_024 * 1_024 * 1_024,
        purgeableBytes: 4 * 1_024 * 1_024 * 1_024,
        wiredBytes: 10 * 1_024 * 1_024 * 1_024,
        compressedBytes: 6 * 1_024 * 1_024 * 1_024,
        swapUsedBytes: Int64(3.2 * 1_024 * 1_024 * 1_024),
        pressureFreePercentage: 80,
        pressureSummary: "Normal",
        topProcesses: memorySnapshot.topProcesses.filter { [203, 205].contains($0.id) },
        swapTotalBytes: 4 * 1_024 * 1_024 * 1_024,
        swappedInBytes: Int64(5.7 * 1_024 * 1_024 * 1_024),
        swappedOutBytes: Int64(9.4 * 1_024 * 1_024 * 1_024),
        measurements: MemoryMeasurements(
            pressure: .available(.normal),
            physicalBytes: .available(48 * 1_024 * 1_024 * 1_024),
            availableBytes: .available(17 * 1_024 * 1_024 * 1_024),
            appBytes: .available(15 * 1_024 * 1_024 * 1_024),
            wiredBytes: .available(10 * 1_024 * 1_024 * 1_024),
            compressedBytes: .available(6 * 1_024 * 1_024 * 1_024),
            cachedBytes: .available(5 * 1_024 * 1_024 * 1_024),
            swapUsedBytes: .available(UInt64(3.2 * 1_024 * 1_024 * 1_024)),
            swapInRate: .available(0),
            swapOutRate: .available(0)
        )
    )

    static var memoryQuitResult: MemoryOptimizationResult {
        let completedProcesses = memorySnapshot.topProcesses.filter {
            [201, 202, 204].contains($0.id)
        }
        let skippedProcess = memorySnapshot.topProcesses.first { $0.id == 205 }!
        let targetResults = completedProcesses.map {
            MemoryOptimizationTargetResult(
                target: MemoryOptimizationTarget(
                    identity: $0.identity,
                    name: $0.name,
                    estimatedBytes: UInt64(clamping: $0.residentBytes)
                ),
                outcome: .gracefulQuitSucceeded,
                detail: nil
            )
        } + [
            MemoryOptimizationTargetResult(
                target: MemoryOptimizationTarget(
                    identity: skippedProcess.identity,
                    name: skippedProcess.name,
                    estimatedBytes: UInt64(clamping: skippedProcess.residentBytes)
                ),
                outcome: .targetExitedBeforeRequest,
                detail: nil
            ),
        ]
        let execution = MemoryOptimizationExecutionResult(
            planID: UUID(uuidString: "6F79CA4A-75BD-4B36-A7D0-9E93F579984D")!,
            startedAt: referenceDate,
            completedAt: referenceDate.addingTimeInterval(2.4),
            completion: .completed,
            targetResults: targetResults,
            snapshotBefore: memorySnapshot,
            snapshotAfter: memoryAfterQuitSnapshot,
            estimatedApplicationReductionBytes: UInt64(clamping: Int64(20.6 * 1_024 * 1_024 * 1_024)),
            observedApplicationMemoryDeltaBytes: 18 * 1_024 * 1_024 * 1_024,
            observedAvailableMemoryDeltaBytes: 8 * 1_024 * 1_024 * 1_024,
            pressureBefore: .critical,
            pressureAfter: .normal,
            swapUsedBeforeBytes: UInt64(clamping: memorySnapshot.swapUsedBytes),
            swapUsedAfterBytes: UInt64(clamping: memoryAfterQuitSnapshot.swapUsedBytes),
            attributionNotice: L10n.text(
                "退出状态与可用内存已重新测量。",
                "Exit status and available memory were remeasured."
            )
        )
        return MemoryOptimizationResult(
            beforeSnapshot: memorySnapshot,
            snapshot: memoryAfterQuitSnapshot,
            status: .completed,
            detail: L10n.text(
                "3 个应用已正常退出，1 个在请求前已退出；实际内存状态已刷新。",
                "3 apps quit normally and 1 exited before the request; memory was remeasured."
            ),
            durationSeconds: 2.4,
            executionResult: execution
        )
    }

    /// D122: the awake share of the fixture's 8.5 days since the boot
    /// (`systemUptimeSeconds`), for the uptime page.
    static let systemAwakeSeconds: TimeInterval = 561_600

    static let storageSnapshot = StorageCapacitySnapshot(
        totalBytes: 1_000_000_000_000,
        availableBytes: 480_000_000_000,
        availableForImportantUsageBytes: 560_000_000_000
    )

    static let volumeName = "Macintosh HD"

    static let networkInterfaceSnapshot = NativeNetworkInterfaceSnapshot(
        generatedAt: referenceDate,
        interfaceName: "en0",
        wiFiInterfaceName: "en0",
        isWiFiPoweredOn: true,
        hardwareAddress: "02:00:00:00:00:01",
        ssid: "Studio Wi-Fi",
        bssid: "02:00:00:00:00:02",
        countryCode: "AU",
        wiFiPHYMode: "802.11ax",
        transmitRateMbps: 1_200,
        rssiDBm: -48,
        noiseDBm: -92,
        channelNumber: 149,
        channelBandGHz: 5,
        channelWidthMHz: 80,
        ipv4Addresses: ["192.0.2.35"],
        ipv6Addresses: ["2001:db8::35"],
        ipv4SubnetMask: "255.255.255.0",
        ipv4Router: "192.0.2.1",
        ipv6Router: "2001:db8::1",
        dnsServers: ["192.0.2.53", "2001:db8::53"],
        interfaceMTU: 1_500,
        linkSpeedMbps: 1_200,
        // D140: the addresses iStat lists, the IPv6 one secured.
        listedAddresses: ["192.0.2.35", "2001:db8::35"]
    )

    static let publicNetworkAddressSnapshot = PublicNetworkAddressSnapshot(
        generatedAt: referenceDate,
        ipv4Address: "203.0.113.35",
        ipv6Address: "2001:db8:1::35",
        ipv4CountryCode: "AU",
        ipv6CountryCode: "AU"
    )

    static func publicNetworkAddressSnapshot(for scenario: MenuBarSnapshotScenario?) -> PublicNetworkAddressSnapshot? {
        scenario == .networkSecondaryUnavailable ? nil : publicNetworkAddressSnapshot
    }

    static let nativeDiskIOCounters = NativeDiskIOCounters(
        date: referenceDate,
        readBytes: 9_500_000_000,
        writtenBytes: 4_300_000_000,
        readOperations: 8_400_000,
        writeOperations: 3_100_000,
        driverCount: 1
    )

    static let nativeDiskIOHistory = diskIOPoints()

    static var batterySnapshot: BatteryPowerSnapshot {
        batterySnapshot(for: batteryState)
    }

    static func batterySnapshot(for state: BatteryDemoState) -> BatteryPowerSnapshot {
        switch state {
        case .charging:
            BatteryPowerSnapshot(
                chargePercent: 76,
                isCharging: true,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: 78,
                isFullyCharged: false,
                isOptimizedChargingEngaged: false
            )
        case .battery:
            BatteryPowerSnapshot(
                chargePercent: 72,
                isCharging: false,
                powerSource: .batteryPower,
                timeToEmptyMinutes: 266,
                timeToFullChargeMinutes: nil,
                isFullyCharged: false,
                isOptimizedChargingEngaged: false
            )
        case .charged:
            BatteryPowerSnapshot(
                chargePercent: 100,
                isCharging: false,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil,
                isFullyCharged: true,
                isOptimizedChargingEngaged: false
            )
        case .connected:
            BatteryPowerSnapshot(
                chargePercent: 76,
                isCharging: false,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil,
                isFullyCharged: false,
                isOptimizedChargingEngaged: false
            )
        case .batteryToExternal:
            BatteryPowerSnapshot(
                chargePercent: 76,
                isCharging: true,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: 78,
                isFullyCharged: false,
                isOptimizedChargingEngaged: false
            )
        case .externalToBattery:
            BatteryPowerSnapshot(
                chargePercent: 72,
                isCharging: false,
                powerSource: .batteryPower,
                timeToEmptyMinutes: 266,
                timeToFullChargeMinutes: nil,
                isFullyCharged: false,
                isOptimizedChargingEngaged: false
            )
        case .missing:
            BatteryPowerSnapshot(
                chargePercent: nil,
                isCharging: nil,
                powerSource: .unknown,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil,
                isFullyCharged: nil,
                isOptimizedChargingEngaged: nil
            )
        }
    }

    static var batteryElectricalSnapshot: NativeBatteryElectricalSnapshot {
        let power: Double
        switch batteryState {
        case .charging: power = 28.0
        case .battery: power = -6.29
        case .batteryToExternal: power = 28.0
        case .externalToBattery: power = -6.29
        case .charged, .connected, .missing: power = 0
        }
        return NativeBatteryElectricalSnapshot(
            generatedAt: referenceDate,
            voltageVolts: 12.1,
            amperageAmps: power / 12.1,
            powerWatts: power,
            temperatureCelsius: 31.8,
            adapterPowerWatts: 96,
            adapterVoltageVolts: 20.3,
            adapterAmperageAmps: 4.7,
            adapterName: "96W USB-C",
            designCapacityMAh: 5_100,
            currentCapacityMAh: 3_876,
            maximumCapacityMAh: 4_760,
            cycleCount: 108,
            condition: .normal,
            systemLoadWatts: [.charging, .charged, .connected].contains(batteryState) ? 18.4 : nil,
            electricalSource: .smc,
            currentReading: .value(power / 12.1),
            voltageReading: .value(12.1),
            temperatureReading: .value(31.8),
            temperatureSource: "TB0T",
            cellVoltages: [.value(4.032), .value(4.035), .value(4.033)],
            usbPowerOut: .value([
                USBPowerOutPort(portIndex: 2, watts: 1.26),
                USBPowerOutPort(portIndex: 3, watts: 0.03),
            ]),
            powerBasis: .smcPowerKey
        )
    }

    static var powerHistory: [MenuBarPowerHistoryPoint] {
        powerHistory(for: batteryState)
    }

    static let healthSummary = MenuBarHealthSummary(
        generatedAt: referenceDate,
        diskSMARTStatus: .verified,
        diskRemainingLifePercent: 96,
        batteryCapacityPercent: 93,
        batteryCycleCount: 108,
        batteryCondition: .normal,
        batteryPowerMode: .automatic
    )

    private static func telemetryPoints(
        memorySnapshot: MemorySnapshot,
        validation: ValidationOptions?,
        hardwareState: HardwareControlDemoState
    ) -> [MenuBarTelemetryPoint] {
        let user: [Double] = [22, 18, 25, 29, 24, 31, 27, 20, 23, 28, 26, 19]
        let system: [Double] = [12, 10, 11, 13, 12, 15, 13, 11, 12, 14, 11, 10]
        let gpu: [Double] = [42, 38, 45, 48, 41, 52, 47, 39, 44, 50, 46, 40]
        let memoryOffsets: [Double] = [0, 0, 1, 1, 0, 2, 2, 1, 1, 0, 0, -1]
        let memoryPercent = memorySnapshot.measuredUsedRatio.map { $0 * 100 }
        let temperature: [Double] = [53, 51, 54, 56, 53, 58, 55, 52, 54, 57, 55, 51]
        let fan: [Double] = [1_620, 1_540, 1_680, 1_760, 1_640, 1_880, 1_720, 1_580, 1_660, 1_820, 1_700, 1_560]
        let currentFan = fanTelemetry(for: hardwareState)
        let showsCurveTarget = hardwareState == .curveActive
            || hardwareState == .curveDraftChanges
        let download: [Int64] = [3_800_000, 2_900_000, 4_400_000, 5_100_000, 3_600_000, 6_200_000, 4_800_000, 3_200_000, 4_000_000, 5_600_000, 4_600_000, 3_100_000]
        let upload: [Int64] = [420_000, 320_000, 510_000, 620_000, 390_000, 740_000, 560_000, 350_000, 460_000, 680_000, 530_000, 310_000]
        let cpuPattern = validation?.cpuPattern
        let hasMemoryOverride = validation?.memoryUsedPercent != nil || validation?.memoryPressure != nil
        let sampleCount = cpuPattern == nil ? 121 : 301

        return (0..<sampleCount).map { index in
            // Optional CPU cases cover five minutes at exact one-second timestamps.
            // Other channels retain the original fixture's thirty-second stages.
            let valueIndex = (cpuPattern == nil ? index : 110 + index / 30) % user.count
            let secondsBeforeCurrent = cpuPattern == nil ? 3_600 - index * 30 : 300 - index
            let totalValue: Double?
            if let cpuPattern {
                totalValue = cpuPattern.totalPercent(secondsBeforeCurrent: secondsBeforeCurrent)
            } else {
                totalValue = user[valueIndex] + system[valueIndex]
            }
            let userValue = cpuPattern == nil ? Optional(user[valueIndex]) : totalValue.map { $0 * 0.7 }
            let systemValue = cpuPattern == nil ? Optional(system[valueIndex]) : totalValue.map { $0 * 0.3 }
            // D122: each fan's own reading, as a live point carries the
            // snapshot's, so a selected fan's history draws (was nil: only the
            // average had a history).
            let stageFanReadings = currentFan.readings.map { reading in
                SystemFanReading(
                    index: reading.index,
                    identity: reading.identity,
                    actualRPM: min(reading.maximumRPM ?? Int.max, max(reading.minimumRPM ?? 0,
                        reading.actualRPM + Int(fan[valueIndex] - fan[0]))),
                    minimumRPM: reading.minimumRPM,
                    maximumRPM: reading.maximumRPM,
                    targetRPM: reading.targetRPM
                )
            }
            return MenuBarTelemetryPoint(
                date: referenceDate.addingTimeInterval(-Double(secondsBeforeCurrent)),
                cpuTotal: totalValue,
                cpuUser: userValue,
                cpuSystem: systemValue,
                gpu: gpu[valueIndex],
                memory: memoryPercent.map { $0 + (hasMemoryOverride ? 0 : memoryOffsets[valueIndex]) },
                memoryPressure: memorySnapshot.pressureEstimatePercent.map(Double.init),
                memoryPressureLevelCode: memorySnapshot.measurements.pressure.value?.systemCode,
                memoryAppOrOtherBytes: memorySnapshot.ringComposition?.appOrOtherBytes,
                memoryWiredBytes: memorySnapshot.ringComposition?.wiredBytes,
                memoryPhysicalBytes: memorySnapshot.ringComposition?.physicalBytes,
                compressedMemoryBytes: memorySnapshot.ringComposition?.compressedBytes,
                swapUsedBytes: memorySnapshot.measurements.swapUsedBytes.value,
                swapUsedPercent: MenuBarTelemetryPoint.swapUsedPercent(
                    used: memorySnapshot.measurements.swapUsedBytes.value, total: memorySnapshot.swapTotalBytes),
                chipTemperature: temperature[valueIndex],
                gpuTemperature: temperature[valueIndex] - 4,
                temperatureReadings: [
                    SystemTemperatureReading(zone: .chip, celsius: temperature[valueIndex]),
                    SystemTemperatureReading(zone: .soc, celsius: temperature[valueIndex] + 1),
                    SystemTemperatureReading(zone: .performanceCores, celsius: temperature[valueIndex] + 2),
                    SystemTemperatureReading(zone: .efficiencyCores, celsius: temperature[valueIndex] - 3),
                    SystemTemperatureReading(zone: .gpu, celsius: temperature[valueIndex] - 4),
                    SystemTemperatureReading(zone: .storage, celsius: 42 + Double(valueIndex % 3)),
                    SystemTemperatureReading(zone: .battery, celsius: 34 + Double(valueIndex % 2)),
                    // D57 zones, so their third-level histories draw.
                    SystemTemperatureReading(zone: .chargingCircuit, celsius: 56 + Double(valueIndex % 3) * 0.5),
                    SystemTemperatureReading(zone: .ambient, celsius: 59 + Double(valueIndex % 2)),
                    SystemTemperatureReading(zone: .palmRest, celsius: 32.5 + Double(valueIndex % 2) * 0.5),
                    SystemTemperatureReading(zone: .thunderboltLeft, celsius: 45.5 + Double(valueIndex % 2) * 0.5),
                    SystemTemperatureReading(zone: .thunderboltRight, celsius: 38),
                    SystemTemperatureReading(zone: .wifi, celsius: 64 + Double(valueIndex % 3) * 0.5),
                ],
                fanRPM: currentFan.actualRPM.map { rpm in
                    min(Double(currentFan.maxRPM ?? Int.max), max(Double(currentFan.minRPM ?? 0),
                        Double(rpm) + fan[valueIndex] - fan[0]))
                },
                fanTargetRPM: showsCurveTarget ? currentFan.targetRPM.map(Double.init) : nil,
                fanReadings: stageFanReadings.isEmpty ? nil : stageFanReadings,
                downBytesPerSecond: download[valueIndex],
                upBytesPerSecond: upload[valueIndex]
            )
        }
    }

    private static func diskIOPoints() -> [NativeDiskIOPoint] {
        let read: [Int64] = [4_200_000, 3_100_000, 5_400_000, 4_700_000, 3_800_000, 6_100_000]
        let write: [Int64] = [1_100_000, 900_000, 1_500_000, 1_200_000, 1_000_000, 1_700_000]
        return (0..<121).map { index in
            let valueIndex = index % read.count
            return NativeDiskIOPoint(
                date: referenceDate.addingTimeInterval(-3_600 + Double(index) * 30),
                readBytesPerSecond: read[valueIndex],
                writeBytesPerSecond: write[valueIndex],
                readOperationsPerSecond: Double(read[valueIndex]) / 4_096,
                writeOperationsPerSecond: Double(write[valueIndex]) / 4_096
            )
        }
    }

    static func powerHistory(for state: BatteryDemoState) -> [MenuBarPowerHistoryPoint] {
        return (0..<121).map { index in
            let charge: Double?
            let source: BatteryPowerSource
            let isCharging: Bool?
            let powerWatts: Double?

            switch state {
            case .charging:
                charge = stagedBatteryLevel(
                    index,
                    sampleCount: 121,
                    levels: [
                        60, 60, 61, 61, 62, 62, 63, 63, 64,
                        64, 65, 65, 66, 66, 67, 67, 68, 69,
                        69, 70, 71, 72, 72, 73, 74, 75, 76,
                    ]
                )
                source = .acPower
                isCharging = true
                powerWatts = 28
            case .battery:
                charge = stagedBatteryLevel(
                    index,
                    sampleCount: 121,
                    levels: [
                        90, 90, 89, 89, 88, 88, 87, 87, 86,
                        86, 85, 85, 84, 84, 83, 82, 82, 81,
                        80, 79, 78, 77, 76, 75, 74, 73, 72,
                    ]
                )
                source = .batteryPower
                isCharging = false
                powerWatts = -6.29
            case .charged:
                charge = 100
                source = .acPower
                isCharging = false
                powerWatts = 0
            case .connected:
                charge = 76
                source = .acPower
                isCharging = false
                powerWatts = 0
            case .batteryToExternal:
                let isExternal = index >= 61
                charge = isExternal
                    ? stagedBatteryLevel(
                        index - 61,
                        sampleCount: 60,
                        levels: [70, 70, 71, 71, 72, 72, 73, 73, 74, 74, 75, 75, 76]
                    )
                    : stagedBatteryLevel(
                        index,
                        sampleCount: 61,
                        levels: [72, 72, 72, 71, 71, 71, 70, 70]
                    )
                source = isExternal ? .acPower : .batteryPower
                isCharging = isExternal
                powerWatts = isExternal ? 28 : -6.29
            case .externalToBattery:
                let isBattery = index >= 61
                charge = isBattery
                    ? stagedBatteryLevel(
                        index - 61,
                        sampleCount: 60,
                        levels: [74, 74, 73, 73, 72, 72]
                    )
                    : stagedBatteryLevel(
                        index,
                        sampleCount: 61,
                        levels: [70, 70, 71, 71, 72, 72, 73, 73, 74]
                    )
                source = isBattery ? .batteryPower : .acPower
                isCharging = !isBattery
                powerWatts = isBattery ? -6.29 : 28
            case .missing:
                charge = nil
                source = .unknown
                isCharging = nil
                powerWatts = 0
            }

            return MenuBarPowerHistoryPoint(
                date: referenceDate.addingTimeInterval(-3_600 + Double(index) * 30),
                chargePercent: charge,
                batteryPowerWatts: powerWatts,
                isCharging: isCharging,
                powerSource: source
            )
        }
    }

    private static func stagedBatteryLevel(
        _ index: Int,
        sampleCount: Int,
        levels: [Double]
    ) -> Double {
        guard !levels.isEmpty else { return 0 }
        let safeSampleCount = max(1, sampleCount)
        let boundedIndex = min(max(0, index), safeSampleCount - 1)
        let levelIndex = min(
            levels.count - 1,
            boundedIndex * levels.count / safeSampleCount
        )
        return levels[levelIndex]
    }
}
#endif
