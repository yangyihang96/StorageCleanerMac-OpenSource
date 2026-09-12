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
        mode.map { FanControlMode.resolve(observedMode: $0).title }
            ?? "—"
    }
}

extension View {
    /// Measure the page's ideal height at its actual column width, independently
    /// of the panel's previous height. A window resize must not feed back into
    /// this measurement when switching compact/full controls or the editor.
    func controlPaletteContentLayout(_ presentation: ControlPalettePresentationState) -> some View {
        frame(width: ControlPaletteMetrics.size(
            kind: presentation.kind,
            fanPage: presentation.fanPage
        ).width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) {
                    presentation.reportMeasuredContentSize(proxy.size)
                }
            }
        }
    }
}

struct ControlPaletteRootView: View {
    @ObservedObject private var presentation: ControlPalettePresentationState
    @ObservedObject private var fanControl: FanControlCoordinator
    @ObservedObject private var computerHealthStore: ComputerHealthStore
    @ObservedObject private var monitorState: MenuBarMonitorState
    @ObservedObject private var auxiliaryState: MenuBarAuxiliaryMonitorState

    @AppStorage(L10n.appearanceDefaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(PanelAppearancePreferences.miniWindowAppearanceKey) private var miniWindowAppearanceRawValue = ""
    @AppStorage(PanelAppearancePreferences.colorThemeKey) private var panelColorTheme = PanelColorTheme.graphite.rawValue
    @AppStorage(PanelAppearancePreferences.backgroundColorKey) private var panelBackgroundColor = ""
    @AppStorage(PanelAppearancePreferences.chartColorKey) private var panelChartColor = ""

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
    }

    var body: some View {
        MetricPanelShell {
            VStack(alignment: .leading, spacing: 0) {
                switch presentation.kind {
                case .fan:
                    if presentation.fanPage == .curveEditor {
                        fanCurveEditor
                    } else {
                        fanHistory
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
        .environment(\.panelBackgroundTint, paletteBackgroundTint)
        .environment(\.panelChartAccentColor, paletteChartTint)
        .preferredColorScheme(preferredColorScheme)
        .controlPaletteContentLayout(presentation)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            presentation.beginInteraction()
        })
        // `isHelperReachable` starts false on every app launch, so an
        // approved helper still reads "connection interrupted" until
        // something pings it. Refresh whenever a control palette opens so
        // the controls reflect the real helper state without requiring a
        // manual "Check Again". The refresh only pings an already-approved
        // service; it never triggers registration or approval prompts.
        .task(id: presentation.kind) {
            guard presentation.kind == .fan || presentation.kind == .power else { return }
            await fanControl.refreshConnection()
        }
    }

    private var fanHistory: some View {
        let points = monitorState.history(within: 600).map { point in
            presentation.selectedFanIndex.map { point.replacingFanRPM(with: point.fanRPM(at: $0)) } ?? point
        }
        return GeekPrecisionLineChart(
            points: points,
            series: [MenuBarTelemetrySeries(id: "fan-control-history", title: L10n.text("转速", "Speed"),
                channel: .fanRPM, color: AppChartPalette.primary)],
            valueRange: 0...max(1, (points.compactMap(\.fanRPM).max() ?? 6000) * 1.1),
            unit: .fanRPM,
            accessibilityLabel: L10n.text("风扇转速历史", "Fan speed history"),
            style: .stackedBars, duration: 600, showsLegend: false,
            showsTimelineLabels: true, showsTooltip: true
        )
        .frame(height: 78)
        .padding(.bottom, 6)
    }

    private var fanCurveEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    presentation.showFanControls()
                } label: {
                    Label(
                        L10n.text("风扇控制", "Fan Control"),
                        systemImage: AppSymbols.Panel.attachedDetail
                    )
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .font(AdvancedPanelTypography.captionStrong)
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
            if fanControl.helperState != .enabled {
                ControlPaletteHelperStatusView(
                    helperState: fanControl.helperState,
                    isBusy: fanControl.isPreparingHelper || fanControl.isRefreshingConnection,
                    enable: { Task { await fanControl.registerHelper() } },
                    openSystemSettings: fanControl.openApprovalSettings,
                    retry: { Task { await fanControl.refreshConnection() } }
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
                    : .acPower,
                isCharging: auxiliaryState.batterySnapshot?.isCharging == true,
                showsChargeTargetSetting: hasInternalBattery,
                showsFullChargeAction: auxiliaryState.batterySnapshot?
                    .shouldOfferFullChargeAction == true,
                chargeLimitState: auxiliaryState.batteryChargeLimitState,
                batteryPowerWatts: auxiliaryState.batteryElectricalSnapshot?.powerWatts,
                adapterPowerWatts: auxiliaryState.batteryElectricalSnapshot?.adapterPowerWatts,
                adjustmentState: computerHealthStore.batteryPowerModeAdjustmentState,
                controlsEnabled: fanControl.helperState == .enabled && !fanControl.isDataOnlyFixture,
                onChargeToFull: BatteryFullChargeService.requestToFull,
                onSetChargeTarget: auxiliaryState.setBatteryChargeTarget,
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
            auxiliaryState.refreshBatteryChargeLimitState()
            await computerHealthStore.refreshBatteryPowerModes()
        }
    }

    private var hasInternalBattery: Bool {
        auxiliaryState.batterySnapshot != nil
            || auxiliaryState.batteryElectricalSnapshot?.hasBatteryData == true
            || computerHealthStore.snapshot?.battery != nil
    }

    private var paletteBackgroundTint: Color? {
        PanelAppearancePreferences.color(
            from: PanelColorTheme.resolvedBackgroundHex(
                storedTheme: panelColorTheme,
                customHex: panelBackgroundColor,
                chartHex: panelChartColor
            ) ?? ""
        )?.opacity(MiniWindowStyleTokens.panelBackgroundTintOpacity)
    }

    private var paletteChartTint: Color? {
        PanelAppearancePreferences.color(
            from: PanelColorTheme.resolvedChartHex(
                storedTheme: panelColorTheme,
                backgroundHex: panelBackgroundColor,
                customHex: panelChartColor
            ) ?? ""
        )
    }

    private var preferredColorScheme: ColorScheme? {
        if let appearance = MiniWindowAppearance(rawValue: miniWindowAppearanceRawValue) {
            return appearance.preferredColorScheme
        }
        switch AppAppearance(rawValue: appearanceRawValue) ?? .system {
        case .system:
            return resolvedPanelTheme == .graphite ? .dark : nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var resolvedPanelTheme: PanelColorTheme {
        PanelColorTheme.resolved(
            storedTheme: panelColorTheme,
            backgroundHex: panelBackgroundColor,
            chartHex: panelChartColor
        )
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: AppSymbols.Monitor.sensors)
                    .foregroundStyle(AppDesignTokens.Palette.tertiary)
                Text(L10n.text("风扇控制", "Fan Control"))
                Spacer(minLength: 4)
                MiniWindowStatusCapsule(title: statusTitle, tint: statusTint, isBusy: isBusy)
            }
            .font(AdvancedPanelTypography.captionStrong)

            HStack(spacing: 2) {
                fanModeSection(.systemAutomatic, title: L10n.text("自动", "Automatic")) { EmptyView() }
                fanModeSection(.manual, title: L10n.text("手动", "Manual")) { EmptyView() }
                fanModeSection(.customCurve, title: L10n.text("曲线", "Curve")) { EmptyView() }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            Divider()
            if displayedMode == .customCurve {
                curveSummary
            } else {
                manualControls
                    .disabled(displayedMode != .manual)
                    .opacity(displayedMode == .manual ? 1 : 0.55)
                    .help(L10n.text("手动目标草稿；当前实际 RPM 位于父级传感器面板", "Manual target draft; actual RPM is shown in the parent sensor panel"))
            }
            if hasPendingChanges || isBusy || submissionFailed {
                VStack(alignment: .leading, spacing: 5) {
                    if hasPendingChanges || isBusy {
                        HStack(spacing: 6) {
                            Text(hasPendingChanges ? L10n.text("有待应用更改", "Unapplied Changes") : L10n.text("未修改", "Unchanged"))
                                .font(AdvancedPanelTypography.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button(L10n.text("取消", "Cancel"), action: cancelDraft)
                                .disabled(!hasPendingChanges || isBusy)
                            Button(L10n.text("应用", "Apply"), action: applyDraft)
                                .buttonStyle(.borderedProminent)
                                .disabled(!hasPendingChanges || applyDisabledReason != nil || isBusy)
                                .accessibilityHint(applyDisabledReason ?? L10n.text("提交后需要 Helper 回读确认", "Helper readback is required after submission"))
                        }
                    }
                    if submissionFailed {
                        Text(L10n.text("未生效，请重试", "Not applied. Try again."))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(AppDesignTokens.Palette.warning)
                            .help(fanControl.lastMessage ?? "")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Button { showsCapabilityDetails.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: capability == .controllable ? "checkmark.shield" : "eye")
                        Text(L10n.text("详细信息", "Details"))
                        Spacer(minLength: 4)
                        Image(systemName: showsCapabilityDetails ? "chevron.up" : "info.circle")
                    }
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .help(applyDisabledReason ?? L10n.text("应用后需回读确认", "Apply requires readback confirmation"))
                .accessibilityIdentifier("fan-capability-details")
                if showsCapabilityDetails || isExpanded {
                    Button(isExpanded ? L10n.text("收起读数", "Hide Readings") : L10n.text("查看全部读数", "All Readings")) {
                        presentation.setFanControlsExpanded(!isExpanded)
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .accessibilityIdentifier("fan-control-layout-toggle")
                    if isExpanded {
                        fanReadbackRows
                        paletteValueRow(L10n.text("温度来源", "Temperature Source"), curveStore.draftProfile.sensor.displayTitle)
                    }
                    paletteValueRow(L10n.text("硬件量程", "Hardware Range"), hardwareRangeTitle)
                    paletteValueRow(L10n.text("Helper 连接", "Helper Connection"), FanStatusPresentation.connectionTitle(fanControl.helperState))
                    paletteValueRow(L10n.text("系统批准", "System Approval"), FanStatusPresentation.approvalTitle(fanControl.helperState))
                    if fanControl.helperState != .enabled {
                        ControlPaletteHelperStatusView(
                            helperState: fanControl.helperState,
                            isBusy: fanControl.isPreparingHelper || fanControl.isRefreshingConnection,
                            enable: { Task { await fanControl.registerHelper() } },
                            openSystemSettings: fanControl.openApprovalSettings,
                            retry: { Task { await fanControl.refreshConnection() } }
                        )
                        .disabled(fanControl.isDataOnlyFixture)
                    }
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

    private func fanModeSection<Content: View>(
        _ mode: GeekFanControlMode, title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Button { choose(mode) } label: {
            Text(title).font(AdvancedPanelTypography.captionStrong)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(displayedMode == mode ? Color.accentColor : .clear))
                .foregroundStyle(displayedMode == mode ? .white : .primary)
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(isBusy)
        .accessibilityIdentifier("fan-draft-mode-" + mode.rawValue)
        .accessibilityAddTraits(displayedMode == mode ? .isSelected : [])
        .help(L10n.text("仅选择草稿，应用后才生效", "Draft selection only; Apply is required"))
    }

    private func paletteCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5, content: content)
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045)))
    }

    @ViewBuilder private var manualControls: some View {
        if telemetry.hasVerifiedRanges {
            if telemetry.fanCount > 1 { FanSyncToggleRow(draft: $draft, isDisabled: isBusy) }
            FanManualSliderList(draft: $draft, telemetry: telemetry, isDisabled: isBusy || displayedMode != .manual, compact: true)
        } else {
            Text(L10n.text("转速调节暂不可用", "Speed adjustment unavailable"))
                .font(AdvancedPanelTypography.caption).foregroundStyle(.secondary)
        }
    }

    private var curveSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            paletteValueRow(L10n.text("已应用曲线", "Applied Curve"), curveStore.appliedProfile?.name ?? L10n.text("尚未应用", "Not Active"))
            FanCurveCompactPreview(points: curveStore.draftProfile.points,
                currentTemperature: currentDraftTemperature,
                currentPercentage: draftPreviewPercentage)
                .frame(height: 64)
                .accessibilityLabel(L10n.text("曲线草稿预览", "Curve Draft Preview"))

            paletteValueRow(telemetry.fanCount > 1 ? L10n.text("平均目标", "Average Target") : L10n.text("目标转速", "Target Speed"), draftTargetRPM.map(SystemFanSpeedFormat.string) ?? "—")
            Button { presentation.showFanCurveEditor() } label: {
                Label(L10n.text("编辑曲线", "Edit Curve"), systemImage: AppSymbols.Monitor.advanced)
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
                .font(AdvancedPanelTypography.caption).foregroundStyle(.secondary)
        } else if telemetry.readings.count > 4 {
            Menu(L10n.text("查看全部 \(telemetry.readings.count) 个风扇", "View All \(telemetry.readings.count) Fans")) {
                ForEach(telemetry.readings) { reading in Text(reading.displayName + " · " + reading.displayRPM) }
            }
            .font(AdvancedPanelTypography.caption)
        } else {
            ForEach(telemetry.readings) { reading in paletteValueRow(reading.displayName, reading.displayRPM) }
        }
    }

    private func paletteValueRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).monospacedDigit()
        }
        .font(AdvancedPanelTypography.caption)
        .lineLimit(1)
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
        return FanStatusPresentation.confirmedModeTitle(fanControl.observedMode)
    }
    private var statusTint: Color {
        fanControl.helperState == .enabled ? AppDesignTokens.Palette.tertiary : AppDesignTokens.Palette.warning
    }
    private func isRequesting(_ mode: GeekFanControlMode) -> Bool { fanControl.requestedMode == mode && isBusy }

    private func choose(_ mode: GeekFanControlMode) {
        guard !isBusy else { return }
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

private struct ControlPaletteModeRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor

    let systemImage: String
    let title: String
    let detail: String
    let selected: Bool
    let isApplying: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(AdvancedPanelTypography.captionStrong)
                    .foregroundStyle(selected ? controlTint : .secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: 4)
                if isApplying {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: selected ? AppSymbols.Status.success : "circle")
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(selected ? controlTint : .secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 39)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected
                        ? controlTint.opacity(0.12)
                        : GeekVisualTokens.cardFill(for: colorScheme))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        GeekVisualTokens.cardBorder(
                            for: colorScheme,
                            isActive: isHovered,
                            isSelected: selected
                        ),
                        lineWidth: GeekVisualTokens.cardBorderLineWidth(
                            isActive: isHovered,
                            isSelected: selected,
                            displayScale: displayScale
                        )
                    )
            }
            .opacity(isDisabled ? 0.5 : 1)
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(title)
        .accessibilityHint(Text(detail))
        .accessibilityValue(selected
            ? L10n.text("已选择", "Selected")
            : (isApplying ? L10n.text("正在应用", "Applying") : L10n.text("未选择", "Not Selected")))
    }

    private var controlTint: Color {
        panelChartAccentColor ?? .accentColor
    }
}

struct ControlPaletteHelperStatusView: View {
    let helperState: HelperState
    let isBusy: Bool
    let enable: () -> Void
    let openSystemSettings: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                Text(isBusy ? L10n.text("正在检测…", "Checking…") : helperState.title)
                    .font(AdvancedPanelTypography.captionStrong)
                    .lineLimit(1)
            }

            Button(buttonTitle, action: buttonAction)
                .controlSize(.small)
                .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var buttonTitle: String {
        switch helperState {
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

    private var buttonAction: () -> Void {
        switch helperState {
        case .notRegistered, .unavailable: enable
        case .requiresApproval: openSystemSettings
        case .enabled, .connectionInterrupted, .signatureRejected: retry
        }
    }
}
