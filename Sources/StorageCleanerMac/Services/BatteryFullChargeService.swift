import Darwin
import Foundation
import ObjectiveC.runtime

enum BatteryFullChargeResult: Equatable, Sendable {
    case accepted
    case alreadyCharging
    case alreadyFull
    case requiresACPower
    case unsupported
    case rejected
    case verificationFailed
}

struct BatteryChargeTarget: RawRepresentable, Hashable, Identifiable, Comparable, Sendable {
    static let protected = BatteryChargeTarget(rawValue: 80)!
    static let full = BatteryChargeTarget(rawValue: 100)!
    static let defaultsKey = "battery.chargeTargetPercent"

    let rawValue: Int

    init?(rawValue: Int) {
        guard (70...100).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    var id: Int { rawValue }
    var manualLimitPercent: UInt8? {
        self == .full ? nil : UInt8(rawValue)
    }

    var displayText: String { "\(rawValue)%" }

    static func stored(in defaults: UserDefaults = .standard) -> BatteryChargeTarget {
        guard let rawValue = defaults.object(forKey: defaultsKey) as? Int else {
            return .protected
        }
        return BatteryChargeTarget(rawValue: rawValue) ?? .protected
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    static func < (lhs: BatteryChargeTarget, rhs: BatteryChargeTarget) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct BatteryChargeLimitState: Equatable, Sendable {
    let target: BatteryChargeTarget
    let availableTargets: [BatteryChargeTarget]

    static func resolve(
        manualLimitEnabled: Bool?,
        manualLimit: Int?,
        availableLimits: [Int]
    ) -> BatteryChargeLimitState? {
        guard let manualLimitEnabled else { return nil }
        let nativeTargets = availableLimits.compactMap(BatteryChargeTarget.init(rawValue:))
        guard !nativeTargets.isEmpty else { return nil }

        let target: BatteryChargeTarget
        if manualLimitEnabled {
            guard let manualLimit,
                  let resolved = BatteryChargeTarget(rawValue: manualLimit) else {
                return nil
            }
            target = resolved
        } else {
            target = .full
        }

        var targets = Set(nativeTargets)
        targets.insert(target)
        targets.insert(.full)
        return BatteryChargeLimitState(
            target: target,
            availableTargets: targets.sorted()
        )
    }
}

enum BatteryChargeTargetUpdateResult: Equatable, Sendable {
    case applied
    case unsupported
    case rejected
    case verificationFailed
}

/// Uses the same fixed smart-charging operation as macOS Control Center.
/// The private SPI is loaded dynamically so unsupported systems fail closed.
@MainActor
enum BatteryFullChargeService {
    private static let smartChargeClient = PowerUISmartChargeClient.make()
    private static var requestedFullForCurrentPause = false

    static func currentChargeLimitState() -> BatteryChargeLimitState? {
        guard let client = smartChargeClient,
              client.supportsManualChargeLimit else { return nil }
        return client.chargeLimitState
    }

    nonisolated static func preflightResult(
        for snapshot: BatteryPowerSnapshot?
    ) -> BatteryFullChargeResult? {
        guard let snapshot else { return .unsupported }
        guard snapshot.powerSource == .acPower else { return .requiresACPower }
        if snapshot.isFullyCharged == true || snapshot.chargePercent == 100 {
            return .alreadyFull
        }
        if snapshot.isCharging == true {
            return .alreadyCharging
        }
        guard snapshot.chargePercent != nil else { return .unsupported }
        return nil
    }

    static func requestToFull() async -> BatteryFullChargeResult {
        if let result = preflightResult(for: BatteryPowerService.internalBatterySnapshot()) {
            return result
        }
        guard let client = smartChargeClient,
              let before = client.status(),
              before.chargingOverrideAllowed else {
            return .unsupported
        }
        guard client.requestFullCharge(
            manualLimitEnabled: before.manualLimitEnabled
        ) else {
            return .rejected
        }

        // PowerUI publishes its accepted target before the charger hardware
        // starts drawing current, which can take several seconds.
        for attempt in 0..<10 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let after = client.status() else { continue }
            if !after.chargingOverrideAllowed {
                return .accepted
            }
        }
        return .verificationFailed
    }

    static func setPreferredTarget(
        _ target: BatteryChargeTarget
    ) async -> BatteryChargeTargetUpdateResult {
        guard let client = smartChargeClient,
              client.supportsManualChargeLimit else {
            return .unsupported
        }
        guard client.availableChargeTargets.contains(target) else {
            return .unsupported
        }
        guard client.setChargeTarget(target) else {
            return .rejected
        }

        for attempt in 0..<10 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard client.matchesChargeTarget(target) else { continue }
            target.save()
            if target != .full {
                requestedFullForCurrentPause = false
            }
            return .applied
        }
        return .verificationFailed
    }

    /// Reuses the existing battery sampling path; this adds no timer or poller.
    static func reconcileSystemTarget(
        for snapshot: BatteryPowerSnapshot?
    ) -> BatteryChargeLimitState? {
        guard let state = currentChargeLimitState() else { return nil }
        if BatteryChargeTarget.stored() != state.target {
            state.target.save()
        }

        guard state.target == .full,
              snapshot?.shouldOfferFullChargeAction == true else {
            if state.target != .full || snapshot?.shouldOfferFullChargeAction != true {
                requestedFullForCurrentPause = false
            }
            return state
        }
        guard !requestedFullForCurrentPause else { return state }
        requestedFullForCurrentPause = true
        Task { _ = await requestToFull() }
        return state
    }
}

@MainActor
private final class PowerUISmartChargeClient {
    fileprivate struct Status {
        let chargingOverrideAllowed: Bool
        let manualLimitEnabled: Bool
    }

    private static let runtimeLoaded: Bool = {
        dlopen(
            "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI",
            RTLD_NOW | RTLD_LOCAL
        ) != nil
    }()

    private let runtimeClass: AnyClass
    private let object: AnyObject

    private init(runtimeClass: AnyClass, object: AnyObject) {
        self.runtimeClass = runtimeClass
        self.object = object
    }

    static func make() -> PowerUISmartChargeClient? {
        guard runtimeLoaded,
              let runtimeClass = NSClassFromString("PowerUISmartChargeClient"),
              let allocated = class_createInstance(runtimeClass, 0) else {
            return nil
        }
        let selector = NSSelectorFromString("initWithClientName:")
        guard let method = class_getInstanceMethod(runtimeClass, selector) else {
            return nil
        }
        typealias Initialize = @convention(c) (
            AnyObject, Selector, NSString
        ) -> AnyObject
        let initialize = unsafeBitCast(
            method_getImplementation(method),
            to: Initialize.self
        )
        let object = initialize(
            allocated as AnyObject,
            selector,
            "StorageCleanerMac" as NSString
        )
        return PowerUISmartChargeClient(runtimeClass: runtimeClass, object: object)
    }

    fileprivate func status() -> Status? {
        let selector = NSSelectorFromString(
            "smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:"
        )
        guard let method = class_getInstanceMethod(runtimeClass, selector) else {
            return nil
        }
        typealias ReadStatus = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutablePointer<UInt64>,
            UnsafeMutablePointer<UInt64>,
            UnsafeMutablePointer<ObjCBool>,
            UnsafeMutablePointer<AnyObject?>
        ) -> Bool
        let readStatus = unsafeBitCast(
            method_getImplementation(method),
            to: ReadStatus.self
        )
        var state: UInt64 = 0
        var limit: UInt64 = 0
        var overrideAllowed = ObjCBool(false)
        var error: AnyObject?
        guard readStatus(
            object,
            selector,
            &state,
            &limit,
            &overrideAllowed,
            &error
        ), error == nil else {
            return nil
        }
        guard let enabled = unsignedValue(for: "isMCLCurrentlyEnabled:") else {
            return nil
        }
        return Status(
            chargingOverrideAllowed: overrideAllowed.boolValue,
            manualLimitEnabled: enabled != 0
        )
    }

    var supportsManualChargeLimit: Bool {
        let selector = NSSelectorFromString("isMCLSupported")
        guard let method = class_getInstanceMethod(runtimeClass, selector) else {
            return false
        }
        typealias ReadSupport = @convention(c) (AnyObject, Selector) -> Bool
        let readSupport = unsafeBitCast(
            method_getImplementation(method),
            to: ReadSupport.self
        )
        return readSupport(object, selector)
    }

    var isManualChargeLimitEnabled: Bool? {
        unsignedValue(for: "isMCLCurrentlyEnabled:").map { $0 != 0 }
    }

    var manualChargeLimit: UInt8? {
        let selector = NSSelectorFromString("getMCLLimitWithError:")
        guard let method = class_getInstanceMethod(runtimeClass, selector) else {
            return nil
        }
        typealias ReadLimit = @convention(c) (
            AnyObject, Selector, UnsafeMutablePointer<AnyObject?>
        ) -> UInt8
        let readLimit = unsafeBitCast(
            method_getImplementation(method),
            to: ReadLimit.self
        )
        var error: AnyObject?
        let value = readLimit(object, selector, &error)
        return error == nil ? value : nil
    }

    var availableChargeTargets: [BatteryChargeTarget] {
        let selector = NSSelectorFromString("availableChargeLimitsWithError:")
        guard let method = class_getInstanceMethod(runtimeClass, selector) else {
            return []
        }
        typealias ReadLimits = @convention(c) (
            AnyObject, Selector, UnsafeMutablePointer<AnyObject?>
        ) -> AnyObject?
        let readLimits = unsafeBitCast(
            method_getImplementation(method),
            to: ReadLimits.self
        )
        var error: AnyObject?
        guard let values = readLimits(object, selector, &error) as? [NSNumber],
              error == nil else { return [] }
        return Set(values.compactMap {
            BatteryChargeTarget(rawValue: $0.intValue)
        }).sorted()
    }

    var chargeLimitState: BatteryChargeLimitState? {
        BatteryChargeLimitState.resolve(
            manualLimitEnabled: isManualChargeLimitEnabled,
            manualLimit: manualChargeLimit.map(Int.init),
            availableLimits: availableChargeTargets.map(\.rawValue)
        )
    }

    func setChargeTarget(_ target: BatteryChargeTarget) -> Bool {
        guard isManualChargeLimitEnabled != nil else { return false }
        if let limit = target.manualLimitPercent {
            resetEngagementOverride()
            guard setManualChargeLimit(limit) else { return false }
            guard let isManualChargeLimitEnabled else { return false }
            guard isManualChargeLimitEnabled || invoke("enableMCL:") else {
                return false
            }
            resetEngagementOverride()
            return true
        }
        guard let isManualChargeLimitEnabled else { return false }
        return !isManualChargeLimitEnabled || invoke("disableMCL:")
    }

    func matchesChargeTarget(_ target: BatteryChargeTarget) -> Bool {
        guard let isManualChargeLimitEnabled else { return false }
        if let limit = target.manualLimitPercent {
            return isManualChargeLimitEnabled && manualChargeLimit == limit
        }
        return !isManualChargeLimitEnabled
    }

    private func setManualChargeLimit(_ limit: UInt8) -> Bool {
        let selector = NSSelectorFromString("setMCLLimit:error:")
        guard let method = class_getInstanceMethod(runtimeClass, selector) else {
            return false
        }
        typealias SetLimit = @convention(c) (
            AnyObject,
            Selector,
            UInt8,
            UnsafeMutablePointer<AnyObject?>
        ) -> Bool
        let setLimit = unsafeBitCast(
            method_getImplementation(method),
            to: SetLimit.self
        )
        var error: AnyObject?
        guard setLimit(object, selector, limit, &error), error == nil else {
            return false
        }
        return true
    }

    private func resetEngagementOverride() {
        let selector = NSSelectorFromString("resetEngagementOverride")
        guard let method = class_getInstanceMethod(runtimeClass, selector) else { return }
        typealias ResetOverride = @convention(c) (AnyObject, Selector) -> Void
        let resetOverride = unsafeBitCast(
            method_getImplementation(method),
            to: ResetOverride.self
        )
        resetOverride(object, selector)
    }

    func requestFullCharge(manualLimitEnabled: Bool) -> Bool {
        invoke(
            manualLimitEnabled
                ? "temporarilyDisableMCL:"
                : "temporarilyEnableCharging:"
        )
    }

    private func unsignedValue(for selectorName: String) -> UInt64? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(runtimeClass, selector) else {
            return nil
        }
        typealias ReadValue = @convention(c) (
            AnyObject, Selector, UnsafeMutablePointer<AnyObject?>
        ) -> UInt64
        let readValue = unsafeBitCast(
            method_getImplementation(method),
            to: ReadValue.self
        )
        var error: AnyObject?
        let value = readValue(object, selector, &error)
        return error == nil ? value : nil
    }

    private func invoke(_ selectorName: String) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(runtimeClass, selector) else {
            return false
        }
        typealias Invoke = @convention(c) (
            AnyObject, Selector, UnsafeMutablePointer<AnyObject?>
        ) -> Bool
        let invoke = unsafeBitCast(
            method_getImplementation(method),
            to: Invoke.self
        )
        var error: AnyObject?
        return invoke(object, selector, &error) && error == nil
    }
}
