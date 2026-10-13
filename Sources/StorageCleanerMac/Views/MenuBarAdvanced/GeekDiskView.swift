import SwiftUI

/// One display budget for the existing disk and network secondary tables.
/// These values only format prepared snapshots; they never read the system.
enum GeekSecondaryTransferLayout {
    static let numberFontSize: CGFloat = 18
    static let unitFontSize: CGFloat = 12
    static let minimumScale: CGFloat = 0.75
    static let indicatorSize: CGFloat = 8
    static let processNumberFontSize: CGFloat = 11
    static let processUnitFontSize: CGFloat = 10
    static let processMinimumScale: CGFloat = 0.9
    static let processIconSize = MiniWindowStyleTokens.processIconSize
    static let processRowHeight = MiniWindowStyleTokens.dataRowHeight
    static let processSpacing = MiniWindowStyleTokens.rowSpacing
    static let processValueColumnWidth: CGFloat = 60

    static func processByteString(_ bytes: Int64) -> String {
        // Retain the existing byte presentation through TiB. Its unit list
        // ends there; larger real counters need PiB/EiB instead of an
        // unbounded seven-digit TiB value in the same native table column.
        let pebibyte: Int64 = 1 << 50
        guard bytes >= pebibyte else { return ByteFormat.string(bytes) }
        let exbibyte: Int64 = 1 << 60
        let divisor = bytes >= exbibyte ? exbibyte : pebibyte
        return String(format: "%.1f %@", Double(bytes) / Double(divisor),
                      bytes >= exbibyte ? "EiB" : "PiB")
    }

    static func processCardHeight(rowCount: Int) -> CGFloat {
        let rows = max(1, rowCount)
        return 2 * MiniWindowStyleTokens.cardVerticalInset
            + processRowHeight + processSpacing
            + CGFloat(rows) * processRowHeight
            + CGFloat(rows - 1) * processSpacing
    }
}

enum GeekDiskVolumeLayout {
    static let ringSize: CGFloat = 35
    static let cardHeight = ringSize + 2 * MiniWindowStyleTokens.cardVerticalInset
}

/// The original disk reference allocates its extra height to the I/O plot,
/// rather than to an empty spacer. These slots are display-only; the existing
/// secondary-content measurement still owns the available-screen fallback.
enum GeekDiskIOCardLayout {
    static let cardHeight: CGFloat = 180
    static let readoutHeight: CGFloat = 36
    static let chartHeight: CGFloat = 110
    static let peakHeight: CGFloat = 16
    static let spacing: CGFloat = 3
}

enum GeekDiskIOCardSelection {
    static func isSelected(route: GeekPanelRoute, requestID: UUID?, metric: GeekChartRangeMetric?) -> Bool {
        guard case let .history(module: .disk, selection: .inline(routeID)) = route,
              let requestID, routeID == requestID, metric == .disk else { return false }
        return true
    }
}

struct GeekDiskPeakRow: View {
    let readPeak: String
    let writePeak: String

    var body: some View {
        HStack(spacing: 14) {
            GeekDiskInlineMetric(title: L10n.text("读取峰值", "Read Peak"), value: readPeak)
            GeekDiskInlineMetric(title: L10n.text("写入峰值", "Write Peak"), value: writePeak)
        }
    }
}

/// Share the combined plot's existing worker/cache. The fixed row remains in
/// place while a first summary is prepared; no history walk occurs in body.
struct GeekPreparedDiskPeakRow: View {
    let points: [NativeDiskIOPoint]
    let duration: TimeInterval

    var body: some View {
        GeekLiveChartTimeline(duration: duration) { referenceDate in
            MenuBarChartPreparation(kind: GeekPreparedDiskSummary.preparationKind,
                first: points.first?.date, last: points.last?.date, count: points.count,
                configuration: GeekPreparedDiskSummary.preparationConfiguration(duration: duration),
                shape: GeekPreparedDiskSummary.preparationShape,
                clockRevision: referenceDate.timeIntervalSince1970, cost: 512,
                build: { GeekPreparedDiskSummary(points: points, duration: duration, referenceDate: referenceDate) },
                placeholder: AnyView(GeekDiskPeakRow(readPeak: "--", writePeak: "--"))) { summary in
                GeekDiskPeakRow(readPeak: summary.readPeakText, writePeak: summary.writePeakText)
            }
        }
    }
}

struct GeekDiskIOCard<Read: View, Write: View, Chart: View, Peak: View>: View {
    private let read: Read
    private let write: Write
    private let chart: Chart
    private let peak: Peak

    init(
        @ViewBuilder read: () -> Read,
        @ViewBuilder write: () -> Write,
        @ViewBuilder chart: () -> Chart,
        @ViewBuilder peak: () -> Peak
    ) {
        self.read = read()
        self.write = write()
        self.chart = chart()
        self.peak = peak()
    }

    var body: some View {
        GeekCombinedCard(height: GeekDiskIOCardLayout.cardHeight) {
            VStack(spacing: GeekDiskIOCardLayout.spacing) {
                HStack(spacing: 12) {
                    read
                    write
                }
                .frame(height: GeekDiskIOCardLayout.readoutHeight)

                chart.frame(height: GeekDiskIOCardLayout.chartHeight)

                peak.frame(height: GeekDiskIOCardLayout.peakHeight)
            }
        }
    }
}

/// One wording for the capacity figures shared by the overview card, the
/// volume rows and the volume inspector.
enum GeekDiskCapacityWording {
    /// "可用" is the important-usage capacity, which includes space macOS can
    /// purge on demand; `df` and the inspector's 当前严格空闲 report less.
    static var availableHelp: String {
        L10n.text(
            "可用含可清除空间（macOS 可按需清除的缓存、本地快照等），因此通常大于 df 显示的空闲空间；悬停磁盘卷可查看当前严格空闲与可回收估算。",
            "Available includes purgeable space (caches, local snapshots and other data macOS can clear on demand), so it is usually larger than the free space df reports; hover a volume for strict free space and the reclaimable estimate."
        )
    }

    /// The volume row's ring shows the used share, so its text names it.
    /// "Available" is the same important-usage figure that `availableHelp`
    /// explains (not the smaller strict free space).
    static func volumeSummary(usedPercent: Int, available: String) -> String {
        L10n.text("\(usedPercent)% 已用 · \(available) 可用", "\(usedPercent)% used · \(available) available")
    }
}

/// Volume risk remains a capacity-specific signal. It must never recolor the
/// neighbouring network/process section headings or the read/write columns.
enum GeekDiskVolumeColors {
    static func capacityTint(
        volume: GeekDiskVolumePresentation,
        metricColors: PanelMetricColors
    ) -> Color {
        guard volume.usageProgress != nil, let capacity = volume.capacity else { return .secondary }
        return capacityTint(capacity: capacity, metricColors: metricColors)
    }

    /// The used share's color: the level-two volume ring and the level-one
    /// disk bar (D14) show the same quantity and share this exit.
    static func capacityTint(
        capacity: StorageCapacitySnapshot,
        metricColors: PanelMetricColors
    ) -> Color {
        switch capacity.pressure {
        case .normal: metricColors.diskWrite
        case .attention: .orange
        case .critical: .red
        }
    }
}

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
            liveCard(.diskIO) { geekDiskTrend }
                .environment(\.geekCombinedCardIsSelected, GeekDiskIOCardSelection.isSelected(
                    route: panelCoordinator.route,
                    requestID: activeInlineTertiaryRequest?.id,
                    metric: activeInlineTertiaryRequest?.chartRangeMetric
                ))
            if showsExtendedGeekDetails {
                liveCard(.energyProcesses) { geekDiskProcessCard }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)

    }

    private var geekDiskVolumeList: some View {
        Group {
            if geekDiskVolumes.isEmpty {
                GeekCombinedCard(height: GeekDiskVolumeLayout.cardHeight) {
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
            sourceOffset: CGFloat(index) * (GeekDiskVolumeLayout.cardHeight + GeekPanelLayout.detailSpacing)
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
            Text(L10n.text("网络硬盘", "Network Drives"))
            .font(AdvancedPanelTypography.captionStrong)
            .foregroundStyle(panelMetricColors.sectionHeader)
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
        networkStorageVolumes.filter {
            GeekDiskVolumePresentation.hasReadableCapacity($0.capacity)
        }.map { volume in
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
        GeekDiskIOCard {
            geekDiskThroughputHoverTarget(.read)
        } write: {
            geekDiskThroughputHoverTarget(.write)
        } chart: {
            GeekHoverDetailTarget(
                accessibilityLabel: L10n.text("磁盘 I/O 三级详情", "Disk I/O Deep Detail"),
                chartRangeMetric: .disk,
                popoverSize: GeekHoverDetailMetrics.diskIOSize,
                usesCardActiveBorder: true
            ) {
                GeekDiskIOChart(
                    points: geekChartDiskHistory,
                    accessibilityLabel: L10n.text(
                        "最近 \(geekMetricRange(.disk).title) 的磁盘读取与写入趋势",
                        "Disk read and write trends over the last \(geekMetricRange(.disk).title)"
                    ),
                    duration: geekMetricRange(.disk).duration,
                    showsLegend: false,
                    showsTimelineLabels: false,
                    horizontalInset: 0
                )
            } detail: {
                GeekDiskIOHoverDetail(
                    points: geekChartDiskHistory,
                    counters: nativeDiskIOCounters,
                    duration: geekMetricRange(.disk).duration
                )
            }
        } peak: {
            GeekPreparedDiskPeakRow(points: geekChartDiskHistory, duration: geekMetricRange(.disk).duration)
        }
    }

    private func geekDiskThroughputHoverTarget(_ mode: GeekDiskIOChartMode) -> some View {
        GeekHoverDetailTarget(
            accessibilityLabel: mode == .read
                ? L10n.text("磁盘读取三级详情", "Disk Read Deep Detail")
                : L10n.text("磁盘写入三级详情", "Disk Write Deep Detail"),
            chartRangeMetric: .disk,
            popoverSize: GeekHoverDetailMetrics.diskIOSize,
            usesCardActiveBorder: true
        ) {
            GeekSecondaryTransferValue(
                title: mode == .read ? L10n.text("读取", "Read") : L10n.text("写入", "Write"),
                value: mode == .read ? geekDiskReadRateText : geekDiskWriteRateText,
                tint: mode == .read ? panelMetricColors.diskRead : panelMetricColors.diskWrite
            )
        } detail: {
            GeekDiskThroughputHoverDetail(
                points: geekChartDiskHistory,
                counters: nativeDiskIOCounters,
                duration: geekMetricRange(.disk).duration,
                mode: mode
            )
        }
    }

    private var geekDiskProcessCard: some View {
        GeekCombinedCard(height: GeekSecondaryTransferLayout.processCardHeight(rowCount: geekDiskApps.count)) {
            VStack(alignment: .leading, spacing: GeekSecondaryTransferLayout.processSpacing) {
                GeekProcessListHeader(
                    title: L10n.text("进程", "PROCESSES"),
                    status: geekOnDemandSnapshotStatusText,
                    help: L10n.text(
                        "按需快照 · \(geekOnDemandSnapshotStatusText)\(GeekOnDemandSnapshotFreshness.nothingMeasuredReason(geekOnDemandSnapshotNothingMeasured))",
                        "On-demand snapshot · \(geekOnDemandSnapshotStatusText)\(GeekOnDemandSnapshotFreshness.nothingMeasuredReason(geekOnDemandSnapshotNothingMeasured))"
                    ),
                    columns: [
                        GeekProcessListColumn(id: "read", title: L10n.text("读取", "Read"),
                                              tint: panelMetricColors.diskRead,
                                              accessibilityLabel: L10n.text("读取速率", "Read rate")),
                        GeekProcessListColumn(id: "write", title: L10n.text("写入", "Write"),
                                              tint: panelMetricColors.diskWrite,
                                              accessibilityLabel: L10n.text("写入速率", "Write rate")),
                    ]
                )
                .frame(height: GeekSecondaryTransferLayout.processRowHeight)

                if geekDiskApps.isEmpty {
                    Group {
                        if store.isLoadingEnergyImpact || store.isMenuBarProcessSamplePending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            // Review P2-8: why the list is empty.
                            Text(geekOnDemandSnapshotNothingMeasured
                                 ? GeekOnDemandSnapshotFreshness.nothingMeasuredText : "—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: GeekSecondaryTransferLayout.processSpacing) {
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
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.preparedProcesses.disk }
#endif
        return store.menuBarPreparedProcesses?.disk ?? []
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

    static func hasReadableCapacity(_ capacity: StorageCapacitySnapshot?) -> Bool {
        (capacity?.totalBytes ?? 0) > 0
    }

    var usagePercent: Int? {
        guard Self.hasReadableCapacity(capacity) else { return nil }
        return capacity?.userUsedPercent
    }

    var usageProgress: Double? {
        guard Self.hasReadableCapacity(capacity) else { return nil }
        return capacity?.userUsedRatio
    }
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

struct GeekDiskVolumeSummary: View {
    @Environment(\.panelMetricColors) private var metricColors
    let volume: GeekDiskVolumePresentation

    private var capacityTint: Color {
        GeekDiskVolumeColors.capacityTint(volume: volume, metricColors: metricColors)
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
        GeekCombinedCard(height: GeekDiskVolumeLayout.cardHeight) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                GeekDiskVolumeCapacityRing(volume: volume, tint: capacityTint)
                if volume.isNetwork {
                    AppSymbolGlyph(
                        systemImage: AppSymbols.Panel.networkGlobe,
                        size: MiniWindowStyleTokens.moduleIconSlotSize,
                        weight: .medium
                    )
                    .foregroundStyle(capacityTint)
                    .frame(width: MiniWindowStyleTokens.moduleIconSlotSize, height: MiniWindowStyleTokens.moduleIconSlotSize)
                    .accessibilityHidden(true)
                }

                // Two lines beside the ring: the name with the health status,
                // then the capacity summary with the health reading's age. The
                // summary keeps its full width and font ("100% used · 999.99 GB
                // available" fits); a long name truncates, and the age gives
                // way when both cannot fit (it stays in help and VoiceOver).
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: MiniWindowStyleTokens.inlineSpacing) {
                        Text(volume.name)
                            .font(AdvancedPanelTypography.captionStrong)
                            .lineLimit(1)
                        Spacer(minLength: MiniWindowStyleTokens.rowSpacing)
                        healthStatus
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: MiniWindowStyleTokens.inlineSpacing) {
                            capacitySummary
                            if !volume.isNetwork {
                                Spacer(minLength: MiniWindowStyleTokens.rowSpacing)
                                Text(GeekDiskHealthTimestamp.ageText(volume.healthCheckedAt))
                                    .font(AdvancedPanelTypography.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                        capacitySummary
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var capacitySummary: some View {
        Text(volume.usagePercent.flatMap { percent in volume.capacity.map { (percent, $0) } }.map { percent, capacity in
            GeekDiskCapacityWording.volumeSummary(
                usedPercent: percent,
                available: ByteFormat.storageString(capacity.userAvailableBytes)
            )
        } ?? L10n.text("容量 —", "Capacity —"))
        .font(AdvancedPanelTypography.body)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        // Never a smaller font or an ellipsis for the capacity figures.
        .fixedSize()
        .help(GeekDiskCapacityWording.availableHelp)
        .diskVolumeLayoutProbe("disk-volume.summary")
    }

    private var healthStatus: some View {
        HStack(spacing: MiniWindowStyleTokens.rowSpacing) {
            if volume.isNetwork {
                AppSymbolGlyph(systemImage: AppSymbols.Panel.networkGlobe, size: 8, weight: .medium)
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
        .fixedSize()
        .help(healthDetail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(volume.isNetwork
            ? L10n.text("网络硬盘状态", "Network drive status")
            : L10n.text("磁盘健康状态", "Disk health"))
        .accessibilityValue(healthDetail)
    }

    private var healthDetail: String {
        volume.isNetwork ? volume.healthText
            : volume.healthText + " · " + GeekDiskHealthTimestamp.detailText(volume.healthCheckedAt)
    }
}

private extension View {
    @ViewBuilder
    func diskVolumeLayoutProbe(_ id: String) -> some View {
        #if DEBUG
        layoutProbe(id)
        #else
        self
        #endif
    }
}

struct GeekDiskVolumeCapacityRing: View {
    let volume: GeekDiskVolumePresentation
    let tint: Color

    var body: some View {
        GeekCombinedRing(
            title: "", value: volume.usagePercent.map { "\($0)%" } ?? "—",
            progress: volume.usageProgress, tint: tint, size: GeekDiskVolumeLayout.ringSize
        )
        .accessibilityLabel(L10n.text("\(volume.name)容量占用", "\(volume.name) capacity used"))
    }
}

struct GeekSecondaryTransferReadout: View {
    let value: String
    var numberFontSize = GeekSecondaryTransferLayout.numberFontSize
    var unitFontSize = GeekSecondaryTransferLayout.unitFontSize
    var minimumScale = GeekSecondaryTransferLayout.minimumScale

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "--" ? "—" : trimmed
    }

    var body: some View {
        let parts = GeekCombinedRing.splitReadout(displayValue)
        return (Text(parts?.number ?? displayValue).font(.system(size: numberFontSize, weight: .regular))
            + Text(parts.map { $0.unit.isEmpty ? "" : " " + $0.unit } ?? "")
                .font(.system(size: unitFontSize, weight: .regular)))
            .monospacedDigit()
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(minimumScale)
            .accessibilityLabel(displayValue)
    }
}

struct GeekSecondaryTransferValue: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            GeekSecondaryTransferReadout(value: value)
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                Circle().fill(tint)
                    .frame(width: GeekSecondaryTransferLayout.indicatorSize,
                           height: GeekSecondaryTransferLayout.indicatorSize)
                Text(title).font(AdvancedPanelTypography.body)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .help("\(title): \(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
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
            GeekSecondaryTransferReadout(
                value: value,
                numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                unitFontSize: GeekSecondaryTransferLayout.processUnitFontSize,
                minimumScale: GeekSecondaryTransferLayout.processMinimumScale
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct GeekDiskProcessRow: View {
    let app: EnergyImpactApp

    var body: some View {
        HStack(spacing: 6) {
            GeekSecondaryProcessIcon(path: app.iconPath)

            Text(app.name)
                .font(AdvancedPanelTypography.body)
                .lineLimit(1)

            Spacer(minLength: 3)

            GeekSecondaryTransferReadout(
                value: GeekSecondaryTransferLayout.processByteString(app.diskReadBytesPerSecond),
                numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                unitFontSize: GeekSecondaryTransferLayout.processUnitFontSize,
                minimumScale: GeekSecondaryTransferLayout.processMinimumScale
            )
            .frame(width: GeekSecondaryTransferLayout.processValueColumnWidth, alignment: .trailing)

            GeekSecondaryTransferReadout(
                value: GeekSecondaryTransferLayout.processByteString(app.diskWriteBytesPerSecond),
                numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                unitFontSize: GeekSecondaryTransferLayout.processUnitFontSize,
                minimumScale: GeekSecondaryTransferLayout.processMinimumScale
            )
            .frame(width: GeekSecondaryTransferLayout.processValueColumnWidth, alignment: .trailing)
        }
        .frame(height: GeekSecondaryTransferLayout.processRowHeight)
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
