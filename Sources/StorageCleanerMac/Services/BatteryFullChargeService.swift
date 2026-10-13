import Darwin
import Foundation
import ObjectiveC.runtime

enum BatteryFullChargeResult: Equatable, Sendable {
    case accepted
    case noActiveLimit
    case alreadyCharging
    case alreadyFull
    case requiresACPower
    case unsupported
    case rejected
    case optimizedChargingRejectedAfterManualLift(effectiveLimit: Int?)
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

enum BatteryChargeLimitSource: Equatable, Sendable {
    case optimized
    case manual
    case manualAndOptimized
    case none
    case unknown
}

/// D59：仅采用主会话实测的数值语义，其余状态一律未知。
enum BatterySmartChargingState: Equatable, Sendable {
    case enabled
    case temporarilyDisabled
    case unknown

    init(rawValue: UInt64?) {
        switch rawValue {
        case 1: self = .enabled
        case 3: self = .temporarilyDisabled
        default: self = .unknown
        }
    }
}

struct BatteryChargeLimitState: Equatable, Sendable {
    let target: BatteryChargeTarget
    let availableTargets: [BatteryChargeTarget]
    let effectiveLimit: Int?
    let source: BatteryChargeLimitSource
    let smartChargingTemporarilyDisabled: Bool
    let manualLimitTemporarilyDisabled: Bool
    let smartChargingState: BatterySmartChargingState

    init(
        target: BatteryChargeTarget,
        availableTargets: [BatteryChargeTarget],
        effectiveLimit: Int? = nil,
        source: BatteryChargeLimitSource = .unknown,
        smartChargingTemporarilyDisabled: Bool = false,
        manualLimitTemporarilyDisabled: Bool = false,
        smartChargingState: BatterySmartChargingState = .unknown
    ) {
        self.target = target
        self.availableTargets = availableTargets
        self.effectiveLimit = effectiveLimit
        self.source = source
        self.smartChargingTemporarilyDisabled = smartChargingTemporarilyDisabled
        self.manualLimitTemporarilyDisabled = manualLimitTemporarilyDisabled
        self.smartChargingState = smartChargingTemporarilyDisabled ? .temporarilyDisabled : smartChargingState
    }

    static func resolveSource(
        manualLimitEnabled: Bool?,
        manualLimit: Int? = nil,
        effectiveLimit: Int?,
        smartChargingState: BatterySmartChargingState,
        maxLimited: Bool?
    ) -> BatteryChargeLimitSource {
        if effectiveLimit == 100, maxLimited == true { return .unknown }
        guard let manualLimitEnabled else { return .unknown }
        if manualLimitEnabled {
            guard let manualLimit else { return .unknown }
            if let effectiveLimit, effectiveLimit < manualLimit, smartChargingState == .enabled {
                return .manualAndOptimized
            }
            if effectiveLimit == manualLimit || (effectiveLimit == 100 && manualLimit < 100) {
                return .manual
            }
            // 仅缺少实际值时仍保留已知手动来源，不能推测限值。
            return effectiveLimit == nil ? .manual : .unknown
        }
        if maxLimited == true || (smartChargingState == .enabled && effectiveLimit.map { $0 < 100 } == true) {
            return .optimized
        }
        if effectiveLimit == 100, maxLimited != true { return .none }
        if effectiveLimit == nil, maxLimited == false { return .none }
        return .unknown
    }

    static func resolve(
        manualLimitEnabled: Bool?,
        manualLimit: Int?,
        availableLimits: [Int],
        effectiveLimit: Int? = nil,
        smartChargingRawValue: UInt64? = nil,
        maxLimited: Bool? = nil
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

        let effectiveLimit = effectiveLimit.flatMap { (1...100).contains($0) ? $0 : nil }
        let smartChargingState = BatterySmartChargingState(rawValue: smartChargingRawValue)
        var targets = Set(nativeTargets)
        targets.insert(target)
        targets.insert(.full)
        return BatteryChargeLimitState(
            target: target,
            availableTargets: targets.sorted(),
            effectiveLimit: effectiveLimit,
            source: resolveSource(
                manualLimitEnabled: manualLimitEnabled,
                manualLimit: manualLimit,
                effectiveLimit: effectiveLimit,
                smartChargingState: smartChargingState,
                maxLimited: maxLimited
            ),
            smartChargingTemporarilyDisabled: smartChargingState == .temporarilyDisabled,
            manualLimitTemporarilyDisabled: manualLimitEnabled && target != .full
                && effectiveLimit == 100 && maxLimited != true,
            smartChargingState: smartChargingState
        )
    }
}

struct BatteryChargingEngagement: Equatable, Sendable {
    let obcEngaged: Bool
    let maxLimited: Bool
    let chargingOverrideAllowed: Bool
}

enum BatteryFullChargeOperation: CaseIterable, Hashable, Sendable {
    case temporarilyDisableSmartCharging
    case temporarilyDisableManualLimit
    case temporarilyEnableCharging

    fileprivate var selectorName: String {
        switch self {
        case .temporarilyDisableSmartCharging: "temporarilyDisableSmartCharging:"
        case .temporarilyDisableManualLimit: "temporarilyDisableMCL:"
        case .temporarilyEnableCharging: "temporarilyEnableCharging:"
        }
    }
}

/// 只读快照不改变充电设置；私有接口缺失或报错时保留 nil。
struct BatterySmartChargeReading: Equatable, Sendable {
    var supportsManualChargeLimit = false
    var manualLimitEnabled: Bool?
    var manualLimit: Int?
    var availableLimits: [Int] = []
    var effectiveLimit: Int?
    var smartChargingRawValue: UInt64?
    var engagement: BatteryChargingEngagement?

    var source: BatteryChargeLimitSource {
        BatteryChargeLimitState.resolveSource(
            manualLimitEnabled: manualLimitEnabled,
            manualLimit: manualLimit,
            effectiveLimit: effectiveLimit,
            smartChargingState: BatterySmartChargingState(rawValue: smartChargingRawValue),
            maxLimited: engagement?.maxLimited
        )
    }

    var chargeLimitState: BatteryChargeLimitState? {
        // 不支持手动上限的机型仍可显示已读到的系统优化上限，选择器没有可选项。
        if !supportsManualChargeLimit {
            guard effectiveLimit != nil || engagement != nil else { return nil }
            let smart = BatterySmartChargingState(rawValue: smartChargingRawValue)
            return BatteryChargeLimitState(
                target: .full, availableTargets: [], effectiveLimit: effectiveLimit,
                source: BatteryChargeLimitState.resolveSource(
                    manualLimitEnabled: false, effectiveLimit: effectiveLimit,
                    smartChargingState: smart, maxLimited: engagement?.maxLimited
                ), smartChargingTemporarilyDisabled: smart == .temporarilyDisabled,
                smartChargingState: smart
            )
        }
        return BatteryChargeLimitState.resolve(
            manualLimitEnabled: manualLimitEnabled,
            manualLimit: manualLimit,
            availableLimits: availableLimits,
            effectiveLimit: effectiveLimit,
            smartChargingRawValue: smartChargingRawValue,
            maxLimited: engagement?.maxLimited
        )
    }

    var fullChargeOperation: BatteryFullChargeOperation? {
        switch source {
        case .optimized: return .temporarilyDisableSmartCharging
        case .manual, .manualAndOptimized: return .temporarilyDisableManualLimit
        case .none, .unknown:
            if engagement?.obcEngaged == true,
               engagement?.chargingOverrideAllowed == true {
                return .temporarilyEnableCharging
            }
            return nil
        }
    }

    var hasContradictoryLimit: Bool { effectiveLimit == 100 && engagement?.maxLimited == true }
    var hasActiveLimit: Bool { effectiveLimit.map { $0 < 100 } == true || engagement?.maxLimited == true }
    var confirmsFullCharge: Bool {
        if let effectiveLimit, let limited = engagement?.maxLimited {
            return effectiveLimit == 100 && !limited
        }
        if let effectiveLimit { return effectiveLimit == 100 }
        return engagement?.maxLimited == false
    }

    func confirmsTransition(from before: Self, operation: BatteryFullChargeOperation) -> Bool {
        guard !hasContradictoryLimit else { return false }
        if operation == .temporarilyEnableCharging {
            guard let previous = before.engagement, let current = engagement else { return false }
            return (previous.obcEngaged && !current.obcEngaged)
                || (previous.chargingOverrideAllowed && !current.chargingOverrideAllowed)
        }
        return before.hasActiveLimit && confirmsFullCharge
    }
}

/// 生产客户端和测试假实现都在主线程。测试显式传入客户端，
/// 不替换或初始化生产单例。
@MainActor
protocol BatterySmartChargeClient: AnyObject {
    func read() -> BatterySmartChargeReading
    func supportsFullCharge(_ operation: BatteryFullChargeOperation) -> Bool
    func requestFullCharge(_ operation: BatteryFullChargeOperation) -> Bool
    func setChargeTarget(_ target: BatteryChargeTarget) -> Bool
    func matchesChargeTarget(_ target: BatteryChargeTarget) -> Bool
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
    private static var cachedClient: PowerUISmartChargeClient?
    private static var smartChargeClient: PowerUISmartChargeClient? {
        guard BatteryChargeLimitAccess.allowsLiveAccess,
              BatteryPowerService.internalBatteryAvailability() == .present else { return nil }
        if cachedClient == nil { cachedClient = PowerUISmartChargeClient.make() }
        return cachedClient
    }

    static func currentChargeLimitState() -> BatteryChargeLimitState? {
        currentChargeLimitState(using: smartChargeClient)
    }

    static func currentChargeLimitState(
        using client: (any BatterySmartChargeClient)?
    ) -> BatteryChargeLimitState? {
        client?.read().chargeLimitState
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
        guard BatteryChargeLimitAccess.allowsLiveAccess else { return .unsupported }
        let snapshot = BatteryPowerService.internalBatterySnapshot()
        if let result = preflightResult(for: snapshot) { return result }
        return await requestToFull(
            using: smartChargeClient,
            snapshot: snapshot
        )
    }

    static func requestToFull(
        using client: (any BatterySmartChargeClient)?,
        snapshot: BatteryPowerSnapshot?,
        wait: @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        }
    ) async -> BatteryFullChargeResult {
        if let result = preflightResult(for: snapshot) { return result }
        guard let client else { return .unsupported }
        let before = client.read()
        guard !before.hasContradictoryLimit else { return .unsupported }
        // 旧式挂起虽然没有上限，仍须验证挂起或覆盖许可的真实转变。
        let legacyPause = before.fullChargeOperation == .temporarilyEnableCharging
        if before.confirmsFullCharge && !legacyPause { return .noActiveLimit }
        guard (legacyPause || before.hasActiveLimit),
              let operation = before.fullChargeOperation,
              client.supportsFullCharge(operation) else {
            return .unsupported
        }
        guard client.requestFullCharge(operation) else { return .rejected }
        let first: (accepted: Bool, cancelled: Bool, reading: BatterySmartChargeReading)
        if before.source == .manualAndOptimized {
            // 两条限制并存时，解除手动并不会解除优化上限；立即回读一次再决定第二步。
            let reading = client.read()
            first = (reading.confirmsTransition(from: before, operation: operation), false, reading)
        } else {
            first = await verifyTransition(using: client, before: before, operation: operation, wait: wait)
        }
        if first.accepted { return .accepted }
        guard !first.cancelled else { return .verificationFailed }
        // 只在回读仍有限制且智能充电为 1 时继续；第二步仍须验证真实状态转变。
        guard operation == .temporarilyDisableManualLimit,
              first.reading.hasActiveLimit, !first.reading.hasContradictoryLimit,
              first.reading.smartChargingRawValue == 1 else { return .verificationFailed }
        let secondOperation = BatteryFullChargeOperation.temporarilyDisableSmartCharging
        guard client.supportsFullCharge(secondOperation) else { return .unsupported }
        guard client.requestFullCharge(secondOperation) else {
            // 第一项请求已接受，不能把第二项拒绝说成整次操作未发生；实际上限重新回读。
            return .optimizedChargingRejectedAfterManualLift(effectiveLimit: client.read().effectiveLimit)
        }
        let second = await verifyTransition(
            using: client, before: first.reading, operation: secondOperation, wait: wait
        )
        return second.accepted ? .accepted : .verificationFailed
    }

    private static func verifyTransition(
        using client: any BatterySmartChargeClient,
        before: BatterySmartChargeReading,
        operation: BatteryFullChargeOperation,
        wait: @MainActor () async throws -> Void
    ) async -> (accepted: Bool, cancelled: Bool, reading: BatterySmartChargeReading) {
        var latest = before
        for attempt in 0...30 {
            if attempt > 0 {
                do { try await wait() } catch { return (false, true, latest) }
            }
            latest = client.read()
            if latest.confirmsTransition(from: before, operation: operation) { return (true, false, latest) }
        }
        return (false, false, latest)
    }

    static func setPreferredTarget(
        _ target: BatteryChargeTarget
    ) async -> BatteryChargeTargetUpdateResult {
        await setPreferredTarget(target, using: smartChargeClient, defaults: .standard)
    }

    static func setPreferredTarget(
        _ target: BatteryChargeTarget,
        using client: (any BatterySmartChargeClient)?,
        defaults: UserDefaults,
        wait: @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(100))
        }
    ) async -> BatteryChargeTargetUpdateResult {
        guard let client else { return .unsupported }
        let before = client.read()
        guard before.supportsManualChargeLimit,
              before.chargeLimitState?.availableTargets.contains(target) == true else {
            return .unsupported
        }
        guard client.setChargeTarget(target) else { return .rejected }

        for attempt in 0..<10 {
            if attempt > 0 {
                do { try await wait() } catch { return .verificationFailed }
            }
            guard client.matchesChargeTarget(target) else { continue }
            target.save(in: defaults)
            return .applied
        }
        return .verificationFailed
    }

    /// D5：后台采样只同步手动偏好，不启用充电，
    /// 不改变手动上限或优化充电设置。
    static func reconcileSystemTarget() -> BatteryChargeLimitState? {
        reconcileSystemTarget(using: smartChargeClient, defaults: .standard)
    }

    static func reconcileSystemTarget(
        using client: (any BatterySmartChargeClient)?,
        defaults: UserDefaults
    ) -> BatteryChargeLimitState? {
        guard let state = currentChargeLimitState(using: client) else { return nil }
        if BatteryChargeTarget.stored(in: defaults) != state.target {
            state.target.save(in: defaults)
        }
        return state
    }
}

@MainActor
private final class PowerUISmartChargeClient: BatterySmartChargeClient {

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

    private func chargingEngagement() -> BatteryChargingEngagement? {
        BatteryChargeLimitObjCCalls.engagement(on: object)
    }

    func read() -> BatterySmartChargeReading {
        // currentChargeLimit: 与 isSmartChargingCurrentlyEnabled: 均为
        // Q24@0:8^@16；沿用 UInt64 + 错误指针的读取方式。
        let supportsManual = supportsManualChargeLimit
        let effectiveLimit = unsignedValue(for: "currentChargeLimit:").flatMap {
            (1...100).contains($0) ? Int($0) : nil
        }
        return BatterySmartChargeReading(
            supportsManualChargeLimit: supportsManual,
            manualLimitEnabled: supportsManual ? isManualChargeLimitEnabled : false,
            manualLimit: supportsManual ? manualChargeLimit.map(Int.init) : nil,
            availableLimits: supportsManual ? availableChargeTargets.map(\.rawValue) : [],
            effectiveLimit: effectiveLimit,
            smartChargingRawValue: unsignedValue(for: "isSmartChargingCurrentlyEnabled:"),
            engagement: chargingEngagement()
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
        BatteryChargeLimitObjCCalls.decodeManualEnabled(unsignedValue(for: "isMCLCurrentlyEnabled:"))
    }

    var manualChargeLimit: UInt8? {
        BatteryChargeLimitObjCCalls.byteValue(on: object, selectorName: "getMCLLimitWithError:")
    }

    var availableChargeTargets: [BatteryChargeTarget] {
        let values = BatteryChargeLimitObjCCalls.limits(on: object, selectorName: "availableChargeLimitsWithError:") ?? []
        return Set(values.compactMap(BatteryChargeTarget.init(rawValue:))).sorted()
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
        BatteryChargeLimitObjCCalls.setByte(on: object, selectorName: "setMCLLimit:error:", value: limit)
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

    func supportsFullCharge(_ operation: BatteryFullChargeOperation) -> Bool {
        class_getInstanceMethod(
            runtimeClass, NSSelectorFromString(operation.selectorName)
        ) != nil
    }

    func requestFullCharge(_ operation: BatteryFullChargeOperation) -> Bool {
        // temporarilyDisableSmartCharging: 实测为 B24@0:8^@16，
        // 与既有临时操作共用 Bool 返回值和错误指针的调用方式。
        invoke(operation.selectorName)
    }

    private func unsignedValue(for selectorName: String) -> UInt64? {
        BatteryChargeLimitObjCCalls.unsignedValue(on: object, selectorName: selectorName)
    }

    private func invoke(_ selectorName: String) -> Bool {
        BatteryChargeLimitObjCCalls.invoke(on: object, selectorName: selectorName)
    }
}

/// 生产与替身测试共用的 Objective-C 调用边界。NSError ** 接收 +0 对象，
/// 必须用 autoreleasing 指针，不能把它当普通 Swift 强引用指针。
@MainActor
enum BatteryChargeLimitObjCCalls {
    private static func method(on object: AnyObject, selector: Selector) -> Method? {
        guard let cls = object_getClass(object) else { return nil }
        return class_getInstanceMethod(cls, selector)
    }

    nonisolated static func decodeManualEnabled(_ rawValue: UInt64?) -> Bool? {
        switch rawValue {
        case 0: false
        case 1: true
        default: nil
        }
    }

    static func unsignedValue(on object: AnyObject, selectorName: String) -> UInt64? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = method(on: object, selector: selector) else { return nil }
        typealias ReadValue = @convention(c) (
            AnyObject, Selector, AutoreleasingUnsafeMutablePointer<AnyObject?>
        ) -> UInt64
        let call = unsafeBitCast(method_getImplementation(method), to: ReadValue.self)
        var error: AnyObject?
        let value = call(object, selector, &error)
        return error == nil ? value : nil
    }

    static func byteValue(on object: AnyObject, selectorName: String) -> UInt8? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = method(on: object, selector: selector) else { return nil }
        typealias ReadLimit = @convention(c) (
            AnyObject, Selector, AutoreleasingUnsafeMutablePointer<AnyObject?>
        ) -> UInt8
        let call = unsafeBitCast(method_getImplementation(method), to: ReadLimit.self)
        var error: AnyObject?
        let value = call(object, selector, &error)
        return error == nil ? value : nil
    }

    static func limits(on object: AnyObject, selectorName: String) -> [Int]? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = method(on: object, selector: selector) else { return nil }
        typealias ReadLimits = @convention(c) (
            AnyObject, Selector, AutoreleasingUnsafeMutablePointer<AnyObject?>
        ) -> AnyObject?
        let call = unsafeBitCast(method_getImplementation(method), to: ReadLimits.self)
        var error: AnyObject?
        let result = call(object, selector, &error)
        guard error == nil, let values = result as? [NSNumber] else { return nil }
        return values.map(\.intValue)
    }

    static func setByte(on object: AnyObject, selectorName: String, value: UInt8) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard let method = method(on: object, selector: selector) else { return false }
        typealias SetLimit = @convention(c) (
            AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<AnyObject?>
        ) -> Bool
        let call = unsafeBitCast(method_getImplementation(method), to: SetLimit.self)
        var error: AnyObject?
        return call(object, selector, value, &error) && error == nil
    }

    static func invoke(on object: AnyObject, selectorName: String) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard let method = method(on: object, selector: selector) else { return false }
        typealias Invoke = @convention(c) (
            AnyObject, Selector, AutoreleasingUnsafeMutablePointer<AnyObject?>
        ) -> Bool
        let call = unsafeBitCast(method_getImplementation(method), to: Invoke.self)
        var error: AnyObject?
        return call(object, selector, &error) && error == nil
    }

    static func engagement(
        on object: AnyObject,
        selectorName: String = "isOBCEngaged:isMaxChargeLimited:chargingOverrideAllowed:withError:"
    ) -> BatteryChargingEngagement? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = method(on: object, selector: selector) else { return nil }
        // 本机类型编码 B48@0:8^B16^B24^B32^@40；只有 error 是 autoreleasing。
        typealias ReadStatus = @convention(c) (
            AnyObject, Selector, UnsafeMutablePointer<ObjCBool>,
            UnsafeMutablePointer<ObjCBool>, UnsafeMutablePointer<ObjCBool>,
            AutoreleasingUnsafeMutablePointer<AnyObject?>
        ) -> Bool
        let call = unsafeBitCast(method_getImplementation(method), to: ReadStatus.self)
        var engaged = ObjCBool(false), limited = ObjCBool(false), allowed = ObjCBool(false)
        var error: AnyObject?
        guard call(object, selector, &engaged, &limited, &allowed, &error), error == nil else { return nil }
        return BatteryChargingEngagement(
            obcEngaged: engaged.boolValue, maxLimited: limited.boolValue,
            chargingOverrideAllowed: allowed.boolValue
        )
    }
}
