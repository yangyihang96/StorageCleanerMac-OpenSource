import SwiftUI

/// The hardware probes list (level three): two columns. D119: the sensors
/// page's temperature group is iStat's single column of 15 pt rows; the
/// grid's row, chrome and font constants went with the old card.
enum GeekSensorTemperatureLayout {
    static let gridColumnSpacing: CGFloat = 10

    static func temperatureGridRowCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount + 1) / 2
    }
}

/// D119: the sensors page's three rings are the overview card's (iStat
/// `sensors-overview`): 72 pt rings in 87 pt cells on an 88 pt card (was
/// 62 pt rings 24 pt apart).
enum GeekSensorSummaryLayout {
    static let ringSize = GeekIStatCardGeometry.sensorRingSize
    static let cardHeight = GeekIStatCardGeometry.sensorsHeight
}

/// Snapshot-only copy for the compact ring. Keep the unit visible; the full
/// state, averaging and sample provenance belong in help and accessibility.
struct GeekSensorFanRingPresentation {
    let value: String
    let caption: String
    let accessibilityValue: String
    let helpText: String

    init(telemetry: FanTelemetryState) {
        let explanation: String
        if telemetry.isSampling {
            value = "—"
            caption = L10n.text("检测中", "Reading")
            explanation = L10n.text("正在检测风扇，尚无转速读数。", "Checking fans; no RPM reading yet.")
        } else if telemetry.isFanless {
            value = L10n.text("无", "None")
            caption = L10n.text("被动散热", "Passive")
            explanation = L10n.text("此 Mac 无风扇，采用被动散热。", "This Mac has no fans and uses passive cooling.")
        } else if let rpm = telemetry.actualRPM {
            let formattedRPM = SystemFanSpeedFormat.number(rpm)
            value = formattedRPM
            caption = "rpm"
            explanation = telemetry.fanCount > 1
                ? L10n.text("\(ByteFormat.count(telemetry.fanCount)) 个风扇的平均转速：\(formattedRPM) rpm。", "Average speed across \(ByteFormat.count(telemetry.fanCount)) fans: \(formattedRPM) rpm.")
                : L10n.text("风扇实际转速：\(formattedRPM) rpm。", "Actual fan speed: \(formattedRPM) rpm.")
        } else {
            value = "—"
            caption = L10n.text("不可用", "N/A")
            explanation = L10n.text("尚无有效的系统风扇转速读数。", "No valid system fan RPM reading is available.")
        }
        accessibilityValue = explanation
        let provenance = telemetry.timestamp.map {
            L10n.text("系统风扇读数 · 采样 \($0.formatted(date: .omitted, time: .standard))", "System fan telemetry · Sampled \($0.formatted(date: .omitted, time: .standard))")
        } ?? L10n.text("系统风扇读数 · 采样时间未知", "System fan telemetry · Sample time unknown")
        let controlHint = telemetry.actualRPM != nil && !telemetry.isFanless && !telemetry.isSampling
            ? L10n.text("点击“风扇控制”或悬停风扇转速可打开控制。", "Click Fan Control or hover a fan speed to open controls.")
            : ""
        helpText = [explanation, provenance, controlHint].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct GeekSensorFanRing: View {
    let telemetry: FanTelemetryState
    let tint: Color

    var body: some View {
        let presentation = GeekSensorFanRingPresentation(telemetry: telemetry)
        GeekIStatSensorRing(
            title: L10n.text("风扇", "FANS"),
            value: presentation.value,
            detail: presentation.caption,
            progress: telemetry.percentage.map { $0 / 100 },
            tint: tint
        )
        .help(presentation.helpText)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.helpText)
    }
}

enum GeekSensorPageAvailability: Equatable {
    case sampling
    case available
    case unavailable

    static func resolve(
        reportedAvailability: SystemSensorAvailability,
        hasSensorData: Bool
    ) -> Self {
        if hasSensorData { return .available }
        switch reportedAvailability {
        case .sampling: return .sampling
        case .available: return .available
        case .unavailable: return .unavailable
        }
    }
}

enum GeekSensorReadoutLayout {
    /// D119: a titled group of 15 pt rows on the 17 pt pitch, 24 + 17n (was
    /// 26 + 23n).
    static func cardHeight(rowCount: Int) -> CGFloat {
        GeekIStatSectionGeometry.rowsHeight(rowCount, titled: true)
    }

    /// D122: a readout's third level: the titled card of its rows
    /// (`detailRowCount`), and the note's card (three lines until it is
    /// measured); was 190 + 18 per extra detail row.
    static func detailSize(_ readout: GeekSensorReadout) -> CGSize {
        GeekIStatDetailGeometry.pageSize(
            cards: [
                GeekIStatSectionGeometry.rowsHeight(detailRowCount(readout), titled: true),
                GeekIStatNoteCard.estimatedHeight,
            ],
            width: detailWidth
        )
    }

    /// The readout pages keep their 270 pt width for the chip blocks' names.
    static let detailWidth: CGFloat = 270

    /// The rows of a readout's titled card: the source, the sample when
    /// there is one, and the extra readings.
    static func detailRowCount(_ readout: GeekSensorReadout) -> Int {
        1 + (readout.sampledAt == nil ? 0 : 1) + readout.detailRows.count
    }

    /// The indent of a detail row that is part of the row above it.
    static let childIndent: CGFloat = 14
}

struct GeekSensorReadout: Identifiable {
    let id: String
    let title: String
    let value: String
    let source: String
    let note: String
    let sampledAt: Date?
    /// D57: the value is carried from an earlier window (no new reading in
    /// the latest one) or not measured yet; the row says "更新中".
    var isUpdating = false
    /// Extra third-level rows (input voltage, brightness, chip breakdown…).
    var detailRows: [GeekSensorReadoutDetailRow] = []
}

struct GeekSensorReadoutDetailRow: Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    var isUpdating = false
    /// A part of the row above (the CPU's core clusters), indented so it is
    /// not read as one more term of the total.
    var isIndented = false

    init(_ title: String, _ value: String, id: String? = nil, isUpdating: Bool = false, isIndented: Bool = false) {
        self.id = id ?? title
        self.title = title
        self.value = value
        self.isUpdating = isUpdating
        self.isIndented = isIndented
    }
}

/// The power page's "功耗" card (DECISIONS D57 ③): the whole computer
/// (SMC `PSTR`), the measured power input while on external power (`PDTR`),
/// the battery (`B0AP`, sign from `B0AC`; `PPBR` only as a third-level
/// reference, D57 supplement), the built-in display's
/// backlight (`PBwo`/`PDBR`, checked against `IDBR × VP0R`) and the chip
/// total (IOReport Energy Model), whose third level lists the SoC blocks.
/// A row whose key or channel does not exist is hidden; an out-of-range
/// value shows "—"; a legal zero is shown.
enum GeekPowerReadouts {
    /// After this long without a new sample the rows say "更新中".
    static let staleAfter: TimeInterval = 6

    static func rows(
        hasInternalBattery: Bool,
        powerSource: BatteryPowerSource?,
        telemetry: MenuBarPowerTelemetry?,
        electrical: NativeBatteryElectricalSnapshot?,
        now: Date = Date()
    ) -> [GeekSensorReadout] {
        guard let telemetry else { return [] }
        let isStale = now.timeIntervalSince(telemetry.generatedAt) > staleAfter
        let time = telemetry.generatedAt
        let smc = telemetry.smc
        var rows: [GeekSensorReadout] = []

        if let row = row(
            id: "power-system",
            title: L10n.text("整机", "Computer"),
            reading: smc.systemPowerWatts,
            source: "SMC PSTR",
            note: systemNote(hasInternalBattery: hasInternalBattery, powerSource: powerSource),
            sampledAt: time
        ) {
            rows.append(row)
        }

        if powerSource == .acPower, var row = row(
            id: "power-input",
            title: L10n.text("电源输入", "Power Input"),
            reading: smc.inputPowerWatts,
            source: "SMC PDTR",
            note: L10n.text(
                "电源适配器实际输入功率（测量值，不是协商功率）",
                "Measured input power from the adapter (not the negotiated rating)"
            ),
            sampledAt: time
        ) {
            row.detailRows = [
                GeekSensorReadoutDetailRow(
                    L10n.text("输入电压", "Input Voltage"),
                    HardwareReadingText.detail(smc.inputVoltageVolts, format: HardwareReadingText.volts)
                ),
                GeekSensorReadoutDetailRow(
                    L10n.text("输入电流", "Input Current"),
                    HardwareReadingText.detail(smc.inputCurrentAmps, format: HardwareReadingText.amps)
                ),
            ] + (electrical?.adapterPowerWatts.map {
                [GeekSensorReadoutDetailRow(L10n.text("协商功率", "Negotiated"), IStatNumberFormat.power($0))]
            } ?? [])
            rows.append(row)
        }

        let batteryComputed = smc.battery.rowPowerBasis == .voltageTimesCurrent
        if hasInternalBattery, var row = row(
            id: "power-battery",
            title: L10n.text("电池", "Battery"),
            reading: smc.battery.rowPowerWatts,
            format: HardwareReadingText.signedWatts,
            // Incremental review P2-2: without B0AP the row is B0AV × B0AC.
            source: batteryComputed ? L10n.text("电压 × 电流（SMC）", "Voltage × Current (SMC)") : "SMC B0AP",
            note: batteryComputed
                ? L10n.text(
                    "电池电压 × 电流（B0AV × B0AC，本机没有 B0AP），约每秒更新；正负号与方向依据电池电流（B0AC）",
                    "Battery voltage × current (B0AV × B0AC; this Mac has no B0AP), updated about every second; the sign and direction follow the battery current (B0AC)"
                )
                : L10n.text(
                    "电池端电压 × 电流，约每秒更新；正负号与方向依据电池电流（B0AC）",
                    "Battery voltage × current, updated about every second; the sign and direction follow the battery current (B0AC)"
                ),
            sampledAt: time
        ) {
            row.detailRows = [
                GeekSensorReadoutDetailRow(L10n.text("方向", "Direction"), batteryDirectionText(smc.battery)),
                GeekSensorReadoutDetailRow(
                    L10n.text("电池轨（SMC）", "Battery Rail (SMC)"),
                    HardwareReadingText.detail(smc.batteryPowerWatts, format: HardwareReadingText.watts),
                    id: "battery-rail"
                ),
            ]
            rows.append(row)
        }

        let backlight = smc.backlight
        if var row = row(
            id: "power-backlight",
            title: L10n.text("屏幕背光", "Display Backlight"),
            reading: backlight.displayWatts,
            source: backlight.sourceKey.map { "SMC \($0)" } ?? "SMC",
            note: backlightNote(backlight),
            sampledAt: time
        ) {
            row.detailRows = [
                GeekSensorReadoutDetailRow(
                    L10n.text("亮度", "Brightness"),
                    HardwareReadingText.detail(telemetry.backlightBrightnessNits) {
                        L10n.text(String(format: "%.0f 尼特", $0), String(format: "%.0f nits", $0))
                    }
                ),
                GeekSensorReadoutDetailRow(
                    L10n.text("背光电流", "Backlight Current"),
                    HardwareReadingText.detail(backlight.currentAmps, format: HardwareReadingText.amps)
                ),
                GeekSensorReadoutDetailRow(
                    L10n.text("12 V 供电轨", "12 V Rail"),
                    HardwareReadingText.detail(backlight.railVoltageVolts, format: HardwareReadingText.volts)
                ),
            ]
            rows.append(row)
        }

        if let row = chipRow(telemetry: telemetry) {
            rows.append(row)
        }

        guard isStale else { return rows }
        return rows.map { row in
            var row = row
            row.isUpdating = true
            return row
        }
    }

    /// A row for a reading, or nil when its key does not exist.
    private static func row(
        id: String,
        title: String,
        reading: HardwareReading<Double>,
        format: (Double) -> String = HardwareReadingText.watts,
        source: String,
        note: String,
        sampledAt: Date
    ) -> GeekSensorReadout? {
        switch reading {
        case .unsupported:
            return nil
        case .invalid:
            return GeekSensorReadout(
                id: id, title: title, value: HardwareReadingText.invalidValue, source: source,
                note: "\(HardwareReadingText.invalid) · \(note)", sampledAt: sampledAt
            )
        case let .value(value):
            return GeekSensorReadout(
                id: id, title: title, value: format(value), source: source,
                note: note, sampledAt: sampledAt
            )
        }
    }

    /// What `PSTR` is (incremental review P2-3). Measured on Mac17,9 on
    /// external power (10 s means over 2 × 2.5 min, B0AP -14…+12 W):
    /// PSTR ≈ 1.00 × PDTR − 1.00 × B0AP, so it is what the computer uses,
    /// without the power that charges the battery, and with what the battery
    /// adds while it discharges. On battery all of it comes from the battery.
    static func systemNote(hasInternalBattery: Bool, powerSource: BatteryPowerSource?) -> String {
        let base = L10n.text("整机耗电功率，约每秒更新", "Power the whole computer uses, updated about every second")
        guard hasInternalBattery else { return base }
        switch powerSource {
        case .acPower?:
            return L10n.text(
                "\(base)；接电源时不含给电池充电的部分：约等于电源输入减去充电功率，电池补电时约等于电源输入加上电池放电",
                "\(base); on external power it does not include the power charging the battery: about the input minus the charging power, or the input plus what the battery adds while it discharges"
            )
        case .batteryPower?:
            return L10n.text("\(base)；用电池时全部由电池供电", "\(base); on battery all of it comes from the battery")
        default:
            return base
        }
    }

    /// "充电中／放电中" from the current's direction (charging itself is not
    /// measured); "电流约为 0" below 5 mA; the rule's text without `B0AC`.
    static func batteryDirectionText(_ battery: SMCBatteryTelemetry) -> String {
        switch battery.currentDirection {
        case .charging?: return L10n.text("充电中", "Charging")
        case .discharging?: return L10n.text("放电中", "Discharging")
        case nil:
            switch battery.currentAmps {
            case .unsupported: return HardwareReadingText.unsupported
            case .invalid: return HardwareReadingText.invalid
            case .value: return L10n.text("电流约为 0", "About 0 A")
            }
        }
    }

    private static func backlightNote(_ backlight: BacklightPowerReading) -> String {
        let purpose = L10n.text("内建屏背光功率", "Built-in display backlight power")
        switch backlight.verification {
        case let .verified(deviation)?:
            return L10n.text(
                "\(purpose)；与背光电流 × 12 V 供电轨核对一致（偏差 \(Int((deviation * 100).rounded()))%）",
                "\(purpose); agrees with backlight current × 12 V rail (\(Int((deviation * 100).rounded()))%)"
            )
        case let .mismatch(deviation)?:
            let percent = deviation.isFinite ? "\(Int((deviation * 100).rounded()))%" : "—"
            return L10n.text(
                "\(purpose)；与背光电流 × 12 V 供电轨核对不一致（偏差 \(percent)，超过 ±20%）",
                "\(purpose); disagrees with backlight current × 12 V rail (\(percent), beyond ±20%)"
            )
        case .unverifiable?:
            return L10n.text(
                "\(purpose)；缺少背光电流或 12 V 供电轨读数，无法核对",
                "\(purpose); cannot be checked without backlight current and 12 V rail readings"
            )
        case nil:
            return purpose
        }
    }

    /// The chip total; its third level lists every SoC block this Mac has
    /// (the core clusters indented under the CPU, which already contains
    /// them) and names the expected ones it does not have. Without a CPU
    /// part there is no total (D57 supplement): the row then only leads to
    /// the blocks that do exist, with "CPU" under "本机不支持".
    private static func chipRow(telemetry: MenuBarPowerTelemetry) -> GeekSensorReadout? {
        let soc = telemetry.soc
        guard soc.isSupported, soc.total != nil || !soc.items.isEmpty else { return nil }
        let value: String
        if let total = soc.total {
            if total.isInvalid {
                value = HardwareReadingText.invalidValue
            } else if let watts = total.watts {
                value = HardwareReadingText.watts(watts)
            } else {
                value = L10n.text("更新中…", "Updating…")
            }
        } else {
            value = L10n.text("本机不支持", "Unsupported")
        }
        var detailRows: [GeekSensorReadoutDetailRow] = []
        if let cpu = soc.cpu {
            detailRows.append(componentRow(id: SoCPowerComponent.cpu.rawValue, title: SoCPowerComponent.cpu.title, power: cpu))
        }
        detailRows += soc.items.map {
            componentRow(
                id: $0.component.rawValue,
                title: $0.component.title,
                power: $0.power,
                isIndented: $0.component.isCPUCluster && soc.cpu != nil
            )
        }
        if !soc.unsupportedComponents.isEmpty {
            detailRows.append(GeekSensorReadoutDetailRow(
                HardwareReadingText.unsupported,
                soc.unsupportedComponents.map(\.title).joined(separator: "、"),
                id: "unsupported"
            ))
        }
        let reference = telemetry.smc.chipPowerReferenceWatts
        if reference.isSupported {
            detailRows.append(GeekSensorReadoutDetailRow(
                L10n.text("校验：系统控制器估计", "Check: SMC Estimate"),
                HardwareReadingText.detail(reference, format: HardwareReadingText.watts),
                id: "reference"
            ))
        }
        guard let total = soc.total else {
            return GeekSensorReadout(
                id: "power-chip",
                title: L10n.text("芯片合计", "Chip Total"),
                value: value,
                source: L10n.text("IOReport 能耗计数", "IOReport Energy Model"),
                note: L10n.text(
                    "本机没有 CPU 能耗计数，不显示芯片合计；三级只列出能读到的部件",
                    "This Mac has no CPU energy counter, so there is no chip total; only the blocks it measures are listed"
                ),
                sampledAt: telemetry.generatedAt,
                detailRows: detailRows
            )
        }
        var note = L10n.text(
            "芯片各部件能耗计数之和（CPU 已含各核心簇）；按计数更新时刻对齐计算，没有新计数的时段沿用上次读数并标“更新中”",
            "Sum of the IOReport energy counters (the CPU includes its core clusters); computed between counter updates, and a period without a new count keeps the last reading marked Updating"
        )
        if let watts = total.watts, let referenceWatts = reference.value {
            note += L10n.text(
                "；与系统控制器的芯片功率估计相差 \(IStatNumberFormat.power(abs(watts - referenceWatts)))",
                "; differs from the SMC chip estimate by \(IStatNumberFormat.power(abs(watts - referenceWatts)))"
            )
        }
        return GeekSensorReadout(
            id: "power-chip",
            title: L10n.text("芯片合计", "Chip Total"),
            value: value,
            source: L10n.text("IOReport 能耗计数", "IOReport Energy Model"),
            note: note,
            sampledAt: telemetry.generatedAt,
            isUpdating: total.isUpdating,
            detailRows: detailRows
        )
    }

    private static func componentRow(
        id: String,
        title: String,
        power: SoCChannelPower,
        isIndented: Bool = false
    ) -> GeekSensorReadoutDetailRow {
        let value: String
        if power.isInvalid {
            value = HardwareReadingText.invalid
        } else if let watts = power.watts {
            value = HardwareReadingText.watts(watts)
        } else {
            value = L10n.text("更新中…", "Updating…")
        }
        return GeekSensorReadoutDetailRow(title, value, id: id, isUpdating: power.isUpdating, isIndented: isIndented)
    }
}

/// The power page's "电池电气" card (D57 ①): the SMC's live `B0AC`/`B0AV`
/// (about once a second); AppleSmartBattery's once-a-minute values only when
/// the SMC lacks the key, and then labelled as such.
enum GeekBatteryElectricalReadouts {
    static func rows(electrical: NativeBatteryElectricalSnapshot?) -> [GeekSensorReadout] {
        currentRows(electrical: electrical) + voltageRows(electrical: electrical)
    }

    /// D119: the sensors page's current group.
    static func currentRows(electrical: NativeBatteryElectricalSnapshot?) -> [GeekSensorReadout] {
        guard let electrical else { return [] }
        let isSMC = electrical.electricalSource == .smc
        return row(
            id: "battery-current",
            title: L10n.text("电池电流", "Battery Current"),
            reading: electrical.currentReading,
            format: HardwareReadingText.signedAmps,
            source: isSMC ? "SMC B0AC" : "AppleSmartBattery",
            note: isSMC
                ? L10n.text("带符号的电池电流，负值为放电；约每秒更新", "Signed battery current, negative while discharging; updated about every second")
                : controllerNote,
            sampledAt: electrical.generatedAt
        ).map { [$0] } ?? []
    }

    /// D119: the sensors page's voltage group.
    static func voltageRows(electrical: NativeBatteryElectricalSnapshot?) -> [GeekSensorReadout] {
        guard let electrical else { return [] }
        let isSMC = electrical.electricalSource == .smc
        return row(
            id: "battery-voltage",
            title: L10n.text("电池电压", "Battery Voltage"),
            reading: electrical.voltageReading,
            format: HardwareReadingText.volts,
            source: isSMC ? "SMC B0AV" : "AppleSmartBattery",
            note: isSMC
                ? L10n.text("电池端电压；约每秒更新", "Battery terminal voltage; updated about every second")
                : controllerNote,
            sampledAt: electrical.generatedAt
        ).map { [$0] } ?? []
    }

    private static var controllerNote: String {
        L10n.text("电池控制器约每分钟才更新一次", "The battery controller updates only about once a minute")
    }

    private static func row(
        id: String,
        title: String,
        reading: HardwareReading<Double>,
        format: (Double) -> String,
        source: String,
        note: String,
        sampledAt: Date
    ) -> GeekSensorReadout? {
        switch reading {
        case .unsupported:
            return nil
        case .invalid:
            return GeekSensorReadout(
                id: id, title: title, value: HardwareReadingText.invalidValue, source: source,
                note: "\(HardwareReadingText.invalid) · \(note)", sampledAt: sampledAt
            )
        case let .value(value):
            return GeekSensorReadout(
                id: id, title: title, value: format(value), source: source, note: note, sampledAt: sampledAt
            )
        }
    }
}

/// BOARD N16-1: the GPU frequency wherever the mini window shows it (the
/// CPU page's frequency rows and GPU rings, the sensors rings). A reading
/// that cannot be made says why; it is never shown as a number.
/// Missing native channels are omitted. A real GPU-off observation remains
/// "Idle", and a measured zero is kept; neither is a missing helper reading.
enum GeekProcessorFrequencyPresentation {
    static func rows(telemetry: CPUPerformanceStateService.Snapshot?, sampledAt: Date?) -> [GeekSensorReadout] {
        let clusters = telemetry?.clusters ?? []
        func valid(_ frequency: Double?) -> Double? {
            frequency.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        func text(_ frequency: Double) -> String {
            IStatNumberFormat.frequency(megahertz: frequency)
        }
        var rows: [GeekSensorReadout] = []
        if let highest = clusters.compactMap({ valid($0.frequencyMHz) }).max() {
            rows.append(GeekSensorReadout(
                id: "cpu-frequency",
                title: L10n.text("CPU 当前最高核心组", "CPU Highest Active Cluster"),
                value: text(highest), source: "IOReport",
                note: L10n.text("核心组工作点；不是每颗核心独立时钟", "Cluster operating point, not each core's independent clock"),
                sampledAt: sampledAt))
        }
        rows += clusters.enumerated().compactMap { index, cluster in
            guard let frequency = valid(cluster.frequencyMHz) else { return nil }
            return GeekSensorReadout(
                id: "cpu-cluster-\(cluster.identifier)",
                title: L10n.text("核心组 \(index + 1) · \(ByteFormat.count(cluster.coreCount)) 核", "Cluster \(index + 1) · \(ByteFormat.count(cluster.coreCount)) cores"),
                value: text(frequency), source: "IOReport",
                note: L10n.text("\(cluster.performanceLevelName) 层级的平均工作点", "Average operating point of \(cluster.performanceLevelName) level"),
                sampledAt: sampledAt)
        }
        if let gpu = telemetry?.gpu, gpu.frequencyMHz == nil || valid(gpu.frequencyMHz) != nil {
            rows.append(GeekGPUFrequencyPresentation.readout(gpu, sampledAt: sampledAt))
        }
        return rows
    }
}

enum GeekGPUFrequencyPresentation {
    /// "0.34 GHz", "空闲" while the GPU was off, "—" without a reading.
    /// D128: iStat's frequency, at most two decimals ("1.4 GHz").
    static func value(_ reading: CPUPerformanceStateService.GPUReading?) -> String {
        guard let reading else { return "—" }
        guard let frequency = reading.frequencyMHz else { return idleTitle }
        return gigahertz(frequency)
    }

    /// A ring's value and unit: "0.34" + "GHz", "空闲", or "—".
    static func ringValue(_ reading: CPUPerformanceStateService.GPUReading?) -> (value: String, unit: String?) {
        guard let reading else { return ("—", nil) }
        guard let frequency = reading.frequencyMHz else { return (idleTitle, nil) }
        return (IStatNumberFormat.number(frequency / 1_000, decimals: 2), "GHz")
    }

    /// The share of the GPU's highest operating point (a ring's arc).
    static func ringProgress(_ reading: CPUPerformanceStateService.GPUReading?) -> Double? {
        guard let reading, reading.maximumFrequencyMHz > 0 else { return nil }
        guard let frequency = reading.frequencyMHz else { return 0 }
        return min(1, max(0, frequency / reading.maximumFrequencyMHz))
    }

    static func readout(
        _ reading: CPUPerformanceStateService.GPUReading?,
        sampledAt: Date?
    ) -> GeekSensorReadout {
        let title = L10n.text("GPU 频率", "GPU Frequency")
        guard let reading else {
            return GeekSensorReadout(
                id: "gpu-frequency", title: title, value: "—",
                source: L10n.text("未提供", "Not exposed"),
                note: L10n.text(
                    "未能读取 GPU 工作点：本机没有可识别的 GPU 频率表或性能状态",
                    "The GPU operating point could not be read: no recognizable GPU frequency table or performance states"
                ),
                sampledAt: nil
            )
        }
        let note = reading.frequencyMHz == nil
            ? L10n.text("本次采样期间 GPU 处于关闭状态", "The GPU was powered off during this sample")
            : L10n.text(
                "活动时段按各工作点停留时间加权的平均频率；活动 \(Int((reading.activeRatio * 100).rounded()))%",
                "Average frequency of the active time, weighted by time in each operating point; active \(Int((reading.activeRatio * 100).rounded()))%"
            )
        return GeekSensorReadout(
            id: "gpu-frequency", title: title, value: value(reading),
            source: "IOReport", note: note, sampledAt: sampledAt
        )
    }

    private static var idleTitle: String { L10n.text("空闲", "Idle") }

    private static func gigahertz(_ megahertz: Double) -> String {
        IStatNumberFormat.frequency(megahertz: megahertz)
    }
}

/// D122: a reading's level three in iStat's plain-menu cards: a titled card
/// of rows (the value in the title row; the source, the sample and the
/// extra readings, parts indented under their row) and a card of the note.
struct GeekSensorReadoutDetail: View {
    @Environment(\.miniWindowPageProvidesInset) private var pageProvidesInset
    let readout: GeekSensorReadout

    var body: some View {
        VStack(spacing: MiniWindowStyleTokens.cardSpacing) {
            GeekIStatRowsCard(
                title: readout.title,
                rowCount: GeekSensorReadoutLayout.detailRowCount(readout)
            ) {
                Text(readout.value)
                    .geekIStatValueText(readout.isUpdating ? .secondary : .primary)
            } rows: {
                GeekIStatRow(title: L10n.text("来源", "Source"), value: readout.source)
                if let sampledAt = readout.sampledAt {
                    GeekIStatRow(
                        title: L10n.text("采样", "Sampled"),
                        value: readout.isUpdating
                            ? "\(sampledAt.formatted(date: .omitted, time: .standard)) · \(HardwareReadingText.updating)"
                            : sampledAt.formatted(date: .omitted, time: .standard)
                    )
                }
                ForEach(readout.detailRows) { row in
                    GeekIStatRow(
                        title: row.title,
                        value: row.isUpdating && !row.value.hasSuffix("…")
                            ? "\(row.value) · \(HardwareReadingText.updating)"
                            : row.value
                    )
                    .padding(.leading, row.isIndented ? GeekSensorReadoutLayout.childIndent : 0)
                    .help("\(row.title) \(row.value)")
                }
            }
            GeekIStatNoteCard(text: readout.note)
        }
        .padding(pageProvidesInset ? 0 : GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// Individual probes are snapshot-only. Present all of them together as a
/// current-reading inspector; a regional history must not be labelled as the
/// history of a particular core or SMC probe.
/// D122: one titled iStat card: the probes in two columns of 15 pt rows on
/// the 17 pt pitch (the columns 10 pt apart), then the sample time.
struct GeekDetailedTemperaturesDetail: View {
    @Environment(\.miniWindowPageProvidesInset) private var pageProvidesInset
    let readings: [SystemTemperatureDetailReading]
    let sampledAt: Date?

    /// The card's rows: the grid's and the sample's.
    nonisolated static func rowCount(readingCount: Int, hasSample: Bool) -> Int {
        GeekSensorTemperatureLayout.temperatureGridRowCount(itemCount: readingCount) + (hasSample ? 1 : 0)
    }

    nonisolated static func popoverSize(readingCount: Int, hasSample: Bool) -> CGSize {
        GeekIStatDetailGeometry.pageSize(
            cards: [GeekIStatSectionGeometry.rowsHeight(rowCount(readingCount: readingCount, hasSample: hasSample), titled: true)],
            width: MiniWindowStyleTokens.historyWidth
        )
    }

    var body: some View {
        GeekIStatRowsCard(
            title: L10n.text("核心与硬件温度", "Core & Hardware Temperature"),
            rowCount: Self.rowCount(readingCount: readings.count, hasSample: sampledAt != nil)
        ) {
            Text(L10n.text("\(ByteFormat.count(readings.count)) 项", "\(ByteFormat.count(readings.count)) Sensors"))
                .geekIStatValueText(.secondary)
        } rows: {
            LazyVGrid(
                // The sensors card's former two-column grid (its zones are one
                // iStat column since D119); the 10 pt column gap is calibrated
                // geometry (GeekSensorsPowerHoverDetailTests).
                columns: [
                    GridItem(.flexible(), spacing: GeekSensorTemperatureLayout.gridColumnSpacing),
                    GridItem(.flexible()),
                ],
                alignment: .leading,
                spacing: GeekIStatSectionGeometry.rowGap
            ) {
                ForEach(readings) { reading in
                    HStack(spacing: MiniWindowStyleTokens.rowSpacing) {
                        Text(reading.name)
                            .geekIStatLabelText()
                            .truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(IStatNumberFormat.temperature(reading.celsius))
                            .geekIStatValueText(reading.celsius >= 90
                                ? AppDesignTokens.Palette.destructive
                                : reading.celsius >= 80
                                    ? AppDesignTokens.Palette.warning
                                    : .primary)
                    }
                    .frame(height: GeekIStatSectionGeometry.rowHeight)
                    .help(reading.sourceHelp)
                    .accessibilityElement(children: .combine)
                }
            }
            if let sampledAt {
                GeekIStatRow(
                    title: L10n.text("采样", "Sampled"),
                    value: sampledAt.formatted(date: .omitted, time: .standard),
                    valueColor: .secondary
                )
            }
        }
        .padding(pageProvidesInset ? 0 : GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

extension MenuBarAdvancedStatusView {
    /// D119: iStat's sensor menu (`SensorsMenu`): the three rings (88), then a
    /// titled group per kind of reading (24 + 17n): temperature, the fans
    /// with our fan control entry, current, power, voltage, frequency and
    /// ambient light. The battery current and voltage and the power rows
    /// moved here from the power page.
    var geekSensorsPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.sensors) {
                VStack(spacing: GeekPanelLayout.detailSpacing) {
                    switch geekSensorPageAvailability {
                    case .sampling:
                        geekSensorStatusCard(PanelChartSampling.statusText)
                            .id(GeekHardwareDetailFocus.monitoring)
                    case .unavailable:
                        geekSensorStatusCard(
                            L10n.text(
                                "此 Mac 没有可用的传感器读数",
                                "No sensor readings are available for this Mac"
                            )
                        )
                        .id(GeekHardwareDetailFocus.monitoring)
                    case .available:
                        if geekHasSensorGaugeData {
                            geekSensorsGaugeCard
                                .id(GeekHardwareDetailFocus.monitoring)
                        }
                        if !geekDisplayedTemperatures.isEmpty || !geekDetailedTemperatures.isEmpty {
                            geekTemperatureCard
                        }
                    }
                }
            }
            liveCard(.controls) { geekHardwareControlSummaryCard }
                .id(GeekHardwareDetailFocus.power)
            // The battery and power readings redraw with their own samples,
            // the helper's with its leaf (GeekHelperPowerMetricsCards).
            liveCard(.battery) { geekHelperPowerMetricsCards }
            liveCard(.sensors) { geekSensorFrequencyGroup }
            // D57: ambient light at the end of the page, only on a Mac with
            // the sensor.
            if monitorSnapshot?.ambientLight?.isSupported == true {
                liveCard(.sensors) { geekAmbientLightCard }
            }
        }
    }

    @ViewBuilder
    private var geekAmbientLightCard: some View {
        if let readout = GeekAmbientLightReadout.readout(
            monitorSnapshot?.ambientLight,
            sampledAt: monitorSnapshot?.sensorReadingDate
        ) {
            // D138: iStat's group name, 'Sensors.Light' (was AMBIENT LIGHT).
            geekSensorReadoutCard(L10n.text("环境光", "LIGHT"), rows: [readout])
        }
    }

    /// The page while there is no sensor reading: one 25 pt row.
    private func geekSensorStatusCard(_ text: String) -> some View {
        GeekIStatCard(height: GeekIStatSectionGeometry.singleRowHeight) {
            Text(text)
                .geekIStatLabelText()
                .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// iStat `sensors-overview` on the module page: the overview card's three
    /// rings (72 pt in 87 pt cells), each opening its history (level three);
    /// the card menu ("⋮") opens the fan control palette.
    private var geekSensorsGaugeCard: some View {
        GeekIStatCard(height: GeekSensorSummaryLayout.cardHeight) {
            GeekIStatSensorCells {
                geekSensorRingCell { geekCPUTemperatureRing }
                geekSensorRingCell { geekGPUTemperatureRing }
                geekSensorRingCell { geekFanRing }
            }
            .geekIStatLayer(top: (GeekSensorSummaryLayout.cardHeight - GeekSensorSummaryLayout.ringSize) / 2,
                            height: GeekSensorSummaryLayout.ringSize, leading: 0, trailing: 0)

            if geekFanControlEntryPresentation.showsControl {
                GeekIStatCardMenuButton(state: geekFanControlEntryPresentation)
                    .geekIStatLayer(top: 0, height: GeekIStatCardMenuButton.side, leading: 0, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("传感器", "Sensors"))
    }

    private func geekSensorRingCell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: GeekSensorSummaryLayout.ringSize, height: GeekSensorSummaryLayout.ringSize)
    }

    private var geekCPUTemperatureRing: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("CPU 温度三级详情", "CPU Temperature Deep Detail"),
            chartRangeMetric: .temperature,
            popoverSize: GeekSensorPowerHoverDetailMetrics.sensorHistorySize
        ) {
            GeekIStatSensorRing(
                title: "CPU",
                value: temperatureValue.map(geekCompactTemperature) ?? "—",
                // iStat: the temperature over the frequency, as on the overview.
                detail: temperatureValue == nil ? nil : geekCompactFrequencyText,
                progress: temperatureValue.map { min(1, max(0, $0 / 100)) },
                tint: temperatureTint
            )
            .help(L10n.text(
                "芯片温度汇总；温度弧范围为 0–100°C，并非 CPU 占用率。",
                "Aggregated chip temperature; the arc spans 0–100°C, not CPU utilization."
            ))
        } detail: {
            GeekSensorMetricHoverDetail(
                title: L10n.text("CPU 温度", "CPU Temperature"),
                currentValue: metricValue(.chipTemperature),
                points: geekMetricHistory(.temperature),
                channel: .chipTemperature,
                unit: .temperature,
                valueRange: 0...100,
                tint: temperatureTint,
                duration: geekMetricRange(.temperature).duration,
                isUpdating: geekMetricIsUpdating(.temperature)
            )
        }
    }

    private var geekGPUTemperatureRing: some View {
        let gpuTemperatureChannel = geekGPUTemperature.map { _ in
            MenuBarTelemetryChannel.gpuTemperature
        }
        return GeekHoverDetailTarget(
            accessibilityLabel: L10n.text(
                "GPU 温度三级详情",
                "GPU Temperature Deep Detail"
            ),
            chartRangeMetric: .temperature,
            popoverSize: GeekSensorMetricHoverDetail.popoverSize(
                extraRowCount: metricAvailable(.gpuUsage) ? 1 : 0,
                hasNote: false
            )
        ) {
            GeekIStatSensorRing(
                title: "GPU",
                value: geekGPUTemperature.map(geekCompactTemperature) ?? metricValue(.gpuUsage),
                detail: geekGPURingDetail,
                progress: geekGPUTemperature.map { min(1, max(0, $0 / 100)) }
                    ?? metricPercent(.gpuUsage),
                tint: geekGPUTemperature.map(geekTemperatureTint) ?? resolvedGPUTint
            )
            .help(geekGPUTemperature != nil
                ? L10n.text("GPU 温度；温度弧范围为 0–100°C。", "GPU temperature; the arc spans 0–100°C.")
                : L10n.text("GPU 温度不可用；当前显示负载，范围为 0–100%。", "GPU temperature is unavailable; showing utilization on a 0–100% scale."))
        } detail: {
            GeekSensorMetricHoverDetail(
                title: L10n.text("GPU 温度", "GPU Temperature"),
                currentValue: geekGPUTemperature.map { IStatNumberFormat.temperature($0) }
                    ?? PanelChartSampling.statusText,
                points: geekMetricHistory(.temperature),
                channel: gpuTemperatureChannel,
                unit: .temperature,
                valueRange: 0...100,
                tint: geekGPUTemperature.map(geekTemperatureTint) ?? resolvedGPUTint,
                duration: geekMetricRange(.temperature).duration,
                secondaryTitle: metricAvailable(.gpuUsage)
                    ? L10n.text("负载", "Load")
                    : nil,
                secondaryValue: metricAvailable(.gpuUsage) ? metricValue(.gpuUsage) : nil,
                isUpdating: geekMetricIsUpdating(.temperature)
            )
        }
    }

    /// The fan ring opens the fan speed history, as the fan rows do; a Mac
    /// without fans has no history to open.
    @ViewBuilder
    private var geekFanRing: some View {
        // Same exit as the fan speed history (GeekFanHoverDetail).
        let ring = GeekSensorFanRing(telemetry: geekFanTelemetry, tint: panelMetricColors.sensorGraph(chartAccent: panelChartAccentColor))
        if geekFanTelemetry.isFanless {
            ring
        } else {
            GeekHoverDetailTarget(
                accessibilityLabel: L10n.text("风扇转速三级详情", "Fan Speed Deep Detail"),
                chartRangeMetric: .fan,
                popoverSize: GeekFanHoverDetail.popoverSize(selectedFanIndex: nil, readingCount: geekFanReadings.count)
            ) {
                ring
            } detail: {
                geekFanHoverDetail
            }
        }
    }

    /// D119: one 15 pt row per zone in a single column (iStat's temperature
    /// group); the hardware probes list is the group's last row (was a
    /// two-column grid and a card of its own).
    private var geekTemperatureCard: some View {
        let showsProbes = !geekDetailedTemperatures.isEmpty
        return GeekIStatRowsCard(
            title: L10n.text("温度", "TEMPERATURE"),
            rowCount: geekDisplayedTemperatures.count + (showsProbes ? 1 : 0)
        ) {
            ForEach(geekDisplayedTemperatures) { reading in
                geekTemperatureRow(reading)
            }
            if showsProbes {
                geekDetailedTemperatureRow
            }
        }
    }

    private var geekDetailedTemperatures: [SystemTemperatureDetailReading] {
        monitorSnapshot?.temperatureDetails ?? []
    }

    private var geekDetailedTemperatureRow: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("全部核心与硬件温度", "All Core & Hardware Temperatures"),
            popoverSize: geekDetailedTemperaturesPopoverSize,
            selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset
        ) {
            GeekIStatRow(
                title: L10n.text("硬件探头", "Hardware Probes"),
                value: L10n.text("\(ByteFormat.count(geekDetailedTemperatures.count)) 项", "\(ByteFormat.count(geekDetailedTemperatures.count)) Sensors"),
                valueColor: .secondary
            )
        } detail: {
            GeekDetailedTemperaturesDetail(
                readings: geekDetailedTemperatures,
                sampledAt: monitorSnapshot?.sensorReadingDate
            )
        }
    }

    /// D122: the probe card (was 60 + 20 per grid row).
    private var geekDetailedTemperaturesPopoverSize: CGSize {
        GeekDetailedTemperaturesDetail.popoverSize(
            readingCount: geekDetailedTemperatures.count,
            hasSample: monitorSnapshot?.sensorReadingDate != nil
        )
    }

    /// D119: a titled group of 15 pt readout rows (iStat's sensor groups),
    /// each opening its source, sample and note (level three).
    func geekSensorReadoutCard(_ title: String, rows: [GeekSensorReadout]) -> some View {
        geekSensorReadoutCard(title, rows: rows, extraRowCount: 0) { EmptyView() }
    }

    /// The group with `extraRowCount` rows of the caller's after the
    /// readouts (the power group's helper state).
    func geekSensorReadoutCard<Extra: View>(
        _ title: String,
        rows: [GeekSensorReadout],
        extraRowCount: Int,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        GeekIStatRowsCard(title: title, rowCount: rows.count + extraRowCount) {
            ForEach(rows) { readout in
                GeekHoverDetailTarget(
                    accessibilityLabel: "\(readout.title)\(L10n.text("详情", " Details"))",
                    popoverSize: GeekSensorReadoutLayout.detailSize(readout),
                    selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset
                ) {
                    HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                        Text(readout.title)
                            .geekIStatLabelText()
                        Spacer(minLength: 4)
                        if readout.isUpdating {
                            Text(HardwareReadingText.updating)
                                .geekIStatValueText(.secondary)
                        }
                        Text(readout.value)
                            .geekIStatValueText(readout.isUpdating ? .secondary : .primary)
                    }
                    .frame(height: GeekIStatSectionGeometry.rowHeight)
                    .accessibilityElement(children: .combine)
                } detail: {
                    GeekSensorReadoutDetail(readout: readout)
                }
            }
            extra()
        }
    }

    /// Monitoring and control are deliberately separate surfaces (the iStat
    /// model). This group only *reads*: per-fan speeds with hover history and
    /// the current mode. All mode switches and sliders live exclusively in
    /// the attached control palette, so interacting with monitoring UI can
    /// never change the hardware state.
    /// D119: iStat's fan group (24 + 17n): a 15 pt row per fan, then our fan
    /// control entry and the thermal state as rows; the helper action is the
    /// title row's trailing text (was a capsule above 24 pt rows).
    private var geekHardwareControlSummaryCard: some View {
        GeekIStatRowsCard(title: L10n.text("风扇", "FANS"), rowCount: geekFanGroupRowCount) {
            if !geekFanTelemetry.isFanless, geekHelperState != .enabled, fanControl.offersHelperConnectionAction {
                Button(action: compactHelperAction) {
                    HStack(spacing: 4) {
                        if fanControl.isPreparingHelper || fanControl.isRefreshingConnection {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(compactHelperActionTitle)
                            .geekIStatValueText(helperSummaryTint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .disabled(fanControl.isDataOnlyFixture || (compactHelperActionIsReconnect && fanControl.helperReconnectWaitSeconds > 0))
                .help(compactHelperHelp)
                .accessibilityLabel(L10n.text("高级控制状态", "Advanced Control Status"))
                .accessibilityValue(FanStatusPresentation.controlTitle(geekFanControlCapabilityState))
            }
        } rows: {
            if geekFanTelemetry.readings.isEmpty {
                Text(geekFanTelemetry.isFanless
                    ? L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling")
                    : geekFanTelemetry.isSampling
                        ? L10n.text("正在检测风扇…", "Checking Fans…")
                        : L10n.text("风扇读数不可用", "Fan readings unavailable"))
                    .geekIStatLabelText()
                    .frame(maxWidth: .infinity, minHeight: GeekIStatSectionGeometry.rowHeight,
                           maxHeight: GeekIStatSectionGeometry.rowHeight, alignment: .leading)
            } else {
                ForEach(geekFanTelemetry.readings.prefix(2)) { reading in
                    compactFanHistoryRow(reading)
                }
            }

            if !geekFanTelemetry.isFanless {
                geekFanControlEntryRow
            }

            if geekFanThermallyProtected {
                Text(L10n.text("热保护中", "Thermal protection"))
                    .geekIStatValueText(AppDesignTokens.Palette.warning)
                    .frame(maxWidth: .infinity, minHeight: GeekIStatSectionGeometry.rowHeight,
                           maxHeight: GeekIStatSectionGeometry.rowHeight, alignment: .leading)
            }
        }
    }

    var geekFanControlEntryPresentation: FanControlEntryPresentation {
        let fractions = Array(fanControl.confirmedManualFractionByFan.values)
        let confirmedPercentage = fractions.isEmpty ? nil
            : fractions.reduce(0, +) / Double(fractions.count) * 100
        return FanControlEntryPresentation(telemetry: geekFanTelemetry, helperState: geekHelperState,
            observedMode: geekObservedFanMode, manualPercentage: geekPreviewManualPercentage ?? confirmedPercentage)
    }

    var geekFanControlEntryRow: some View {
        FanControlEntryRow(state: geekFanControlEntryPresentation)
    }

    private var geekFanThermallyProtected: Bool {
        let state = monitorSnapshot?.thermalState
        return state == .serious || state == .critical
    }

    /// The fans (at most two, D73) or their state, the control entry and
    /// the thermal state.
    private var geekFanGroupRowCount: Int {
        max(1, min(2, geekFanTelemetry.readings.count))
            + (geekFanTelemetry.isFanless ? 0 : 1)
            + (geekFanThermallyProtected ? 1 : 0)
    }

    private func compactFanHistoryRow(_ reading: SystemFanReading) -> some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            GeekHoverDetailTarget(
                accessibilityLabel: L10n.text("\(reading.displayName)转速历史", "\(reading.displayName) Speed History"),
                chartRangeMetric: .fan,
                popoverSize: GeekFanHoverDetail.popoverSize(selectedFanIndex: reading.index,
                                                            readingCount: geekFanTelemetry.readings.count),
                selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset
            ) {
                Text(reading.displayName)
                    .geekIStatLabelText()
                    .frame(maxWidth: .infinity, minHeight: GeekIStatSectionGeometry.rowHeight, alignment: .leading)
            } detail: {
                GeekFanHoverDetail(
                    points: geekMetricHistory(.fan),
                    duration: geekMetricRange(.fan).duration,
                    currentValue: reading.displayRPM,
                    readings: geekFanTelemetry.readings,
                    valueRange: 0...fanTrendMaximum,
                    selectedFanIndex: reading.index,
                    isUpdating: geekMetricIsUpdating(.fan)
                )
            }
            ControlPaletteHoverAnchor(
                kind: .fan,
                accessibilityLabel: L10n.text("\(reading.displayName)风扇控制", "\(reading.displayName) Fan Control"),
                selectedFanIndex: reading.index
            ) {
                Text(reading.displayRPM)
                    .geekIStatValueText()
                    .frame(minHeight: GeekIStatSectionGeometry.rowHeight, alignment: .trailing)
            }
        }
        .frame(height: GeekIStatSectionGeometry.rowHeight)
    }

    private var helperSummaryTint: Color {
        switch geekFanControlCapabilityState {
        case .controllable:
            panelMetricColors.sensorGraph
        case .checking, .authorizationRequired, .requiresSystemApproval, .readOnly:
            AppDesignTokens.Palette.information
        case .unsupported, .connectionFailed:
            AppDesignTokens.Palette.warning
        }
    }

    private var compactHelperHelp: String {
        geekHardwareControlMessage ?? L10n.text(
            "设置高级风扇控制",
            "Set up advanced fan controls"
        )
    }

    private var compactHelperActionTitle: String {
        switch geekHelperState {
        case .notRegistered, .unavailable: L10n.text("启用控制", "Enable Controls")
        case .requiresApproval: L10n.text("完成授权", "Finish Setup")
        case .enabled, .connectionInterrupted, .signatureRejected: fanControl.helperReconnectTitle
        }
    }

    private var compactHelperActionIsReconnect: Bool {
        [.enabled, .connectionInterrupted, .signatureRejected].contains(geekHelperState)
    }

    private func compactHelperAction() {
        switch geekHelperState {
        // `unavailable` includes launchd's pre-submission state, so it must
        // attempt registration rather than only retrying a connection that
        // cannot exist yet.
        case .notRegistered, .unavailable:
            Task { await fanControl.registerHelper() }
        case .requiresApproval:
            fanControl.openApprovalSettings()
        case .enabled, .connectionInterrupted, .signatureRejected:
            Task { await fanControl.reconnectHelper() }
        }
    }

    private var geekRegionalTemperatureByZone: [SystemTemperatureZone: SystemTemperatureReading] {
        var byZone = Dictionary(
            uniqueKeysWithValues: (monitorSnapshot?.temperatureReadings ?? [])
                .filter { $0.celsius.isFinite }
                .map { ($0.zone, $0) }
        )
        if hasInternalBattery,
           let batteryTemperature = batteryElectricalSnapshot?.temperatureCelsius,
           batteryTemperature.isFinite {
            byZone[.battery] = SystemTemperatureReading(
                zone: .battery,
                celsius: batteryTemperature
            )
        }
        let hasChipRegion = [.chip, .soc, .performanceCores, .superCores, .efficiencyCores]
            .contains { byZone[$0] != nil }
        if !hasChipRegion, let temperatureValue {
            byZone[.chip] = SystemTemperatureReading(zone: .chip, celsius: temperatureValue)
        }
        return byZone
    }

    private var geekDisplayedTemperatures: [SystemTemperatureReading] {
        let byZone = geekRegionalTemperatureByZone
        return GeekTemperatureZoneLayout
            .displayZones(available: Set(byZone.keys))
            .compactMap { byZone[$0] }
    }

    /// D119: the sensors page's current and voltage groups (were the power
    /// page's battery electrical card).
    var geekBatteryCurrentReadouts: [GeekSensorReadout] {
        GeekBatteryElectricalReadouts.currentRows(electrical: batteryElectricalSnapshot)
    }

    var geekBatteryVoltageReadouts: [GeekSensorReadout] {
        GeekBatteryElectricalReadouts.voltageRows(electrical: batteryElectricalSnapshot)
    }

    var geekPowerReadouts: [GeekSensorReadout] {
        GeekPowerReadouts.rows(
            hasInternalBattery: hasInternalBattery,
            powerSource: batterySnapshot?.powerSource
                ?? (hasInternalBattery ? nil : .acPower),
            telemetry: powerTelemetry,
            electrical: batteryElectricalSnapshot,
            now: powerTelemetryReferenceDate
        )
    }

    /// Debug scenarios only: the power rows with another chip breakdown.
    func geekDebugPowerReadouts(soc: SoCPowerReading) -> [GeekSensorReadout] {
        guard var telemetry = powerTelemetry else { return [] }
        telemetry.soc = soc
        return GeekPowerReadouts.rows(
            hasInternalBattery: hasInternalBattery,
            powerSource: batterySnapshot?.powerSource
                ?? (hasInternalBattery ? nil : .acPower),
            telemetry: telemetry,
            electrical: batteryElectricalSnapshot,
            now: powerTelemetryReferenceDate
        )
    }

    var geekFrequencyReadouts: [GeekSensorReadout] {
        GeekProcessorFrequencyPresentation.rows(telemetry: processorTelemetry,
            sampledAt: auxiliaryState.processorTelemetryRefreshedAt)
    }

    /// The overview's and the sensors page's GPU ring detail: the GPU
    /// frequency like the CPU ring's (iStat), when it was read.
    var geekCompactGPUFrequencyText: String? {
        processorTelemetry?.gpu.map(GeekGPUFrequencyPresentation.value)
    }

    var geekGPUTemperature: Double? {
        geekDisplayedTemperatures.first { $0.zone == .gpu }?.celsius
    }

    private var geekGPURingDetail: String? {
        // BOARD N16-1: below a temperature, the frequency (like the CPU ring).
        if geekGPUTemperature != nil, let frequency = geekCompactGPUFrequencyText {
            return frequency
        }
        guard metricAvailable(.gpuUsage) else { return nil }
        return geekGPUTemperature == nil
            ? L10n.text("负载", "Load")
            : metricValue(.gpuUsage)
    }

    private var geekHasSensorGaugeData: Bool {
        temperatureValue != nil
            || geekGPUTemperature != nil
            || metricAvailable(.gpuUsage)
            || !geekFanReadings.isEmpty
    }

    private var geekSensorPageAvailability: GeekSensorPageAvailability {
        GeekSensorPageAvailability.resolve(
            reportedAvailability: monitorSnapshot?.sensorAvailability ?? .sampling,
            hasSensorData: geekHasSensorGaugeData
                || !geekDisplayedTemperatures.isEmpty
                || !geekDetailedTemperatures.isEmpty
                || !geekFanReadings.isEmpty
                || processorTelemetry?.clusters.contains(where: { $0.frequencyMHz != nil }) == true
                || (hasInternalBattery && batteryElectricalSnapshot?.hasBatteryData == true)
        )
    }

    var geekFanTelemetry: FanTelemetryState {
        FanTelemetryState.resolve(snapshot: monitorSnapshot)
    }

    private var geekFanReadings: [SystemFanReading] {
        geekFanTelemetry.readings
    }

    private var geekFanAverageRPM: Int? {
        geekFanTelemetry.actualRPM
    }

    var geekHelperState: HelperState {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.helperState
        }
#endif
        return fanControl.helperState
    }

    var geekObservedFanMode: GeekFanControlMode? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.observedMode
        }
#endif
        return fanControl.observedMode
    }

    var geekFanControlModeState: FanControlMode {
        FanControlMode.resolve(observedMode: geekObservedFanMode)
    }

    var geekFanControlCapabilityState: FanControlCapability {
        FanControlCapability.resolve(
            telemetry: geekFanTelemetry,
            helperState: geekHelperState
        )
    }

    private var geekHardwareThermalState: SystemThermalState {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.thermalState
        }
#endif
        return monitorSnapshot?.thermalState ?? .nominal
    }

    private var geekHardwareControlMessage: String? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.message
        }
#endif
        return fanControl.lastMessage
    }

    private var geekPreviewManualPercentage: Double? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.manualPercentage
        }
#endif
        return nil
    }

    private var geekPowerModes: BatteryPowerModes {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.powerModes
        }
#endif
        return computerHealthStore.batteryPowerModes
    }

    private var geekPowerModeCapability: PowerModeCapability {
        PowerModeCapability.resolve(
            modes: geekPowerModes,
            hasCompletedRead: geekHasCompletedPowerModeRead,
            helperState: geekHelperState
        )
    }

    private var geekHasCompletedPowerModeRead: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return true }
#endif
        return computerHealthStore.hasCompletedBatteryPowerModeRead
    }

    private var geekFanModeOrCapabilityTitle: String {
        FanStatusPresentation.confirmedModeTitle(fanControl.observedMode)
    }

    private var geekFanHoverDetail: some View {
        GeekFanHoverDetail(
            points: geekMetricHistory(.fan),
            duration: geekMetricRange(.fan).duration,
            currentValue: geekFanAverageRPM.map(SystemFanSpeedFormat.string)
                ?? L10n.text("未采集", "Not Collected"),
            readings: geekFanReadings,
            valueRange: 0...fanTrendMaximum,
            selectedFanIndex: nil,
            isUpdating: geekMetricIsUpdating(.fan)
        )
    }

    private func geekTemperatureRow(_ reading: SystemTemperatureReading) -> some View {
        let zone = reading.zone
        let detail = geekTemperatureDetail(reading)
        return GeekHoverDetailTarget(
            accessibilityLabel: L10n.text(
                "\(geekTemperatureZoneTitle(zone))温度三级详情",
                "\(geekTemperatureZoneTitle(zone)) Temperature Deep Detail"
            ),
            chartRangeMetric: .temperature,
            popoverSize: detail.size,
            selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset
        ) {
            geekTemperatureRowContent(zone: zone, reading: reading)
        } detail: {
            detail.view
        }
    }

    /// A temperature row's third level and its popover size. D57: the CPU
    /// row adds the hottest and average core; zones named from SMC keys
    /// alone say so.
    private func geekTemperatureDetail(
        _ reading: SystemTemperatureReading
    ) -> (view: GeekSensorMetricHoverDetail, size: CGSize) {
        let zone = reading.zone
        let detailRows = GeekTemperatureRowDetail.rows(
            zone: zone,
            celsius: reading.celsius,
            details: geekDetailedTemperatures
        )
        let note = GeekTemperatureRowDetail.note(
            zone: zone,
            inferredZones: monitorSnapshot?.inferredTemperatureZones ?? []
        )
        let view = GeekSensorMetricHoverDetail(
            title: geekTemperatureZoneTitle(zone),
            currentValue: IStatNumberFormat.temperature(reading.celsius),
            points: geekMetricHistory(.temperature),
            channel: MenuBarTelemetryChannel.temperature(zone),
            unit: .temperature,
            valueRange: 0...100,
            tint: geekTemperatureTint(reading.celsius),
            duration: geekMetricRange(.temperature).duration,
            detailRows: detailRows,
            note: note,
            isUpdating: geekMetricIsUpdating(.temperature)
        )
        return (view, GeekSensorMetricHoverDetail.popoverSize(
            extraRowCount: detailRows.count,
            hasNote: note != nil
        ))
    }

#if DEBUG || STORAGE_CLEANER_BETA
    /// Debug snapshot scenarios (D57 screenshots) open the same detail
    /// views as the hover targets.
    func geekDebugTemperatureDetail(_ zone: SystemTemperatureZone) -> (view: AnyView, size: CGSize)? {
        guard let reading = geekDisplayedTemperatures.first(where: { $0.zone == zone }) else { return nil }
        let detail = geekTemperatureDetail(reading)
        return (AnyView(detail.view), detail.size)
    }

    var geekDebugHardwareProbesDetail: (view: AnyView, size: CGSize) {
        (
            AnyView(GeekDetailedTemperaturesDetail(
                readings: geekDetailedTemperatures,
                sampledAt: monitorSnapshot?.sensorReadingDate
            )),
            geekDetailedTemperaturesPopoverSize
        )
    }

    var geekDebugAmbientLightReadout: GeekSensorReadout? {
        GeekAmbientLightReadout.readout(monitorSnapshot?.ambientLight, sampledAt: monitorSnapshot?.sensorReadingDate)
    }
#endif

    private func geekTemperatureRowContent(
        zone: SystemTemperatureZone,
        reading: SystemTemperatureReading
    ) -> some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            Text(geekTemperatureZoneTitle(zone))
                .geekIStatLabelText()
            Spacer(minLength: 4)
            Text(geekCompactTemperature(reading.celsius))
                .geekIStatValueText(geekTemperatureValueForeground(reading.celsius))
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GeekIStatSectionGeometry.rowHeight,
            maxHeight: GeekIStatSectionGeometry.rowHeight,
            alignment: .leading
        )
        .help(L10n.text("查看历史趋势", "View History Trend"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(geekTemperatureZoneTitle(zone))
        .accessibilityValue(IStatNumberFormat.temperature(reading.celsius))
    }

    private func geekTemperatureZoneTitle(_ zone: SystemTemperatureZone) -> String {
        switch zone {
        case .chip: "CPU"
        case .soc: "SoC"
        case .performanceCores: L10n.text("CPU 性能核心", "CPU P-Cores")
        case .superCores: L10n.text("CPU 超级核心", "CPU Super Cores")
        case .efficiencyCores: L10n.text("CPU 能效核心", "CPU E-Cores")
        case .gpu: "GPU"
        case .storage: "SSD"
        case .battery: L10n.text("电池", "Battery")
        case .ambient: L10n.text("散热气流", "Airflow")
        case .palmRest: L10n.text("掌托", "Palm Rest")
        case .thunderboltLeft: L10n.text("左侧雷雳", "Thunderbolt Left")
        case .thunderboltRight: L10n.text("右侧雷雳", "Thunderbolt Right")
        case .wifi: "Wi-Fi"
        case .chargingCircuit: L10n.text("充电电路", "Charging Circuit")
        }
    }

    /// "80°" (the sensors rings and, D43, the CPU card's title). D128:
    /// iStat's whole degrees without the scale (was "%.0f°C").
    func geekCompactTemperature(_ value: Double) -> String {
        IStatNumberFormat.temperature(value)
    }

    /// One temperature color rule for every ring and history that shows a
    /// temperature (sensors page, CPU page GPU card, overview rings).
    func geekTemperatureTint(_ value: Double) -> Color {
        panelMetricColors.temperature(value, chartAccent: panelChartAccentColor)
    }

    private func geekTemperatureValueForeground(_ value: Double) -> Color {
        value >= 80 ? geekTemperatureTint(value) : .primary
    }
}

/// D57: ambient light (`CurrentLux`) on the sensors page, in lux.
enum GeekAmbientLightReadout {
    static func readout(_ reading: HardwareReading<Double>?, sampledAt: Date?) -> GeekSensorReadout? {
        guard let reading, reading.isSupported else { return nil }
        let source = L10n.text("环境光传感器 CurrentLux", "Ambient light sensor CurrentLux")
        let note = L10n.text("环境光传感器测得的照度，单位勒克斯（lx）", "Illuminance measured by the ambient light sensor, in lux (lx)")
        guard let lux = reading.value else {
            return GeekSensorReadout(
                id: "ambient-light", title: L10n.text("光照", "Light"),
                value: HardwareReadingText.invalidValue, source: source,
                note: "\(HardwareReadingText.invalid) · \(note)", sampledAt: sampledAt
            )
        }
        return GeekSensorReadout(
            id: "ambient-light", title: L10n.text("光照", "Light"),
            value: IStatNumberFormat.light(lux), source: source, note: note, sampledAt: sampledAt
        )
    }
}

/// D57: the extra third-level readings of a temperature row.
enum GeekTemperatureRowDetail {
    /// The CPU row reads the level-one ring's value (the hottest core); its
    /// third level adds the hottest and the average of the CPU probes. The
    /// count is of sensors, not cores: M5 has a probe per core, M1–M4 a
    /// few per cluster (review item 9).
    static func rows(
        zone: SystemTemperatureZone,
        celsius: Double,
        details: [SystemTemperatureDetailReading]
    ) -> [GeekSensorReadoutDetailRow] {
        guard zone == .chip else { return [] }
        let cores = details.filter {
            guard let zone = $0.zone else { return false }
            return [.superCores, .performanceCores, .efficiencyCores].contains(zone)
        }.map(\.celsius)
        var rows = [GeekSensorReadoutDetailRow(L10n.text("最高", "Hottest"), HardwareReadingText.celsius(celsius))]
        if !cores.isEmpty {
            rows.append(GeekSensorReadoutDetailRow(
                L10n.text("平均（\(ByteFormat.count(cores.count)) 个传感器）", "Average (\(ByteFormat.count(cores.count)) sensors)"),
                HardwareReadingText.celsius(cores.reduce(0, +) / Double(cores.count))
            ))
        }
        return rows
    }

    static func note(
        zone: SystemTemperatureZone,
        inferredZones: Set<SystemTemperatureZone>
    ) -> String? {
        guard inferredZones.contains(zone) else { return nil }
        return L10n.text(
            "依据键名推断：该位置的传感器没有公开定义",
            "Inferred from the key name: this sensor has no public definition"
        )
    }
}

enum GeekTemperatureZoneLayout {
    static func displayZones(
        available: Set<SystemTemperatureZone>
    ) -> [SystemTemperatureZone] {
        let orderedZones: [SystemTemperatureZone] = [
            .chip,
            .soc,
            .performanceCores,
            .efficiencyCores,
            .superCores,
            .gpu,
            .storage,
            .battery,
            .chargingCircuit,
            .ambient,
            .palmRest,
            .thunderboltLeft,
            .thunderboltRight,
            .wifi
        ]
        return orderedZones.filter(available.contains)
    }
}
