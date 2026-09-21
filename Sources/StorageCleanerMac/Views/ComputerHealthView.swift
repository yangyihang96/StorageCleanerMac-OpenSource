import AppKit
import SwiftUI

struct ComputerHealthView: View {
    @Environment(\.windowLayoutMetrics) private var layout
    @ObservedObject var scanStore: ScanStore
    @ObservedObject var healthStore: ComputerHealthStore
    @ObservedObject var networkStore: NetworkSpeedTestStore

    private enum SpeedTestConsent: Equatable {
        case native
        case compatibility
    }

    @State private var pendingSpeedTestConsent: SpeedTestConsent? = nil
    @State private var isEvidenceExpanded = false

    private let environmentColumns = [
        GridItem(.adaptive(minimum: 320, maximum: 500), spacing: 14, alignment: .top)
    ]

    var body: some View {
        Group {
            if healthStore.evaluation == nil {
                healthEmptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppDesignTokens.Layout.pageSpacing) {
                        if healthStore.isRefreshing {
                            RuntimeInlineStatus(
                                title: L10n.text("正在更新健康检查", "Updating Health Check"),
                                detail: L10n.text("当前保留上次检查结果", "Previous results remain visible")
                            )
                        }
                        if healthStore.evaluation != nil {
                            if layout.density == .compact {
                                healthScoreHero
                                HealthFactorGrid(evaluation: healthStore.evaluation, snapshot: healthStore.snapshot)
                            } else {
                                HStack(alignment: .top, spacing: 18) {
                                    HealthFactorGrid(evaluation: healthStore.evaluation, snapshot: healthStore.snapshot, usesTwoColumns: true)
                                        .frame(maxWidth: .infinity)
                                    healthScoreHero.frame(width: 340)
                                }
                            }

                            if !dashboardActions.isEmpty {
                                HealthActionList(
                                    actions: dashboardActions,
                                    batterySettingsState: healthStore.batterySettingsAdjustmentState,
                                    perform: perform
                                )
                            }

                            environmentSection
                            scoreEvidenceDisclosure
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .confirmationDialog(
            speedTestConsentTitle,
            isPresented: isShowingSpeedTestConsent,
            titleVisibility: .visible
        ) {
            if pendingSpeedTestConsent == .compatibility {
                Button(L10n.text("使用兼容测速", "Use Compatibility Test")) {
                    networkStore.startCompatibility(consentGranted: true)
                }
            } else {
                Button(L10n.text("开始系统测速", "Start System Test")) {
                    networkStore.start(consentGranted: true)
                }
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(speedTestConsentMessage)
        }
    }

    private var healthEmptyState: some View {
        HeroScanPage(
            title: ReviewFilter.healthHub.title,
            subtitle: ReviewFilter.healthHub.pageSubtitle,
            headerSystemImage: ReviewFilter.healthHub.systemImage,
            actionTitle: healthStore.snapshot == nil
                ? L10n.text("检查", "Check")
                : L10n.text("重新检查", "Check Again"),
            actionDetail: L10n.text("磁盘、电池与系统状态", "Disk, battery, and system status"),
            actionSystemImage: healthStore.error == nil ? "waveform.path.ecg" : "arrow.clockwise",
            status: healthHeroStatus,
            isLoading: healthStore.isRefreshing,
            isActionDisabled: healthStore.isRefreshing,
            trustText: L10n.text("只读取系统状态，不会修改设置", "System status is read only; no settings are changed")
        ) {
            Task { await healthStore.refresh(force: healthStore.snapshot != nil) }
        }
    }

    private var healthHeroStatus: ScanStatusPresentation {
        if healthStore.isRefreshing {
            return .scanning(L10n.text("正在检查系统健康", "Checking system health"))
        }
        if let error = healthStore.error {
            return .failed(healthErrorText(error))
        }
        if healthStore.snapshot == nil {
            return .idle(L10n.text("尚未检查系统健康", "System health not checked"))
        }
        return .idle(L10n.text("尚未生成健康评估", "Health evaluation is not ready"))
    }

    private var healthScoreHero: some View {
        HealthScoreHero(
            evaluation: healthStore.evaluation,
            checkedAt: healthStore.lastRefreshAt,
            isRefreshing: healthStore.isRefreshing,
            errorText: healthStore.error.map(healthErrorText),
            refreshTitle: healthStore.snapshot == nil
                ? L10n.text("开始健康检查", "Start Health Check")
                : L10n.text("重新检查", "Check Again"),
            isPortrait: layout.density != .compact
        ) {
            Task { await healthStore.refresh(force: healthStore.snapshot != nil) }
        }
    }

    private var isShowingSpeedTestConsent: Binding<Bool> {
        Binding(
            get: { pendingSpeedTestConsent != nil },
            set: { isPresented in
                if !isPresented {
                    pendingSpeedTestConsent = nil
                }
            }
        )
    }

    private var speedTestConsentTitle: String {
        pendingSpeedTestConsent == .compatibility
            ? L10n.text("使用兼容测速？", "Use Compatibility Test?")
            : L10n.text("开始系统测速？", "Start System Test?")
    }

    private var speedTestConsentMessage: String {
        if pendingSpeedTestConsent == .compatibility {
            let standardPayloadMiB = NetworkCompatibilitySpeedTestService
                .standardApplicationPayloadBytes / 1_048_576
            let maximumPayloadMiB = NetworkCompatibilitySpeedTestService
                .maximumApplicationPayloadBytes / 1_048_576
            return L10n.text(
                "兼容测速会连接公开测速端点 speed.cloudflare.com，标准测试约产生 \(standardPayloadMiB) MiB 应用层正文，最大预算 \(maximumPayloadMiB) MiB；HTTP、TLS、TCP/IP 开销和网络重传会产生额外流量。可随时取消，只保存完整结果，不保存服务器地址或 IP。",
                "The compatibility test connects to the public speed-test endpoint speed.cloudflare.com. A standard test transfers about \(standardPayloadMiB) MiB of application payload, with a \(maximumPayloadMiB) MiB maximum budget; HTTP, TLS, TCP/IP overhead and retransmissions create additional traffic. You can cancel at any time. Only a complete result is stored; server addresses and IPs are not stored."
            )
        }
        return L10n.text(
            "系统测速由 macOS 在约 20 秒内动态调整流量，高速网络可能传输数 GB；应用会在约 25 秒处安全停止。只保存本次完整结果，不保存服务器地址或 IP。",
            "macOS dynamically sizes traffic during the roughly 20-second system test, which can transfer several GB on a fast link; the app safely stops it at about 25 seconds. Only the completed result is kept; server addresses and IPs are not stored."
        )
    }

    private var dashboardActions: [HealthDashboardAction] {
        guard let evaluation = healthStore.evaluation,
              let snapshot = healthStore.snapshot else {
            return []
        }
        let context = HealthDashboardActionContext.make(
            evaluation: evaluation,
            snapshot: snapshot,
            storageForecast: healthStore.storageForecast,
            referenceDate: evaluation.evaluatedAt
        )
        return HealthDashboardActionSelector.select(from: context)
    }

    private var hasDashboardBatteryAction: Bool {
        dashboardActions.contains { $0.safeAction == .battery }
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    L10n.text("保护与当前状态（不计分）", "Protection & Current State (Not Scored)"),
                    systemImage: "gauge.with.dots.needle.50percent"
                )
                    .font(AppDesignTokens.Typography.sectionTitle)
                Spacer()
                Text(L10n.text(
                    "备份、FileVault、当前电量、温度与网络独立呈现",
                    "Backup, FileVault, charge, thermal state, and network stay separate"
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: environmentColumns, alignment: .leading, spacing: 14) {
                currentPowerCard
                protectionReadinessCard
                networkEnvironmentCard
                thermalReadinessCard
            }
        }
    }

    private var currentPowerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            environmentHeader(
                title: L10n.text("当前电源", "Current Power"),
                symbol: "battery.75",
                status: currentPowerStatusText,
                tint: currentPowerStatusColor
            )

            if let battery = healthStore.snapshot?.battery {
                if let charge = battery.currentChargePercent {
                    evidenceValueRow(
                        label: L10n.text("当前电量", "Current Charge"),
                        value: "\(charge)%"
                    )
                }
                if let source = battery.powerSource {
                    evidenceValueRow(
                        label: L10n.text("供电来源", "Power Source"),
                        value: powerSourceText(source)
                    )
                }
                if let charging = battery.isCharging {
                    evidenceValueRow(
                        label: L10n.text("充电状态", "Charging State"),
                        value: charging
                            ? L10n.text("正在充电", "Charging")
                            : L10n.text("未在充电", "Not Charging")
                    )
                }
                if let mode = battery.powerSource == .batteryPower
                    ? battery.batteryPowerMode
                    : battery.adapterPowerMode {
                    evidenceValueRow(
                        label: L10n.text("当前电源模式", "Current Power Mode"),
                        value: powerModeText(mode)
                    )
                }
            }

            Text(L10n.text(
                "当前电量和供电模式会随使用变化，不代表电池寿命，也不参与健康分。",
                "Charge and power mode change during use; they are not battery lifespan and do not affect the health score."
            ))
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .fullBleedSection()
    }

    private var protectionReadinessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            environmentHeader(
                title: L10n.text("数据保护", "Data Protection"),
                symbol: "lock.shield",
                status: L10n.text("独立检查", "Separate Check"),
                tint: AppDesignTokens.Palette.information
            )

            if let enabled = healthStore.snapshot?.disk.isFileVaultEnabled {
                evidenceValueRow(label: "FileVault", value: enabledText(enabled))
            }
            if let backup = healthStore.snapshot?.backup {
                evidenceValueRow(
                    label: L10n.text("时间机器", "Time Machine"),
                    value: destinationText(backup.destinationState)
                )
                if let latest = backup.latestCompleteBackup {
                    evidenceValueRow(
                        label: L10n.text("最近完整备份", "Latest Complete Backup"),
                        value: latest.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }

            Text(L10n.text(
                "备份与磁盘加密很重要，但它们描述保护准备度，不会伪装成硬件寿命分。",
                "Backup and disk encryption matter, but they describe protection readiness rather than hardware lifespan."
            ))
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .fullBleedSection()
    }

    private var networkEnvironmentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            environmentHeader(
                title: L10n.text("网络体验", "Network Experience"),
                symbol: "network",
                status: networkStatusText,
                tint: networkStatusColor
            )

            Text(networkSummary)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let result = networkStore.lastSuccessfulResult {
                evidenceValueRow(
                    label: L10n.text("测速方式", "Test Method"),
                    value: result.source == .nativeSystem
                        ? L10n.text("macOS 系统测速", "macOS System Test")
                        : L10n.text("兼容估算", "Compatibility Estimate")
                )
                if !result.interfaceName.trimmed.isEmpty {
                    evidenceValueRow(
                        label: L10n.text("网络接口", "Interface"),
                        value: result.interfaceName
                    )
                }
                HStack(spacing: 10) {
                    environmentMetric(
                        title: L10n.text("下载", "Download"),
                        value: speedText(result.downloadMbps),
                        tint: AppDesignTokens.Palette.information
                    )
                    environmentMetric(
                        title: L10n.text("上传", "Upload"),
                        value: speedText(result.uploadMbps),
                        tint: AppDesignTokens.Palette.sensitive
                    )
                }

                HStack(spacing: 14) {
                    if let rpm = result.responsivenessRPM {
                        Label(String(format: "%.0f RPM", rpm), systemImage: "bolt.horizontal")
                    }
                    Label(
                        String(format: "%.0f ms", result.idleLatencyMilliseconds),
                        systemImage: "timer"
                    )
                    Spacer()
                    Text(result.testedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(AppTypography.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                if let loadedLatency = result.loadedLatencyP95Milliseconds,
                   let jitter = result.jitterMilliseconds {
                    HStack(spacing: 10) {
                        environmentMetric(
                            title: L10n.text("负载延迟 P95", "Loaded Latency P95"),
                            value: String(format: "%.0f ms", loadedLatency),
                            tint: AppDesignTokens.Palette.warning
                        )
                        environmentMetric(
                            title: L10n.text("抖动", "Jitter"),
                            value: String(format: "%.1f ms", jitter),
                            tint: AppDesignTokens.Palette.sensitive
                        )
                    }
                }

                HStack(spacing: 14) {
                    if let transferredBytes = result.transferredBytes {
                        Label(ByteFormat.string(Int64(clamping: transferredBytes)), systemImage: "arrow.up.arrow.down")
                    }
                    if result.durationSeconds > 0 {
                        Label(String(format: "%.1f s", result.durationSeconds), systemImage: "clock")
                    }
                    Spacer(minLength: 0)
                }
                .font(AppTypography.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            if networkStore.state == .running {
                Button(L10n.text("取消测速", "Cancel Test")) {
                    networkStore.cancel()
                }
                .appButtonChrome(.secondary)
                .controlSize(.regular)
            } else if networkStore.isCompatibilityAvailable {
                HStack(spacing: 8) {
                    Button(L10n.text("兼容测速", "Compatibility Test")) {
                        pendingSpeedTestConsent = .compatibility
                    }
                    .appButtonChrome(.primary)

                    Button(L10n.text("重试系统测速", "Retry System Test")) {
                        pendingSpeedTestConsent = .native
                    }
                    .appButtonChrome(.secondary)
                }
                .controlSize(.regular)
            } else {
                Button(L10n.text("手动测速", "Run Manual Test")) {
                    pendingSpeedTestConsent = .native
                }
                .appButtonChrome(.secondary)
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .fullBleedSection()
    }

    private var thermalReadinessCard: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { timeline in
            thermalReadinessCard(now: timeline.date)
        }
    }

    private func thermalReadinessCard(now: Date) -> some View {
        let presentation = ThermalReadinessResolver.resolve(
            healthStore.thermalReadiness,
            checkedAt: healthStore.lastRefreshAt,
            now: now
        )
        let statusText = thermalReadinessText(presentation)
        let statusColor = thermalReadinessColor(presentation)

        return VStack(alignment: .leading, spacing: 12) {
            environmentHeader(
                title: L10n.text("热与性能就绪度", "Thermal & Performance Readiness"),
                symbol: "thermometer.medium",
                status: statusText,
                tint: statusColor
            )

            Text(thermalReadinessDetail(presentation))
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                evidenceValueRow(
                    label: L10n.text("当前状态", "Current State"),
                    value: statusText
                )
                evidenceValueRow(
                    label: L10n.text("检查时间", "Checked At"),
                    value: healthStore.lastRefreshAt?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? L10n.text("尚未检查", "Not Checked")
                )
                evidenceValueRow(
                    label: L10n.text("计分规则", "Scoring Rule"),
                    value: L10n.text("不计入核心分", "Excluded from Core Score")
                )
                evidenceValueRow(
                    label: L10n.text("数据性质", "Evidence Type"),
                    value: L10n.text("即时系统状态", "Current System State")
                )
            }

            Label(
                L10n.text(
                    "未知状态保持中性，不会显示为健康。",
                    "Unknown remains neutral and is never shown as healthy."
                ),
                systemImage: "info.circle"
            )
            .font(AppTypography.body)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .fullBleedSection()
    }

    private var scoreEvidenceDisclosure: some View {
        DisclosureGroup(isExpanded: $isEvidenceExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                if let evaluation = healthStore.evaluation {
                    scoreBreakdown(evaluation)
                } else {
                    Text(L10n.text(
                        "完成一次手动健康检查后，这里会显示每项证据、可用性、更新时间和加权扣分。",
                        "After a manual health check, this area shows evidence, availability, timestamps, and weighted deductions."
                    ))
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                }

                if let snapshot = healthStore.snapshot {
                    Divider()
                    rawEvidenceGrid(snapshot)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "function")
                    .foregroundStyle(AppDesignTokens.Palette.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HealthDashboardText.scoreEvidenceTitle)
                        .font(AppDesignTokens.Typography.sectionTitle)
                    Text(L10n.text(
                        "查看算法版本、分项分数和系统原始值",
                        "Review algorithm versions, component scores, and raw system values"
                    ))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .fullBleedSection()
    }

    private func scoreBreakdown(_ evaluation: ComputerHealthEvaluation) -> some View {
        let accounting = ComputerHealthScoring.accounting(for: evaluation.components)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                MetadataPill(
                    text: evaluation.modelVersion,
                    systemImage: "number",
                    tint: AppDesignTokens.Palette.secondary
                )
                MetadataPill(
                    text: evaluation.confidence.modelVersion,
                    systemImage: "checkmark.shield",
                    tint: AppDesignTokens.Palette.information
                )
                Spacer()
            }

            ForEach(HealthFactor.allCases, id: \.self) { factor in
                let component = evaluation.components.first { $0.factor == factor }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(
                        HealthDashboardVisuals.factorTitle(factor),
                        systemImage: HealthDashboardVisuals.factorSymbol(factor)
                    )
                    .frame(minWidth: 142, alignment: .leading)

                    Text(component.map { HealthDashboardVisuals.availabilityText($0.availability) }
                        ?? L10n.text("未提供", "Unavailable"))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Text(componentScoreText(component))
                        .fontWeight(.semibold)
                        .monospacedDigit()

                    Text(weightedDeductionText(
                        component,
                        factor: factor,
                        accounting: accounting
                    ))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 76, alignment: .trailing)
                        .monospacedDigit()

                    Text(component?.evaluatedAt.formatted(date: .abbreviated, time: .shortened) ?? "--")
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 142, alignment: .trailing)
                        .monospacedDigit()
                }
                .font(AppDesignTokens.Typography.secondary)
                .padding(.vertical, 3)
            }
        }
    }

    private func rawEvidenceGrid(_ snapshot: ComputerHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !snapshot.actionRequiredIssues.isEmpty {
                Text(L10n.text(
                    "系统明确标记需处理：\(snapshot.actionRequiredIssues.count) 项；可执行入口已在顶部按因子去重。",
                    "Explicit system action flags: \(snapshot.actionRequiredIssues.count); safe destinations are deduplicated at the top."
                ))
                .font(AppTypography.body)
                .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: environmentColumns, alignment: .leading, spacing: 12) {
                evidencePanel(
                    title: L10n.text("磁盘可靠性证据", "Disk Reliability Evidence"),
                    symbol: "internaldrive.fill",
                    updatedAt: snapshot.disk.checkedAt
                ) {
                    diskEvidenceRows(snapshot.disk)
                }

                evidencePanel(
                    title: L10n.text("容量与预测证据", "Capacity & Forecast Evidence"),
                    symbol: "chart.line.downtrend.xyaxis",
                    updatedAt: snapshot.capacity.recordedAt
                ) {
                    if let value = snapshot.capacity.availableBytes {
                        evidenceValueRow(
                            label: L10n.text("普通可用", "Available"),
                            value: ByteFormat.string(value)
                        )
                    }
                    if let value = snapshot.capacity.availableForImportantUsageBytes {
                        evidenceValueRow(
                            label: L10n.text("重要用途可用", "Important-usage Available"),
                            value: ByteFormat.string(value)
                        )
                    }
                    if let value = snapshot.capacity.sevenDayDeltaBytes {
                        evidenceValueRow(
                            label: L10n.text("7 日实际变化", "Observed 7-day Change"),
                            value: capacityDeltaText(value)
                        )
                    }
                    if let value = snapshot.capacity.thirtyDayDeltaBytes {
                        evidenceValueRow(
                            label: L10n.text("30 日实际变化", "Observed 30-day Change"),
                            value: capacityDeltaText(value)
                        )
                    }
                    evidenceValueRow(
                        label: L10n.text("空间压力预测", "Pressure Forecast"),
                        value: storageForecastText
                    )
                }

                evidencePanel(
                    title: L10n.text("备份证据", "Backup Evidence"),
                    symbol: "clock.arrow.circlepath",
                    updatedAt: snapshot.backup.checkedAt
                ) {
                    evidenceValueRow(
                        label: L10n.text("备份目标", "Destination"),
                        value: destinationText(snapshot.backup.destinationState)
                    )
                    if let latest = snapshot.backup.latestCompleteBackup {
                        evidenceValueRow(
                            label: L10n.text("最近完整备份", "Latest Complete Backup"),
                            value: latest.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let running = snapshot.backup.isRunning {
                        evidenceValueRow(
                            label: L10n.text("当前状态", "Current State"),
                            value: running
                                ? L10n.text("正在备份", "Backing Up")
                                : L10n.text("空闲", "Idle")
                        )
                    }
                }

                evidencePanel(
                    title: L10n.text("稳定性证据（最近 30 天）", "Stability Evidence (30 days)"),
                    symbol: "waveform.path.ecg",
                    updatedAt: snapshot.stability.generatedAt
                ) {
                    evidenceValueRow(
                        label: L10n.text("崩溃", "Crashes"),
                        value: countText(snapshot.stability.crashCount)
                    )
                    evidenceValueRow(
                        label: L10n.text("卡死", "Hangs"),
                        value: countText(snapshot.stability.hangCount)
                    )
                    evidenceValueRow(
                        label: L10n.text("无响应采样", "Spins"),
                        value: countText(snapshot.stability.spinCount)
                    )
                    evidenceValueRow(
                        label: L10n.text("内核崩溃", "Kernel Panics"),
                        value: countText(snapshot.stability.panicCount)
                    )
                    evidenceValueRow(
                        label: L10n.text("意外重启", "Unexpected Restarts"),
                        value: countText(snapshot.stability.unexpectedRestartCount)
                    )
                }

                evidencePanel(
                    title: L10n.text("电池证据与安全引导", "Battery Evidence & Safe Guidance"),
                    symbol: "battery.75",
                    updatedAt: snapshot.batteryEvidence.checkedAt
                ) {
                    batteryEvidenceRows(snapshot.batteryEvidence)
                }
            }
        }
    }

    @ViewBuilder
    private func diskEvidenceRows(_ snapshot: DiskHealthSnapshot) -> some View {
        evidenceValueRow(label: "SMART", value: smartText(snapshot.smartStatus))
        if let value = snapshot.fileSystem {
            evidenceValueRow(label: L10n.text("文件系统", "File System"), value: value)
        }
        if let value = snapshot.isInternal {
            evidenceValueRow(
                label: L10n.text("位置", "Location"),
                value: value ? L10n.text("内置", "Internal") : L10n.text("外置", "External")
            )
        }
        if let value = snapshot.isSolidState {
            evidenceValueRow(label: L10n.text("介质", "Media"), value: value ? "SSD" : "HDD")
        }
        if let enabled = snapshot.isTRIMEnabled {
            evidenceValueRow(label: "TRIM", value: enabledText(enabled))
        }
        if let enabled = snapshot.isFileVaultEnabled {
            evidenceValueRow(label: "FileVault", value: enabledText(enabled))
        }
    }

    @ViewBuilder
    private func batteryEvidenceRows(_ evidence: BatteryHealthEvidence) -> some View {
        switch evidence {
        case .notPresent:
            evidenceValueRow(label: L10n.text("内置电池", "Internal Battery"), value: L10n.text("此 Mac 没有", "Not Present"))
        case .failed(let reason, _):
            evidenceValueRow(label: L10n.text("读取状态", "Probe Status"), value: batteryFailureText(reason))
        case .present(let snapshot):
            if let value = snapshot.currentChargePercent {
                evidenceValueRow(label: L10n.text("当前电量", "Current Charge"), value: "\(value)%")
            }
            if let value = snapshot.isCharging {
                evidenceValueRow(
                    label: L10n.text("充电状态", "Charging State"),
                    value: value ? L10n.text("正在充电", "Charging") : L10n.text("未在充电", "Not Charging")
                )
            }
            if let value = snapshot.powerSource {
                evidenceValueRow(label: L10n.text("电源来源", "Power Source"), value: powerSourceText(value))
            }
            if let minutes = snapshot.remainingTimeMinutes,
               let estimate = BatteryTimeEstimateResolver.resolve(
                   minutes: minutes,
                   isCharging: snapshot.isCharging,
                   powerSource: snapshot.powerSource
               ) {
                evidenceValueRow(
                    label: estimate.kind.localizedLabel,
                    value: remainingTimeText(estimate.minutes)
                )
            }
            if let value = snapshot.maximumCapacityPercent {
                evidenceValueRow(label: L10n.text("最大容量", "Maximum Capacity"), value: "\(value)%")
            }
            if let value = snapshot.cycleCount {
                evidenceValueRow(label: L10n.text("循环计数", "Cycle Count"), value: "\(value)")
            }
            if let value = snapshot.condition {
                evidenceValueRow(label: L10n.text("电池状况", "Condition"), value: batteryConditionText(value))
            }
            if let value = snapshot.batteryPowerMode {
                evidenceValueRow(label: L10n.text("电池供电模式", "On-battery Mode"), value: powerModeText(value))
            }
            if let value = snapshot.adapterPowerMode {
                evidenceValueRow(label: L10n.text("接电模式", "Power-adapter Mode"), value: powerModeText(value))
            }
            evidenceValueRow(label: L10n.text("磨损趋势", "Wear Trend"), value: batteryTrendText)

            Text(L10n.text(
                "只打开系统设置并在返回后核验变化；不会写入 SMC 或直接限制充电。",
                "Only opens System Settings and verifies changes after you return; it never writes SMC values or directly limits charging."
            ))
            .font(AppTypography.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if healthStore.batterySettingsAdjustmentState == .unverifiable {
                HStack(spacing: 8) {
                    Button(L10n.text("重试读取电源模式", "Retry Reading Power Mode")) {
                        Task { await healthStore.beginBatterySettingsAdjustment() }
                    }
                    if !hasDashboardBatteryAction {
                        Button(L10n.text(
                            "打开电池设置（无法自动核验）",
                            "Open Battery Settings (Automatic Verification Unavailable)"
                        )) {
                            healthStore.openBatterySettingsWithoutVerification()
                        }
                    }
                }
                .appButtonChrome(.secondary)
                .controlSize(.regular)
            } else if !hasDashboardBatteryAction {
                Button(batteryActionTitle) {
                    performBatterySafeAction()
                }
                .appButtonChrome(.secondary)
                .controlSize(.regular)
                .disabled(!batteryActionPresentation.isEnabled)
            }

            if let verification = batteryVerificationText {
                Text(verification)
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func evidencePanel<Content: View>(
        title: String,
        symbol: String,
        updatedAt: Date? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(AppDesignTokens.Typography.cardTitle)
                .foregroundStyle(AppDesignTokens.Palette.secondary)
            if let updatedAt {
                Text(L10n.text(
                    "更新于 \(updatedAt.formatted(date: .abbreviated, time: .shortened))",
                    "Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
                ))
                .font(AppTypography.body)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    private func environmentHeader(
        title: String,
        symbol: String,
        status: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(AppDesignTokens.Typography.sectionSymbol)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            Text(title)
                .font(AppDesignTokens.Typography.cardTitle)
            Spacer()
            Text(status)
                .font(AppTypography.body.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.09), in: Capsule())
        }
    }

    private func environmentMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).foregroundStyle(.secondary)
            }
            .font(AppTypography.body)
            Text(value)
                .font(AppDesignTokens.Typography.compactMetricValue)
                .foregroundStyle(tint)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.055),
            in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.settingsPanel)
        )
    }

    private func evidenceValueRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(AppDesignTokens.Typography.secondary)
    }

    private func perform(_ action: HealthDashboardSafeAction) {
        switch action {
        case .openDiskUtility:
            ComputerHealthSystemActions.open(.diskUtility)
        case .openSafeCleanup:
            scanStore.showFilter(.green)
        case .battery:
            batteryAction()
        case .openTimeMachineSettings:
            ComputerHealthSystemActions.open(.timeMachineSettings)
        case .openDiagnosticReports:
            ComputerHealthSystemActions.open(.diagnosticReports)
        }
    }

    private func batteryAction() {
        performBatterySafeAction()
    }

    private func performBatterySafeAction() {
        switch healthStore.batterySettingsAdjustmentState {
        case .awaitingVerification, .unchanged:
            Task { await healthStore.verifyBatterySettingsAfterReturn() }
        case .unverifiable:
            healthStore.openBatterySettingsWithoutVerification()
        case .openingSettings, .verifying:
            break
        case .idle, .expired, .verified, .failedToOpen:
            Task { await healthStore.beginBatterySettingsAdjustment() }
        }
    }

    private var batteryActionTitle: String {
        batteryActionPresentation.label.localizedTitle
    }

    private var batteryActionPresentation: BatterySettingsActionPresentation {
        BatterySettingsActionResolver.resolve(healthStore.batterySettingsAdjustmentState)
    }

    private var batteryVerificationText: String? {
        switch healthStore.batterySettingsAdjustmentState {
        case .idle: nil
        case .openingSettings: L10n.text("正在打开系统设置", "Opening System Settings")
        case .awaitingVerification: L10n.text("修改后返回本应用验证", "Return after making a change")
        case .verifying: L10n.text("正在读取并核对", "Reading and comparing")
        case .unchanged: L10n.text("未检测到变化，可再次验证", "No change detected; you can verify again")
        case .expired: L10n.text("验证超过 5 分钟，请重新建立基线", "Verification expired; establish a new baseline")
        case .unverifiable: L10n.text("当前电源模式无法自动读取，请在系统设置中手动核对", "Power mode cannot be read automatically; verify it manually in System Settings")
        case .verified: L10n.text("已验证真实设置变化", "Confirmed settings change")
        case .failedToOpen: L10n.text("未能打开系统设置", "Could not open System Settings")
        }
    }

    private var currentPowerStatusText: String {
        guard let evidence = healthStore.snapshot?.batteryEvidence else {
            return L10n.text("尚未检查", "Not Checked")
        }
        switch evidence {
        case .notPresent:
            return L10n.text("不适用", "Not Applicable")
        case .failed:
            return L10n.text("暂不可用", "Unavailable")
        case .present(let battery):
            if let charge = battery.currentChargePercent {
                return "\(charge)%"
            }
            return battery.powerSource.map(powerSourceText)
                ?? L10n.text("已读取", "Available")
        }
    }

    private var currentPowerStatusColor: Color {
        guard let evidence = healthStore.snapshot?.batteryEvidence,
              case .present = evidence else {
            return .secondary
        }
        return AppDesignTokens.Palette.information
    }

    private var networkStatusText: String {
        switch networkStore.state {
        case .idle: L10n.text("未测试", "Not Tested")
        case .running: L10n.text("测试中", "Testing")
        case .succeeded: L10n.text("已完成", "Completed")
        case .offline: L10n.text("离线", "Offline")
        case .timedOut: L10n.text("超时", "Timed Out")
        case .cancelled: L10n.text("已取消", "Cancelled")
        case .failed: L10n.text("未完成", "Failed")
        case .consentRequired: L10n.text("等待确认", "Consent Required")
        case .compatibilityAvailable: L10n.text("系统测速不可用", "System Test Unavailable")
        case .compatibilityConsentRequired: L10n.text("等待兼容测速确认", "Compatibility Consent Required")
        }
    }

    private var networkStatusColor: Color {
        switch networkStore.state {
        case .succeeded, .running: AppDesignTokens.Palette.information
        case .offline, .timedOut, .failed, .compatibilityAvailable: AppDesignTokens.Palette.warning
        case .idle, .cancelled, .consentRequired, .compatibilityConsentRequired: .secondary
        }
    }

    private var networkSummary: String {
        switch networkStore.state {
        case .idle: L10n.text("仅在你二次确认后产生测速流量。", "Traffic is generated only after your second confirmation.")
        case .running: L10n.text("正在测试，可随时取消。", "Testing now; you can cancel at any time.")
        case .succeeded: L10n.text("显示最近一次完整结果，不作为系统健康扣分项。", "Shows the latest complete result and never affects the system health score.")
        case .offline: L10n.text("当前网络不可用。", "The network appears to be offline.")
        case .timedOut: L10n.text("测试超时，没有保存不完整结果。", "The test timed out; no partial result was saved.")
        case .cancelled: L10n.text("测试已取消，没有保存不完整结果。", "The test was cancelled; no partial result was saved.")
        case .failed:
            networkStore.conflictMessage
                ?? L10n.text("测试未完成，请稍后重试。", "The test did not complete; try again later.")
        case .consentRequired: L10n.text("测速会产生流量，需要先确认。", "The test creates traffic and requires confirmation.")
        case .compatibilityAvailable:
            L10n.text(
                "macOS 系统测速服务当前不可用。可以重试系统测速，或另行确认使用兼容测速。",
                "The macOS system test service is unavailable. Retry it, or separately confirm the compatibility test."
            )
        case .compatibilityConsentRequired:
            L10n.text(
                "兼容测速会产生额外流量，需要再次确认。",
                "The compatibility test creates additional traffic and requires another confirmation."
            )
        }
    }

    private func thermalReadinessText(_ presentation: ThermalReadinessPresentation) -> String {
        switch presentation {
        case .notChecked: L10n.text("尚未检查", "Not Checked")
        case .stale: L10n.text("需要重新检查", "Check Again")
        case .current(.ready): L10n.text("就绪", "Ready")
        case .current(.elevated): L10n.text("温度升高", "Elevated")
        case .current(.constrained): L10n.text("性能受限", "Constrained")
        case .current(.critical): L10n.text("严重受限", "Critical")
        case .current(.unknown): L10n.text("未知", "Unknown")
        }
    }

    private func thermalReadinessColor(_ presentation: ThermalReadinessPresentation) -> Color {
        switch presentation {
        case .current(.ready): AppDesignTokens.Palette.success
        case .current(.elevated): AppDesignTokens.Palette.warning
        case .current(.constrained), .current(.critical): AppDesignTokens.Palette.destructive
        case .notChecked, .stale, .current(.unknown): .secondary
        }
    }

    private func thermalReadinessDetail(_ presentation: ThermalReadinessPresentation) -> String {
        switch presentation {
        case .notChecked:
            L10n.text(
                "开始健康检查后才读取即时热状态；首次打开不会推断为正常。",
                "The current thermal state is read only when you run a health check; first open is never inferred as healthy."
            )
        case .stale:
            L10n.text(
                "即时热状态已超过 10 分钟，请重新检查后再据此安排高负载操作。",
                "This live thermal state is over 10 minutes old. Check again before planning heavy work from it."
            )
        case .current(.ready):
            L10n.text("系统当前未报告明显的热限制。", "The system currently reports no material thermal constraint.")
        case .current(.elevated):
            L10n.text("温度已升高，重负载结果可能受到影响。", "Temperature is elevated and may affect heavy-work results.")
        case .current(.constrained):
            L10n.text("系统正在限制部分性能，建议先降低负载。", "The system is constraining performance; reduce workload first.")
        case .current(.critical):
            L10n.text("系统报告严重热限制，请停止高负载并让设备降温。", "The system reports critical thermal constraint; stop heavy work and let the Mac cool.")
        case .current(.unknown):
            L10n.text("本次没有可靠的即时热状态，不推断为正常。", "No reliable current thermal state is available, so it is not inferred as healthy.")
        }
    }

    private var storageForecastText: String {
        guard let forecast = healthStore.storageForecast else {
            return L10n.text("数据不足或趋势不稳定", "Insufficient or Unstable Trend")
        }
        if forecast.daysUntilPressure == 0 {
            return L10n.text("已进入压力区", "Already Under Pressure")
        }
        if forecast.daysUntilPressure > 365 {
            return L10n.text("超过一年", "More Than One Year")
        }
        if let earliest = forecast.earliestDaysUntilPressure,
           let latest = forecast.latestDaysUntilPressure {
            return L10n.text(
                "约 \(forecast.daysUntilPressure) 天（\(earliest)–\(latest) 天）",
                "About \(forecast.daysUntilPressure) days (\(earliest)–\(latest))"
            )
        }
        return L10n.text("约 \(forecast.daysUntilPressure) 天", "About \(forecast.daysUntilPressure) days")
    }

    private var batteryTrendText: String {
        guard let trend = healthStore.batteryTrend else {
            return L10n.text("样本不足或波动过大", "Insufficient or Noisy Samples")
        }
        let classification = switch trend.classification {
        case .stable: L10n.text("近期稳定", "Recently Stable")
        case .observe: L10n.text("建议观察", "Observe")
        case .decliningQuickly: L10n.text("下降较快", "Declining Quickly")
        }
        return L10n.text(
            "\(classification) · 90 日 \(String(format: "%.1f", trend.lossPer90Days)) 点 · 可信度 \(trend.confidence)%",
            "\(classification) · \(String(format: "%.1f", trend.lossPer90Days)) pts/90d · \(trend.confidence)% confidence"
        )
    }

    private func componentScoreText(_ component: HealthComponentEvaluation?) -> String {
        guard let component,
              component.availability == .available || component.availability == .partial,
              let score = component.score,
              score.isFinite else {
            return "—"
        }
        return "\(Int(score.rounded())) / 100"
    }

    private func weightedDeductionText(
        _ component: HealthComponentEvaluation?,
        factor: HealthFactor,
        accounting: ComputerHealthScoreAccounting
    ) -> String {
        guard component != nil,
              let deduction = accounting.component(for: factor)?.normalizedDeduction else {
            return L10n.text("不计分", "Not Scored")
        }
        return String(format: "−%.1f", deduction)
    }

    private func healthErrorText(_ error: ComputerHealthRefreshError) -> String {
        switch error {
        case .cancelled: L10n.text("检查已取消。", "The check was cancelled.")
        case .timedOut: L10n.text("部分系统检查超时。", "Some system checks timed out.")
        case .permissionDenied: L10n.text("部分系统信息没有读取权限。", "Some system information could not be read due to permissions.")
        case .readFailed: L10n.text("未能完成检查，请稍后重试。", "The check could not be completed; try again later.")
        }
    }

    private func smartText(_ value: DiskSMARTStatus) -> String {
        switch value {
        case .verified: L10n.text("已验证", "Verified")
        case .failing: L10n.text("需要处理", "Action Required")
        case .unsupported: L10n.text("系统不支持", "Unsupported")
        case .unavailable: L10n.text("未提供", "Unavailable")
        }
    }

    private func enabledText(_ enabled: Bool) -> String {
        enabled ? L10n.text("已启用", "Enabled") : L10n.text("未启用", "Disabled")
    }

    private func capacityDeltaText(_ value: Int64) -> String {
        if value == 0 { return L10n.text("无明显变化", "No Material Change") }
        let amount = ByteFormat.string(value == .min ? .max : abs(value))
        return value > 0
            ? L10n.text("可用增加 \(amount)", "Available Increased by \(amount)")
            : L10n.text("可用减少 \(amount)", "Available Decreased by \(amount)")
    }

    private func destinationText(_ value: TimeMachineDestinationState) -> String {
        switch value {
        case .configured: L10n.text("已配置", "Configured")
        case .unconfigured: L10n.text("未配置", "Not Configured")
        case .unreachable: L10n.text("无法连接", "Unreachable")
        case .permissionDenied: L10n.text("权限受限", "Permission Limited")
        case .timedOut: L10n.text("检查超时", "Check Timed Out")
        case .unavailable: L10n.text("未提供", "Unavailable")
        }
    }

    private func countText(_ count: Int?) -> String {
        count.map(String.init) ?? L10n.text("未提供", "Unavailable")
    }

    private func batteryConditionText(_ value: BatteryCondition) -> String {
        switch value {
        case .normal: L10n.text("正常", "Normal")
        case .serviceRecommended: L10n.text("建议检修", "Service Recommended")
        case .unknown: L10n.text("系统未明确", "Not Reported")
        }
    }

    private func batteryFailureText(_ value: BatteryHealthProbeFailureReason) -> String {
        switch value {
        case .permissionDenied: L10n.text("权限受限", "Permission Limited")
        case .timedOut: L10n.text("读取超时", "Timed Out")
        case .cancelled: L10n.text("已取消", "Cancelled")
        case .unavailable: L10n.text("系统未提供", "Unavailable")
        case .readFailed: L10n.text("读取失败", "Read Failed")
        }
    }

    private func powerModeText(_ value: BatteryPowerMode) -> String {
        switch value {
        case .lowPower: L10n.text("低电量", "Low Power")
        case .automatic: L10n.text("自动", "Automatic")
        case .highPower: L10n.text("高性能", "High Power")
        }
    }

    private func powerSourceText(_ value: BatteryPowerSource) -> String {
        switch value {
        case .acPower: L10n.text("电源适配器", "Power Adapter")
        case .batteryPower: L10n.text("电池", "Battery")
        case .unknown: L10n.text("系统未明确", "Not Reported")
        }
    }

    private func remainingTimeText(_ minutes: Int) -> String {
        let safeMinutes = max(0, minutes)
        let hours = safeMinutes / 60
        let remainder = safeMinutes % 60
        if hours == 0 {
            return L10n.text("\(remainder) 分钟", "\(remainder) min")
        }
        if remainder == 0 {
            return L10n.text("\(hours) 小时", "\(hours) hr")
        }
        return L10n.text(
            "\(hours) 小时 \(remainder) 分钟",
            "\(hours) hr \(remainder) min"
        )
    }

    private func speedText(_ value: Double) -> String {
        String(format: "%.1f Mbps", value)
    }
}

private enum ComputerHealthSystemAction {
    case diskUtility
    case timeMachineSettings
    case diagnosticReports
}

@MainActor
private enum ComputerHealthSystemActions {
    @discardableResult
    static func open(_ action: ComputerHealthSystemAction) -> Bool {
        switch action {
        case .diskUtility:
            return NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app", isDirectory: true)
            )
        case .timeMachineSettings:
            return openSettings(
                deepLink: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
            )
        case .diagnosticReports:
            let candidates = [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
                URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true),
            ]
            guard let folder = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) else { return false }
            return NSWorkspace.shared.open(folder)
        }
    }

    private static func openSettings(deepLink: String) -> Bool {
        if let url = URL(string: deepLink), NSWorkspace.shared.open(url) {
            return true
        }
        return NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true)
        )
    }
}

#if DEBUG
enum ComputerHealthDebugFixture: String, CaseIterable {
    case fullScore
    case dataInsufficient
    case smartFailing
    case noBattery
    case longLocalizedText
}

struct ComputerHealthDashboardDebugView: View {
    let fixture: ComputerHealthDebugFixture
    private let evaluation: ComputerHealthEvaluation
    private let history: [ComputerHealthHistoryEntry]
    private let actions: [HealthDashboardAction]
    private let batterySettingsState: BatterySettingsAdjustmentState

    init(fixture: ComputerHealthDebugFixture) {
        self.fixture = fixture
        let data = Self.makeData(fixture)
        self.evaluation = data.evaluation
        self.history = data.history
        self.actions = data.actions
        self.batterySettingsState = data.batterySettingsState
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HealthScoreHero(
                    evaluation: evaluation,
                    checkedAt: evaluation.evaluatedAt,
                    isRefreshing: false,
                    errorText: nil,
                    refreshTitle: L10n.text("重新检查", "Check Again"),
                    onRefresh: {}
                )
                if !actions.isEmpty {
                    HealthActionList(
                        actions: actions,
                        batterySettingsState: batterySettingsState,
                        perform: { _ in }
                    )
                }
                HealthTrendChart(evaluation: evaluation, history: history)
                HealthFactorGrid(evaluation: evaluation)
                debugEnvironmentSection
                debugEvidenceSection
                if fixture == .longLocalizedText {
                    Text(L10n.text(
                        "这是一段用于验证 980×680 窗口、超长中文说明和按钮标签不会互相覆盖的固定调试文本。",
                        "This fixed debug sentence verifies that very long localized explanations and button labels remain readable in a 980×680 window without overlapping adjacent controls."
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .frame(width: 980, alignment: .topLeading)
        }
        .frame(width: 980, height: 680)
    }

    private var debugEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(HealthDashboardText.environmentTitle, systemImage: "gauge.with.dots.needle.50percent")
                    .font(AppDesignTokens.Typography.sectionTitle)
                Spacer()
                Text(L10n.text(
                    "网络与即时热状态仅作环境参考，不改变核心健康分。",
                    "Network and live thermal state are environmental context and never alter the core score."
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320, maximum: 500), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                debugEnvironmentCard(
                    title: L10n.text("网络体验", "Network Experience"),
                    symbol: "network",
                    status: L10n.text("等待二次确认", "Awaiting Second Confirmation"),
                    detail: L10n.text(
                        "测速仅在再次确认后产生流量；这里同时验证很长的中英文环境说明可以自然换行。",
                        "Traffic is generated only after a second confirmation; this card also verifies that long localized environment guidance wraps without colliding with adjacent content."
                    )
                )
                debugEnvironmentCard(
                    title: L10n.text("热与性能就绪度", "Thermal & Performance Readiness"),
                    symbol: "thermometer.medium",
                    status: L10n.text("尚未检查", "Not Checked"),
                    detail: L10n.text(
                        "未知与过期状态保持中性，必须重新检查后才能据此安排高负载操作。",
                        "Unknown and stale readings stay neutral; run another check before using them to plan heavy work."
                    )
                )
            }
        }
    }

    private func debugEnvironmentCard(
        title: String,
        symbol: String,
        status: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(AppDesignTokens.Typography.cardTitle)
                Spacer(minLength: 8)
                Text(status)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text(detail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L10n.text("不计入核心健康分", "Excluded from Core Health Score"))
                .font(AppTypography.body)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius)
    }

    private var debugEvidenceSection: some View {
        DisclosureGroup(isExpanded: .constant(true)) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(evaluation.components, id: \.factor) { component in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(
                            HealthDashboardVisuals.factorTitle(component.factor),
                            systemImage: HealthDashboardVisuals.factorSymbol(component.factor)
                        )
                        .frame(minWidth: 150, alignment: .leading)
                        Text(HealthDashboardVisuals.availabilityText(component.availability))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(component.score.map { "\(Int($0.rounded())) / 100" } ?? "—")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(AppDesignTokens.Typography.secondary)
                }

                Divider()
                Text(L10n.text(
                    "原始证据示例：充电时显示预计充满，放电时才显示预计剩余；未知状态不会硬猜。",
                    "Raw evidence example: charging shows time until full, discharging shows time remaining, and unknown states are never guessed."
                ))
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        } label: {
            Label(HealthDashboardText.scoreEvidenceTitle, systemImage: "function")
                .font(AppDesignTokens.Typography.sectionTitle)
        }
        .padding(16)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius)
    }

    private struct DebugData {
        let evaluation: ComputerHealthEvaluation
        let history: [ComputerHealthHistoryEntry]
        let actions: [HealthDashboardAction]
        let batterySettingsState: BatterySettingsAdjustmentState
    }

    private static func makeData(_ fixture: ComputerHealthDebugFixture) -> DebugData {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let factorScores: [HealthFactor: (HealthEvidenceAvailability, Double?)] = switch fixture {
        case .fullScore:
            Dictionary(uniqueKeysWithValues: HealthFactor.allCases.map { ($0, (.available, 100)) })
        case .dataInsufficient:
            Dictionary(uniqueKeysWithValues: HealthFactor.allCases.map { ($0, (.unavailable, nil)) })
        case .smartFailing:
            [.diskReliability: (.available, 0), .capacity: (.available, 72), .stability: (.available, 90), .backup: (.available, 80), .battery: (.available, 88)]
        case .noBattery:
            [.diskReliability: (.available, 96), .capacity: (.available, 90), .stability: (.available, 92), .backup: (.available, 90), .battery: (.notApplicable, nil)]
        case .longLocalizedText:
            [.diskReliability: (.available, 88), .capacity: (.partial, 68), .stability: (.available, 75), .backup: (.available, 65), .battery: (.available, 40)]
        }
        let components = HealthFactor.allCases.map { factor in
            let value = factorScores[factor] ?? (.unavailable, nil)
            return HealthComponentEvaluation(
                factor: factor,
                availability: value.0,
                score: value.1,
                evaluatedAt: now,
                modelVersion: ComputerHealthEvaluation.currentModelVersion
            )
        }
        let numericScores = components.compactMap(\.score)
        let score: Double? = if fixture == .dataInsufficient {
            nil
        } else if fixture == .smartFailing {
            20
        } else {
            numericScores.reduce(0, +) / Double(max(numericScores.count, 1))
        }
        let status: ComputerHealthEvaluationStatus = if fixture == .dataInsufficient {
            .dataInsufficient
        } else if fixture == .smartFailing {
            .actionRequired
        } else if (score ?? 0) >= 85 {
            .healthy
        } else {
            .attention
        }
        let evaluation = ComputerHealthEvaluation(
            score: score,
            status: status,
            coverage: fixture == .dataInsufficient ? 0 : 1,
            confidence: HealthConfidence(
                value: fixture == .dataInsufficient ? 18 : 88,
                level: fixture == .dataInsufficient ? .low : .high,
                modelVersion: "health-confidence-v1"
            ),
            components: components,
            evaluatedAt: now
        )
        let history = [7, 14, 30].map { days in
            let date = now.addingTimeInterval(Double(-days) * 86_400)
            let historical = ComputerHealthEvaluation(
                score: score.map { min(100, max(0, $0 - Double(days) / 10)) },
                status: status,
                coverage: evaluation.coverage,
                confidence: evaluation.confidence,
                components: components,
                evaluatedAt: date
            )
            return ComputerHealthHistoryEntry(recordedAt: date, evaluation: historical)
        } + [ComputerHealthHistoryEntry(recordedAt: now, evaluation: evaluation)]
        let context = HealthDashboardActionContext(
            evaluation: evaluation,
            smartIsFailing: fixture == .smartFailing,
            isUnderCurrentCapacityPressure: false,
            batteryServiceRecommended: false,
            backupNeedsAttention: false,
            hasRecentPanicOrRestart: false,
            forecastDaysUntilPressure: nil
        )
        return DebugData(
            evaluation: evaluation,
            history: history,
            actions: HealthDashboardActionSelector.select(from: context),
            batterySettingsState: fixture == .longLocalizedText ? .unverifiable : .idle
        )
    }
}
#endif
