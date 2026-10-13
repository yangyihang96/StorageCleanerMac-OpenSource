import SwiftUI

enum GeekSensorTemperatureLayout {
    static let chromeHeight: CGFloat = 26
    static let rowHeight: CGFloat = 16
    static let gridRowHeight: CGFloat = 18
    static let gridColumnSpacing: CGFloat = 10
    static let gaugeSpacing: CGFloat = 24
    static let miniRingSize: CGFloat = 14
    static let fontSize: CGFloat = 11

    static func cardHeight(rowCount: Int) -> CGFloat {
        chromeHeight + CGFloat(max(0, rowCount)) * rowHeight
    }

    static func temperatureGridRowCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount + 1) / 2
    }

    static func temperatureCardHeight(itemCount: Int) -> CGFloat {
        chromeHeight
            + CGFloat(temperatureGridRowCount(itemCount: itemCount)) * gridRowHeight
    }
}

enum GeekSensorSummaryLayout {
    static let ringSize: CGFloat = 62
    static let spacing = GeekSensorTemperatureLayout.gaugeSpacing
    static let cardHeight = ringSize + 2 * MiniWindowStyleTokens.cardVerticalInset
}

struct GeekSensorSummaryCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeekCombinedCard(height: GeekSensorSummaryLayout.cardHeight) {
            HStack(spacing: GeekSensorSummaryLayout.spacing) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
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
                ? L10n.text("\(telemetry.fanCount) 个风扇的平均转速：\(formattedRPM) rpm。", "Average speed across \(telemetry.fanCount) fans: \(formattedRPM) rpm.")
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
        GeekCombinedRing(
            title: L10n.text("风扇", "FANS"),
            value: presentation.value,
            detail: presentation.caption,
            progress: telemetry.percentage.map { $0 / 100 },
            tint: tint,
            size: GeekSensorSummaryLayout.ringSize,
            labelPlacement: .aboveValue,
            fixedDetailFontSize: 8.5
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
    static func cardHeight(rowCount: Int) -> CGFloat {
        26 + CGFloat(rowCount) * 23
    }

    /// A readout's third level: the source, sample and note rows, plus one
    /// row per extra detail (input voltage, brightness, chip blocks…).
    static func detailSize(extraRowCount: Int) -> CGSize {
        CGSize(width: 270, height: 190 + CGFloat(max(0, extraRowCount)) * 18)
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
                [GeekSensorReadoutDetailRow(L10n.text("协商功率", "Negotiated"), String(format: "%.0f W", $0))]
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
                "；与系统控制器的芯片功率估计相差 \(String(format: "%.1f", abs(watts - referenceWatts))) W",
                "; differs from the SMC chip estimate by \(String(format: "%.1f", abs(watts - referenceWatts))) W"
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
        guard let electrical else { return [] }
        let isSMC = electrical.electricalSource == .smc
        let controllerNote = L10n.text("电池控制器约每分钟才更新一次", "The battery controller updates only about once a minute")
        var rows: [GeekSensorReadout] = []
        if let row = row(
            id: "battery-current",
            title: L10n.text("电池电流", "Battery Current"),
            reading: electrical.currentReading,
            format: HardwareReadingText.signedAmps,
            source: isSMC ? "SMC B0AC" : "AppleSmartBattery",
            note: isSMC
                ? L10n.text("带符号的电池电流，负值为放电；约每秒更新", "Signed battery current, negative while discharging; updated about every second")
                : controllerNote,
            sampledAt: electrical.generatedAt
        ) {
            rows.append(row)
        }
        if let row = row(
            id: "battery-voltage",
            title: L10n.text("电池电压", "Battery Voltage"),
            reading: electrical.voltageReading,
            format: { String(format: "%.2f V", $0) },
            source: isSMC ? "SMC B0AV" : "AppleSmartBattery",
            note: isSMC
                ? L10n.text("电池端电压；约每秒更新", "Battery terminal voltage; updated about every second")
                : controllerNote,
            sampledAt: electrical.generatedAt
        ) {
            rows.append(row)
        }
        return rows
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
            String(format: "%.2f GHz", frequency / 1_000)
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
                title: L10n.text("核心组 \(index + 1) · \(cluster.coreCount) 核", "Cluster \(index + 1) · \(cluster.coreCount) cores"),
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
    static func value(_ reading: CPUPerformanceStateService.GPUReading?) -> String {
        guard let reading else { return "—" }
        guard let frequency = reading.frequencyMHz else { return idleTitle }
        return gigahertz(frequency)
    }

    /// A ring's value and unit: "0.34" + "GHz", "空闲", or "—".
    static func ringValue(_ reading: CPUPerformanceStateService.GPUReading?) -> (value: String, unit: String?) {
        guard let reading else { return ("—", nil) }
        guard let frequency = reading.frequencyMHz else { return (idleTitle, nil) }
        return (String(format: "%.2f", frequency / 1_000), "GHz")
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
        String(format: "%.2f GHz", megahertz / 1_000)
    }
}

struct GeekSensorReadoutDetail: View {
    let readout: GeekSensorReadout

    var body: some View {
        GeekHoverDetailCanvas(title: readout.title, trailing: readout.value) {
            GeekHoverValueRow(title: L10n.text("来源", "Source"), value: readout.source)
            if let sampledAt = readout.sampledAt {
                GeekHoverValueRow(
                    title: L10n.text("采样", "Sampled"),
                    value: readout.isUpdating
                        ? "\(sampledAt.formatted(date: .omitted, time: .standard)) · \(HardwareReadingText.updating)"
                        : sampledAt.formatted(date: .omitted, time: .standard)
                )
            }
            ForEach(readout.detailRows) { row in
                GeekHoverValueRow(
                    title: row.title,
                    value: row.isUpdating && !row.value.hasSuffix("…")
                        ? "\(row.value) · \(HardwareReadingText.updating)"
                        : row.value
                )
                .padding(.leading, row.isIndented ? GeekSensorReadoutLayout.childIndent : 0)
            }
            Text(readout.note)
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Individual probes are snapshot-only. Present all of them together as a
/// current-reading inspector; a regional history must not be labelled as the
/// history of a particular core or SMC probe.
struct GeekDetailedTemperaturesDetail: View {
    let readings: [SystemTemperatureDetailReading]
    let sampledAt: Date?

    var body: some View {
        GeekHoverDetailCanvas(
            title: L10n.text("核心与硬件温度", "Core & Hardware Temperature"),
            trailing: L10n.text("\(readings.count) 项", "\(readings.count) Sensors")
        ) {
            LazyVGrid(
                // The same two-column grid as the sensors card; its 10 pt
                // column gap is calibrated geometry (GeekSensorsPowerHoverDetailTests).
                columns: [
                    GridItem(.flexible(), spacing: GeekSensorTemperatureLayout.gridColumnSpacing),
                    GridItem(.flexible()),
                ],
                alignment: .leading,
                spacing: 2
            ) {
                ForEach(readings) { reading in
                    HStack(spacing: 4) {
                        Text(reading.name)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(String(format: "%.0f°C", reading.celsius))
                            .foregroundStyle(reading.celsius >= 90
                                ? AppDesignTokens.Palette.destructive
                                : reading.celsius >= 80
                                    ? AppDesignTokens.Palette.warning
                                    : .primary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .font(AdvancedPanelTypography.caption)
                    .frame(minHeight: 18)
                    .help(reading.sourceHelp)
                    .accessibilityElement(children: .combine)
                }
            }
            if let sampledAt {
                Text(L10n.text("采样 \(sampledAt.formatted(date: .omitted, time: .standard))", "Sampled \(sampledAt.formatted(date: .omitted, time: .standard))"))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension MenuBarAdvancedStatusView {
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
                if !geekDisplayedTemperatures.isEmpty {
                    geekTemperatureCard
                }
                if !geekDetailedTemperatures.isEmpty {
                    geekDetailedTemperatureCard
                }
            }

                }
            }
            geekHelperPowerMetricsCards
            liveCard(.controls) { geekHardwareControlSummaryCard }
                .id(GeekHardwareDetailFocus.power)
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
            geekSensorReadoutCard(L10n.text("环境", "ENVIRONMENT"), rows: [readout])
        }
    }

    private func geekSensorStatusCard(_ text: String) -> some View {
        GeekCombinedCard(height: 43) {
            Text(text)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .accessibilityLabel(text)
        }
    }

    private var geekSensorsGaugeCard: some View {
        GeekSensorSummaryCard {
            if let temperatureValue {
                GeekHoverDetailTarget(
                    accessibilityLabel: L10n.text("CPU 温度三级详情", "CPU Temperature Deep Detail"),
                    chartRangeMetric: .temperature,
                    popoverSize: GeekSensorPowerHoverDetailMetrics.sensorHistorySize
                ) {
                    GeekCombinedRing(
                        title: "CPU",
                        value: geekCompactTemperature(temperatureValue),
                        progress: min(1, max(0, temperatureValue / 100)),
                        tint: temperatureTint,
                        size: GeekSensorSummaryLayout.ringSize,
                        labelPlacement: .aboveValue
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

            if geekGPUTemperature != nil || metricAvailable(.gpuUsage) {
                let gpuTemperatureChannel = geekGPUTemperature.map { _ in
                    MenuBarTelemetryChannel.gpuTemperature
                }
                GeekHoverDetailTarget(
                    accessibilityLabel: L10n.text(
                        "GPU 温度三级详情",
                        "GPU Temperature Deep Detail"
                    ),
                    chartRangeMetric: .temperature,
                    popoverSize: GeekSensorPowerHoverDetailMetrics.sensorHistorySize
                ) {
                    GeekCombinedRing(
                        title: "GPU",
                        value: geekGPUTemperature.map(geekCompactTemperature) ?? metricValue(.gpuUsage),
                        detail: geekGPURingDetail,
                        progress: geekGPUTemperature.map { min(1, max(0, $0 / 100)) }
                            ?? metricPercent(.gpuUsage),
                        tint: geekGPUTemperature.map(geekTemperatureTint) ?? resolvedGPUTint,
                        size: GeekSensorSummaryLayout.ringSize,
                        labelPlacement: .aboveValue
                    )
                    .help(geekGPUTemperature != nil
                        ? L10n.text("GPU 温度；温度弧范围为 0–100°C。", "GPU temperature; the arc spans 0–100°C.")
                        : L10n.text("GPU 温度不可用；当前显示负载，范围为 0–100%。", "GPU temperature is unavailable; showing utilization on a 0–100% scale."))
                } detail: {
                    GeekSensorMetricHoverDetail(
                        title: L10n.text("GPU 温度", "GPU Temperature"),
                        currentValue: geekGPUTemperature.map { String(format: "%.1f°C", $0) }
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

            // Same exit as the fan speed history (GeekFanHoverDetail).
            GeekSensorFanRing(telemetry: geekFanTelemetry, tint: panelMetricColors.sensorGraph(chartAccent: panelChartAccentColor))
        }
    }

    private var geekTemperatureCard: some View {
        GeekCombinedCard(
            height: GeekSensorTemperatureLayout.temperatureCardHeight(
                itemCount: geekDisplayedTemperatures.count
            )
        ) {
            VStack(alignment: .leading, spacing: 0) {
                geekSensorHeader(L10n.text("温度", "TEMPERATURE"))

                LazyVGrid(
                    columns: [
                        GridItem(
                            .flexible(),
                            spacing: GeekSensorTemperatureLayout.gridColumnSpacing,
                            alignment: .leading
                        ),
                        GridItem(.flexible(), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(geekDisplayedTemperatures) { reading in
                        geekTemperatureRow(reading)
                    }
                }
            }
        }
    }

    private var geekDetailedTemperatures: [SystemTemperatureDetailReading] {
        monitorSnapshot?.temperatureDetails ?? []
    }

    private var geekDetailedTemperatureCard: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("全部核心与硬件温度", "All Core & Hardware Temperatures"),
            popoverSize: CGSize(
                width: MiniWindowStyleTokens.historyWidth,
                height: 60 + CGFloat(GeekSensorTemperatureLayout.temperatureGridRowCount(
                    itemCount: geekDetailedTemperatures.count
                )) * 20
            ),
            usesCardActiveBorder: true
        ) {
            GeekCombinedCard(height: 48) {
                HStack(spacing: 8) {
                    geekSensorHeader(L10n.text("硬件探头", "HARDWARE PROBES"))
                    Spacer(minLength: 2)
                    Text(L10n.text("\(geekDetailedTemperatures.count) 项", "\(geekDetailedTemperatures.count) Sensors"))
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    GeekDisclosureIcon()
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
        } detail: {
            GeekDetailedTemperaturesDetail(
                readings: geekDetailedTemperatures,
                sampledAt: monitorSnapshot?.sensorReadingDate
            )
        }
    }

    func geekSensorReadoutCard(_ title: String, rows: [GeekSensorReadout]) -> some View {
        GeekCombinedCard(height: GeekSensorReadoutLayout.cardHeight(rowCount: rows.count)) {
            VStack(alignment: .leading, spacing: 0) {
                geekSensorHeader(title)
                ForEach(rows) { readout in
                    GeekHoverDetailTarget(
                        accessibilityLabel: "\(readout.title)\(L10n.text("详情", " Details"))",
                        popoverSize: GeekSensorReadoutLayout.detailSize(extraRowCount: readout.detailRows.count),
                        selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset
                    ) {
                        HStack(spacing: 6) {
                            Text(readout.title)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if readout.isUpdating {
                                Text(HardwareReadingText.updating)
                                    .font(AdvancedPanelTypography.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Text(readout.value)
                                .foregroundStyle(readout.isUpdating ? .secondary : .primary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .font(AdvancedPanelTypography.caption)
                        .frame(height: 23)
                        .accessibilityElement(children: .combine)
                    } detail: {
                        GeekSensorReadoutDetail(readout: readout)
                    }
                }
            }
        }
    }

    /// Monitoring and control are deliberately separate surfaces (the iStat
    /// model). This card only *reads*: per-fan speeds with hover history and
    /// the current mode. All mode switches and sliders live exclusively in
    /// the attached control palette, so interacting with monitoring UI can
    /// never change the hardware state.
    private var geekHardwareControlSummaryCard: some View {
        GeekCombinedCard(height: geekFanControlCardHeight) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L10n.text("风扇", "FANS"))
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(panelMetricColors.sectionHeader)
                    Spacer(minLength: 4)
                    if !geekFanTelemetry.isFanless, geekHelperState != .enabled, fanControl.offersHelperConnectionAction {
                        Button(action: compactHelperAction) {
                        MiniWindowStatusCapsule(
                            title: compactHelperActionTitle,
                            tint: helperSummaryTint,
                            isBusy: fanControl.isPreparingHelper
                                || fanControl.isRefreshingConnection
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .disabled(fanControl.isDataOnlyFixture || (compactHelperActionIsReconnect && fanControl.helperReconnectWaitSeconds > 0))
                    .help(compactHelperHelp)
                    .accessibilityLabel(L10n.text("高级控制状态", "Advanced Control Status"))
                    .accessibilityValue(FanStatusPresentation.controlTitle(geekFanControlCapabilityState))
                    }
                }
                .frame(height: 18)

                if geekFanTelemetry.readings.isEmpty {
                    HStack(spacing: 6) {
                        Text(geekFanTelemetry.isFanless
                            ? L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling")
                            : geekFanTelemetry.isSampling
                                ? L10n.text("正在检测风扇…", "Checking Fans…")
                                : L10n.text("风扇读数不可用", "Fan readings unavailable"))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 24)
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
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                }

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

    private var geekFanControlCardHeight: CGFloat {
        let rows = max(1, min(2, geekFanTelemetry.readings.count))
        let controlRows = geekFanTelemetry.isFanless ? 0 : 1
        let itemCount = 1 + rows + controlRows + (geekFanThermallyProtected ? 1 : 0)
        return 10 + 18 + CGFloat(rows + controlRows) * 24
            + CGFloat(itemCount - 1) * 4 + (geekFanThermallyProtected ? 17 : 0)
    }

    private func compactFanHistoryRow(_ reading: SystemFanReading) -> some View {
        HStack(spacing: 6) {
            GeekHoverDetailTarget(
                accessibilityLabel: L10n.text("\(reading.displayName)转速历史", "\(reading.displayName) Speed History"),
                chartRangeMetric: .fan,
                popoverSize: GeekSensorPowerHoverDetailMetrics.sensorHistorySize,
                selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset
            ) {
                Text(reading.displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
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
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minHeight: 24, alignment: .trailing)
            }
        }
        .font(AdvancedPanelTypography.caption)
        .frame(height: 24)
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

    var geekBatteryElectricalReadouts: [GeekSensorReadout] {
        GeekBatteryElectricalReadouts.rows(electrical: batteryElectricalSnapshot)
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

    private func geekSensorHeader(
        _ title: String,
        emphasized: Bool = true
    ) -> some View {
        Text(title)
            .font(AdvancedPanelTypography.captionStrong)
            .foregroundStyle(emphasized ? panelMetricColors.sectionHeader : Color.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
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
            currentValue: String(format: "%.1f°C", reading.celsius),
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
            CGSize(
                width: MiniWindowStyleTokens.historyWidth,
                height: 60 + CGFloat(GeekSensorTemperatureLayout.temperatureGridRowCount(
                    itemCount: geekDetailedTemperatures.count
                )) * 20
            )
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
        HStack(alignment: .center, spacing: 4) {
            Text(geekCompactTemperatureZoneTitle(zone))
                .font(.system(size: GeekSensorTemperatureLayout.fontSize, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            Text(geekCompactTemperature(reading.celsius))
                .font(.system(size: GeekSensorTemperatureLayout.fontSize, weight: .regular))
                .foregroundStyle(geekTemperatureValueForeground(reading.celsius))
                .monospacedDigit()
                .lineLimit(1)

            GeekDisclosureIcon()
                .frame(width: GeekSensorTemperatureLayout.miniRingSize)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GeekSensorTemperatureLayout.gridRowHeight,
            maxHeight: GeekSensorTemperatureLayout.gridRowHeight,
            alignment: .leading
        )
        .help(L10n.text("查看历史趋势", "View History Trend"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(geekTemperatureZoneTitle(zone))
        .accessibilityValue(String(format: "%.1f°C", reading.celsius))
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

    private func geekCompactTemperatureZoneTitle(_ zone: SystemTemperatureZone) -> String {
        switch zone {
        case .performanceCores: L10n.text("性能核心", "P-Cores")
        case .superCores: L10n.text("超级核心", "Super Cores")
        case .efficiencyCores: L10n.text("能效核心", "E-Cores")
        case .thunderboltLeft: L10n.text("雷雳左", "TB Left")
        case .thunderboltRight: L10n.text("雷雳右", "TB Right")
        default: geekTemperatureZoneTitle(zone)
        }
    }

    /// "80°C" (the sensors rings and, D43, the CPU card's title).
    func geekCompactTemperature(_ value: Double) -> String {
        String(format: "%.0f°C", value)
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
            value: String(format: "%.0f lx", lux), source: source, note: note, sampledAt: sampledAt
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
                L10n.text("平均（\(cores.count) 个传感器）", "Average (\(cores.count) sensors)"),
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
