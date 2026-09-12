import Foundation

enum BatteryTimeEstimateKind: Equatable, Sendable {
    case untilFull
    case remaining

    var localizedLabel: String {
        switch self {
        case .untilFull:
            L10n.text("预计充满", "Estimated Until Full")
        case .remaining:
            L10n.text("预计剩余", "Estimated Remaining")
        }
    }
}

struct BatteryTimeEstimate: Equatable, Sendable {
    let kind: BatteryTimeEstimateKind
    let minutes: Int
}

enum BatteryTimeEstimateResolver {
    static func resolve(
        minutes: Int,
        isCharging: Bool?,
        powerSource: BatteryPowerSource?
    ) -> BatteryTimeEstimate? {
        guard minutes >= 0 else { return nil }
        if isCharging == true {
            return BatteryTimeEstimate(kind: .untilFull, minutes: minutes)
        }
        if isCharging == false, powerSource == .batteryPower {
            return BatteryTimeEstimate(kind: .remaining, minutes: minutes)
        }
        return nil
    }
}

enum BatterySettingsActionLabel: Equatable, Sendable {
    case openSettings
    case openingSettings
    case verifySettings
    case verifying
    case verifyAgain
    case reopenSettings
    case openManually
    case recheckSettings
}

struct BatterySettingsActionPresentation: Equatable, Sendable {
    let label: BatterySettingsActionLabel
    let isEnabled: Bool
}

enum BatterySettingsActionResolver {
    static func resolve(
        _ state: BatterySettingsAdjustmentState
    ) -> BatterySettingsActionPresentation {
        switch state {
        case .idle:
            BatterySettingsActionPresentation(label: .openSettings, isEnabled: true)
        case .openingSettings:
            BatterySettingsActionPresentation(label: .openingSettings, isEnabled: false)
        case .awaitingVerification:
            BatterySettingsActionPresentation(label: .verifySettings, isEnabled: true)
        case .verifying:
            BatterySettingsActionPresentation(label: .verifying, isEnabled: false)
        case .unchanged:
            BatterySettingsActionPresentation(label: .verifyAgain, isEnabled: true)
        case .expired, .failedToOpen:
            BatterySettingsActionPresentation(label: .reopenSettings, isEnabled: true)
        case .unverifiable:
            BatterySettingsActionPresentation(label: .openManually, isEnabled: true)
        case .verified:
            BatterySettingsActionPresentation(label: .recheckSettings, isEnabled: true)
        }
    }
}

extension BatterySettingsActionLabel {
    var localizedTitle: String {
        switch self {
        case .openSettings:
            L10n.text("打开电池设置", "Open Battery Settings")
        case .openingSettings:
            L10n.text("正在打开设置", "Opening Settings")
        case .verifySettings:
            L10n.text("验证电池设置", "Verify Battery Settings")
        case .verifying:
            L10n.text("正在验证设置", "Verifying Settings")
        case .verifyAgain:
            L10n.text("重新验证设置", "Verify Settings Again")
        case .reopenSettings:
            L10n.text("重新打开电池设置", "Reopen Battery Settings")
        case .openManually:
            L10n.text("打开电池设置（手动核对）", "Open Battery Settings (Verify Manually)")
        case .recheckSettings:
            L10n.text("重新检查电池设置", "Recheck Battery Settings")
        }
    }
}

enum ThermalReadinessPresentation: Equatable, Sendable {
    case notChecked
    case stale
    case current(ThermalReadiness)
}

enum ThermalReadinessResolver {
    static let defaultFreshnessInterval: TimeInterval = 600

    static func resolve(
        _ readiness: ThermalReadiness,
        checkedAt: Date?,
        now: Date,
        freshnessInterval: TimeInterval = defaultFreshnessInterval
    ) -> ThermalReadinessPresentation {
        guard let checkedAt else { return .notChecked }
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              freshnessInterval.isFinite,
              freshnessInterval >= 0 else {
            return .stale
        }
        let age = now.timeIntervalSince(checkedAt)
        guard age >= 0, age <= freshnessInterval else { return .stale }
        return .current(readiness)
    }
}
