import Foundation
import CryptoKit

struct AdvancedTelemetryRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let value: String
    let detail: String?
}

enum AdvancedTelemetryRows {
    static func make(
        cpuFrequencyGHz: Double?,
        nominalVoltageMillivolts: Double?,
        cpuPowerWatts: Double?,
        fanRPM: [Int]?,
        fanReadings: [SystemFanReading]? = nil
    ) -> [AdvancedTelemetryRow] {
        var rows: [AdvancedTelemetryRow] = []

        if let cpuFrequencyGHz,
           cpuFrequencyGHz.isFinite,
           (0...20).contains(cpuFrequencyGHz) {
            rows.append(AdvancedTelemetryRow(
                id: "cpu-frequency",
                title: L10n.text("处理器频率", "CPU Frequency"),
                value: String(format: "%.2f GHz", cpuFrequencyGHz),
                detail: nil
            ))
        }
        if let nominalVoltageMillivolts,
           nominalVoltageMillivolts.isFinite,
           (0...5_000).contains(nominalVoltageMillivolts) {
            rows.append(AdvancedTelemetryRow(
                id: "cpu-voltage",
                title: L10n.text("标称状态电压", "Nominal State Voltage"),
                value: String(format: "%.3f V", nominalVoltageMillivolts / 1_000),
                detail: L10n.text("系统 DVFS 状态值", "System DVFS state value")
            ))
        }
        if let cpuPowerWatts,
           cpuPowerWatts.isFinite,
           (0...1_000).contains(cpuPowerWatts) {
            rows.append(AdvancedTelemetryRow(
                id: "cpu-power",
                title: L10n.text("处理器功耗", "CPU Power"),
                value: String(format: "%.1f W", cpuPowerWatts),
                detail: nil
            ))
        }
        if let fanReadings,
           !fanReadings.isEmpty,
           fanReadings.count <= 16,
           Set(fanReadings.map(\.index)).count == fanReadings.count,
           fanReadings.allSatisfy({ (0...20_000).contains($0.actualRPM) }) {
            rows.append(contentsOf: fanReadings
                .sorted { $0.index < $1.index }
                .map { reading in
                    AdvancedTelemetryRow(
                        id: "fan-\(reading.index)",
                        title: reading.displayName,
                        value: reading.displayRPM,
                        detail: nil
                    )
                })
        } else if let fanRPM,
           !fanRPM.isEmpty,
           fanRPM.count <= 16,
           fanRPM.allSatisfy({ (0...20_000).contains($0) }) {
            rows.append(contentsOf: fanRPM.enumerated().map { index, speed in
                AdvancedTelemetryRow(
                    id: "fan-\(index)",
                    title: L10n.text("风扇 \(index + 1)", "Fan \(index + 1)"),
                    value: SystemFanSpeedFormat.string(speed),
                    detail: nil
                )
            })
        }

        return rows
    }
}

struct MenuBarTelemetryPoint: Codable, Equatable, Sendable {
    private(set) var date: Date
    var bucketStatistics: MenuBarHistoryStatistics? = nil
    /// Hardware source times survive cheap publication ticks and persistence.
    let sensorSampledAt: Date?
    let gpuSampledAt: Date?
    let cpuTotal: Double?
    let cpuUser: Double?
    let cpuSystem: Double?
    let gpu: Double?
    let memory: Double?
    let memoryPressure: Double?
    /// The system's pressure level when the sample was taken, as its system
    /// code (1 normal, 2 warning, 4 critical). Nil for samples recorded
    /// before the level was stored or while it could not be read; an unknown
    /// code is treated as no level, so one odd value never invalidates the
    /// stored history. When samples are compacted into one per bucket, the
    /// bucket's most severe recorded level is kept (`standingForBucket`).
    private(set) var memoryPressureLevelCode: Int?
    let memoryAppOrOtherBytes: UInt64?
    let memoryWiredBytes: UInt64?
    let memoryPhysicalBytes: UInt64?
    let compressedMemoryBytes: UInt64?
    let swapUsedBytes: UInt64?
    let chipTemperature: Double?
    let gpuTemperature: Double?
    let temperatureReadings: [SystemTemperatureReading]?
    let fanRPM: Double?
    let fanTargetRPM: Double?
    let fanReadings: [SystemFanReading]?
    let downBytesPerSecond: Int64?
    let upBytesPerSecond: Int64?

    init(
        date: Date,
        cpuTotal: Double?,
        cpuUser: Double?,
        cpuSystem: Double?,
        gpu: Double?,
        memory: Double?,
        memoryPressure: Double? = nil,
        memoryPressureLevelCode: Int? = nil,
        memoryAppOrOtherBytes: UInt64? = nil,
        memoryWiredBytes: UInt64? = nil,
        memoryPhysicalBytes: UInt64? = nil,
        compressedMemoryBytes: UInt64? = nil,
        swapUsedBytes: UInt64? = nil,
        chipTemperature: Double?,
        gpuTemperature: Double? = nil,
        temperatureReadings: [SystemTemperatureReading]? = nil,
        fanRPM: Double?,
        fanTargetRPM: Double? = nil,
        fanReadings: [SystemFanReading]? = nil,
        downBytesPerSecond: Int64?,
        upBytesPerSecond: Int64?,
        sensorSampledAt: Date? = nil,
        gpuSampledAt: Date? = nil
    ) {
        self.date = date
        self.sensorSampledAt = sensorSampledAt
        self.gpuSampledAt = gpuSampledAt
        self.cpuTotal = cpuTotal
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.gpu = gpu
        self.memory = memory
        self.memoryPressure = memoryPressure
        self.memoryPressureLevelCode = memoryPressureLevelCode
        self.memoryAppOrOtherBytes = memoryAppOrOtherBytes
        self.memoryWiredBytes = memoryWiredBytes
        self.memoryPhysicalBytes = memoryPhysicalBytes
        self.compressedMemoryBytes = compressedMemoryBytes
        self.swapUsedBytes = swapUsedBytes
        self.chipTemperature = chipTemperature
        self.gpuTemperature = gpuTemperature
        self.temperatureReadings = temperatureReadings
        self.fanRPM = fanRPM
        self.fanTargetRPM = fanTargetRPM
        self.fanReadings = fanReadings
        self.downBytesPerSecond = downBytesPerSecond
        self.upBytesPerSecond = upBytesPerSecond
    }

    init(snapshot: SystemMonitorSnapshot) {
        let throughput = snapshot.networkThroughput
        date = snapshot.generatedAt
        sensorSampledAt = snapshot.sensorSampledAt
        gpuSampledAt = snapshot.gpuSampledAt
        cpuTotal = snapshot.cpuUsageBreakdown?.totalPercent
            ?? Self.metricValue(.cpuUsage, in: snapshot)
        cpuUser = snapshot.cpuUsageBreakdown?.userPercent
        cpuSystem = snapshot.cpuUsageBreakdown?.systemPercent
        gpu = Self.metricValue(.gpuUsage, in: snapshot)
        memory = Self.metricValue(.memoryUsage, in: snapshot)
        memoryPressure = nil
        memoryPressureLevelCode = nil
        memoryAppOrOtherBytes = nil
        memoryWiredBytes = nil
        memoryPhysicalBytes = nil
        compressedMemoryBytes = nil
        swapUsedBytes = nil
        chipTemperature = Self.metricValue(.chipTemperature, in: snapshot)
        gpuTemperature = snapshot.temperatureReadings?
            .first(where: { $0.zone == .gpu && $0.celsius.isFinite })?
            .celsius
        temperatureReadings = snapshot.temperatureReadings
        fanRPM = Self.metricValue(.fanSpeed, in: snapshot)
            ?? Self.average(snapshot.fanReadings?.map(\.actualRPM) ?? [])
        fanReadings = snapshot.fanReadings
        let targets = snapshot.fanReadings?.compactMap(\.targetRPM) ?? []
        fanTargetRPM = if let fanReadings = snapshot.fanReadings,
                          !fanReadings.isEmpty,
                          targets.count == fanReadings.count {
            Double(targets.reduce(0, +)) / Double(targets.count)
        } else {
            nil
        }
        downBytesPerSecond = throughput?.downBytesPerSecond
        upBytesPerSecond = throughput?.upBytesPerSecond
    }

    init(memorySnapshot snapshot: MemorySnapshot) {
        date = snapshot.generatedAt
        sensorSampledAt = nil
        gpuSampledAt = nil
        cpuTotal = nil
        cpuUser = nil
        cpuSystem = nil
        gpu = nil
        memory = snapshot.measuredUsedRatio.map { $0 * 100 }
        memoryPressure = snapshot.pressureEstimatePercent.map(Double.init)
        memoryPressureLevelCode = snapshot.measurements.pressure.value?.systemCode
        memoryAppOrOtherBytes = snapshot.ringComposition?.appOrOtherBytes
        memoryWiredBytes = snapshot.ringComposition?.wiredBytes
        memoryPhysicalBytes = snapshot.ringComposition?.physicalBytes
        compressedMemoryBytes = snapshot.ringComposition?.compressedBytes ?? snapshot.measurements.compressedBytes.value
        swapUsedBytes = snapshot.measurements.swapUsedBytes.value
        chipTemperature = nil
        gpuTemperature = nil
        temperatureReadings = nil
        fanRPM = nil
        fanTargetRPM = nil
        fanReadings = nil
        downBytesPerSecond = nil
        upBytesPerSecond = nil
    }

    /// The sample that stands for a history bucket when this (newer) sample
    /// replaces `older` in it: this sample's values, with the most severe
    /// system pressure level recorded in the bucket, so a short elevated or
    /// high period survives compaction (review of batch 4b, P2-7). Only
    /// recorded system levels are carried; a percent estimate is never
    /// stored as a system level.
    private func preservingPressure(replacing older: MenuBarTelemetryPoint) -> MenuBarTelemetryPoint {
        guard let olderCode = older.memoryPressureLevelCode,
              let olderLevel = MemoryPressureLevel(systemCode: olderCode) else { return self }
        // This sample's own level: its system level, or its percent estimate.
        if let ownLevel = memoryPressureLevel, ownLevel.severity >= olderLevel.severity { return self }
        var point = self
        point.memoryPressureLevelCode = olderCode
        return point
    }

    func standingForBucket(replacing older: MenuBarTelemetryPoint,
                           gaps: [DateInterval]? = nil) -> MenuBarTelemetryPoint {
        var point = preservingPressure(replacing: older)
        // A replacement at the same time (journal replay, correction) is never
        // extra coverage, and it never discards the bucket accumulated so far.
        guard date > older.date else {
            point.bucketStatistics = older.bucketStatistics ?? bucketStatistics
            return point
        }
        let gaps = gaps ?? MenuBarSamplingGaps.shared.intervals(at: date)
        point.bucketStatistics = MenuBarHistoryStatistics.merging(
            older.statistics(gaps: gaps), newer: statistics(previous: older, gaps: gaps))
        return point
    }

    /// `gaps` is one snapshot of the known pauses taken by the caller for a
    /// whole pass; it is never re-read per point and channel.
    func statistic(for channel: MenuBarTelemetryChannel, previous: MenuBarTelemetryPoint? = nil,
                   gaps: [DateInterval]? = nil) -> MenuBarHistoryStatistic? {
        if let bucketStatistics { return bucketStatistics.metrics[channel.rawValue] }
        guard let value = channel.value(in: self), value.isFinite else { return nil }
        let end = channel.sampleDate(in: self)
        let before = previous.flatMap { channel.value(in: $0) == nil ? nil : channel.sampleDate(in: $0) }
        if let before, end <= before { return nil }
        let coverage = before == nil ? [] : MenuBarHistoryStatistic.coverage(from: before, to: end,
            gaps: gaps ?? MenuBarSamplingGaps.shared.intervals(at: end))
        let companions: [String: Double]? = channel == .cpuTotal
            ? cpuUser.flatMap { user in cpuSystem.map { ["cpuUser": user, "cpuSystem": $0] } } : nil
        return MenuBarHistoryStatistic(value: value, date: end, coverage: coverage, peakCompanions: companions)
    }

    func statistics(previous: MenuBarTelemetryPoint? = nil, gaps: [DateInterval]? = nil) -> MenuBarHistoryStatistics {
        if let bucketStatistics { return bucketStatistics }
        let gaps = gaps ?? MenuBarSamplingGaps.shared.intervals(at: date)
        var metrics: [String: MenuBarHistoryStatistic] = [:]
        for channel in MenuBarTelemetryChannel.allCases {
            if let record = statistic(for: channel, previous: previous, gaps: gaps) { metrics[channel.rawValue] = record }
        }
        return MenuBarHistoryStatistics(metrics: metrics)
    }

    var cpuPeakSample: MenuBarTelemetryPoint {
        guard let peak = bucketStatistics?.metrics["cpuTotal"] else { return self }
        return MenuBarTelemetryPoint(date: peak.peakDate, cpuTotal: peak.peak,
            cpuUser: peak.peakCompanions?["cpuUser"], cpuSystem: peak.peakCompanions?["cpuSystem"],
            gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
    }

    /// The sample's pressure level: the system level recorded with it, or,
    /// when it has only the percent, the percent estimate.
    var memoryPressureLevel: MemoryPressureLevel? {
        if let code = memoryPressureLevelCode, let level = MemoryPressureLevel(systemCode: code) {
            return level
        }
        return memoryPressure.flatMap(MemoryPressureLevel.estimated(fromPressurePercent:))
    }

    /// Recover the same non-overlapping composition from recorded bytes. No
    /// new history fields are needed; older complete samples remain usable.
    var memoryComposition: MemoryRingComposition? {
        guard let physical = memoryPhysicalBytes, physical > 0,
              let app = memoryAppOrOtherBytes,
              let wired = memoryWiredBytes,
              let compressed = compressedMemoryBytes else { return nil }
        let subtotal = app.addingReportingOverflow(wired)
        let used = subtotal.partialValue.addingReportingOverflow(compressed)
        guard !subtotal.overflow, !used.overflow, used.partialValue <= physical else { return nil }
        return MemoryRingComposition(
            physicalBytes: physical, availableBytes: physical - used.partialValue,
            wiredBytes: wired, compressedBytes: compressed
        )
    }

    func fanRPM(at index: Int) -> Double? {
        guard index >= 0,
              let reading = fanReadings?.first(where: { $0.index == index }) else {
            return nil
        }
        return Double(reading.actualRPM)
    }

    func temperature(_ zone: SystemTemperatureZone) -> Double? {
        temperatureReadings?
            .first(where: { $0.zone == zone && $0.celsius.isFinite })?
            .celsius
    }

    func replacingFanRPM(with value: Double?) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(
            date: date,
            cpuTotal: cpuTotal,
            cpuUser: cpuUser,
            cpuSystem: cpuSystem,
            gpu: gpu,
            memory: memory,
            memoryPressure: memoryPressure,
            memoryPressureLevelCode: memoryPressureLevelCode,
            memoryAppOrOtherBytes: memoryAppOrOtherBytes,
            memoryWiredBytes: memoryWiredBytes,
            memoryPhysicalBytes: memoryPhysicalBytes,
            compressedMemoryBytes: compressedMemoryBytes,
            swapUsedBytes: swapUsedBytes,
            chipTemperature: chipTemperature,
            gpuTemperature: gpuTemperature,
            temperatureReadings: temperatureReadings,
            fanRPM: value,
            fanTargetRPM: fanTargetRPM,
            fanReadings: fanReadings,
            downBytesPerSecond: downBytesPerSecond,
            upBytesPerSecond: upBytesPerSecond,
            sensorSampledAt: sensorSampledAt, gpuSampledAt: gpuSampledAt
        )
    }

    /// A current status can legitimately reuse its most recent memory reading.
    /// History must not turn that display convenience into a new observation.
    func replacingMemory(with value: Double?) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(
            date: date,
            cpuTotal: cpuTotal,
            cpuUser: cpuUser,
            cpuSystem: cpuSystem,
            gpu: gpu,
            memory: value,
            memoryPressure: memoryPressure,
            memoryPressureLevelCode: memoryPressureLevelCode,
            memoryAppOrOtherBytes: memoryAppOrOtherBytes,
            memoryWiredBytes: memoryWiredBytes,
            memoryPhysicalBytes: memoryPhysicalBytes,
            compressedMemoryBytes: compressedMemoryBytes,
            swapUsedBytes: swapUsedBytes,
            chipTemperature: chipTemperature,
            gpuTemperature: gpuTemperature,
            temperatureReadings: temperatureReadings,
            fanRPM: fanRPM,
            fanTargetRPM: fanTargetRPM,
            fanReadings: fanReadings,
            downBytesPerSecond: downBytesPerSecond,
            upBytesPerSecond: upBytesPerSecond,
            sensorSampledAt: sensorSampledAt, gpuSampledAt: gpuSampledAt
        )
    }

    /// Prepared charts project a hardware-only series onto its original source
    /// time, collapsing repeated cached values into one observation. Cheap or
    /// mixed-source series retain their publication timeline.
    static func historyPoints(_ points: [Self], channels: [MenuBarTelemetryChannel]) -> [Self] {
        guard let first = channels.first, first.hardwareSource != nil,
              channels.allSatisfy({ $0.hardwareSource == first.hardwareSource }) else { return points }
        var result: [Self] = []
        result.reserveCapacity(points.count)
        var needsOrdering = false
        for point in points {
            var projected = point
            projected.date = first.sampleDate(in: point)
            if result.last?.date == projected.date {
                result[result.count - 1] = projected
            } else {
                if let last = result.last, projected.date < last.date { needsOrdering = true }
                result.append(projected)
            }
        }
        guard needsOrdering else { return result }
        // A missing publication can precede a late completed read whose
        // original time is earlier. Order those observations before bucketing.
        let ordered = result.enumerated().sorted {
            $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date
        }
        result.removeAll(keepingCapacity: true)
        for item in ordered {
            if result.last?.date == item.element.date { result[result.count - 1] = item.element }
            else { result.append(item.element) }
        }
        return result
    }

    private static func metricValue(
        _ kind: MenuBarMetricKind,
        in snapshot: SystemMonitorSnapshot
    ) -> Double? {
        guard let metric = snapshot.metric(for: kind), metric.isAvailable else {
            return nil
        }
        let numericText = metric.value.filter {
            $0.isNumber || $0 == "." || $0 == "-"
        }
        guard let value = Double(numericText), value.isFinite else {
            return nil
        }
        return value
    }

    private static func average(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}

/// Saved history stays readable across versions (review item 6). Earlier
/// versions decode `temperatureReadings` strictly: one zone they do not know
/// fails the point and, with it, the whole history file. Zones added later
/// (D57's charging circuit) are therefore written under their own key, which
/// earlier versions ignore; and this version skips a saved zone it does not
/// know instead of failing. Every other field is coded as the synthesized
/// conformance did.
extension MenuBarTelemetryPoint {
    private enum CodingKeys: String, CodingKey {
        case sensorSampledAt, gpuSampledAt, bucketStatistics
        case date, cpuTotal, cpuUser, cpuSystem, gpu, memory, memoryPressure, memoryPressureLevelCode
        case memoryAppOrOtherBytes, memoryWiredBytes, memoryPhysicalBytes, compressedMemoryBytes, swapUsedBytes
        case chipTemperature, gpuTemperature, temperatureReadings, addedTemperatureReadings
        case fanRPM, fanTargetRPM, fanReadings, downBytesPerSecond, upBytesPerSecond
    }

    /// A saved reading with its zone as written, so an unknown zone can be
    /// skipped rather than fail the decode.
    private struct StoredTemperatureReading: Codable {
        let zone: String
        let celsius: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let original = try container.decodeIfPresent([StoredTemperatureReading].self, forKey: .temperatureReadings)
        let added = try container.decodeIfPresent([StoredTemperatureReading].self, forKey: .addedTemperatureReadings)
        let stored: [StoredTemperatureReading]? = original == nil && added == nil
            ? nil
            : (original ?? []) + (added ?? [])
        self.init(
            date: try container.decode(Date.self, forKey: .date),
            cpuTotal: try container.decodeIfPresent(Double.self, forKey: .cpuTotal),
            cpuUser: try container.decodeIfPresent(Double.self, forKey: .cpuUser),
            cpuSystem: try container.decodeIfPresent(Double.self, forKey: .cpuSystem),
            gpu: try container.decodeIfPresent(Double.self, forKey: .gpu),
            memory: try container.decodeIfPresent(Double.self, forKey: .memory),
            memoryPressure: try container.decodeIfPresent(Double.self, forKey: .memoryPressure),
            memoryPressureLevelCode: try container.decodeIfPresent(Int.self, forKey: .memoryPressureLevelCode),
            memoryAppOrOtherBytes: try container.decodeIfPresent(UInt64.self, forKey: .memoryAppOrOtherBytes),
            memoryWiredBytes: try container.decodeIfPresent(UInt64.self, forKey: .memoryWiredBytes),
            memoryPhysicalBytes: try container.decodeIfPresent(UInt64.self, forKey: .memoryPhysicalBytes),
            compressedMemoryBytes: try container.decodeIfPresent(UInt64.self, forKey: .compressedMemoryBytes),
            swapUsedBytes: try container.decodeIfPresent(UInt64.self, forKey: .swapUsedBytes),
            chipTemperature: try container.decodeIfPresent(Double.self, forKey: .chipTemperature),
            gpuTemperature: try container.decodeIfPresent(Double.self, forKey: .gpuTemperature),
            temperatureReadings: stored?.compactMap { reading in
                SystemTemperatureZone(rawValue: reading.zone).map {
                    SystemTemperatureReading(zone: $0, celsius: reading.celsius)
                }
            },
            fanRPM: try container.decodeIfPresent(Double.self, forKey: .fanRPM),
            fanTargetRPM: try container.decodeIfPresent(Double.self, forKey: .fanTargetRPM),
            fanReadings: try container.decodeIfPresent([SystemFanReading].self, forKey: .fanReadings),
            downBytesPerSecond: try container.decodeIfPresent(Int64.self, forKey: .downBytesPerSecond),
            upBytesPerSecond: try container.decodeIfPresent(Int64.self, forKey: .upBytesPerSecond),
            sensorSampledAt: try container.decodeIfPresent(Date.self, forKey: .sensorSampledAt),
            gpuSampledAt: try container.decodeIfPresent(Date.self, forKey: .gpuSampledAt)
        )
        bucketStatistics = try container.decodeIfPresent(MenuBarHistoryStatistics.self, forKey: .bucketStatistics)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(bucketStatistics, forKey: .bucketStatistics)
        try container.encodeIfPresent(sensorSampledAt, forKey: .sensorSampledAt)
        try container.encodeIfPresent(gpuSampledAt, forKey: .gpuSampledAt)
        try container.encodeIfPresent(cpuTotal, forKey: .cpuTotal)
        try container.encodeIfPresent(cpuUser, forKey: .cpuUser)
        try container.encodeIfPresent(cpuSystem, forKey: .cpuSystem)
        try container.encodeIfPresent(gpu, forKey: .gpu)
        try container.encodeIfPresent(memory, forKey: .memory)
        try container.encodeIfPresent(memoryPressure, forKey: .memoryPressure)
        try container.encodeIfPresent(memoryPressureLevelCode, forKey: .memoryPressureLevelCode)
        try container.encodeIfPresent(memoryAppOrOtherBytes, forKey: .memoryAppOrOtherBytes)
        try container.encodeIfPresent(memoryWiredBytes, forKey: .memoryWiredBytes)
        try container.encodeIfPresent(memoryPhysicalBytes, forKey: .memoryPhysicalBytes)
        try container.encodeIfPresent(compressedMemoryBytes, forKey: .compressedMemoryBytes)
        try container.encodeIfPresent(swapUsedBytes, forKey: .swapUsedBytes)
        try container.encodeIfPresent(chipTemperature, forKey: .chipTemperature)
        try container.encodeIfPresent(gpuTemperature, forKey: .gpuTemperature)
        if let temperatureReadings {
            let added = SystemTemperatureZone.addedAfterOriginalHistoryFormat
            try container.encode(temperatureReadings.filter { !added.contains($0.zone) }, forKey: .temperatureReadings)
            let later = temperatureReadings.filter { added.contains($0.zone) }
            if !later.isEmpty {
                try container.encode(later, forKey: .addedTemperatureReadings)
            }
        }
        try container.encodeIfPresent(fanRPM, forKey: .fanRPM)
        try container.encodeIfPresent(fanTargetRPM, forKey: .fanTargetRPM)
        try container.encodeIfPresent(fanReadings, forKey: .fanReadings)
        try container.encodeIfPresent(downBytesPerSecond, forKey: .downBytesPerSecond)
        try container.encodeIfPresent(upBytesPerSecond, forKey: .upBytesPerSecond)
    }
}

enum MenuBarTelemetryChannel: String, CaseIterable, Equatable, Sendable {
    case cpuTotal
    case cpuUser
    case cpuSystem
    case gpu
    case memory
    case memoryPressure
    case memoryAppOrOtherBytes
    case memoryWiredBytes
    case compressedMemoryBytes
    case memoryAppPercent
    case memoryWiredPercent
    case memoryCompressedPercent
    case memoryFreePercent
    case swapUsedBytes
    case chipTemperature
    case gpuTemperature
    case socTemperature
    case performanceCoreTemperature
    case superCoreTemperature
    case efficiencyCoreTemperature
    case storageTemperature
    case batteryTemperature
    case ambientTemperature
    case palmRestTemperature
    case thunderboltLeftTemperature
    case thunderboltRightTemperature
    case wifiTemperature
    case chargingCircuitTemperature
    case fanRPM
    case fanTargetRPM
    case download
    case upload

    var hardwareSource: String? {
        switch self {
        case .gpu: "gpu"
        case .chipTemperature, .gpuTemperature, .socTemperature, .performanceCoreTemperature,
             .superCoreTemperature, .efficiencyCoreTemperature, .storageTemperature, .batteryTemperature,
             .ambientTemperature, .palmRestTemperature, .thunderboltLeftTemperature,
             .thunderboltRightTemperature, .wifiTemperature, .chargingCircuitTemperature,
             .fanRPM, .fanTargetRPM: "sensors"
        default: nil
        }
    }

    func mean(in point: MenuBarTelemetryPoint) -> Double? {
        point.bucketStatistics?.metrics[rawValue]?.mean ?? value(in: point)
    }

    func peak(in point: MenuBarTelemetryPoint) -> Double? {
        point.bucketStatistics?.metrics[rawValue]?.peak ?? value(in: point)
    }

    func sampleDate(in point: MenuBarTelemetryPoint) -> Date {
        switch hardwareSource {
        case "gpu": point.gpuSampledAt ?? point.date
        case "sensors": point.sensorSampledAt ?? point.date
        default: point.date
        }
    }

    func value(in point: MenuBarTelemetryPoint) -> Double? {
        switch self {
        case .cpuTotal:
            point.cpuTotal
        case .cpuUser:
            point.cpuUser
        case .cpuSystem:
            point.cpuSystem
        case .gpu:
            point.gpu
        case .memory:
            point.memory
        case .memoryPressure:
            point.memoryPressure
        case .memoryAppOrOtherBytes:
            point.memoryAppOrOtherBytes.map { Double($0) }
        case .memoryWiredBytes:
            point.memoryWiredBytes.map { Double($0) }
        case .compressedMemoryBytes:
            point.compressedMemoryBytes.map { Double($0) }
        case .memoryAppPercent:
            point.memoryComposition.map { $0.appOrOtherRatio * 100 }
        case .memoryWiredPercent:
            point.memoryComposition.map { $0.wiredRatio * 100 }
        case .memoryCompressedPercent:
            point.memoryComposition.map { $0.compressedRatio * 100 }
        case .memoryFreePercent:
            point.memoryComposition.map { $0.availableRatio * 100 }
        case .swapUsedBytes:
            point.swapUsedBytes.map { Double($0) }
        case .chipTemperature:
            point.temperature(.chip) ?? point.chipTemperature
        case .gpuTemperature:
            point.temperature(.gpu) ?? point.gpuTemperature
        case .socTemperature:
            point.temperature(.soc)
        case .performanceCoreTemperature:
            point.temperature(.performanceCores)
        case .superCoreTemperature:
            point.temperature(.superCores)
        case .efficiencyCoreTemperature:
            point.temperature(.efficiencyCores)
        case .storageTemperature:
            point.temperature(.storage)
        case .batteryTemperature:
            point.temperature(.battery)
        case .ambientTemperature:
            point.temperature(.ambient)
        case .palmRestTemperature:
            point.temperature(.palmRest)
        case .thunderboltLeftTemperature:
            point.temperature(.thunderboltLeft)
        case .thunderboltRightTemperature:
            point.temperature(.thunderboltRight)
        case .wifiTemperature:
            point.temperature(.wifi)
        case .chargingCircuitTemperature:
            point.temperature(.chargingCircuit)
        case .fanRPM:
            point.fanRPM
        case .fanTargetRPM:
            point.fanTargetRPM
        case .download:
            point.downBytesPerSecond.map(Double.init)
        case .upload:
            point.upBytesPerSecond.map(Double.init)
        }
    }

    static func temperature(_ zone: SystemTemperatureZone) -> Self {
        switch zone {
        case .chip: .chipTemperature
        case .soc: .socTemperature
        case .performanceCores: .performanceCoreTemperature
        case .superCores: .superCoreTemperature
        case .efficiencyCores: .efficiencyCoreTemperature
        case .gpu: .gpuTemperature
        case .storage: .storageTemperature
        case .battery: .batteryTemperature
        case .ambient: .ambientTemperature
        case .palmRest: .palmRestTemperature
        case .thunderboltLeft: .thunderboltLeftTemperature
        case .thunderboltRight: .thunderboltRightTemperature
        case .wifi: .wifiTemperature
        case .chargingCircuit: .chargingCircuitTemperature
        }
    }
}

enum MenuBarHistoryRetention {
    static let duration: TimeInterval = 28 * 24 * 60 * 60
    static let highResolutionDuration: TimeInterval = 60 * 60
    static let bucketDuration: TimeInterval = 60
    static let maximumMinutePointCount = 28 * 24 * 60 + 1
    static let maximumPointCount = maximumMinutePointCount + Int(highResolutionDuration) + 1

    static func append<T>(
        _ point: T,
        to points: inout [T],
        date: KeyPath<T, Date>
    ) {
        let pointDate = point[keyPath: date]
        if let last = points.last {
            let lastDate = last[keyPath: date]
            if pointDate < lastDate {
                let ordered = (points + [point]).enumerated().sorted {
                    let lhs = $0.element[keyPath: date]
                    let rhs = $1.element[keyPath: date]
                    return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
                }.map(\.element)
                points.removeAll(keepingCapacity: true)
                for value in ordered {
                    append(value, to: &points, date: date)
                }
                return
            }
            if pointDate == lastDate {
                points[points.count - 1] = bucketRepresentative(point, replacing: last)
                return
            }

            points.append(point)
            if minuteBucket(for: pointDate) != minuteBucket(for: lastDate) {
                compactOlderPoints(
                    in: &points,
                    previousEnd: lastDate,
                    endingAt: pointDate,
                    date: date
                )
            }
        } else {
            points.append(point)
        }

        let cutoff = pointDate.addingTimeInterval(-duration)
        let firstRetainedIndex = lowerBound(in: points, for: cutoff, date: date)
        if firstRetainedIndex > 0 {
            points.removeFirst(firstRetainedIndex)
        }
        if points.count > maximumPointCount {
            points.removeFirst(points.count - maximumPointCount)
        }
    }

    static func selected<T>(
        _ points: [T],
        duration: TimeInterval,
        date: KeyPath<T, Date>,
        referenceDate: Date = Date()
    ) -> [T] {
        let cutoff = referenceDate.addingTimeInterval(-duration)
        let startIndex = lowerBound(in: points, for: cutoff, date: date)
        let endIndex = upperBound(in: points, through: referenceDate, date: date)
        guard startIndex < endIndex else { return [] }
        return Array(points[startIndex..<endIndex])
    }

    /// The value that stands for a bucket when `newer` replaces `older` in
    /// it. Telemetry samples keep the bucket's most severe recorded pressure
    /// level; other history values are replaced by the newer one.
    static func bucketRepresentative<T>(_ newer: T, replacing older: T, gaps: [DateInterval]? = nil) -> T {
        if let newPoint = newer as? MenuBarTelemetryPoint,
           let oldPoint = older as? MenuBarTelemetryPoint,
           let merged = newPoint.standingForBucket(replacing: oldPoint, gaps: gaps) as? T {
            return merged
        }
        if var newPoint = newer as? NativeDiskIOPoint, let oldPoint = older as? NativeDiskIOPoint {
            // Same-time replay keeps the accumulated bucket, never extra weight.
            guard newPoint.date > oldPoint.date else {
                newPoint.bucketStatistics = oldPoint.bucketStatistics ?? newPoint.bucketStatistics
                return newPoint as! T
            }
            let gaps = gaps ?? MenuBarSamplingGaps.shared.intervals(at: newPoint.date)
            newPoint.bucketStatistics = MenuBarHistoryStatistics.merging(oldPoint.statistics(gaps: gaps),
                newer: newPoint.statistics(previous: oldPoint, gaps: gaps))
            return newPoint as! T
        }
        if var newPoint = newer as? MenuBarPowerHistoryPoint, let oldPoint = older as? MenuBarPowerHistoryPoint {
            guard newPoint.date > oldPoint.date else {
                newPoint.bucketStatistics = oldPoint.bucketStatistics ?? newPoint.bucketStatistics
                return newPoint as! T
            }
            let gaps = gaps ?? MenuBarSamplingGaps.shared.intervals(at: newPoint.date)
            newPoint.bucketStatistics = MenuBarHistoryStatistics.merging(oldPoint.statistics(gaps: gaps),
                newer: newPoint.statistics(previous: oldPoint, gaps: gaps))
            return newPoint as! T
        }
        return newer
    }

    static func canShareBucket<T>(_ older: T, _ newer: T) -> Bool {
        let statistics: MenuBarHistoryStatistics?
        let incoming: MenuBarHistoryStatistics?
        if let point = older as? MenuBarTelemetryPoint { statistics = point.bucketStatistics }
        else if let point = older as? NativeDiskIOPoint { statistics = point.bucketStatistics }
        else if let point = older as? MenuBarPowerHistoryPoint {
            if let next = newer as? MenuBarPowerHistoryPoint,
               point.isCharging != next.isCharging || point.powerSource != next.powerSource { return false }
            statistics = point.bucketStatistics
        } else { statistics = nil }
        if let point = newer as? MenuBarTelemetryPoint { incoming = point.bucketStatistics }
        else if let point = newer as? NativeDiskIOPoint { incoming = point.bucketStatistics }
        else if let point = newer as? MenuBarPowerHistoryPoint { incoming = point.bucketStatistics }
        else { incoming = nil }
        // Split at the metadata bound, preserving both segments and their peaks.
        return statistics?.metrics.allSatisfy { key, value in
            let additional = incoming.map { $0.metrics[key]?.coverage.count ?? 0 } ?? 1
            return value.coverage.count + additional <= 256
        } ?? true
    }

    /// Attach source coverage before the first point of a compressed bucket is
    /// detached from its predecessor. Recent raw samples are left untouched.
    static func preparedForBucket<T>(_ point: T, previous: T?, gaps: [DateInterval]? = nil) -> T {
        if var value = point as? MenuBarTelemetryPoint, value.bucketStatistics == nil {
            value.bucketStatistics = value.statistics(previous: previous as? MenuBarTelemetryPoint, gaps: gaps)
            return value as! T
        }
        if var value = point as? NativeDiskIOPoint, value.bucketStatistics == nil {
            value.bucketStatistics = value.statistics(previous: previous as? NativeDiskIOPoint, gaps: gaps)
            return value as! T
        }
        if var value = point as? MenuBarPowerHistoryPoint, value.bucketStatistics == nil {
            value.bucketStatistics = value.statistics(previous: previous as? MenuBarPowerHistoryPoint, gaps: gaps)
            return value as! T
        }
        return point
    }

    static func minuteBucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSinceReferenceDate / bucketDuration))
    }

    private static func compactOlderPoints<T>(
        in points: inout [T],
        previousEnd: Date,
        endingAt end: Date,
        date: KeyPath<T, Date>
    ) {
        let previousCutoff = previousEnd.addingTimeInterval(-highResolutionDuration)
        let cutoff = end.addingTimeInterval(-highResolutionDuration)
        var startIndex = lowerBound(in: points, for: previousCutoff, date: date)
        let endIndex = lowerBound(in: points, for: cutoff, date: date)
        while startIndex > 0,
              startIndex < points.count,
              minuteBucket(for: points[startIndex - 1][keyPath: date])
                == minuteBucket(for: points[startIndex][keyPath: date]) {
            startIndex -= 1
        }
        guard endIndex - startIndex > 1 else { return }

        var compacted: [T] = []
        compacted.reserveCapacity(endIndex - startIndex)
        var previous: T? = startIndex > 0 ? points[startIndex - 1] : nil
        let gaps = MenuBarSamplingGaps.shared.intervals(at: end)
        for rawPoint in points[startIndex..<endIndex] {
            let point = preparedForBucket(rawPoint, previous: previous, gaps: gaps)
            previous = rawPoint
            if let last = compacted.last,
               minuteBucket(for: last[keyPath: date]) == minuteBucket(for: point[keyPath: date]),
               canShareBucket(last, point) {
                compacted[compacted.count - 1] = bucketRepresentative(point, replacing: last, gaps: gaps)
            } else {
                compacted.append(point)
            }
        }
        points.replaceSubrange(startIndex..<endIndex, with: compacted)
    }

    private static func lowerBound<T>(
        in points: [T],
        for target: Date,
        date: KeyPath<T, Date>
    ) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if points[middle][keyPath: date] < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func upperBound<T>(
        in points: [T],
        through target: Date,
        date: KeyPath<T, Date>
    ) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if points[middle][keyPath: date] <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

struct MenuBarTelemetryHistory: Equatable, Sendable {
    static let windowDuration = MenuBarHistoryRetention.duration
    static let maximumPointCount = MenuBarHistoryRetention.maximumPointCount
    static let epochGapDuration: TimeInterval = 60
    /// The recent ring only ever holds the high-resolution hour (expiration
    /// folds older samples into the minute ring on every append), so its
    /// capacity follows that window instead of the full 28-day point count.
    /// The slack absorbs manual refresh bursts between scheduled samples.
    private static let recentCapacity = Int(MenuBarHistoryRetention.highResolutionDuration) + 64
    private static let minuteCapacity = MenuBarHistoryRetention.maximumMinutePointCount + 2

    /// The recent ring keeps every real sample for one hour. Samples that age
    /// out of that window are folded into a second ring, one latest point per
    /// minute. Expiration walks each sample once, so normal append work is
    /// constant amortized time rather than a full-history rebuild per minute.
    private var recentBuffer = RingBuffer<MenuBarTelemetryPoint>(
        capacity: Self.recentCapacity
    )
    private var minuteBuffer = RingBuffer<MenuBarTelemetryPoint>(
        capacity: Self.minuteCapacity
    )
    private(set) var epoch = 0
    private(set) var epochBreaks: [Date] = []

    var points: [MenuBarTelemetryPoint] { minuteBuffer.elements + recentBuffer.elements }

    /// Materializes only the requested window instead of copying the entire
    /// retained history (up to ~44k points) for every chart refresh. Both
    /// rings are date-ordered, so each bound is a binary search.
    func points(
        within duration: TimeInterval,
        referenceDate: Date = Date()
    ) -> [MenuBarTelemetryPoint] {
        let cutoff = referenceDate.addingTimeInterval(-duration)
        var result: [MenuBarTelemetryPoint] = []

        let minuteStart = minuteBuffer.firstIndex { $0.date >= cutoff }
        let minuteEnd = minuteBuffer.firstIndex { $0.date > referenceDate }
        if minuteStart < minuteEnd {
            result.reserveCapacity(minuteEnd - minuteStart)
            result.append(contentsOf: minuteBuffer.elements(in: minuteStart..<minuteEnd))
        }

        let recentStart = recentBuffer.firstIndex { $0.date >= cutoff }
        let recentEnd = recentBuffer.firstIndex { $0.date > referenceDate }
        if recentStart < recentEnd {
            result.append(contentsOf: recentBuffer.elements(in: recentStart..<recentEnd))
        }
        return result
    }

    /// Avoids materializing the entire retained history for live bookkeeping.
    var latest: MenuBarTelemetryPoint? { recentBuffer.last ?? minuteBuffer.last }

    mutating func append(_ snapshot: SystemMonitorSnapshot) {
        append(MenuBarTelemetryPoint(snapshot: snapshot))
    }

    mutating func append(_ point: MenuBarTelemetryPoint) {
        guard let lastDate = latest?.date else {
            recentBuffer.append(point)
            return
        }

        if point.date < lastDate {
            beginNewEpoch(at: point.date)
            rebuildOrdered(with: points + [point])
            return
        }

        if point.date == lastDate {
            if let last = recentBuffer.last {
                recentBuffer.replaceLast(with: point.standingForBucket(replacing: last))
            } else if let last = minuteBuffer.last {
                minuteBuffer.replaceLast(with: point.standingForBucket(replacing: last))
            }
            return
        }

        if point.date.timeIntervalSince(lastDate) > Self.epochGapDuration {
            beginNewEpoch(at: point.date)
        }

        compactExpired(before: point.date)
        recentBuffer.append(point)
    }

    mutating func restore(_ restoredPoints: [MenuBarTelemetryPoint]) {
        rebuildOrdered(with: restoredPoints + points)
    }

    private mutating func beginNewEpoch(at date: Date) {
        epoch += 1
        epochBreaks.append(date)
        if epochBreaks.count > 64 {
            epochBreaks.removeFirst(epochBreaks.count - 64)
        }
    }

    private mutating func rebuildOrdered(with points: [MenuBarTelemetryPoint]) {
        let ordered = normalized(points)
        let cutoff = (ordered.last?.date ?? .distantPast)
            .addingTimeInterval(-MenuBarHistoryRetention.highResolutionDuration)

        recentBuffer.removeAll(keepingCapacity: true)
        minuteBuffer.removeAll(keepingCapacity: true)
        for point in ordered {
            if point.date < cutoff {
                appendMinute(point)
            } else {
                recentBuffer.append(point)
            }
        }
    }

    private func normalized(_ points: [MenuBarTelemetryPoint]) -> [MenuBarTelemetryPoint] {
        guard !points.isEmpty else { return [] }
        let sorted = points.enumerated().sorted(by: {
            let lhsDate = $0.element.date
            let rhsDate = $1.element.date
            return lhsDate == rhsDate ? $0.offset < $1.offset : lhsDate < rhsDate
        }).map(\.element)

        guard let end = sorted.last?.date else { return [] }
        let cutoff = end.addingTimeInterval(-Self.windowDuration)
        let highResolutionCutoff = end.addingTimeInterval(
            -MenuBarHistoryRetention.highResolutionDuration
        )
        var normalized: [MenuBarTelemetryPoint] = []
        normalized.reserveCapacity(min(sorted.count, Self.maximumPointCount))
        let gaps = MenuBarSamplingGaps.shared.intervals(at: end)

        for point in sorted where point.date >= cutoff {
            if let last = normalized.last, last.date == point.date {
                normalized[normalized.count - 1] = point.standingForBucket(replacing: last, gaps: gaps)
            } else if point.date < highResolutionCutoff,
                      let last = normalized.last,
                      last.date < highResolutionCutoff,
                      MenuBarHistoryRetention.minuteBucket(for: last.date)
                        == MenuBarHistoryRetention.minuteBucket(for: point.date),
                      MenuBarHistoryRetention.canShareBucket(last, point) {
                normalized[normalized.count - 1] = point.standingForBucket(replacing: last, gaps: gaps)
            } else {
                normalized.append(point.date < highResolutionCutoff
                    ? MenuBarHistoryRetention.preparedForBucket(point, previous: normalized.last, gaps: gaps) : point)
            }
        }

        if normalized.count > Self.maximumPointCount {
            return Array(normalized.suffix(Self.maximumPointCount))
        }
        return normalized
    }

    private mutating func compactExpired(before date: Date) {
        let cutoff = date.addingTimeInterval(
            -MenuBarHistoryRetention.highResolutionDuration
        )
        var expiredCount = 0
        let availableCount = recentBuffer.count

        while expiredCount < availableCount,
              let point = recentBuffer.element(at: expiredCount),
              point.date < cutoff {
            let bucket = MenuBarHistoryRetention.minuteBucket(for: point.date)
            var latest = MenuBarHistoryRetention.preparedForBucket(point, previous: minuteBuffer.last)
            expiredCount += 1
            while expiredCount < availableCount,
                  let next = recentBuffer.element(at: expiredCount),
                  next.date < cutoff,
                  MenuBarHistoryRetention.minuteBucket(for: next.date) == bucket,
                  MenuBarHistoryRetention.canShareBucket(latest, next) {
                latest = next.standingForBucket(replacing: latest)
                expiredCount += 1
            }
            appendMinute(latest)
        }

        if expiredCount > 0 {
            recentBuffer.removeFirst(expiredCount)
        }

        let retentionCutoff = date.addingTimeInterval(-Self.windowDuration)
        var expiredMinuteCount = 0
        while let point = minuteBuffer.element(at: expiredMinuteCount),
              point.date < retentionCutoff {
            expiredMinuteCount += 1
        }
        minuteBuffer.removeFirst(expiredMinuteCount)
        minuteBuffer.removeFirst(max(0, minuteBuffer.count - Self.minuteCapacity))
    }

    private mutating func appendMinute(_ point: MenuBarTelemetryPoint) {
        if let last = minuteBuffer.last,
           MenuBarHistoryRetention.minuteBucket(for: last.date)
                == MenuBarHistoryRetention.minuteBucket(for: point.date),
           MenuBarHistoryRetention.canShareBucket(last, point) {
            minuteBuffer.replaceLast(with: point.standingForBucket(replacing: last))
        } else {
            minuteBuffer.append(point)
        }
    }
}

/// Bounded FIFO storage for the high-frequency telemetry path.
///
/// Storage grows with real samples instead of eagerly allocating the full
/// retention window. Once the configured capacity is reached, append and
/// overwrite remain O(1); `elements` returns oldest-to-newest order.
struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage = []
    }

    var isEmpty: Bool { count == 0 }
    var allocatedSlotCount: Int { storage.count }

    var first: Element? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    var last: Element? {
        guard count > 0 else { return nil }
        return storage[index(forOffset: count - 1)]
    }

    var elements: [Element] {
        guard count > 0 else { return [] }
        return (0..<count).compactMap { storage[index(forOffset: $0)] }
    }

    func element(at offset: Int) -> Element? {
        guard offset >= 0, offset < count else { return nil }
        return storage[index(forOffset: offset)]
    }

    /// Index of the first element for which `belongsToSuffix` is true,
    /// assuming stored elements are ordered so the predicate is false for a
    /// prefix and true for the remaining suffix. Returns `count` when no
    /// element satisfies the predicate.
    func firstIndex(satisfying belongsToSuffix: (Element) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if let element = element(at: middle), belongsToSuffix(element) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }

    func elements(in range: Range<Int>) -> [Element] {
        guard range.lowerBound >= 0, range.upperBound <= count else { return [] }
        return range.compactMap { element(at: $0) }
    }

    @discardableResult
    mutating func append(_ element: Element) -> Element? {
        guard capacity > 0 else { return nil }
        if count == capacity {
            let overwritten = storage[head]
            storage[head] = element
            head = (head + 1) % storage.count
            return overwritten
        }

        if count < storage.count {
            storage[index(forOffset: count)] = element
            count += 1
            return nil
        }

        // A partially filled ring can wrap after removals. Realign only when
        // it needs to grow; steady-state append/overwrite remains O(1).
        if head != 0 {
            storage = elements.map(Optional.some)
            head = 0
        }
        storage.append(element)
        count += 1
        return nil
    }

    mutating func replaceLast(with element: Element) {
        guard count > 0 else {
            _ = append(element)
            return
        }
        storage[index(forOffset: count - 1)] = element
    }

    mutating func removeFirst(_ requestedCount: Int = 1) {
        guard capacity > 0, count > 0, requestedCount > 0 else { return }
        let removeCount = min(requestedCount, count)
        for offset in 0..<removeCount {
            storage[index(forOffset: offset)] = nil
        }
        head = (head + removeCount) % storage.count
        count -= removeCount
        if count == 0 { head = 0 }
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        if keepingCapacity {
            for index in storage.indices { storage[index] = nil }
        } else {
            storage.removeAll(keepingCapacity: false)
        }
        head = 0
        count = 0
    }

    private func index(forOffset offset: Int) -> Int {
        precondition(!storage.isEmpty)
        return (head + offset) % storage.count
    }
}

extension RingBuffer: Equatable where Element: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elements == rhs.elements
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

/// D80: sufficient statistics over observed time, independent of display bins.
/// Raw/legacy fields remain the last sample. Absence of this optional payload
/// is the v1 format, so the existing checkpoint/journal needs no replacement.
struct MenuBarHistoryStatistic: Codable, Equatable, Sendable {
    let mean: Double
    let peak: Double
    let minimum: Double
    let last: Double
    let peakDate: Date
    let lastDate: Date
    let sampleCount: Int
    let coverage: [DateInterval]
    /// Components of the very same sample that supplied the total CPU peak.
    let peakCompanions: [String: Double]?

    var coveredDuration: TimeInterval { coverage.reduce(0) { $0 + $1.duration } }
    var start: Date { coverage.first?.start ?? peakDate }
    var end: Date { coverage.last?.end ?? lastDate }

    init(value: Double, date: Date, coverage: [DateInterval] = [], peakCompanions: [String: Double]? = nil) {
        mean = value; peak = value; minimum = value; last = value
        peakDate = date; lastDate = date; sampleCount = 1
        self.coverage = coverage
        self.peakCompanions = peakCompanions
    }

    fileprivate init(mean: Double, peak: Double, minimum: Double, last: Double,
                 peakDate: Date, lastDate: Date, sampleCount: Int,
                 coverage: [DateInterval], peakCompanions: [String: Double]?) {
        self.mean = mean; self.peak = peak; self.minimum = minimum; self.last = last
        self.peakDate = peakDate; self.lastDate = lastDate; self.sampleCount = sampleCount
        self.coverage = coverage; self.peakCompanions = peakCompanions
    }

    /// Only bracketed, reasonably spaced observations establish coverage.
    /// Longer gaps/known pauses do not get a guessed duration or a zero value.
    static func coverage(from start: Date?, to end: Date, measured: Bool = false,
                         gaps: [DateInterval]? = nil) -> [DateInterval] {
        guard let start, end > start, start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              measured || end.timeIntervalSince(start) <= 180,
              !MenuBarSamplingGaps.crosses(gaps ?? MenuBarSamplingGaps.shared.intervals(at: end),
                  from: start, to: end) else { return [] }
        return [DateInterval(start: start, end: end)]
    }

    func merging(_ newer: Self) -> Self {
        // Idempotent journal replay and cached source times never double weight.
        guard newer.lastDate > lastDate else { return self }
        let lhsWeight = coveredDuration, rhsWeight = newer.coveredDuration
        let total = lhsWeight + rhsWeight
        let mean = self.mean == newer.mean ? self.mean : total > 0
            ? self.mean * (lhsWeight / total) + newer.mean * (rhsWeight / total)
            : newer.mean
        let peakSample = newer.peak > peak ? newer : self
        var intervals = coverage
        for interval in newer.coverage {
            if let previous = intervals.last, interval.start <= previous.end {
                intervals[intervals.count - 1] = DateInterval(start: min(previous.start, interval.start),
                                                            end: max(previous.end, interval.end))
            } else { intervals.append(interval) }
        }
        let mergedPeak = peakSample.peak, mergedMinimum = Swift.min(minimum, newer.minimum)
        // Floating-point weighting can drift a hair outside the true range.
        return Self(mean: Swift.min(Swift.max(mean, mergedMinimum), mergedPeak), peak: mergedPeak, minimum: mergedMinimum,
                    last: newer.last, peakDate: peakSample.peakDate, lastDate: newer.lastDate,
                    sampleCount: sampleCount + newer.sampleCount, coverage: intervals,
                    peakCompanions: peakSample.peakCompanions)
    }

    func overlap(from start: Date, to end: Date) -> Double {
        coverage.reduce(0) { $0 + max(0, min(end, $1.end).timeIntervalSince(max(start, $1.start))) }
    }

    /// Relative to the magnitude (bytes/s can be 1e10), plus a tiny absolute floor.
    private var tolerance: Double { Swift.max(abs(peak), abs(minimum), 1) * 1e-9 }

    var isValid: Bool {
        [mean, peak, minimum, last].allSatisfy(\.isFinite)
            && peak >= minimum && mean >= minimum - tolerance && mean <= peak + tolerance
            && peakDate.timeIntervalSinceReferenceDate.isFinite && lastDate.timeIntervalSinceReferenceDate.isFinite
            && peakDate <= lastDate && sampleCount > 0 && sampleCount <= 10_000_000
            && coverage.count <= 256 && coverage.allSatisfy {
                $0.start.timeIntervalSinceReferenceDate.isFinite && $0.end.timeIntervalSinceReferenceDate.isFinite
                    && $0.duration > 0 && $0.end <= lastDate
            }
            && zip(coverage, coverage.dropFirst()).allSatisfy { $0.end < $1.start }
            && (peakCompanions?.count ?? 0) <= 2
            && (peakCompanions?.values.allSatisfy(\.isFinite) ?? true)
    }
}

struct MenuBarHistoryStatistics: Codable, Equatable, Sendable {
    let metrics: [String: MenuBarHistoryStatistic]
    init(metrics: [String: MenuBarHistoryStatistic]) { self.metrics = metrics }

    private enum CodingKeys: String, CodingKey { case metrics, contexts, values }

    /// Source dates/counts/coverage are usually shared by many channels. Store
    /// them once per bucket; the 28-day history must fit the existing 16 MiB cap.
    private struct Context: Codable, Equatable {
        let lastDate: Date
        let sampleCount: Int
        let coverage: [DateInterval]
        var isValid: Bool {
            sampleCount > 0 && sampleCount <= 10_000_000
                && MenuBarHistoryStatistic(value: 0, date: lastDate, coverage: coverage).isValid
        }
    }

    private struct Value: Codable {
        let mean: Double
        let peak: Double
        let minimum: Double
        let last: Double
        let peakDate: Date
        let context: Int
        let companions: [String: Double]?

        init(_ record: MenuBarHistoryStatistic, context: Int) {
            mean = record.mean; peak = record.peak; minimum = record.minimum; last = record.last
            peakDate = record.peakDate; self.context = context; companions = record.peakCompanions
        }
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            mean = try c.decode(Double.self); peak = try c.decode(Double.self)
            minimum = try c.decode(Double.self); last = try c.decode(Double.self)
            peakDate = try c.decode(Date.self); context = try c.decode(Int.self)
            companions = c.isAtEnd ? nil : try c.decodeIfPresent([String: Double].self)
            guard c.isAtEnd else { throw MonitoringFileError.invalidStructure }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(mean); try c.encode(peak); try c.encode(minimum); try c.encode(last)
            try c.encode(peakDate); try c.encode(context)
            if let companions { try c.encode(companions) }
        }
        func record(in contexts: [Context]) throws -> MenuBarHistoryStatistic {
            guard contexts.indices.contains(context) else { throw MonitoringFileError.invalidStructure }
            let source = contexts[context]
            return .init(mean: mean, peak: peak, minimum: minimum, last: last,
                         peakDate: peakDate, lastDate: source.lastDate, sampleCount: source.sampleCount,
                         coverage: source.coverage, peakCompanions: companions)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metrics: [String: MenuBarHistoryStatistic]
        if container.contains(.values) {
            let values = try container.decode([String: Value].self, forKey: .values)
            let contexts = try container.decode([Context].self, forKey: .contexts)
            guard values.count <= 64, contexts.count <= 64, contexts.allSatisfy(\.isValid)
            else { throw MonitoringFileError.invalidStructure }
            metrics = try values.mapValues { try $0.record(in: contexts) }
        } else {
            // Also read the verbose statistics object; old snapshots without any
            // statistics continue through the point's decodeIfPresent path.
            metrics = try container.decode([String: MenuBarHistoryStatistic].self, forKey: .metrics)
        }
        guard metrics.count <= 64, metrics.keys.allSatisfy({ $0.count <= 64 }),
              metrics.values.allSatisfy(\.isValid) else { throw MonitoringFileError.invalidStructure }
        self.metrics = metrics
    }

    func encode(to encoder: Encoder) throws {
        var contexts: [Context] = []
        var values: [String: Value] = [:]
        for key in metrics.keys.sorted() {
            let record = metrics[key]!
            let source = Context(lastDate: record.lastDate, sampleCount: record.sampleCount, coverage: record.coverage)
            let index: Int
            if let existing = contexts.firstIndex(of: source) { index = existing }
            else { index = contexts.count; contexts.append(source) }
            values[key] = Value(record, context: index)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contexts, forKey: .contexts)
        try container.encode(values, forKey: .values)
    }

    static func merging(_ older: Self, newer: Self) -> Self {
        var result = older.metrics
        for (key, value) in newer.metrics { result[key] = result[key].map { $0.merging(value) } ?? value }
        return Self(metrics: result)
    }
}

extension NativeDiskIOPoint {
    func statistics(previous: Self? = nil, gaps: [DateInterval]? = nil) -> MenuBarHistoryStatistics {
        if let bucketStatistics { return bucketStatistics }
        let start = intervalStart.map { max($0, previous?.date ?? $0) } ?? previous?.date
        let coverage = start == nil ? [] : MenuBarHistoryStatistic.coverage(from: start, to: date,
            measured: intervalStart != nil, gaps: gaps ?? MenuBarSamplingGaps.shared.intervals(at: date))
        return MenuBarHistoryStatistics(metrics: [
            "diskRead": .init(value: Double(readBytesPerSecond), date: date, coverage: coverage),
            "diskWrite": .init(value: Double(writeBytesPerSecond), date: date, coverage: coverage),
            "diskReadOperations": .init(value: readOperationsPerSecond, date: date, coverage: coverage),
            "diskWriteOperations": .init(value: writeOperationsPerSecond, date: date, coverage: coverage)
        ])
    }
}

extension MenuBarPowerHistoryPoint {
    func statistics(previous: Self? = nil, gaps: [DateInterval]? = nil) -> MenuBarHistoryStatistics {
        if let bucketStatistics { return bucketStatistics }
        let gaps = previous == nil ? [] : gaps ?? MenuBarSamplingGaps.shared.intervals(at: date)
        var metrics: [String: MenuBarHistoryStatistic] = [:]
        for (key, value, oldValue) in [("charge", chargePercent, previous?.chargePercent),
                                      ("batteryPower", batteryPowerWatts, previous?.batteryPowerWatts)] {
            guard let value, value.isFinite else { continue }
            let coverage = MenuBarHistoryStatistic.coverage(from: oldValue == nil ? nil : previous?.date, to: date, gaps: gaps)
            metrics[key] = .init(value: value, date: date, coverage: coverage)
        }
        return MenuBarHistoryStatistics(metrics: metrics)
    }
}

/// The physical channel's identity is separate from its localized label.
struct MenuBarTemperatureChannel: Equatable, Sendable {
    enum Source: String, Sendable { case smc = "SMC", hid = "HID" }
    enum Confidence: Equatable, Sendable {
        case verified, recognized, unknown
        var rank: Int { switch self { case .verified: 2; case .recognized: 1; case .unknown: 0 } }
        var title: String {
            switch self {
            case .verified: L10n.text("已验证位置", "Verified location")
            case .recognized: L10n.text("已识别通道标签", "Recognized channel label")
            case .unknown: L10n.text("位置未确认", "Location unconfirmed")
            }
        }
    }
    let source: Source
    let rawKey: String
    let ordinal: Int
    let rawName: String
    let location: String?
    let confidence: Confidence
    var unit: String { "°C" }
    var id: String {
        let identity = "\(source.rawValue):\(rawKey):\(ordinal)"
        return source.rawValue.lowercased() + "." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var help: String {
        "\(source.rawValue) · \(rawKey) · \(rawName) · \(unit) · \(confidence.title)"
            + (location.map { " · \($0)" } ?? "")
    }

    static func zoneTitle(_ zone: SystemTemperatureZone) -> String {
        switch zone {
        case .chip: L10n.text("处理器芯片", "CPU Chip")
        case .soc: L10n.text("片上系统", "SoC")
        case .performanceCores: L10n.text("性能核心", "Performance Core")
        case .superCores: L10n.text("超级核心", "Super Core")
        case .efficiencyCores: L10n.text("能效核心", "Efficiency Core")
        case .gpu: L10n.text("图形芯片", "GPU")
        case .storage: L10n.text("存储", "Storage")
        case .battery: L10n.text("电池", "Battery")
        case .ambient: L10n.text("环境", "Ambient")
        case .palmRest: L10n.text("掌托", "Palm Rest")
        case .thunderboltLeft: L10n.text("左侧雷雳接口", "Left Thunderbolt")
        case .thunderboltRight: L10n.text("右侧雷雳接口", "Right Thunderbolt")
        case .wifi: L10n.text("无线网络模块", "Wi-Fi Module")
        case .chargingCircuit: L10n.text("充电电路", "Charging Circuit")
        }
    }
}

extension SystemTemperatureDetailReading {
    var sourceHelp: String {
        channel?.help ?? "\(id) · " + L10n.text("温度通道；来源元数据未记录", "Temperature channel; source metadata not recorded")
    }
}

extension Int64 {
    /// Double(Int64.max) rounds up; never trap when a real counter nears the cap.
    init(clampingHistoryValue value: Double) {
        if !value.isFinite || value <= 0 { self = 0 }
        else if value >= Double(Int64.max) { self = .max }
        else { self = Int64(value) }
    }
}
