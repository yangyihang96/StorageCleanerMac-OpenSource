import SwiftUI

extension MenuBarAdvancedStatusView {
    private var geekPrimaryDiskRemainingLifePercent: Int? {
        computerHealthStore.snapshot?.disk.remainingLifePercent
            ?? healthSummary?.diskRemainingLifePercent
    }

    private var geekPrimaryDiskSMARTStatus: DiskSMARTStatus {
        if let current = computerHealthStore.snapshot?.disk.smartStatus,
           current != .unavailable {
            return current
        }
        return healthSummary?.diskSMARTStatus ?? .unavailable
    }

    var geekPrimaryDiskHealthText: String? {
        if let remainingLifePercent = geekPrimaryDiskRemainingLifePercent {
            return "\(min(100, max(0, remainingLifePercent)))%"
        }
        switch geekPrimaryDiskSMARTStatus {
        case .verified:
            return L10n.text("正常", "Normal")
        case .failing:
            return L10n.text("需注意", "Attention")
        case .unsupported:
            return L10n.text("不支持", "Unsupported")
        case .unavailable:
            return nil
        }
    }

    var geekPrimaryDiskHealthTint: Color {
        switch geekPrimaryDiskSMARTStatus {
        case .verified:
            return AppDesignTokens.Palette.success
        case .failing:
            return AppDesignTokens.Palette.destructive
        case .unsupported:
            return AppDesignTokens.Palette.warning
        case .unavailable:
            return .secondary
        }
    }

    var geekDiskPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.capacity) {
                VStack(spacing: GeekPanelLayout.detailSpacing) {
            geekDiskVolumeList
            if !geekNetworkDiskVolumes.isEmpty {
                geekNetworkDiskSection
            }
                }
            }
            liveCard(.diskIO) { geekDiskIOHoverTarget }
            if showsExtendedGeekDetails {
                liveCard(.energyProcesses) { geekDiskProcessCard }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)

    }

    private var geekDiskIOHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("磁盘 I/O 三级详情", "Disk I/O Deep Detail"),
            chartRangeMetric: .disk,
            popoverSize: GeekHoverDetailMetrics.diskIOSize
        ) {
            geekDiskTrend
        } detail: {
            GeekDiskIOHoverDetail(
                points: geekChartDiskHistory,
                counters: nativeDiskIOCounters,
                duration: geekChartDuration
            )
        }
    }

    private var geekDiskVolumeList: some View {
        Group {
            if geekDiskVolumes.isEmpty {
                GeekCombinedCard(height: 42) {
                    GeekDiskLoadingRow()
                }
            } else {
                VStack(spacing: GeekPanelLayout.detailSpacing) {
                    ForEach(Array(geekDiskVolumes.enumerated()), id: \.element.id) {
                        index,
                        volume in
                        geekDiskVolumeHoverTarget(index: index, volume: volume)
                    }
                }
            }
        }
    }

    private func geekDiskVolumeHoverTarget(
        index: Int,
        volume: GeekDiskVolumePresentation
    ) -> some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text(
                "\(volume.name) 磁盘卷三级详情",
                "\(volume.name) Disk Volume Deep Detail"
            ),
            popoverSize: volume.isNetwork && volume.capacity == nil
                ? CGSize(width: 220, height: 100) : GeekHoverDetailMetrics.volumeSize,
            sourceOffset: CGFloat(index) * (42 + GeekPanelLayout.detailSpacing)
        ) {
            GeekDiskVolumeSummary(volume: volume)
        } detail: {
            GeekDiskVolumeHoverDetail(
                snapshot: volume.capacity,
                volumeName: volume.name,
                status: volume.healthText,
                temperature: volume.temperature,
                healthCheckedAt: volume.healthCheckedAt,
                showsHealthTimestamp: !volume.isNetwork,
                isNetwork: volume.isNetwork
            )
        }
    }

    private var geekNetworkDiskSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(
                L10n.text("网络硬盘", "Network Drives"),
                systemImage: AppSymbols.Panel.networkGlobe
            )
            .font(AdvancedPanelTypography.captionStrong)
            .foregroundStyle(storageTint)
            .padding(.horizontal, 2)

            VStack(spacing: GeekPanelLayout.detailSpacing) {
                ForEach(Array(geekNetworkDiskVolumes.enumerated()), id: \.element.id) { index, volume in
                    geekDiskVolumeHoverTarget(index: index, volume: volume)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("网络硬盘", "Network Drives"))
    }

    private var geekDiskVolumes: [GeekDiskVolumePresentation] {
        var volumes: [GeekDiskVolumePresentation] = []
        if let storageSnapshot {
            let diskHealth = computerHealthStore.snapshot?.disk
            let smartStatus = diskHealth?.smartStatus
                ?? healthSummary?.diskSMARTStatus
                ?? .unavailable
            volumes.append(GeekDiskVolumePresentation(
                id: "/",
                name: volumeName,
                capacity: storageSnapshot,
                healthText: diskHealthText(
                    smartStatus: smartStatus,
                    remainingLifePercent: geekPrimaryDiskRemainingLifePercent
                ),
                smartStatus: smartStatus,
                temperature: diskHealth?.temperatureCelsius.map {
                    "\(Int($0.rounded()))°"
                } ?? monitorSnapshot?.temperatureReadings?
                    .first { $0.zone == .storage }
                    .map { "\(Int($0.celsius.rounded()))°" },
                isNetwork: false,
                healthCheckedAt: GeekDiskHealthTimestamp.checkedAt(
                    snapshot: diskHealth,
                    fallbackRemainingLifePercent: healthSummary?.diskRemainingLifePercent
                )
            ))
        }
        volumes.append(contentsOf: externalStorageVolumes.map { volume in
            return GeekDiskVolumePresentation(
                id: volume.id,
                name: volume.name,
                capacity: volume.capacity,
                healthText: diskHealthText(
                    smartStatus: volume.health.smartStatus,
                    remainingLifePercent: volume.remainingLifePercent
                ),
                smartStatus: volume.health.smartStatus,
                temperature: volume.temperatureCelsius.map {
                    "\(Int($0.rounded()))°"
                },
                isNetwork: false,
                healthCheckedAt: volume.health.checkedAt
            )
        })
        return volumes
    }

    private var geekNetworkDiskVolumes: [GeekDiskVolumePresentation] {
        networkStorageVolumes.map { volume in
            GeekDiskVolumePresentation(
                id: volume.id,
                name: volume.name,
                capacity: volume.capacity,
                healthText: L10n.text("已连接", "Connected"),
                smartStatus: .unavailable,
                temperature: nil,
                isNetwork: true
            )
        }
    }

    private func diskHealthText(
        smartStatus: DiskSMARTStatus,
        remainingLifePercent: Int?
    ) -> String {
        guard let remainingLifePercent else {
            return diskSMARTStatusText(smartStatus)
        }
        return L10n.text(
            "健康度 \(remainingLifePercent)%",
            "Health \(remainingLifePercent)%"
        )
    }

    private var geekDiskTrend: some View {
        GeekCombinedCard(height: 130) {
            VStack(spacing: 3) {
                HStack(spacing: 12) {
                    GeekDiskLiveMetric(
                        title: L10n.text("读取", "Read"),
                        value: geekDiskReadRateText,
                        color: resolvedSecondaryTint
                    )
                    GeekDiskLiveMetric(
                        title: L10n.text("写入", "Write"),
                        value: geekDiskWriteRateText,
                        color: resolvedPrimaryTint
                    )
                }

                GeekDiskIOChart(
                    points: geekChartDiskHistory,
                    accessibilityLabel: L10n.text(
                        "最近 \(geekChartRangeTitle) 的磁盘读取与写入趋势",
                        "Disk read and write trends over the last \(geekChartRangeTitle)"
                    ),
                    duration: geekChartDuration,
                    showsLegend: false,
                    showsTimelineLabels: false,
                    horizontalInset: 0
                )
                .frame(height: 60)

                HStack(spacing: 14) {
                    GeekDiskInlineMetric(
                        title: L10n.text("读取峰值", "Read Peak"),
                        value: geekDiskReadPeakText
                    )
                    GeekDiskInlineMetric(
                        title: L10n.text("写入峰值", "Write Peak"),
                        value: geekDiskWritePeakText
                    )
                }
            }
        }
    }

    private var geekDiskProcessCard: some View {
        GeekCombinedCard(height: 110) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.text("进程", "PROCESSES"))
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(storageTint)
                        .lineLimit(1)
                        .help(L10n.text(
                            "按需快照 · \(geekOnDemandSnapshotStatusText)",
                            "On-demand snapshot · \(geekOnDemandSnapshotStatusText)"
                        ))
                        .accessibilityValue(geekOnDemandSnapshotStatusText)

                    Spacer(minLength: 4)
                    Text(geekOnDemandSnapshotStatusText)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(L10n.text("读", "R"))
                        .font(AdvancedPanelTypography.body)
                        .foregroundStyle(storageTint)
                        .frame(width: 54, alignment: .trailing)
                    Text(L10n.text("写", "W"))
                        .font(AdvancedPanelTypography.body)
                        .foregroundStyle(storageTint)
                        .frame(width: 54, alignment: .trailing)
                }

                if geekDiskApps.isEmpty {
                    Group {
                        if store.isLoadingEnergyImpact {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 1) {
                        ForEach(geekDiskApps) { app in
                            GeekDiskProcessRow(app: app)
                        }
                    }
                }
            }
        }
    }

    private var geekDiskApps: [EnergyImpactApp] {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return geekEnergyApps }
#endif
        return store.menuBarPreparedProcesses?.disk ?? []
    }

    private var geekDiskReadPeakText: String {
        guard let peak = geekChartDiskHistory.map(\.readBytesPerSecond).max() else {
            return "--"
        }
        return "\(ByteFormat.string(peak))/s"
    }

    private var geekDiskWritePeakText: String {
        guard let peak = geekChartDiskHistory.map(\.writeBytesPerSecond).max() else {
            return "--"
        }
        return "\(ByteFormat.string(peak))/s"
    }
}

struct GeekDiskVolumePresentation: Identifiable, Equatable {
    let id: String
    let name: String
    let capacity: StorageCapacitySnapshot?
    let healthText: String
    let smartStatus: DiskSMARTStatus
    let temperature: String?
    let isNetwork: Bool
    var healthCheckedAt: Date? = nil
}

enum GeekDiskHealthTimestamp {
    static func checkedAt(
        snapshot: DiskHealthSnapshot?,
        fallbackRemainingLifePercent: Int?
    ) -> Date? {
        guard let snapshot else { return nil }
        // A retained wear reading can predate this snapshot. The summary's
        // generatedAt also changes for network tests, so it is not a disk date.
        if snapshot.remainingLifePercent == nil, fallbackRemainingLifePercent != nil { return nil }
        return snapshot.checkedAt
    }

    static func ageText(_ checkedAt: Date?, now: Date = Date()) -> String {
        guard let checkedAt else { return L10n.text("时间未知", "Time unknown") }
        let age = now.timeIntervalSince(checkedAt)
        guard age.isFinite, age >= 0, age < Double(Int.max) else {
            return L10n.text("时间未知", "Time unknown")
        }
        if age < 60 { return L10n.text("刚读取", "Just read") }
        if age < 3_600 { return L10n.text("\(Int(age / 60)) 分钟前", "\(Int(age / 60)) min ago") }
        if age < 86_400 { return L10n.text("\(Int(age / 3_600)) 小时前", "\(Int(age / 3_600)) hr ago") }
        return L10n.text("\(Int(age / 86_400)) 天前", "\(Int(age / 86_400)) days ago")
    }

    static func detailText(_ checkedAt: Date?, now: Date = Date()) -> String {
        guard let checkedAt, checkedAt.timeIntervalSinceReferenceDate.isFinite else {
            return L10n.text("健康读取时间未知", "Health read time unknown")
        }
        let timestamp = checkedAt.formatted(date: .numeric, time: .standard)
        return L10n.text("健康读取：\(timestamp)", "Health read: \(timestamp)")
            + " · " + ageText(checkedAt, now: now)
    }
}

private struct GeekDiskVolumeSummary: View {
    let volume: GeekDiskVolumePresentation

    private var capacityTint: Color {
        guard let capacity = volume.capacity else { return .secondary }
        return switch capacity.pressure {
        case .normal:
            AppChartPalette.primary
        case .attention:
            .orange
        case .critical:
            .red
        }
    }

    private var healthTint: Color {
        if volume.isNetwork { return AppDesignTokens.Palette.information }
        return switch volume.smartStatus {
        case .verified:
            .green
        case .failing:
            .red
        case .unsupported:
            .orange
        case .unavailable:
            .secondary
        }
    }

    var body: some View {
        GeekCombinedCard(height: 42) {
            HStack(spacing: 8) {
                Image(systemName: volume.isNetwork
                    ? AppSymbols.Panel.networkGlobe
                    : AppSymbols.Monitor.storage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(capacityTint)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text(volume.name)
                        .font(AdvancedPanelTypography.captionStrong)
                        .lineLimit(1)

                    Text(volume.capacity.map { capacity in
                        L10n.text(
                            "\(capacity.userUsedPercent)% 已用 · \(ByteFormat.storageString(capacity.userAvailableBytes)) 可用",
                            "\(capacity.userUsedPercent)% used · \(ByteFormat.storageString(capacity.userAvailableBytes)) available"
                        )
                    } ?? L10n.text("容量 —", "Capacity —"))
                    .font(AdvancedPanelTypography.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                    if volume.isNetwork {
                        Image(systemName: AppSymbols.Panel.networkGlobe)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(healthTint)
                    } else {
                        Circle()
                            .fill(healthTint)
                            .frame(width: 7, height: 7)
                    }
                    Text(volume.healthText)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                    if !volume.isNetwork {
                        Text(GeekDiskHealthTimestamp.ageText(volume.healthCheckedAt))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                    .help(volume.isNetwork ? volume.healthText
                        : volume.healthText + " · " + GeekDiskHealthTimestamp.detailText(volume.healthCheckedAt))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(volume.isNetwork
                        ? L10n.text("网络硬盘状态", "Network drive status")
                        : L10n.text("磁盘健康状态", "Disk health"))
                    .accessibilityValue(volume.isNetwork ? volume.healthText
                        : volume.healthText + " · " + GeekDiskHealthTimestamp.detailText(volume.healthCheckedAt))
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct GeekDiskLiveMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)

            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(AdvancedPanelTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct GeekDiskInlineMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(AdvancedPanelTypography.captionStrong)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct GeekDiskProcessRow: View {
    let app: EnergyImpactApp

    var body: some View {
        HStack(spacing: 6) {
            AdvancedAppIcon(path: app.iconPath, fallback: "app.fill")
                .scaleEffect(0.62)
                .frame(width: 14, height: 14)

            Text(app.name)
                .font(AdvancedPanelTypography.body)
                .lineLimit(1)

            Spacer(minLength: 3)

            Text(ByteFormat.string(app.diskReadBytesPerSecond))
                .font(AdvancedPanelTypography.body)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 54, alignment: .trailing)

            Text(ByteFormat.string(app.diskWriteBytesPerSecond))
                .font(AdvancedPanelTypography.body)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 54, alignment: .trailing)
        }
        .frame(minHeight: 14)
        .help(L10n.text("近期按需磁盘测量", "Latest on-demand disk measurement"))
        .accessibilityElement(children: .combine)
    }
}

private struct GeekDiskLoadingRow: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityLabel(L10n.text("正在采样", "Sampling"))
    }
}
