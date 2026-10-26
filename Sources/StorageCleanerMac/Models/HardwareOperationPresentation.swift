import FanControlShared
import Foundation

/// D102 L4: the text for one hardware operation record on the Operation
/// History page.
enum HardwareOperationPresentation {
    static func title(_ record: HardwareOperationRecord) -> String {
        switch record.operation {
        // Manual speeds, the preset sets and Maximum all write fan targets.
        case .fanSpeed: L10n.text("设置风扇转速", "Fan speed set")
        case .fanCurveOn: L10n.text("开启风扇曲线", "Fan curve on")
        case .fanCurveUpdate: L10n.text("更新风扇曲线", "Fan curve updated")
        case .fanCurveOff: L10n.text("关闭风扇曲线", "Fan curve off")
        case .systemFanControl: L10n.text("风扇交回系统控制", "Return fans to system control")
        case .powerMode: L10n.text("电源模式", "Power mode")
        case .macMiniMode: L10n.text("Mac mini 模式", "Mac mini mode")
        }
    }

    /// The requested values, or nil when the operation has none. Fans are
    /// numbered from 1, as in the fan list when a fan has no name.
    static func detail(_ record: HardwareOperationRecord) -> String? {
        var parts = (record.targetRPMByFan ?? [:]).sorted { $0.key < $1.key }.map { fan, rpm in
            L10n.text("风扇 \(fan + 1)：\(rpm) RPM", "Fan \(fan + 1): \(rpm) RPM")
        }
        parts += (record.automaticFanIDs ?? []).sorted().map { fan in
            L10n.text("风扇 \(fan + 1)：交回系统", "Fan \(fan + 1): system control")
        }
        if let setting = record.powerSetting, let value = record.powerValue {
            let flag = record.powerSource ?? ""
            let source = switch flag {
            case "-b": L10n.text("电池", "Battery")
            case "-c": L10n.text("电源适配器", "Power adapter")
            default: flag
            }
            parts.append("\(source) · pmset \(setting) \(value)")
        }
        if let mode = record.macMiniMode {
            parts.append(mode == .whenOnAC ? L10n.text("开启", "On") : L10n.text("关闭", "Off"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: L10n.text("；", "; "))
    }

    static func outcome(_ record: HardwareOperationRecord) -> String {
        switch record.outcome {
        case .succeeded:
            return L10n.text("成功", "Succeeded")
        case .failed:
            if record.errorCode == FanControlHelperErrorCode.fanCrashRecoveryFailed.rawValue {
                return L10n.text("失败：辅助程序启动时未能交回系统控制", "Failed: the helper could not return control at startup")
            }
            return record.errorCode.map { L10n.text("失败（\($0)）", "Failed (\($0))") } ?? L10n.text("失败", "Failed")
        case .unconfirmed:
            return L10n.text("未确认：已发出，但没有收到可用的回复", "Unconfirmed: sent, but no usable reply came back")
        case .automaticRestore:
            let reason = automaticRestoreReason(record)
            return L10n.text("\(reason.chinese)，已自动交回系统", "\(reason.english); returned to the system")
        case .automaticRestoreFailed:
            let reason = automaticRestoreReason(record)
            return L10n.text("\(reason.chinese)，但未能交回系统控制", "\(reason.english); could not return control to the system")
        case .automaticRestoreUnconfirmed:
            let reason = automaticRestoreReason(record)
            return L10n.text("\(reason.chinese)，是否已交回系统未确认", "\(reason.english); return to the system unconfirmed")
        }
    }

    /// D105: the reason the helper reported, or the one a reply's error code gave.
    private static func automaticRestoreReason(_ record: HardwareOperationRecord) -> (chinese: String, english: String) {
        let reason = record.automaticRestoreReason
            ?? record.errorCode.flatMap(FanControlAutomaticRestore.Reason.init(rawValue:))
        return switch reason {
        case .fanLeaseExpired, .curveLeaseExpired, nil: ("租约到期", "Lease expired")
        case .thermalProtectionActivated: ("过热保护", "Thermal protection")
        case .curveFailed: ("风扇曲线停止", "Fan curve stopped")
        case .fanVerificationFailed: ("风扇状态无法核对", "Fan state could not be verified")
        case .appDisconnected: ("App 断开连接", "App disconnected")
        case .helperStopping: ("辅助程序退出", "Helper stopped")
        case .startupRecovery: ("辅助程序重新启动", "Helper restarted")
        case .other: ("辅助程序自动处理", "Helper's own action")
        }
    }
}
