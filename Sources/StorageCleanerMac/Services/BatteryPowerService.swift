import Foundation
import IOKit
import IOKit.ps

enum BatteryPowerSource: String, Codable, Equatable, Sendable {
    case acPower
    case batteryPower
    case unknown
}

/// A normalized battery reading used by presentation and history consumers.
/// The persisted menu-bar history keeps its older wire format; this value is
/// intentionally runtime-only so missing fields stay optional instead of
/// being collapsed into false or zero.
struct BatterySample: Equatable, Sendable {
    let timestamp: Date
    let monotonicTimestamp: Duration
    let levelPercent: Double?
    let powerSource: BatteryPowerSource
    let isCharging: Bool?
    let isCharged: Bool?
    let timeToFullMinutes: Int?
    let timeToEmptyMinutes: Int?
    let healthPercent: Double?
    let adapterWatts: Int?
    let isValid: Bool

    init(
        timestamp: Date,
        monotonicTimestamp: Duration,
        snapshot: BatteryPowerSnapshot?,
        healthPercent: Double? = nil,
        adapterWatts: Int? = nil
    ) {
        self.timestamp = timestamp
        self.monotonicTimestamp = monotonicTimestamp
        self.levelPercent = snapshot?.chargePercent.map(Double.init)
        self.powerSource = snapshot?.powerSource ?? .unknown
        self.isCharging = snapshot?.isCharging
        self.isCharged = snapshot?.isFullyCharged
        self.timeToFullMinutes = snapshot?.timeToFullChargeMinutes
        self.timeToEmptyMinutes = snapshot?.timeToEmptyMinutes
        self.healthPercent = healthPercent
        self.adapterWatts = adapterWatts
        let levelIsValid = levelPercent.map { $0.isFinite && (0...100).contains($0) } ?? true
        self.isValid = snapshot != nil
            && timestamp.timeIntervalSinceReferenceDate.isFinite
            && levelIsValid
    }
}

enum BatteryPresentationState: Equatable, Sendable {
    case charging(timeToFullMinutes: Int?)
    case charged
    case connectedNotCharging
    case optimizedChargingPaused
    case discharging(timeToEmptyMinutes: Int?)
    case calculating
    case unknown
    case unavailable
}

struct BatteryPowerSnapshot: Equatable, Sendable {
    let chargePercent: Int?
    let isCharging: Bool?
    let powerSource: BatteryPowerSource
    let timeToEmptyMinutes: Int?
    let timeToFullChargeMinutes: Int?
    let isFullyCharged: Bool?
    let isOptimizedChargingEngaged: Bool?

    init(
        chargePercent: Int?,
        isCharging: Bool?,
        powerSource: BatteryPowerSource,
        timeToEmptyMinutes: Int?,
        timeToFullChargeMinutes: Int?,
        isFullyCharged: Bool? = nil,
        isOptimizedChargingEngaged: Bool? = nil
    ) {
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.powerSource = powerSource
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullChargeMinutes = timeToFullChargeMinutes
        self.isFullyCharged = isFullyCharged
        self.isOptimizedChargingEngaged = isOptimizedChargingEngaged
    }

    var isConnectedToAC: Bool? {
        switch powerSource {
        case .acPower:
            true
        case .batteryPower:
            false
        case .unknown:
            nil
        }
    }

    var isDischarging: Bool? {
        if isCharging == true {
            return false
        }
        switch powerSource {
        case .batteryPower:
            return isCharging == false ? true : nil
        case .acPower:
            return false
        case .unknown:
            return nil
        }
    }

    var remainingTimeMinutes: Int? {
        if isCharging == true {
            return timeToFullChargeMinutes
        }
        if isDischarging == true {
            return timeToEmptyMinutes
        }
        return nil
    }

    var shouldOfferFullChargeAction: Bool {
        guard powerSource == .acPower,
              isCharging == false,
              let chargePercent else { return false }
        return (0..<100).contains(chargePercent)
    }

    var presentationState: BatteryPresentationState {
        // A 100% reading is not proof that the adapter is connected or that
        // macOS has declared the pack fully charged; use the explicit
        // IOPowerSources flag so a just-unplugged battery remains discharging.
        if isFullyCharged == true {
            return .charged
        }

        switch powerSource {
        case .acPower:
            if isCharging == true {
                return .charging(timeToFullMinutes: timeToFullChargeMinutes)
            }
            if isCharging == false {
                return isOptimizedChargingEngaged == true
                    ? .optimizedChargingPaused
                    : .connectedNotCharging
            }
            return .unknown
        case .batteryPower:
            if isCharging == false {
                return .discharging(timeToEmptyMinutes: timeToEmptyMinutes)
            }
            if isCharging == true {
                return .charging(timeToFullMinutes: timeToFullChargeMinutes)
            }
            return .calculating
        case .unknown:
            return isCharging == true
                ? .charging(timeToFullMinutes: timeToFullChargeMinutes)
                : .unknown
        }
    }
}

enum BatteryPowerProvenance: Equatable, Sendable {
    case internalBattery
    case externalOrUnknown
}

struct BatteryPowerSample: Equatable, Sendable {
    let snapshot: BatteryPowerSnapshot
    let provenance: BatteryPowerProvenance
}

enum InternalBatteryAvailability: Equatable, Sendable {
    case present
    case absent
    case unknown
}

enum BatteryPowerService {
    /// Detect the Mac's internal hardware, independently of charge readings,
    /// AC power, UPS devices, or rechargeable peripherals.
    static func internalBatteryAvailability() -> InternalBatteryAvailability {
        var registryHasBattery: Bool?
        if let matching = IOServiceMatching("AppleSmartBattery") {
            var iterator: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                let battery = IOIteratorNext(iterator)
                registryHasBattery = battery != 0
                if battery != 0 { IOObjectRelease(battery) }
            }
        }
        if registryHasBattery == true { return .present }
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else { return .unknown }
        let info = unmanagedInfo.takeRetainedValue()
        guard let unmanagedSources = IOPSCopyPowerSourcesList(info) else { return .unknown }
        let sources = unmanagedSources.takeRetainedValue() as [AnyObject]
        var descriptions = [[String: Any]]()
        for source in sources {
            guard let value = IOPSGetPowerSourceDescription(info, source),
                  let description = value.takeUnretainedValue() as? [String: Any] else {
                return .unknown
            }
            descriptions.append(description)
        }
        return internalBatteryAvailability(
            registryHasBattery: registryHasBattery, powerSourceDescriptions: descriptions
        )
    }

    static func internalBatteryAvailability(
        registryHasBattery: Bool?, powerSourceDescriptions: [[String: Any]]?
    ) -> InternalBatteryAvailability {
        if registryHasBattery == true { return .present }
        guard let descriptions = powerSourceDescriptions else { return .unknown }
        if descriptions.contains(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) {
            return .present
        }
        // Absence requires two successful reads. A failed read is not evidence
        // that the machine has no battery, even when it currently uses AC.
        guard registryHasBattery == false,
              descriptions.allSatisfy({ $0[kIOPSTypeKey] as? String != nil }) else { return .unknown }
        return .absent
    }

    static func snapshot() -> BatteryPowerSnapshot? {
        selectedSample(allowExternalFallback: true)?.snapshot
    }

    static func internalBatterySnapshot() -> BatteryPowerSnapshot? {
        internalBatterySample()?.snapshot
    }

    static func currentSystemPowerSource() -> BatteryPowerSource {
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else { return .unknown }
        let info = unmanagedInfo.takeRetainedValue()
        guard let unmanagedType = IOPSGetProvidingPowerSourceType(info) else {
            return .unknown
        }
        return powerSource(
            fromProvidingType: unmanagedType.takeUnretainedValue() as String
        )
    }

    static func powerSource(fromProvidingType type: String?) -> BatteryPowerSource {
        switch type {
        case kIOPMACPowerKey, kIOPMUPSPowerKey:
            .acPower
        case kIOPMBatteryPowerKey:
            .batteryPower
        default:
            .unknown
        }
    }

    static func internalBatterySample() -> BatteryPowerSample? {
        selectedSample(allowExternalFallback: false)
    }

    private static func selectedSample(allowExternalFallback: Bool) -> BatteryPowerSample? {
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = unmanagedInfo.takeRetainedValue()
        guard let unmanagedSources = IOPSCopyPowerSourcesList(info) else { return nil }
        let sources = unmanagedSources.takeRetainedValue() as [AnyObject]

        var descriptions = [[String: Any]]()
        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(info, source),
                  let description = unmanagedDescription.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            descriptions.append(description)
        }
        return selectSample(
            fromPowerSourceDescriptions: descriptions,
            allowExternalFallback: allowExternalFallback
        )
    }

    static func selectSample(
        fromPowerSourceDescriptions descriptions: [[String: Any]],
        allowExternalFallback: Bool
    ) -> BatteryPowerSample? {
        var firstExternal: BatteryPowerSample?
        for description in descriptions {
            let parsed = snapshot(fromPowerSourceDescription: description)
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return BatteryPowerSample(snapshot: parsed, provenance: .internalBattery)
            }
            if allowExternalFallback, firstExternal == nil, parsed.chargePercent != nil {
                firstExternal = BatteryPowerSample(
                    snapshot: parsed,
                    provenance: .externalOrUnknown
                )
            }
        }
        return firstExternal
    }

    static func snapshot(fromPowerSourceDescription description: [String: Any]) -> BatteryPowerSnapshot {
        let currentCapacity = integer(description[kIOPSCurrentCapacityKey])
        let maximumCapacity = integer(description[kIOPSMaxCapacityKey])
        let chargePercent: Int?
        if let currentCapacity, let maximumCapacity, maximumCapacity > 0 {
            chargePercent = min(
                100,
                max(0, Int((Double(currentCapacity) / Double(maximumCapacity) * 100).rounded()))
            )
        } else {
            chargePercent = nil
        }

        let powerSource: BatteryPowerSource
        switch description[kIOPSPowerSourceStateKey] as? String {
        case kIOPSACPowerValue:
            powerSource = .acPower
        case kIOPSBatteryPowerValue:
            powerSource = .batteryPower
        default:
            powerSource = .unknown
        }

        return BatteryPowerSnapshot(
            chargePercent: chargePercent,
            isCharging: boolean(description[kIOPSIsChargingKey]),
            powerSource: powerSource,
            timeToEmptyMinutes: minutes(description[kIOPSTimeToEmptyKey]),
            timeToFullChargeMinutes: minutes(description[kIOPSTimeToFullChargeKey]),
            isFullyCharged: boolean(description["Is Charged"]),
            isOptimizedChargingEngaged: boolean(
                description["Optimized Battery Charging Engaged"]
            )
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        return (value as? NSNumber)?.intValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func minutes(_ value: Any?) -> Int? {
        // IOPowerSources uses -1 and, on some transitions, 0 for an unknown
        // estimate. Neither value is a user-visible "0 minutes" estimate.
        guard let value = integer(value), value > 0 else { return nil }
        return value
    }
}

/// IOKit power-source changes are more precise than a UI timer. The observer
/// only asks the shared monitor to refresh; it never creates a second sampler.
final class BatteryPowerSourceObserver: @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    private var runLoopSource: CFRunLoopSource?

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard runLoopSource == nil,
              let unmanagedSource = IOPSNotificationCreateRunLoopSource(
                  Self.callback,
                  Unmanaged.passUnretained(self).toOpaque()
              ) else { return }
        let source = unmanagedSource.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            source,
            CFRunLoopMode.defaultMode
        )
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                CFRunLoopMode.defaultMode
            )
        }
    }

    @MainActor
    private func handleNotification() {
        onChange()
    }

    private static let callback: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        let observer = Unmanaged<BatteryPowerSourceObserver>
            .fromOpaque(context)
            .takeUnretainedValue()
        Task { @MainActor in
            observer.handleNotification()
        }
    }
}
