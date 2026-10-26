import FanControlShared
import Foundation

enum MacMiniModePresentation {
    static var title: String {
        L10n.text("Mac mini 模式：插电时不睡眠（合盖也继续运行）", "Mac mini mode: no sleep on AC (runs with lid closed)")
    }

    /// D124: the section's major label and the line under it (the title
    /// split for the text section; `title` stays the toggle's full name).
    static var sectionTitle: String {
        L10n.text("Mac mini 模式", "Mac mini Mode")
    }

    static var summary: String {
        L10n.text("插电时不睡眠（合盖也继续运行）", "No sleep on AC (runs with lid closed)")
    }

    static var safetyNotice: String {
        L10n.text("拔电后自动恢复睡眠", "Unplugging automatically restores sleep")
    }

    static func isOn(_ status: MacMiniModeStatus?) -> Bool { status?.mode == .whenOnAC }

    static func reason(_ status: MacMiniModeStatus?) -> String? {
        guard let status else { return nil }
        if let failure = status.failure { return failureMessage(failure) }
        if status.mode == .off {
            if status.ownsSleepDisabled {
                return L10n.text("正在恢复正常睡眠，尚未确认", "Normal sleep restoration is unconfirmed")
            }
            if status.readings.sleepDisabled == true {
                return L10n.text("其他来源已禁止睡眠，本应用未更改", "Another source disabled sleep; this app left it unchanged")
            }
            if status.readings.sleepDisabled == nil {
                return L10n.text("无法读取系统睡眠状态", "System sleep state is unavailable")
            }
            return nil
        }
        if status.readings.powerSource == .unknown {
            return L10n.text("无法确认电源来源，尚未确认禁止睡眠", "Power source is unknown; disabling sleep is unconfirmed")
        }
        guard status.isConsistent else {
            return status.readings.powerSource == .ac
                ? L10n.text("插电时禁止睡眠尚未生效", "Disabling sleep on AC has not been confirmed")
                : L10n.text("电池供电时正常睡眠尚未恢复", "Normal sleep on battery has not been confirmed")
        }
        return nil
    }

    static func failureMessage(_ code: FanControlHelperErrorCode?) -> String {
        switch code {
        case .fanCrashRecoveryFailed:
            L10n.text(FanControlStartupSafety.failureMessageChinese, FanControlStartupSafety.failureMessageEnglish)
        case .macMiniModeStateUnavailable: failureMessage(.stateUnavailable)
        case .macMiniModePersistenceFailed: failureMessage(.persistenceFailed)
        case .macMiniModeVerificationFailed: failureMessage(.verificationFailed)
        case .macMiniModeSleepFailed: failureMessage(.sleepRequestFailed)
        case .macMiniModeConflict: failureMessage(.conflictingIdentity)
        default: failureMessage(.commandFailed)
        }
    }

    static func failureMessage(_ failure: MacMiniModeFailure) -> String {
        switch failure {
        case .stateUnavailable:
            L10n.text("无法读取电源或系统睡眠状态，尚未确认设置", "Power or system sleep state is unavailable; the setting is unconfirmed")
        case .persistenceFailed:
            L10n.text("系统助手的恢复记录或互斥锁不可用；请查看助手日志，修复记录目录或锁目录权限后重新加载助手", "The helper recovery record or shared lock is unavailable; check helper logs, repair the record or lock directory permissions, then reload the helper")
        case .commandFailed:
            L10n.text("系统睡眠设置未成功，请重试", "The system sleep setting failed; try again")
        case .verificationFailed:
            L10n.text("系统睡眠设置回读不一致，请重试", "System sleep readback did not match; try again")
        case .conflictingIdentity:
            L10n.text("另一版本已开启 Mac mini 模式，请先在那里关闭或移除助手；已移除或签名不符的应用核实后不再占用。", "The other app version holds Mac mini mode; turn it off or remove its helper first. A verified missing or mismatched app no longer holds it.")
        case .sleepRequestFailed:
            L10n.text("已恢复睡眠设置，但合盖睡眠请求失败", "Sleep settings were restored, but the lid-sleep request failed")
        }
    }

    /// Detailed actual readings are accessible without adding explanatory rows.
    static func detail(_ status: MacMiniModeStatus?) -> String {
        guard let status else { return L10n.text("系统睡眠状态尚未读取", "System sleep state has not been read") }
        func value(_ value: Bool?) -> String {
            guard let value else { return L10n.text("未知", "Unknown") }
            return value ? L10n.text("是", "Yes") : L10n.text("否", "No")
        }
        let source = switch status.readings.powerSource {
        case .ac: L10n.text("插电", "AC")
        case .battery: L10n.text("电池", "Battery")
        case .unknown: L10n.text("未知", "Unknown")
        }
        let owner = switch status.settingOwner {
        case .helper: L10n.text("本应用助手负责恢复", "This helper owns recovery")
        case .externalOrUnknown: L10n.text("其他来源或未知工具", "External or unknown tool")
        case .none: L10n.text("未禁止睡眠", "Sleep is not disabled")
        case .unknown: L10n.text("来源未知", "Unknown source")
        }
        return [
            L10n.text("电源：", "Power: ") + source,
            L10n.text("已合盖：", "Lid closed: ") + value(status.readings.clamshellClosed),
            L10n.text("合盖会睡眠：", "Lid causes sleep: ") + value(status.readings.clamshellCausesSleep),
            L10n.text("系统禁止睡眠：", "System sleep disabled: ") + value(status.readings.sleepDisabled),
            L10n.text("设置来源：", "Setting source: ") + owner,
        ].joined(separator: "\n")
    }
}
