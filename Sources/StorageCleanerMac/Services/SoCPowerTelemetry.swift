import Foundation

/// One cumulative counter of the IOReport "Energy Model" group.
struct SoCEnergyCounter: Equatable, Sendable {
    let name: String
    /// The channel's own unit label: mJ, µJ/uJ or nJ (one group mixes them).
    let unitLabel: String
    /// Cumulative energy in `unitLabel`s.
    let value: Int64
    /// When the driver last updated the counter, in seconds on the reader's
    /// monotonic clock (IOReportElement.timestamp). Nil when unreadable.
    let updatedAt: Double?
}

enum SoCEnergyUnit {
    /// Joules per unit of a channel's label; nil for anything else (the
    /// channel is then not used, never guessed).
    static func joules(perUnitLabel label: String) -> Double? {
        switch label.trimmingCharacters(in: .whitespaces) {
        case "J": 1
        case "mJ": 1e-3
        case "uJ", "\u{00B5}J", "\u{03BC}J": 1e-6
        case "nJ": 1e-9
        default: nil
        }
    }
}

/// The SoC blocks the power page lists (D57 ③), in display order.
enum SoCPowerComponent: String, CaseIterable, Equatable, Sendable {
    /// `CPU Energy` (or the clusters' sum); never an item of its own, but
    /// named under "本机不支持" when this Mac has no CPU part at all.
    case cpu
    case superCoreCluster
    case performanceCoreCluster
    case efficiencyCoreCluster
    case gpu
    case neuralEngine
    case memory
    case memoryController
    case displayEngine
    case media
    case fabric

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .superCoreCluster: L10n.text("超级核心簇", "Super Cores")
        case .performanceCoreCluster: L10n.text("性能核心簇", "Performance Cores")
        case .efficiencyCoreCluster: L10n.text("能效核心簇", "Efficiency Cores")
        case .gpu: "GPU"
        case .neuralEngine: L10n.text("神经网络引擎", "Neural Engine")
        case .memory: L10n.text("内存", "Memory")
        case .memoryController: L10n.text("内存控制器", "Memory Controller")
        case .displayEngine: L10n.text("显示引擎", "Display Engine")
        case .media: L10n.text("媒体", "Media")
        case .fabric: L10n.text("片上互连", "Fabric")
        }
    }

    var isCPUCluster: Bool {
        [.superCoreCluster, .performanceCoreCluster, .efficiencyCoreCluster].contains(self)
    }

    /// The non-cluster blocks every Apple silicon Energy Model is expected
    /// to have; a missing one is listed as "本机不支持" in the breakdown.
    static let expectedNonClusterComponents: [SoCPowerComponent] = [
        .gpu, .neuralEngine, .memory, .memoryController, .displayEngine, .media, .fabric
    ]
}

/// Maps Energy Model channel names onto blocks (research 2026-10-07 §4.2,
/// macmon). Per-core, SRAM, DTL and CPM channels and PCIe ports are not
/// used; `GPU0` only stands in when there is no `GPU Energy`. Ultra chips
/// prefix every channel with its die, `DIE_<n>_` (macmon: "DIE_{}_CPU
/// Energy"); the prefix is set aside and the dies' channels are summed.
enum SoCEnergyChannelClassifier {
    enum Role: Equatable, Sendable {
        /// `CPU Energy` (= the sum of the clusters).
        case cpuTotal
        /// A cluster aggregate: PCPU, MCPU0, ECPU…, by prefix.
        case cluster(prefix: String)
        /// `GPU Energy` (nJ, updated continuously).
        case gpuTotal
        /// `GPU0`… (mJ), a fallback without `GPU Energy`.
        case gpuCluster
        case component(SoCPowerComponent)
    }

    static func role(forChannel channelName: String) -> Role? {
        // "CPU Energy"; on Ultra "DIE_0_CPU Energy", "DIE_1_CPU Energy" (D57
        // supplement: anything ending in "CPU Energy").
        if channelName.hasSuffix("CPU Energy") { return .cpuTotal }
        let name = withoutDiePrefix(channelName)
        if name == "GPU Energy" { return .gpuTotal }
        if let prefix = prefix(of: name, in: ["PCPU", "MCPU", "ECPU"]) { return .cluster(prefix: prefix) }
        if prefix(of: name, in: ["GPU"]) != nil { return .gpuCluster }
        if prefix(of: name, in: ["ANE"]) != nil { return .component(.neuralEngine) }
        if prefix(of: name, in: ["DRAM"]) != nil { return .component(.memory) }
        if prefix(of: name, in: ["AMCC", "DCS"]) != nil { return .component(.memoryController) }
        if prefix(of: name, in: ["DISPEXT", "DISP"]) != nil { return .component(.displayEngine) }
        if prefix(of: name, in: ["ISP", "AVE", "MSR"]) != nil { return .component(.media) }
        if prefix(of: name, in: ["FAB", "AFR"]) != nil { return .component(.fabric) }
        return nil
    }

    /// The cluster block of a cluster channel. M5 Pro/Max: PCPU super,
    /// MCPU performance. M5: PCPU super, ECPU efficiency (perflevel0 is
    /// "Super"). M1–M4: PCPU performance, ECPU efficiency.
    static func clusterComponent(
        prefix: String,
        clusterPrefixes: Set<String>,
        performanceLevelNames: [String]
    ) -> SoCPowerComponent {
        switch prefix {
        case "MCPU": return .performanceCoreCluster
        case "ECPU": return .efficiencyCoreCluster
        default:
            let hasSuperLevel = performanceLevelNames.contains {
                $0.trimmingCharacters(in: .whitespaces).lowercased() == "super"
            }
            return clusterPrefixes.contains("MCPU") || hasSuperLevel
                ? .superCoreCluster
                : .performanceCoreCluster
        }
    }

    /// The channel name without an Ultra die prefix: `DIE_<n>_` (or
    /// `DIE_<n> `) followed by the usual name; any other name unchanged.
    static func withoutDiePrefix(_ name: String) -> String {
        guard name.hasPrefix("DIE_") else { return name }
        let afterDie = name.dropFirst(4)
        let digits = afterDie.prefix(while: \.isASCIIDigit)
        let rest = afterDie.dropFirst(digits.count)
        guard !digits.isEmpty, let separator = rest.first, separator == "_" || separator == " ",
              rest.count > 1 else { return name }
        return String(rest.dropFirst())
    }

    /// `name` is one of `prefixes` followed only by digits (or nothing).
    private static func prefix(of name: String, in prefixes: [String]) -> String? {
        for prefix in prefixes where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            if suffix.allSatisfy(\.isASCIIDigit) { return prefix }
        }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// One channel's power over its latest counter-update interval.
struct SoCChannelPower: Equatable, Sendable {
    /// Nil before the first complete window ("更新中") or when invalid.
    var watts: Double?
    /// The value is carried from an earlier window (no counter update in
    /// the latest one), or there is no value yet.
    var isUpdating: Bool
    /// The computed power was implausible (counter reset or out of range).
    var isInvalid: Bool = false
}

/// Turns cumulative Energy Model counters into power without the batch
/// artefacts (D57 ①, research §4.2): the mJ counters advance in batches about
/// every 2.1 s, so dividing by the sampling interval shows 0 W and 2–3×
/// spikes. Power is energy between two counter *updates* divided by the time
/// between those updates (IOReportElement timestamps), so it is exact for any
/// sampling interval. A window without an update keeps the previous value
/// and is marked updating; the first window has no value yet. Without
/// timestamps a window of at least `fallbackMinimumSpan` between counter
/// changes is used instead.
struct SoCPowerEstimator: Sendable {
    static let validWatts: ClosedRange<Double> = 0...1_000
    /// Updates closer together than this are not divided (a forced
    /// refresh right after a sample); the next window spans both.
    static let minimumUpdateInterval: TimeInterval = 0.5
    /// Fallback only: ≥ 4 s (D57); 8 s keeps the batch quantisation within
    /// about a quarter at a 2 s sampling interval.
    static let fallbackMinimumSpan: TimeInterval = 8
    /// Fallback only: a counter that has not moved for this long while
    /// samples keep arriving is a measured zero.
    static let fallbackIdleZeroAfter: TimeInterval = 12
    /// A gap between two samples longer than this (the page was hidden, the
    /// system slept) starts a new baseline: one window across the gap would
    /// show its average, not what the chip does now. The earlier values stay,
    /// marked updating, until the next full window (review item 4).
    static let maximumSampleGap: TimeInterval = 10

    private struct ChannelState: Sendable {
        var last: SoCEnergyCounter
        var power: SoCChannelPower
        /// Fallback: (sample time, value) at each observed change, newest last.
        var changes: [(time: Double, value: Int64)] = []
        var lastChangeSampleTime: Double
    }

    private var channels: [String: ChannelState] = [:]

    init() {}

    /// Forget the counters (the panel closed): the next window starts a new
    /// baseline. Earlier values are kept and marked updating until replaced.
    mutating func reset() {
        for name in channels.keys {
            channels[name]?.power.isUpdating = true
        }
        carriedPowers.merge(channels.mapValues(\.power)) { _, new in new }
        channels.removeAll()
        lastSampleClock = nil
    }

    private var carriedPowers: [String: SoCChannelPower] = [:]
    private var lastSampleClock: Double?

    /// `sampledAt` is on the counters' clock; `continuousClock` (default
    /// `sampledAt`) also runs while the system sleeps and measures the gap
    /// since the previous sample.
    mutating func update(
        counters: [SoCEnergyCounter],
        sampledAt: Double,
        continuousClock: Double? = nil
    ) -> [String: SoCChannelPower] {
        let clock = continuousClock ?? sampledAt
        if let lastSampleClock, !(clock - lastSampleClock <= Self.maximumSampleGap) {
            reset()
        }
        lastSampleClock = clock
        var result: [String: SoCChannelPower] = [:]
        for counter in counters {
            guard let joulesPerUnit = SoCEnergyUnit.joules(perUnitLabel: counter.unitLabel) else { continue }
            guard var state = channels[counter.name] else {
                let carried = carriedPowers[counter.name].map {
                    SoCChannelPower(watts: $0.watts, isUpdating: true, isInvalid: false)
                } ?? SoCChannelPower(watts: nil, isUpdating: true)
                channels[counter.name] = ChannelState(
                    last: counter,
                    power: carried,
                    changes: [(sampledAt, counter.value)],
                    lastChangeSampleTime: sampledAt
                )
                result[counter.name] = carried
                continue
            }
            if let previousTime = state.last.updatedAt, let time = counter.updatedAt {
                state = Self.timestamped(
                    state, counter: counter, previousTime: previousTime, time: time,
                    sampledAt: sampledAt, joulesPerUnit: joulesPerUnit
                )
            } else {
                state = Self.windowed(state, counter: counter, sampledAt: sampledAt, joulesPerUnit: joulesPerUnit)
            }
            channels[counter.name] = state
            result[counter.name] = state.power
        }
        carriedPowers.removeAll()
        return result
    }

    private static func timestamped(
        _ state: ChannelState,
        counter: SoCEnergyCounter,
        previousTime: Double,
        time: Double,
        sampledAt: Double,
        joulesPerUnit: Double
    ) -> ChannelState {
        var state = state
        let energyDelta = counter.value - state.last.value
        if time == previousTime, energyDelta == 0 {
            // No counter update in this window: keep the value, mark it.
            state.power.isUpdating = true
            return state
        }
        guard time > previousTime, energyDelta >= 0 else {
            // A counter reset or an inconsistent element: start again.
            state.last = counter
            state.power = SoCChannelPower(watts: state.power.watts, isUpdating: true)
            return state
        }
        guard time - previousTime >= minimumUpdateInterval else { return state }
        let watts = Double(energyDelta) * joulesPerUnit / (time - previousTime)
        state.last = counter
        // Should a later sample lose its timestamp, the fallback window
        // starts here rather than at an old baseline.
        state.changes = [(sampledAt, counter.value)]
        state.lastChangeSampleTime = sampledAt
        state.power = watts.isFinite && validWatts.contains(watts)
            ? SoCChannelPower(watts: watts, isUpdating: false)
            : SoCChannelPower(watts: nil, isUpdating: false, isInvalid: true)
        return state
    }

    private static func windowed(
        _ state: ChannelState,
        counter: SoCEnergyCounter,
        sampledAt: Double,
        joulesPerUnit: Double
    ) -> ChannelState {
        var state = state
        let energyDelta = counter.value - state.last.value
        guard energyDelta >= 0 else {
            state.last = counter
            state.changes = [(sampledAt, counter.value)]
            state.lastChangeSampleTime = sampledAt
            state.power = SoCChannelPower(watts: state.power.watts, isUpdating: true)
            return state
        }
        state.last = counter
        guard energyDelta > 0 else {
            // No change. A counter that has not moved for long enough is a
            // measured zero; otherwise keep the value and mark it.
            if sampledAt - state.lastChangeSampleTime >= fallbackIdleZeroAfter {
                state.power = SoCChannelPower(watts: 0, isUpdating: false)
            } else {
                state.power.isUpdating = true
            }
            return state
        }
        state.lastChangeSampleTime = sampledAt
        state.changes.append((sampledAt, counter.value))
        // The newest change that is at least the minimum span back.
        guard let anchor = state.changes.dropLast().last(where: {
            sampledAt - $0.time >= fallbackMinimumSpan
        }) else {
            state.power.isUpdating = true
            return state
        }
        state.changes.removeAll { $0.time < anchor.time }
        let watts = Double(counter.value - anchor.value) * joulesPerUnit / (sampledAt - anchor.time)
        state.power = watts.isFinite && validWatts.contains(watts)
            ? SoCChannelPower(watts: watts, isUpdating: false)
            : SoCChannelPower(watts: nil, isUpdating: false, isInvalid: true)
        return state
    }
}

/// The chip power breakdown the power page shows (D57 ③).
struct SoCPowerReading: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        let component: SoCPowerComponent
        let power: SoCChannelPower
        let channelNames: [String]
        var id: SoCPowerComponent { component }
    }

    /// Blocks this Mac has, in display order ("有多少就列多少").
    var items: [Item]
    /// Expected blocks without a channel ("本机不支持" in the breakdown),
    /// `.cpu` first when there is no CPU part.
    var unsupportedComponents: [SoCPowerComponent]
    /// `CPU Energy` (or the clusters' sum).
    var cpu: SoCChannelPower?
    /// The chip total: CPU plus every other listed block. Nil without a CPU
    /// part (D57 supplement): the other blocks alone are not a chip total.
    var total: SoCChannelPower?
    /// False when the Energy Model cannot be read at all.
    var isSupported: Bool

    static let unsupported = SoCPowerReading(
        items: [],
        unsupportedComponents: [],
        cpu: nil,
        total: nil,
        isSupported: false
    )

    func item(_ component: SoCPowerComponent) -> Item? {
        items.first { $0.component == component }
    }

    /// Groups channel powers into blocks.
    static func make(
        channelPowers: [String: SoCChannelPower],
        performanceLevelNames: [String]
    ) -> SoCPowerReading {
        guard !channelPowers.isEmpty else { return .unsupported }
        var cpuTotalNames: [String] = []
        var clusterNames: [String: [String]] = [:]
        var gpuTotalNames: [String] = []
        var gpuClusterNames: [String] = []
        var componentNames: [SoCPowerComponent: [String]] = [:]
        for name in channelPowers.keys.sorted() {
            switch SoCEnergyChannelClassifier.role(forChannel: name) {
            case .cpuTotal: cpuTotalNames.append(name)
            case let .cluster(prefix): clusterNames[prefix, default: []].append(name)
            case .gpuTotal: gpuTotalNames.append(name)
            case .gpuCluster: gpuClusterNames.append(name)
            case let .component(component): componentNames[component, default: []].append(name)
            case nil: continue
            }
        }
        let clusterPrefixes = Set(clusterNames.keys)
        var clusterComponents: [SoCPowerComponent: [String]] = [:]
        for (prefix, names) in clusterNames {
            let component = SoCEnergyChannelClassifier.clusterComponent(
                prefix: prefix,
                clusterPrefixes: clusterPrefixes,
                performanceLevelNames: performanceLevelNames
            )
            clusterComponents[component, default: []].append(contentsOf: names)
        }
        componentNames[.gpu] = gpuTotalNames.isEmpty ? gpuClusterNames : gpuTotalNames
        componentNames.merge(clusterComponents) { $0 + $1 }

        var items: [Item] = []
        for component in SoCPowerComponent.allCases {
            guard let names = componentNames[component], !names.isEmpty else { continue }
            items.append(Item(
                component: component,
                power: sum(names.map { channelPowers[$0] }),
                channelNames: names.sorted()
            ))
        }
        let cpu: SoCChannelPower? = cpuTotalNames.isEmpty
            ? (items.contains(where: \.component.isCPUCluster)
                ? sum(items.filter(\.component.isCPUCluster).map(\.power))
                : nil)
            : sum(cpuTotalNames.map { channelPowers[$0] })
        let total = cpu.map { cpu in
            sum([cpu] + items.filter { !$0.component.isCPUCluster }.map(\.power))
        }
        return SoCPowerReading(
            items: items,
            unsupportedComponents: (cpu == nil ? [.cpu] : []) + SoCPowerComponent.expectedNonClusterComponents.filter { component in
                !items.contains { $0.component == component }
            },
            cpu: cpu,
            total: total,
            isSupported: true
        )
    }

    /// A sum is only a value when every part has one; updating or invalid
    /// when any part is.
    private static func sum(_ parts: [SoCChannelPower?]) -> SoCChannelPower {
        let powers = parts.compactMap { $0 }
        guard powers.count == parts.count, !powers.isEmpty else {
            return SoCChannelPower(watts: nil, isUpdating: true)
        }
        if powers.contains(where: \.isInvalid) {
            return SoCChannelPower(watts: nil, isUpdating: false, isInvalid: true)
        }
        let isUpdating = powers.contains(where: \.isUpdating)
        let values = powers.compactMap(\.watts)
        guard values.count == powers.count else {
            return SoCChannelPower(watts: nil, isUpdating: true)
        }
        return SoCChannelPower(watts: values.reduce(0, +), isUpdating: isUpdating)
    }
}

/// Owns the Energy Model subscription and the estimator. Every call runs on
/// the caller's background thread; calls are serialised by the lock.
final class SoCPowerSampler: @unchecked Sendable {
    typealias ReaderFactory = @Sendable () -> EnergyModelCounterReader?

    private let lock = NSLock()
    private let readerFactory: ReaderFactory
    private let performanceLevelNames: [String]
    private var reader: EnergyModelCounterReader?
    private var didCreateReader = false
    private var estimator = SoCPowerEstimator()

    init(
        performanceLevelNames: [String] = SoCPowerSampler.systemPerformanceLevelNames(),
        readerFactory: @escaping ReaderFactory = { EnergyModelCounterReader() }
    ) {
        self.performanceLevelNames = performanceLevelNames
        self.readerFactory = readerFactory
    }

    func sample() -> SoCPowerReading {
        lock.lock()
        defer { lock.unlock() }
        if !didCreateReader {
            didCreateReader = true
            reader = readerFactory()
        }
        guard let reader, let counters = reader.read() else { return .unsupported }
        let powers = estimator.update(
            counters: counters,
            sampledAt: reader.now(),
            continuousClock: reader.continuousNow()
        )
        return SoCPowerReading.make(channelPowers: powers, performanceLevelNames: performanceLevelNames)
    }

    /// The panel stopped needing power data: the next sample starts a new
    /// baseline (its values marked updating until a full window exists).
    func pause() {
        lock.lock()
        estimator.reset()
        lock.unlock()
    }

    static func systemPerformanceLevelNames() -> [String] {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &count, &size, nil, 0) == 0,
              (1...8).contains(count) else { return [] }
        return (0..<Int(count)).compactMap { index in
            var length = 0
            let name = "hw.perflevel\(index).name"
            guard sysctlbyname(name, nil, &length, nil, 0) == 0, (2...256).contains(length) else { return nil }
            var buffer = [CChar](repeating: 0, count: length)
            guard sysctlbyname(name, &buffer, &length, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}

/// Everything the power page's "功耗" card shows, sampled together.
struct MenuBarPowerTelemetry: Equatable, Sendable {
    var smc: SMCPowerTelemetry
    var backlightBrightnessNits: HardwareReading<Double>
    var soc: SoCPowerReading
    var generatedAt: Date

    static func unsupported(at date: Date) -> MenuBarPowerTelemetry {
        MenuBarPowerTelemetry(
            smc: .unsupported,
            backlightBrightnessNits: .unsupported,
            soc: .unsupported,
            generatedAt: date
        )
    }
}

/// Read-only power telemetry for the power page (D57). Called on a
/// background task only while the page needs it.
enum PowerTelemetryService {
    static let socSampler = SoCPowerSampler()

    static func sample(now: Date = Date()) -> MenuBarPowerTelemetry {
        MenuBarPowerTelemetry(
            smc: SMCPowerTelemetryService.currentTelemetry(),
            backlightBrightnessNits: DisplayBacklightService.currentBrightnessNits(),
            soc: legacySoCReading(),
            generatedAt: now
        )
    }

    private static func legacySoCReading() -> SoCPowerReading {
        // D71: on macOS 26+ these third-party counters are frozen, even as
        // root. Never display a frozen count as a measured zero.
        if #available(macOS 26, *) { return .unsupported }
        return socSampler.sample()
    }

    static func pause() {
        socSampler.pause()
    }
}
