import AppKit
import Darwin
import Foundation
import os

struct BatteryHealthCommand: Hashable, Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
}

protocol BatteryHealthCommandRunning: Sendable {
    func capture(_ command: BatteryHealthCommand) async throws -> Data
}

enum BatteryPowerModeSettingKey: String, Codable, Equatable, Sendable {
    case powerMode = "powermode"
    case lowPowerMode = "lowpowermode"
}

struct BatteryPowerModeWriteCommand: Equatable, Sendable {
    static let executable = "/usr/bin/pmset"

    let source: BatteryPowerSource
    let mode: BatteryPowerMode
    let setting: BatteryPowerModeSettingKey
    let arguments: [String]

    private init(
        source: BatteryPowerSource,
        mode: BatteryPowerMode,
        setting: BatteryPowerModeSettingKey,
        arguments: [String]
    ) {
        self.source = source
        self.mode = mode
        self.setting = setting
        self.arguments = arguments
    }

    /// This is deliberately an exhaustive whitelist. Neither the executable,
    /// setting name nor any argument can originate from user-controlled text.
    static func make(
        source: BatteryPowerSource,
        mode: BatteryPowerMode,
        setting: BatteryPowerModeSettingKey = .powerMode
    ) -> BatteryPowerModeWriteCommand? {
        switch (source, mode, setting) {
        case (.batteryPower, .automatic, .powerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-b", "powermode", "0"]
            )
        case (.batteryPower, .lowPower, .powerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-b", "powermode", "1"]
            )
        case (.batteryPower, .highPower, .powerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-b", "powermode", "2"]
            )
        case (.acPower, .automatic, .powerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-c", "powermode", "0"]
            )
        case (.acPower, .lowPower, .powerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-c", "powermode", "1"]
            )
        case (.acPower, .highPower, .powerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-c", "powermode", "2"]
            )
        case (.batteryPower, .automatic, .lowPowerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-b", "lowpowermode", "0"]
            )
        case (.batteryPower, .lowPower, .lowPowerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-b", "lowpowermode", "1"]
            )
        case (.acPower, .automatic, .lowPowerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-c", "lowpowermode", "0"]
            )
        case (.acPower, .lowPower, .lowPowerMode):
            BatteryPowerModeWriteCommand(
                source: source,
                mode: mode,
                setting: setting,
                arguments: ["-c", "lowpowermode", "1"]
            )
        case (.batteryPower, .highPower, .lowPowerMode),
             (.acPower, .highPower, .lowPowerMode),
             (.unknown, _, _):
            nil
        }
    }

    var isWhitelisted: Bool {
        self == Self.make(source: source, mode: mode, setting: setting)
    }
}

enum BatteryPowerModeCommandFailure: Error, Equatable, Sendable {
    case cancelled
    case permissionDenied
    case timedOut
    case unavailable
    case verificationFailed
}

protocol BatteryPowerModeCommandRunning: Sendable {
    func apply(_ command: BatteryPowerModeWriteCommand) async throws -> BatteryPowerModes?
}

struct PrivilegedBatteryPowerModeCommandRunner: BatteryPowerModeCommandRunning {
    func apply(_ command: BatteryPowerModeWriteCommand) async throws -> BatteryPowerModes? {
        guard command.isWhitelisted else {
            throw BatteryPowerModeCommandFailure.unavailable
        }
        try Task.checkCancellation()
        let verifiedModes = try await FanControlCoordinator.shared.applyPowerMode(command)
        try Task.checkCancellation()
        return verifiedModes
    }
}

enum BatteryHealthCommandFailure: Error, Equatable {
    case permissionDenied
    case timedOut
    case cancelled
    case unavailable
}

final class BatteryHealthCancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        state.withLock { $0 }
    }

    func cancel() {
        state.withLock { $0 = true }
    }
}

struct ShellBatteryHealthCommandRunner: BatteryHealthCommandRunning {
    typealias Execute = @Sendable (
        BatteryHealthCommand,
        BatteryHealthCancellationFlag
    ) throws -> Data

    static let outputByteLimit = 1_048_576

    private let execute: Execute

    init(execute: @escaping Execute) {
        self.execute = execute
    }

    init(
        cleanupReaper: ShellProcessCleanupReaper = .shared,
        cleanupWaitTimeout: TimeInterval = 1
    ) {
        execute = { command, cancellation in
            Data(try Shell.captureCancellable(
                command.executable,
                command.arguments,
                timeout: command.timeout,
                outputByteLimit: ShellBatteryHealthCommandRunner.outputByteLimit,
                cancellationCheck: { cancellation.isCancelled },
                cleanupReaper: cleanupReaper,
                cleanupWaitTimeout: cleanupWaitTimeout
            ).utf8)
        }
    }

    func capture(_ command: BatteryHealthCommand) async throws -> Data {
        guard command == BatteryHealthService.profilerCommand
                || command == BatteryHealthService.powerModesCommand else {
            throw BatteryHealthCommandFailure.unavailable
        }
        try Task.checkCancellation()
        let cancellation = BatteryHealthCancellationFlag()
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try execute(command, cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw BatteryHealthCommandFailure.cancelled
        } catch ShellError.cancelled {
            throw BatteryHealthCommandFailure.cancelled
        } catch ShellError.timedOut {
            throw BatteryHealthCommandFailure.timedOut
        } catch let failure as BatteryHealthCommandFailure {
            throw failure
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain,
               nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                throw BatteryHealthCommandFailure.permissionDenied
            }
            throw BatteryHealthCommandFailure.unavailable
        }
    }
}

struct BatteryPowerModes: Equatable, Sendable {
    let battery: BatteryPowerMode?
    let adapter: BatteryPowerMode?
    let supportedBatteryModes: [BatteryPowerMode]
    let supportedAdapterModes: [BatteryPowerMode]
    let batterySetting: BatteryPowerModeSettingKey?
    let adapterSetting: BatteryPowerModeSettingKey?

    init(
        battery: BatteryPowerMode?,
        adapter: BatteryPowerMode?,
        supportedBatteryModes: [BatteryPowerMode] = [],
        supportedAdapterModes: [BatteryPowerMode] = [],
        batterySetting: BatteryPowerModeSettingKey? = nil,
        adapterSetting: BatteryPowerModeSettingKey? = nil
    ) {
        self.battery = battery
        self.adapter = adapter
        self.supportedBatteryModes = Self.normalized(supportedBatteryModes)
        self.supportedAdapterModes = Self.normalized(supportedAdapterModes)
        self.batterySetting = batterySetting
        self.adapterSetting = adapterSetting
    }

    static let unavailable = BatteryPowerModes(battery: nil, adapter: nil)

    func currentMode(for source: BatteryPowerSource) -> BatteryPowerMode? {
        switch source {
        case .batteryPower: battery
        case .acPower: adapter
        case .unknown: nil
        }
    }

    func supportedModes(for source: BatteryPowerSource) -> [BatteryPowerMode] {
        switch source {
        case .batteryPower: supportedBatteryModes
        case .acPower: supportedAdapterModes
        case .unknown: []
        }
    }

    func setting(for source: BatteryPowerSource) -> BatteryPowerModeSettingKey? {
        switch source {
        case .batteryPower: batterySetting
        case .acPower: adapterSetting
        case .unknown: nil
        }
    }

    private static func normalized(_ modes: [BatteryPowerMode]) -> [BatteryPowerMode] {
        [.automatic, .lowPower, .highPower].filter(modes.contains)
    }
}

enum BatteryPowerModeChangeResult: Equatable, Sendable {
    case changed(BatteryPowerModes)
    case busy
    case unsupported
    case cancelled
    case permissionDenied
    case timedOut
    case failed
    case verificationFailed(BatteryPowerModes)
}

protocol BatteryPowerModeControlling: Sendable {
    func readPowerModes() async -> BatteryPowerModes?
    func changePowerMode(
        source: BatteryPowerSource,
        mode: BatteryPowerMode
    ) async -> BatteryPowerModeChangeResult
}

private enum BatteryHealthSampleOutcome: Sendable {
    case present(BatteryHealthSnapshot)
    case notPresent
    case failed(BatteryHealthProbeFailureReason)
}

private extension BatteryHealthCommandFailure {
    var probeFailureReason: BatteryHealthProbeFailureReason {
        switch self {
        case .permissionDenied:
            .permissionDenied
        case .timedOut:
            .timedOut
        case .cancelled:
            .cancelled
        case .unavailable:
            .unavailable
        }
    }
}

actor BatteryHealthService {
    static let profilerCommand = BatteryHealthCommand(
        executable: "/usr/sbin/system_profiler",
        arguments: ["-json", "-detailLevel", "mini", "-timeout", "5", "SPPowerDataType"],
        timeout: 8
    )

    static let powerModesCommand = BatteryHealthCommand(
        executable: "/usr/bin/pmset",
        arguments: ["-g", "custom"],
        timeout: 3
    )

    private let runner: any BatteryHealthCommandRunning
    private let powerModeWriter: any BatteryPowerModeCommandRunning
    private let powerSampleProvider: @Sendable () -> BatteryPowerSample?
    private let now: @Sendable () -> Date
    private let verificationDelay: @Sendable () async -> Void
    private let beforeSnapshotPublication: (@Sendable () async -> Void)?
    private var activeSamplingTask: Task<BatteryHealthSampleOutcome, Error>?
    private var samplingGeneration: UInt64 = 0
    private var isChangingPowerMode = false

    init(
        runner: any BatteryHealthCommandRunning = ShellBatteryHealthCommandRunner(),
        powerModeWriter: any BatteryPowerModeCommandRunning = PrivilegedBatteryPowerModeCommandRunner(),
        powerSampleProvider: @escaping @Sendable () -> BatteryPowerSample? = BatteryPowerService.internalBatterySample,
        now: @escaping @Sendable () -> Date = { Date() },
        verificationDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(200))
        },
        beforeSnapshotPublication: (@Sendable () async -> Void)? = nil
    ) {
        self.runner = runner
        self.powerModeWriter = powerModeWriter
        self.powerSampleProvider = powerSampleProvider
        self.now = now
        self.verificationDelay = verificationDelay
        self.beforeSnapshotPublication = beforeSnapshotPublication
    }

    func snapshot() async throws -> BatteryHealthSnapshot? {
        switch try await sampleOutcome() {
        case let .present(snapshot):
            return snapshot
        case .notPresent, .failed:
            return nil
        }
    }

    func evidence() async throws -> BatteryHealthEvidence {
        switch try await sampleOutcome() {
        case let .present(snapshot):
            return .present(snapshot)
        case .notPresent:
            return .notPresent(checkedAt: now())
        case let .failed(reason):
            return .failed(reason: reason, checkedAt: now())
        }
    }

    func readPowerModes() async -> BatteryPowerModes? {
        do {
            let data = try await Self.captureRequired(Self.powerModesCommand, runner: runner)
            try Task.checkCancellation()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return Self.powerModes(
                from: output,
                inferMissingBatteryLowPowerMode:
                    powerSampleProvider() != nil
            )
        } catch {
            return nil
        }
    }

    func changePowerMode(
        source: BatteryPowerSource,
        mode: BatteryPowerMode
    ) async -> BatteryPowerModeChangeResult {
        guard !isChangingPowerMode else { return .busy }
        isChangingPowerMode = true
        defer { isChangingPowerMode = false }

        guard source != .unknown,
              let baseline = await readPowerModes(),
              baseline.supportedModes(for: source).contains(mode),
              let setting = baseline.setting(for: source),
              let command = BatteryPowerModeWriteCommand.make(
                  source: source,
                  mode: mode,
                  setting: setting
              ) else {
            return .unsupported
        }

        if baseline.currentMode(for: source) == mode {
            return .changed(baseline)
        }

        let helperVerifiedModes: BatteryPowerModes?
        do {
            helperVerifiedModes = try await powerModeWriter.apply(command)
        } catch BatteryPowerModeCommandFailure.cancelled {
            return .cancelled
        } catch BatteryPowerModeCommandFailure.permissionDenied {
            return .permissionDenied
        } catch BatteryPowerModeCommandFailure.timedOut {
            return .timedOut
        } catch BatteryPowerModeCommandFailure.verificationFailed {
            return .verificationFailed(baseline)
        } catch {
            return .failed
        }

        if let helperVerifiedModes {
            guard helperVerifiedModes.setting(for: source) == setting,
                  helperVerifiedModes.currentMode(for: source) == mode else {
                return .verificationFailed(helperVerifiedModes)
            }
            return .changed(helperVerifiedModes)
        }

        // pmset normally publishes the new custom profile immediately, but a
        // short bounded retry absorbs occasional powerd propagation latency.
        // Success is exact: the requested source, setting key and mode must all
        // match. A change to the other power source never counts as success.
        var lastObserved = baseline
        for attempt in 0..<10 {
            if attempt > 0 {
                await verificationDelay()
            }
            guard !Task.isCancelled else { return .cancelled }
            guard let observed = await readPowerModes() else { continue }
            lastObserved = observed
            if observed.setting(for: source) == setting,
               observed.currentMode(for: source) == mode {
                return .changed(observed)
            }
        }
        return .verificationFailed(lastObserved)
    }

    private func sampleOutcome() async throws -> BatteryHealthSampleOutcome {
        samplingGeneration &+= 1
        let generation = samplingGeneration

        if let previous = activeSamplingTask {
            previous.cancel()
            _ = try? await previous.value
            guard generation == samplingGeneration else {
                throw CancellationError()
            }
        }
        try Task.checkCancellation()

        let runner = self.runner
        let powerSampleProvider = self.powerSampleProvider
        let now = self.now
        let task = Task.detached(priority: .utility) {
            try await Self.sample(
                runner: runner,
                powerSampleProvider: powerSampleProvider,
                now: now
            )
        }
        activeSamplingTask = task

        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if let beforeSnapshotPublication {
                await beforeSnapshotPublication()
            }
            try Task.checkCancellation()
            guard generation == samplingGeneration else {
                throw CancellationError()
            }
            activeSamplingTask = nil
            return outcome
        } catch {
            if generation == samplingGeneration {
                activeSamplingTask = nil
            }
            throw error
        }
    }

    private nonisolated static func sample(
        runner: any BatteryHealthCommandRunning,
        powerSampleProvider: @escaping @Sendable () -> BatteryPowerSample?,
        now: @escaping @Sendable () -> Date
    ) async throws -> BatteryHealthSampleOutcome {
        try Task.checkCancellation()
        let powerSample = powerSampleProvider()
        let profilerData: Data?
        do {
            profilerData = try await captureRequired(Self.profilerCommand, runner: runner)
        } catch let failure as BatteryHealthCommandFailure {
            guard reliableInternalPowerSnapshot(from: powerSample) != nil else {
                return .failed(failure.probeFailureReason)
            }
            profilerData = nil
        }
        try Task.checkCancellation()
        let modesData = try await captureOptional(Self.powerModesCommand, runner: runner)
        try Task.checkCancellation()
        guard let snapshot = Self.parse(
            systemProfilerData: profilerData,
            powerSample: powerSample,
            powerModeOutput: modesData.flatMap { String(data: $0, encoding: .utf8) },
            sampledAt: now()
        ) else {
            if let profilerData,
               explicitlyReportsNoBattery(profilerData) {
                return .notPresent
            }
            return .failed(.readFailed)
        }
        return .present(snapshot)
    }

    static func parse(
        systemProfilerData: Data?,
        powerSample: BatteryPowerSample?,
        powerModeOutput: String?,
        sampledAt: Date = Date()
    ) -> BatteryHealthSnapshot? {
        let profilerBattery = systemProfilerData.flatMap(batteryRecord)
        let internalPowerSnapshot = reliableInternalPowerSnapshot(from: powerSample)
        if let systemProfilerData,
           hasPowerDataEnvelope(systemProfilerData),
           profilerBattery == nil,
           internalPowerSnapshot == nil {
            return nil
        }
        guard profilerBattery != nil || internalPowerSnapshot != nil else { return nil }

        let chargeInfo = profilerBattery.flatMap {
            dictionary(in: $0, keys: ["sppower_battery_charge_info"])
        }
        let healthInfo = profilerBattery.flatMap {
            dictionary(in: $0, keys: ["sppower_battery_health_info"])
        }
        let chargePercent = internalPowerSnapshot?.chargePercent ?? chargeInfo.flatMap {
            percent(value(in: $0, keys: ["sppower_battery_state_of_charge"]))
        }
        let isCharging = internalPowerSnapshot?.isCharging ?? chargeInfo.flatMap {
            boolean(value(in: $0, keys: ["sppower_battery_is_charging"]))
        }
        let maximumCapacityPercent = healthInfo.flatMap {
            percent(value(in: $0, keys: ["sppower_battery_health_maximum_capacity"]))
        }
        let cycleCount = healthInfo.flatMap {
            nonnegativeInteger(value(in: $0, keys: ["sppower_battery_cycle_count"]))
        }
        let condition = healthInfo.flatMap {
            batteryCondition(value(in: $0, keys: ["sppower_battery_health"]))
        }
        let optimizedCharging = internalPowerSnapshot?.isOptimizedChargingEngaged
            ?? chargeInfo.flatMap {
                boolean(value(in: $0, keys: [
                    "sppower_battery_optimized_charging",
                    "optimized_battery_charging_engaged",
                    "Optimized Battery Charging Engaged"
                ]))
            }
        let modes = powerModeOutput.map {
            powerModes(from: $0)
        } ?? BatteryPowerModes(
            battery: nil,
            adapter: nil
        )
        let availability: HealthAvailability = switch condition {
        case .normal?, .serviceRecommended?:
            .available
        case .unknown?, nil:
            .partial
        }
        let proposedStatus: HealthStatus = switch condition {
        case .serviceRecommended?:
            .actionRequired
        case .normal?:
            .healthy
        case .unknown?, nil:
            .attention
        }

        return BatteryHealthSnapshot(
            availability: availability,
            status: proposedStatus,
            currentChargePercent: chargePercent,
            isCharging: isCharging,
            powerSource: internalPowerSnapshot?.powerSource,
            remainingTimeMinutes: internalPowerSnapshot?.remainingTimeMinutes,
            maximumCapacityPercent: maximumCapacityPercent,
            cycleCount: cycleCount,
            condition: condition,
            batteryPowerMode: modes.battery,
            adapterPowerMode: modes.adapter,
            guidance: guidance(
                condition: condition,
                optimizedCharging: optimizedCharging,
                powerSnapshot: internalPowerSnapshot,
                chargePercent: chargePercent,
                modes: modes
            ),
            sampledAt: sampledAt
        )
    }

    static func powerModes(
        from output: String,
        inferMissingBatteryLowPowerMode: Bool = false
    ) -> BatteryPowerModes {
        enum Section {
            case battery
            case adapter
        }

        struct Accumulator {
            var consolidatedValue: Int?
            var sawConsolidatedKey = false
            var consolidatedIsInvalid = false
            var lowPowerValue: Int?
            var sawLowPowerKey = false
            var lowPowerIsInvalid = false

            mutating func recordConsolidated(_ rawValue: Int?) {
                sawConsolidatedKey = true
                guard let rawValue, (0...2).contains(rawValue) else {
                    consolidatedIsInvalid = true
                    return
                }
                if let consolidatedValue, consolidatedValue != rawValue {
                    consolidatedIsInvalid = true
                    return
                }
                consolidatedValue = rawValue
            }

            mutating func recordLowPower(_ rawValue: Int?) {
                sawLowPowerKey = true
                guard let rawValue, (0...1).contains(rawValue) else {
                    lowPowerIsInvalid = true
                    return
                }
                if let lowPowerValue, lowPowerValue != rawValue {
                    lowPowerIsInvalid = true
                    return
                }
                lowPowerValue = rawValue
            }

            var setting: BatteryPowerModeSettingKey? {
                if sawConsolidatedKey {
                    return !consolidatedIsInvalid && consolidatedValue != nil
                        ? .powerMode
                        : nil
                }
                if sawLowPowerKey {
                    return !lowPowerIsInvalid && lowPowerValue != nil
                        ? .lowPowerMode
                        : nil
                }
                return nil
            }

            var currentMode: BatteryPowerMode? {
                if sawConsolidatedKey {
                    guard !consolidatedIsInvalid else { return nil }
                    return consolidatedValue.flatMap(BatteryHealthService.powerMode)
                }
                guard sawLowPowerKey,
                      !lowPowerIsInvalid,
                      let lowPowerValue else { return nil }
                switch lowPowerValue {
                case 0: return .automatic
                case 1: return .lowPower
                default: return nil
                }
            }

            var supportedModes: [BatteryPowerMode] {
                if sawConsolidatedKey {
                    return !consolidatedIsInvalid && consolidatedValue != nil
                        ? [.automatic, .lowPower, .highPower]
                        : []
                }
                if sawLowPowerKey {
                    return !lowPowerIsInvalid && lowPowerValue != nil
                        ? [.automatic, .lowPower]
                        : []
                }
                return []
            }

            var sawAnyModeKey: Bool {
                sawConsolidatedKey || sawLowPowerKey
            }
        }

        var section: Section?
        var battery = Accumulator()
        var adapter = Accumulator()
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed.lowercased() {
            case "battery power:":
                section = .battery
            case "ac power:":
                section = .adapter
            default:
                if trimmed.hasSuffix(":") {
                    // Do not let an unknown power-source section (for example
                    // UPS Power) inherit the previous Battery or AC source.
                    section = nil
                    continue
                }
                let components = trimmed.split(whereSeparator: \.isWhitespace)
                guard let rawKey = components.first else {
                    continue
                }
                let key = rawKey.lowercased()
                guard key == BatteryPowerModeSettingKey.powerMode.rawValue
                        || key == BatteryPowerModeSettingKey.lowPowerMode.rawValue else {
                    continue
                }
                let rawValue = components.count == 2 ? Int(components[1]) : nil
                switch section {
                case .battery:
                    switch key {
                    case BatteryPowerModeSettingKey.powerMode.rawValue:
                        battery.recordConsolidated(rawValue)
                    case BatteryPowerModeSettingKey.lowPowerMode.rawValue:
                        battery.recordLowPower(rawValue)
                    default:
                        break
                    }
                case .adapter:
                    switch key {
                    case BatteryPowerModeSettingKey.powerMode.rawValue:
                        adapter.recordConsolidated(rawValue)
                    case BatteryPowerModeSettingKey.lowPowerMode.rawValue:
                        adapter.recordLowPower(rawValue)
                    default:
                        break
                    }
                case nil:
                    break
                }
            }
        }
        // macOS 26 can omit the Battery Power section from `pmset -g custom`
        // while a real internal battery is present and the low-power feature
        // is exposed for AC. In that state the missing value is unknown, not
        // unsupported. Offer only the conservative Automatic/Low Power pair;
        // a write is still reported as successful only if a later pmset read
        // publishes the exact Battery value.
        let canInferBatteryLowPower =
            inferMissingBatteryLowPowerMode
            && !battery.sawAnyModeKey
            && adapter.setting == .lowPowerMode
        return BatteryPowerModes(
            battery: canInferBatteryLowPower ? nil : battery.currentMode,
            adapter: adapter.currentMode,
            supportedBatteryModes: canInferBatteryLowPower
                ? [.automatic, .lowPower]
                : battery.supportedModes,
            supportedAdapterModes: adapter.supportedModes,
            batterySetting: canInferBatteryLowPower
                ? .lowPowerMode
                : battery.setting,
            adapterSetting: adapter.setting
        )
    }

    private nonisolated static func captureRequired(
        _ command: BatteryHealthCommand,
        runner: any BatteryHealthCommandRunning
    ) async throws -> Data {
        do {
            return try await runner.capture(command)
        } catch is CancellationError {
            throw CancellationError()
        } catch BatteryHealthCommandFailure.cancelled {
            throw CancellationError()
        } catch let failure as BatteryHealthCommandFailure {
            throw failure
        } catch {
            // Do not let command output or other implementation details escape
            // into the health model or UI.
            throw BatteryHealthCommandFailure.unavailable
        }
    }

    private nonisolated static func captureOptional(
        _ command: BatteryHealthCommand,
        runner: any BatteryHealthCommandRunning
    ) async throws -> Data? {
        do {
            return try await runner.capture(command)
        } catch is CancellationError {
            throw CancellationError()
        } catch BatteryHealthCommandFailure.cancelled {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func batteryRecord(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return dictionaries(in: object).first { dictionary in
            dictionary["sppower_battery_charge_info"] is [String: Any]
                || dictionary["sppower_battery_health_info"] is [String: Any]
        }
    }

    private static func reliableInternalPowerSnapshot(
        from sample: BatteryPowerSample?
    ) -> BatteryPowerSnapshot? {
        guard let sample, sample.provenance == .internalBattery else { return nil }
        let snapshot = sample.snapshot
        guard snapshot.chargePercent != nil
                || snapshot.isCharging != nil
                || snapshot.isFullyCharged != nil
                || snapshot.isOptimizedChargingEngaged != nil else {
            return nil
        }
        return snapshot
    }

    private static func hasPowerDataEnvelope(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["SPPowerDataType"] is [Any]
    }

    private static func explicitlyReportsNoBattery(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["SPPowerDataType"] as? [Any] else {
            return false
        }
        return records.isEmpty
    }

    private static func dictionaries(in object: Any) -> [[String: Any]] {
        if let dictionary = object as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap(dictionaries)
        }
        if let array = object as? [Any] {
            return array.flatMap(dictionaries)
        }
        return []
    }

    private static func dictionary(in source: [String: Any], keys: [String]) -> [String: Any]? {
        value(in: source, keys: keys) as? [String: Any]
    }

    private static func value(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let result = dictionary[key] { return result }
        }
        for key in keys {
            if let result = dictionary.first(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            })?.value {
                return result
            }
        }
        return nil
    }

    private static func percent(_ value: Any?) -> Int? {
        let parsed: Int?
        if let number = value as? NSNumber {
            parsed = number.intValue
        } else if let string = value as? String {
            parsed = Int(string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: ""))
        } else {
            parsed = nil
        }
        guard let parsed, (0...100).contains(parsed) else { return nil }
        return parsed
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        let parsed: Int?
        if let number = value as? NSNumber {
            parsed = number.intValue
        } else if let string = value as? String {
            parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            parsed = nil
        }
        guard let parsed, parsed >= 0 else { return nil }
        return parsed
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = value as? String else { return nil }
        switch normalizedToken(string) {
        case "yes", "true", "enabled", "on", "1":
            return true
        case "no", "false", "disabled", "off", "0":
            return false
        default:
            return nil
        }
    }

    private static func batteryCondition(_ value: Any?) -> BatteryCondition? {
        guard let string = value as? String else { return nil }
        let token = normalizedToken(string)
        if token.contains("service")
            || token.contains("replace")
            || token.contains("checkbattery")
            || token == "poor" {
            return .serviceRecommended
        }
        if token.contains("normal") || token.contains("good") {
            return .normal
        }
        return token.isEmpty ? nil : .unknown
    }

    private static func guidance(
        condition: BatteryCondition?,
        optimizedCharging: Bool?,
        powerSnapshot: BatteryPowerSnapshot?,
        chargePercent: Int?,
        modes: BatteryPowerModes
    ) -> BatteryGuidance {
        if condition == .serviceRecommended {
            return BatteryGuidance(
                kind: .serviceRecommended,
                detail: L10n.text(
                    "系统建议检修电池，请在系统设置中查看详情。",
                    "macOS recommends battery service. Review the details in System Settings."
                )
            )
        }
        if optimizedCharging == true {
            return BatteryGuidance(
                kind: .optimizedChargingNormal,
                detail: L10n.text(
                    "系统正在使用优化充电保护电池，这是正常状态。",
                    "Optimized charging is protecting the battery; this is normal."
                )
            )
        }
        if powerSnapshot?.powerSource == .batteryPower,
           let chargePercent,
           chargePercent <= 20,
           modes.battery != .lowPower {
            return BatteryGuidance(
                kind: .considerLowPower,
                detail: L10n.text(
                    "当前电量较低，可在系统设置中考虑低电量模式。",
                    "Battery charge is low. Consider Low Power Mode in System Settings."
                )
            )
        }
        if powerSnapshot?.powerSource == .acPower,
           let adapter = modes.adapter,
           adapter != .automatic {
            return BatteryGuidance(
                kind: .automaticRecommended,
                detail: L10n.text(
                    "日常接电使用可优先考虑自动模式。",
                    "Automatic mode is usually the best choice for everyday use on power."
                )
            )
        }
        return BatteryGuidance(kind: .none)
    }

    private static func powerMode(_ rawValue: Int) -> BatteryPowerMode? {
        switch rawValue {
        case 0:
            .automatic
        case 1:
            .lowPower
        case 2:
            .highPower
        default:
            nil
        }
    }

    private static func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension BatteryHealthService: BatteryPowerModeControlling {}

enum BatteryHealthRuntime {
    static let shared = BatteryHealthService()
}

@MainActor
protocol BatterySettingsOpening: AnyObject {
    func open(_ url: URL) -> Bool
}

enum BatterySettingsBeginResult: Equatable, Sendable {
    case opened
    case baselineUnavailable
    case failedToOpen
    case superseded
}

enum BatterySettingsVerificationResult: Equatable, Sendable {
    case changed
    case unchanged
    case expired
    case unverifiable
}

@MainActor
protocol BatterySettingsVerifying: AnyObject {
    func beginAdjustment() async -> BatterySettingsBeginResult
    func verifyAfterSettingsChange() async -> BatterySettingsVerificationResult
    func openSettingsWithoutVerification() -> Bool
    func cancelVerification()
}

@MainActor
final class WorkspaceBatterySettingsOpener: BatterySettingsOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class BatterySettingsVerifier: BatterySettingsVerifying {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Battery-Settings.extension"
    )!

    private struct Fingerprint: Equatable {
        enum Comparison {
            case changed
            case unchanged
            case unverifiable
        }

        let batteryPowerMode: BatteryPowerMode?
        let adapterPowerMode: BatteryPowerMode?

        init?(_ snapshot: BatteryHealthSnapshot) {
            guard snapshot.batteryPowerMode != nil || snapshot.adapterPowerMode != nil else {
                return nil
            }
            self.batteryPowerMode = snapshot.batteryPowerMode
            self.adapterPowerMode = snapshot.adapterPowerMode
        }

        func comparison(with current: Fingerprint) -> Comparison {
            var didChange = false
            if let batteryPowerMode {
                guard let currentBatteryPowerMode = current.batteryPowerMode else {
                    return .unverifiable
                }
                didChange = didChange || currentBatteryPowerMode != batteryPowerMode
            }
            if let adapterPowerMode {
                guard let currentAdapterPowerMode = current.adapterPowerMode else {
                    return .unverifiable
                }
                didChange = didChange || currentAdapterPowerMode != adapterPowerMode
            }
            return didChange ? .changed : .unchanged
        }
    }

    private let reader: () async -> BatteryHealthSnapshot?
    private let opener: any BatterySettingsOpening
    private let now: () -> Date
    private let verificationWindow: TimeInterval
    private var baseline: Fingerprint?
    private var startedAt: Date?
    private var sessionGeneration: UInt64 = 0

    init(
        reader: @escaping () async -> BatteryHealthSnapshot?,
        opener: any BatterySettingsOpening = WorkspaceBatterySettingsOpener(),
        now: @escaping () -> Date = Date.init,
        verificationWindow: TimeInterval = 300
    ) {
        self.reader = reader
        self.opener = opener
        self.now = now
        self.verificationWindow = max(0, verificationWindow)
    }

    func beginAdjustment() async -> BatterySettingsBeginResult {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        baseline = nil
        startedAt = nil

        let snapshot = await reader()
        guard generation == sessionGeneration, !Task.isCancelled else { return .superseded }
        guard let snapshot, let fingerprint = Fingerprint(snapshot) else {
            cancelVerification()
            return .baselineUnavailable
        }
        guard opener.open(Self.settingsURL) else {
            if generation == sessionGeneration {
                cancelVerification()
            }
            return .failedToOpen
        }
        guard generation == sessionGeneration, !Task.isCancelled else { return .superseded }
        baseline = fingerprint
        startedAt = now()
        return .opened
    }

    func verifyAfterSettingsChange() async -> BatterySettingsVerificationResult {
        guard let baseline, let startedAt else { return .unverifiable }
        let generation = sessionGeneration
        let age = now().timeIntervalSince(startedAt)
        guard age >= 0, age <= verificationWindow else {
            if generation == sessionGeneration {
                cancelVerification()
            }
            return .expired
        }
        guard let snapshot = await reader() else {
            guard generation == sessionGeneration, !Task.isCancelled else { return .unverifiable }
            cancelVerification()
            return .unverifiable
        }
        guard generation == sessionGeneration, !Task.isCancelled else { return .unverifiable }
        guard let current = Fingerprint(snapshot) else {
            cancelVerification()
            return .unverifiable
        }

        switch baseline.comparison(with: current) {
        case .changed:
            cancelVerification()
            return .changed
        case .unchanged:
            return .unchanged
        case .unverifiable:
            cancelVerification()
            return .unverifiable
        }
    }

    func openSettingsWithoutVerification() -> Bool {
        cancelVerification()
        return opener.open(Self.settingsURL)
    }

    func cancelVerification() {
        sessionGeneration &+= 1
        baseline = nil
        startedAt = nil
    }
}
