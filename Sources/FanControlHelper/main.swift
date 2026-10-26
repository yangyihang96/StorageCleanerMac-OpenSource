@preconcurrency import Darwin
import FanControlShared
import Foundation
import IOKit
import os
import Security

private enum HelperPerformanceTelemetry {
    static let logger = Logger(
        subsystem: StorageCleanerBuildIdentity.appBundleIdentifier,
        category: "Performance"
    )
    static let signposter = OSSignposter(logger: logger)
}

@objc protocol FanControlHelperProtocol {
    func execute(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    )
}

private enum FanControlHelperProtocolContract {
    static let currentVersion = HardwareControlProtocol.currentVersion
}

private struct FanControlHelperRequest: Codable {
    enum Operation: String, Codable {
        case ping
        case readPowerConfiguration
        case apply
        case renewFanControlLease
        case restoreAutomatic
        case applyPowerMode
        case validateFanCurve
        case activateFanCurve
        case updateFanCurve
        case getFanCurveRuntimeState
        case deactivateFanCurve
        case readMacMiniMode
        case setMacMiniMode
        case samplePowerMetrics
    }

    let protocolVersion: Int?
    let operation: Operation
    let targetRPMByFan: [Int: Int]
    let automaticFanIDs: [Int]
    let allowsRPMDecrease: Bool
    let watchdogSeconds: Double
    let powerModeSource: String?
    let powerModeSetting: String?
    let powerModeValue: Int?
    let curveProfile: FanCurveProfile?
    let curveLeaseID: UUID?
    let macMiniMode: MacMiniMode?
}

private enum FanControlHelperErrorCode: String, Codable {
    case invalidRequest
    case unsupportedHardware
    case pmsetFailed
    case pmsetVerificationFailed
    case smcReadFailed
    case smcWriteFailed
    case fanVerificationFailed
    case fanCrashRecoveryFailed
    case fanLeaseExpired
    case partialFanWriteFailure
    case invalidCurvePointCount
    case invalidCurveTemperature
    case invalidCurvePercentage
    case nonIncreasingTemperatures
    case decreasingFanPercentage
    case missingFullSpeedPoint
    case fullSpeedPointTooHot
    case sensorUnavailable
    case sensorStale
    case fanRangeUnavailable
    case curveActivationFailed
    case curveUpdateFailed
    case curveVerificationFailed
    case curveLeaseExpired
    case thermalProtectionActivated
    case macMiniModeStateUnavailable
    case macMiniModePersistenceFailed
    case macMiniModeCommandFailed
    case macMiniModeVerificationFailed
    case macMiniModeSleepFailed
    case macMiniModeConflict
}

private enum PowerModeSettingKey: String, Codable {
    case powerMode = "powermode"
    case lowPowerMode = "lowpowermode"
}

private enum PowerMode: String, Codable {
    case lowPower
    case automatic
    case highPower
}

private struct PowerConfiguration: Codable {
    let battery: PowerMode?
    let adapter: PowerMode?
    let supportedBatteryModes: [PowerMode]
    let supportedAdapterModes: [PowerMode]
    let batterySetting: PowerModeSettingKey?
    let adapterSetting: PowerModeSettingKey?

    func matches(source: String, setting: String, value: Int) -> Bool {
        let observedMode: PowerMode?
        let observedSetting: PowerModeSettingKey?
        switch source {
        case "-b":
            observedMode = battery
            observedSetting = batterySetting
        case "-c":
            observedMode = adapter
            observedSetting = adapterSetting
        default:
            return false
        }
        guard observedSetting?.rawValue == setting else { return false }
        return observedMode == Self.mode(setting: setting, value: value)
    }

    private static func mode(setting: String, value: Int) -> PowerMode? {
        switch (setting, value) {
        case (PowerModeSettingKey.powerMode.rawValue, 0),
             (PowerModeSettingKey.lowPowerMode.rawValue, 0):
            .automatic
        case (PowerModeSettingKey.powerMode.rawValue, 1),
             (PowerModeSettingKey.lowPowerMode.rawValue, 1):
            .lowPower
        case (PowerModeSettingKey.powerMode.rawValue, 2):
            .highPower
        default:
            nil
        }
    }
}

private struct FanControlHelperReply: Codable {
    let protocolVersion: Int
    let operation: FanControlHelperRequest.Operation?
    let success: Bool
    let message: String
    let appliedTargetRPMByFan: [Int: Int]
    let powerConfiguration: PowerConfiguration?
    let curveRuntimeState: FanCurveRuntimeState?
    let errorCode: FanControlHelperErrorCode?
    let macMiniModeStatus: MacMiniModeStatus?
    let powerSampleResult: PowermetricsResult?
    /// D105 (review C-R1, C-R2): the returns to system control this helper
    /// made on its own, on a ping and on every reply that did not succeed.
    let automaticRestores: [FanControlAutomaticRestore]?

    init(
        protocolVersion: Int = FanControlHelperProtocolContract.currentVersion,
        operation: FanControlHelperRequest.Operation? = nil,
        success: Bool,
        message: String,
        appliedTargetRPMByFan: [Int: Int],
        powerConfiguration: PowerConfiguration? = nil,
        curveRuntimeState: FanCurveRuntimeState? = nil,
        errorCode: FanControlHelperErrorCode? = nil,
        macMiniModeStatus: MacMiniModeStatus? = nil,
        powerSampleResult: PowermetricsResult? = nil,
        automaticRestores: [FanControlAutomaticRestore]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.success = success
        self.message = message
        self.appliedTargetRPMByFan = appliedTargetRPMByFan
        self.powerConfiguration = powerConfiguration
        self.curveRuntimeState = curveRuntimeState
        self.errorCode = errorCode
        self.macMiniModeStatus = macMiniModeStatus
        self.powerSampleResult = powerSampleResult
        self.automaticRestores = automaticRestores
    }

    func echoing(_ operation: FanControlHelperRequest.Operation) -> Self {
        FanControlHelperReply(
            operation: operation,
            success: success,
            message: message,
            appliedTargetRPMByFan: appliedTargetRPMByFan,
            powerConfiguration: powerConfiguration,
            curveRuntimeState: curveRuntimeState,
            errorCode: errorCode,
            macMiniModeStatus: macMiniModeStatus,
            powerSampleResult: powerSampleResult,
            automaticRestores: automaticRestores
        )
    }

    func reporting(_ restores: [FanControlAutomaticRestore]) -> Self {
        FanControlHelperReply(
            operation: operation,
            success: success,
            message: message,
            appliedTargetRPMByFan: appliedTargetRPMByFan,
            powerConfiguration: powerConfiguration,
            curveRuntimeState: curveRuntimeState,
            errorCode: errorCode,
            macMiniModeStatus: macMiniModeStatus,
            powerSampleResult: powerSampleResult,
            automaticRestores: restores
        )
    }
}

private final class FanControlHelperDaemon:
    NSObject,
    NSXPCListenerDelegate,
    FanControlHelperProtocol,
    @unchecked Sendable
{
    private static let machServiceName = StorageCleanerBuildIdentity.helperLabel
    // The marker survives a helper crash long enough for the next launch to
    // return AppleSMC to automatic control.  It is only written by this
    // privileged helper, and a stale marker is safe: recovery can only lower
    // a manual target back to the system-managed mode.
    private static let controlRecoveryMarkerURL = URL(
        fileURLWithPath: "/var/run/\(StorageCleanerBuildIdentity.helperLabel).active"
    )

    private let listener = NSXPCListener(machServiceName: machServiceName)
    private let smcQueue = DispatchQueue(
        label: "\(StorageCleanerBuildIdentity.helperLabel).smc"
    )
    private let commandQueue = DispatchQueue(
        label: "\(StorageCleanerBuildIdentity.helperLabel).commands"
    )
    private let watchdogQueue = DispatchQueue(
        label: "\(StorageCleanerBuildIdentity.helperLabel).watchdog"
    )
    private let startupSafety = FanControlStartupSafety()
    /// D105 (review C-R1, C-R2): the returns this helper made on its own,
    /// kept beside the crash-recovery marker in root's /var/run.
    private let automaticRestores = FanControlAutomaticRestoreJournal(
        url: URL(fileURLWithPath: "/var/run/\(StorageCleanerBuildIdentity.helperLabel).restores")
    )
    // Validated before the listener is exposed; never re-derived from an
    // updated on-disk image while this old process is serving connections.
    private let startupIdentity: CodeSigningCheck.StartupIdentity?
    // D102 L1: the requirement every message from a client must meet, built
    // once from the startup signature for the same reason.
    private let clientRequirement: String?
    private let upgradeLedger = HelperUpgradeLedger(label: StorageCleanerBuildIdentity.helperLabel)
    // commandQueue confined; a final check must match this exact candidate.
    private var replacementForTermination: CodeSigningCheck.ReplacementIdentity?
    private var cancelledHandoffKeepsResident = false
    private var connections: [NSXPCConnection] = []
    private var forcedFanIDs: Set<Int> = []
    private var forcedTargetRPMByFan: [Int: Int] = [:]
    private var watchdogDeadline: Date?
    private var watchdog: DispatchSourceTimer?
    private var watchdogRestorePending = false
    private var fanCurveController: FanCurveController?
    private var fanCurveTimer: DispatchSourceTimer?
    private var lastFanCurveRuntimeState = FanCurveRuntimeState.inactive
    // These members are confined to commandQueue, independently of the fan lease.
    private var macMiniRuntime: MacMiniModeRuntime?
    private var idleExitWork: DispatchWorkItem?
    private var terminationSources: [DispatchSourceSignal] = []
    private var isTerminating = false
    private let requestLock = NSLock()
    private var pendingRequestCount = 0
    private var pendingPowerSamples = 0
    private let powerSamplingRunner: PowermetricsProcessRunner
    private let powerSampling: PowermetricsSamplingCoordinator
    private let powerSamplingClients = PowermetricsClientGate()
    /// Signing checks for sampling run here, never on an XPC delivery queue that
    /// also carries fan writes and lease renewals.
    private let powerSamplingVerificationQueue = DispatchQueue(
        label: "StorageCleanerMac.helper.powerSamplingVerification", qos: .utility)
    private var acceptsRequests = true

    override init() {
        let runner = PowermetricsProcessRunner()
        powerSamplingRunner = runner
        powerSampling = runner.makeCoordinator()
        do {
            startupIdentity = try CodeSigningCheck.captureStartupIdentity()
            if startupIdentity == nil {
                NSLog("Helper startup signature snapshot unavailable; caller authentication stays closed.")
            }
        } catch {
            startupIdentity = nil
            NSLog("Helper startup signing snapshot failed: \(error)")
        }
        clientRequirement = startupIdentity.flatMap { identity in
            identity.signing.certificates.first.flatMap { leaf in
                FanControlPeerRequirement.expression(identifier: StorageCleanerBuildIdentity.appBundleIdentifier,
                                                     leafCertificate: SecCertificateCopyData(leaf) as Data,
                                                     teamIdentifier: identity.signing.teamIdentifier)
            }
        }
        super.init()
        listener.delegate = self
    }

    func run() {
        commandQueue.sync {
            let runtime = MacMiniModeRuntime(queue: commandQueue) { [unowned self] command in
                self.runPMSet(command.arguments).succeeded
            }
            runtime.didBecomeIdle = { [weak self] in self?.scheduleIdleExit() }
            macMiniRuntime = runtime
            startTerminationHandlers()
        }
        // D105: a helper that left the fans under its control left the marker.
        let recoversPreviousControl = FileManager.default.fileExists(atPath: Self.controlRecoveryMarkerURL.path)
        let startupState = startupSafety.start(recoverFans: {
            smcQueue.sync { recoverPreviousControlIfNeeded() }
        }, prepareMacMiniForTermination: {
            _ = commandQueue.sync { macMiniRuntime?.prepareForTermination() }
        })
        if recoversPreviousControl {
            automaticRestores.record(.startupRecovery, restored: startupState == .ready)
        }
        startupSafety.startNormalWork {
            commandQueue.sync { macMiniRuntime?.start() }
            startWatchdog()
            startFanCurveTimer()
        }
        if startupState == .recoveryFailed {
            NSLog("%@", FanControlStartupSafety.failureMessageChinese)
            // Only authenticated fault replies are served. After disconnect,
            // normal idle exit uses EXIT_SUCCESS, avoiding a KeepAlive loop.
        }
        listener.resume()
        commandQueue.async { [weak self] in self?.scheduleIdleExit() }
        RunLoop.current.run()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        do {
            guard let startupIdentity,
                  let token = CodeSigningCheck.auditToken(for: newConnection),
                  try CodeSigningCheck.clientMatchesHelper(auditToken: token, helperIdentity: startupIdentity.signing) else {
                NSLog("Rejected fan-control XPC client with mismatched code signing.")
                return false
            }
            // Only a client that passed ALL original listener checks may even
            // inspect handoff eligibility. Extra seal/team/path checks do not
            // expand normal fan-control authority.
            if let replacement = try CodeSigningCheck.shouldYieldToReplacement(auditToken: token, startup: startupIdentity),
               let runningBuild = startupIdentity.signing.signedBuild,
               upgradeLedger.permits(target: replacement.build, running: runningBuild, at: ProcessInfo.processInfo.systemUptime) {
                commandQueue.async { [weak self] in
                    self?.terminateForReplacementOrSignal(isReplacement: true, replacement: replacement)
                }
                return false
            }
        } catch {
            NSLog("Rejected fan-control XPC client: \(error)")
            return false
        }
        // D102 L1: on top of the checks above, the system checks every message
        // against the app's identifier, this helper's leaf certificate and
        // Team ID; a client that stops meeting it loses the connection.
        guard let clientRequirement else {
            NSLog("Rejected fan-control XPC client: no code signing requirement.")
            return false
        }
        newConnection.setCodeSigningRequirement(clientRequirement)

        newConnection.exportedInterface = NSXPCInterface(
            with: FanControlHelperProtocol.self
        )
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            smcQueue.sync {
                powerSamplingClients.forget(connection: ObjectIdentifier(newConnection))
                connections.removeAll { $0 === newConnection }
                if startupSafety.isReady { restoreAutomatically(.appDisconnected) }
            }
            commandQueue.async { [weak self] in self?.scheduleIdleExit() }
        }
        let admitted = smcQueue.sync {
            requestLock.withLock {
                guard acceptsRequests else { return false }
                connections.append(newConnection)
                powerSamplingClients.register(connection: ObjectIdentifier(newConnection))
                return true
            }
        }
        guard admitted else { return false }
        newConnection.resume()
        return true
    }

    func execute(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        guard requestData.count <= 65_536 else {
            reply(Self.encoded(failure(
                "Fan-control request exceeds the maximum encoded size.",
                errorCode: .invalidRequest
            )))
            return
        }
        struct Header: Decodable { let operation: FanControlHelperRequest.Operation }
        if (try? JSONDecoder().decode(Header.self, from: requestData).operation) == .samplePowerMetrics {
            executePowerSample(requestData, reply: reply)
            return
        }
        let request: FanControlHelperRequest
        do {
            request = try JSONDecoder().decode(FanControlHelperRequest.self, from: requestData)
        } catch {
            reply(Self.encoded(failure(
                "Invalid request: \(error.localizedDescription)",
                errorCode: .invalidRequest
            )))
            return
        }

        let queue = switch request.operation {
        case .apply, .renewFanControlLease, .restoreAutomatic,
             .validateFanCurve, .activateFanCurve, .updateFanCurve,
             .getFanCurveRuntimeState, .deactivateFanCurve:
            smcQueue
        case .ping, .readPowerConfiguration, .applyPowerMode,
             .readMacMiniMode, .setMacMiniMode, .samplePowerMetrics:
            commandQueue
        }
        let accepted = requestLock.withLock {
            guard acceptsRequests else { return false }
            pendingRequestCount += 1
            return true
        }
        guard accepted else {
            reply(Self.encoded(failure("Helper is terminating.", operation: request.operation, errorCode: .invalidRequest)))
            return
        }
        queue.async { [self] in
            defer {
                requestLock.withLock { pendingRequestCount -= 1 }
                commandQueue.async { [weak self] in self?.scheduleIdleExit() }
            }
            reply(Self.encoded(reportingAutomaticRestores(handle(request))))
        }
    }

    /// D105 (review C-R1, C-R2): a ping (the app connecting) and every reply
    /// that did not succeed carry this helper's own returns to system control,
    /// so the app records what actually happened instead of inferring it.
    private func reportingAutomaticRestores(_ reply: FanControlHelperReply) -> FanControlHelperReply {
        guard reply.operation != .samplePowerMetrics, reply.operation == .ping || !reply.success else { return reply }
        return reply.reporting(automaticRestores.restores)
    }

    /// Shares the authenticated listener, but no hardware executor or policy lock.
    private func executePowerSample(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        @Sendable func finish(_ result: PowermetricsResult) {
            let succeeded: Bool
            if case .sample = result { succeeded = true } else { succeeded = false }
            reply(Self.encoded(FanControlHelperReply(operation: .samplePowerMetrics,
                success: succeeded, message: "Read-only power sampling result.",
                appliedTargetRPMByFan: [:], powerSampleResult: result)))
        }
        guard (try? PowermetricsSamplingRequest.decode(data)) != nil else {
            finish(.failure(.invalidRequest)); return
        }
        // current() is used synchronously on the XPC dispatch thread. Do not
        // move this lookup into Task, or fall back to a caller-supplied PID.
        guard let connection = NSXPCConnection.current(),
              let token = CodeSigningCheck.auditToken(for: connection) else {
            finish(.failure(.unauthorized)); return
        }
        let connectionID = ObjectIdentifier(connection)
        // Cheap per-connection interval before any Security work; refused
        // attempts count too, so a flood cannot buy repeated seal checks.
        guard let admission = powerSamplingClients.admitAttempt(connection: connectionID,
                                                               now: PowermetricsMonotonicClock.seconds) else {
            finish(.failure(.throttled)); return
        }
        guard startupSafety.isReady else { finish(.failure(.unavailable)); return }
        let accepted = requestLock.withLock {
            guard acceptsRequests, pendingPowerSamples < PowermetricsSamplingCoordinator.maximumWaiters else { return false }
            pendingRequestCount += 1
            pendingPowerSamples += 1
            return true
        }
        guard accepted else { finish(.failure(.busy)); return }
        let client = CodeSigningCheck.clientProcess(of: token)
        powerSamplingVerificationQueue.async { [self] in
            // Cheap identity check on every request; the full seal check only
            // once per connection and process instance (pid + pidversion).
            let authorized = powerSamplingClients.authorize(
                admission: admission, process: client,
                cheapCheck: { try CodeSigningCheck.powerSamplingClientIdentityMatches(auditToken: token) },
                sealCheck: { try CodeSigningCheck.powerSamplingClientSealIsValid(auditToken: token) })
            Task { [self] in
                // An unauthorized caller neither launches nor consumes the throttle.
                let result = await powerSampling.request(authorized: authorized)
                finish(result)
                requestLock.withLock {
                    pendingRequestCount -= 1
                    pendingPowerSamples -= 1
                }
                commandQueue.async { [weak self] in self?.scheduleIdleExit() }
            }
        }
    }

    private func handle(_ request: FanControlHelperRequest) -> FanControlHelperReply {
        guard let protocolVersion = request.protocolVersion else {
            return failure(
                "Missing fan-control protocol version.",
                operation: request.operation,
                errorCode: .invalidRequest
            )
        }
        guard HardwareControlProtocol.accepts(protocolVersion) else {
            return failure(
                "Unsupported fan-control protocol version \(protocolVersion).",
                operation: request.operation,
                errorCode: .invalidRequest
            )
        }
        guard request.operation == .setMacMiniMode || request.macMiniMode == nil else {
            return failure("Unexpected Mac mini mode payload.", operation: request.operation, errorCode: .invalidRequest)
        }

        // Fault-mode recovery has its own executor: no fan or curve operation
        // can enter it, and mode ON is explicitly excluded.
        if FanControlStartupSafety.permitsSleepRecovery(operation: request.operation.rawValue, mode: request.macMiniMode,
            hasEmptyPayload: hasEmptyPayload(request, allowingMacMiniMode: request.operation == .setMacMiniMode)) {
            return startupSafety.dispatchSleepRecovery(recover: {
                handleMacMiniMode(request).echoing(request.operation)
            }, reject: { _ in
                failure(FanControlStartupSafety.failureMessageChinese, operation: request.operation,
                        errorCode: .fanCrashRecoveryFailed)
            })
        }
        return startupSafety.dispatch(execute: {
            handleReady(request)
        }, reject: { _ in
            failure(FanControlStartupSafety.failureMessageChinese, operation: request.operation,
                    errorCode: .fanCrashRecoveryFailed)
        })
    }

    private func handleReady(_ request: FanControlHelperRequest) -> FanControlHelperReply {
        let response = switch request.operation {
        case .ping:
            ping(request)
        case .readPowerConfiguration:
            readPowerConfiguration(request)
        case .restoreAutomatic:
            restoreAutomatic(request)
        case .apply:
            apply(request)
        case .renewFanControlLease:
            renewFanControlLease(request)
        case .applyPowerMode:
            applyPowerMode(request)
        case .validateFanCurve:
            validateFanCurve(request)
        case .activateFanCurve:
            activateFanCurve(request)
        case .updateFanCurve:
            updateFanCurve(request)
        case .getFanCurveRuntimeState:
            getFanCurveRuntimeState(request)
        case .deactivateFanCurve:
            deactivateFanCurve(request)
        case .readMacMiniMode, .setMacMiniMode:
            handleMacMiniMode(request)
        case .samplePowerMetrics:
            failure("Sampling requires the strict read-only envelope.", errorCode: .invalidRequest)
        }
        return response.echoing(request.operation)
    }

    private func ping(_ request: FanControlHelperRequest) -> FanControlHelperReply {
        guard hasEmptyPayload(request) else {
            return failure("Rejected invalid ping request.", errorCode: .invalidRequest)
        }
        return FanControlHelperReply(
            success: true,
            message: "Hardware-control helper is ready.",
            appliedTargetRPMByFan: [:]
        )
    }

    private func restoreAutomatic(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard hasEmptyPayload(request) else {
            return failure(
                "Rejected invalid automatic-restore request.",
                errorCode: .invalidRequest
            )
        }
        guard let controller = SMCFanController() else {
            return failure(
                "AppleSMC is unavailable while verifying automatic fan control.",
                errorCode: .smcReadFailed
            )
        }
        fanCurveController = nil
        if restoreAllFans(using: controller) {
            lastFanCurveRuntimeState = .inactive
            return FanControlHelperReply(
                success: true,
                message: "Automatic-restore request completed.",
                appliedTargetRPMByFan: [:],
                curveRuntimeState: .inactive
            )
        }
        return failure(
            "Could not restore system fan control.",
            errorCode: .smcWriteFailed
        )
    }

    private func hasEmptyPayload(
        _ request: FanControlHelperRequest, allowingMacMiniMode: Bool = false
    ) -> Bool {
        request.targetRPMByFan.isEmpty
            && request.automaticFanIDs.isEmpty
            && !request.allowsRPMDecrease
            && request.watchdogSeconds == 0
            && request.powerModeSource == nil
            && request.powerModeSetting == nil
            && request.powerModeValue == nil
            && request.curveProfile == nil
            && request.curveLeaseID == nil
            && (allowingMacMiniMode || request.macMiniMode == nil)
    }

    private func handleMacMiniMode(_ request: FanControlHelperRequest) -> FanControlHelperReply {
        guard !isTerminating,
              hasEmptyPayload(request, allowingMacMiniMode: request.operation == .setMacMiniMode),
              let macMiniRuntime else {
            return failure("Rejected Mac mini mode request.", errorCode: .invalidRequest)
        }
        let status: MacMiniModeStatus
        if request.operation == .setMacMiniMode {
            guard let mode = request.macMiniMode else {
                return failure("Missing Mac mini mode.", errorCode: .invalidRequest)
            }
            status = startupSafety.isReady ? macMiniRuntime.setMode(mode) : macMiniRuntime.disableForRemoval()
        } else {
            status = macMiniRuntime.status()
        }
        let code: FanControlHelperErrorCode? = switch status.failure {
        case .stateUnavailable?: .macMiniModeStateUnavailable
        case .persistenceFailed?: .macMiniModePersistenceFailed
        case .commandFailed?: .macMiniModeCommandFailed
        case .verificationFailed?: .macMiniModeVerificationFailed
        case .sleepRequestFailed?: .macMiniModeSleepFailed
        case .conflictingIdentity?: .macMiniModeConflict
        case nil: nil
        }
        return FanControlHelperReply(
            success: code == nil, message: code == nil ? "Mac mini mode state read." : "Mac mini mode remains unconfirmed.",
            appliedTargetRPMByFan: [:], errorCode: code, macMiniModeStatus: status
        )
    }

    private func scheduleIdleExit() {
        idleExitWork?.cancel()
        guard !isTerminating, !cancelledHandoffKeepsResident else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isTerminating, !self.cancelledHandoffKeepsResident else { return }
            // Admission and the final idle decision share the same queue/lock
            // order, so no connection can arrive between the check and exit.
            self.smcQueue.sync {
                self.requestLock.withLock {
                    guard MacMiniHelperIdlePolicy.mayExit(
                        connectionCount: self.connections.count,
                        pendingRequests: self.pendingRequestCount,
                        hasFanWork: !self.forcedFanIDs.isEmpty || self.fanCurveController != nil || self.watchdogRestorePending,
                        requiresResidentHelper: self.startupSafety.requiresResidentHelper(
                            macMiniRequested: self.macMiniRuntime?.requiresResidentHelper != false
                        )
                    ) else { return }
                    self.acceptsRequests = false
                    exit(EXIT_SUCCESS)
                }
            }
        }
        idleExitWork = work
        commandQueue.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func startTerminationHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: commandQueue)
            source.setEventHandler { [weak self] in
                self?.terminateForReplacementOrSignal(isReplacement: false)
            }
            source.resume()
            terminationSources.append(source)
        }
    }

    /// commandQueue confined; serialize with pmset work and reuse the same
    /// recovery executors as SIGTERM. No unchecked client reaches this method.
    private func terminateForReplacementOrSignal(isReplacement: Bool, replacement: CodeSigningCheck.ReplacementIdentity? = nil) {
        guard !isTerminating else { return }
        replacementForTermination = replacement
        isTerminating = true
        requestLock.withLock { acceptsRequests = false }
        self.powerSamplingRunner.stopForTermination()
        idleExitWork?.cancel()
        finishTerminationWhenDrained(isReplacement: isReplacement)
    }

    private func finishTerminationWhenDrained(isReplacement: Bool) {
        // A request admitted just before the gate closed may not yet have
        // reached its executor. Drain its counted work before the final restore.
        guard requestLock.withLock({ pendingRequestCount == 0 }) else {
            commandQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.finishTerminationWhenDrained(isReplacement: isReplacement)
            }
            return
        }
        let recovered = HelperUpgradeSafety.prepareForExit(stopRequestsAndSampling: {
            smcQueue.sync {
                fanCurveTimer?.cancel()
                fanCurveTimer = nil
                fanCurveController = nil
                watchdog?.cancel()
                watchdog = nil
            }
        }, restoreSleep: {
            macMiniRuntime?.prepareForTermination() == true
        }, restoreFans: {
            // Startup failure has already tried recovery and latched the
            // marker. Do not dispatch additional writes in a failed process.
            !startupSafety.isReady || smcQueue.sync { restoreAutomatically(.helperStopping) }
        })
        let keepRequestedMode = macMiniRuntime?.requiresResidentHelper == true
        // KeepAlive is SuccessfulExit=false. A successful upgrade is on demand;
        // restoration failure (marker preserved) or an enabled sleep policy
        // needs an immediate new process, just like the existing signal path.
        let success = !startupSafety.isReady || (recovered && !keepRequestedMode)
        let exitProcess = {
            NSLog("Helper termination replacement=%@ recovery=%@ successfulExit=%@",
                  String(isReplacement), String(recovered), String(success))
            exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        guard isReplacement else { exitProcess(); return }
        HelperUpgradeSafety.finishHandoff(revalidateAndRecord: {
            guard let startupIdentity, let runningBuild = startupIdentity.signing.signedBuild,
                  let replacement = replacementForTermination else { return false }
            return upgradeLedger.commitIfPermitted(target: replacement.build, running: runningBuild, at: ProcessInfo.processInfo.systemUptime) {
                // Fresh SecStaticCode: repeat seal/chain/team/path/version checks
                // after drain/recovery, and require the initially inspected image.
                try CodeSigningCheck.validatedReplacement(startup: startupIdentity) == replacement
            }
        }, resumeService: {
            cancelledHandoffKeepsResident = true
            replacementForTermination = nil
            isTerminating = false
            powerSamplingRunner.resumeAfterCancelledTermination()
            if startupSafety.isReady {
                macMiniRuntime?.start()
                smcQueue.sync { startWatchdog(); startFanCurveTimer() }
            }
            requestLock.withLock { acceptsRequests = true }
            scheduleIdleExit()
            NSLog("Helper handoff cancelled: final image validation or protected cooldown denied it; service resumed.")
        }, exitProcess: exitProcess)
    }

    private func readPowerConfiguration(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard request.targetRPMByFan.isEmpty,
              request.automaticFanIDs.isEmpty,
              !request.allowsRPMDecrease,
              request.watchdogSeconds == 0,
              request.powerModeSource == nil,
              request.powerModeSetting == nil,
              request.powerModeValue == nil,
              request.curveProfile == nil,
              request.curveLeaseID == nil else {
            return failure(
                "Rejected invalid power-configuration request.",
                errorCode: .invalidRequest
            )
        }

        switch capturePowerConfiguration() {
        case .success(let configuration):
            return FanControlHelperReply(
                success: true,
                message: "Power configuration read.",
                appliedTargetRPMByFan: [:],
                powerConfiguration: configuration
            )
        case .failure(let error):
            return failure(error.description, errorCode: .pmsetFailed)
        }
    }

    private func applyPowerMode(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard request.targetRPMByFan.isEmpty,
              request.automaticFanIDs.isEmpty,
              !request.allowsRPMDecrease,
              request.watchdogSeconds == 0,
              let source = request.powerModeSource,
              let setting = request.powerModeSetting,
              let value = request.powerModeValue,
              request.curveProfile == nil,
              request.curveLeaseID == nil,
              ["-b", "-c"].contains(source),
              (setting == "powermode" && (0...2).contains(value))
                || (setting == "lowpowermode" && (0...1).contains(value)) else {
            return failure(
                "Rejected out-of-range power-mode request.",
                errorCode: .invalidRequest
            )
        }

        let write = runPMSet([source, setting, String(value)])
        guard write.succeeded else {
            return failure(
                write.failureDescription(action: "Power-mode command"),
                errorCode: .pmsetFailed
            )
        }

        var lastConfiguration: PowerConfiguration?
        for attempt in 0..<3 {
            if attempt > 0 { usleep(150_000) }
            guard case .success(let configuration) = capturePowerConfiguration() else {
                continue
            }
            lastConfiguration = configuration
            if configuration.matches(source: source, setting: setting, value: value) {
                NSLog(
                    "Verified power-mode update for %@ %@=%d.",
                    source,
                    setting,
                    value
                )
                return FanControlHelperReply(
                    success: true,
                    message: "Power mode applied and verified.",
                    appliedTargetRPMByFan: [:],
                    powerConfiguration: configuration
                )
            }
        }

        return FanControlHelperReply(
            success: false,
            message: "pmset readback did not match the requested power mode.",
            appliedTargetRPMByFan: [:],
            powerConfiguration: lastConfiguration,
            errorCode: .pmsetVerificationFailed
        )
    }

    private enum PowerConfigurationCaptureError: Error, CustomStringConvertible {
        case command(String)

        var description: String {
            switch self {
            case .command(let message): message
            }
        }
    }

    private struct PMSetResult {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String
        let timedOut: Bool

        var succeeded: Bool {
            !timedOut && terminationStatus == 0
        }

        func failureDescription(action: String) -> String {
            if timedOut { return "\(action) timed out." }
            let detail = standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(action) failed with exit status \(terminationStatus)."
                : "\(action) failed with exit status \(terminationStatus): \(detail)"
        }
    }

    private final class PipeReadResult: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ data: Data) {
            lock.withLock { self.data = data }
        }

        func load() -> Data {
            lock.withLock { data }
        }
    }

    private func runPMSet(_ arguments: [String]) -> PMSetResult {
        let signpostID = HelperPerformanceTelemetry.signposter.makeSignpostID()
        let signpostState = HelperPerformanceTelemetry.signposter.beginInterval(
            "PMSetExecution",
            id: signpostID
        )
        defer {
            HelperPerformanceTelemetry.signposter.endInterval(
                "PMSetExecution",
                signpostState
            )
        }
        guard HelperPMSetWhitelist.permits(arguments) else {
            return PMSetResult(
                terminationStatus: -1,
                standardOutput: "",
                standardError: "Rejected non-whitelisted pmset arguments.",
                timedOut: false
            )
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = [
            "LANG": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return PMSetResult(
                terminationStatus: -1,
                standardOutput: "",
                standardError: String(error.localizedDescription.prefix(512)),
                timedOut: false
            )
        }

        let outputResult = PipeReadResult()
        let errorResult = PipeReadResult()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputResult.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorResult.store(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        guard finished.wait(timeout: .now() + 4) == .success else {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) != .success, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            if readGroup.wait(timeout: .now() + 1) != .success {
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                _ = readGroup.wait(timeout: .now() + 1)
            }
            return PMSetResult(
                terminationStatus: -1,
                standardOutput: "",
                standardError: "",
                timedOut: true
            )
        }

        if readGroup.wait(timeout: .now() + 1) != .success {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = readGroup.wait(timeout: .now() + 1)
        }

        return PMSetResult(
            terminationStatus: process.terminationStatus,
            standardOutput: Self.boundedText(
                outputResult.load()
            ),
            standardError: Self.boundedText(
                errorResult.load()
            ),
            timedOut: false
        )
    }

    private func capturePowerConfiguration() -> Result<PowerConfiguration, PowerConfigurationCaptureError> {
        let result = runPMSet(["-g", "custom"])
        guard result.succeeded else {
            return .failure(.command(
                result.failureDescription(action: "Power-configuration read")
            ))
        }
        return .success(Self.parsePowerConfiguration(result.standardOutput))
    }

    private static func boundedText(_ data: Data) -> String {
        String(decoding: data.prefix(16_384), as: UTF8.self)
    }

    private static func parsePowerConfiguration(_ output: String) -> PowerConfiguration {
        enum Section { case battery, adapter }
        struct Accumulator {
            var consolidatedValue: Int?
            var consolidatedInvalid = false
            var sawConsolidated = false
            var lowPowerValue: Int?
            var lowPowerInvalid = false
            var sawLowPower = false

            mutating func record(_ setting: String, value: Int?) {
                switch setting {
                case PowerModeSettingKey.powerMode.rawValue:
                    sawConsolidated = true
                    guard let value, (0...2).contains(value),
                          consolidatedValue == nil || consolidatedValue == value else {
                        consolidatedInvalid = true
                        return
                    }
                    consolidatedValue = value
                case PowerModeSettingKey.lowPowerMode.rawValue:
                    sawLowPower = true
                    guard let value, (0...1).contains(value),
                          lowPowerValue == nil || lowPowerValue == value else {
                        lowPowerInvalid = true
                        return
                    }
                    lowPowerValue = value
                default:
                    break
                }
            }

            var setting: PowerModeSettingKey? {
                if sawConsolidated {
                    return !consolidatedInvalid && consolidatedValue != nil
                        ? .powerMode : nil
                }
                return sawLowPower && !lowPowerInvalid && lowPowerValue != nil
                    ? .lowPowerMode : nil
            }

            var mode: PowerMode? {
                switch setting {
                case .powerMode:
                    switch consolidatedValue {
                    case 0: .automatic
                    case 1: .lowPower
                    case 2: .highPower
                    default: nil
                    }
                case .lowPowerMode:
                    lowPowerValue == 0 ? .automatic
                        : (lowPowerValue == 1 ? .lowPower : nil)
                case nil:
                    nil
                }
            }

            var supportedModes: [PowerMode] {
                switch setting {
                case .powerMode: [.automatic, .lowPower, .highPower]
                case .lowPowerMode: [.automatic, .lowPower]
                case nil: []
                }
            }
        }

        var section: Section?
        var battery = Accumulator()
        var adapter = Accumulator()
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercase = trimmed.lowercased()
            if lowercase == "battery power:" {
                section = .battery
                continue
            }
            if lowercase == "ac power:" {
                section = .adapter
                continue
            }
            if lowercase.hasSuffix(" power:") {
                section = nil
                continue
            }
            guard let section else { continue }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard let setting = fields.first.map(String.init),
                  setting == PowerModeSettingKey.powerMode.rawValue
                    || setting == PowerModeSettingKey.lowPowerMode.rawValue else {
                continue
            }
            let value = fields.count == 2 ? Int(fields[1]) : nil
            switch section {
            case .battery: battery.record(setting, value: value)
            case .adapter: adapter.record(setting, value: value)
            }
        }

        return PowerConfiguration(
            battery: battery.mode,
            adapter: adapter.mode,
            supportedBatteryModes: battery.supportedModes,
            supportedAdapterModes: adapter.supportedModes,
            batterySetting: battery.setting,
            adapterSetting: adapter.setting
        )
    }

    private func renewFanControlLease(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard request.targetRPMByFan.isEmpty,
              request.automaticFanIDs.isEmpty,
              !request.allowsRPMDecrease,
              request.watchdogSeconds.isFinite,
              (3...30).contains(request.watchdogSeconds),
              request.powerModeSource == nil,
              request.powerModeSetting == nil,
              request.powerModeValue == nil,
              request.curveProfile == nil else {
            return failure(
                "Rejected invalid fan-control lease request.",
                errorCode: .invalidRequest
            )
        }
        if let curveLeaseID = request.curveLeaseID {
            guard let fanCurveController else {
                return curveFailureReply(.curveLeaseExpired, operation: request.operation)
            }
            do {
                let now = Date()
                try fanCurveController.renew(
                    leaseID: curveLeaseID,
                    watchdogSeconds: request.watchdogSeconds,
                    at: now
                )
                watchdogDeadline = now.addingTimeInterval(request.watchdogSeconds)
                return FanControlHelperReply(
                    success: true,
                    message: "Fan-curve lease renewed.",
                    appliedTargetRPMByFan: fanCurveController.runtimeState.targetRPMByFan,
                    curveRuntimeState: fanCurveController.runtimeState
                )
            } catch let error as FanCurveError {
                failCurveControl(error)
                return curveFailureReply(error, operation: request.operation)
            } catch {
                failCurveControl(.curveLeaseExpired)
                return curveFailureReply(.curveLeaseExpired, operation: request.operation)
            }
        }
        guard request.curveLeaseID == nil else {
            return failure("Rejected invalid fan-control lease ID.", errorCode: .invalidRequest)
        }
        guard !forcedTargetRPMByFan.isEmpty else {
            return failure(
                "No active fan-control lease exists.",
                errorCode: .fanLeaseExpired
            )
        }
        guard let controller = SMCFanController() else {
            restoreAutomatically(.fanVerificationFailed)
            return failure(
                "AppleSMC is unavailable while renewing the lease.",
                errorCode: .smcReadFailed
            )
        }
        let smcID = HelperPerformanceTelemetry.signposter.makeSignpostID()
        let smcState = HelperPerformanceTelemetry.signposter.beginInterval(
            "SMCAccess",
            id: smcID
        )
        defer {
            HelperPerformanceTelemetry.signposter.endInterval(
                "SMCAccess",
                smcState
            )
        }
        guard controller.verifiesManualTargets(forcedTargetRPMByFan) else {
            let restoreCompleted = restoreAllFans(using: controller)
            automaticRestores.record(.fanVerificationFailed, restored: restoreCompleted)
            return failure(
                restoreCompleted
                    ? "Fan state no longer matches the active lease; the automatic-restore request completed."
                    : "Fan state no longer matches the active lease; automatic restoration remains unconfirmed.",
                errorCode: .fanVerificationFailed
            )
        }

        watchdogDeadline = Date().addingTimeInterval(request.watchdogSeconds)
        HelperPerformanceTelemetry.signposter.emitEvent("FanReadback")
        return FanControlHelperReply(
            success: true,
            message: "Fan-control lease renewed.",
            appliedTargetRPMByFan: forcedTargetRPMByFan
        )
    }

    private func apply(_ request: FanControlHelperRequest) -> FanControlHelperReply {
        guard request.targetRPMByFan.count <= 16,
              request.automaticFanIDs.count <= 16,
              request.watchdogSeconds.isFinite,
              (3...30).contains(request.watchdogSeconds),
              request.powerModeSource == nil,
              request.powerModeSetting == nil,
              request.powerModeValue == nil,
              request.curveProfile == nil,
              request.curveLeaseID == nil else {
            return failure(
                "Rejected out-of-range fan-control request.",
                errorCode: .invalidRequest
            )
        }
        guard Set(request.targetRPMByFan.keys).isDisjoint(
            with: request.automaticFanIDs
        ) else {
            return failure(
                "A fan cannot be forced and automatic in the same request.",
                errorCode: .invalidRequest
            )
        }
        guard let controller = SMCFanController() else {
            return failure(
                "AppleSMC is unavailable.",
                errorCode: .unsupportedHardware
            )
        }
        let smcID = HelperPerformanceTelemetry.signposter.makeSignpostID()
        let smcState = HelperPerformanceTelemetry.signposter.beginInterval(
            "SMCAccess",
            id: smcID
        )
        let writeID = HelperPerformanceTelemetry.signposter.makeSignpostID()
        let writeState = HelperPerformanceTelemetry.signposter.beginInterval(
            "FanTargetWrite",
            id: writeID
        )
        defer {
            HelperPerformanceTelemetry.signposter.endInterval(
                "FanTargetWrite",
                writeState
            )
            HelperPerformanceTelemetry.signposter.endInterval(
                "SMCAccess",
                smcState
            )
        }

        // Manual and curve control are mutually exclusive. Keep the current
        // hardware speed as the transition baseline; the incoming typed manual
        // target is then verified by the same SMC transaction below.
        if fanCurveController != nil {
            fanCurveController = nil
            lastFanCurveRuntimeState = .inactive
        }

        let targetFanIDs = Set(request.targetRPMByFan.keys)
        let automaticFanIDs = Set(request.automaticFanIDs).union(
            forcedFanIDs.subtracting(targetFanIDs)
        )

        var applied: [Int: Int] = [:]
        for fanID in automaticFanIDs.sorted() {
            guard controller.setAutomatic(fanID: fanID) else {
                _ = restoreAllFans(using: controller)
                return failure(
                    "Could not restore fan \(fanID) to automatic control.",
                    errorCode: .partialFanWriteFailure
                )
            }
            forcedFanIDs.remove(fanID)
            forcedTargetRPMByFan.removeValue(forKey: fanID)
        }

        // Arm the final fail-safe before the first write that can switch a fan
        // into manual mode. The watchdog schedules independently, while the
        // restore itself remains serialized with every other AppleSMC write.
        if !targetFanIDs.isEmpty {
            guard armCrashRecoveryMarker() else {
                _ = restoreAllFans(using: controller)
                return failure(
                    "Could not arm fan-control crash recovery.",
                    errorCode: .smcWriteFailed
                )
            }
            forcedFanIDs.formUnion(targetFanIDs)
            watchdogDeadline = Date().addingTimeInterval(request.watchdogSeconds)
        }

        for (fanID, requestedRPM) in request.targetRPMByFan.sorted(by: {
            $0.key < $1.key
        }) {
            guard let appliedRPM = controller.applyCoolingBoost(
                fanID: fanID,
                requestedRPM: requestedRPM,
                allowsRPMDecrease: request.allowsRPMDecrease
            ) else {
                _ = restoreAllFans(using: controller)
                return failure(
                    controller.failureMessage
                        ?? "Could not safely apply fan \(fanID) target.",
                    errorCode: applied.isEmpty
                        ? .smcWriteFailed
                        : .partialFanWriteFailure
                )
            }
            forcedFanIDs.insert(fanID)
            applied[fanID] = appliedRPM
        }

        if forcedFanIDs.isEmpty {
            forcedTargetRPMByFan.removeAll()
            watchdogDeadline = nil
            clearCrashRecoveryMarker()
        } else {
            forcedTargetRPMByFan = applied
            watchdogDeadline = Date().addingTimeInterval(request.watchdogSeconds)
        }
        HelperPerformanceTelemetry.signposter.emitEvent("FanReadback")
        return FanControlHelperReply(
            success: true,
            message: "Cooling overlay applied.",
            appliedTargetRPMByFan: applied
        )
    }

    private func validateFanCurve(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard curveRequestHasNoUnrelatedPayload(request),
              request.watchdogSeconds == 0,
              let profile = request.curveProfile,
              request.curveLeaseID == nil,
              let controller = SMCFanController() else {
            return curveFailureReply(.curveActivationFailed, operation: request.operation)
        }
        do {
            _ = try FanCurveController(
                profile: profile,
                leaseID: UUID(),
                watchdogSeconds: 15,
                smc: controller,
                now: Date()
            )
            return FanControlHelperReply(
                success: true,
                message: "Fan curve is valid for this hardware.",
                appliedTargetRPMByFan: [:],
                curveRuntimeState: .inactive
            )
        } catch let error as FanCurveError {
            return curveFailureReply(error, operation: request.operation)
        } catch {
            return curveFailureReply(.curveActivationFailed, operation: request.operation)
        }
    }

    private func activateFanCurve(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard curveRequestHasNoUnrelatedPayload(request),
              let profile = request.curveProfile,
              let leaseID = request.curveLeaseID,
              request.watchdogSeconds.isFinite,
              (3...30).contains(request.watchdogSeconds),
              fanCurveController == nil,
              let smc = SMCFanController() else {
            return curveFailureReply(.curveActivationFailed, operation: request.operation)
        }
        guard armCrashRecoveryMarker() else {
            return curveFailureReply(.curveActivationFailed, operation: request.operation)
        }
        do {
            let now = Date()
            let controller = try FanCurveController(
                profile: profile,
                leaseID: leaseID,
                watchdogSeconds: request.watchdogSeconds,
                smc: smc,
                now: now
            )
            fanCurveController = controller
            let state = try controller.activate(at: now)
            synchronizeCurveControlState(state, watchdogSeconds: request.watchdogSeconds)
            return FanControlHelperReply(
                success: true,
                message: "Fan curve activated and verified.",
                appliedTargetRPMByFan: state.targetRPMByFan,
                curveRuntimeState: state
            )
        } catch let error as FanCurveError {
            failCurveControl(error)
            return curveFailureReply(error, operation: request.operation)
        } catch {
            failCurveControl(.curveActivationFailed)
            return curveFailureReply(.curveActivationFailed, operation: request.operation)
        }
    }

    private func updateFanCurve(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard curveRequestHasNoUnrelatedPayload(request),
              let profile = request.curveProfile,
              let leaseID = request.curveLeaseID,
              request.watchdogSeconds.isFinite,
              (3...30).contains(request.watchdogSeconds),
              let fanCurveController else {
            return curveFailureReply(.curveUpdateFailed, operation: request.operation)
        }
        do {
            let state = try fanCurveController.update(
                profile: profile,
                leaseID: leaseID,
                watchdogSeconds: request.watchdogSeconds,
                at: Date()
            )
            synchronizeCurveControlState(state, watchdogSeconds: request.watchdogSeconds)
            return FanControlHelperReply(
                success: true,
                message: "Fan curve updated and verified.",
                appliedTargetRPMByFan: state.targetRPMByFan,
                curveRuntimeState: state
            )
        } catch let error as FanCurveError {
            failCurveControl(error)
            return curveFailureReply(error, operation: request.operation)
        } catch {
            failCurveControl(.curveUpdateFailed)
            return curveFailureReply(.curveUpdateFailed, operation: request.operation)
        }
    }

    private func getFanCurveRuntimeState(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard hasEmptyPayload(request) else {
            return failure("Rejected invalid fan-curve state request.", errorCode: .invalidRequest)
        }
        let state = fanCurveController?.runtimeState ?? lastFanCurveRuntimeState
        return FanControlHelperReply(
            success: true,
            message: "Fan-curve runtime state read.",
            appliedTargetRPMByFan: state.targetRPMByFan,
            curveRuntimeState: state
        )
    }

    private func deactivateFanCurve(
        _ request: FanControlHelperRequest
    ) -> FanControlHelperReply {
        guard hasEmptyPayload(request) else {
            return failure("Rejected invalid fan-curve stop request.", errorCode: .invalidRequest)
        }
        fanCurveController = nil
        lastFanCurveRuntimeState = FanCurveRuntimeState(status: .restoringAutomatic)
        guard restoreAllFans() else {
            return curveFailureReply(.curveVerificationFailed, operation: request.operation)
        }
        lastFanCurveRuntimeState = .inactive
        return FanControlHelperReply(
            success: true,
            message: "Fan curve stopped; system fan control restored.",
            appliedTargetRPMByFan: [:],
            curveRuntimeState: .inactive
        )
    }

    private func curveRequestHasNoUnrelatedPayload(
        _ request: FanControlHelperRequest
    ) -> Bool {
        request.targetRPMByFan.isEmpty
            && request.automaticFanIDs.isEmpty
            && !request.allowsRPMDecrease
            && request.powerModeSource == nil
            && request.powerModeSetting == nil
            && request.powerModeValue == nil
    }

    private func synchronizeCurveControlState(
        _ state: FanCurveRuntimeState,
        watchdogSeconds: TimeInterval
    ) {
        lastFanCurveRuntimeState = state
        forcedFanIDs = Set(state.targetRPMByFan.keys)
        forcedTargetRPMByFan = state.targetRPMByFan
        watchdogDeadline = Date().addingTimeInterval(watchdogSeconds)
    }

    private func failCurveControl(_ error: FanCurveError) {
        var state = fanCurveController?.runtimeState ?? lastFanCurveRuntimeState
        state.status = curveRuntimeStatus(for: error)
        state.failureReason = error
        lastFanCurveRuntimeState = state
        fanCurveController = nil
        if !restoreAutomatically(Self.automaticRestoreReason(for: error)) {
            NSLog("Fan-curve failure could not restore AppleSMC control.")
        }
    }

    private static func automaticRestoreReason(for error: FanCurveError) -> FanControlAutomaticRestore.Reason {
        switch error {
        case .curveLeaseExpired: .curveLeaseExpired
        case .thermalProtectionActivated: .thermalProtectionActivated
        default: .curveFailed
        }
    }

    /// D105 (review C-R1, C-R2): a return to system control the helper makes
    /// on its own. Its result is kept for the app, which records it when it
    /// next hears from the helper; the return never waits for the app. Only a
    /// return that had something to give back is kept. smcQueue confined.
    @discardableResult
    private func restoreAutomatically(_ reason: FanControlAutomaticRestore.Reason) -> Bool {
        FanControlAutomaticRestore.perform(
            reason,
            hadControl: !forcedFanIDs.isEmpty
                || FileManager.default.fileExists(atPath: Self.controlRecoveryMarkerURL.path),
            restore: { restoreAllFans() },
            keep: { automaticRestores.record($0, restored: $1) }
        )
    }

    private func curveRuntimeStatus(for error: FanCurveError) -> FanCurveRuntimeStatus {
        switch error {
        case .sensorUnavailable, .unsupportedSensor:
            .sensorUnavailable
        case .sensorStale:
            .sensorStale
        case .curveLeaseExpired:
            .leaseExpired
        case .thermalProtectionActivated:
            .thermalProtection
        case .curveVerificationFailed:
            .verificationFailed
        default:
            .inactive
        }
    }

    private func curveFailureReply(
        _ error: FanCurveError,
        operation: FanControlHelperRequest.Operation
    ) -> FanControlHelperReply {
        FanControlHelperReply(
            operation: operation,
            success: false,
            message: error.rawValue,
            appliedTargetRPMByFan: [:],
            curveRuntimeState: lastFanCurveRuntimeState,
            errorCode: helperErrorCode(for: error)
        )
    }

    private func helperErrorCode(for error: FanCurveError) -> FanControlHelperErrorCode {
        switch error {
        case .invalidCurvePointCount: .invalidCurvePointCount
        case .invalidCurveTemperature: .invalidCurveTemperature
        case .invalidCurvePercentage: .invalidCurvePercentage
        case .nonIncreasingTemperatures: .nonIncreasingTemperatures
        case .decreasingFanPercentage: .decreasingFanPercentage
        case .missingFullSpeedPoint: .missingFullSpeedPoint
        case .fullSpeedPointTooHot: .fullSpeedPointTooHot
        case .sensorUnavailable, .unsupportedSensor: .sensorUnavailable
        case .sensorStale: .sensorStale
        case .fanRangeUnavailable, .invalidTargetFans: .fanRangeUnavailable
        case .curveUpdateFailed: .curveUpdateFailed
        case .curveVerificationFailed: .curveVerificationFailed
        case .curveLeaseExpired: .curveLeaseExpired
        case .thermalProtectionActivated: .thermalProtectionActivated
        case .unsupportedProfileVersion, .curveActivationFailed: .curveActivationFailed
        }
    }

    @discardableResult
    private func restoreAllFans() -> Bool {
        if forcedFanIDs.isEmpty,
           !FileManager.default.fileExists(atPath: Self.controlRecoveryMarkerURL.path) {
            forcedTargetRPMByFan.removeAll()
            watchdogDeadline = nil
            return true
        }
        guard let controller = SMCFanController() else { return false }
        return restoreAllFans(using: controller)
    }

    @discardableResult
    private func restoreAllFans(using controller: SMCFanController) -> Bool {
        let result = controller.restoreAllFans()
        if result {
            forcedFanIDs.removeAll()
            forcedTargetRPMByFan.removeAll()
            watchdogDeadline = nil
            clearCrashRecoveryMarker()
        }
        return result
    }

    private func recoverPreviousControlIfNeeded() -> Bool {
        guard FileManager.default.fileExists(
            atPath: Self.controlRecoveryMarkerURL.path
        ) else {
            return true
        }
        return restoreAllFans()
    }

    private func armCrashRecoveryMarker() -> Bool {
        do {
            try Data("active\n".utf8).write(
                to: Self.controlRecoveryMarkerURL,
                options: [.atomic]
            )
            return true
        } catch {
            NSLog("Could not write fan-control crash recovery marker: %@", error.localizedDescription)
            return false
        }
    }

    private func clearCrashRecoveryMarker() {
        do {
            try FileManager.default.removeItem(at: Self.controlRecoveryMarkerURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            NSLog("Could not clear fan-control crash recovery marker: %@", error.localizedDescription)
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !watchdogRestorePending else { return }
            watchdogRestorePending = true
            smcQueue.async { [weak self] in
                guard let self else { return }
                defer {
                    watchdogQueue.async { [weak self] in
                        self?.watchdogRestorePending = false
                    }
                }
                guard !forcedFanIDs.isEmpty,
                      let watchdogDeadline,
                      Date() >= watchdogDeadline else {
                    return
                }
                if fanCurveController != nil {
                    failCurveControl(.curveLeaseExpired)
                } else if !restoreAutomatically(.fanLeaseExpired) {
                    NSLog("Fan-control watchdog could not restore AppleSMC control.")
                }
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func startFanCurveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: smcQueue)
        timer.schedule(
            deadline: .now() + FanCurveControlPolicy.standard.sampleInterval,
            repeating: FanCurveControlPolicy.standard.sampleInterval,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard let self, let fanCurveController else { return }
            do {
                let state = try fanCurveController.tick(at: Date())
                lastFanCurveRuntimeState = state
                forcedFanIDs = Set(state.targetRPMByFan.keys)
                forcedTargetRPMByFan = state.targetRPMByFan
            } catch let error as FanCurveError {
                failCurveControl(error)
            } catch {
                failCurveControl(.curveVerificationFailed)
            }
        }
        timer.resume()
        fanCurveTimer = timer
    }

    private func failure(
        _ message: String,
        operation: FanControlHelperRequest.Operation? = nil,
        errorCode: FanControlHelperErrorCode? = nil
    ) -> FanControlHelperReply {
        FanControlHelperReply(
            operation: operation,
            success: false,
            message: message,
            appliedTargetRPMByFan: [:],
            errorCode: errorCode
        )
    }

    private static func encoded(_ reply: FanControlHelperReply) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data(
            #"{"protocolVersion":4,"operation":null,"success":false,"message":"Reply encoding failed.","appliedTargetRPMByFan":{}}"#
                .utf8
        )
    }
}

// Apple Silicon fan-mode probing, unlock, and reset behavior is adapted from
// Stats (https://github.com/exelban/stats), MIT licensed, Copyright (c) 2019
// Serhiy Mytrovtsiy. The full license is in THIRD_PARTY_NOTICES.md.
final class SMCFanController {
    private enum Command: UInt8 {
        case kernelIndex = 2
        case readBytes = 5
        case writeBytes = 6
        case readKeyInfo = 9
    }

    private struct KeyData {
        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct LimitData {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: IOByteCount32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var version = Version()
        var limitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private struct Value {
        let key: String
        let dataType: String
        var bytes: [UInt8]

        var dataSize: UInt32 {
            UInt32(bytes.count)
        }
    }

    private var connection: io_connect_t = 0
    private var lastWriteFailure: String?
    private(set) var failureMessage: String?

    private static let cpuTemperatureKeys = [
        "TCMz", "TCMb", "TC0P", "TCHP", "TPMP",
        "TPDX", "TPD0", "TPD1", "TPD2", "TPD3", "TPD4", "TPD5", "TPD6", "TPD7",
        "TRDX", "TRD0", "TRD1", "TRD2", "TRD3", "TRD4", "TRD5", "TRD6", "TRD7",
        "TUDX", "TUD0", "TUD1", "TUD2", "TUD3", "TUD4", "TUD5", "TUD6", "TUD7",
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R",
        "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p",
    ]
    private static let performanceCoreTemperatureKeys = [
        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
        "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
    ]
    private static let gpuTemperatureKeys = [
        "TG0P", "TG0D", "TG0H", "TG0T", "TVDG",
        "Tg08", "Tg0C", "Tg0O", "Tg0R", "Tg0U", "Tg0X", "Tg0a", "Tg0d",
        "Tg0g", "Tg0j", "Tg12", "Tg16", "Tg1I", "Tg1M", "Tg1Q", "Tg1U",
        "Tg1Y", "Tg1c", "Tg1k", "Tg1o", "Tg1x",
    ]

    init?() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        guard IOServiceOpen(
            service,
            mach_task_self_,
            0,
            &openedConnection
        ) == kIOReturnSuccess else {
            return nil
        }
        connection = openedConnection
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func availableFanCount() -> Int {
        fanCount() ?? 0
    }

    func curveFanRange(fanID: Int) -> FanCurveFanRange? {
        guard validFanID(fanID),
              let actual = readDouble("F\(fanID)Ac").map(Int.init),
              let minimum = readDouble("F\(fanID)Mn").map(Int.init),
              let maximum = readDouble("F\(fanID)Mx").map(Int.init),
              actual >= 0,
              minimum >= 0,
              maximum > minimum else {
            return nil
        }
        return FanCurveFanRange(
            fanID: fanID,
            minimumRPM: minimum,
            maximumRPM: maximum,
            actualRPM: actual
        )
    }

    func availableFanCurveSensors() -> Set<FanCurveSensor> {
        Set(FanCurveSensor.allCases.filter { curveTemperature($0) != nil })
    }

    func curveTemperature(_ sensor: FanCurveSensor) -> Double? {
        let keys: [String]
        switch sensor {
        case .chipMaximum:
            keys = Self.cpuTemperatureKeys + Self.gpuTemperatureKeys
        case .cpu:
            keys = Self.cpuTemperatureKeys
        case .gpu:
            keys = Self.gpuTemperatureKeys
        case .performanceCore:
            keys = Self.performanceCoreTemperatureKeys
        case .efficiencyCore:
            // No stable AppleSMC efficiency-core key family is exposed on all
            // supported Macs. Keep this semantic unavailable instead of
            // guessing from a user-provided or model-specific key.
            return nil
        }
        let values = keys.compactMap(readDouble).filter {
            $0.isFinite && (5...130).contains($0)
        }
        return values.max()
    }

    func applyCoolingBoost(
        fanID: Int,
        requestedRPM: Int,
        allowsRPMDecrease: Bool
    ) -> Int? {
        failureMessage = nil
        guard validFanID(fanID) else {
            failureMessage = "Fan \(fanID) is not present on this Mac."
            return nil
        }
        guard let actual = readDouble("F\(fanID)Ac").map(Int.init),
              let minimum = readDouble("F\(fanID)Mn").map(Int.init),
              let maximum = readDouble("F\(fanID)Mx").map(Int.init),
              minimum >= 0,
              maximum > minimum else {
            failureMessage =
                "Could not read the real speed range for fan \(fanID)."
            return nil
        }
        guard (0...20_000).contains(requestedRPM) else {
            failureMessage = "Fan \(fanID) target is outside the safe range."
            return nil
        }

        // Only an explicit manual-mode request may lower the fan. Curve and
        // preset requests remain cooling overlays even if the hardware speed
        // changes between sampling and this privileged write.
        let safeFloor = allowsRPMDecrease ? minimum : max(actual, minimum)
        let safeTarget = min(maximum, max(safeFloor, requestedRPM))
        guard unlockFanControl(fanID: fanID) else {
            if failureMessage == nil {
                failureMessage =
                    "Could not enable manual control for fan \(fanID)."
            }
            return nil
        }
        guard writeFanTarget(fanID: fanID, targetRPM: safeTarget) else {
            if failureMessage == nil {
                failureMessage =
                    "Could not verify fan \(fanID) target \(safeTarget) RPM."
            }
            return nil
        }
        return safeTarget
    }

    func setAutomatic(fanID: Int) -> Bool {
        guard validFanID(fanID) else { return false }

        #if arch(arm64)
        let modeKey = fanModeKey(fanID)
        guard var mode = read(modeKey) else { return false }
        if mode.bytes.first != 0 {
            mode.bytes[0] = 0
            guard writeWithRetry(mode)
                    || read(modeKey)?.bytes.first == 0 else {
                return false
            }
        }
        guard var target = read("F\(fanID)Tg") else { return false }
        zeroFanTarget(&target)
        return writeWithRetry(target)
            || targetMatches(fanID: fanID, targetRPM: 0)
        #else
        if var mode = read("F\(fanID)Md") {
            mode.bytes[0] = 0
            guard write(mode) else { return false }
        }
        guard var forcedMask = read("FS! "),
              updateForcedMask(&forcedMask, fanID: fanID, forced: false) else {
            return false
        }
        return write(forcedMask)
        #endif
    }

    func restoreAllFans() -> Bool {
        guard let count = fanCount() else { return false }
        var success = true

        for fanID in 0..<count {
            success = setAutomatic(fanID: fanID) && success
        }

        #if arch(arm64)
        // Keep Ftst enabled until every fan has been returned to automatic
        // mode, then release the hardware-wide test latch once.
        if var testMode = read("Ftst"), testMode.bytes.first != 0 {
            testMode.bytes[0] = 0
            success = (
                writeWithRetry(testMode)
                    || read("Ftst")?.bytes.first == 0
            ) && success
        }
        #endif

        return success
    }

    func verifiesManualTargets(_ targets: [Int: Int]) -> Bool {
        !targets.isEmpty && targets.allSatisfy { fanID, targetRPM in
            validFanID(fanID)
                && isManualControlEnabled(fanID: fanID)
                && targetMatches(fanID: fanID, targetRPM: targetRPM)
        }
    }

    private func isManualControlEnabled(fanID: Int) -> Bool {
        #if arch(arm64)
        read(fanModeKey(fanID))?.bytes.first == 1
        #else
        guard let forcedMask = read("FS! ") else { return false }
        return forcedMaskContains(forcedMask, fanID: fanID)
        #endif
    }

    private func unlockFanControl(fanID: Int) -> Bool {
        #if arch(arm64)
        let modeKey = fanModeKey(fanID)
        guard var mode = read(modeKey) else {
            failureMessage =
                "Fan \(fanID) manual-mode key is unavailable."
            return false
        }
        mode.bytes[0] = 1
        if write(mode), read(modeKey)?.bytes.first == 1 {
            return true
        }
        if read(modeKey)?.bytes.first == 1 {
            // Some Apple Silicon firmware reports a write error even though
            // the requested mode landed. Only accept a real readback.
            lastWriteFailure = nil
            return true
        }

        guard var testMode = read("Ftst") else {
            failureMessage =
                "Fan \(fanID) manual-mode write failed"
                + diagnosticSuffix()
                + "; this firmware does not expose the Ftst unlock key."
            return false
        }
        if testMode.bytes.first != 1 {
            testMode.bytes[0] = 1
            guard writeWithRetry(testMode)
                    || read("Ftst")?.bytes.first == 1 else {
                failureMessage =
                    "Could not enable the AppleSMC Ftst unlock"
                    + diagnosticSuffix()
                    + "."
                return false
            }
        }
        // M3/M4 thermal management can take several seconds to release the
        // hardware-wide latch after Ftst is enabled. Yield before retrying so
        // repeated mode writes do not race that transition.
        usleep(3_000_000)

        for attempt in 0..<150 {
            guard var retryMode = read(modeKey) else {
                failureMessage =
                    "Fan \(fanID) manual-mode key disappeared during unlock."
                return false
            }
            retryMode.bytes[0] = 1
            if write(retryMode), read(modeKey)?.bytes.first == 1 {
                return true
            }
            if read(modeKey)?.bytes.first == 1 {
                lastWriteFailure = nil
                return true
            }
            if attempt < 149 {
                usleep(100_000)
            }
        }
        failureMessage =
            "Timed out enabling manual control for fan \(fanID)"
            + diagnosticSuffix()
            + "."
        return false
        #else
        guard var forcedMask = read("FS! "),
              updateForcedMask(&forcedMask, fanID: fanID, forced: true) else {
            return false
        }
        return write(forcedMask)
        #endif
    }

    private func writeFanTarget(fanID: Int, targetRPM: Int) -> Bool {
        let key = "F\(fanID)Tg"
        guard var value = read(key) else {
            failureMessage = "Fan \(fanID) target key is unavailable."
            return false
        }
        switch value.dataType {
        case "flt ":
            let bytes = withUnsafeBytes(of: Float(targetRPM)) { Array($0) }
            guard value.bytes.count >= 4 else {
                failureMessage =
                    "Fan \(fanID) target key has an invalid float size."
                return false
            }
            value.bytes.replaceSubrange(0..<4, with: bytes.prefix(4))
        case "fpe2":
            guard value.bytes.count >= 2 else {
                failureMessage =
                    "Fan \(fanID) target key has an invalid fpe2 size."
                return false
            }
            value.bytes[0] = UInt8(targetRPM >> 6)
            value.bytes[1] = UInt8(
                (targetRPM << 2) ^ ((targetRPM >> 6) << 8)
            )
        default:
            failureMessage =
                "Fan \(fanID) target format \(value.dataType) is unsupported."
            return false
        }

        for attempt in 0..<10 {
            _ = write(value)
            if targetMatches(fanID: fanID, targetRPM: targetRPM) {
                lastWriteFailure = nil
                return true
            }
            if attempt < 9 {
                usleep(50_000)
            }
        }
        let observed = readDouble(key).map {
            String(format: "%.0f", $0)
        } ?? "unavailable"
        failureMessage =
            "Fan \(fanID) target write was not verified"
            + diagnosticSuffix()
            + "; requested \(targetRPM) RPM, read back \(observed) RPM."
        return false
    }

    private func targetMatches(fanID: Int, targetRPM: Int) -> Bool {
        guard let observed = readDouble("F\(fanID)Tg"),
              observed.isFinite else {
            return false
        }
        let tolerance = max(25, Double(targetRPM) * 0.02)
        return abs(observed - Double(targetRPM)) <= tolerance
    }

    private func forcedMaskContains(_ value: Value, fanID: Int) -> Bool {
        guard fanID >= 0 else { return false }
        let byteOffset = fanID / 8
        guard byteOffset < value.bytes.count else { return false }
        let byteIndex = value.bytes.count - 1 - byteOffset
        return value.bytes[byteIndex] & UInt8(1 << (fanID % 8)) != 0
    }

    private func updateForcedMask(
        _ value: inout Value,
        fanID: Int,
        forced: Bool
    ) -> Bool {
        guard fanID >= 0 else { return false }
        let byteOffset = fanID / 8
        guard byteOffset < value.bytes.count else { return false }
        let byteIndex = value.bytes.count - 1 - byteOffset
        let bit = UInt8(1 << (fanID % 8))
        if forced {
            value.bytes[byteIndex] |= bit
        } else {
            value.bytes[byteIndex] &= ~bit
        }
        return true
    }

    private func diagnosticSuffix() -> String {
        guard let lastWriteFailure else { return "" }
        return " (\(lastWriteFailure))"
    }

    private func zeroFanTarget(_ value: inout Value) {
        switch value.dataType {
        case "flt ":
            let bytes = withUnsafeBytes(of: Float(0)) { Array($0) }
            if value.bytes.count >= 4 {
                value.bytes.replaceSubrange(0..<4, with: bytes.prefix(4))
            }
        case "fpe2":
            if value.bytes.count >= 2 {
                value.bytes[0] = 0
                value.bytes[1] = 0
            }
        default:
            break
        }
    }

    private func fanModeKey(_ fanID: Int) -> String {
        #if arch(arm64)
        let lowerCaseKey = "F\(fanID)md"
        return read(lowerCaseKey) != nil ? lowerCaseKey : "F\(fanID)Md"
        #else
        return "F\(fanID)Md"
        #endif
    }

    private func validFanID(_ fanID: Int) -> Bool {
        guard let fanCount = fanCount() else { return false }
        return (0..<fanCount).contains(fanID)
    }

    private func fanCount() -> Int? {
        guard let value = readDouble("FNum"),
              value.isFinite,
              (1...16).contains(value) else {
            return nil
        }
        return Int(value.rounded(.down))
    }

    private func readDouble(_ key: String) -> Double? {
        guard let value = read(key) else { return nil }
        switch value.dataType {
        case "ui8 ":
            return value.bytes.first.map(Double.init)
        case "ui16":
            guard value.bytes.count >= 2 else { return nil }
            return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
        case "ui32":
            guard value.bytes.count >= 4 else { return nil }
            return Double(
                UInt32(value.bytes[0]) << 24
                    | UInt32(value.bytes[1]) << 16
                    | UInt32(value.bytes[2]) << 8
                    | UInt32(value.bytes[3])
            )
        case "flt ":
            guard value.bytes.count >= 4 else { return nil }
            let raw = UInt32(value.bytes[0])
                | UInt32(value.bytes[1]) << 8
                | UInt32(value.bytes[2]) << 16
                | UInt32(value.bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "fpe2":
            guard value.bytes.count >= 2 else { return nil }
            return Double(
                (Int(value.bytes[0]) << 6) + (Int(value.bytes[1]) >> 2)
            )
        default:
            return nil
        }
    }

    private func read(_ key: String) -> Value? {
        guard let keyCode = keyCode(key) else { return nil }
        var input = KeyData()
        var output = KeyData()
        input.key = keyCode
        input.data8 = Command.readKeyInfo.rawValue

        guard call(input: &input, output: &output) == kIOReturnSuccess,
              output.result == 0,
              output.keyInfo.dataSize > 0,
              output.keyInfo.dataSize <= 32 else {
            return nil
        }

        let dataSize = output.keyInfo.dataSize
        let dataType = output.keyInfo.dataType.smcString
        input.keyInfo.dataSize = dataSize
        input.data8 = Command.readBytes.rawValue
        guard call(input: &input, output: &output) == kIOReturnSuccess,
              output.result == 0 else {
            return nil
        }

        let bytes = withUnsafeBytes(of: output.bytes) {
            Array($0.prefix(Int(dataSize)))
        }
        return Value(
            key: key,
            dataType: dataType,
            bytes: bytes
        )
    }

    private func write(_ value: Value) -> Bool {
        guard let code = keyCode(value.key),
              !value.bytes.isEmpty,
              value.bytes.count <= 32 else {
            lastWriteFailure = "\(value.key): invalid payload"
            return false
        }

        var bytes = value.bytes
        bytes.append(contentsOf: repeatElement(0, count: 32 - bytes.count))
        var input = KeyData()
        var output = KeyData()
        input.key = code
        input.data8 = Command.writeBytes.rawValue
        input.keyInfo.dataSize = IOByteCount32(value.dataSize)
        input.bytes = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
            bytes[16], bytes[17], bytes[18], bytes[19],
            bytes[20], bytes[21], bytes[22], bytes[23],
            bytes[24], bytes[25], bytes[26], bytes[27],
            bytes[28], bytes[29], bytes[30], bytes[31]
        )
        let ioResult = call(input: &input, output: &output)
        guard ioResult == kIOReturnSuccess else {
            lastWriteFailure = String(
                format: "%@: IOKit 0x%08x",
                value.key,
                UInt32(bitPattern: ioResult)
            )
            return false
        }
        guard output.result == 0 else {
            lastWriteFailure = String(
                format: "%@: firmware 0x%02x",
                value.key,
                output.result
            )
            return false
        }
        lastWriteFailure = nil
        return true
    }

    private func writeWithRetry(
        _ value: Value,
        attempts: Int = 10,
        delayMicroseconds: useconds_t = 50_000
    ) -> Bool {
        for attempt in 0..<attempts {
            if write(value) { return true }
            if attempt < attempts - 1 {
                usleep(delayMicroseconds)
            }
        }
        return false
    }

    private func call(
        input: inout KeyData,
        output: inout KeyData
    ) -> kern_return_t {
        var outputSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(
            connection,
            UInt32(Command.kernelIndex.rawValue),
            &input,
            MemoryLayout<KeyData>.stride,
            &output,
            &outputSize
        )
    }

    private func keyCode(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) {
            $0 << 8 | UInt32($1)
        }
    }
}

private enum CodeSigningCheckError: Error {
    case failed(OSStatus)
}

enum CodeSigningCheck {
    private static let mainApplicationIdentifier =
        StorageCleanerBuildIdentity.appBundleIdentifier

    static func auditToken(for connection: NSXPCConnection) -> audit_token_t? {
        let raw = connection.value(forKey: "auditToken")
        var token = audit_token_t()
        if let value = raw as? NSValue {
            withUnsafeMutableBytes(of: &token) {
                value.getValue($0.baseAddress!, size: $0.count)
            }
            return token
        }
        if let data = raw as? Data,
           data.count == MemoryLayout<audit_token_t>.size {
            _ = withUnsafeMutableBytes(of: &token) {
                data.copyBytes(to: $0)
            }
            return token
        }
        return nil
    }

    static func clientMatchesHelper(auditToken: audit_token_t, helperIdentity: SigningIdentity) throws -> Bool {
        let clientIdentity = try signingIdentity(for: auditToken)
        return HelperClientSigningPolicy.permits(
            helperCertificates: helperIdentity.certificates.map { SecCertificateCopyData($0) as Data },
            clientCertificates: clientIdentity.certificates.map { SecCertificateCopyData($0) as Data },
            clientIdentifier: clientIdentity.identifier, expectedIdentifier: mainApplicationIdentifier)
    }

    struct StartupIdentity {
        let signing: SigningIdentity
        let executableURL: URL
        let stamp: HelperExecutableStamp
    }

    static func captureStartupIdentity() throws -> StartupIdentity? {
        // A daemon embedded in Contents/Resources must identify its process
        // image, not rely on Foundation's interpretation of the enclosing app.
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0, size <= 65_536 else { return nil }
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let imagePath = String(bytes: bytes, encoding: .utf8) else { return nil }
        let url = URL(fileURLWithPath: imagePath).standardizedFileURL
        guard let before = HelperExecutableStamp.read(at: url) else { return nil }
        let signing = try signingIdentityForSelf()
        guard !signing.certificates.isEmpty, signing.codeHash?.isEmpty == false,
              signing.executableURL?.standardizedFileURL.path == url.standardizedFileURL.path,
              HelperExecutableStamp.read(at: url) == before else { return nil }
        return .init(signing: signing, executableURL: url, stamp: before)
    }

    struct ReplacementIdentity: Equatable, Sendable {
        let stamp: HelperExecutableStamp
        let codeHash: Data
        let build: HelperSignedBuildVersion
    }

    static func shouldYieldToReplacement(auditToken: audit_token_t, startup: StartupIdentity) throws -> ReplacementIdentity? {
        guard try powerSamplingClientIdentityMatches(auditToken: auditToken),
              try powerSamplingClientSealIsValid(auditToken: auditToken) else { return nil }
        return try validatedReplacement(startup: startup)
    }

    static func validatedReplacement(startup: StartupIdentity) throws -> ReplacementIdentity? {
        let expectedPath = StorageCleanerBuildIdentity.installedApplicationPath
            + "/Contents/Resources/StorageCleanerFanControlHelper"
        guard startup.executableURL.standardizedFileURL.path == expectedPath,
              let stamp = HelperExecutableStamp.read(at: startup.executableURL), stamp != startup.stamp,
              startup.signing.teamIdentifier == PowermetricsClientPolicy.teamIdentifier else { return nil }
        // Validate the replacement itself with full resources and the original
        // signing chain; metadata alone must not permit an unsigned swap/DoS.
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(startup.executableURL as CFURL, [], &code))
        guard let code else { return nil }
        try check(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil))
        let replacement = try signingIdentity(for: code)
        let replacementValid = replacement.identifier == StorageCleanerBuildIdentity.helperLabel
            && replacement.teamIdentifier == startup.signing.teamIdentifier
            && replacement.certificates == startup.signing.certificates
            && replacement.executableURL?.standardizedFileURL.path == expectedPath
            && HelperExecutableStamp.read(at: startup.executableURL) == stamp
        guard HelperUpgradeSafety.shouldYield(originalClientValid: true, installedTeamClientValid: true,
            startupStamp: startup.stamp, currentStamp: stamp,
            runningCodeHash: startup.signing.codeHash, replacementCodeHash: replacement.codeHash,
            runningBuild: startup.signing.signedBuild, replacementBuild: replacement.signedBuild,
            replacementSignatureValid: replacementValid),
              let build = replacement.signedBuild, let hash = replacement.codeHash else { return nil }
        return ReplacementIdentity(stamp: stamp, codeHash: hash, build: build)
    }

    static func clientProcess(of auditToken: audit_token_t) -> PowermetricsClientGate.ClientProcess {
        // Same fields libbsm's audit_token_to_pid/_pidversion read (val[5], val[7]);
        // read directly so the helper does not need to link libbsm.
        PowermetricsClientGate.ClientProcess(pid: Int32(bitPattern: auditToken.val.5),
                                             pidVersion: Int32(bitPattern: auditToken.val.7))
    }

    private static func powerSamplingGuestCode(auditToken: audit_token_t) throws -> (SecCode, SecStaticCode)? {
        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) } as CFData
        var code: SecCode?
        try check(SecCodeCopyGuestWithAttributes(nil,
            [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code))
        guard let code else { return nil }
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code, [], &staticCode))
        guard let staticCode else { return nil }
        return (code, staticCode)
    }

    /// Cheap relative to the full seal: dynamic validity of the running code,
    /// then identifier, team and installed paths from its signing information.
    static func powerSamplingClientIdentityMatches(auditToken: audit_token_t) throws -> Bool {
        guard let (code, staticCode) = try powerSamplingGuestCode(auditToken: auditToken) else { return false }
        try check(SecCodeCheckValidity(code, [], nil))
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        let values = information as? [String: Any]
        guard let identifier = values?[kSecCodeInfoIdentifier as String] as? String,
              let team = values?[kSecCodeInfoTeamIdentifier as String] as? String,
              let executable = values?[kSecCodeInfoMainExecutable as String] as? URL else { return false }
        return PowermetricsClientPolicy.permits(identifier: identifier, team: team, executableURL: executable,
            helperApplicationURL: MacMiniApplicationIdentity.applicationURL(executableURL: Bundle.main.executableURL))
    }

    /// Expensive (tens of ms or more): full static seal, including resources
    /// and nested code. Cached per connection and process instance by the gate.
    static func powerSamplingClientSealIsValid(auditToken: audit_token_t) throws -> Bool {
        guard let (_, staticCode) = try powerSamplingGuestCode(auditToken: auditToken) else { return false }
        try check(SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckNestedCode), nil))
        return true
    }

    static func macMiniExpectedIdentity(at url: URL, applicationIdentifier: String = mainApplicationIdentifier) throws -> MacMiniApplicationIdentity? {
        let helper = try signingIdentityForSelf()
        guard !helper.certificates.isEmpty else { return nil }
        let identity: String
        if !helper.teamIdentifier.isEmpty {
            identity = "team:" + helper.teamIdentifier
        } else {
            var ownCode: SecCode?
            try check(SecCodeCopySelf([], &ownCode))
            guard let ownCode else { return nil }
            var ownStaticCode: SecStaticCode?
            try check(SecCodeCopyStaticCode(ownCode, [], &ownStaticCode))
            guard let ownStaticCode else { return nil }
            var requirement: SecRequirement?
            try check(SecCodeCopyDesignatedRequirement(ownStaticCode, [], &requirement))
            guard let requirement else { return nil }
            var string: CFString?
            try check(SecRequirementCopyString(requirement, [], &string))
            guard let string else { return nil }
            let ownClause = "identifier \"\(helper.identifier)\""
            let appClause = "identifier \"\(applicationIdentifier)\""
            let ownText = string as String
            guard ownText.contains(ownClause) else { return nil }
            identity = "requirement:" + ownText.replacingOccurrences(of: ownClause, with: appClause)
        }
        return MacMiniApplicationIdentity(installationPath: url.standardizedFileURL.path, signingIdentity: identity)
    }

    /// Unknown Security/I/O errors are retryable, not signing mismatches.
    static func validateMacMiniApplication(_ expected: MacMiniApplicationIdentity,
                                           identifier: String) -> Bool? {
        let url = URL(fileURLWithPath: expected.installationPath)
        do {
            let application = try signingIdentity(at: url)
            guard !application.identifier.isEmpty else { return nil }
            let helperTeam: String
            var satisfiesRequirement = false
            if expected.signingIdentity.hasPrefix("team:") {
                helperTeam = String(expected.signingIdentity.dropFirst("team:".count))
            } else if expected.signingIdentity.hasPrefix("requirement:") {
                helperTeam = ""
                let text = String(expected.signingIdentity.dropFirst("requirement:".count))
                var requirement: SecRequirement?
                try check(SecRequirementCreateWithString(text as CFString, [], &requirement))
                var code: SecStaticCode?
                try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
                guard let code, let requirement else { return nil }
                try check(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement))
                satisfiesRequirement = true
            } else { return false }
            return MacMiniApplicationTrust.matches(
                applicationIdentifier: application.identifier, expectedIdentifier: identifier,
                applicationTeam: application.teamIdentifier, helperTeam: helperTeam,
                satisfiesDesignatedRequirement: satisfiesRequirement
            )
        } catch CodeSigningCheckError.failed(let status) {
            // These Security statuses prove mismatch. Missing resources and
            // other intermittent reads remain unknown until a later retry.
            if [errSecCSUnsigned, errSecCSSignatureFailed, errSecCSReqFailed].contains(status) { return false }
            return nil
        } catch { return nil }
    }

    struct SigningIdentity {
        let identifier: String
        let teamIdentifier: String
        let certificates: [SecCertificate]
        let executableURL: URL?
        let codeHash: Data?
        let signedBuild: HelperSignedBuildVersion?
        init(identifier: String, teamIdentifier: String, certificates: [SecCertificate], executableURL: URL? = nil, codeHash: Data? = nil, signedBuild: HelperSignedBuildVersion? = nil) {
            self.identifier = identifier; self.teamIdentifier = teamIdentifier
            self.certificates = certificates; self.executableURL = executableURL; self.codeHash = codeHash
            self.signedBuild = signedBuild
        }
    }

    static func signingIdentity(at url: URL) throws -> SigningIdentity {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        guard let code else {
            return SigningIdentity(identifier: "", teamIdentifier: "", certificates: [])
        }
        return try signingIdentity(for: code)
    }

    private static func signingIdentityForSelf() throws -> SigningIdentity {
        var code: SecCode?
        try check(SecCodeCopySelf([], &code))
        guard let code else {
            return SigningIdentity(identifier: "", teamIdentifier: "", certificates: [])
        }
        try check(SecCodeCheckValidity(code, [], nil))
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code, [], &staticCode))
        guard let staticCode else {
            return SigningIdentity(identifier: "", teamIdentifier: "", certificates: [])
        }
        return try signingIdentity(for: staticCode)
    }

    private static func signingIdentity(
        for auditToken: audit_token_t
    ) throws -> SigningIdentity {
        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) } as CFData
        var code: SecCode?
        try check(SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributeAudit: tokenData] as CFDictionary,
            [],
            &code
        ))
        guard let code else {
            return SigningIdentity(identifier: "", teamIdentifier: "", certificates: [])
        }
        // D102 L1: the running client, not only its file, must still be valid.
        try check(SecCodeCheckValidity(code, [], nil))
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code, [], &staticCode))
        guard let staticCode else {
            return SigningIdentity(identifier: "", teamIdentifier: "", certificates: [])
        }
        return try signingIdentity(for: staticCode)
    }

    private static func signingIdentity(
        for code: SecStaticCode
    ) throws -> SigningIdentity {
        try check(SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckNestedCode),
            nil
        ))
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ))
        let values = information as? [String: Any]
        // Security's signing information for the standalone executable uses
        // its embedded __TEXT,__info_plist. Never read the enclosing App plist,
        // BuildInfo.plist, a sidecar or an XPC-provided version as authority.
        let signedInfo = values?[kSecCodeInfoPList as String] as? [String: Any]
        let signedBuild: HelperSignedBuildVersion?
        if signedInfo?["CFBundleIdentifier"] as? String == StorageCleanerBuildIdentity.helperLabel,
           let text = signedInfo?["CFBundleVersion"] as? String {
            signedBuild = HelperSignedBuildVersion(text)
        } else { signedBuild = nil }
        return SigningIdentity(
            identifier: values?[kSecCodeInfoIdentifier as String] as? String ?? "",
            teamIdentifier: values?[kSecCodeInfoTeamIdentifier as String] as? String ?? "",
            certificates: values?[
                kSecCodeInfoCertificates as String
            ] as? [SecCertificate] ?? [],
            executableURL: values?[kSecCodeInfoMainExecutable as String] as? URL,
            codeHash: values?[kSecCodeInfoUnique as String] as? Data,
            signedBuild: signedBuild
        )
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw CodeSigningCheckError.failed(status)
        }
    }
}

private extension UInt32 {
    var smcString: String {
        String(bytes: [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff),
        ], encoding: .utf8) ?? ""
    }
}

private let fanControlHelperDaemon = FanControlHelperDaemon()
fanControlHelperDaemon.run()
