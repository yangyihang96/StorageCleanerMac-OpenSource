import FanControlShared
import SwiftUI

enum GeekHardwareControlLayout {
    static let summaryHeight: CGFloat = 68
    static let summaryRingSize: CGFloat = 56

    static func authorizationHeight(for state: HelperState) -> CGFloat {
        state == .enabled ? 30 : 112
    }

    static func fanHeight(
        capability: FanControlCapability,
        mode: FanControlMode,
        fanCount: Int
    ) -> CGFloat {
        if capability == .controllable, mode == .manual {
            return 160
        }
        if capability == .controllable, mode == .temperatureCurve {
            return 160
        }
        return 78 + CGFloat(min(fanCount, 2)) * 18
    }

    static func powerHeight(hasBattery: Bool) -> CGFloat {
        hasBattery ? 116 : 88
    }
}

struct GeekHardwareAuthorizationCard: View {
    let helperState: HelperState
    let isPreparing: Bool
    let isRefreshing: Bool
    let message: String?
    let enable: () -> Void
    let openSystemSettings: () -> Void
    let refresh: () -> Void

    var body: some View {
        GeekCombinedCard(
            height: GeekHardwareControlLayout.authorizationHeight(for: helperState)
        ) {
            if helperState == .enabled {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(AppDesignTokens.Palette.success)
                    Text(L10n.text("高级控制已启用", "Advanced Control Enabled"))
                        .font(AdvancedPanelTypography.captionStrong)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(L10n.text("高级硬件控制", "Advanced Hardware Control"))
                            .font(AdvancedPanelTypography.captionStrong)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        HardwareStatusBadge(
                            title: operationTitle ?? helperState.title,
                            tint: badgeTint
                        )
                    }

                    Text(L10n.text(
                        "启用后可分别设置电池与接通电源模式、手动调整风扇，并在应用异常时自动恢复系统散热。",
                        "Enable separate battery and AC power modes, manual fan control, and automatic cooling recovery after an app failure."
                    ))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let message, helperState != .notRegistered {
                        Text(message)
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        switch helperState {
                        case .notRegistered:
                            Button(L10n.text("启用高级硬件控制", "Enable Advanced Hardware Control"), action: enable)
                                .disabled(isPreparing)
                        case .requiresApproval, .connectionInterrupted:
                            Button(L10n.text("打开系统设置", "Open System Settings"), action: openSystemSettings)
                            Button(L10n.text("重新检测", "Check Again"), action: refresh)
                                .disabled(isRefreshing)
                        case .unavailable, .signatureRejected:
                            Button(L10n.text("重新检测", "Check Again"), action: refresh)
                                .disabled(isRefreshing)
                        case .enabled:
                            EmptyView()
                        }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var operationTitle: String? {
        if isPreparing { return L10n.text("正在申请", "Requesting") }
        if isRefreshing { return L10n.text("正在连接", "Connecting") }
        return nil
    }

    private var badgeTint: Color {
        switch helperState {
        case .signatureRejected, .connectionInterrupted:
            AppDesignTokens.Palette.warning
        default:
            AppDesignTokens.Palette.information
        }
    }
}

struct GeekFanControlCard: View {
    @ObservedObject var fanControl: FanControlCoordinator
    @ObservedObject var curveStore: FanCurveStore
    let telemetry: FanTelemetryState
    let capability: FanControlCapability
    let mode: FanControlMode
    let thermalState: SystemThermalState
    let message: String?
    let previewManualPercentage: Double?
    let editCurve: () -> Void

    @State private var draftManualPercentage: Double?
    @State private var previewCommitTask: Task<Void, Never>?

    init(
        fanControl: FanControlCoordinator,
        curveStore: FanCurveStore,
        telemetry: FanTelemetryState,
        capability: FanControlCapability,
        mode: FanControlMode,
        thermalState: SystemThermalState,
        message: String?,
        previewManualPercentage: Double?,
        editCurve: @escaping () -> Void
    ) {
        self.fanControl = fanControl
        self.curveStore = curveStore
        self.telemetry = telemetry
        self.capability = capability
        self.mode = mode
        self.thermalState = thermalState
        self.message = message
        self.previewManualPercentage = previewManualPercentage
        self.editCurve = editCurve
        _draftManualPercentage = State(initialValue: nil)
        _previewCommitTask = State(initialValue: nil)
    }

    var body: some View {
        GeekCombinedCard(
            height: GeekHardwareControlLayout.fanHeight(
                capability: capability,
                mode: mode,
                fanCount: telemetry.fanCount
            )
        ) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L10n.text("风扇控制", "Fan Control"))
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(AppDesignTokens.Palette.tertiary)
                    Spacer(minLength: 6)
                    HardwareStatusBadge(title: statusTitle, tint: statusTint)
                }

                if telemetry.telemetryAvailable {
                    if mode == .systemAutomatic || capability != .controllable {
                        ForEach(Array(telemetry.readings.prefix(2))) { reading in
                            HStack(spacing: 6) {
                                Text(reading.displayName)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 6)
                                Text(L10n.text(
                                    "实际 \(reading.displayRPM)",
                                    "Actual \(reading.displayRPM)"
                                ))
                                .monospacedDigit()
                            }
                            .font(AdvancedPanelTypography.caption)
                            .lineLimit(1)
                        }
                    }
                } else {
                    Text(emptyStateText)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                }

                if capability == .controllable {
                    Picker(
                        L10n.text("模式", "Mode"),
                        selection: modeBinding
                    ) {
                        Text(FanControlMode.systemAutomatic.title)
                            .tag(FanControlMode.systemAutomatic)
                        Text(FanControlMode.manual.title)
                            .tag(FanControlMode.manual)
                        Text(FanControlMode.temperatureCurve.title)
                            .tag(FanControlMode.temperatureCurve)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .disabled(isThermallyProtected)
                    .accessibilityLabel(L10n.text("风扇控制模式", "Fan Control Mode"))

                    if mode == .manual {
                        manualControls
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if mode == .temperatureCurve {
                        curveControls
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if let operationText {
                        Text(operationText)
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(operationTint)
                    }
                } else if let reasonText {
                    HStack(spacing: 6) {
                        Text(reasonText)
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        if telemetry.telemetryAvailable, telemetry.fanCount > 0 {
                            Button(L10n.text("编辑曲线", "Edit Curve"), action: editCurve)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: mode)
        }
        .onDisappear {
            previewCommitTask?.cancel()
            commitManualPreview()
        }
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L10n.text("转速", "Speed"))
                if telemetry.fanCount > 1 {
                    Text(L10n.text("· 同步控制全部风扇", "· Synchronize All Fans"))
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("\(Int(displayedManualPercentage.rounded()))%")
                    .monospacedDigit()
            }
            .font(AdvancedPanelTypography.captionStrong)

            Slider(
                value: manualPercentageBinding,
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { commitManualPreview() }
                }
            )
            .controlSize(.small)
            .disabled(isThermallyProtected)

            if let reading = telemetry.readings.first,
               let minimumRPM = reading.minimumRPM,
               let maximumRPM = reading.maximumRPM {
                let targetRPM = FanControlPlanner.targetRPM(
                    minimumRPM: minimumRPM,
                    maximumRPM: maximumRPM,
                    fraction: displayedManualPercentage / 100
                )
                fanTextPairRow(
                    L10n.text("最低", "Minimum"),
                    SystemFanSpeedFormat.string(minimumRPM),
                    L10n.text("最高", "Maximum"),
                    SystemFanSpeedFormat.string(maximumRPM)
                )
                fanTextPairRow(
                    L10n.text("目标", "Target"),
                    SystemFanSpeedFormat.string(targetRPM),
                    L10n.text("实际", "Actual"),
                    SystemFanSpeedFormat.string(reading.actualRPM)
                )
            }

            HStack(spacing: 6) {
                Button(L10n.text("恢复自动", "Restore Automatic")) {
                    Task { await fanControl.selectMode(.systemAutomatic) }
                }

                Spacer(minLength: 0)

                Button(L10n.text("最大", "Maximum")) {
                    Task {
                        if fanControl.selectedMode != .manual {
                            await fanControl.selectMode(.manual)
                        }
                        fanControl.commitManualPercentage(100)
                    }
                }
                .disabled(isThermallyProtected)
            }
            .controlSize(.small)
        }
    }

    private var curveControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            fanTextRow(
                L10n.text("控制传感器", "Control Sensor"),
                displayedCurveProfile?.sensor.displayTitle ?? "—"
            )
            fanTextPairRow(
                L10n.text("当前温度", "Current Temperature"),
                displayedCurveRuntimeState.filteredTemperature.map {
                    String(format: "%.1f°C", $0)
                } ?? "—",
                L10n.text("当前输出", "Current Output"),
                displayedCurveRuntimeState.appliedPercentage.map {
                    "\(Int($0.rounded()))%"
                } ?? "—"
            )

            FanCurveCompactPreview(
                points: displayedCurveProfile?.points
                    ?? curveStore.savedProfile.points,
                currentTemperature: displayedCurveRuntimeState.filteredTemperature,
                currentPercentage: displayedCurveRuntimeState.appliedPercentage
            )
            .frame(height: 24)

            fanTextPairRow(
                L10n.text("目标转速", "Target RPM"),
                averageRPM(displayedCurveRuntimeState.targetRPMByFan)
                    .map(SystemFanSpeedFormat.string) ?? "—",
                L10n.text("实际转速", "Actual RPM"),
                averageRPM(displayedCurveRuntimeState.actualRPMByFan)
                    .map(SystemFanSpeedFormat.string) ?? "—"
            )

            HStack(spacing: 6) {
                Button(L10n.text("恢复自动", "Restore Automatic")) {
                    Task { await fanControl.selectMode(.systemAutomatic) }
                }

                Spacer(minLength: 0)

                Button(L10n.text("编辑曲线", "Edit Curve"), action: editCurve)
            }
            .controlSize(.small)
        }
    }

    private func fanTextRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).monospacedDigit()
        }
        .font(AdvancedPanelTypography.caption)
        .lineLimit(1)
    }

    private func fanTextPairRow(
        _ firstTitle: String,
        _ firstValue: String,
        _ secondTitle: String,
        _ secondValue: String
    ) -> some View {
        HStack(spacing: 5) {
            Text(firstTitle).foregroundStyle(.secondary)
            Text(firstValue).monospacedDigit()
            Spacer(minLength: 6)
            Text(secondTitle).foregroundStyle(.secondary)
            Text(secondValue).monospacedDigit()
        }
        .font(AdvancedPanelTypography.caption)
        .lineLimit(1)
    }

    private func averageRPM(_ values: [Int: Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private var modeBinding: Binding<FanControlMode> {
        Binding {
            mode
        } set: { requested in
            switch requested {
            case .systemAutomatic:
                Task { await fanControl.selectMode(.systemAutomatic) }
            case .manual:
                Task { await fanControl.selectMode(.manual) }
            case .temperatureCurve:
                editCurve()
            case .unknown:
                break
            }
        }
    }

    private var manualPercentageBinding: Binding<Double> {
        Binding {
            displayedManualPercentage
        } set: { value in
            draftManualPercentage = min(100, max(0, value.isFinite ? value : 0))
            scheduleManualPreviewCommit()
        }
    }

    private var displayedManualPercentage: Double {
        draftManualPercentage
            ?? previewManualPercentage
            ?? fanControl.manualFraction * 100
    }

    private func scheduleManualPreviewCommit() {
        previewCommitTask?.cancel()
        guard let percentage = draftManualPercentage else { return }
        previewCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(
                FanControlSafetyPolicy.manualControlDebounce
            ))
            guard !Task.isCancelled else { return }
            fanControl.commitManualPercentage(percentage)
        }
    }

    private func commitManualPreview() {
        previewCommitTask?.cancel()
        previewCommitTask = nil
        guard let percentage = draftManualPercentage else { return }
        fanControl.commitManualPercentage(percentage)
        draftManualPercentage = nil
    }

    private var isThermallyProtected: Bool {
        thermalState == .serious || thermalState == .critical
    }

    private var statusTitle: String {
        if isThermallyProtected { return L10n.text("热保护", "Thermal Protection") }
        if fanControl.isApplying || fanControl.isSwitchingMode {
            return L10n.text("正在应用…", "Applying…")
        }
        if mode == .temperatureCurve, displayedCurveHasUnappliedChanges {
            return L10n.text("有未应用更改", "Unapplied Changes")
        }
        switch mode {
        case .systemAutomatic: return FanControlMode.systemAutomatic.title
        case .manual: return L10n.text(
            "手动 \(Int(displayedManualPercentage.rounded()))%",
            "Manual \(Int(displayedManualPercentage.rounded()))%"
        )
        case .temperatureCurve:
            return curveRuntimeTitle
        case .unknown:
            return FanStatusPresentation.monitoringTitle(
                mode: mode,
                capability: capability
            )
        }
    }

    private var curveRuntimeTitle: String {
        switch displayedCurveRuntimeState.status {
        case .inactive: L10n.text("尚未应用", "Not Active")
        case .preparing: L10n.text("准备中", "Preparing")
        case .active: L10n.text("曲线调节", "Fan Curve")
        case .applying: L10n.text("正在应用…", "Applying…")
        case .sensorUnavailable: L10n.text("传感器失效", "Sensor Unavailable")
        case .sensorStale: L10n.text("温度已过期", "Temperature Stale")
        case .helperUnavailable: L10n.text("高级控制暂不可用", "Advanced Control Temporarily Unavailable")
        case .leaseExpired: L10n.text("租约失效", "Lease Expired")
        case .thermalProtection: L10n.text("热保护", "Thermal Protection")
        case .verificationFailed: L10n.text("验证失败", "Verification Failed")
        case .restoringAutomatic: L10n.text("恢复自动中", "Restoring Automatic")
        }
    }

    private var displayedCurveProfile: FanCurveProfile? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.curveProfile
        }
#endif
        return curveStore.appliedProfile
    }

    private var displayedCurveRuntimeState: FanCurveRuntimeState {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.curveRuntimeState
        }
#endif
        return fanControl.curveRuntimeState
    }

    private var displayedCurveHasUnappliedChanges: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.curveHasUnappliedChanges
        }
#endif
        return curveStore.hasUnappliedChanges
    }

    private var statusTint: Color {
        if isThermallyProtected || capability == .connectionFailed {
            return AppDesignTokens.Palette.warning
        }
        return capability == .controllable
            ? AppDesignTokens.Palette.tertiary
            : .secondary
    }

    private var emptyStateText: String {
        if telemetry.isSampling { return L10n.text("正在检测风扇能力…", "Checking fan capability…") }
        if telemetry.isFanless { return L10n.text("此设备没有风扇 · 被动散热", "No fans · Passive cooling") }
        return L10n.text("风扇遥测不可用", "Fan telemetry unavailable")
    }

    private var reasonText: String? {
        return switch capability {
        case .checking:
            L10n.text("控制能力：检测中…", "Control capability: checking…")
        case .authorizationRequired:
            L10n.text("需要启用高级控制；只读转速仍可用。", "Enable advanced control; read-only RPM remains available.")
        case .requiresSystemApproval:
            L10n.text("等待系统批准；只读转速仍可用。", "Awaiting system approval; read-only RPM remains available.")
        case .readOnly:
            L10n.text("只读监测：未获得可靠的最低/最高转速范围。", "Read-only monitoring: a reliable minimum/maximum RPM range is unavailable.")
        case let .unsupported(reason):
            reason
        case .connectionFailed:
            L10n.text(
                "风扇转速监测正常；手动和曲线控制暂不可用，请重新检测。",
                "Fan speed monitoring is available; manual and curve control are temporarily unavailable. Check again."
            )
        case .controllable:
            nil
        }
    }

    private var operationText: String? {
        if fanControl.isApplying || fanControl.isSwitchingMode {
            return L10n.text("正在应用…", "Applying…")
        }
        return message
    }

    private var operationTint: Color {
        message == nil ? .secondary : AppDesignTokens.Palette.warning
    }
}

struct GeekPowerModeControlCard: View {
    let hasInternalBattery: Bool
    let currentSource: BatteryPowerSource
    let batteryMode: BatteryPowerMode?
    let batterySupportedModes: [BatteryPowerMode]
    let adapterMode: BatteryPowerMode?
    let adapterSupportedModes: [BatteryPowerMode]
    let capability: PowerModeCapability
    let helperState: HelperState
    let adjustmentState: BatteryPowerModeAdjustmentState
    let changeMode: (BatteryPowerSource, BatteryPowerMode) -> Void

    var body: some View {
        GeekCombinedCard(
            height: GeekHardwareControlLayout.powerHeight(hasBattery: hasInternalBattery)
        ) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L10n.text("电源模式", "Power Mode"))
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 6)
                    HardwareStatusBadge(title: capabilityTitle, tint: capabilityTint)
                }

                Text(L10n.text(
                    "当前电源来源：\(powerSourceTitle)",
                    "Current power source: \(powerSourceTitle)"
                ))
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)

                if hasInternalBattery, !batterySupportedModes.isEmpty {
                    powerModeMenu(
                        title: L10n.text("使用电池", "On Battery"),
                        source: .batteryPower,
                        mode: batteryMode,
                        supportedModes: batterySupportedModes
                    )
                }
                if !adapterSupportedModes.isEmpty {
                    powerModeMenu(
                        title: L10n.text("接通电源", "On Power Adapter"),
                        source: .acPower,
                        mode: adapterMode,
                        supportedModes: adapterSupportedModes
                    )
                }

                if let operationText {
                    Text(operationText)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(operationTint)
                        .lineLimit(1)
                }
            }
        }
    }

    private func powerModeMenu(
        title: String,
        source: BatteryPowerSource,
        mode: BatteryPowerMode?,
        supportedModes: [BatteryPowerMode]
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Picker("", selection: powerModeBinding(
                source: source,
                mode: mode
            )) {
                if mode == nil {
                    Text(L10n.text("模式未知", "Mode Unknown"))
                        .tag(nil as BatteryPowerMode?)
                }
                ForEach(supportedModes, id: \.self) { option in
                    Text(powerModeTitle(option))
                        .tag(option as BatteryPowerMode?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 108)
            .disabled(!controlsEnabled)
            .help(supportedModes.contains(.highPower)
                ? L10n.text("写入后会读取 pmset 实际值确认。", "The actual pmset value is read back after writing.")
                : L10n.text("此 Mac 不支持高功率模式", "This Mac does not support High Power mode"))
            .accessibilityLabel(title)
            .accessibilityValue(mode.map(powerModeTitle) ?? L10n.text("模式未知", "Mode Unknown"))
        }
        .frame(minHeight: 22)
    }

    private func powerModeBinding(
        source: BatteryPowerSource,
        mode: BatteryPowerMode?
    ) -> Binding<BatteryPowerMode?> {
        Binding {
            mode
        } set: { requested in
            guard let requested else { return }
            changeMode(source, requested)
        }
    }

    private var controlsEnabled: Bool {
        helperState == .enabled
            && capability != .checking
            && capability != .unsupported
            && capability != .authorizationRequired
    }

    private var capabilityTitle: String {
        if adjustmentState.isChanging { return L10n.text("正在应用…", "Applying…") }
        switch helperState {
        case .requiresApproval: return L10n.text("等待系统批准", "Awaiting System Approval")
        case .connectionInterrupted: return L10n.text(
            "高级控制暂不可用",
            "Advanced Control Temporarily Unavailable"
        )
        case .signatureRejected: return L10n.text("签名校验失败", "Signature Rejected")
        case .unavailable: return L10n.text("辅助程序不可用", "Helper Unavailable")
        case .notRegistered, .enabled: break
        }
        switch capability {
        case .checking: return L10n.text("检测中", "Checking")
        case .automaticOnly: return L10n.text("仅自动", "Automatic Only")
        case .automaticAndLowPower: return L10n.text("支持低功耗", "Low Power Supported")
        case .automaticLowAndHighPower: return L10n.text("三档可用", "Three Modes")
        case .unsupported: return L10n.text("不支持", "Unsupported")
        case .authorizationRequired: return L10n.text("需要授权", "Authorization Required")
        }
    }

    private var capabilityTint: Color {
        if helperState == .connectionInterrupted
            || helperState == .signatureRejected
            || helperState == .unavailable {
            return AppDesignTokens.Palette.warning
        }
        return switch capability {
        case .unsupported:
            .secondary
        case .authorizationRequired:
            AppDesignTokens.Palette.warning
        default:
            AppDesignTokens.Palette.information
        }
    }

    private var powerSourceTitle: String {
        switch currentSource {
        case .batteryPower: L10n.text("使用电池", "Battery")
        case .acPower: L10n.text("接通电源", "Power Adapter")
        case .unknown: L10n.text("来源未知", "Unknown")
        }
    }

    private func powerModeTitle(_ mode: BatteryPowerMode) -> String {
        switch mode {
        case .automatic: L10n.text("自动", "Automatic")
        case .lowPower: L10n.text("低功耗", "Low Power")
        case .highPower: L10n.text("高功率", "High Power")
        }
    }

    private var operationText: String? {
        switch adjustmentState {
        case .idle:
            nil
        case .changing:
            L10n.text("正在应用并回读…", "Applying and reading back…")
        case .changed:
            L10n.text("已生效", "Applied")
        case .unsupported:
            L10n.text("此 Mac 不支持所选模式", "This Mac does not support the selected mode")
        case .cancelled:
            L10n.text("操作已取消", "Operation cancelled")
        case .permissionDenied:
            L10n.text("等待系统批准", "Awaiting system approval")
        case .timedOut:
            L10n.text("应用超时", "Apply timed out")
        case .failed:
            L10n.text("无法应用电源模式", "Could not apply power mode")
        case .verificationFailed:
            L10n.text("回读不一致，已恢复实际值", "Readback differed; the actual value was restored")
        }
    }

    private var operationTint: Color {
        switch adjustmentState {
        case .changed, .idle, .changing:
            .secondary
        default:
            AppDesignTokens.Palette.warning
        }
    }
}

private struct HardwareStatusBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}
