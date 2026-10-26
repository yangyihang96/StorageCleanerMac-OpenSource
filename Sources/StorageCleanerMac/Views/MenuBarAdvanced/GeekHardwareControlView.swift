import SwiftUI

/// D73: the entry stays reachable while setup or telemetry is unavailable.
/// Opening it only presents the existing palette; it never requests a mode.
struct FanControlEntryPresentation: Equatable {
    let showsControl: Bool
    let status: String
    let headerStatus: String

    init(telemetry: FanTelemetryState, helperState: HelperState,
         observedMode: GeekFanControlMode?, manualPercentage: Double?) {
        showsControl = !telemetry.isFanless
        if telemetry.isFanless {
            status = L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling")
        } else if helperState != .enabled {
            status = FanControlSetupPresentation.reason(helperState)
        } else {
            switch observedMode {
            case .systemAutomatic: status = L10n.text("系统自动", "System Automatic")
            case .customCurve: status = L10n.text("自定义曲线", "Custom Curve")
            case .maximum: status = GeekFanControlMode.maximum.title
            case .manual, .fanSet:
                if let manualPercentage, manualPercentage.isFinite, (0...100).contains(manualPercentage) {
                    status = L10n.text("手动 \(Int(manualPercentage.rounded()))%", "Manual \(Int(manualPercentage.rounded()))%")
                } else {
                    status = L10n.text("手动控制", "Manual Control")
                }
            case nil:
                status = telemetry.isSampling ? L10n.text("正在检测", "Checking")
                    : L10n.text("仅监测", "Monitoring Only")
            }
        }
        if helperState != .enabled, !telemetry.isFanless {
            headerStatus = FanControlSetupPresentation.capsuleTitle(helperState)
        } else if observedMode == .systemAutomatic, !telemetry.isFanless {
            headerStatus = L10n.text("系统自动", "Automatic")
        } else {
            headerStatus = status
        }
    }
}

enum FanControlSetupPresentation {
    static func reason(_ state: HelperState) -> String {
        switch state {
        case .notRegistered: L10n.text("辅助程序未启用", "Helper Not Enabled")
        case .requiresApproval: L10n.text("等待系统批准", "Awaiting System Approval")
        case .connectionInterrupted: L10n.text("连接中断", "Connection Interrupted")
        case .signatureRejected: L10n.text("辅助程序未受信任", "Helper Not Trusted")
        case .unavailable: L10n.text("辅助程序不可用", "Helper Unavailable")
        case .enabled: L10n.text("已连接", "Connected")
        }
    }

    static func capsuleTitle(_ state: HelperState) -> String {
        switch state {
        case .requiresApproval: L10n.text("等待批准", "Awaiting Approval")
        case .connectionInterrupted: L10n.text("未连接", "Disconnected")
        case .notRegistered, .unavailable: L10n.text("未启用", "Not Enabled")
        case .signatureRejected: L10n.text("未受信任", "Untrusted")
        case .enabled: L10n.text("已连接", "Connected")
        }
    }

    static func actionTitle(_ state: HelperState) -> String {
        switch state {
        case .notRegistered, .unavailable: L10n.text("启用风扇控制", "Enable Fan Control")
        case .requiresApproval: L10n.text("在系统设置中批准", "Approve in System Settings")
        case .enabled, .connectionInterrupted, .signatureRejected: L10n.text("重新检测", "Check Again")
        }
    }
}

enum FanControlPaletteAvailability {
    /// Presentation choices are distinct from Settings' supported write modes.
    static func visibleModes(telemetry: FanTelemetryState) -> [GeekFanControlMode] {
        let standardModes: [GeekFanControlMode] = telemetry.isFanless ? [] : [.systemAutomatic, .customCurve, .manual]
        return standardModes + (telemetry.isFanless ? [] : [.maximum])
    }

    static func disabledReason(mode: GeekFanControlMode, telemetry: FanTelemetryState,
                               helperState: HelperState) -> String? {
        if helperState != .enabled { return FanControlSetupPresentation.reason(helperState) }
        if telemetry.isFanless { return L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling") }
        // System control can still be restored when fan telemetry disappears.
        if mode == .systemAutomatic { return nil }
        if telemetry.isSampling { return L10n.text("正在检测风扇", "Checking Fans") }
        if !telemetry.hasVerifiedRanges { return L10n.text("风扇量程不可用 · 仅监测", "Fan Range Unavailable · Monitoring Only") }
        return nil
    }
}

struct FanControlEntryRow: View {
    /// D119: a row of iStat's fan group, 15 pt on the 17 pt pitch; its hit
    /// area covers the pitch (D73 kept a 24 pt row).
    nonisolated static let height: CGFloat = 15
    nonisolated static let headerHeight: CGFloat = 20
    let presentation: FanControlEntryPresentation
    let isHeader: Bool

    init(state: FanControlEntryPresentation, isHeader: Bool = false) {
        self.presentation = state
        self.isHeader = isHeader
    }

    var body: some View {
        if presentation.showsControl {
            ControlPaletteAnchorButton(kind: .fan, accessibilityLabel: L10n.text("风扇控制", "Fan Control")) {
                if isHeader {
                    HStack(spacing: 4) {
                        Text(L10n.text("风扇控制", "Fan Control") + " · " + presentation.headerStatus)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        GeekDisclosureIcon(systemImage: "chevron.forward")
                    }
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: Self.headerHeight)
                } else {
                    HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                        Text(L10n.text("风扇控制", "Fan Control"))
                            .geekIStatLabelText()
                        Spacer(minLength: 4)
                        Text(presentation.status)
                            .geekIStatValueText(.secondary)
                        GeekDisclosureIcon(systemImage: "chevron.forward")
                    }
                    .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
                    .contentShape(Rectangle().inset(by: -GeekIStatSectionGeometry.rowGap / 2))
                }
            }
            .accessibilityIdentifier("fan-control-entry")
            .accessibilityValue(presentation.status)
        } else {
            Text(presentation.status)
                .geekIStatLabelText()
                .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        }
    }
}
