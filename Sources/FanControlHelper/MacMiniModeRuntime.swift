@preconcurrency import Darwin
import FanControlShared
import Foundation
import IOKit
import IOKit.ps

/// All policy and process calls run on the helper's serial command queue.
final class MacMiniModeRuntime: @unchecked Sendable {
    private let queue: DispatchQueue
    private var lifecycle: MacMiniModeLifecycle
    private typealias BootstrapValue = (store: MacMiniPolicyStore?, load: MacMiniPolicyLoad, bindingWasKnown: Bool)
    private let bootstrap: MacMiniDeferredBootstrap<BootstrapValue>
    private let installation: MacMiniInstallationContext
    private let sharedLock: MacMiniPolicyLock?
    private let execute: (MacMiniPMSetCommand) -> Bool
    private var timer: DispatchSourceTimer?
    private var powerSource: CFRunLoopSource?
    private var bundleWatcher: DispatchSourceFileSystemObject?
    private let applicationURL: URL?
    var didBecomeIdle: (@Sendable () -> Void)?

    var requiresResidentHelper: Bool { bootstrap.isPending || lifecycle.requiresResidentHelper }

    init(queue: DispatchQueue, execute: @escaping (MacMiniPMSetCommand) -> Bool) {
        self.queue = queue
        self.execute = execute
        // Bundle supplies the actual running executable, never argv or XPC.
        let applicationURL = MacMiniApplicationIdentity.applicationURL(executableURL: Bundle.main.executableURL)
        self.applicationURL = applicationURL
        let installation = MacMiniInstallationContext(applicationURL: applicationURL)
        self.installation = installation
        let lock: MacMiniPolicyLock?
        do {
            lock = try MacMiniPolicyLock(
                directoryURL: URL(fileURLWithPath: "/private/var/db/StorageCleanerMac-MacMiniMode-Lock"), trustedOwner: 0
            )
        } catch {
            lock = nil
            NSLog("Mac mini mode shared lock unavailable: \(error). Check /private/var/db/StorageCleanerMac-MacMiniMode-Lock (root 0700) and owner.lock (root, regular single-link 0600); repair and reload helper. Only proven recovery 0 is allowed.")
        }
        self.sharedLock = lock
        let bootstrap = MacMiniDeferredBootstrap<BootstrapValue>(
            acquire: { lock?.acquire() ?? true }, release: { lock?.release() }, load: {
                guard lock != nil else {
                    return (nil, MacMiniPolicyStore.readRecoveryWithoutLock(
                        directoryURL: Self.policyDirectory(beta: StorageCleanerBuildIdentity.isBeta), trustedOwner: 0
                    ), true)
                }
                let identity = installation.expectedIdentity
                let loaded = MacMiniPolicyStore.openOrDegrade(
                    directoryURL: Self.policyDirectory(beta: StorageCleanerBuildIdentity.isBeta),
                    application: identity, trustedOwner: 0
                )
                return (loaded.store, loaded.load, identity != nil)
            }
        )
        self.bootstrap = bootstrap
        let initial = bootstrap.retry() ?? (store: nil, load: .init(reason: "shared lock busy; bootstrap deferred"), bindingWasKnown: false)
        lifecycle = Self.makeLifecycle(initial, installation: installation, lock: lock, execute: execute)
        if let reason = initial.load.reason { NSLog("Mac mini mode remains unconfirmed: \(reason)") }
    }

    private static func makeLifecycle(_ loaded: BootstrapValue, installation: MacMiniInstallationContext,
                                      lock: MacMiniPolicyLock?, execute: @escaping (MacMiniPMSetCommand) -> Bool) -> MacMiniModeLifecycle {
        let engine = MacMiniModeEngine(state: loaded.load.state, read: Self.readSystem, execute: execute,
            persist: { state in
                guard let store = loaded.store else { throw MacMiniModeFailure.persistenceFailed }
                try store.save(state)
            }, persistenceUnavailable: loaded.load.persistenceUnavailable)
        return MacMiniModeLifecycle(engine: engine, installationIsValid: { installation.isValid() },
            otherIdentityIsHolding: {
                try MacMiniPolicyStore.isHolding(
                    directoryURL: Self.policyDirectory(beta: !StorageCleanerBuildIdentity.isBeta), trustedOwner: 0,
                    validateApplication: { installation.validatePeer($0) }
                )
            }, hardwareIsSupported: Self.hardwareIsSupported,
               acquire: { lock?.acquire() == true }, release: { lock?.release() })
    }

    private func retryBootstrap() {
        let rebind = bootstrap.value?.bindingWasKnown == false && installation.expectedIdentity != nil
        guard bootstrap.isPending || rebind,
              let loaded = bootstrap.retry(reloadWhen: { _ in rebind }) else { return }
        lifecycle = Self.makeLifecycle(loaded, installation: installation, lock: sharedLock, execute: execute)
    }

    private static func policyDirectory(beta: Bool) -> URL {
        URL(fileURLWithPath: "/private/var/db/\(beta ? "StorageCleanerMac-Beta" : "StorageCleanerMac")-MacMiniMode")
    }

    func start() { reconcile() }
    func status() -> MacMiniModeStatus { lifecycle.engine.status() }

    func setMode(_ mode: MacMiniMode) -> MacMiniModeStatus {
        retryBootstrap()
        let status = lifecycle.setMode(mode)
        updateMonitoring()
        return status
    }

    /// Fault-mode removal never starts monitoring or requests immediate sleep.
    func disableForRemoval() -> MacMiniModeStatus {
        retryBootstrap()
        return lifecycle.disableForRemoval()
    }

    func prepareForTermination() -> Bool {
        retryBootstrap()
        timer?.cancel()
        timer = nil
        removePowerSource()
        bundleWatcher?.cancel()
        bundleWatcher = nil
        let status = lifecycle.prepareForTermination()
        return !bootstrap.isPending && !status.ownsSleepDisabled
    }

    private func updateMonitoring() {
        guard requiresResidentHelper else {
            timer?.cancel()
            timer = nil
            removePowerSource()
            bundleWatcher?.cancel()
            bundleWatcher = nil
            didBecomeIdle?()
            return
        }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            if bootstrap.isPending {
                timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            } else {
                timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(2))
            }
            timer.setEventHandler { [weak self] in self?.reconcile() }
            timer.resume()
            self.timer = timer
        }
        if powerSource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let runtime = Unmanaged<MacMiniModeRuntime>.fromOpaque(context).takeUnretainedValue()
                runtime.queue.async { [weak runtime] in runtime?.reconcile() }
            }, context)?.takeRetainedValue() {
                powerSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            }
        }
        if bundleWatcher == nil, let applicationURL {
            let descriptor = open(applicationURL.path, O_EVTONLY | O_NOFOLLOW)
            if descriptor >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: [.delete, .rename, .revoke], queue: queue
                )
                watcher.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.installation.invalidate()
                    self.bundleWatcher?.cancel()
                    self.bundleWatcher = nil
                    // Atomic updater replacement may change the watched inode.
                    // Recheck the path and signing identity after that replacement.
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reconcile() }
                }
                watcher.setCancelHandler { close(descriptor) }
                watcher.resume()
                bundleWatcher = watcher
            }
        }
    }

    private func removePowerSource() {
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
    }

    private func reconcile() {
        let wasPending = bootstrap.isPending
        retryBootstrap()
        if wasPending && !bootstrap.isPending { timer?.cancel(); timer = nil }
        let status = bootstrap.isPending ? lifecycle.engine.reportFailure(.persistenceFailed) : lifecycle.reconcile()
        updateMonitoring()
        if status.failure != nil { NSLog("Mac mini mode reconciliation remains unconfirmed: \(String(describing: status.failure))") }
    }

    private static func hardwareIsSupported() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef], !sources.isEmpty else { return nil }
        let hasBattery = sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        return MacMiniModeAvailability.shouldOffer(hasInternalBattery: hasBattery,
                                                   hasClamshell: readSystem().clamshellClosed != nil)
    }

    private static func readSystem() -> MacMiniSystemReadings {
        let power: MacMiniPowerSource
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            switch type as String {
            case kIOPMACPowerKey: power = .ac
            case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: power = .battery
            default: power = .unknown
            }
        } else {
            power = .unknown
        }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else {
            return MacMiniSystemReadings(
                powerSource: power, sleepDisabled: nil,
                clamshellClosed: nil, clamshellCausesSleep: nil
            )
        }
        defer { IOObjectRelease(root) }
        func boolean(_ key: String) -> Bool? {
            guard let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() else { return nil }
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as? NSNumber)?.boolValue }
            if let number = value as? NSNumber, [0.0, 1.0].contains(number.doubleValue) { return number.boolValue }
            return nil
        }
        return MacMiniSystemReadings(
            powerSource: power, sleepDisabled: boolean("SleepDisabled"),
            clamshellClosed: boolean("AppleClamshellState"),
            clamshellCausesSleep: boolean("AppleClamshellCausesSleep")
        )
    }
}

/// Runtime-only evidence; neither XPC nor archive claims can replace own signing.
private final class MacMiniInstallationContext {
    private let applicationURL: URL?
    private var expected: MacMiniApplicationIdentity?
    private let validation = MacMiniApplicationValidation(
        metadata: MacMiniApplicationValidation.readMetadata,
        verify: CodeSigningCheck.validateMacMiniApplication
    )

    init(applicationURL: URL?) {
        self.applicationURL = applicationURL
        expected = applicationURL.flatMap { try? CodeSigningCheck.macMiniExpectedIdentity(at: $0) }
    }

    var expectedIdentity: MacMiniApplicationIdentity? {
        if expected == nil, let applicationURL {
            expected = try? CodeSigningCheck.macMiniExpectedIdentity(at: applicationURL)
        }
        return expected
    }

    func isValid() -> Bool? {
        guard applicationURL != nil else { return false }
        guard let identity = expectedIdentity else { return nil }
        return validation.validate(identity, identifier: StorageCleanerBuildIdentity.appBundleIdentifier)
    }

    func validatePeer(_ record: MacMiniApplicationIdentity) -> Bool? {
        // The peer's root-protected record carries ITS helper-derived identity.
        // Do not confuse a valid older signing identity with our current team.
        let peerID = StorageCleanerBuildIdentity.isBeta ? "com.local.StorageCleanerMac" : "com.local.StorageCleanerMac.beta"
        return validation.validate(record, identifier: peerID)
    }

    func invalidate() { validation.invalidate() }
}
