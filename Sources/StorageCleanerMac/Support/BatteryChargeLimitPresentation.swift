import Foundation

/// D59、D73：分段高亮只来自实际回读；测试可指定语言，无需写全局偏好。
enum BatteryChargeLimitPresentation {
    static func cardSummary(
        _ state: BatteryChargeLimitState?, usesChinese: Bool = L10n.usesChinese
    ) -> String? {
        guard let state else { return nil }
        if state.smartChargingTemporarilyDisabled || state.manualLimitTemporarilyDisabled {
            return usesChinese ? "本次充满" : "Full this time"
        }
        if state.source == .none || state.effectiveLimit == 100 && state.source != .unknown {
            return usesChinese ? "无上限" : "No limit"
        }
        guard let limit = state.effectiveLimit else { return nil }
        return usesChinese ? "上限 \(limit)%" : "Limit \(limit)%"
    }

    static func energyModeCardTitle(
        mode: BatteryPowerMode?, state: BatteryChargeLimitState?,
        usesChinese: Bool = L10n.usesChinese
    ) -> String? {
        guard let mode else { return cardSummary(state, usesChinese: usesChinese) }
        let modeText: String
        switch mode {
        case .automatic: modeText = usesChinese ? "自动" : "Auto"
        case .lowPower: modeText = usesChinese ? "低功耗" : "Low Power"
        case .highPower: modeText = usesChinese ? "高功率" : "High Power"
        }
        guard let limit = cardSummary(state, usesChinese: usesChinese) else { return modeText }
        return "\(modeText) · \(limit)"
    }

    static func summary(
        _ state: BatteryChargeLimitState?,
        usesChinese: Bool = L10n.usesChinese
    ) -> String {
        guard let state else {
            return usesChinese ? "充电上限未知" : "Charge limit unknown"
        }
        if state.smartChargingTemporarilyDisabled || state.manualLimitTemporarilyDisabled {
            return usesChinese ? "本次充到 100%" : "Charging to 100% this time"
        }
        if state.source == .none { return usesChinese ? "不限" : "No limit" }
        let limit = state.effectiveLimit.map { "\($0)%" }
        let base = usesChinese
            ? limit.map { "上限 \($0)" } ?? "上限未知"
            : limit.map { "Limit \($0)" } ?? "Limit unknown"
        switch state.source {
        case .optimized:
            return usesChinese ? "\(base)（macOS 优化充电）" : "\(base) (macOS optimized charging)"
        case .manual:
            return usesChinese ? "\(base)（手动）" : "\(base) (manual)"
        case .manualAndOptimized:
            return usesChinese ? "\(base)（手动 + macOS 优化充电）" : "\(base) (manual + macOS optimized charging)"
        case .unknown:
            return usesChinese ? "\(base)（来源未知）" : "\(base) (source unknown)"
        case .none:
            return usesChinese ? "不限" : "No limit"
        }
    }

    static func manualTargetLabel(
        _ target: BatteryChargeTarget,
        usesChinese: Bool = L10n.usesChinese
    ) -> String {
        target.displayText
    }

    /// 不用存储的手动目标或发送中的目标代替实际生效值，也不吸附到最近档位。
    static func selectedSegment(_ state: BatteryChargeLimitState?) -> BatteryChargeTarget? {
        guard let state, let effective = state.effectiveLimit else { return nil }
        return state.availableTargets.first { $0.rawValue == effective }
    }

    /// D73：只在非手动来源显示一行说明，安全操作详情保留在提示和失败信息中。
    static func sourceCaption(
        _ state: BatteryChargeLimitState?, usesChinese: Bool = L10n.usesChinese
    ) -> String? {
        guard let state else { return nil }
        let value = state.effectiveLimit.map { "\($0)%" }
        switch state.source {
        case .manual: return nil
        case .optimized, .manualAndOptimized:
            let limit = value ?? (usesChinese ? "未知" : "unknown")
            return usesChinese ? "macOS 优化充电 · 上限 \(limit)"
                : "macOS optimized charging · Limit \(limit)"
        case .none:
            guard state.smartChargingState == .enabled else { return nil }
            return usesChinese ? "macOS 优化充电已开启，目前没有限制。"
                : "macOS optimized charging is enabled; no limit is active now."
        case .unknown:
            return usesChinese ? "充电上限来源未知" : "Charge-limit source unknown"
        }
    }

    static func manualLimitUnavailableMessage(usesChinese: Bool = L10n.usesChinese) -> String {
        usesChinese ? "本机不支持手动上限" : "Manual limit not supported on this Mac"
    }

    static func optimizedChargingRejectedAfterManualLiftMessage(
        effectiveLimit: Int?, usesChinese: Bool = L10n.usesChinese
    ) -> String {
        let completed = usesChinese
            ? "已临时解除手动上限，但 macOS 拒绝暂停优化充电"
            : "The manual limit was temporarily lifted, but macOS refused to pause optimized charging"
        if let effectiveLimit, (1..<100).contains(effectiveLimit) {
            return usesChinese ? "\(completed)，充电仍限制在 \(effectiveLimit)%。"
                : "\(completed); charging is still limited to \(effectiveLimit)%."
        }
        if effectiveLimit == 100 {
            return usesChinese ? "\(completed)；当前回读上限为 100%。"
                : "\(completed); the current limit reads back as 100%."
        }
        return usesChinese ? "\(completed)；当前充电上限未能回读确认，请检查电池设置。"
            : "\(completed); the current charge limit could not be verified. Check Battery settings."
    }

    static func optimizedExplanation(
        _ state: BatteryChargeLimitState?,
        powerSource: BatteryPowerSource = .acPower,
        canRequestFullCharge: Bool = true,
        usesChinese: Bool = L10n.usesChinese
    ) -> String? {
        guard let state else { return nil }
        if state.smartChargingState == .enabled, state.source == .none, state.effectiveLimit == 100 {
            return usesChinese ? "macOS 优化充电已开启，目前没有限制。"
                : "macOS optimized charging is enabled; no limit is active now."
        }
        guard state.source == .optimized || state.source == .manualAndOptimized else { return nil }
        let base: String
        if let limit = state.effectiveLimit, limit < 100 {
            base = usesChinese ? "macOS 优化充电另设上限 \(limit)%"
                : "macOS optimized charging sets a separate limit of \(limit)%"
        } else {
            base = usesChinese ? "macOS 优化充电另设上限（当前值未知）"
                : "macOS optimized charging sets a separate limit (current value unknown)"
        }
        let action: String
        if powerSource == .batteryPower {
            action = usesChinese ? "接上电源后可以点“本次充到 100%”临时充满"
                : "Connect power, then click “Charge This Time to 100%” for a full charge this time"
        } else if powerSource == .acPower && canRequestFullCharge {
            action = usesChinese ? "要这次充满请点“本次充到 100%”"
                : "For a full charge this time, click “Charge This Time to 100%”"
        } else {
            action = ""
        }
        let ending = usesChinese ? "要长期关闭请在系统设置里关闭优化充电。"
            : "To turn it off permanently, disable optimized charging in System Settings."
        return usesChinese ? "\(base)；\(action.isEmpty ? "" : action + "，")\(ending)"
            : "\(base). \(action.isEmpty ? "" : action + ". ")\(ending)"
    }

    /// R7：把视图记忆清除规则固定为纯函数；重新生效、读失败不能保留成功提示。
    static func retainedAcceptedSource(
        _ acceptedSource: BatteryChargeLimitSource?,
        previous: BatteryChargeLimitState?, current: BatteryChargeLimitState?, isRequesting: Bool
    ) -> BatteryChargeLimitSource? {
        if isRequesting { return acceptedSource }
        guard let current, current.source != .unknown,
              current.effectiveLimit.map({ $0 < 100 }) != true else { return nil }
        if previous?.smartChargingTemporarilyDisabled == true,
           !current.smartChargingTemporarilyDisabled { return nil }
        return acceptedSource
    }

    static func fullChargeStatus(
        _ state: BatteryChargeLimitState?,
        acceptedSource: BatteryChargeLimitSource? = nil,
        usesChinese: Bool = L10n.usesChinese
    ) -> String? {
        if state?.smartChargingTemporarilyDisabled == true {
            return usesChinese
                ? "本次将充到 100%（优化充电已临时暂停）"
                : "Charging to 100% this time (optimized charging temporarily paused)"
        }
        if state?.manualLimitTemporarilyDisabled == true {
            return usesChinese ? "本次将充到 100%（手动上限已临时解除）"
                : "Charging to 100% this time (manual limit temporarily lifted)"
        }
        guard let acceptedSource = retainedAcceptedSource(
            acceptedSource, previous: state, current: state, isRequesting: false
        ) else { return nil }
        if acceptedSource == .optimized || acceptedSource == .manualAndOptimized {
            return usesChinese ? "本次将充到 100%（优化充电已临时暂停）"
                : "Charging to 100% this time (optimized charging temporarily paused)"
        }
        return usesChinese ? "本次将充到 100%" : "Charging to 100% this time"
    }

    static func noActiveLimitMessage(usesChinese: Bool = L10n.usesChinese) -> String {
        usesChinese ? "当前没有生效的充电上限，无需解除。"
            : "No charge limit is active; nothing to lift."
    }

    static func unsupportedMessage(
        _ state: BatteryChargeLimitState?,
        usesChinese: Bool = L10n.usesChinese
    ) -> String {
        switch state?.source ?? .unknown {
        case .optimized:
            return usesChinese
                ? "无法读取可验证的优化充电上限，或此系统未提供临时暂停优化充电的控制。请打开电池设置检查。"
                : "The optimized limit cannot be verified, or this system does not provide a temporary optimized-charging control. Check Battery settings."
        case .manual, .manualAndOptimized:
            return usesChinese
                ? "无法读取可验证的手动上限，或此系统未提供临时解除手动上限的控制。请打开电池设置检查。"
                : "The manual limit cannot be verified, or this system does not provide a temporary manual-limit control. Check Battery settings."
        case .none:
            return usesChinese
                ? "当前没有可解除的充电上限；未读到允许覆盖的系统充电暂停，或覆盖接口不可用。请使用系统电池菜单。"
                : "There is no charge limit to lift. An overridable charging pause was not reported, or its control is unavailable. Use the system Battery menu."
        case .unknown:
            return usesChinese
                ? "充电上限来源或系统暂停状态未知，无法安全选择临时满充控制。请使用系统电池菜单。"
                : "The charge-limit source or charging-pause state is unknown, so a temporary full-charge control cannot be safely selected. Use the system Battery menu."
        }
    }
}
