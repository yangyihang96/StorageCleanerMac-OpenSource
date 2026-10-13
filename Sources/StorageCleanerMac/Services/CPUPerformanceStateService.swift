import Darwin
import Foundation
import IOKit

/// Best-effort Apple Silicon CPU and GPU operating-point telemetry.
///
/// IOReport is a private SPI. Every discovery, decoding and mapping step is
/// validated and fails closed so an OS or SoC layout change hides the dynamic
/// values instead of presenting a plausible but incorrect clock or voltage.
enum CPUPerformanceStateService {
    struct Snapshot: Equatable, Sendable {
        let processorModel: String
        let performanceLevels: [PerformanceLevel]
        let clusters: [ClusterReading]
        /// BOARD N16-1: the GPU's operating point over the same interval.
        var gpu: GPUReading? = nil
    }

    /// The GPU over one IOReport interval ("GPU Stats" › "GPU Performance
    /// States" › GPUPH, weighted by the pmgr GPU DVFS table).
    struct GPUReading: Equatable, Sendable {
        /// The residency-weighted frequency of the active states; nil when
        /// the GPU was off for the whole interval (idle, not zero).
        let frequencyMHz: Double?
        /// The share of the interval the GPU was not off (0...1).
        let activeRatio: Double
        /// The table's highest operating point (a ring's scale).
        let maximumFrequencyMHz: Double
    }

    struct PerformanceLevel: Equatable, Sendable {
        let index: Int
        let name: String
        let coreCount: Int
        let coresPerL2: Int?
    }

    struct ClusterReading: Equatable, Sendable {
        let identifier: String
        let performanceLevelIndex: Int
        let performanceLevelName: String
        let coreCount: Int
        let frequencyMHz: Double?
        let voltageVolts: Double?
    }

    struct DVFSState: Equatable, Hashable, Sendable {
        let frequencyMHz: Double
        let voltageVolts: Double
    }

    struct StateResidency: Equatable, Sendable {
        let name: String
        let value: UInt64
    }

    struct WeightedOperatingPoint: Equatable, Sendable {
        let frequencyMHz: Double
        let voltageVolts: Double
    }

    struct DVFSTable: Equatable, Sendable {
        let sourceKey: String
        let states: [DVFSState]
    }

    struct ClusterStateChannel: Equatable, Sendable {
        let identifier: String
        let residencies: [StateResidency]
    }

    struct ClusterAssignment: Equatable, Sendable {
        let channelIdentifier: String
        let performanceLevel: PerformanceLevel
        let coreCount: Int
        let table: DVFSTable
    }

    private static let store = Store()
    private static let snapshotCoordinator = CPUPerformanceSnapshotCoordinator {
        store.sampleCurrentSnapshot()
    }
    private static let inactiveStateNames: Set<String> = ["IDLE", "DOWN", "OFF"]
    private static let validFrequencyMHz = 300.0...8_000.0
    /// Apple GPUs run between a few hundred megahertz and about two gigahertz.
    private static let validGPUFrequencyMHz = 100.0...3_000.0
    private static let validVoltageVolts = 0.4...1.5
    private static let latestVerifiedDynamicTelemetryOSMajor = 27
    /// Energy Model counters were verified on macOS 27.2 (Mac17,9).
    static let latestVerifiedEnergyModelOSMajor = 27

    /// Static model and perflevel topology do not need an IOReport delta.
    static func staticSnapshot() -> Snapshot? {
        store.staticSnapshot()
    }

    static func resolvedProcessorModel(
        topologyModel: String?,
        sysctlBrand: String?
    ) -> String? {
        for candidate in [topologyModel, sysctlBrand] {
            let normalized = candidate?
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            if let normalized, !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    /// The first call seeds the reusable IOReport subscription and returns nil.
    /// Later calls delta the new sample against that baseline without sleeping.
    static func currentSnapshot() async -> Snapshot? {
        await snapshotCoordinator.snapshot()
    }

    static func decodeDVFSStates(_ data: Data) -> [DVFSState]? {
        let recordSize = 8
        guard !data.isEmpty, data.count.isMultiple(of: recordSize) else { return nil }

        return data.withUnsafeBytes { raw -> [DVFSState]? in
            var states: [DVFSState] = []
            states.reserveCapacity(raw.count / recordSize)
            for offset in stride(from: 0, to: raw.count, by: recordSize) {
                let rawFrequency = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let rawVoltage = raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                if rawFrequency == 0, rawVoltage == 0 {
                    continue
                }
                guard let frequencyMHz = normalizedFrequencyMHz(rawFrequency),
                      let voltageVolts = normalizedVoltageVolts(rawVoltage) else {
                    return nil
                }
                states.append(DVFSState(
                    frequencyMHz: frequencyMHz,
                    voltageVolts: voltageVolts
                ))
            }
            guard !states.isEmpty else { return nil }
            for index in states.indices.dropFirst() {
                let previous = states[index - 1]
                let current = states[index]
                guard current.frequencyMHz > previous.frequencyMHz,
                      current.voltageVolts >= previous.voltageVolts else {
                    return nil
                }
            }
            return states
        }
    }

    /// The pmgr GPU table (`voltage-states9`): its first record is the
    /// powered-off state (0 Hz, a retention voltage), the rest are the
    /// operating points P1…Pn in ascending order, optionally followed by
    /// all-zero padding.
    static func decodeGPUDVFSStates(_ data: Data) -> [DVFSState]? {
        let recordSize = 8
        guard !data.isEmpty, data.count.isMultiple(of: recordSize) else { return nil }

        return data.withUnsafeBytes { raw -> [DVFSState]? in
            var states: [DVFSState] = []
            var isPadding = false
            for offset in stride(from: 0, to: raw.count, by: recordSize) {
                let rawFrequency = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let rawVoltage = raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                // Review P2-4: padding is only at the end. A zero record
                // followed by an operating point would shift every later P
                // state onto the wrong clock, so the table is not read.
                guard !isPadding || (rawFrequency == 0 && rawVoltage == 0) else { return nil }
                if rawFrequency == 0 {
                    // Only the leading powered-off record and padding have
                    // no clock.
                    guard offset == 0 || rawVoltage == 0 else { return nil }
                    isPadding = offset > 0
                    continue
                }
                guard let frequencyMHz = normalizedFrequencyMHz(rawFrequency, valid: validGPUFrequencyMHz),
                      let voltageVolts = normalizedVoltageVolts(rawVoltage) else {
                    return nil
                }
                if let previous = states.last {
                    guard frequencyMHz > previous.frequencyMHz,
                          voltageVolts >= previous.voltageVolts else { return nil }
                }
                states.append(DVFSState(frequencyMHz: frequencyMHz, voltageVolts: voltageVolts))
            }
            return states.isEmpty ? nil : states
        }
    }

    /// The GPU's operating point over an interval: GPUPH residencies (OFF,
    /// then P1…P15) against the table's operating points. The P states map
    /// in order onto the operating points; P states past the end of the table
    /// must have no residency, and any other shape fails closed.
    static func gpuReading(
        residencies: [StateResidency],
        states: [DVFSState]
    ) -> GPUReading? {
        guard !states.isEmpty,
              let maximum = states.last?.frequencyMHz,
              let firstActive = residencies.firstIndex(where: { !isInactiveState($0.name) }),
              residencies[..<firstActive].allSatisfy({ isInactiveState($0.name) }) else { return nil }
        let active = Array(residencies[firstActive...])
        guard active.count >= states.count,
              active.enumerated().allSatisfy({ index, state in
                  state.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "P\(index + 1)"
              }),
              active.dropFirst(states.count).allSatisfy({ $0.value == 0 }) else { return nil }

        let offTotal = residencies[..<firstActive].reduce(0.0) { $0 + Double($1.value) }
        let activeTotal = active.reduce(0.0) { $0 + Double($1.value) }
        let total = offTotal + activeTotal
        guard total > 0 else { return nil }
        guard activeTotal > 0 else {
            return GPUReading(frequencyMHz: nil, activeRatio: 0, maximumFrequencyMHz: maximum)
        }
        var weighted = 0.0
        for (residency, state) in zip(active, states) {
            weighted += Double(residency.value) * state.frequencyMHz
        }
        let frequencyMHz = weighted / activeTotal
        guard frequencyMHz.isFinite, validGPUFrequencyMHz.contains(frequencyMHz) else { return nil }
        return GPUReading(
            frequencyMHz: frequencyMHz,
            activeRatio: min(1, max(0, activeTotal / total)),
            maximumFrequencyMHz: maximum
        )
    }

    static func decodeACCClusterVoltageStateIndices(_ data: Data) -> [Int]? {
        let recordSize = 8
        guard !data.isEmpty, data.count.isMultiple(of: recordSize) else { return nil }

        var indices: [Int] = []
        for offset in stride(from: 0, to: data.count, by: recordSize) {
            let index = Int(data[offset])
            guard index > 0, !indices.contains(index) else { return nil }
            indices.append(index)
        }
        return indices.isEmpty ? nil : indices
    }

    static func weightedOperatingPoint(
        residencies: [StateResidency],
        states: [DVFSState]
    ) -> WeightedOperatingPoint? {
        guard let active = validatedOperatingStateResidencies(
            residencies: residencies,
            states: states
        ) else { return nil }

        let activeTotal = active.reduce(0.0) { $0 + Double($1.value) }
        guard activeTotal > 0 else { return nil }

        var weightedFrequency = 0.0
        var weightedVoltage = 0.0
        for (residency, state) in zip(active, states) {
            let weight = Double(residency.value)
            weightedFrequency += weight * state.frequencyMHz
            weightedVoltage += weight * state.voltageVolts
        }

        let frequencyMHz = weightedFrequency / activeTotal
        let voltageVolts = weightedVoltage / activeTotal
        guard frequencyMHz.isFinite,
              voltageVolts.isFinite,
              validFrequencyMHz.contains(frequencyMHz),
              validVoltageVolts.contains(voltageVolts) else { return nil }
        return WeightedOperatingPoint(
            frequencyMHz: frequencyMHz,
            voltageVolts: voltageVolts
        )
    }

    static func isIdleOperatingState(
        residencies: [StateResidency],
        states: [DVFSState]
    ) -> Bool? {
        guard let active = validatedOperatingStateResidencies(
            residencies: residencies,
            states: states
        ) else { return nil }
        return active.allSatisfy { $0.value == 0 }
    }

    /// Matches channels to DVFS tables by exact active-state count, then maps
    /// table groups to sysctl perflevels by their reported performance order.
    /// No E/P channel order is assumed; M5 PCPU/MCPU* and older ECPU/PCPU are
    /// discovered from the actual channel identifiers.
    static func makeClusterAssignments(
        channels: [ClusterStateChannel],
        tables: [DVFSTable],
        performanceLevels: [PerformanceLevel]
    ) -> [ClusterAssignment]? {
        let clusterChannels = channels.filter { isCPUClusterIdentifier($0.identifier) }
        guard !clusterChannels.isEmpty,
              Set(clusterChannels.map(\.identifier)).count == clusterChannels.count,
              !tables.isEmpty,
              !performanceLevels.isEmpty else { return nil }

        var selected: [(channel: ClusterStateChannel, table: DVFSTable)] = []
        for channel in clusterChannels {
            let activeCount = channel.residencies.filter { !isInactiveState($0.name) }.count
            guard activeCount > 0 else { return nil }
            let candidates = tables.filter { $0.states.count == activeCount }
            guard !candidates.isEmpty else { return nil }

            let variants = Dictionary(grouping: candidates, by: \.states)
            guard variants.count == 1,
                  let table = candidates.sorted(by: { $0.sourceKey < $1.sourceKey }).first else {
                return nil
            }
            selected.append((channel, table))
        }

        let grouped = Dictionary(grouping: selected, by: { $0.table.states })
        guard grouped.count == performanceLevels.count else { return nil }

        var tableGroups = grouped.map { states, entries in
            (states: states, entries: entries, maximumMHz: states.map(\.frequencyMHz).max() ?? 0)
        }
        tableGroups.sort { $0.maximumMHz > $1.maximumMHz }
        for index in 1..<tableGroups.count
        where abs(tableGroups[index - 1].maximumMHz - tableGroups[index].maximumMHz) < 0.001 {
            return nil
        }

        let levels = performanceLevels.sorted { $0.index < $1.index }
        guard Set(levels.map(\.index)).count == levels.count else { return nil }

        var assignments: [ClusterAssignment] = []
        for (group, level) in zip(tableGroups, levels) {
            guard let coresPerL2 = level.coresPerL2,
                  coresPerL2 > 0,
                  level.coreCount > 0,
                  level.coreCount.isMultiple(of: coresPerL2),
                  level.coreCount / coresPerL2 == group.entries.count else {
                return nil
            }

            for entry in group.entries {
                assignments.append(ClusterAssignment(
                    channelIdentifier: entry.channel.identifier,
                    performanceLevel: level,
                    coreCount: coresPerL2,
                    table: entry.table
                ))
            }
        }

        return assignments.sorted {
            ($0.performanceLevel.index, $0.channelIdentifier)
                < ($1.performanceLevel.index, $1.channelIdentifier)
        }
    }

    private static func normalizedFrequencyMHz(
        _ raw: UInt32,
        valid: ClosedRange<Double> = validFrequencyMHz
    ) -> Double? {
        guard raw > 0 else { return nil }
        let value = Double(raw)
        let mhz: Double
        if raw >= 100_000_000 {
            mhz = value / 1_000_000
        } else if raw >= 100_000 {
            mhz = value / 1_000
        } else {
            mhz = value
        }
        return mhz.isFinite && valid.contains(mhz) ? mhz : nil
    }

    private static func normalizedVoltageVolts(_ raw: UInt32) -> Double? {
        guard raw > 0 else { return nil }
        let value = Double(raw)
        let volts: Double
        if raw >= 100_000 {
            volts = value / 1_000_000
        } else if raw >= 100 {
            volts = value / 1_000
        } else {
            volts = value
        }
        return volts.isFinite && validVoltageVolts.contains(volts) ? volts : nil
    }

    private static func isInactiveState(_ name: String) -> Bool {
        inactiveStateNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    private static func hasValidatedOperatingStateOrder(_ states: [StateResidency]) -> Bool {
        guard !states.isEmpty else { return false }
        return states.enumerated().allSatisfy { index, state in
            let expected = "V\(index)P\(states.count - index - 1)"
            return state.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() == expected
        }
    }

    private static func validatedOperatingStateResidencies(
        residencies: [StateResidency],
        states: [DVFSState]
    ) -> [StateResidency]? {
        guard !residencies.isEmpty, !states.isEmpty else { return nil }
        let active = residencies.filter { !isInactiveState($0.name) }
        guard active.count == states.count,
              hasValidatedOperatingStateOrder(active) else { return nil }
        return active
    }

    private static func isCPUClusterIdentifier(_ name: String) -> Bool {
        let uppercased = name.uppercased()
        for prefix in ["ECPU", "MCPU", "PCPU"] where uppercased.hasPrefix(prefix) {
            let suffix = uppercased.dropFirst(prefix.count)
            return suffix.isEmpty || suffix.allSatisfy(\.isNumber)
        }
        return false
    }

    private struct StaticConfiguration {
        let processorModel: String
        let performanceLevels: [PerformanceLevel]
        let tables: [DVFSTable]
        /// The GPU's operating points (pmgr `voltage-states9`), if readable.
        let gpuStates: [DVFSState]?
    }

    private final class Store: @unchecked Sendable {
        private let configuration: StaticConfiguration?
        private let client: IOReportClient?
        private let gpuClient: IOReportClient?

        init() {
            configuration = Self.loadConfiguration()
            let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            let isVerifiedOS = osMajor <= latestVerifiedDynamicTelemetryOSMajor
            client = isVerifiedOS
                ? IOReportClient(group: "CPU Stats", subgroup: "CPU Complex Performance States")
                : nil
            gpuClient = isVerifiedOS && configuration?.gpuStates != nil
                ? IOReportClient(group: "GPU Stats", subgroup: "GPU Performance States")
                : nil
        }

        func staticSnapshot() -> Snapshot? {
            if let configuration {
                return Snapshot(
                    processorModel: configuration.processorModel,
                    performanceLevels: configuration.performanceLevels,
                    clusters: []
                )
            }
            guard Self.sysctlInteger("hw.optional.arm64") == 1,
                  let processorModel = CPUPerformanceStateService.resolvedProcessorModel(
                    topologyModel: nil,
                    sysctlBrand: Self.sysctlString("machdep.cpu.brand_string")
                  ) else { return nil }
            return Snapshot(
                processorModel: processorModel,
                performanceLevels: [],
                clusters: []
            )
        }

        /// The CPU clusters and the GPU over the interval since the previous
        /// call. Either part fails closed on its own: a GPU reading is kept
        /// when the clusters cannot be mapped, and the other way round.
        func sampleCurrentSnapshot() -> Snapshot? {
            guard let configuration else { return nil }
            let gpu = sampleGPU(configuration: configuration)
            let clusters = sampleClusters(configuration: configuration)
            guard clusters != nil || gpu != nil else { return nil }
            return Snapshot(
                processorModel: configuration.processorModel,
                performanceLevels: configuration.performanceLevels,
                clusters: clusters ?? [],
                gpu: gpu
            )
        }

        private func sampleGPU(configuration: StaticConfiguration) -> GPUReading? {
            guard let states = configuration.gpuStates,
                  let delta = gpuClient?.nextDelta(),
                  let channel = gpuClient?.gpuPerformanceChannel(from: delta) else { return nil }
            return gpuReading(residencies: channel.residencies, states: states)
        }

        private func sampleClusters(configuration: StaticConfiguration) -> [ClusterReading]? {
            guard let delta = client?.nextDelta(),
                  let channels = client?.clusterChannels(from: delta),
                  let assignments = makeClusterAssignments(
                    channels: channels,
                    tables: configuration.tables,
                    performanceLevels: configuration.performanceLevels
                  ) else {
                return nil
            }

            let channelsByIdentifier = Dictionary(
                uniqueKeysWithValues: channels.map { ($0.identifier, $0) }
            )
            var readings: [ClusterReading] = []
            for assignment in assignments {
                guard let channel = channelsByIdentifier[assignment.channelIdentifier] else {
                    return nil
                }
                guard let isIdle = isIdleOperatingState(
                    residencies: channel.residencies,
                    states: assignment.table.states
                ) else { return nil }
                if isIdle {
                    readings.append(ClusterReading(
                        identifier: assignment.channelIdentifier,
                        performanceLevelIndex: assignment.performanceLevel.index,
                        performanceLevelName: assignment.performanceLevel.name,
                        coreCount: assignment.coreCount,
                        frequencyMHz: nil,
                        voltageVolts: nil
                    ))
                    continue
                }
                guard let point = weightedOperatingPoint(
                    residencies: channel.residencies,
                    states: assignment.table.states
                ) else { return nil }
                readings.append(ClusterReading(
                    identifier: assignment.channelIdentifier,
                    performanceLevelIndex: assignment.performanceLevel.index,
                    performanceLevelName: assignment.performanceLevel.name,
                    coreCount: assignment.coreCount,
                    frequencyMHz: point.frequencyMHz,
                    voltageVolts: point.voltageVolts
                ))
            }
            guard !readings.isEmpty else { return nil }
            return readings.sorted {
                ($0.performanceLevelIndex, $0.identifier)
                    < ($1.performanceLevelIndex, $1.identifier)
            }
        }

        private static func loadConfiguration() -> StaticConfiguration? {
            guard sysctlInteger("hw.optional.arm64") == 1,
                  let processorModel = sysctlString("machdep.cpu.brand_string"),
                  !processorModel.isEmpty,
                  let levelCount = sysctlInteger("hw.nperflevels"),
                  (1...8).contains(levelCount) else { return nil }

            var levels: [PerformanceLevel] = []
            for index in 0..<levelCount {
                guard let name = sysctlString("hw.perflevel\(index).name"),
                      !name.isEmpty,
                      let coreCount = sysctlInteger("hw.perflevel\(index).physicalcpu"),
                      coreCount > 0 else { return nil }
                let coresPerL2 = sysctlInteger("hw.perflevel\(index).cpusperl2")
                levels.append(PerformanceLevel(
                    index: index,
                    name: name,
                    coreCount: coreCount,
                    coresPerL2: coresPerL2.flatMap { $0 > 0 ? $0 : nil }
                ))
            }

            return StaticConfiguration(
                processorModel: processorModel,
                performanceLevels: levels,
                tables: pmgrValue(loadDVFSTables(pmgr:)) ?? [],
                gpuStates: pmgrValue(loadGPUDVFSStates(pmgr:))
            )
        }

        /// `read` applied to the pmgr registry entry.
        private static func pmgrValue<Value>(_ read: (io_registry_entry_t) -> Value?) -> Value? {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching("AppleARMIODevice"),
                &iterator
            ) == KERN_SUCCESS else { return nil }
            defer { IOObjectRelease(iterator) }

            var entry = IOIteratorNext(iterator)
            while entry != IO_OBJECT_NULL {
                let currentEntry = entry
                defer { IOObjectRelease(currentEntry) }
                var name = [CChar](repeating: 0, count: 128)
                guard IORegistryEntryGetName(currentEntry, &name) == KERN_SUCCESS,
                      decodedCString(name) == "pmgr" else {
                    entry = IOIteratorNext(iterator)
                    continue
                }
                return read(currentEntry)
            }
            return nil
        }

        private static func loadDVFSTables(pmgr: io_registry_entry_t) -> [DVFSTable]? {
            let indices: [Int]
            if let accData = registryData(entry: pmgr, key: "acc-clusters") {
                guard let discovered = decodeACCClusterVoltageStateIndices(accData) else {
                    return nil
                }
                indices = discovered
            } else {
                indices = [1, 5]
            }

            var tables: [DVFSTable] = []
            for index in indices {
                let key = "voltage-states\(index)-sram"
                guard let data = registryData(entry: pmgr, key: key),
                      let states = decodeDVFSStates(data) else { return nil }
                tables.append(DVFSTable(sourceKey: key, states: states))
            }
            return tables
        }

        /// The GPU table the GPUPH states map onto (M1 to M5).
        private static func loadGPUDVFSStates(pmgr: io_registry_entry_t) -> [DVFSState]? {
            registryData(entry: pmgr, key: "voltage-states9").flatMap(decodeGPUDVFSStates)
        }

        private static func registryData(entry: io_registry_entry_t, key: String) -> Data? {
            IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? Data
        }

        private static func sysctlInteger(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let result = name.withCString {
                sysctlbyname($0, &value, &size, nil, 0)
            }
            guard result == 0, size == MemoryLayout<Int32>.size else { return nil }
            return Int(value)
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            let sizeResult = name.withCString {
                sysctlbyname($0, nil, &size, nil, 0)
            }
            guard sizeResult == 0, size > 1, size <= 1_024 else { return nil }

            var buffer = [CChar](repeating: 0, count: size)
            let readResult = name.withCString { cName in
                buffer.withUnsafeMutableBufferPointer {
                    sysctlbyname(cName, $0.baseAddress, &size, nil, 0)
                }
            }
            guard readResult == 0 else { return nil }
            return decodedCString(buffer)
        }

        private static func decodedCString(_ buffer: [CChar]) -> String {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

actor CPUPerformanceSnapshotCoordinator {
    typealias Snapshot = CPUPerformanceStateService.Snapshot
    typealias Operation = @Sendable () -> Snapshot?

    private struct Flight {
        let generation: UInt64
        var timedOut: Bool
    }

    private let timeout: Duration
    private let cooldown: Duration
    private let operation: Operation
    private let clock = ContinuousClock()

    private var generation: UInt64 = 0
    private var flight: Flight?
    private var waiters: [UUID: CheckedContinuation<Snapshot?, Never>] = [:]
    private var timeoutTask: Task<Void, Never>?
    private var cooldownDeadline: ContinuousClock.Instant?

    init(
        timeout: Duration = .seconds(2),
        cooldown: Duration = .seconds(5),
        operation: @escaping Operation
    ) {
        precondition(timeout > .zero)
        precondition(cooldown >= .zero)
        self.timeout = timeout
        self.cooldown = cooldown
        self.operation = operation
    }

    func snapshot() async -> Snapshot? {
        guard !Task.isCancelled else { return nil }
        let waiterID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                register(continuation, id: waiterID)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func register(
        _ continuation: CheckedContinuation<Snapshot?, Never>,
        id: UUID
    ) {
        if let flight {
            guard !flight.timedOut else {
                continuation.resume(returning: nil)
                return
            }
            waiters[id] = continuation
            return
        }

        if let cooldownDeadline, clock.now < cooldownDeadline {
            continuation.resume(returning: nil)
            return
        }

        waiters[id] = continuation
        generation &+= 1
        let workerGeneration = generation
        flight = Flight(generation: workerGeneration, timedOut: false)

        let operation = operation
        Task.detached(priority: .utility) { [weak self] in
            let result = operation()
            await self?.finish(result, generation: workerGeneration)
        }

        let timeout = timeout
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOut(generation: workerGeneration)
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }

    private func timeOut(generation: UInt64) {
        guard var flight,
              flight.generation == generation,
              !flight.timedOut else { return }
        flight.timedOut = true
        self.flight = flight
        cooldownDeadline = clock.now.advanced(by: cooldown)
        resumeWaiters(returning: nil)
    }

    private func finish(_ result: Snapshot?, generation: UInt64) {
        guard let flight, flight.generation == generation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        self.flight = nil

        guard !flight.timedOut else {
            // A timed-out private SPI call may finish much later. Its result is
            // deliberately discarded so it cannot overwrite a newer panel
            // generation after the cooldown.
            return
        }
        cooldownDeadline = nil
        resumeWaiters(returning: result)
    }

    private func resumeWaiters(returning result: Snapshot?) {
        let continuations = Array(waiters.values)
        waiters.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}

/// Read-only IOReport "Energy Model" counters (DECISIONS D57): the energy
/// each SoC block has used, for the power page's chip breakdown. Reuses this
/// file's IOReport subscription plumbing; only copy, subscribe, sample and
/// value-reading functions are called. Fails closed (nil) when the group,
/// the unit or value functions, or a verified OS are missing.
final class EnergyModelCounterReader: @unchecked Sendable {
    private let client: IOReportClient
    private let symbols: IOReportSymbols
    private let unitLabel: IOReportSymbols.ChannelGetString
    private let simpleValue: IOReportSymbols.SimpleGetIntegerValue
    private let ticksToSeconds: Double

    init?(
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) {
        guard osMajor <= CPUPerformanceStateService.latestVerifiedEnergyModelOSMajor,
              let symbols = IOReportSymbols.shared,
              let unitLabel = symbols.channelGetUnitLabel,
              let simpleValue = symbols.simpleGetIntegerValue,
              let client = IOReportClient(group: "Energy Model", subgroup: nil) else { return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return nil }
        self.client = client
        self.symbols = symbols
        self.unitLabel = unitLabel
        self.simpleValue = simpleValue
        self.ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Seconds on the same clock as the counters' update timestamps.
    func now() -> Double {
        Double(mach_absolute_time()) * ticksToSeconds
    }

    /// Seconds on a clock that keeps running while the system sleeps
    /// (mach_absolute_time stops), to notice a gap between samples.
    func continuousNow() -> Double {
        Double(mach_continuous_time()) * ticksToSeconds
    }

    /// The current cumulative counters of the channels the power page uses.
    func read() -> [SoCEnergyCounter]? {
        guard let sample = client.currentSample(),
              let entries = (sample as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            return nil
        }
        let readAt = mach_absolute_time()
        var counters: [SoCEnergyCounter] = []
        for entry in entries {
            let channel = unsafeBitCast(entry, to: CFDictionary.self)
            guard let name = symbols.channelGetName(channel)?.takeUnretainedValue() as String?,
                  SoCEnergyChannelClassifier.role(forChannel: name) != nil,
                  let unit = unitLabel(channel)?.takeUnretainedValue() as String? else { continue }
            let value = simpleValue(channel, 0)
            let updatedAt = Self.updateTimestamp(
                rawElements: entry["RawElements"] as? Data,
                expectedValue: value,
                notAfter: readAt
            ).map { Double($0) * ticksToSeconds }
            counters.append(SoCEnergyCounter(name: name, unitLabel: unit, value: value, updatedAt: updatedAt))
        }
        return counters.isEmpty ? nil : counters
    }

    /// When the driver last updated a simple channel: `IOReportElement`
    /// (IOKit/IOReportTypes.h) is provider_id, channel_id, channel_type,
    /// timestamp (mach_absolute_time) and the values, 64 bytes for one
    /// element. The layout is checked against the value the library reports;
    /// any mismatch gives nil and the estimator falls back to its window.
    static func updateTimestamp(rawElements: Data?, expectedValue: Int64, notAfter: UInt64) -> UInt64? {
        guard let rawElements, rawElements.count == 64 else { return nil }
        return rawElements.withUnsafeBytes { raw -> UInt64? in
            let timestamp = raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            let value = raw.loadUnaligned(fromByteOffset: 32, as: Int64.self)
            guard value == expectedValue, timestamp > 0, timestamp <= notAfter else { return nil }
            return timestamp
        }
    }
}

private final class IOReportClient: @unchecked Sendable {
    private let symbols: IOReportSymbols
    private let subscription: UnsafeMutableRawPointer
    private let subscribedChannels: CFMutableDictionary
    private var previousSample: CFDictionary?

    init?(group: String, subgroup: String?) {
        guard let symbols = IOReportSymbols.shared,
              let desired = symbols.copyChannelsInGroup(
                group as CFString,
                subgroup.map { $0 as CFString },
                0, 0, 0
              )?.takeRetainedValue() else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = symbols.createSubscription(
            nil,
            desired,
            &subscribed,
            0,
            nil
        ),
              let subscribedChannels = subscribed?.takeRetainedValue() else { return nil }

        self.symbols = symbols
        self.subscription = subscription
        self.subscribedChannels = subscribedChannels
    }

    func nextDelta() -> CFDictionary? {
        guard let current = symbols.createSamples(
            subscription,
            subscribedChannels,
            nil
        )?.takeRetainedValue() else { return nil }
        defer { previousSample = current }
        guard let previousSample else { return nil }
        return symbols.createSamplesDelta(
            previousSample,
            current,
            nil
        )?.takeRetainedValue()
    }

    /// An absolute sample (cumulative counters), without a delta.
    func currentSample() -> CFDictionary? {
        symbols.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
    }

    func clusterChannels(from sample: CFDictionary) -> [CPUPerformanceStateService.ClusterStateChannel]? {
        stateChannels(from: sample, subgroup: "CPU Complex Performance States", where: isCPUClusterIdentifier)
    }

    /// The GPU's performance-state channel (GPUPH: OFF, P1…P15).
    func gpuPerformanceChannel(from sample: CFDictionary) -> CPUPerformanceStateService.ClusterStateChannel? {
        guard let channels = stateChannels(
            from: sample, subgroup: "GPU Performance States", where: { $0 == "GPUPH" }
        ), channels.count == 1 else { return nil }
        return channels.first
    }

    private func stateChannels(
        from sample: CFDictionary,
        subgroup expectedSubgroup: String,
        where accepts: (String) -> Bool
    ) -> [CPUPerformanceStateService.ClusterStateChannel]? {
        guard let entries = (sample as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            return nil
        }

        var channels: [CPUPerformanceStateService.ClusterStateChannel] = []
        for entry in entries {
            let channel = unsafeBitCast(entry, to: CFDictionary.self)
            let subgroup = symbols.channelGetSubGroup(channel)?.takeUnretainedValue() as String? ?? ""
            guard subgroup == expectedSubgroup else { continue }
            let identifier = symbols.channelGetName(channel)?.takeUnretainedValue() as String? ?? ""
            guard accepts(identifier) else { continue }
            let count = Int(symbols.stateGetCount(channel))
            guard count > 0, count <= 128 else { return nil }

            var residencies: [CPUPerformanceStateService.StateResidency] = []
            residencies.reserveCapacity(count)
            var valid = true
            for index in 0..<count {
                guard let name = symbols.stateGetName(channel, Int32(index))?
                    .takeUnretainedValue() as String?, !name.isEmpty else {
                    valid = false
                    break
                }
                let rawValue = symbols.stateGetResidency(channel, Int32(index))
                guard rawValue >= 0 else {
                    valid = false
                    break
                }
                residencies.append(.init(name: name, value: UInt64(rawValue)))
            }
            guard valid else { return nil }
            channels.append(.init(identifier: identifier, residencies: residencies))
        }
        return channels.isEmpty ? nil : channels
    }

    private func isCPUClusterIdentifier(_ name: String) -> Bool {
        let uppercased = name.uppercased()
        for prefix in ["ECPU", "MCPU", "PCPU"] where uppercased.hasPrefix(prefix) {
            let suffix = uppercased.dropFirst(prefix.count)
            return suffix.isEmpty || suffix.allSatisfy(\.isNumber)
        }
        return false
    }
}

fileprivate struct IOReportSymbols: @unchecked Sendable {
    typealias SimpleGetIntegerValue = @convention(c) (CFDictionary?, Int32) -> Int64
    typealias CopyChannelsInGroup = @convention(c) (
        CFString?, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFMutableDictionary>?
    typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary?,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
        UInt64,
        CFTypeRef?
    ) -> UnsafeMutableRawPointer?
    typealias CreateSamples = @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary?, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (
        CFDictionary?, CFDictionary?, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    typealias ChannelGetString = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    typealias StateGetCount = @convention(c) (CFDictionary?) -> Int32
    typealias StateGetName = @convention(c) (CFDictionary?, Int32) -> Unmanaged<CFString>?
    typealias StateGetResidency = @convention(c) (CFDictionary?, Int32) -> Int64

    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let channelGetName: ChannelGetString
    let channelGetSubGroup: ChannelGetString
    let stateGetCount: StateGetCount
    let stateGetName: StateGetName
    let stateGetResidency: StateGetResidency
    /// Energy Model only (D57). Optional so that losing them on a future
    /// macOS hides the chip breakdown without hiding the frequencies.
    let channelGetUnitLabel: ChannelGetString?
    let simpleGetIntegerValue: SimpleGetIntegerValue?

    static let shared: IOReportSymbols? = {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard let copyChannelsInGroup = load(
            "IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self
        ), let createSubscription = load(
            "IOReportCreateSubscription", as: CreateSubscription.self
        ), let createSamples = load(
            "IOReportCreateSamples", as: CreateSamples.self
        ), let createSamplesDelta = load(
            "IOReportCreateSamplesDelta", as: CreateSamplesDelta.self
        ), let channelGetName = load(
            "IOReportChannelGetChannelName", as: ChannelGetString.self
        ), let channelGetSubGroup = load(
            "IOReportChannelGetSubGroup", as: ChannelGetString.self
        ), let stateGetCount = load(
            "IOReportStateGetCount", as: StateGetCount.self
        ), let stateGetName = load(
            "IOReportStateGetNameForIndex", as: StateGetName.self
        ), let stateGetResidency = load(
            "IOReportStateGetResidency", as: StateGetResidency.self
        ) else { return nil }

        return IOReportSymbols(
            copyChannelsInGroup: copyChannelsInGroup,
            createSubscription: createSubscription,
            createSamples: createSamples,
            createSamplesDelta: createSamplesDelta,
            channelGetName: channelGetName,
            channelGetSubGroup: channelGetSubGroup,
            stateGetCount: stateGetCount,
            stateGetName: stateGetName,
            stateGetResidency: stateGetResidency,
            channelGetUnitLabel: load("IOReportChannelGetUnitLabel", as: ChannelGetString.self),
            simpleGetIntegerValue: load("IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValue.self)
        )
    }()
}
