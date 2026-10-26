import AppKit
import FanControlShared
import SwiftUI

extension FanStatusPresentation {
    static func controlTitle(_ capability: FanControlCapability) -> String {
        capability == .controllable
            ? L10n.text("可提交控制", "Ready to Submit")
            : capability.title
    }

    static func confirmedModeTitle(_ mode: GeekFanControlMode?) -> String {
        if mode == .maximum { return GeekFanControlMode.maximum.title }
        return mode.map { FanControlMode.resolve(observedMode: $0).title }
            ?? "—"
    }
}

extension View {
    /// Measure the page's ideal height at its actual column width, independently
    /// of the panel's previous height. A window resize must not feed back into
    /// this measurement when the content changes (the manual section's
    /// sliders, the notes).
    func controlPaletteContentLayout(_ presentation: ControlPalettePresentationState) -> some View {
        MiniWindowMeasuredPage(
            initialSize: ControlPaletteMetrics.size(kind: presentation.kind),
            reportSize: presentation.reportNaturalContentSize
        ) {
            self
        }
    }
}

struct ControlPaletteRootView: View {
    @ObservedObject private var presentation: ControlPalettePresentationState
    @ObservedObject private var fanControl: FanControlCoordinator
    @ObservedObject private var computerHealthStore: ComputerHealthStore
    @ObservedObject private var monitorState: MenuBarMonitorState
    @ObservedObject private var auxiliaryState: MenuBarAuxiliaryMonitorState
    @State private var chargeLimitConsumerID = UUID()

    init(
        presentation: ControlPalettePresentationState,
        store: ScanStore,
        computerHealthStore: ComputerHealthStore,
        fanControl: FanControlCoordinator = .shared
    ) {
        _presentation = ObservedObject(wrappedValue: presentation)
        _fanControl = ObservedObject(wrappedValue: fanControl)
        _computerHealthStore = ObservedObject(wrappedValue: computerHealthStore)
        _monitorState = ObservedObject(wrappedValue: store.menuBarMonitorState)
        _auxiliaryState = ObservedObject(wrappedValue: store.menuBarAuxiliaryMonitorState)
        // 在异步采样与视图 task 之前登记只读夹具，避免首次采样连真实服务。
        store.menuBarAuxiliaryMonitorState.setChargeLimitDataOnlyFixture(fanControl.isDataOnlyFixture)
    }

    var body: some View {
        MetricPanelShell {
            VStack(alignment: .leading, spacing: 0) {
                switch presentation.kind {
                case .fan:
                    FanControlPaletteView(
                        presentation: presentation,
                        fanControl: fanControl,
                        telemetry: FanTelemetryState.resolve(
                            snapshot: monitorState.snapshot
                        ),
                        thermalState: monitorState.snapshot?.thermalState ?? .nominal
                    )
                case .power:
                    powerPalette
                case .networkConnection:
                    GeekNetworkTertiaryView(
                        snapshot: auxiliaryState.networkInterfaceSnapshot,
                        topology: auxiliaryState.networkTopologySnapshot,
                        refresh: auxiliaryState.refreshNetworkConnectionSnapshot,
                        contentPadding: 0
                    )
                case .none:
                    Color.clear.accessibilityHidden(true)
                }
            }
            .controlSize(.small)
            .padding(GeekPanelLayout.contentPadding)
        }
        // D135: the panel's iStat theme, resolved as on the panel itself.
        .modifier(PanelAppearanceEnvironment())
        .controlPaletteContentLayout(presentation)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            presentation.beginInteraction()
        })
        // Opening a palette reads the shared connection cache. Startup,
        // lifecycle and the backoff worker own automatic reconnection; the
        // explicit Reconnect action below resets the deadline once.
        .task(id: presentation.kind) {
            guard presentation.kind == .fan || presentation.kind == .power else { return }
            await fanControl.refreshConnection()
        }
    }

    /// D124: iStat's energy-mode menu (the battery and AC sections) with our
    /// charge-limit and Mac mini sections after it, cards 7 pt apart; the
    /// helper's state stays first because every control here needs it (was
    /// Mac mini mode first and 6 pt apart).
    private var powerPalette: some View {
        VStack(alignment: .leading, spacing: MiniWindowStyleTokens.cardSpacing) {
            if fanControl.helperState != .enabled {
                ControlPaletteHelperStatusView(
                    helperState: fanControl.helperState,
                    offersAction: fanControl.offersHelperConnectionAction,
                    isBusy: fanControl.isPreparingHelper || fanControl.isRefreshingConnection,
                    reconnectWaitSeconds: fanControl.helperReconnectWaitSeconds,
                    enable: { Task { await fanControl.registerHelper() } },
                    openSystemSettings: fanControl.openApprovalSettings,
                    retry: { Task { await fanControl.reconnectHelper() } }
                )
                .disabled(fanControl.isDataOnlyFixture)
            }

            GeekEnergyModeHoverDetail(
                batteryMode: computerHealthStore.batteryPowerModes.battery,
                batterySupportedModes: hasInternalBattery
                    ? computerHealthStore.batteryPowerModes.supportedBatteryModes
                    : [],
                adapterMode: computerHealthStore.batteryPowerModes.adapter,
                adapterSupportedModes: computerHealthStore.batteryPowerModes.supportedAdapterModes,
                powerSource: hasInternalBattery
                    ? (auxiliaryState.batterySnapshot?.powerSource ?? .unknown)
                    : (auxiliaryState.internalBatteryAvailability == .absent ? .acPower : .unknown),
                isCharging: auxiliaryState.batterySnapshot?.isCharging == true,
                showsChargeTargetSetting: hasInternalBattery,
                showsFullChargeAction: auxiliaryState.batterySnapshot?
                    .shouldOfferFullChargeAction == true,
                chargeLimitState: displayedChargeLimitState,
                batteryPowerWatts: auxiliaryState.batteryElectricalSnapshot?.powerWatts,
                adapterPowerWatts: auxiliaryState.batteryElectricalSnapshot?.adapterPowerWatts,
                adjustmentState: computerHealthStore.batteryPowerModeAdjustmentState,
                controlsEnabled: fanControl.helperState == .enabled && !fanControl.isDataOnlyFixture,
                chargeLimitControlsEnabled: allowsLiveChargeLimitControls,
                onChargeToFull: {
                    guard allowsLiveChargeLimitControls else { return .unsupported }
                    let result = await BatteryFullChargeService.requestToFull()
                    auxiliaryState.refreshBatteryChargeLimitState(reason: .userOperation)
                    return result
                },
                onSetChargeTarget: { target in
                    guard allowsLiveChargeLimitControls else { return .unsupported }
                    return await auxiliaryState.setBatteryChargeTarget(target)
                },
                onOpenBatterySettings: {
                    NSWorkspace.shared.open(BatterySettingsVerifier.settingsURL)
                },
                onChangeMode: { source, mode in
                    Task {
                        await computerHealthStore.changeBatteryPowerMode(
                            source: source,
                            mode: mode
                        )
                    }
                }
            )
            MacMiniModeControls(fanControl: fanControl, hasInternalBattery: hasInternalBattery)
        }
        .task {
            guard allowsLiveChargeLimitControls else { return }
            // 调板独立登记需求；父面板切离电源页后仍按可见调板采样，不改变全局暂停状态。
            auxiliaryState.updateConsumer(chargeLimitConsumerID, demand: MenuBarAuxiliaryMonitorDemand(
                needsProcessorTelemetry: false, needsDiskIOSampling: false,
                needsNetworkInterface: false, needsPublicNetworkAddress: false,
                needsNetworkProcesses: false, needsChargeLimit: true
            ))
            auxiliaryState.refreshBatteryChargeLimitState(reason: .panelOpened)
            await computerHealthStore.refreshBatteryPowerModes()
        }
        .onDisappear {
            auxiliaryState.unregisterConsumer(chargeLimitConsumerID)
        }
    }

    private var displayedChargeLimitState: BatteryChargeLimitState? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.chargeLimitState() }
#endif
        return auxiliaryState.batteryChargeLimitState
    }

    private var allowsLiveChargeLimitControls: Bool {
        BatteryChargeLimitAccess.allowsLiveAccess && !fanControl.isDataOnlyFixture
    }

    private var hasInternalBattery: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.hasInternalBattery
        }
#endif
        if auxiliaryState.internalBatteryAvailability == .absent { return false }
        if auxiliaryState.internalBatteryAvailability == .present { return true }
        if case .notPresent? = computerHealthStore.snapshot?.batteryEvidence { return false }
        return auxiliaryState.batterySnapshot != nil
            || auxiliaryState.batteryElectricalSnapshot?.hasBatteryData == true
            || computerHealthStore.snapshot?.battery != nil
    }

}

/// D152: iStat Menus 7.30's fan submenu (`-[SensorsMenu loadItems]` and the
/// submenu's open handler): a text section per mode with iStat's toggle on
/// its major label, in iStat's order — Automatic, Custom Fan Curve, Manual —
/// and our Maximum after them. The toggles are one choice
/// (`setDisableOffSelection:`): turning one on switches the mode at once, the
/// one that is on does nothing. The manual section holds the Sync tick row
/// (two fans or more) and the sliders, which store their values in any mode
/// and write them in manual mode. Our notes follow the sections: the
/// helper's setup, the preview, why a mode is unavailable and the
/// coordinator's last message. Was D64's draft of single-choice cards with
/// Apply and Cancel, a title, a status capsule and the details.
struct FanControlPaletteView: View {
    @ObservedObject var presentation: ControlPalettePresentationState
    @ObservedObject var fanControl: FanControlCoordinator
    @ObservedObject private var curveStore: FanCurveStore
    let telemetry: FanTelemetryState
    let thermalState: SystemThermalState

    init(
        presentation: ControlPalettePresentationState,
        fanControl: FanControlCoordinator,
        telemetry: FanTelemetryState,
        thermalState: SystemThermalState
    ) {
        self.presentation = presentation
        self.fanControl = fanControl
        self.curveStore = fanControl.curveStore
        self.telemetry = telemetry
        self.thermalState = thermalState
    }

    /// The {spacer} rows of iStat's manual section.
    static let syncSpacerHeight: CGFloat = 2
    static let sliderSpacerHeight: CGFloat = 16

    var body: some View {
        if telemetry.isFanless {
            Text(L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling"))
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: MiniWindowStyleTokens.cardSpacing) {
                ForEach(sections) { choice in
                    section(choice)
                }
                notes
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("风扇控制浮层", "Fan Control Palette"))
        }
    }

    private var sections: [FanControlModeChoice] {
        let modes = FanControlPaletteAvailability.visibleModes(telemetry: telemetry)
        return FanControlModeChoice.allCases.filter { modes.contains($0.mode) }
    }

    private func section(_ choice: FanControlModeChoice) -> some View {
        GeekIStatTextSectionCard {
            GeekIStatMajorLabelRow(title: choice.title, hasRowsBelow: choice == .manual) {
                Toggle(isOn: Binding(
                    get: { displayedMode == choice.mode },
                    set: { isOn in if isOn { choose(choice.mode) } }
                )) {
                    EmptyView()
                }
                .toggleStyle(GeekIStatSwitchToggleStyle())
                .disabled(disabledReason(choice.mode) != nil)
                .accessibilityIdentifier("fan-mode-" + choice.mode.rawValue)
                .accessibilityLabel(choice.title)
                .accessibilityHint(disabledReason(choice.mode) ?? choice.subtitle)
                .help(disabledReason(choice.mode) ?? choice.subtitle)
#if DEBUG
                .layoutProbe("fan.mode.switch." + choice.mode.rawValue)
#endif
            }
            if choice == .manual {
                manualRows
            }
        }
#if DEBUG
        .layoutProbe("fan.section." + choice.mode.rawValue)
#endif
    }

    @ViewBuilder private var manualRows: some View {
        if FanManualSliderList.isAvailable(for: telemetry) {
            if telemetry.readings.count >= 2 {
                Color.clear.frame(height: Self.syncSpacerHeight)
                GeekIStatTickRow(
                    title: L10n.text("同步", "Sync"),
                    isSelected: fanControl.synchronizesManualFans
                ) {
                    presentation.beginInteraction()
                    fanControl.setManualFansSynchronized(!fanControl.synchronizesManualFans)
                }
                .disabled(fanControl.isDataOnlyFixture)
                .accessibilityIdentifier("fan-manual-sync")
#if DEBUG
                .layoutProbe("fan.manual.sync")
#endif
            }
            Color.clear.frame(height: Self.sliderSpacerHeight)
            FanManualSliderList(fanControl: fanControl, readings: telemetry.readings)
                .disabled(fanControl.isDataOnlyFixture)
        } else {
            Text(L10n.text("转速调节暂不可用", "Speed adjustment unavailable"))
                .geekIStatSectionNote()
        }
    }

    @ViewBuilder private var notes: some View {
        if fanControl.helperState != .enabled {
            ControlPaletteHelperStatusView(
                helperState: fanControl.helperState,
                isFanControl: true,
                offersAction: fanControl.offersHelperConnectionAction,
                isBusy: fanControl.isPreparingHelper || fanControl.isRefreshingConnection,
                reconnectWaitSeconds: fanControl.helperReconnectWaitSeconds,
                enable: { Task { await fanControl.registerHelper() } },
                openSystemSettings: fanControl.openApprovalSettings,
                retry: { Task { await fanControl.reconnectHelper() } }
            )
            .disabled(fanControl.isDataOnlyFixture)
        }
        let messages = noteMessages
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(messages, id: \.self) { message in
                    Text(message).geekIStatSectionNote()
                }
            }
        }
    }

    /// The preview, then why the other modes are unavailable (each reason
    /// once), then the coordinator's last message. Internal so the
    /// headless tests read it without a window.
    var noteMessages: [String] {
        var messages: [String] = []
        if fanControl.isDataOnlyFixture {
            messages.append(Self.previewNote)
        } else if fanControl.helperState == .enabled {
            for choice in sections where choice.mode != .systemAutomatic {
                if let reason = disabledReason(choice.mode), !messages.contains(reason) {
                    messages.append(reason)
                }
            }
        }
        if let message = fanControl.lastMessage, !message.isEmpty, !messages.contains(message) {
            messages.append(message)
        }
        return messages
    }

    /// Computed, so it follows a language change as the other copy does.
    static var previewNote: String { L10n.text("模拟预览 · 不会更改风扇", "Preview · Fan Controls Disabled") }

    /// The switch that is on: the requested mode while it is being set up,
    /// otherwise the coordinator's mode (a fixed fan set from Settings shows
    /// as manual).
    private var displayedMode: GeekFanControlMode {
        Self.displayedMode(requested: fanControl.requestedMode, selected: fanControl.selectedMode)
    }

    static func displayedMode(requested: GeekFanControlMode?, selected: GeekFanControlMode) -> GeekFanControlMode {
        let mode = requested ?? selected
        return mode == .fanSet ? .manual : mode
    }

    private func disabledReason(_ mode: GeekFanControlMode) -> String? {
        Self.disabledReason(
            mode: mode, telemetry: telemetry, helperState: fanControl.helperState,
            thermalState: thermalState, isDataOnlyFixture: fanControl.isDataOnlyFixture,
            curveIsAvailable: fanControl.previewTemperature(for: curveStore.draftProfile.sensor) != nil
                && curveStore.validationError == nil
        )
    }

    /// Why a toggle is unavailable: the preview, the helper's setup and the
    /// fans (`FanControlPaletteAvailability`; a fan listed twice counts as
    /// an unverified range, as the planner refuses it), thermal protection
    /// for the modes that set speeds, a curve without a valid profile or a
    /// temperature. iStat's toggles have none of these; they are our write
    /// preconditions.
    static func disabledReason(
        mode: GeekFanControlMode, telemetry: FanTelemetryState, helperState: HelperState,
        thermalState: SystemThermalState, isDataOnlyFixture: Bool, curveIsAvailable: Bool
    ) -> String? {
        if isDataOnlyFixture { return previewNote }
        if let reason = FanControlPaletteAvailability.disabledReason(
            mode: mode, telemetry: telemetry, helperState: helperState
        ) {
            return reason
        }
        if mode != .systemAutomatic && !FanManualSliderList.isAvailable(for: telemetry) {
            return L10n.text("风扇量程不可用 · 仅监测", "Fan Range Unavailable · Monitoring Only")
        }
        if mode != .systemAutomatic && (thermalState == .serious || thermalState == .critical) {
            return L10n.text("热保护中，只能使用自动控制", "Thermal protection: automatic control only")
        }
        if mode == .customCurve && !curveIsAvailable {
            return L10n.text("曲线或温度来源不可用", "Curve or temperature source unavailable")
        }
        return nil
    }

    /// iStat's handlers return when the mode is already on; the curve's
    /// toggle applies the curve as Settings or the fan-curve page left it.
    private func choose(_ mode: GeekFanControlMode) {
        guard mode != displayedMode, disabledReason(mode) == nil else { return }
        presentation.beginInteraction()
        Task { @MainActor in
            if mode == .customCurve {
                await fanControl.applyFanCurveDraft()
            } else {
                await fanControl.selectMode(mode)
            }
        }
    }
}

/// D152: the fan submenu's sections in iStat's order with our Maximum last.
/// The titles are iStat's (`Sensors.Automatic`, `Sensors.Custom Fan Curve`,
/// `Sensors.Manual`; iStat's Chinese '扇曲线' is not copied, as D135) and the
/// major label draws them in upper case (was 自动控制 and 手动控制 on cards
/// with icons; fixed fan sets remain a Settings detail, D73 fix1).
enum FanControlModeChoice: CaseIterable, Identifiable {
    case automatic
    case curve
    case manual
    case maximum

    init?(mode: GeekFanControlMode) {
        switch mode {
        case .systemAutomatic: self = .automatic
        case .customCurve: self = .curve
        case .manual: self = .manual
        case .maximum: self = .maximum
        case .fanSet: return nil
        }
    }

    var id: Self { self }

    var mode: GeekFanControlMode {
        switch self {
        case .automatic: .systemAutomatic
        case .curve: .customCurve
        case .manual: .manual
        case .maximum: .maximum
        }
    }

    var title: String {
        switch self {
        case .automatic: L10n.text("自动", "Automatic")
        case .curve: L10n.text("自定义风扇曲线", "Custom Fan Curve")
        case .manual: L10n.text("手动", "Manual")
        case .maximum: GeekFanControlMode.maximum.title
        }
    }

    // D64: used only as the spoken hint, never as visible option copy.
    var subtitle: String {
        switch self {
        case .automatic: L10n.text("交给 macOS 动态调节", "macOS adjusts the fans")
        case .curve: L10n.text("按温度曲线调节转速", "Follows a temperature curve")
        case .manual: L10n.text("直接设置目标转速", "Set a target speed directly")
        case .maximum: L10n.text("所有风扇使用硬件最大转速", "Use the hardware maximum RPM for every fan")
        }
    }
}

struct ControlPaletteHelperStatusView: View {
    let helperState: HelperState
    var isFanControl = false
    let offersAction: Bool
    let isBusy: Bool
    var reconnectWaitSeconds = 0
    let enable: () -> Void
    let openSystemSettings: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                Text(isBusy ? L10n.text("正在检测…", "Checking…") : (isFanControl ? FanControlSetupPresentation.reason(helperState) : helperState.title))
                    .font(AdvancedPanelTypography.captionStrong)
                    .lineLimit(1)
            }

            if offersAction {
                Button(buttonTitle, action: buttonAction)
                    .controlSize(.small)
                    .disabled(isBusy || (isReconnectAction && reconnectWaitSeconds > 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var buttonTitle: String {
        if isReconnectAction, reconnectWaitSeconds > 0 {
            return L10n.text("等待 \(reconnectWaitSeconds) 秒", "Wait \(reconnectWaitSeconds)s")
        }
        if isFanControl { return FanControlSetupPresentation.actionTitle(helperState) }
        return switch helperState {
        // `unavailable` also covers launchd's pre-submission state, which is
        // still registerable. Offering only "Check Again" there left the user
        // with no way to enable advanced control at all.
        case .notRegistered, .unavailable:
            L10n.text("启用高级控制", "Enable Advanced Control")
        case .requiresApproval:
            L10n.text("打开系统设置", "Open System Settings")
        case .enabled, .connectionInterrupted, .signatureRejected:
            L10n.text("重新检测", "Check Again")
        }
    }

    private var isReconnectAction: Bool {
        [.enabled, .connectionInterrupted, .signatureRejected].contains(helperState)
    }

    private var buttonAction: () -> Void {
        switch helperState {
        case .notRegistered, .unavailable: enable
        case .requiresApproval: openSystemSettings
        case .enabled, .connectionInterrupted, .signatureRejected: retry
        }
    }
}
