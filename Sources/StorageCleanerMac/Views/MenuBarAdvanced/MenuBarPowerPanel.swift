import SwiftUI

struct MenuBarPowerPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}

extension MenuBarAdvancedStatusView {
    var powerPage: some View {
        MenuBarPowerPanel {
            VStack(spacing: 6) {
                if let batterySnapshot, hasUsableBatteryData(batterySnapshot) {
                    AdvancedPanelCard(
                        title: L10n.text("电源", "Power"),
                        systemImage: batterySystemImage,
                        tint: batteryTint
                    ) {
                        HStack(spacing: 14) {
                            if let charge = batterySnapshot.chargePercent {
                                AdvancedCompactGauge(
                                    title: L10n.text("电量", "Charge"),
                                    value: "\(charge)%",
                                    progress: Double(charge) / 100,
                                    tint: batteryTint
                                )
                            }

                            VStack(spacing: 0) {
                                if batterySnapshot.powerSource != .unknown {
                                    AdvancedValueRow(title: L10n.text("供电来源", "Power Source"), value: batteryPowerSourceTitle, tint: batteryTint)
                                }
                                if let isCharging = batterySnapshot.isCharging {
                                    AdvancedValueRow(
                                        title: L10n.text("状态", "Status"),
                                        value: isCharging ? L10n.text("正在充电", "Charging") : batteryStatusTitle,
                                        tint: batteryTint
                                    )
                                }
                                if batterySnapshot.isDischarging == true,
                                   let runtime = batteryPredictedRuntimeText {
                                    AdvancedValueRow(
                                        title: batteryRuntimeEstimate == nil
                                            ? L10n.text("系统预计", "System Runtime")
                                            : L10n.text("耗电预计", "Power-based Runtime"),
                                        value: runtime,
                                        tint: batteryTint
                                    )
                                } else if let remaining = batterySnapshot.remainingTimeMinutes {
                                    AdvancedValueRow(title: L10n.text("预计充满", "Full Charge In"), value: durationMinutesText(remaining), tint: batteryTint)
                                }
                            }
                        }

                        if let fullyCharged = batterySnapshot.isFullyCharged {
                            AdvancedValueRow(
                                title: L10n.text("完全充满", "Fully Charged"),
                                value: fullyCharged ? L10n.text("是", "Yes") : L10n.text("否", "No"),
                                tint: fullyCharged ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.secondary
                            )
                        }
                        if let optimized = batterySnapshot.isOptimizedChargingEngaged {
                            AdvancedValueRow(
                                title: L10n.text("优化充电", "Optimized Charging"),
                                value: optimized ? L10n.text("已启用", "Engaged") : L10n.text("未启用", "Not Engaged"),
                                tint: optimized ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.secondary
                            )
                        }
                        if let electrical = batteryElectricalSnapshot {
                            Divider()
                            if let adapterPower = electrical.adapterPowerWatts {
                                AdvancedValueRow(title: L10n.text("电源适配器", "Power Adapter"), value: String(format: "%.0f W", adapterPower), tint: AppDesignTokens.Palette.success)
                            }
                            if let voltage = electrical.voltageVolts {
                                AdvancedValueRow(title: L10n.text("电池电压", "Battery Voltage"), value: String(format: "%.3f V", voltage), tint: AppDesignTokens.Palette.information)
                            }
                            if let amperage = electrical.amperageAmps {
                                AdvancedValueRow(title: L10n.text("电池电流", "Battery Current"), value: String(format: "%+.3f A", amperage), tint: amperage == 0 ? AppDesignTokens.Palette.secondary : batteryTint)
                            }
                            if let power = electrical.powerWatts {
                                AdvancedValueRow(title: L10n.text("电池功率", "Battery Power"), value: String(format: "%+.2f W", power), tint: power == 0 ? AppDesignTokens.Palette.secondary : AppDesignTokens.Palette.warning)
                            }
                            if let temperature = electrical.temperatureCelsius {
                                AdvancedValueRow(title: L10n.text("电池温度", "Battery Temperature"), value: String(format: "%.1f °C", temperature), tint: temperature >= 40 ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.success)
                            }
                        }
                    }
                }

                if hasCachedBatteryHealth {
                    AdvancedPanelCard(
                        title: L10n.text("上次电池健康检查", "Last Battery Health Check"),
                        systemImage: AppSymbols.Navigation.health,
                        tint: AppDesignTokens.Palette.success
                    ) {
                        if let capacity = healthSummary?.batteryCapacityPercent {
                            AdvancedCompactGauge(
                                title: L10n.text("最大容量", "Maximum Capacity"),
                                value: "\(capacity)%",
                                progress: min(1, max(0, Double(capacity) / 100)),
                                tint: batteryCapacityTint(capacity)
                            )
                        }
                        if let cycles = healthSummary?.batteryCycleCount {
                            AdvancedValueRow(
                                title: L10n.text("循环次数", "Cycle Count"),
                                value: "\(cycles)",
                                tint: AppDesignTokens.Palette.information
                            )
                        }
                        if let condition = healthSummary?.batteryCondition {
                            AdvancedValueRow(
                                title: L10n.text("电池状态", "Battery Condition"),
                                value: batteryConditionText(condition),
                                tint: batteryConditionTint(condition)
                            )
                        }
                        if let mode = healthSummary?.batteryPowerMode {
                            AdvancedValueRow(
                                title: L10n.text("电源模式", "Power Mode"),
                                value: batteryPowerModeText(mode),
                                tint: AppDesignTokens.Palette.secondary
                            )
                        }
                    }
                }

                AdvancedPanelCard(
                    title: L10n.text("能耗", "Energy"),
                    systemImage: AppSymbols.Monitor.power,
                    tint: AppDesignTokens.Palette.warning
                ) {
                    if let energy = store.energyImpactSnapshot {
                        AdvancedValueRow(title: L10n.text("当前应用功率", "Current App Power"), value: energy.currentPowerWattsText, tint: AppDesignTokens.Palette.warning)
                        AdvancedValueRow(title: L10n.text("估算能量", "Estimated Energy"), value: energy.estimatedTotalEnergyText, tint: AppDesignTokens.Palette.caution)
                        AdvancedValueRow(title: L10n.text("样本时长", "Sample Duration"), value: energy.sampleDurationText, tint: AppDesignTokens.Palette.tertiary)
                        AdvancedValueRow(title: L10n.text("能耗覆盖", "Energy Coverage"), value: "\(energy.energyCoveragePercentText) · \(energy.energyCoverageText)", tint: AppDesignTokens.Palette.secondary)
                        AdvancedValueRow(title: L10n.text("测量时间", "Measured At"), value: timestampText(energy.generatedAt), tint: AppDesignTokens.Palette.secondary)
                        AdvancedValueRow(title: L10n.text("活跃应用", "Active Apps"), value: "\(energy.activeAppCount)", tint: AppDesignTokens.Palette.warning)
                        AdvancedValueRow(title: L10n.text("测量来源", "Measurement"), value: energy.source, tint: AppDesignTokens.Palette.secondary)
                        AdvancedValueRow(title: L10n.text("运行时间", "Uptime"), value: energy.uptimeText, tint: AppDesignTokens.Palette.secondary)

                        ForEach(Array(energy.apps.filter(\.isApplication).prefix(3))) { app in
                            AdvancedEnergyAppRow(app: app)
                        }
                    } else {
                        AdvancedUnavailableRow(title: L10n.text("能耗按需测量，不参与每秒常驻采样。", "Energy use is measured on demand and excluded from the one-second resident sampler."))
                    }
                }

                if store.isLoadingEnergyImpact {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("正在测量能耗…", "Measuring energy use…"))
                            .font(AdvancedPanelTypography.body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(minHeight: 32)
                } else {
                    AppButton(
                        title: store.energyImpactSnapshot == nil
                            ? L10n.text("测量一次能耗", "Measure Energy Once")
                            : L10n.text("重新测量能耗", "Measure Energy Again"),
                        systemImage: AppSymbols.Panel.utilization,
                        controlSize: .small,
                        fillsWidth: true
                    ) {
                        store.refreshEnergyImpact()
                    }
                }

                AppButton(
                    title: L10n.text("打开能耗", "Open Energy"),
                    systemImage: AppSymbols.Panel.openProcesses,
                    controlSize: .small,
                    fillsWidth: true
                ) {
                    openApp(filter: .energy)
                }
            }
        }
        }

}
