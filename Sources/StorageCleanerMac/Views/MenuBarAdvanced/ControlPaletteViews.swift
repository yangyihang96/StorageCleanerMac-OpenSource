import AppKit
import FanControlShared
import SwiftUI

extension FanStatusPresentation {
    static func connectionTitle(_ state: HelperState) -> String {
        switch state {
        case .enabled: L10n.text("已连接", "Connected")
        case .notRegistered, .requiresApproval: L10n.text("未连接", "Not Connected")
        case .connectionInterrupted: L10n.text("连接中断", "Connection Interrupted")
        case .signatureRejected: L10n.text("验证失败", "Verification Failed")
        case .unavailable: L10n.text("连接不可用", "Connection Unavailable")
        }
    }

    static func approvalTitle(_ state: HelperState) -> String {
        switch state {
        case .enabled, .connectionInterrupted: L10n.text("已批准", "Approved")
        case .requiresApproval: L10n.text("等待批准", "Awaiting Approval")
        case .notRegistered: L10n.text("尚未申请", "Not Requested")
        case .unavailable, .signatureRejected: L10n.text("未确认", "Unconfirmed")
        }
    }

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
    /// this measurement when switching compact/full controls or the editor.
    func controlPaletteContentLayout(_ presentation: ControlPalettePresentationState) -> some View {
        MiniWindowMeasuredPage(
            initialSize: ControlPaletteMetrics.size(kind: presentation.kind, fanPage: presentation.fanPage),
            reportSize: presentation.reportNaturalContentSize
        ) {
            self
        }
    }
}

struct ControlPaletteRootView: View {
    @Environment(\.colorScheme) private var inheritedColorScheme
    @ObservedObject private var presentation: ControlPalettePresentationState
    @ObservedObject private var fanControl: FanControlCoordinator
    @ObservedObject private var computerHealthStore: ComputerHealthStore
    @ObservedObject private var monitorState: MenuBarMonitorState
    @ObservedObject private var auxiliaryState: MenuBarAuxiliaryMonitorState
    @State private var chargeLimitConsumerID = UUID()

    @AppStorage(L10n.appearanceDefaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(PanelAppearancePreferences.miniWindowAppearanceKey) private var miniWindowAppearanceRawValue = ""
    @AppStorage(PanelAppearancePreferences.colorThemeKey) private var panelColorTheme = PanelColorTheme.graphite.rawValue
    @AppStorage(PanelAppearancePreferences.backgroundColorKey) private var panelBackgroundColor = ""
    @AppStorage(PanelAppearancePreferences.chartColorKey) private var panelChartColor = ""
    @AppStorage(PanelPalettePreferences.surfaceThemeKey) private var panelSurfacePresetRaw = ""

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
                    if presentation.fanPage == .curveEditor {
                        fanCurveEditor
                    } else {
                        FanControlPaletteView(
                            presentation: presentation,
                            fanControl: fanControl,
                            telemetry: FanTelemetryState.resolve(
                                snapshot: monitorState.snapshot
                            ),
                            thermalState: monitorState.snapshot?.thermalState ?? .nominal
                        )
                    }
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
        .foregroundStyle(panelChrome?.text ?? MiniWindowColorPalette.primaryText,
                         panelChrome?.secondaryText ?? MiniWindowColorPalette.secondaryText,
                         panelChrome?.tertiaryText ?? MiniWindowColorPalette.tertiaryText)
        .tint(panelChrome?.accent ?? MiniWindowColorPalette.blue)
        .environment(\.panelBackgroundTint, panelChrome == nil ? paletteBackgroundTint : nil)
        .environment(\.panelChartAccentColor, paletteChartTint)
        .modifier(PanelMetricColorEnvironment())
        .environment(\.miniWindowVisualMode, visualMode)
        .environment(\.panelChromePalette, panelChrome)
        .environment(\.colorScheme, panelChrome?.controlScheme ?? .dark)
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

    private var fanCurveEditor: some View {
        VStack(alignment: .leading, spacing: MiniWindowStyleTokens.cardSpacing) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                Button {
                    presentation.showFanControls()
                } label: {
                    Label(L10n.text("风扇控制", "Fan Control"), systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .font(AdvancedPanelTypography.captionStrong)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("返回风扇控制", "Back to Fan Control"))

                Spacer(minLength: 0)

                Text(L10n.text("编辑曲线", "Edit Curve"))
                    .font(AdvancedPanelTypography.captionStrong)
                    .foregroundStyle(AppDesignTokens.Palette.tertiary)
            }

            FanCurveEditor(
                fanControl: fanControl,
                fanReadings: fanControl.latestFanReadings,
                compact: true
            )
        }
    }

    private var powerPalette: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacMiniModeControls(fanControl: fanControl, hasInternalBattery: hasInternalBattery)
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

    private var paletteBackgroundTint: Color? {
        PanelColorTheme.backgroundTint(
            storedTheme: panelColorTheme,
            backgroundHex: panelBackgroundColor,
            chartHex: panelChartColor
        )
    }

    private var paletteChartTint: Color? {
        PanelColorTheme.chartColor(
            storedTheme: panelColorTheme,
            backgroundHex: panelBackgroundColor,
            customHex: panelChartColor
        )
    }

    private var visualMode: MiniWindowVisualMode {
        MiniWindowVisualMode.resolve(
            miniWindowRawValue: miniWindowAppearanceRawValue,
            appRawValue: appearanceRawValue,
            systemColorScheme: inheritedColorScheme
        )
    }

    private var panelChrome: PanelChromePalette? {
        PanelSurfacePreset(rawValue: panelSurfacePresetRaw)?.palette(for: visualMode)
    }

}

struct FanControlPaletteView: View {
    @ObservedObject var presentation: ControlPalettePresentationState
    @ObservedObject var fanControl: FanControlCoordinator
    @ObservedObject private var curveStore: FanCurveStore
    let telemetry: FanTelemetryState
    let thermalState: SystemThermalState
    var showsExpandedControls = false
    @State private var draft: FanControlDraft
    @State private var submittedConfiguration: FanControlDraft.Configuration?
    @State private var isSubmitting = false
    @State private var submissionFailed = false
    @State private var localMessage: String?
    @State private var showsCapabilityDetails = false
    private var isExpanded: Bool { presentation.fanControlsExpanded ?? showsExpandedControls }

    init(
        presentation: ControlPalettePresentationState,
        fanControl: FanControlCoordinator,
        telemetry: FanTelemetryState,
        thermalState: SystemThermalState,
        showsExpandedControls: Bool = false
    ) {
        self.presentation = presentation
        self.fanControl = fanControl
        self.curveStore = fanControl.curveStore
        self.telemetry = telemetry
        self.thermalState = thermalState
        self.showsExpandedControls = showsExpandedControls
        _draft = State(initialValue: FanControlDraft(
            telemetry: telemetry, observedMode: fanControl.observedMode,
            synchronizesFans: fanControl.synchronizesManualFans,
            confirmedFractions: fanControl.confirmedManualFractionByFan
        ))
    }

    var body: some View {
        if telemetry.isFanless {
            Text(L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling"))
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
        } else {
            paletteContent
        }
    }

    private var paletteContent: some View {
        VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                Text(L10n.text("风扇控制", "Fan Control"))
                Spacer(minLength: 4)
                MiniWindowStatusCapsule(title: statusTitle, tint: statusTint, isBusy: isBusy)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(statusTitle)
                    .accessibilityIdentifier("fan-control-status")
                Button { showsCapabilityDetails.toggle() } label: {
                    AppSymbolGlyph(systemImage: showsCapabilityDetails ? "info.circle.fill" : "info.circle",
                                   size: MiniWindowStyleTokens.moduleIconGlyphSize)
                        .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .accessibilityLabel(L10n.text("风扇详细信息", "Fan Details"))
                .accessibilityIdentifier("fan-capability-details")
            }
            .font(AdvancedPanelTypography.captionStrong)

            if isExpanded || showsCapabilityDetails {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                Text(currentFanTitle)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSnapshotStale && !fanControl.isDataOnlyFixture {
                    AppSymbolGlyph(systemImage: "clock.badge.exclamationmark",
                                   size: MiniWindowStyleTokens.statusGlyphSize)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                        .frame(width: MiniWindowStyleTokens.statusIconSlotSize,
                               height: MiniWindowStyleTokens.statusIconSlotSize)
                        .accessibilityLabel(L10n.text("快照已过期", "Stale Snapshot"))
                }
                Text(currentFanRPM)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(AdvancedPanelTypography.caption)
            .help(sampleTimestampTitle)

            }

            // fix1: the automatic and maximum choices share a row; curve and
            // manual retain the full width for their editor and slider controls.
            MiniWindowGroup {
                VStack(alignment: .leading, spacing: FanControlModeCard.spacing) {
                    HStack(alignment: .top, spacing: FanControlModeCard.spacing) {
                        fanModeSection(.systemAutomatic) { EmptyView() }
                        fanModeSection(.maximum) { EmptyView() }
                    }
                    fanModeSection(.customCurve) {
                        curveSummary
                    }
                    fanModeSection(.manual) {
                        manualControls
                    }
                }
            }

            // Keep the concrete block reason visible even in the compact
            // presentation. Opening a control palette never registers a helper
            // or changes the observed hardware mode.
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
            if fanControl.isDataOnlyFixture && displayedMode != .manual {
                Text(L10n.text("模拟预览 · 不会更改风扇", "Preview · Fan Controls Disabled"))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
            } else if !fanControl.isDataOnlyFixture, let reason = applyDisabledReason, fanControl.helperState == .enabled {
                Text(reason).font(AdvancedPanelTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = fanControl.lastMessage, !message.isEmpty {
                Text(message).font(AdvancedPanelTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if fanControl.observedMode != nil && fanControl.observedMode != .systemAutomatic
                && !telemetry.telemetryAvailable {
                // Recovery stays reachable even when RPM or range telemetry is
                // missing. This is the existing system-automatic intent.
                Button(L10n.text("恢复 macOS 自动控制", "Restore macOS Automatic Control")) {
                    presentation.beginInteraction()
                    Task { @MainActor in
                        await fanControl.selectMode(.systemAutomatic)
                    }
                }
                .disabled(isBusy || fanControl.helperState != .enabled || fanControl.isDataOnlyFixture)
                .accessibilityIdentifier("fan-restore-system-automatic")
                .help(L10n.text("请求交回系统控制；以回读状态为准。", "Requests system control; readback determines the result."))
            }
            if displayedMode != .manual && (hasPendingChanges || isBusy || submissionFailed) {
                HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                    Spacer(minLength: 0)
                    draftActions
                }
            }
            if submissionFailed {
                Text(L10n.text("未生效，请重试", "Not applied. Try again."))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .help(fanControl.lastMessage ?? "")
            }

            if showsCapabilityDetails || isExpanded {
                MiniWindowGroup {
                    paletteValueRow(L10n.text("采样时间", "Sampled"), sampleTimestampTitle)
                    paletteValueRow(L10n.text("控制能力", "Control Capability"), FanStatusPresentation.controlTitle(capability))
                    fanReadbackRows
                    Button(isExpanded ? L10n.text("收起读数", "Hide Readings") : L10n.text("查看全部读数", "All Readings")) {
                        presentation.setFanControlsExpanded(!isExpanded)
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .accessibilityIdentifier("fan-control-layout-toggle")
                    if isExpanded {
                        paletteValueRow(L10n.text("温度来源", "Temperature Source"), curveStore.draftProfile.sensor.displayTitle)
                    }
                    paletteValueRow(L10n.text("硬件量程", "Hardware Range"), hardwareRangeTitle)
                    paletteValueRow(L10n.text("Helper 连接", "Helper Connection"), FanStatusPresentation.connectionTitle(fanControl.helperState))
                    paletteValueRow(L10n.text("系统批准", "System Approval"), FanStatusPresentation.approvalTitle(fanControl.helperState))
                    Button(L10n.text("复制风扇诊断", "Copy Fan Diagnostics"), action: copyFanDiagnostics)
                        .accessibilityIdentifier("fan-copy-diagnostics")
                        .help(L10n.text("仅复制已有读数，不读取私人文件、不修改风扇。", "Copies cached readings only; no private-file access or fan writes."))
                }
            }
        }
        .onChange(of: draft.configuration) { _, configuration in
            if draft.hasChanges { presentation.beginInteraction() }
            if draft.hasChanges && configuration != submittedConfiguration {
                localMessage = nil
                submittedConfiguration = nil
            }
        }
        .onChange(of: telemetry.readings) { _, _ in refreshDraftIfUnedited() }
        .onChange(of: fanControl.observedMode) { _, _ in
            confirmSubmittedDraft()
            refreshDraftIfUnedited()
        }
        .onChange(of: fanControl.confirmedManualFractionByFan) { _, _ in confirmSubmittedDraft() }
        .onChange(of: fanControl.isApplying) { _, applying in if !applying { confirmSubmittedDraft() } }
        .onChange(of: fanControl.isSwitchingMode) { _, switching in if !switching { confirmSubmittedDraft() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("风扇控制浮层", "Fan Control Palette"))
    }

    @ViewBuilder
    private func fanModeSection<Content: View>(
        _ mode: GeekFanControlMode, @ViewBuilder content: () -> Content
    ) -> some View {
        if FanControlPaletteAvailability.visibleModes(telemetry: telemetry).contains(mode),
           let choice = FanControlModeChoice(mode: mode) {
            VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
                FanControlModeCard(
                    choice: choice,
                    selected: displayedMode == mode,
                    isApplying: isRequesting(mode),
                    isDisabled: isBusy || modeDisabledReason(mode) != nil,
                    disabledReason: modeDisabledReason(mode),
                    action: { choose(mode) }
                )
                .accessibilityIdentifier("fan-draft-mode-" + mode.rawValue)
                .help(modeDisabledReason(mode) ?? choice.subtitle)

                if displayedMode == mode {
                    content()
                        .padding(.horizontal, FanControlModeCard.contentInset)
                }
            }
        }
    }

    @ViewBuilder private var manualControls: some View {
        if telemetry.hasVerifiedRanges {
            FanManualSliderList(draft: $draft, telemetry: telemetry, isDisabled: isBusy || modeDisabledReason(.manual) != nil || displayedMode != .manual, compact: true,
                compactFooter: { AnyView(manualFooter(fanID: $0)) })
        } else {
            Text(L10n.text("转速调节暂不可用", "Speed adjustment unavailable"))
                .font(AdvancedPanelTypography.caption).foregroundStyle(AppDesignTokens.Palette.secondaryText)
        }
    }

    /// Actual RPM and the local draft share one row with the explicit commit actions.
    private func manualFooter(fanID: Int?) -> some View {
        let actual = FanManualSliderList.actualRPM(fanID: fanID, telemetry: telemetry)
        let target = draft.targetRPM(fanID: fanID, telemetry: telemetry)
        let reading = L10n.text("实际 ", "Actual ") + (actual.map(SystemFanSpeedFormat.string) ?? "—")
            + " · " + L10n.text("草稿目标 ", "Draft Target ") + (target.map(SystemFanSpeedFormat.string) ?? "—")
        return HStack(spacing: MiniWindowStyleTokens.rowSpacing) {
            Text((actual.map(SystemFanSpeedFormat.number) ?? "—") + " → "
                + (target.map(SystemFanSpeedFormat.number) ?? "—") + " rpm")
                .font(AdvancedPanelTypography.caption).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
                .help(reading)
                .accessibilityLabel(reading)
            Spacer(minLength: 0)
            draftActions
        }
        .controlSize(.mini)
    }

    @ViewBuilder private var draftActions: some View {
        if displayedMode == .manual || hasPendingChanges || isBusy || submissionFailed {
            if hasPendingChanges || isBusy {
                MiniWindowStatusCapsule(
                    title: isBusy ? L10n.text("正在应用", "Applying") : L10n.text("待应用", "Pending"),
                    tint: isBusy ? Color.accentColor : AppDesignTokens.Palette.warning,
                    isBusy: isBusy
                )
            } else if fanControl.isDataOnlyFixture {
                Text(L10n.text("预览", "Preview"))
                    .font(AdvancedPanelTypography.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .help(L10n.text("模拟预览 · 不会更改风扇", "Preview · Fan Controls Disabled"))
                    .accessibilityLabel(L10n.text("模拟预览 · 不会更改风扇", "Preview · Fan Controls Disabled"))
            }
            Button(L10n.text("取消", "Cancel"), action: cancelDraft)
                .disabled(!hasPendingChanges || isBusy)
            Button(L10n.text("应用", "Apply"), action: applyDraft)
                .buttonStyle(.borderedProminent)
                .disabled(!hasPendingChanges || applyDisabledReason != nil || isBusy)
                .accessibilityHint(applyDisabledReason ?? L10n.text("提交后需要 Helper 回读确认", "Helper readback is required after submission"))
        }
    }

    private var curveSummary: some View {
        VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
            paletteValueRow(L10n.text("已应用曲线", "Applied Curve"), curveStore.appliedProfile?.name ?? L10n.text("尚未应用", "Not Active"))
            paletteValueRow(telemetry.fanCount > 1 ? L10n.text("平均目标", "Average Target") : L10n.text("目标转速", "Target Speed"), draftTargetRPM.map(SystemFanSpeedFormat.string) ?? "—")
            Button { presentation.showFanCurveEditor() } label: {
                Text(L10n.text("编辑曲线", "Edit Curve"))
                    .font(AdvancedPanelTypography.captionStrong)
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .disabled(isBusy)
            .accessibilityIdentifier(L10n.text("编辑曲线", "Edit Curve"))
        }
    }

    @ViewBuilder private var fanReadbackRows: some View {
        if telemetry.readings.isEmpty {
            Text(telemetry.isFanless ? L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling")
                : telemetry.isSampling ? L10n.text("正在检测风扇…", "Checking Fans…")
                : L10n.text("风扇读数不可用", "Fan Readings Unavailable"))
                .font(AdvancedPanelTypography.caption).foregroundStyle(AppDesignTokens.Palette.secondaryText)
        } else if telemetry.readings.count > 4 {
            Menu(L10n.text("查看全部 \(telemetry.readings.count) 个风扇", "View All \(telemetry.readings.count) Fans")) {
                ForEach(telemetry.readings) { reading in Text(reading.displayName + " · " + reading.displayRPM) }
            }
            .font(AdvancedPanelTypography.caption)
        } else {
            ForEach(telemetry.readings) { reading in paletteValueRow(reading.displayName, reading.displayRPM) }
        }
    }

    private func copyFanDiagnostics() {
        func number(_ value: Int?) -> Any {
            if let value { return value }
            return NSNull()
        }
        let readings = telemetry.readings.map { reading -> [String: Any] in
            ["index": reading.index, "actualRPM": reading.actualRPM,
             "minimumRPM": number(reading.minimumRPM), "maximumRPM": number(reading.maximumRPM),
             "targetRPM": number(reading.targetRPM)]
        }
        let payload: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "source": "cached-view-model-readings-not-a-new-hardware-probe",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "helperState": String(describing: fanControl.helperState),
            "observedMode": FanStatusPresentation.confirmedModeTitle(fanControl.observedMode),
            "telemetryAvailable": telemetry.telemetryAvailable,
            "verifiedRanges": telemetry.hasVerifiedRanges,
            "fanCount": telemetry.fanCount, "readings": readings
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func paletteValueRow(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                Text(title).foregroundStyle(AppDesignTokens.Palette.secondaryText).fixedSize()
                Spacer(minLength: 6)
                Text(value).monospacedDigit().fixedSize()
            }
            VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
                Text(title).foregroundStyle(AppDesignTokens.Palette.secondaryText)
                Text(value).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(AdvancedPanelTypography.caption)
        .frame(minHeight: MiniWindowStyleTokens.dataRowHeight)
        .help(title + " · " + value)
    }

    private var isCompactAutomatic: Bool {
        Self.usesCompactAutomaticLayout(
            isExpanded: isExpanded, observedMode: fanControl.observedMode,
            draft: draft, hasPendingChanges: hasPendingChanges, isBusy: isBusy,
            hasSubmittedDraft: submittedConfiguration != nil
        )
    }

    static func usesCompactAutomaticLayout(
        isExpanded: Bool,
        observedMode: GeekFanControlMode?,
        draft: FanControlDraft,
        hasPendingChanges: Bool,
        isBusy: Bool,
        hasSubmittedDraft: Bool
    ) -> Bool {
        !isExpanded && observedMode == .systemAutomatic && draft.mode == .systemAutomatic
            && !hasPendingChanges && !isBusy && !hasSubmittedDraft
    }

    private var displayedMode: GeekFanControlMode? { draft.mode }
    private var focusedFan: SystemFanReading? {
        telemetry.readings.first { $0.index == presentation.selectedFanIndex }
            ?? (telemetry.readings.count == 1 ? telemetry.readings.first : nil)
    }
    private var currentFanTitle: String {
        if let focusedFan { return focusedFan.displayName }
        if telemetry.fanCount > 1 {
            return L10n.text("\(telemetry.fanCount) 个风扇 · 平均转速", "\(telemetry.fanCount) Fans · Average Speed")
        }
        return L10n.text("当前转速", "Current Speed")
    }
    private var currentFanRPM: String {
        if let focusedFan { return focusedFan.displayRPM }
        if let actualRPM = telemetry.actualRPM { return SystemFanSpeedFormat.string(actualRPM) }
        return telemetry.isSampling ? L10n.text("读取中", "Reading") : "—"
    }
    private var sampleTimestampTitle: String {
        if fanControl.isDataOnlyFixture { return L10n.text("模拟快照", "Preview Snapshot") }
        guard let timestamp = telemetry.timestamp else { return L10n.text("快照时间未知", "Snapshot Time Unknown") }
        let timestampText = PanelTimestampFormat.detail(timestamp)
        if isSnapshotStale {
            return L10n.text("快照已过期 · \(timestampText)", "Stale Snapshot · \(timestampText)")
        }
        return L10n.text("快照 \(timestampText)", "Snapshot \(timestampText)")
    }
    private var isSnapshotStale: Bool {
        guard let timestamp = telemetry.timestamp else { return false }
        return Date().timeIntervalSince(timestamp) > 10
    }
    private var isBusy: Bool { isSubmitting || fanControl.isSwitchingMode || fanControl.isApplying }
    private var hasPendingChanges: Bool {
        draft.hasChanges || (displayedMode == .customCurve && curveStore.hasUnappliedChanges)
    }
    private var capability: FanControlCapability {
        FanControlCapability.resolve(telemetry: telemetry, helperState: fanControl.helperState)
    }
    private var applyDisabledReason: String? {
        if fanControl.isDataOnlyFixture { return L10n.text("FIXTURE · 仅预览，禁止写入或申请 Helper", "FIXTURE · Preview only; writes and Helper registration blocked") }
        if telemetry.isSampling { return L10n.text("正在读取风扇，暂不能应用", "Reading fans; Apply unavailable") }
        if telemetry.isFanless { return L10n.text("无风扇设备 · 仅监测", "Fanless Device · Monitoring Only") }
        if !telemetry.telemetryAvailable { return L10n.text("风扇读数不可用 · 仅监测", "Fan Readings Unavailable · Monitoring Only") }
        if fanControl.helperState != .enabled {
            return L10n.text("仅监测 · ", "Monitoring Only · ") + FanStatusPresentation.connectionTitle(fanControl.helperState)
                + " / " + FanStatusPresentation.approvalTitle(fanControl.helperState)
        }
        if displayedMode != .systemAutomatic && !telemetry.hasVerifiedRanges {
            return L10n.text("量程不完整 · 仅监测", "Incomplete Range · Monitoring Only")
        }
        if displayedMode != .systemAutomatic && (thermalState == .serious || thermalState == .critical) {
            return L10n.text("热保护中，暂不能应用自定义目标", "Thermal protection prevents custom targets")
        }
        if displayedMode == .customCurve && (currentDraftTemperature == nil || curveStore.validationError != nil) {
            return L10n.text("曲线或温度来源不可用，暂不能应用", "Curve or temperature source unavailable; Apply blocked")
        }
        return nil
    }
    private var hardwareRangeTitle: String {
        telemetry.hasVerifiedRanges ? L10n.text("已读取完整量程", "Complete Range Read") : L10n.text("量程不完整", "Incomplete Range")
    }
    private var currentDraftTemperature: Double? {
        fanControl.previewTemperature(for: curveStore.draftProfile.sensor)
    }
    private var draftPreviewPercentage: Double? {
        guard let currentDraftTemperature else { return nil }
        return FanCurveInterpolator.percentage(at: currentDraftTemperature, points: curveStore.draftProfile.points)
    }
    private var draftTargetRPM: Int? {
        guard let percentage = draftPreviewPercentage else { return nil }
        return FanCurveEditor.targetRPM(percentage: percentage, fanReadings: telemetry.readings)
    }
    private var statusTitle: String {
        if isBusy { return L10n.text("正在应用…", "Applying…") }
        if fanControl.helperState != .enabled { return FanControlSetupPresentation.capsuleTitle(fanControl.helperState) }
        return FanStatusPresentation.confirmedModeTitle(fanControl.observedMode)
    }
    private var statusTint: Color {
        fanControl.helperState == .enabled ? AppDesignTokens.Palette.tertiary : AppDesignTokens.Palette.warning
    }
    private func isRequesting(_ mode: GeekFanControlMode) -> Bool { fanControl.requestedMode == mode && isBusy }

    private func modeDisabledReason(_ mode: GeekFanControlMode) -> String? {
        FanControlPaletteAvailability.disabledReason(mode: mode, telemetry: telemetry, helperState: fanControl.helperState)
    }

    private func choose(_ mode: GeekFanControlMode) {
        guard !isBusy, modeDisabledReason(mode) == nil else { return }
        presentation.beginInteraction()
        submissionFailed = false
        draft.selectMode(mode)
        submittedConfiguration = nil
        localMessage = nil
    }
    private func cancelDraft() {
        guard !isBusy else { return }
        draft.cancel()
        curveStore.discardDraft()
        submittedConfiguration = nil
        localMessage = nil
        submissionFailed = false
    }
    private func applyDraft() {
        guard hasPendingChanges, applyDisabledReason == nil, !isBusy else { return }
        let submitted = draft
        submittedConfiguration = submitted.configuration
        localMessage = nil
        isSubmitting = true
        Task { @MainActor in
            let accepted = await submitted.submit(to: fanControl, telemetry: telemetry, thermalState: thermalState)
            isSubmitting = false
            submissionFailed = !accepted
            if !accepted { submittedConfiguration = nil }
            confirmSubmittedDraft()
        }
    }
    private func confirmSubmittedDraft() {
        guard Self.confirmSubmittedDraft(
            &draft, submittedConfiguration: submittedConfiguration,
            isSubmitting: isSubmitting, fanControl: fanControl
        ) else { return }
        submittedConfiguration = nil
    }

    /// Existing readback may still describe the previous request while a new
    /// submission is in flight. Only the settled result can confirm this draft.
    static func confirmSubmittedDraft(
        _ draft: inout FanControlDraft,
        submittedConfiguration: FanControlDraft.Configuration?,
        isSubmitting: Bool,
        fanControl: FanControlCoordinator
    ) -> Bool {
        guard !isSubmitting, !fanControl.isSwitchingMode, !fanControl.isApplying,
              submittedConfiguration == draft.configuration,
              draft.mode != .customCurve || !fanControl.curveStore.hasUnappliedChanges,
              draft.matchesReadback(mode: fanControl.observedMode, fractions: fanControl.confirmedManualFractionByFan) else { return false }
        draft.markConfirmed()
        return true
    }
    private func refreshDraftIfUnedited() {
        guard !draft.hasChanges, submittedConfiguration == nil, !isBusy else { return }
        draft = FanControlDraft(telemetry: telemetry, observedMode: fanControl.observedMode,
            synchronizesFans: fanControl.synchronizesManualFans,
            confirmedFractions: fanControl.confirmedManualFractionByFan)
    }
}

/// D73 fix1: four visible modes; fixed fan sets remain a Settings detail.
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
        case .automatic: L10n.text("自动控制", "Automatic")
        case .curve: L10n.text("自定义风扇曲线", "Custom Fan Curve")
        case .manual: L10n.text("手动控制", "Manual")
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

    var systemImage: String {
        switch self {
        case .automatic: AppSymbols.Monitor.sensors
        case .curve: AppSymbols.Monitor.advanced
        case .manual: AppSymbols.Panel.settings
        case .maximum: AppSymbols.Monitor.sensors
        }
    }
}

/// One mode as a vertical single-choice card (docs/mini-window-design.md
/// "风扇控制", concept 117/118), simplified by D64: icon, title and a round selection
/// mark on the right. The whole card is the click target. Choosing a card only
/// edits the draft; nothing reaches the fans before "Apply".
struct FanControlModeCard: View {
    /// Cards sit close together like a list; only the chosen one is framed,
    /// which keeps the compact palette within its height budget.
    static let spacing: CGFloat = 2
    /// The selected mode's controls line up with the card's text.
    static let contentInset: CGFloat = 4
    static let markSize: CGFloat = 16
    static let horizontalPadding: CGFloat = 8

    let choice: FanControlModeChoice
    let selected: Bool
    let isApplying: Bool
    let isDisabled: Bool
    var disabledReason: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    private var title: String { choice.title }

    var body: some View {
        Button(action: action) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing + 2) {
                AppSymbolGlyph(systemImage: choice.systemImage, size: 14)
                    .foregroundStyle(selected ? tint : AppDesignTokens.Palette.secondaryText)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
#if DEBUG
                    .layoutProbe("fan.mode.icon")
#endif
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
#if DEBUG
                        .layoutProbe("fan.mode.title")
#endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if isApplying {
                        ProgressView().controlSize(.mini)
                    } else {
                        FanControlModeSelectionMark(selected: selected, tint: tint)
                    }
                }
                .frame(width: Self.markSize, height: Self.markSize)
#if DEBUG
                .layoutProbe("fan.mode.mark")
#endif
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous)
                    .fill(selected ? tint.opacity(0.14) : (isHovered ? tint.opacity(0.07) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.85) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous))
            .opacity(isDisabled ? 0.5 : 1)
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
#if DEBUG
        .layoutProbe("fan.mode.card")
#endif
        // The Button itself is the one accessibility element (review P1-2):
        // wrapping it in `.accessibilityElement(children: .ignore)` made a new
        // element without the button's press action, so VoiceOver could not
        // choose a mode. Only label, hint, value and the selected trait are set.
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(isDisabled ? (disabledReason ?? choice.subtitle) : choice.subtitle))
        .accessibilityIdentifier(title)
        .accessibilityValue(selected
            ? L10n.text("已选择", "Selected")
            : (isApplying ? L10n.text("正在应用", "Applying") : L10n.text("未选择", "Not Selected")))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var tint: Color {
        AppDesignTokens.Palette.information
    }
}

/// The round single-choice mark: a ring, filled in the middle when chosen.
struct FanControlModeSelectionMark: View {
    let selected: Bool
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? tint : AppDesignTokens.Palette.secondaryText.opacity(0.6), lineWidth: 1.5)
            if selected {
                Circle()
                    .fill(tint)
                    .padding(4)
            }
        }
        .frame(width: FanControlModeCard.markSize, height: FanControlModeCard.markSize)
        .accessibilityHidden(true)
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
