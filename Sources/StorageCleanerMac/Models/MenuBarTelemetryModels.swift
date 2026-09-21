import Foundation

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
    let date: Date
    let cpuTotal: Double?
    let cpuUser: Double?
    let cpuSystem: Double?
    let gpu: Double?
    let memory: Double?
    let memoryPressure: Double?
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
        upBytesPerSecond: Int64?
    ) {
        self.date = date
        self.cpuTotal = cpuTotal
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.gpu = gpu
        self.memory = memory
        self.memoryPressure = memoryPressure
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
        cpuTotal = snapshot.cpuUsageBreakdown?.totalPercent
            ?? Self.metricValue(.cpuUsage, in: snapshot)
        cpuUser = snapshot.cpuUsageBreakdown?.userPercent
        cpuSystem = snapshot.cpuUsageBreakdown?.systemPercent
        gpu = Self.metricValue(.gpuUsage, in: snapshot)
        memory = Self.metricValue(.memoryUsage, in: snapshot)
        memoryPressure = nil
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
        cpuTotal = nil
        cpuUser = nil
        cpuSystem = nil
        gpu = nil
        memory = snapshot.measuredUsedRatio.map { $0 * 100 }
        memoryPressure = snapshot.pressureEstimatePercent.map(Double.init)
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
            upBytesPerSecond: upBytesPerSecond
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
            upBytesPerSecond: upBytesPerSecond
        )
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
    case fanRPM
    case fanTargetRPM
    case download
    case upload

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
                points[points.count - 1] = point
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
        for point in points[startIndex..<endIndex] {
            if let last = compacted.last,
               minuteBucket(for: last[keyPath: date]) == minuteBucket(for: point[keyPath: date]) {
                compacted[compacted.count - 1] = point
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
            if recentBuffer.last != nil {
                recentBuffer.replaceLast(with: point)
            } else {
                minuteBuffer.replaceLast(with: point)
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

        for point in sorted where point.date >= cutoff {
            if let last = normalized.last, last.date == point.date {
                normalized[normalized.count - 1] = point
            } else if point.date < highResolutionCutoff,
                      let last = normalized.last,
                      last.date < highResolutionCutoff,
                      MenuBarHistoryRetention.minuteBucket(for: last.date)
                        == MenuBarHistoryRetention.minuteBucket(for: point.date) {
                normalized[normalized.count - 1] = point
            } else {
                normalized.append(point)
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
            var latest = point
            expiredCount += 1
            while expiredCount < availableCount,
                  let next = recentBuffer.element(at: expiredCount),
                  next.date < cutoff,
                  MenuBarHistoryRetention.minuteBucket(for: next.date) == bucket {
                latest = next
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
                == MenuBarHistoryRetention.minuteBucket(for: point.date) {
            minuteBuffer.replaceLast(with: point)
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
