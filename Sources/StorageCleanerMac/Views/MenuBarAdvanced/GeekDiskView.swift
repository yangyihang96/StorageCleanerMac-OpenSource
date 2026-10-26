import SwiftUI

/// One display budget for the existing disk and network secondary tables.
/// These values only format prepared snapshots; they never read the system.
/// D119: the process rows are iStat's, 15 pt on the 17 pt pitch with 12 pt
/// values and a smaller unit (was 16 pt rows 4 pt apart, 11 pt values).
enum GeekSecondaryTransferLayout {
    static let numberFontSize: CGFloat = 18
    static let unitFontSize: CGFloat = 12
    static let minimumScale: CGFloat = 0.75
    static let indicatorSize: CGFloat = 8
    static let processNumberFontSize = GeekIStatCardGeometry.textFontSize
    /// D128: iStat's network and disk process lists set their units at 9 pt
    /// (`format:frozen:`), its rows and peaks at 10 pt (was 10 for both).
    static let processUnitFontSize: CGFloat = 9
    static let rowUnitFontSize: CGFloat = 10
    static let processMinimumScale: CGFloat = 0.9
    static let processIconSize = MiniWindowStyleTokens.processIconSize
    static let processRowHeight = GeekIStatSectionGeometry.rowHeight
    static let processSpacing = GeekIStatSectionGeometry.rowGap
    static let processValueColumnWidth: CGFloat = 64

    /// D119: iStat's process section, 25 + 17n (was 12 + 20 + 16n + 4(n − 1)).
    static func processCardHeight(rowCount: Int) -> CGFloat {
        GeekIStatSectionGeometry.processesHeight(rowCount)
    }

    /// The disk and network process sections list the sampler's five
    /// busiest processes (iStat's default count).
    static let processRowCapacity = 5
}

/// D119: iStat's disk volume section (`disks-physical`, 42): the level-one
/// card's 26 pt ring at (8, 8) and two 15 pt rows from x 41 (was a 35 pt
/// ring in a 47 pt card). Network drives are 15 pt rows under the section
/// title, each with its capacity bar on the right.
enum GeekDiskVolumeLayout {
    static let ringSize = GeekIStatCardGeometry.diskRingSize
    static let ringLineWidth = GeekIStatCardGeometry.diskRingLineWidth
    static let cardHeight = GeekIStatCardGeometry.diskHeight
    static let networkBarWidth: CGFloat = 80
    static let networkBarHeight = GeekIStatCardGeometry.batteryBarHeight
    /// A glyph inside a 15 pt row (a network drive's globe).
    static let rowGlyphSize: CGFloat = 12
}

/// D119: iStat's disk activity section (130): the readouts at 6 with their
/// legend at 25, the mirrored graph from 47 (H − 74 tall, x 8, W − 14 wide)
/// and the peak row at H − 21 (was 180 with a 110 pt plot). The slots are
/// display-only; the secondary-content measurement still owns the
/// available-screen fallback.
enum GeekDiskIOCardLayout {
    static let cardHeight: CGFloat = 130
    static let readoutTop = GeekIStatCardGeometry.networkValueTop
    static let readoutHeight = GeekIStatCardGeometry.networkReadoutHeight
    static let chartTop = GeekIStatCardGeometry.networkGraphTop
    static var chartHeight: CGFloat { cardHeight - 74 }
    static var peakTop: CGFloat { cardHeight - 21 }
    static let peakHeight = GeekIStatCardGeometry.titleHeight
}

enum GeekDiskIOCardSelection {
    static func isSelected(route: GeekPanelRoute, requestID: UUID?, metric: GeekChartRangeMetric?) -> Bool {
        guard case let .history(module: .disk, selection: .inline(routeID)) = route,
              let requestID, routeID == requestID, metric == .disk else { return false }
        return true
    }
}

/// D119: iStat's peak row, the read peak at the leading inset and the write
/// peak at the trailing one (was two centered halves). D146: iStat's
/// "Label: value" with its 'Disks.Read' and 'Disks.Write' (were "读取峰值",
/// "写入峰值" before the value).
struct GeekDiskPeakRow: View {
    let readPeak: String
    let writePeak: String

    var body: some View {
        GeekIStatPeakRow(
            leading: GeekIStatPeakValue(title: L10n.text("读", "Read"), value: readPeak,
                accessibilityLabel: L10n.text("读取峰值", "Read peak")),
            trailing: GeekIStatPeakValue(title: L10n.text("写", "Write"), value: writePeak,
                accessibilityLabel: L10n.text("写入峰值", "Write peak"))
        )
    }
}

extension GeekDiskPeakRow {
    /// D146: the peaks of the bars the activity graph draws, in iStat's disk
    /// activity format; "--" until the graph has a frame (was the selected
    /// window's peaks from the disk summary).
    init(peaks: GeekMirroredChartPeaks?) {
        self.init(readPeak: peaks?.upward.map { IStatNumberFormat.diskActivity($0) } ?? "--",
                  writePeak: peaks?.downward.map { IStatNumberFormat.diskActivity($0) } ?? "--")
    }
}

struct GeekDiskIOCard<Read: View, Write: View, Chart: View, Peak: View>: View {
    private let read: Read
    private let write: Write
    private let chart: Chart
    private let peak: (GeekMirroredChartPeaks?) -> Peak

    /// D146: `peak` builds the peak row from the peaks of the chart in the
    /// graph layer, nil until it has a frame (was a row of its own).
    init(
        @ViewBuilder read: () -> Read,
        @ViewBuilder write: () -> Write,
        @ViewBuilder chart: () -> Chart,
        @ViewBuilder peak: @escaping (GeekMirroredChartPeaks?) -> Peak
    ) {
        self.read = read()
        self.write = write()
        self.chart = chart()
        self.peak = peak
    }

    var body: some View {
        GeekIStatCard(height: GeekDiskIOCardLayout.cardHeight) {
            HStack(spacing: 0) {
                read
                write
            }
            .geekIStatLayer(top: GeekDiskIOCardLayout.readoutTop, height: GeekDiskIOCardLayout.readoutHeight)

            // A layer spans the card, so the peak row keeps the card's offsets.
            chart
                .geekIStatLayer(top: GeekDiskIOCardLayout.chartTop, height: GeekDiskIOCardLayout.chartHeight,
                                trailing: GeekIStatCardGeometry.processorGraphTrailingInset)
                .overlayPreferenceValue(GeekMirroredChartPeaksKey.self) { peaks in
                    peak(peaks)
                        .geekIStatLayer(top: GeekDiskIOCardLayout.peakTop, height: GeekDiskIOCardLayout.peakHeight)
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

    /// D119: iStat's disk menu (301 pt): one card per volume, the network
    /// drives, the read and write activity, then (Geek) the processes.
    var geekDiskPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            // D136: with every volume hidden the menu starts at the activity.
            if showsGeekDiskVolumeSections {
            liveCard(.capacity) {
                VStack(spacing: GeekPanelLayout.detailSpacing) {
            geekDiskVolumeList
            if !geekNetworkDiskVolumes.isEmpty {
                geekNetworkDiskSection
            }
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
                // D136: with every volume hidden the page lists none, as
                // iStat's menu; the row only waits for the first reading.
                if geekDiskVolumesIncludingHidden.isEmpty {
                    GeekCombinedCard(height: GeekDiskVolumeLayout.cardHeight) {
                        GeekDiskLoadingRow()
                    }
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
        let detail = GeekDiskVolumeHoverDetail(
            snapshot: volume.capacity,
            volumeName: volume.name,
            status: volume.healthText,
            temperature: volume.temperature,
            healthCheckedAt: volume.healthCheckedAt,
            showsHealthTimestamp: !volume.isNetwork,
            isNetwork: volume.isNetwork,
            actions: GeekDiskVolumeActions(
                showInFinder: { MiniWindowVolumeActions.showInFinder(path: volume.id) },
                hide: { hideDiskVolume(volume.id) }
            )
        )
        return GeekHoverDetailTarget(
            accessibilityLabel: L10n.text(
                "\(volume.name) 磁盘卷三级详情",
                "\(volume.name) Disk Volume Deep Detail"
            ),
            popoverSize: detail.popoverSize,
            // A fallback until the source is measured: a network drive is a
            // row of the section below the volume cards.
            sourceOffset: volume.isNetwork
                ? CGFloat(geekDiskVolumes.count) * (GeekDiskVolumeLayout.cardHeight + GeekPanelLayout.detailSpacing)
                    + GeekIStatSectionGeometry.rowTop(index, titled: true)
                : CGFloat(index) * (GeekDiskVolumeLayout.cardHeight + GeekPanelLayout.detailSpacing)
        ) {
            if volume.isNetwork {
                GeekDiskNetworkVolumeRow(volume: volume)
            } else {
                // iStat lights each disk's activity; the counters are the
                // whole machine's, so only the startup volume shows them, as
                // on the level-one card.
                GeekDiskVolumeSummary(volume: volume, showsActivity: volume.id == "/",
                                      activity: nativeDiskIOHistory.last)
            }
        } detail: {
            detail
        }
    }

    /// D119: iStat's network disks section: the title row, then one 15 pt
    /// row per drive (24 + 17n; was one 47 pt card per drive under a caption).
    private var geekNetworkDiskSection: some View {
        // D138: iStat's 'Disks.Network Disks' (was 网络硬盘 / Network Drives).
        GeekIStatRowsCard(title: L10n.text("网络磁盘", "Network Disks"), rowCount: geekNetworkDiskVolumes.count) {
            ForEach(Array(geekNetworkDiskVolumes.enumerated()), id: \.element.id) { index, volume in
                geekDiskVolumeHoverTarget(index: index, volume: volume)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("网络磁盘", "Network Disks"))
    }

    /// A volume or network drive to list, or the row waiting for the first
    /// reading.
    private var showsGeekDiskVolumeSections: Bool {
        !geekDiskVolumes.isEmpty || geekDiskVolumesIncludingHidden.isEmpty || !geekNetworkDiskVolumes.isEmpty
    }

    /// D136: the volumes the page lists; a hidden one stays off the page
    /// until the settings show it again (iStat's `Disks.Menu.Filtering`).
    private var geekDiskVolumes: [GeekDiskVolumePresentation] {
        MiniWindowHiddenItems.visible(geekDiskVolumesIncludingHidden, raw: hiddenDiskKeysRaw, key: \.id)
    }

    private var geekDiskVolumesIncludingHidden: [GeekDiskVolumePresentation] {
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
                ),
                hasHealthReading: smartStatus != .unavailable || geekPrimaryDiskRemainingLifePercent != nil
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
                healthCheckedAt: volume.health.checkedAt,
                hasHealthReading: volume.health.smartStatus != .unavailable || volume.remainingLifePercent != nil
            )
        })
        return volumes
    }

    private var geekNetworkDiskVolumes: [GeekDiskVolumePresentation] {
        MiniWindowHiddenItems.visible(networkStorageVolumes, raw: hiddenDiskKeysRaw, key: \.id).filter {
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
                    horizontalInset: 0,
                    verticalInset: 0,
                    mirroredHalfInset: 0,
                    // D131: iStat's menu graph, one bar per sample.
                    bucketing: .samples
                )
            } detail: {
                GeekDiskIOHoverDetail(
                    points: geekChartDiskHistory,
                    counters: nativeDiskIOCounters,
                    duration: geekMetricRange(.disk).duration
                )
            }
        } peak: { peaks in
            GeekDiskPeakRow(peaks: peaks)
        }
    }

    private func geekDiskThroughputHoverTarget(_ mode: GeekDiskIOChartMode) -> some View {
        GeekHoverDetailTarget(
            accessibilityLabel: mode == .read
                ? L10n.text("磁盘读取三级详情", "Disk Read Deep Detail")
                : L10n.text("磁盘写入三级详情", "Disk Write Deep Detail"),
            chartRangeMetric: .disk,
            popoverSize: GeekDiskThroughputHoverDetail.popoverSize,
            usesCardActiveBorder: true
        ) {
            GeekSecondaryTransferValue(
                // D138: iStat's 'Disks.Read' and 'Disks.Write' (were 读取, 写入).
                title: mode == .read ? L10n.text("读", "Read") : L10n.text("写", "Write"),
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

    /// D119: iStat's process section with the read and write columns; it
    /// keeps the height of five rows, so the page does not grow and shrink
    /// with the number of busy processes (was one row per process).
    private var geekDiskProcessCard: some View {
        GeekIStatProcessCard(
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
            ],
            rowCapacity: GeekSecondaryTransferLayout.processRowCapacity
        ) {
            if geekDiskApps.isEmpty {
                // Review P2-8: why the list is empty.
                GeekIStatProcessPlaceholder(
                    isLoading: store.isLoadingEnergyImpact || store.isMenuBarProcessSamplePending,
                    text: geekOnDemandSnapshotNothingMeasured ? GeekOnDemandSnapshotFreshness.nothingMeasuredText : "—"
                )
            } else {
                ForEach(geekDiskApps.prefix(GeekSecondaryTransferLayout.processRowCapacity)) { app in
                    GeekDiskProcessRow(app: app)
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
    /// A SMART status or a wear figure was read. Without one the volume card
    /// shows no health status or age, as iStat shows none (D119; was
    /// "未知 · 时间未知").
    var hasHealthReading = true

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

/// D119: iStat's volume section (`disks-physical`, 42): the used share in
/// the 26 pt ring at (8, 8); the name and the health status on the first
/// 15 pt row and the available space with the health reading's age on the
/// second, both from x 41; the startup volume adds the read and write lights
/// at the trailing inset, as on the level-one card. VoiceOver reads the
/// whole sentence ("44% used · 560 GB available"). Was a 35 pt ring in a
/// 47 pt card with the sentence on the second row.
struct GeekDiskVolumeSummary: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode
    let volume: GeekDiskVolumePresentation
    /// The read and write lights: the counters are the whole machine's, so
    /// only the startup volume shows them.
    var showsActivity = false
    /// The newest throughput sample; nil keeps both lights at the track.
    var activity: NativeDiskIOPoint? = nil

    private typealias IStat = GeekIStatCardGeometry

    private var capacityTint: Color {
        GeekDiskVolumeColors.capacityTint(volume: volume, metricColors: metricColors)
    }

    /// The health status is text (the lights already sit beside it): the
    /// label color while it is fine, the state's color otherwise.
    private var healthTint: Color {
        switch volume.smartStatus {
        case .verified: IStat.labelColor(panelChromePalette)
        case .failing: .red
        case .unsupported: .orange
        case .unavailable: .secondary
        }
    }

    private var textTrailingInset: CGFloat {
        showsActivity ? IStat.diskTextTrailingInset : IStat.inset
    }

    var body: some View {
        GeekIStatCard(height: GeekDiskVolumeLayout.cardHeight) {
            GeekDiskVolumeCapacityRing(volume: volume, tint: capacityTint)
                .geekIStatLayer(top: IStat.inset, height: GeekDiskVolumeLayout.ringSize, alignment: .leading)

            // A long name truncates in the middle; the status keeps its width.
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                Text(volume.name)
                    .geekIStatLabelText()
                    .truncationMode(.middle)
                Spacer(minLength: MiniWindowStyleTokens.rowSpacing)
                if volume.hasHealthReading {
                    healthStatus
                }
            }
            .geekIStatLayer(top: IStat.titleTop, height: IStat.titleHeight,
                            leading: IStat.diskTextLeading, trailing: textTrailingInset)

            // The capacity figure keeps its full width and font; the age
            // gives way when both cannot fit (it stays in help and VoiceOver).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                    availableSummary
                    Spacer(minLength: MiniWindowStyleTokens.rowSpacing)
                    if volume.hasHealthReading {
                        Text(GeekDiskHealthTimestamp.ageText(volume.healthCheckedAt))
                            .geekIStatLabelText()
                            .fixedSize()
                    }
                }
                availableSummary
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .geekIStatLayer(top: IStat.diskSecondRowTop, height: IStat.titleHeight,
                            leading: IStat.diskTextLeading, trailing: textTrailingInset)

            if showsActivity {
                VStack(spacing: IStat.diskLightSpacing) {
                    light(active: (activity?.readBytesPerSecond ?? 0) > 0, tint: metricColors.diskRead)
                    light(active: (activity?.writeBytesPerSecond ?? 0) > 0, tint: metricColors.diskWrite)
                }
                .accessibilityHidden(true)
                .geekIStatLayer(top: IStat.diskLightTop, height: IStat.diskLightColumnHeight, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(capacitySentence)
    }

    /// iStat's "1.43 TB available"; the ring carries the used share.
    private var availableSummary: some View {
        Text(volume.usagePercent.flatMap { _ in volume.capacity }.map(GeekDiskPresentation.availableText)
            ?? L10n.text("容量 —", "Capacity —"))
            .geekIStatValueText()
            // Never a smaller font or an ellipsis for the capacity figure.
            .fixedSize()
            .help(capacitySentence + "\n" + GeekDiskCapacityWording.availableHelp)
            .diskVolumeLayoutProbe("disk-volume.summary")
    }

    private var capacitySentence: String {
        volume.usagePercent.flatMap { percent in volume.capacity.map { (percent, $0) } }.map { percent, capacity in
            GeekDiskCapacityWording.volumeSummary(
                usedPercent: percent,
                available: IStatNumberFormat.space(capacity.userAvailableBytes)
            )
        } ?? L10n.text("容量 —", "Capacity —")
    }

    private var healthStatus: some View {
        Text(volume.healthText)
            .font(.system(size: IStat.textFontSize))
            .foregroundStyle(healthTint)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .help(healthDetail)
            .accessibilityLabel(L10n.text("磁盘健康状态", "Disk health"))
            .accessibilityValue(healthDetail)
    }

    private var healthDetail: String {
        volume.healthText + " · " + GeekDiskHealthTimestamp.detailText(volume.healthCheckedAt)
    }

    private func light(active: Bool, tint: Color) -> some View {
        Circle()
            .fill(active ? tint : GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode, palette: panelChromePalette))
            .frame(width: IStat.diskLightSize, height: IStat.diskLightSize)
    }
}

/// D119: a network drive in iStat's network disks section: one 15 pt row
/// with the globe, the name, and the used share as an 80 × 8 bar on the
/// right (was a 47 pt volume card with the ring and "已连接").
struct GeekDiskNetworkVolumeRow: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode
    let volume: GeekDiskVolumePresentation

    private var capacityTint: Color {
        GeekDiskVolumeColors.capacityTint(volume: volume, metricColors: metricColors)
    }

    private var capacitySentence: String {
        volume.usagePercent.flatMap { percent in volume.capacity.map { (percent, $0) } }.map { percent, capacity in
            GeekDiskCapacityWording.volumeSummary(
                usedPercent: percent,
                available: IStatNumberFormat.space(capacity.userAvailableBytes)
            )
        } ?? L10n.text("容量 —", "Capacity —")
    }

    var body: some View {
        HStack(spacing: GeekIStatCardGeometry.legendDotSpacing) {
            AppSymbolGlyph(
                systemImage: AppSymbols.Panel.networkGlobe,
                size: GeekDiskVolumeLayout.rowGlyphSize,
                weight: .medium
            )
            .foregroundStyle(AppDesignTokens.Palette.information)
            .accessibilityHidden(true)
            Text(volume.name)
                .geekIStatLabelText()
                .truncationMode(.middle)
            Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
            GeekIStatBar(
                progress: volume.usageProgress,
                tint: capacityTint,
                track: GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode, palette: panelChromePalette)
            )
            .frame(width: GeekDiskVolumeLayout.networkBarWidth, height: GeekDiskVolumeLayout.networkBarHeight)
        }
        .frame(height: GeekIStatSectionGeometry.rowHeight)
        .help(capacitySentence + "\n" + GeekDiskCapacityWording.availableHelp)
        .accessibilityElement(children: .ignore)
        // D138: iStat's word, 网络磁盘 (was 网络硬盘 / Network drive).
        .accessibilityLabel(L10n.text("网络磁盘 \(volume.name)", "Network disk \(volume.name)"))
        .accessibilityValue(volume.healthText + " · " + capacitySentence)
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

/// D119: the used share in iStat's 26 pt ring (line 2) without the "%", as
/// on the level-one card (was 35 pt with "44%").
struct GeekDiskVolumeCapacityRing: View {
    let volume: GeekDiskVolumePresentation
    let tint: Color

    var body: some View {
        GeekCombinedRing(
            title: "", value: volume.usagePercent.map { "\($0)" } ?? "—",
            progress: volume.usageProgress, tint: tint, size: GeekDiskVolumeLayout.ringSize,
            strokeWidth: GeekDiskVolumeLayout.ringLineWidth
        )
        .accessibilityLabel(L10n.text("\(volume.name)容量占用", "\(volume.name) capacity used"))
        .accessibilityValue(volume.usagePercent.map { "\($0)%" } ?? "—")
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

    /// D128: the unit keeps the value's own gap, so iStat's disk process
    /// "12K" stays unspaced beside the network's "12 K" (was always a space).
    private func unitText(_ parts: (number: String, unit: String)) -> String {
        guard !parts.unit.isEmpty else { return "" }
        let spaced = displayValue.dropFirst(parts.number.count).first?.isWhitespace == true
        return (spaced ? " " : "") + parts.unit
    }

    var body: some View {
        let parts = GeekCombinedRing.splitReadout(displayValue)
        return (Text(parts?.number ?? displayValue).font(.system(size: numberFontSize, weight: .regular))
            + Text(parts.map(unitText) ?? "")
                .font(.system(size: unitFontSize, weight: .regular)))
            .monospacedDigit()
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(minimumScale)
            .accessibilityLabel(displayValue)
    }
}

/// D119: iStat's bandwidth and activity readout, as on the level-one
/// network card: the value at 18 pt (number and unit alike) in the 19 pt
/// above the legend, then the 9 pt dot and the label centered below (was an
/// 18/12 pt split value over an 8 pt dot).
struct GeekSecondaryTransferValue: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            GeekSecondaryTransferReadout(
                value: value,
                numberFontSize: GeekIStatCardGeometry.bigValueFontSize,
                unitFontSize: GeekIStatCardGeometry.bigValueFontSize
            )
            .foregroundStyle(.primary)
            .frame(height: GeekIStatCardGeometry.networkLegendTop - GeekIStatCardGeometry.networkValueTop)
            GeekIStatCenteredLegend(title: title, color: tint)
                .frame(height: GeekIStatCardGeometry.titleHeight)
        }
        .frame(maxWidth: .infinity)
        .help("\(title): \(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// D146: one peak of iStat's bandwidth and disk activity rows
/// (`format:label:alignment:`). The format '%1$@: %2$@' (zh-CN '%1$@：%2$@')
/// takes the value attributes and the label replaces "%1$@:", or "%1$@"
/// where that is missing: English loses the colon ("Read 12 KB/s"), Chinese
/// keeps its full-width one in the value color ("读：12 KB/s"). The value has
/// iStat's 10 pt unit (was the label 4 pt before the value, D119).
struct GeekIStatPeakValue: View {
    let title: String
    let value: String
    let accessibilityLabel: String

    /// What the format leaves between the label and the value.
    static var separator: String { L10n.text("：", " ") }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title)
                .geekIStatLabelText()
            Text(Self.separator)
                .geekIStatValueText()
            GeekSecondaryTransferReadout(
                value: value,
                numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                unitFontSize: GeekSecondaryTransferLayout.rowUnitFontSize,
                minimumScale: GeekSecondaryTransferLayout.processMinimumScale
            )
            .modifier(GeekIStatTextColor(role: .value))
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value)
    }
}

/// D146: iStat's peak row, the leading peak at x 8 and the trailing one
/// ending 8 from the right edge (`drawAtPoint:` at W − 8 − its width).
struct GeekIStatPeakRow: View {
    let leading: GeekIStatPeakValue
    let trailing: GeekIStatPeakValue

    var body: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            leading
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// D119: a row of iStat's process section with the read and write columns,
/// aligned on the header's column labels.
struct GeekDiskProcessRow: View {
    let app: EnergyImpactApp

    var body: some View {
        GeekIStatProcessRow(iconPath: app.iconPath, name: app.name) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                GeekSecondaryTransferReadout(
                    value: IStatNumberFormat.diskActivity(app.diskReadBytesPerSecond, style: .process),
                    numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                    unitFontSize: GeekSecondaryTransferLayout.processUnitFontSize,
                    minimumScale: GeekSecondaryTransferLayout.processMinimumScale
                )
                .frame(width: GeekSecondaryTransferLayout.processValueColumnWidth, alignment: .trailing)

                GeekSecondaryTransferReadout(
                    value: IStatNumberFormat.diskActivity(app.diskWriteBytesPerSecond, style: .process),
                    numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                    unitFontSize: GeekSecondaryTransferLayout.processUnitFontSize,
                    minimumScale: GeekSecondaryTransferLayout.processMinimumScale
                )
                .frame(width: GeekSecondaryTransferLayout.processValueColumnWidth, alignment: .trailing)
            }
        }
        .help(L10n.text("近期按需磁盘测量", "Latest on-demand disk measurement"))
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
