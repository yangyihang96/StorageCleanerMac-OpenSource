import AppKit
import Combine
import FanControlShared
import Foundation
import os
@preconcurrency import ServiceManagement

@objc protocol FanControlHelperProtocol {
    func execute(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    )
}

enum FanControlHelperStatus: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case needsMigration
    case unavailable

    var title: String {
        switch self {
        case .notRegistered:
            L10n.text("尚未启用", "Not Enabled")
        case .requiresApproval:
            L10n.text("等待系统批准", "Awaiting System Approval")
        case .enabled:
            L10n.text("已安装", "Installed")
        case .needsMigration:
            L10n.text("需要迁移旧版辅助程序", "Legacy Helper Migration Required")
        case .unavailable:
            L10n.text("辅助程序不可用", "Helper Unavailable")
        }
    }

    static var unavailableReadOnlyDetail: String {
        L10n.text(
            "macOS 未识别 App 包内的高级硬件控制服务。LaunchDaemon 需要 Developer ID 签名并完成 Apple 公证；服务缺失或签名无效时也会保持只读。",
            "macOS did not recognize the bundled advanced hardware-control service. LaunchDaemons require Developer ID signing and Apple notarization; a missing or invalidly signed helper also remains read-only."
        )
    }
}

@MainActor
final class FanControlCoordinator: ObservableObject {
    static let shared = FanControlCoordinator()
    static let helperLabel = StorageCleanerBuildIdentity.helperLabel
    static let helperPlistName = "\(helperLabel).plist"
    private(set) var isDataOnlyFixture = false
    private var startupRecoveryFailureLatched = false
    @Published private(set) var macMiniModeStatus: MacMiniModeStatus?
    @Published private(set) var macMiniModeMessage: String?
    @Published private(set) var isChangingMacMiniMode = false
    @Published private(set) var macMiniHelperNeedsUpdate = false
    private var isReadingMacMiniMode = false
    private var macMiniIntentGeneration: UInt64 = 0
    private var fixtureHelperState: HelperState?

#if DEBUG || STORAGE_CLEANER_BETA
    /// Supplies display data to the production palette without installing
    /// lifecycle observers, connecting to XPC, or requesting a hardware mode.
    static func makeReadOnlyFixture(
        defaults: UserDefaults,
        profile: MiniWindowDemoData.HardwareControlDemoProfile,
        snapshot: SystemMonitorSnapshot
    ) -> FanControlCoordinator {
        let helperStatus: FanControlHelperStatus
        switch profile.helperState {
        case .enabled, .connectionInterrupted: helperStatus = .enabled
        case .notRegistered: helperStatus = .notRegistered
        case .requiresApproval: helperStatus = .requiresApproval
        case .signatureRejected, .unavailable: helperStatus = .unavailable
        }
        let coordinator = FanControlCoordinator(
            defaults: defaults,
            helperStatusOverride: helperStatus,
            isHelperReachable: profile.helperState == .enabled,
            now: { snapshot.generatedAt },
            requestSender: { _ in throw CancellationError() },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false },
            serviceStatusProvider: { .notRegistered },
            serviceRegistrar: { throw CancellationError() }
        )
        coordinator.isDataOnlyFixture = true
        coordinator.fixtureHelperState = profile.helperState
        coordinator.latestSnapshot = snapshot
        coordinator.availableCurveSensors = availableCurveSensors(in: snapshot)
        if let curve = profile.curveProfile {
            if profile.observedMode == .customCurve {
                coordinator.curveStore.markApplied(curve)
            } else {
                _ = coordinator.curveStore.replaceDraft(curve)
            }
        }
        coordinator.curvePreviewTemperature = temperature(
            for: coordinator.curveStore.draftProfile.sensor, in: snapshot
        )
        coordinator.curveRuntimeState = profile.curveRuntimeState
        // This is explicitly simulated readback, never a control request or a
        // claim about the host Mac. No LIVE verification-expiry task is started.
        coordinator.observedMode = profile.observedMode
        coordinator.lastMessage = profile.message
        return coordinator
    }
#endif

    @Published private(set) var helperStatus: FanControlHelperStatus
    @Published private(set) var bundledHelperSigningIsTrusted: Bool?
    @Published private(set) var isHelperReachable = false
    @Published private(set) var isRefreshingConnection = false
    @Published private(set) var helperConnectionNeedsAttention = false
    @Published private(set) var isApplying = false
    @Published private(set) var isSwitchingMode = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var observedMode: GeekFanControlMode?
    @Published private(set) var requestedMode: GeekFanControlMode?
    @Published private(set) var synchronizesManualFans = true
    @Published private(set) var manualFractionByFan: [Int: Double] = [:]
    @Published private(set) var confirmedManualFractionByFan: [Int: Double] = [:]
    @Published private(set) var curveRuntimeState = FanCurveRuntimeState.inactive
    @Published private(set) var availableCurveSensors: [FanCurveSensor] = []
    @Published private(set) var curvePreviewTemperature: Double?
    let curveStore: FanCurveStore
    @Published var selectedMode: GeekFanControlMode {
        didSet {
            if selectedMode != oldValue {
                clearObservedMode()
            }
            let persistedMode = selectedMode == .manual || selectedMode == .maximum
                ? GeekFanControlMode.systemAutomatic
                : selectedMode
            defaults.set(
                persistedMode.rawValue,
                forKey: FanControlPreferences.modeKey
            )
        }
    }
    @Published var selectedFanSet: FanControlSet {
        didSet {
            defaults.set(selectedFanSet.rawValue, forKey: FanControlPreferences.setKey)
        }
    }
    @Published var manualFraction: Double {
        didSet {
            defaults.set(
                Self.normalizedFraction(manualFraction),
                forKey: FanControlPreferences.manualFractionKey
            )
        }
    }
    @Published private(set) var curveConfiguration: FanCurveConfiguration {
        didSet {
            guard let data = try? JSONEncoder().encode(curveConfiguration) else { return }
            defaults.set(data, forKey: FanControlPreferences.curveConfigurationKey)
            defaults.set(
                curveLowTemperature,
                forKey: FanControlPreferences.curveLowTemperatureKey
            )
            defaults.set(
                curveHighTemperature,
                forKey: FanControlPreferences.curveHighTemperatureKey
            )
        }
    }

    var curveLowTemperature: Double {
        curveConfiguration.sharedPoints.first?.temperatureCelsius
            ?? FanControlPreferences.defaultCurveLowTemperature
    }

    var curveHighTemperature: Double {
        curveConfiguration.sharedPoints.last?.temperatureCelsius
            ?? FanControlPreferences.defaultCurveHighTemperature
    }

    var hasTrustedHelper: Bool {
        helperStatus == .enabled && isHelperReachable
    }

    var latestFanReadings: [SystemFanReading] {
        latestSnapshot?.fanReadings ?? []
    }

    /// Resolves the selected draft source from the existing sample. This is a
    /// read-only projection: no sampling, state mutation or Helper request.
    func previewTemperature(for sensor: FanCurveSensor) -> Double? {
        guard let latestSnapshot else { return nil }
        return Self.temperature(for: sensor, in: latestSnapshot)
    }

    func previewPercentage(for profile: FanCurveProfile? = nil) -> Double? {
        guard let temperature = curvePreviewTemperature else { return nil }
        return FanCurveInterpolator.percentage(
            at: temperature,
            points: (profile ?? curveStore.draftProfile).points
        )
    }

    func previewTargetRPMByFan(for profile: FanCurveProfile? = nil) -> [Int: Int]? {
        guard let percentage = previewPercentage(for: profile) else { return nil }
        let ranges = latestFanReadings.compactMap(Self.curveRange)
        guard ranges.count == latestFanReadings.count,
              !ranges.isEmpty else { return nil }
        return try? FanCurveRPMMapper.targets(percentage: percentage, ranges: ranges)
    }

    var helperState: HelperState {
        if let fixtureHelperState { return fixtureHelperState }
        return switch helperStatus {
        case .notRegistered:
            .notRegistered
        case .requiresApproval:
            .requiresApproval
        case .enabled:
            isHelperReachable ? .enabled : .connectionInterrupted
        case .needsMigration:
            .unavailable
        case .unavailable:
            Self.bundledHelperURL != nil && bundledHelperSigningIsTrusted == false
                ? .signatureRejected
                : .unavailable
        }
    }

    private let defaults: UserDefaults
    private let service: SMAppService
    private let legacyArtifactsPresentProvider: () -> Bool
    private let legacyArtifactsCurrentProvider: () -> Bool
    private let legacyArtifactsSafeForRemovalProvider: () -> Bool
    private let legacyUninstaller: () async throws -> Void
    private let serviceStatusProvider: (() -> SMAppService.Status)?
    private let serviceRegistrar: (() throws -> Void)?
    private let approvalSettingsOpener: () -> Void
    private let serviceUnregistrar: (() async throws -> Void)?
    private let now: @MainActor () -> Date
    private let reconnectClock: @MainActor () -> TimeInterval
    private let reconnectJitter: @MainActor () -> Double
    private let automaticallyReconnect: Bool
    private let reconnectSleeper: @MainActor (TimeInterval) async throws -> Void
    private let requestSender:
        (@MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply)?
    private let helperRequestTimeout: TimeInterval
    private let fanWriteRequestTimeout: TimeInterval
    private static let logger = Logger(
        subsystem: StorageCleanerBuildIdentity.appBundleIdentifier,
        category: "HardwareControl"
    )
    private static let bundledHelperURL = Bundle.main.url(
        forResource: LegacyFanControlHelperInstaller.bundledHelperName,
        withExtension: nil
    )
    private static let bundledHelperSigningTrustTask: Task<Bool, Never> = {
        let helperURL = bundledHelperURL
        let appURL = Bundle.main.bundleURL
        return Task.detached(priority: .utility) {
            guard let helperURL,
              let appIdentity = LegacyFanControlHelperInstaller.signingIdentity(
                  at: appURL
              ),
              let helperIdentity = LegacyFanControlHelperInstaller.signingIdentity(
                  at: helperURL
              ) else {
                return false
            }
            return LegacyFanControlHelperInstaller.bundledSigningContractIsTrusted(
                app: appIdentity,
                bundledHelper: helperIdentity
            )
        }
    }()
    private var connection: NSXPCConnection?
    private var connectionGeneration: UInt64 = 0
    private var reconnectRequiresAutomaticRestore = false
    private var reconnectBackoff = HelperReconnectBackoff()
    private var manualReconnectCooldown = HelperManualReconnectCooldown()
    private var manualReconnectCountdownTask: Task<Void, Never>?
    @Published private var manualReconnectClockTick: TimeInterval = 0
    private var reconnectInFlight = false
    private var automaticReconnectTask: Task<Void, Never>?
    private var reconnectScheduleGeneration: UInt64 = 0
    private var didOpenApprovalSettingsAutomatically = false
    @Published private(set) var isPreparingHelper = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var restoreRecoveryTask: Task<Void, Never>?
    private var observedModeExpiryTask: Task<Void, Never>?
    private var observedModeVerifiedAt: Date?
    private var lastApplyDate: Date?
    private var lastLeaseRenewalDate: Date?
    private var lastAppliedTargets: [Int: Int] = [:]
    private var lastAutomaticFanIDs: [Int] = []
    private var lastAppliedHardwareRanges: [Int: AppliedHardwareRange] = [:]
    private var curveTemperatureAnchor: Double?
    private var latestSnapshot: SystemMonitorSnapshot?
    private var manualCommitPending = false
    private var manualCommitTask: Task<Void, Never>?
    private var curveLeaseID: UUID?
    private var curveStatusRequestPending = false
    private var lastCurveStatusRead: Date?
    private var controlIntentGeneration: UInt64 = 0
    private var pendingControlIntent: FanControlIntentRequest?
    private var controlIntentTask: Task<Void, Never>?

    private enum FanControlIntent {
        case selectMode(GeekFanControlMode)
        case applyCurveDraft
    }

    private struct FanControlIntentRequest {
        let generation: UInt64
        let intent: FanControlIntent
    }

    private struct AppliedHardwareRange: Equatable {
        let minimumRPM: Int
        let maximumRPM: Int
    }

    init(
        defaults: UserDefaults = .standard,
        helperStatusOverride: FanControlHelperStatus? = nil,
        isHelperReachable: Bool = false,
        now: @escaping @MainActor () -> Date = { Date() },
        requestSender:
            (@MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply)? = nil,
        reconnectClock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        reconnectJitter: @escaping @MainActor () -> Double = { Double.random(in: 0...1) },
        automaticallyReconnect: Bool = true,
        reconnectSleeper: @escaping @MainActor (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        helperRequestTimeout: TimeInterval = FanControlSafetyPolicy.helperRequestTimeout,
        fanWriteRequestTimeout: TimeInterval = FanControlSafetyPolicy.fanWriteRequestTimeout,
        curveStore: FanCurveStore? = nil,
        legacyArtifactsPresentProvider: @escaping () -> Bool = {
            LegacyFanControlHelperInstaller.installedArtifactsPresent()
        },
        legacyArtifactsCurrentProvider: @escaping () -> Bool = {
            LegacyFanControlHelperInstaller.installedArtifactsCurrent()
        },
        legacyArtifactsSafeForRemovalProvider: @escaping () -> Bool = {
            LegacyFanControlHelperInstaller.installedArtifactsSafeForRemoval()
        },
        legacyUninstaller: @escaping () async throws -> Void = {
            throw LegacyFanControlHelperInstallerError.installedArtifactsMismatch
        },
        serviceStatusProvider: (() -> SMAppService.Status)? = nil,
        serviceRegistrar: (() throws -> Void)? = nil,
        serviceUnregistrar: (() async throws -> Void)? = nil,
        approvalSettingsOpener: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.defaults = defaults
        self.legacyArtifactsPresentProvider = legacyArtifactsPresentProvider
        self.legacyArtifactsCurrentProvider = legacyArtifactsCurrentProvider
        self.legacyArtifactsSafeForRemovalProvider = legacyArtifactsSafeForRemovalProvider
        self.legacyUninstaller = legacyUninstaller
        self.serviceStatusProvider = serviceStatusProvider
        self.serviceRegistrar = serviceRegistrar
        self.serviceUnregistrar = serviceUnregistrar
        self.approvalSettingsOpener = approvalSettingsOpener
        self.now = now
        self.reconnectClock = reconnectClock
        self.reconnectJitter = reconnectJitter
        self.automaticallyReconnect = automaticallyReconnect
        self.reconnectSleeper = reconnectSleeper
        self.requestSender = requestSender
        self.helperRequestTimeout = helperRequestTimeout
        self.fanWriteRequestTimeout = fanWriteRequestTimeout
        self.curveStore = curveStore ?? FanCurveStore(defaults: defaults)
        service = SMAppService.daemon(plistName: Self.helperPlistName)
        helperStatus = helperStatusOverride ?? Self.resolvedStatus(service.status)
        bundledHelperSigningIsTrusted = nil
        self.isHelperReachable = isHelperReachable
        selectedFanSet = FanControlSet(
            rawValue: defaults.string(forKey: FanControlPreferences.setKey) ?? ""
        ) ?? .balanced
        manualFraction = Self.storedDouble(
            defaults,
            key: FanControlPreferences.manualFractionKey,
            fallback: FanControlPreferences.defaultManualFraction
        )
        let legacyCurveLowTemperature = Self.storedDouble(
            defaults,
            key: FanControlPreferences.curveLowTemperatureKey,
            fallback: FanControlPreferences.defaultCurveLowTemperature
        )
        let legacyCurveHighTemperature = Self.storedDouble(
            defaults,
            key: FanControlPreferences.curveHighTemperatureKey,
            fallback: FanControlPreferences.defaultCurveHighTemperature
        )
        curveConfiguration = Self.storedCurveConfiguration(
            defaults,
            legacyLowTemperature: legacyCurveLowTemperature,
            legacyHighTemperature: legacyCurveHighTemperature
        )
        // Every new app session requests automatic control, but the observed
        // hardware mode stays unknown until a fresh verified SMC readback.
        selectedMode = .systemAutomatic
        if helperStatusOverride == nil {
            helperStatus = currentHelperStatus()
        }
        if requestSender == nil {
            installLifecycleObservers()
            scheduleAutomaticReconnect(initial: true)
        }
    }

    /// Compatibility for availability/UI readers: cached state only. Explicit
    /// connection/registration actions own service queries and publication.
    func refreshStatus() {}

    func refreshConnection() async {
        guard !isDataOnlyFixture else { return }
        expireObservedModeIfNeeded()
    }

    private func refreshRegistrationStatus() {
        guard !isDataOnlyFixture else { return }
        let resolvedStatus = currentHelperStatus()
        if helperStatus != resolvedStatus {
            helperStatus = resolvedStatus
            Self.logger.info(
                "Hardware helper status changed to \(String(describing: self.helperStatus), privacy: .public)"
            )
        }
        if resolvedStatus != .enabled {
            clearObservedMode()
            if isHelperReachable {
                isHelperReachable = false
            }
            if selectedMode != .systemAutomatic {
                selectedMode = .systemAutomatic
            }
        }
    }

    /// A failed process cannot be restarted by ping. Hide the retry action;
    /// removal followed by fresh authorization is the explicit recovery path.
    var offersHelperReconnect: Bool { !startupRecoveryFailureLatched }
    var offersHelperConnectionAction: Bool {
        offersHelperReconnect || [.notRegistered, .requiresApproval, .unavailable].contains(helperState)
    }

    func connectHelper() async {
        guard !isDataOnlyFixture else { return }
        guard !startupRecoveryFailureLatched else {
            lastMessage = Self.startupRecoveryFailureMessage
            return
        }
        guard !isRefreshingConnection, !isPreparingHelper, !reconnectInFlight,
              reconnectBackoff.permitsAttempt(at: reconnectClock()) else { return }
        isRefreshingConnection = true
        defer {
            isRefreshingConnection = false
            scheduleAutomaticReconnect()
        }
        _ = await resolveBundledHelperSigningTrust()
        refreshRegistrationStatus()
        guard helperStatus == .enabled else { return }
        do {
            let reply = try await waitForHelper()
            if isHelperReachable != reply.success {
                isHelperReachable = reply.success
            }
            if !reply.success {
                failClosed(reply.message)
                return
            }
            do {
                _ = try await readHelperPowerConfiguration()
            } catch {
                Self.logger.error(
                    "Could not read helper power capabilities: \(error.localizedDescription, privacy: .public)"
                )
            }
        } catch is CancellationError {
            return
        } catch {
            recordHelperConnectionFailure(error)
        }
    }

    var helperReconnectWaitSeconds: Int {
        manualReconnectCooldown.remainingSeconds(at: reconnectClock())
    }

    var helperReconnectTitle: String {
        let seconds = helperReconnectWaitSeconds
        return seconds > 0
            ? L10n.text("等待 \(seconds) 秒", "Wait \(seconds)s")
            : L10n.text("重新连接", "Reconnect")
    }

    /// A deliberate action resets automatic backoff once, but cannot bypass
    /// either an in-flight attempt or the independent ten-second manual gate.
    func reconnectHelper() async {
        guard !isDataOnlyFixture, offersHelperReconnect,
              !isRefreshingConnection, !isPreparingHelper, !reconnectInFlight,
              manualReconnectCooldown.admit(at: reconnectClock()) else { return }
        manualReconnectClockTick = reconnectClock()
        startManualReconnectCountdown()
        cancelAutomaticReconnect()
        reconnectBackoff.reset()
        await connectHelper()
    }

    private func startManualReconnectCountdown() {
        // Fake senders use their injected clock; production publishes only the
        // countdown. This worker never queries availability or sends XPC.
        guard requestSender == nil else { return }
        manualReconnectCountdownTask?.cancel()
        manualReconnectCountdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.manualReconnectClockTick = self.reconnectClock()
                if self.helperReconnectWaitSeconds == 0 {
                    self.manualReconnectCountdownTask = nil
                    return
                }
            }
        }
    }

    private func cancelAutomaticReconnect() {
        reconnectScheduleGeneration &+= 1
        automaticReconnectTask?.cancel()
        automaticReconnectTask = nil
    }

    private func scheduleAutomaticReconnect(initial: Bool = false) {
        guard automaticallyReconnect, !isDataOnlyFixture, !startupRecoveryFailureLatched,
              helperStatus == .enabled, !isHelperReachable,
              !reconnectInFlight, !isRefreshingConnection, !isPreparingHelper,
              automaticReconnectTask == nil,
              initial || reconnectBackoff.nextAttemptAt != nil else { return }
        let delay = reconnectBackoff.remainingDelay(at: reconnectClock())
        let generation = reconnectScheduleGeneration
        let sleeper = reconnectSleeper
        automaticReconnectTask = Task { @MainActor [weak self] in
            do { try await sleeper(delay) } catch { return }
            guard !Task.isCancelled, let self,
                  generation == self.reconnectScheduleGeneration else { return }
            self.automaticReconnectTask = nil
            await self.connectHelper()
        }
    }

    private func readHelperPowerConfiguration() async throws -> FanControlPowerConfiguration {
        let reply = try await send(.readPowerConfiguration)
        guard reply.success, let configuration = reply.powerConfiguration else {
            throw FanControlConnectionError.helperRejected(reply.message)
        }
        return configuration
    }

    func registerHelper() async {
        _ = await prepareHelper(
            opensApprovalSettings: true,
            automatic: false
        )
    }

    /// Demand-only, read-only. Does not call prepareHelper or approval settings.
    func samplePowerMetrics() async -> PowermetricsResult {
        guard !isDataOnlyFixture else { return .failure(.unavailable) }
        guard helperStatus == .enabled, isHelperReachable, !isChangingMacMiniMode, !isPreparingHelper,
              !startupRecoveryFailureLatched else { return .failure(.unavailable) }
        do {
            let reply = try await send(.samplePowerMetrics)
            return reply.powerSampleResult ?? .failure(.unavailable)
        } catch let error as FanControlHelperProtocolError {
            if case .unsupportedProtocolVersion(let version) = error, [2, 3].contains(version) {
                macMiniHelperNeedsUpdate = true
            }
            return .failure(.unavailable)
        } catch { return .failure(.unavailable) }
    }

    /// Visible power controls call this; it never installs or changes hardware.
    func refreshMacMiniMode() async {
        guard !isDataOnlyFixture, !isReadingMacMiniMode, !isChangingMacMiniMode else { return }
        guard isHelperReachable || startupRecoveryFailureLatched else { return }
        isReadingMacMiniMode = true
        let generation = macMiniIntentGeneration
        defer { isReadingMacMiniMode = false }
        refreshRegistrationStatus()
        guard helperStatus == .enabled else {
            macMiniModeStatus = nil
            macMiniModeMessage = nil
            return
        }
        do {
            let reply = try await send(.readMacMiniMode)
            guard generation == macMiniIntentGeneration else { return }
            macMiniModeStatus = reply.macMiniModeStatus
            macMiniModeMessage = reply.success ? nil : MacMiniModePresentation.failureMessage(reply.errorCode)
            macMiniHelperNeedsUpdate = false
        } catch {
            guard generation == macMiniIntentGeneration else { return }
            macMiniModeStatus = nil
            recordMacMiniError(error)
        }
    }

    func setMacMiniMode(_ mode: MacMiniMode) async {
        guard !isDataOnlyFixture, !isChangingMacMiniMode else { return }
        isChangingMacMiniMode = true
        macMiniIntentGeneration &+= 1
        defer { isChangingMacMiniMode = false }
        macMiniModeMessage = nil
        if !(startupRecoveryFailureLatched && mode == .off) {
            if helperStatus == .enabled {
                do { _ = try await send(.ping) }
                catch { recordMacMiniError(error); return }
            }
            // Only enabling/normal use needs a ready fan helper. Fault-mode OFF
            // is recovery, not a request to restart normal hardware control.
            guard await prepareHelperForControl() else {
                macMiniModeMessage = lastMessage ?? macMiniUnavailableMessage
                return
            }
        }
        do {
            let reply = try await send(.setMacMiniMode(mode))
            macMiniModeStatus = reply.macMiniModeStatus
            macMiniModeMessage = reply.success ? nil : MacMiniModePresentation.failureMessage(reply.errorCode)
            macMiniHelperNeedsUpdate = false
        } catch {
            macMiniModeStatus = nil
            recordMacMiniError(error)
        }
    }

    func updateMacMiniModeHelper() async {
        guard !isDataOnlyFixture, macMiniHelperNeedsUpdate, !isChangingMacMiniMode else { return }
        await unregisterHelper()
        guard helperStatus == .notRegistered else {
            macMiniModeMessage = lastMessage
            return
        }
        await registerHelper()
        await refreshMacMiniMode()
    }

    private var macMiniUnavailableMessage: String {
        switch helperStatus {
        case .notRegistered:
            L10n.text("开启时需要授权系统助手。", "Enabling requires system-helper authorization.")
        case .requiresApproval:
            L10n.text("请在系统设置的“登录项与扩展”中允许系统助手。", "Allow the helper in System Settings → Login Items & Extensions.")
        case .needsMigration:
            L10n.text("请先迁移旧版系统助手。", "Migrate the legacy helper first.")
        case .enabled, .unavailable:
            L10n.text("系统助手不可用，请重新连接或重新授权。", "The helper is unavailable; reconnect or authorize it again.")
        }
    }

    private func recordMacMiniError(_ error: any Error) {
        if let protocolError = error as? FanControlHelperProtocolError,
           case .unsupportedProtocolVersion(let version) = protocolError,
           [2, 3].contains(version) {
            macMiniHelperNeedsUpdate = true
            macMiniModeMessage = L10n.text(
                "系统助手版本过旧，请更新并重新授权。",
                "The system helper is outdated; update it and authorize it again."
            )
        } else {
            macMiniHelperNeedsUpdate = false
            macMiniModeMessage = L10n.text(
                "无法确认系统睡眠状态，请重新连接系统助手。",
                "System sleep state could not be confirmed; reconnect the system helper."
            )
        }
    }

    /// Explicitly removes a mismatched fixed-path helper before registering
    /// the current app-bundled SMAppService daemon. This is never called by
    /// automatic preparation; the user must choose the migration action.
    func migrateLegacyHelper() async {
        _ = await prepareHelper(
            opensApprovalSettings: true,
            automatic: false,
            allowLegacyMigration: true
        )
    }

    @discardableResult
    private func prepareHelperForControl() async -> Bool {
        await prepareHelper(
            opensApprovalSettings: !didOpenApprovalSettingsAutomatically,
            automatic: true
        )
    }

    @discardableResult
    private func prepareHelper(
        opensApprovalSettings: Bool,
        automatic: Bool,
        allowLegacyMigration: Bool = false
    ) async -> Bool {
        guard !isDataOnlyFixture else { return false }
        guard !isPreparingHelper else { return false }
        isPreparingHelper = true
        defer {
            isPreparingHelper = false
            scheduleAutomaticReconnect()
        }

        lastMessage = nil
        do {
            let legacyArtifactsPresent = legacyArtifactsPresentProvider()
            if legacyArtifactsPresent
                && !legacyArtifactsCurrentProvider() {
                guard allowLegacyMigration,
                      legacyArtifactsSafeForRemovalProvider() else {
                    // Never overwrite a root-owned helper whose bytes or fixed
                    // launchd contract do not match this app.
                    refreshRegistrationStatus()
                    lastMessage = LegacyFanControlHelperInstallerError
                        .installedArtifactsMismatch.localizedDescription
                    return false
                }

                // Migration is explicit and starts fail-closed. No helper
                // request is sent while the old fixed-path installation is
                // being removed.
                resetControlState()
                connection?.invalidate()
                connection = nil
                try await legacyUninstaller()
                guard !legacyArtifactsPresentProvider() else {
                    refreshRegistrationStatus()
                    lastMessage = L10n.text(
                        "旧版系统控制辅助程序未完全移除，系统控制仍保持关闭。",
                        "The legacy system-control helper was not fully removed; system control remains disabled."
                    )
                    return false
                }
            }

            // New installs use the app-bundled SMAppService daemon. The legacy
            // installer is migration-only and never gates this path.
            //
            // `notFound` is also registerable: launchd reports it until the
            // bundled plist has been submitted at least once. Treating it as a
            // dead end left the only authorization entry point unable to
            // register, so advanced control could never be approved. Any real
            // failure now surfaces through the thrown registration error
            // instead of a guessed signing diagnostic.
            if !legacyArtifactsPresentProvider(),
               currentServiceStatus() == .notRegistered
                || currentServiceStatus() == .notFound {
                try await registerService()
            }
            refreshRegistrationStatus()
            if helperStatus == .requiresApproval {
                lastMessage = L10n.text(
                    "请在“系统设置 → 通用 → 登录项与扩展”中允许系统控制辅助程序。只需批准一次。",
                    "Approve the system-control helper once in System Settings → General → Login Items & Extensions."
                )
                if opensApprovalSettings {
                    if automatic {
                        didOpenApprovalSettingsAutomatically = true
                    }
                    approvalSettingsOpener()
                }
                return false
            } else if helperStatus == .enabled {
                let reply = try await waitForHelper()
                isHelperReachable = reply.success
                lastMessage = reply.success
                    ? L10n.text("系统控制辅助程序已连接。", "The system-control helper is connected.")
                    : reply.message
                return reply.success
            } else if helperStatus == .unavailable {
                lastMessage = unavailableHelperDiagnostic
            }
        } catch is CancellationError {
            return false
        } catch {
            if allowLegacyMigration {
                resetControlState()
                connection?.invalidate()
                connection = nil
            }
            refreshRegistrationStatus()
            if helperStatus == .enabled { recordHelperConnectionFailure(error) }
            else { lastMessage = error.localizedDescription }
        }
        return false
    }

    private var unavailableHelperDiagnostic: String {
        // Separate the two real causes. A rejected signature is actionable by
        // rebuilding; everything else is a launchd registration problem, and
        // claiming notarization is required was wrong: SMAppService accepts a
        // consistently signed development build.
        guard Self.bundledHelperURL != nil else {
            return L10n.text(
                "此构建缺少系统控制辅助程序，仅能只读监测。",
                "This build does not contain the system-control helper; monitoring stays read-only."
            )
        }
        guard bundledHelperSigningIsTrusted != false else {
            return L10n.text(
                "系统控制辅助程序的签名与本应用不一致，已拒绝启用；当前继续只读监测。",
                "The system-control helper's signature does not match this app, so it was not enabled; monitoring stays read-only."
            )
        }
        return L10n.text(
            "macOS 尚未登记系统控制辅助程序。请点击“启用高级控制”，并在“系统设置 → 通用 → 登录项与扩展”中允许本应用的后台项目。",
            "macOS has not registered the system-control helper yet. Choose “Enable Advanced Control,” then allow this app's background item in System Settings → General → Login Items & Extensions."
        )
    }

    func unregisterHelper() async {
        guard !isDataOnlyFixture else { return }
        guard !isChangingMacMiniMode else { return }
        isChangingMacMiniMode = true
        macMiniIntentGeneration &+= 1
        defer { isChangingMacMiniMode = false }
        lastMessage = nil
        refreshRegistrationStatus()
        if helperStatus == .enabled {
            do {
                let reply: FanControlHelperReply?
                do {
                    // Stop the persistent policy BEFORE unregistering launchd.
                    let sleepReply = try await send(.setMacMiniMode(.off), allowsLegacyRemovalFallback: true)
                    macMiniModeStatus = sleepReply.macMiniModeStatus
                    guard sleepReply.success,
                          sleepReply.macMiniModeStatus?.mode == .off,
                          sleepReply.macMiniModeStatus?.ownsSleepDisabled == false else {
                        lastMessage = MacMiniModePresentation.failureMessage(sleepReply.errorCode)
                        return
                    }
                    // Startup failure already attempted fan recovery. Never
                    // issue another fan write; sleep OFF is the removal gate.
                    if startupRecoveryFailureLatched { reply = nil }
                    else { reply = try await send(.restoreAutomatic) }
                } catch FanControlHelperProtocolError.unsupportedProtocolVersion(2) {
                    // The old v2 helper has no persistent lid policy. Its only
                    // compatible operation is returning fans to system control.
                    reply = try await send(.restoreAutomaticForVersion2)
                } catch FanControlHelperProtocolError.unsupportedProtocolVersion(3) {
                    // v3 owns a persistent sleep policy: verified OFF precedes
                    // retiring its fans/daemon. Compatibility cannot enable it.
                    let sleepReply = try await send(.disableMacMiniModeForVersion3)
                    macMiniModeStatus = sleepReply.macMiniModeStatus
                    guard sleepReply.success, sleepReply.macMiniModeStatus?.mode == .off,
                          sleepReply.macMiniModeStatus?.ownsSleepDisabled == false else {
                        lastMessage = MacMiniModePresentation.failureMessage(sleepReply.errorCode)
                        return
                    }
                    if startupRecoveryFailureLatched { reply = nil }
                    else { reply = try await send(.restoreAutomaticForVersion3) }
                }
                if let reply, !reply.success, reply.errorCode != .fanCrashRecoveryFailed {
                    failClosed(reply.message)
                    return
                }
            } catch {
                failClosed(error.localizedDescription)
                return
            }
        } else if macMiniModeStatus?.mode == .whenOnAC
                    || macMiniModeStatus?.ownsSleepDisabled == true {
            lastMessage = L10n.text(
                "请先允许系统助手运行并关闭 Mac mini 模式，再移除助手。",
                "Allow the helper to run and turn Mac mini mode off before removing it."
            )
            return
        }
        connection?.invalidate()
        connection = nil
        clearObservedMode()
        isHelperReachable = false
        let removedAfterStartupFault = startupRecoveryFailureLatched
        do {
            if legacyArtifactsPresentProvider() {
                guard legacyArtifactsSafeForRemovalProvider() else {
                    refreshRegistrationStatus()
                    lastMessage = LegacyFanControlHelperInstallerError
                        .installedArtifactsMismatch.localizedDescription
                    return
                }
                try await legacyUninstaller()
            } else if currentServiceStatus() != .notFound {
                if let serviceUnregistrar {
                    try await serviceUnregistrar()
                } else {
                    try await service.unregister()
                }
            }
            selectedMode = .systemAutomatic
            macMiniModeStatus = nil
            macMiniHelperNeedsUpdate = false
            refreshRegistrationStatus()
            startupRecoveryFailureLatched = false
            lastMessage = removedAfterStartupFault
                ? L10n.text("本助手的睡眠恢复责任已解除，辅助程序已移除；风扇自动控制仍未确认。重新授权前请检查风扇状态。",
                            "This helper's sleep restoration is complete and it was removed; automatic fan control is unconfirmed. Check the fan state before authorizing it again.")
                : L10n.text("自定义硬件控制已停止，辅助程序已移除。",
                            "Custom hardware control was stopped and the helper was removed.")
        } catch {
            refreshRegistrationStatus()
            lastMessage = error.localizedDescription
        }
    }

    func openApprovalSettings() {
        guard !isDataOnlyFixture else { return }
        approvalSettingsOpener()
    }

    func curvePoints(forFanID fanID: Int?) -> [FanCurvePoint] {
        guard let fanID else { return curveConfiguration.sharedPoints }
        return curveConfiguration.points(forFanID: fanID)
    }

    func setFanCurvesSynchronized(_ synchronizesFans: Bool, fanIDs: [Int]) {
        var configuration = curveConfiguration
        if !synchronizesFans {
            for fanID in fanIDs where configuration.pointsByFan[fanID] == nil {
                configuration.pointsByFan[fanID] = configuration.sharedPoints
            }
        }
        configuration.synchronizesFans = synchronizesFans
        curveConfiguration = configuration.normalized()
    }

    func addCurvePoint(forFanID fanID: Int?) {
        var points = curvePoints(forFanID: fanID)
        guard points.count < FanCurveConfiguration.maximumPointCount else { return }
        let candidates = zip(points, points.dropFirst())
        guard let gap = candidates.max(by: {
            ($0.1.temperatureCelsius - $0.0.temperatureCelsius)
                < ($1.1.temperatureCelsius - $1.0.temperatureCelsius)
        }) else { return }
        points.append(FanCurvePoint(
            temperatureCelsius: (gap.0.temperatureCelsius + gap.1.temperatureCelsius) / 2,
            speedFraction: (gap.0.speedFraction + gap.1.speedFraction) / 2
        ))
        setCurvePoints(points, forFanID: fanID)
    }

    func updateCurvePoint(
        id: UUID,
        temperatureCelsius: Double,
        speedFraction: Double,
        forFanID fanID: Int?
    ) {
        var points = curvePoints(forFanID: fanID)
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        points[index].temperatureCelsius = temperatureCelsius
        points[index].speedFraction = speedFraction
        setCurvePoints(points, forFanID: fanID)
    }

    func removeCurvePoint(id: UUID, forFanID fanID: Int?) {
        var points = curvePoints(forFanID: fanID)
        guard points.count > 2 else { return }
        points.removeAll { $0.id == id }
        setCurvePoints(points, forFanID: fanID)
    }

    func restoreDefaultCurve(forFanID fanID: Int?) {
        setCurvePoints(FanCurveConfiguration.defaultPoints, forFanID: fanID)
    }

    private func setCurvePoints(_ points: [FanCurvePoint], forFanID fanID: Int?) {
        var configuration = curveConfiguration
        configuration.setPoints(points, forFanID: fanID)
        curveConfiguration = configuration.normalized()
    }

    func applyPowerMode(
        _ command: BatteryPowerModeWriteCommand
    ) async throws -> BatteryPowerModes {
        guard !isDataOnlyFixture else { throw CancellationError() }
        let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
        let signpostState = PerformanceTelemetry.signposter.beginInterval(
            "PowerModeSwitch",
            id: signpostID
        )
        defer {
            PerformanceTelemetry.signposter.endInterval(
                "PowerModeSwitch",
                signpostState
            )
        }
        refreshRegistrationStatus()
        if helperStatus != .enabled {
            _ = await prepareHelperForControl()
        }
        guard helperStatus == .enabled else {
            throw BatteryPowerModeCommandFailure.permissionDenied
        }
        guard let request = FanControlHelperRequest.applyPowerMode(command) else {
            throw BatteryPowerModeCommandFailure.unavailable
        }

        do {
            let reply = try await send(request)
            guard reply.success else {
                if reply.errorCode == .pmsetVerificationFailed {
                    throw BatteryPowerModeCommandFailure.verificationFailed
                }
                if reply.message.localizedCaseInsensitiveContains("timed out") {
                    throw BatteryPowerModeCommandFailure.timedOut
                }
                throw BatteryPowerModeCommandFailure.unavailable
            }
            guard let configuration = reply.powerConfiguration,
                  configuration.matches(command) else {
                throw BatteryPowerModeCommandFailure.verificationFailed
            }
            isHelperReachable = true
            Self.logger.info(
                "Verified power mode update for \(command.source.rawValue, privacy: .public)"
            )
            return configuration.batteryPowerModes
        } catch let failure as BatteryPowerModeCommandFailure {
            throw failure
        } catch {
            clearObservedMode()
            isHelperReachable = false
            throw BatteryPowerModeCommandFailure.unavailable
        }
    }

    func manageStartupItem(
        _ plan: StartupItemsDomain.StartupOperationPlan
    ) async throws {
        _ = plan
        throw StartupItemsDomain.StartupManagementError.unsupported(
            L10n.text(
                "高级硬件控制辅助程序只接受电源和风扇操作，不能修改系统级登录项。",
                "The advanced hardware-control helper accepts only power and fan operations and cannot modify system-level startup items."
            )
        )
    }

    func selectMode(_ mode: GeekFanControlMode) async {
        guard !isDataOnlyFixture else { return }
        requestedMode = mode
        await enqueueControlIntent(.selectMode(mode))
        if requestedMode == mode {
            requestedMode = nil
        }
    }

    private func enqueueControlIntent(_ intent: FanControlIntent) async {
        controlIntentGeneration &+= 1
        pendingControlIntent = FanControlIntentRequest(
            generation: controlIntentGeneration,
            intent: intent
        )
        manualCommitTask?.cancel()
        manualCommitTask = nil
        manualCommitPending = false

        if let controlIntentTask {
            await controlIntentTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.driveControlIntents()
        }
        controlIntentTask = task
        await task.value
    }

    private func driveControlIntents() async {
        isSwitchingMode = true
        defer {
            isSwitchingMode = false
            controlIntentTask = nil
        }

        while let request = pendingControlIntent {
            pendingControlIntent = nil
            switch request.intent {
            case .selectMode:
                await performSelectMode(request)
            case .applyCurveDraft:
                await performApplyFanCurveDraft(request)
            }
        }
    }

    private func performSelectMode(_ request: FanControlIntentRequest) async {
        guard case .selectMode(let mode) = request.intent,
              isCurrentControlIntent(request) else { return }
        guard !startupRecoveryFailureLatched else {
            lastMessage = Self.startupRecoveryFailureMessage
            return
        }
        let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
        let signpostState = PerformanceTelemetry.signposter.beginInterval(
            "FanModeSwitch",
            id: signpostID
        )
        defer {
            PerformanceTelemetry.signposter.endInterval(
                "FanModeSwitch",
                signpostState
            )
        }

        lastMessage = nil
        clearObservedMode()
        if mode == .systemAutomatic {
            var restoreRequestCompleted = false
            if helperStatus == .enabled {
                do {
                    let reply = try await send(.restoreAutomatic)
                    guard isCurrentControlIntent(request) else { return }
                    guard reply.success else {
                        failClosed(reply.message)
                        return
                    }
                    isHelperReachable = true
                    restoreRequestCompleted = true
                } catch {
                    guard isCurrentControlIntent(request) else { return }
                    failClosed(error.localizedDescription)
                    return
                }
            }
            selectedMode = .systemAutomatic
            curveLeaseID = nil
            curveRuntimeState = .inactive
            curveStore.clearAppliedProfile()
            lastApplyDate = nil
            lastLeaseRenewalDate = nil
            lastAppliedTargets.removeAll()
            confirmedManualFractionByFan.removeAll()
            lastAutomaticFanIDs.removeAll()
            lastAppliedHardwareRanges.removeAll()
            if restoreRequestCompleted {
                // The restore reply confirms command completion, but carries
                // no automatic-mode readback. Keep observedMode unconfirmed.
                lastMessage = L10n.text(
                    "Helper 已确认恢复请求完成；当前硬件模式仍待确认。",
                    "Helper confirmed completion of the restore request; the current hardware mode remains unconfirmed."
                )
            }
            return
        }

        if mode == .customCurve {
            if selectedMode == .customCurve,
               curveLeaseID != nil,
               curveStore.appliedProfile != nil {
                publishObservedMode(.customCurve, verifiedAt: now())
            } else {
                lastMessage = L10n.text(
                    "尚未应用曲线，请先在曲线编辑器中检查并应用。",
                    "No fan curve is active. Review and apply one in the curve editor first."
                )
            }
            return
        }

        if let thermalState = latestSnapshot?.thermalState,
           (thermalState == .serious || thermalState == .critical) {
            selectedMode = .systemAutomatic
            lastMessage = L10n.text(
                "由于系统温度较高，风扇已保持自动散热。",
                "Fan control remains automatic because the system thermal state is high."
            )
            return
        }

        if mode == .manual {
            let entryFractions = Self.manualEntryFractions(
                fanReadings: latestSnapshot?.fanReadings
            )
            if !entryFractions.isEmpty {
                manualFractionByFan = entryFractions
                manualFraction = entryFractions.values.reduce(0, +)
                    / Double(entryFractions.count)
            }
        }

        refreshRegistrationStatus()
        if helperStatus != .enabled {
            _ = await prepareHelperForControl()
            guard isCurrentControlIntent(request) else { return }
        }
        guard helperStatus == .enabled else {
            selectedMode = .systemAutomatic
            if helperStatus != .needsMigration {
                lastMessage = L10n.text(
                    "请完成一次“系统控制辅助程序”批准；批准后可直接选择风扇模式。",
                    "Approve the system-control helper once, then select a fan mode directly."
                )
            }
            return
        }

        do {
            let reply = try await send(.ping)
            guard isCurrentControlIntent(request) else { return }
            guard reply.success else {
                selectedMode = .systemAutomatic
                lastMessage = reply.message
                return
            }
            isHelperReachable = true
            selectedMode = mode
            curveLeaseID = nil
            curveRuntimeState = .inactive
            curveStore.clearAppliedProfile()
            lastMessage = if mode == .manual || mode == .maximum {
                L10n.text(
                    "已选择 \(mode.title)，正在根据最新真实转速应用。",
                    "\(mode.title) selected and is being applied from the latest real fan readings."
                )
            } else {
                L10n.text(
                    "已选择 \(mode.title)；下一个真实传感器样本会应用设置。",
                    "\(mode.title) selected. The next real sensor sample will apply it."
                )
            }
            if mode == .manual {
                manualCommitPending = true
                scheduleManualCommit()
            } else if mode == .maximum, let latestSnapshot {
                process(
                    snapshot: latestSnapshot,
                    bypassesMinimumUpdateInterval: true
                )
            }
        } catch {
            guard isCurrentControlIntent(request) else { return }
            selectedMode = .systemAutomatic
            lastMessage = error.localizedDescription
        }
    }

    /// Applies the current draft exactly once. Editing the draft never sends
    /// fan targets; after validation the helper owns the entire control loop.
    func applyFanCurveDraft() async {
        guard !isDataOnlyFixture else { return }
        PerformanceTelemetry.signposter.emitEvent("CurveApplyRequested")
        requestedMode = .customCurve
        await enqueueControlIntent(.applyCurveDraft)
        PerformanceTelemetry.signposter.emitEvent(
            selectedMode == .customCurve && !curveStore.hasUnappliedChanges
                ? "CurveApplyConfirmed"
                : "CurveApplyFailed"
        )
        if requestedMode == .customCurve {
            requestedMode = nil
        }
    }

    private func performApplyFanCurveDraft(
        _ request: FanControlIntentRequest
    ) async {
        guard case .applyCurveDraft = request.intent,
              isCurrentControlIntent(request) else { return }
        guard !startupRecoveryFailureLatched else {
            lastMessage = Self.startupRecoveryFailureMessage
            return
        }
        lastMessage = nil
        guard let snapshot = latestSnapshot,
              now().timeIntervalSince(snapshot.generatedAt)
                <= FanCurveControlPolicy.standard.staleAfter else {
            lastMessage = Self.curveMessage(for: .sensorStale)
            return
        }
        guard snapshot.thermalState != .serious,
              snapshot.thermalState != .critical else {
            lastMessage = Self.curveMessage(for: .thermalProtectionActivated)
            return
        }
        let fanReadings = snapshot.fanReadings ?? []
        guard !fanReadings.isEmpty,
              fanReadings.allSatisfy({ Self.curveRange($0) != nil }) else {
            lastMessage = Self.curveMessage(for: .fanRangeUnavailable)
            return
        }

        let profile: FanCurveProfile
        do {
            profile = try curveStore.preparedProfile(
                targetFanIDs: fanReadings.map(\.index).sorted()
            )
            try FanCurveValidator.validate(
                profile,
                allowedSensors: Set(availableCurveSensors),
                availableFanIDs: Set(fanReadings.map(\.index)),
                requiresTargetFans: true
            )
        } catch let error as FanCurveError {
            lastMessage = Self.curveMessage(for: error)
            return
        } catch {
            lastMessage = Self.curveMessage(for: .curveActivationFailed)
            return
        }

        refreshRegistrationStatus()
        if helperStatus != .enabled {
            _ = await prepareHelperForControl()
            guard isCurrentControlIntent(request) else { return }
        }
        guard helperStatus == .enabled else {
            lastMessage = L10n.text(
                "高级硬件控制尚未获得系统批准。",
                "Advanced hardware control has not yet been approved by the system."
            )
            return
        }
        guard await waitForActiveFanWrite(toFinishFor: request) else { return }

        isApplying = true
        defer { isApplying = false }
        do {
            let validation = try await send(.validateFanCurve(profile))
            guard isCurrentControlIntent(request) else { return }
            guard validation.success else {
                lastMessage = Self.curveMessage(for: validation)
                return
            }

            let leaseID = curveLeaseID ?? UUID()
            let updatesRunningCurve = selectedMode == .customCurve
                && curveLeaseID != nil
                && curveStore.appliedProfile != nil
            let helperRequest: FanControlHelperRequest = updatesRunningCurve
                ? .updateFanCurve(profile, leaseID: leaseID)
                : .activateFanCurve(profile, leaseID: leaseID)
            let reply = try await send(helperRequest)
            guard isCurrentControlIntent(request) else { return }
            guard reply.success,
                  let runtime = reply.curveRuntimeState,
                  runtime.activeProfileID == profile.id,
                  runtime.status == .active || runtime.status == .applying else {
                failClosed(Self.curveMessage(for: reply))
                return
            }

            curveLeaseID = leaseID
            curveRuntimeState = runtime
            curveStore.markApplied(profile)
            selectedMode = .customCurve
            isHelperReachable = true
            lastLeaseRenewalDate = now()
            lastCurveStatusRead = now()
            synchronizeCurveRuntime(runtime, fanReadings: fanReadings)
            publishObservedMode(.customCurve, verifiedAt: now())
            lastMessage = L10n.text(
                "温控曲线已由 Helper 应用并回读确认。",
                "The helper applied and verified the fan curve by readback."
            )
        } catch {
            guard isCurrentControlIntent(request) else { return }
            failClosed(Self.curveMessage(for: .curveActivationFailed))
        }
    }

    private func isCurrentControlIntent(_ request: FanControlIntentRequest) -> Bool {
        request.generation == controlIntentGeneration
    }

    private func waitForActiveFanWrite(
        toFinishFor request: FanControlIntentRequest
    ) async -> Bool {
        while isApplying {
            guard isCurrentControlIntent(request), !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isCurrentControlIntent(request) && !Task.isCancelled
    }

    func process(snapshot: SystemMonitorSnapshot) {
        process(snapshot: snapshot, bypassesMinimumUpdateInterval: false)
    }

    func setManualFansSynchronized(_ synchronized: Bool) {
        guard synchronizesManualFans != synchronized else { return }
        if synchronized {
            let fractions = latestSnapshot?.fanReadings?.compactMap { reading in
                manualFractionByFan[reading.index]
                    ?? Self.manualEntryFraction(reading)
            } ?? []
            if !fractions.isEmpty {
                manualFraction = fractions.reduce(0, +) / Double(fractions.count)
            }
        } else {
            let readings = latestSnapshot?.fanReadings ?? []
            manualFractionByFan = Dictionary(
                uniqueKeysWithValues: readings.map { reading in
                    (
                        reading.index,
                        Self.manualEntryFraction(reading) ?? manualFraction
                    )
                }
            )
        }
        synchronizesManualFans = synchronized
        guard selectedMode == .manual else { return }
        manualCommitPending = true
        scheduleManualCommit()
    }

    func manualPercentage(for fanID: Int?) -> Double {
        guard let fanID, !synchronizesManualFans else {
            return manualFraction * 100
        }
        return (manualFractionByFan[fanID] ?? manualFraction) * 100
    }

    func updateManualPercentage(_ percentage: Double, fanID: Int? = nil) {
        setManualPercentage(percentage, fanID: fanID)
        guard selectedMode == .manual else { return }
        manualCommitPending = true
        scheduleManualCommit()
    }

    func commitManualPercentage(_ percentage: Double, fanID: Int? = nil) {
        manualCommitTask?.cancel()
        manualCommitTask = nil
        setManualPercentage(percentage, fanID: fanID)
        guard selectedMode == .manual else { return }
        manualCommitPending = true
        commitPendingManualUpdate()
    }

    private func setManualPercentage(_ percentage: Double, fanID: Int?) {
        let fraction = Self.normalizedFraction(percentage / 100)
        if let fanID, !synchronizesManualFans {
            manualFractionByFan[fanID] = fraction
        } else {
            manualFraction = fraction
        }
    }

    private func scheduleManualCommit() {
        manualCommitTask?.cancel()
        manualCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(
                FanControlSafetyPolicy.manualControlDebounce
            ))
            guard !Task.isCancelled else { return }
            self?.commitPendingManualUpdate()
        }
    }

    private func commitPendingManualUpdate() {
        guard manualCommitPending,
              selectedMode == .manual,
              let latestSnapshot else {
            manualCommitPending = false
            return
        }
        guard !isApplying else {
            scheduleManualCommit()
            return
        }
        manualCommitPending = false
        process(
            snapshot: latestSnapshot,
            bypassesMinimumUpdateInterval: true
        )
    }

    private func process(
        snapshot: SystemMonitorSnapshot,
        bypassesMinimumUpdateInterval: Bool
    ) {
        latestSnapshot = snapshot
        let sensors = Self.availableCurveSensors(in: snapshot)
        if availableCurveSensors != sensors {
            availableCurveSensors = sensors
        }
        let previewTemperature = Self.temperature(
            for: curveStore.draftProfile.sensor,
            in: snapshot
        )
        if curvePreviewTemperature != previewTemperature {
            curvePreviewTemperature = previewTemperature
        }
        if selectedMode != .systemAutomatic,
           (snapshot.thermalState == .serious || snapshot.thermalState == .critical) {
            failClosed(L10n.text(
                "系统温度较高，已停止自定义风扇控制。",
                "The system thermal state is high; custom fan control was stopped."
            ))
            return
        }
        if hardwareCapabilityChanged(snapshot.fanReadings) {
            failClosed(L10n.text(
                "风扇硬件能力发生变化，已停止自定义控制并请求恢复系统控制。",
                "Fan hardware capability changed; custom control stopped and restoration was requested."
            ))
            return
        }
        invalidateObservedModeIfHardwareChanged(snapshot.fanReadings)
        guard selectedMode != .systemAutomatic,
              helperStatus == .enabled,
              isHelperReachable,
              !isApplying else {
            return
        }
        let now = now()
        if selectedMode == .customCurve {
            processCurveRuntime(at: now, fanReadings: snapshot.fanReadings ?? [])
            return
        }
        if !bypassesMinimumUpdateInterval,
           let lastApplyDate,
           now.timeIntervalSince(lastApplyDate)
            < FanControlSafetyPolicy.minimumUpdateInterval {
            return
        }

        let requestedMode = selectedMode
        curveTemperatureAnchor = nil
        guard let plan = FanControlPlanner.plan(
            mode: requestedMode,
            fanSet: selectedFanSet,
            manualFraction: manualFraction,
            manualFractionByFan: manualFractionByFan,
            synchronizesManualFans: synchronizesManualFans,
            curveLowTemperature: curveLowTemperature,
            curveHighTemperature: curveHighTemperature,
            thermalState: snapshot.thermalState,
            fanReadings: snapshot.fanReadings,
            temperatureReadings: snapshot.temperatureReadings,
            curveConfiguration: curveConfiguration
        ) else {
            failClosed(
                L10n.text(
                    "真实温度或风扇范围不可用，已停止自定义控制。",
                    "Real temperature or fan-range data is unavailable; custom control was stopped."
                )
            )
            return
        }
        if plan.restoresAllFans {
            selectedMode = .systemAutomatic
        }
        let elapsed = lastApplyDate.map { now.timeIntervalSince($0) }
            ?? FanControlSafetyPolicy.minimumUpdateInterval
        let safePlan = FanControlSafetyPolicy.rateLimited(
            plan,
            fanReadings: snapshot.fanReadings ?? [],
            previousTargets: lastAppliedTargets,
            elapsed: elapsed
        )
        let allowsRPMDecrease = requestedMode == .manual
        let isLeaseRenewal = !safePlan.restoresAllFans
            && !lastAppliedTargets.isEmpty
            && safePlan.targetRPMByFan == lastAppliedTargets
            && safePlan.automaticFanIDs == lastAutomaticFanIDs
        if isLeaseRenewal,
           let lastLeaseRenewalDate,
           now.timeIntervalSince(lastLeaseRenewalDate)
            < FanControlSafetyPolicy.leaseRenewalInterval {
            return
        }
        let request: FanControlHelperRequest = isLeaseRenewal
            ? .renewFanControlLease
            : .apply(safePlan, allowsRPMDecrease: allowsRPMDecrease)
        let expectedTargets = isLeaseRenewal
            ? lastAppliedTargets
            : safePlan.targetRPMByFan
        let intentGeneration = controlIntentGeneration

        isApplying = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isApplying = false
                if manualCommitPending {
                    scheduleManualCommit()
                }
            }
            do {
                guard intentGeneration == controlIntentGeneration else { return }
                let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
                let signpostState = PerformanceTelemetry.signposter.beginInterval(
                    "FanTargetWrite",
                    id: signpostID
                )
                defer {
                    PerformanceTelemetry.signposter.endInterval(
                        "FanTargetWrite",
                        signpostState
                    )
                }
                let reply = try await send(request)
                guard intentGeneration == controlIntentGeneration else { return }
                guard reply.success else {
                    failClosed(reply.message)
                    return
                }
                guard FanControlSafetyPolicy.validatedAppliedTargets(
                    expected: expectedTargets,
                    applied: reply.appliedTargetRPMByFan,
                    fanReadings: snapshot.fanReadings ?? []
                ) else {
                    failClosed(L10n.text(
                        "风扇控制回报与请求不一致，已停止自定义控制并请求恢复系统控制。",
                        "The fan-control reply did not match the request; custom control stopped and restoration was requested."
                    ))
                    return
                }
                PerformanceTelemetry.signposter.emitEvent("FanReadback")
                lastLeaseRenewalDate = now
                if !isLeaseRenewal {
                    lastApplyDate = now
                    lastAppliedTargets = reply.appliedTargetRPMByFan
                    lastAutomaticFanIDs = safePlan.automaticFanIDs
                    if !safePlan.restoresAllFans,
                       !reply.appliedTargetRPMByFan.isEmpty {
                        lastAppliedHardwareRanges = snapshot.fanReadings?.reduce(
                            into: [Int: AppliedHardwareRange]()
                        ) { result, reading in
                            guard let minimumRPM = reading.minimumRPM,
                                  let maximumRPM = reading.maximumRPM else { return }
                            result[reading.index] = AppliedHardwareRange(
                                minimumRPM: minimumRPM,
                                maximumRPM: maximumRPM
                            )
                        } ?? [:]
                    } else {
                        lastAppliedHardwareRanges.removeAll()
                    }
                }
                // The authenticated helper only returns these targets after
                // reading the manual-mode bit and target RPM back from SMC.
                let hasVerifiedModeReadback = !safePlan.restoresAllFans
                    && !reply.appliedTargetRPMByFan.isEmpty
                    && selectedMode == requestedMode
                if hasVerifiedModeReadback {
                    if requestedMode == .manual {
                        confirmedManualFractionByFan = Self.manualFractions(
                            targets: reply.appliedTargetRPMByFan,
                            fanReadings: snapshot.fanReadings ?? []
                        )
                    }
                    publishObservedMode(requestedMode, verifiedAt: now)
                    if !isLeaseRenewal {
                        lastMessage = L10n.text("已生效", "Applied")
                    }
                } else {
                    clearObservedMode()
                }
                Self.logger.debug(
                    "Fan control \(isLeaseRenewal ? "lease renewed" : "target applied", privacy: .public)"
                )
            } catch {
                guard intentGeneration == controlIntentGeneration else { return }
                failClosed(error.localizedDescription)
            }
        }
    }

    private func processCurveRuntime(
        at timestamp: Date,
        fanReadings: [SystemFanReading]
    ) {
        guard !curveStatusRequestPending,
              let curveLeaseID else {
            if self.curveLeaseID == nil {
                failClosed(Self.curveMessage(for: .curveLeaseExpired))
            }
            return
        }
        if let lastCurveStatusRead,
           timestamp.timeIntervalSince(lastCurveStatusRead)
            < FanCurveControlPolicy.standard.sampleInterval * 0.8 {
            return
        }

        let renewsLease = lastLeaseRenewalDate.map {
            timestamp.timeIntervalSince($0)
                >= FanControlSafetyPolicy.leaseRenewalInterval
        } ?? true
        let request: FanControlHelperRequest = renewsLease
            ? .renewFanCurveLease(curveLeaseID)
            : .getFanCurveRuntimeState
        let intentGeneration = controlIntentGeneration
        curveStatusRequestPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { curveStatusRequestPending = false }
            do {
                let reply = try await send(request)
                guard intentGeneration == controlIntentGeneration else { return }
                guard reply.success,
                      let runtime = reply.curveRuntimeState,
                      runtime.status == .active || runtime.status == .applying,
                      runtime.activeProfileID == curveStore.appliedProfile?.id else {
                    failClosed(Self.curveMessage(for: reply))
                    return
                }
                let verifiedAt = now()
                curveRuntimeState = runtime
                lastCurveStatusRead = verifiedAt
                if renewsLease {
                    lastLeaseRenewalDate = verifiedAt
                }
                synchronizeCurveRuntime(runtime, fanReadings: fanReadings)
                publishObservedMode(.customCurve, verifiedAt: verifiedAt)
            } catch {
                guard intentGeneration == controlIntentGeneration else { return }
                failClosed(Self.curveMessage(for: .curveVerificationFailed))
            }
        }
    }

    private func synchronizeCurveRuntime(
        _ runtime: FanCurveRuntimeState,
        fanReadings: [SystemFanReading]
    ) {
        lastAppliedTargets = runtime.targetRPMByFan
        lastAutomaticFanIDs.removeAll()
        lastAppliedHardwareRanges = fanReadings.reduce(
            into: [Int: AppliedHardwareRange]()
        ) { result, reading in
            guard runtime.targetRPMByFan[reading.index] != nil,
                  let minimumRPM = reading.minimumRPM,
                  let maximumRPM = reading.maximumRPM else { return }
            result[reading.index] = AppliedHardwareRange(
                minimumRPM: minimumRPM,
                maximumRPM: maximumRPM
            )
        }
    }

    func prepareForTermination() async {
        guard !isDataOnlyFixture else { return }
        restoreRecoveryTask?.cancel()
        var restored = true
        if helperStatus == .enabled {
            do {
                let reply = try await send(.restoreAutomatic)
                restored = reply.success
                if !reply.success {
                    lastMessage = reply.message
                }
            } catch {
                restored = false
                lastMessage = error.localizedDescription
            }
        }
        resetControlState()
        connection?.invalidate()
        connection = nil
        if !restored {
            // Keep retrying the safe restore after the connection is rebuilt;
            // the helper watchdog remains the final fail-safe.
            beginRestoreRecovery()
        }
    }

    func disconnectForTermination() {
        cancelAutomaticReconnect()
        manualReconnectCountdownTask?.cancel()
        manualReconnectCountdownTask = nil
        restoreRecoveryTask?.cancel()
        restoreRecoveryTask = nil
        resetControlState()
        connection?.invalidate()
        connection = nil
    }

    private func failClosed(_ message: String) {
        Self.logger.error("Hardware control failed closed: \(message, privacy: .public)")
        resetControlState()
        lastMessage = startupRecoveryFailureLatched ? Self.startupRecoveryFailureMessage : message
        let oldConnection = connection
        connection = nil
        connectionGeneration &+= 1
        oldConnection?.invalidate()
        beginRestoreRecovery()
    }

    private func resetControlState() {
        controlIntentGeneration &+= 1
        pendingControlIntent = nil
        manualCommitTask?.cancel()
        manualCommitTask = nil
        manualCommitPending = false
        selectedMode = .systemAutomatic
        requestedMode = nil
        clearObservedMode()
        isHelperReachable = false
        isApplying = false
        lastApplyDate = nil
        lastLeaseRenewalDate = nil
        lastAppliedTargets.removeAll()
        confirmedManualFractionByFan.removeAll()
        lastAutomaticFanIDs.removeAll()
        lastAppliedHardwareRanges.removeAll()
        curveTemperatureAnchor = nil
        curveLeaseID = nil
        curveStatusRequestPending = false
        lastCurveStatusRead = nil
        curveRuntimeState = .inactive
        curveStore.clearAppliedProfile()
        latestSnapshot = nil
        availableCurveSensors = []
        curvePreviewTemperature = nil
    }

    private func publishObservedMode(
        _ mode: GeekFanControlMode,
        verifiedAt: Date
    ) {
        observedModeExpiryTask?.cancel()
        observedMode = mode
        observedModeVerifiedAt = verifiedAt
        observedModeExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(
                FanControlSafetyPolicy.watchdogSeconds
            ))
            guard !Task.isCancelled else { return }
            self?.expireObservedModeIfNeeded()
        }
    }

    private func clearObservedMode() {
        observedModeExpiryTask?.cancel()
        observedModeExpiryTask = nil
        observedModeVerifiedAt = nil
        if observedMode != nil {
            observedMode = nil
        }
    }

    func expireObservedModeIfNeeded() {
        guard let observedModeVerifiedAt,
              now().timeIntervalSince(observedModeVerifiedAt)
                >= FanControlSafetyPolicy.watchdogSeconds else {
            return
        }
        clearObservedMode()
    }

    private func invalidateObservedModeIfHardwareChanged(
        _ fanReadings: [SystemFanReading]?
    ) {
        guard observedMode != nil else { return }
        guard observedMode != .customCurve else { return }
        guard !lastAppliedTargets.isEmpty else { return }
        // The monitor snapshot can trail the authenticated Helper readback by
        // several samples immediately after a write. Keep the freshly verified
        // mode until that normal propagation window has passed; healthy manual
        // control is re-verified by the Helper lease every five seconds.
        guard let observedModeVerifiedAt,
              now().timeIntervalSince(observedModeVerifiedAt)
                >= FanControlSafetyPolicy.feedbackGracePeriod,
              let fanReadings else {
            return
        }
        let hasExplicitMismatch = lastAppliedTargets.contains { fanID, targetRPM in
            guard let observedTarget = fanReadings.first(where: {
                $0.index == fanID
            })?.targetRPM else {
                // Missing optional telemetry is not evidence that the Helper's
                // verified SMC readback failed.
                return false
            }
            let tolerance = max(25, Int(Double(targetRPM) * 0.02))
            return abs(observedTarget - targetRPM) > tolerance
        }
        if hasExplicitMismatch {
            clearObservedMode()
        }
    }

    private func hardwareCapabilityChanged(
        _ fanReadings: [SystemFanReading]?
    ) -> Bool {
        guard !lastAppliedHardwareRanges.isEmpty else { return false }
        guard let fanReadings,
              Set(fanReadings.map(\.index)).count == fanReadings.count,
              Set(fanReadings.map(\.index)) == Set(lastAppliedHardwareRanges.keys) else {
            return true
        }
        return lastAppliedHardwareRanges.contains { fanID, range in
            guard let reading = fanReadings.first(where: { $0.index == fanID }),
                  let minimumRPM = reading.minimumRPM,
                  let maximumRPM = reading.maximumRPM else {
                return true
            }
            return minimumRPM != range.minimumRPM || maximumRPM != range.maximumRPM
        }
    }

    private func beginRestoreRecovery() {
        guard !startupRecoveryFailureLatched else {
            lastMessage = Self.startupRecoveryFailureMessage
            return
        }
        reconnectRequiresAutomaticRestore = true
        guard helperStatus == .enabled else { return }
        guard reconnectBackoff.permitsAttempt(at: reconnectClock()), !reconnectInFlight else {
            scheduleAutomaticReconnect()
            return
        }
        // Never cancel/recreate the first attempt from an interruption callback.
        guard restoreRecoveryTask == nil else { return }
        let failureReason = lastMessage
        let pendingMessage = [failureReason, L10n.text(
            "正在请求恢复系统自动控制，结果尚未确认。",
            "Requesting restoration of automatic system control; the result is unconfirmed."
        )].compactMap { $0 }.joined(separator: "\n")
        lastMessage = pendingMessage
        let recoveryGeneration = controlIntentGeneration
        restoreRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                restoreRecoveryTask = nil
                scheduleAutomaticReconnect()
            }
            // Preserve bounded recovery for an authenticated RPC refusal.
            // Transport failures stop this worker; only the shared scheduler
            // may attempt the next connection after its backoff deadline.
            for attempt in 0..<3 {
                guard !Task.isCancelled, !startupRecoveryFailureLatched else { return }
                if attempt > 0 {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                do {
                    let reply = try await send(.restoreAutomatic)
                    if reply.success {
                        reconnectRequiresAutomaticRestore = false
                        isHelperReachable = true
                        if controlIntentGeneration == recoveryGeneration, lastMessage == pendingMessage {
                            lastMessage = [failureReason, L10n.text(
                                "Helper 已确认恢复请求完成；当前硬件模式仍待确认。",
                                "Helper confirmed completion of the restore request; the current hardware mode remains unconfirmed."
                            )].compactMap { $0 }.joined(separator: "\n")
                        }
                        return
                    }
                } catch {
                    // Keep restoration due for the next trusted connection.
                    return
                }
            }
            if controlIntentGeneration == recoveryGeneration, lastMessage == pendingMessage {
                lastMessage = [failureReason, L10n.text(
                    "恢复请求未获确认，请检查辅助程序连接与风扇状态。",
                    "The restore request was not confirmed. Check the helper connection and fan state."
                )].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    /// Both XPC callbacks and request completions enter this same failure gate.
    /// Retiring the exact connection first makes duplicate/stale callbacks inert.
    func handleUnexpectedHelperInvalidation() {
        guard connection != nil || isHelperReachable || reconnectInFlight
                || selectedMode != .systemAutomatic || observedMode != nil else { return }
        recordTransportFailure(FanControlConnectionError.connectionChanged,
                               generation: connectionGeneration)
    }

    private func recordTransportFailure(_ error: any Error, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        let oldConnection = connection
        connection = nil
        connectionGeneration &+= 1
        oldConnection?.invalidate()
        reconnectRequiresAutomaticRestore = reconnectRequiresAutomaticRestore
            || selectedMode != .systemAutomatic || observedMode != nil
            || !lastAppliedTargets.isEmpty || curveLeaseID != nil
        reconnectBackoff.recordFailure(at: reconnectClock(), jitter: reconnectJitter())
        resetControlState()
        recordHelperConnectionFailure(error)
        scheduleAutomaticReconnect()
    }

    private func installLifecycleObservers() {
        // Returning from approval settings is a lifecycle event, not an
        // availability read. Re-query registration and use the same retry gate.
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.connectHelper()
            }
        })
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willPowerOffNotification,
        ]
        lifecycleObservers += names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.selectedMode != .systemAutomatic else { return }
                    await self.prepareForTermination()
                    self.lastMessage = L10n.text(
                        "系统状态已改变；自定义控制已停止，硬件模式等待重新验证。",
                        "The system state changed; custom control stopped and the hardware mode is awaiting verification."
                    )
                }
            }
        }
        lifecycleObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestSnapshot = nil
                    await self.connectHelper()
                }
            }
        )
    }

    private func send(_ request: FanControlHelperRequest,
                      allowsLegacyRemovalFallback: Bool = false) async throws -> FanControlHelperReply {
        guard !isDataOnlyFixture else { throw CancellationError() }
        try Task.checkCancellation()
        if startupRecoveryFailureLatched, request.operation != .ping, !request.isMacMiniSleepRecoveryRequest {
            return try FanControlHelperReply(operation: request.operation, success: false,
                message: Self.startupRecoveryFailureMessage, appliedTargetRPMByFan: [:],
                errorCode: .fanCrashRecoveryFailed).validated(for: request)
        }
        if requestSender == nil, !(await resolveBundledHelperSigningTrust()) {
            throw FanControlConnectionError.untrustedBundledHelper
        }
        let isConnectionAttempt = !isHelperReachable || (requestSender == nil && connection == nil)
        if isConnectionAttempt {
            guard !reconnectInFlight else { throw FanControlConnectionError.reconnectInProgress }
            guard reconnectBackoff.permitsAttempt(at: reconnectClock()) else {
                throw FanControlConnectionError.reconnectDeferred
            }
            reconnectInFlight = true
            if requestSender != nil { connectionGeneration &+= 1 }
        }
        defer {
            if isConnectionAttempt { reconnectInFlight = false }
            scheduleAutomaticReconnect()
        }
        // Signing preflight completes before admission. Connection creation in
        // transport cannot yield between this gate and assigning the connection.
        var generation = connectionGeneration
        do {
            let reply = try await performSend(request, generation: &generation)
            guard generation == connectionGeneration else {
                throw FanControlConnectionError.connectionChanged
            }
            if reply.success, !startupRecoveryFailureLatched {
                reconnectBackoff.reset()
                cancelAutomaticReconnect()
                isHelperReachable = true
            }
            return reply
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if case FanControlConnectionError.untrustedBundledHelper = error {
                // Local signing failures never induce repeated XPC attempts.
                throw error
            }
            // A decoded v2/v3 response is an authenticated protocol mismatch,
            // not a transport refusal. Preserve the existing removal-only
            // fallback on this exact connection; all other mismatches back off.
            if allowsLegacyRemovalFallback,
               request.operation == .setMacMiniMode, request.macMiniMode == .off,
               case FanControlHelperProtocolError.unsupportedProtocolVersion(let version) = error,
               [2, 3].contains(version) {
                throw error
            }
            recordTransportFailure(error, generation: generation)
            throw error
        }
    }

    private func performSend(_ request: FanControlHelperRequest,
                             generation: inout UInt64) async throws -> FanControlHelperReply {
        let response: FanControlHelperReply
        var requestConnectionGeneration: UInt64?
        PerformanceTelemetry.signposter.emitEvent("XPCRequest")
        if let requestSender {
            response = try await withCheckedThrowingContinuation { continuation in
                let completion = FanControlReplyCompletion(continuation)
                armTimeout(for: request, completion: completion)
                Task { @MainActor in
                    do {
                        completion.resume(returning: try await requestSender(request))
                    } catch {
                        completion.resume(throwing: error)
                    }
                }
            }
        } else {
            guard bundledHelperSigningIsTrusted == true else {
                throw FanControlConnectionError.untrustedBundledHelper
            }
            let requestData = try request.encodedForTransport()
            let connection = helperConnection()
            generation = connectionGeneration
            requestConnectionGeneration = connectionGeneration
            response = try await withCheckedThrowingContinuation { continuation in
                let completion = FanControlReplyCompletion(continuation)
                armTimeout(for: request, completion: completion)
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                    completion.resume(throwing: error)
                }
                guard let helper = proxy as? FanControlHelperProtocol else {
                    completion.resume(throwing: FanControlConnectionError.invalidRemoteObject)
                    return
                }
                helper.execute(requestData) { @Sendable replyData in
                    do {
                        completion.resume(returning: try FanControlHelperReply.decodeFromTransport(replyData))
                    } catch {
                        completion.resume(throwing: error)
                    }
                }
            }
        }
        if let requestConnectionGeneration,
           requestConnectionGeneration != connectionGeneration {
            throw FanControlConnectionError.connectionChanged
        }
        PerformanceTelemetry.signposter.emitEvent("XPCReply")
        let validated = try response.validated(for: request)
        if validated.errorCode == .fanCrashRecoveryFailed {
            latchStartupRecoveryFailure()
            return validated.replacingMessage(Self.startupRecoveryFailureMessage)
        }
        if request.operation == .ping, validated.success { startupRecoveryFailureLatched = false }
        return validated
    }

    private func latchStartupRecoveryFailure() {
        startupRecoveryFailureLatched = true
        cancelAutomaticReconnect()
        helperConnectionNeedsAttention = false
        reconnectRequiresAutomaticRestore = false
        restoreRecoveryTask?.cancel()
        restoreRecoveryTask = nil
        resetControlState()
        lastMessage = Self.startupRecoveryFailureMessage
        connection?.invalidate()
        connection = nil
    }

    private static var startupRecoveryFailureMessage: String {
        L10n.text(FanControlStartupSafety.failureMessageChinese, FanControlStartupSafety.failureMessageEnglish)
    }

    private func armTimeout(
        for request: FanControlHelperRequest,
        completion: FanControlReplyCompletion
    ) {
        switch request.operation {
        case .apply, .activateFanCurve, .updateFanCurve:
            completion.armTimeout(after: fanWriteRequestTimeout)
        case .renewFanControlLease, .restoreAutomatic, .validateFanCurve,
             .getFanCurveRuntimeState, .deactivateFanCurve:
            completion.armTimeout(after: helperRequestTimeout)
        case .readPowerConfiguration, .applyPowerMode, .readMacMiniMode, .setMacMiniMode:
            completion.armTimeout(after: FanControlSafetyPolicy.powerModeRequestTimeout)
        case .samplePowerMetrics:
            completion.armTimeout(after: PowermetricsExecutionPolicy.timeoutSeconds + 1)
        case .ping:
            completion.armTimeout(after: helperRequestTimeout)
        }
    }

    private func helperConnection() -> NSXPCConnection {
        if let connection { return connection }

        let newConnection = NSXPCConnection(
            machServiceName: Self.helperLabel,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: FanControlHelperProtocol.self
        )
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            Task { @MainActor in
                guard let self, let newConnection, self.connection === newConnection else { return }
                self.handleUnexpectedHelperInvalidation()
            }
        }
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            Task { @MainActor in
                guard let self, let newConnection, self.connection === newConnection else { return }
                self.recordTransportFailure(FanControlConnectionError.connectionChanged,
                                            generation: self.connectionGeneration)
            }
        }
        connectionGeneration &+= 1
        connection = newConnection
        newConnection.resume()
        return newConnection
    }

    private func waitForHelper() async throws -> FanControlHelperReply {
        // Exactly one ping. Automatic retry is owned by the monotonic scheduler.
        let reply = try await send(.ping)
        if reply.success {
            helperConnectionNeedsAttention = false
            if !reconnectRequiresAutomaticRestore {
                lastMessage = L10n.text("辅助程序已重新连接；当前硬件模式仍待确认。", "The helper reconnected; the hardware mode still needs verification.")
            }
            if reconnectRequiresAutomaticRestore { beginRestoreRecovery() }
        }
        return reply
    }

    private static func connectionRetryMessage(for error: any Error) -> String {
        if let error = error as? FanControlHelperProtocolError {
            switch error {
            case .unsupportedProtocolVersion, .missingProtocolVersion:
                return L10n.text("辅助程序需要更新，正在重新连接…", "The helper needs an update; reconnecting…")
            default: break
            }
        }
        return L10n.text("辅助程序连接中断，正在重新连接…", "The helper connection was interrupted; reconnecting…")
    }

    private func recordHelperConnectionFailure(_ error: any Error) {
        if startupRecoveryFailureLatched {
            lastMessage = Self.startupRecoveryFailureMessage
            return
        }
        if !helperConnectionNeedsAttention { helperConnectionNeedsAttention = true }
        let message = [error.localizedDescription, L10n.text(
            "辅助程序连接未获确认，可能需要更新或重新批准。请点击“重新连接”；仍失败时，在“系统设置 → 通用 → 登录项与扩展”中重新批准本应用的后台项目。旧助手若不支持自动更新，需要按系统批准流程重新启用。当前硬件模式尚未确认。",
            "The helper connection is unconfirmed and may need an update or approval. Choose Reconnect. If it still fails, approve this app's background item again in System Settings → General → Login Items & Extensions. A helper without automatic update support needs to be enabled again through system approval. The current hardware mode is unconfirmed."
        )].joined(separator: "\n")
        isHelperReachable = false
        clearObservedMode()
        let prefix = Self.connectionRetryMessage(for: error)
        let restoreMessage = reconnectRequiresAutomaticRestore ? L10n.text(
            "恢复系统自动控制尚未确认；受信任连接恢复后将再次请求。",
            "Restoration of automatic system control remains unconfirmed; it will be requested after a trusted connection returns."
        ) : nil
        let feedback = [prefix, message, restoreMessage].compactMap { $0 }.joined(separator: "\n")
        if lastMessage != feedback { lastMessage = feedback }
    }

    private func currentServiceStatus() -> SMAppService.Status {
        serviceStatusProvider?() ?? service.status
    }

    private func registerService() async throws {
        if let serviceRegistrar {
            try serviceRegistrar()
        } else {
            guard await resolveBundledHelperSigningTrust() else {
                throw FanControlConnectionError.untrustedBundledHelper
            }
            try service.register()
        }
    }

    private func resolveBundledHelperSigningTrust() async -> Bool {
        if let bundledHelperSigningIsTrusted {
            return bundledHelperSigningIsTrusted
        }
        let trusted = await Self.bundledHelperSigningTrustTask.value
        bundledHelperSigningIsTrusted = trusted
        return trusted
    }

    private func currentHelperStatus() -> FanControlHelperStatus {
        Self.resolvedStatus(
            serviceStatus: currentServiceStatus(),
            legacyArtifactsPresent: legacyArtifactsPresentProvider(),
            legacyArtifactsCurrent: legacyArtifactsCurrentProvider()
        )
    }

    static func resolvedStatus(
        serviceStatus: SMAppService.Status,
        legacyArtifactsPresent: Bool,
        legacyArtifactsCurrent: Bool
    ) -> FanControlHelperStatus {
        if legacyArtifactsPresent {
            return legacyArtifactsCurrent ? .enabled : .needsMigration
        }
        return switch serviceStatus {
        case .notRegistered:
            .notRegistered
        case .requiresApproval:
            .requiresApproval
        case .enabled:
            .enabled
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    private static func resolvedStatus(
        _ status: SMAppService.Status
    ) -> FanControlHelperStatus {
        Self.resolvedStatus(
            serviceStatus: status,
            legacyArtifactsPresent: LegacyFanControlHelperInstaller
                .installedArtifactsPresent(),
            legacyArtifactsCurrent: LegacyFanControlHelperInstaller
                .installedArtifactsCurrent()
        )
    }

    private static func storedDouble(
        _ defaults: UserDefaults,
        key: String,
        fallback: Double
    ) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private static func storedCurveConfiguration(
        _ defaults: UserDefaults,
        legacyLowTemperature: Double,
        legacyHighTemperature: Double
    ) -> FanCurveConfiguration {
        if let data = defaults.data(forKey: FanControlPreferences.curveConfigurationKey),
           let configuration = try? JSONDecoder().decode(
               FanCurveConfiguration.self,
               from: data
           ) {
            return configuration.normalized()
        }
        return .migrated(
            lowTemperature: legacyLowTemperature,
            highTemperature: legacyHighTemperature
        )
    }

    private static func normalizedFraction(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }

    private static func manualEntryFractions(
        fanReadings: [SystemFanReading]?
    ) -> [Int: Double] {
        guard let fanReadings,
              !fanReadings.isEmpty,
              Set(fanReadings.map(\.index)).count == fanReadings.count else {
            return [:]
        }
        return fanReadings.reduce(into: [Int: Double]()) { result, reading in
            if let fraction = manualEntryFraction(reading) {
                result[reading.index] = fraction
            }
        }
    }

    private static func manualEntryFraction(
        _ reading: SystemFanReading
    ) -> Double? {
        guard let minimumRPM = reading.minimumRPM,
              let maximumRPM = reading.maximumRPM,
              minimumRPM >= 0,
              maximumRPM > minimumRPM,
              reading.actualRPM >= 0 else { return nil }
        return normalizedFraction(
            Double(reading.actualRPM - minimumRPM)
                / Double(maximumRPM - minimumRPM)
        )
    }

    private static func manualFractions(
        targets: [Int: Int],
        fanReadings: [SystemFanReading]
    ) -> [Int: Double] {
        targets.reduce(into: [Int: Double]()) { result, entry in
            guard let reading = fanReadings.first(where: { $0.index == entry.key }),
                  let minimumRPM = reading.minimumRPM,
                  let maximumRPM = reading.maximumRPM,
                  maximumRPM > minimumRPM else { return }
            result[entry.key] = normalizedFraction(
                Double(entry.value - minimumRPM)
                    / Double(maximumRPM - minimumRPM)
            )
        }
    }

    private static func curveRange(_ reading: SystemFanReading) -> FanCurveFanRange? {
        guard let minimumRPM = reading.minimumRPM,
              let maximumRPM = reading.maximumRPM,
              minimumRPM >= 0,
              maximumRPM > minimumRPM,
              reading.actualRPM >= 0 else { return nil }
        return FanCurveFanRange(
            fanID: reading.index,
            minimumRPM: minimumRPM,
            maximumRPM: maximumRPM,
            actualRPM: reading.actualRPM
        )
    }

    private static func availableCurveSensors(
        in snapshot: SystemMonitorSnapshot
    ) -> [FanCurveSensor] {
        let readings = snapshot.temperatureReadings ?? []
        var result: [FanCurveSensor] = []
        if temperature(for: .chipMaximum, in: snapshot) != nil {
            result.append(.chipMaximum)
        }
        if readings.contains(where: { cpuTemperatureZones.contains($0.zone) }) {
            result.append(.cpu)
        }
        if readings.contains(where: { $0.zone == .gpu }) {
            result.append(.gpu)
        }
        return result
    }

    private static let cpuTemperatureZones: Set<SystemTemperatureZone> = [
        .chip, .soc, .performanceCores, .superCores, .efficiencyCores,
    ]

    private static let chipTemperatureZones = cpuTemperatureZones.union([.gpu])

    private static func temperature(
        for sensor: FanCurveSensor,
        in snapshot: SystemMonitorSnapshot
    ) -> Double? {
        let readings = snapshot.temperatureReadings ?? []
        let values: [Double] = switch sensor {
        case .chipMaximum:
            readings.filter { chipTemperatureZones.contains($0.zone) }.map(\.celsius)
        case .cpu:
            readings.filter { cpuTemperatureZones.contains($0.zone) }.map(\.celsius)
        case .gpu:
            readings.filter { $0.zone == .gpu }.map(\.celsius)
        case .performanceCore:
            readings.filter {
                $0.zone == .performanceCores || $0.zone == .superCores
            }.map(\.celsius)
        case .efficiencyCore:
            readings.filter { $0.zone == .efficiencyCores }.map(\.celsius)
        }
        return values.filter { $0.isFinite }.max()
    }

    private static func curveError(from reply: FanControlHelperReply) -> FanCurveError {
        guard let rawValue = reply.errorCode?.rawValue else {
            return .curveActivationFailed
        }
        return FanCurveError(rawValue: rawValue) ?? .curveActivationFailed
    }

    private static func curveMessage(for reply: FanControlHelperReply) -> String {
        reply.errorCode == .fanCrashRecoveryFailed
            ? startupRecoveryFailureMessage
            : curveMessage(for: curveError(from: reply))
    }

    private static func curveMessage(for error: FanCurveError) -> String {
        switch error {
        case .invalidCurvePointCount:
            L10n.text("风扇曲线必须包含 3–8 个控制点。", "A fan curve must contain 3–8 control points.")
        case .invalidCurveTemperature:
            L10n.text("曲线温度必须是 25–100°C 的有效数字。", "Curve temperatures must be finite values from 25–100°C.")
        case .invalidCurvePercentage:
            L10n.text("风扇输出必须是 0–100% 的有效数字。", "Fan output must be a finite value from 0–100%.")
        case .nonIncreasingTemperatures:
            L10n.text("曲线温度必须从低到高排列，且相邻至少间隔 2°C。", "Curve temperatures must increase with at least 2°C between points.")
        case .decreasingFanPercentage:
            L10n.text("温度升高时，风扇百分比不能降低。", "Fan percentage cannot decrease as temperature rises.")
        case .missingFullSpeedPoint:
            L10n.text("曲线最后一个控制点必须达到 100%。", "The final curve point must reach 100%.")
        case .fullSpeedPointTooHot:
            L10n.text("曲线必须在 90°C 前达到 100%。", "The curve must reach 100% by 90°C.")
        case .unsupportedProfileVersion:
            L10n.text("该风扇曲线版本不受支持。", "This fan-curve version is unsupported.")
        case .unsupportedSensor:
            L10n.text("当前设备不支持所选温度传感器。", "The selected temperature sensor is unavailable on this Mac.")
        case .invalidTargetFans:
            L10n.text("风扇目标与当前硬件不匹配。", "The selected fans do not match the current hardware.")
        case .sensorUnavailable:
            L10n.text("无法读取所选温度传感器。", "The selected temperature sensor could not be read.")
        case .sensorStale:
            L10n.text("温度数据已过期。", "The temperature data became stale.")
        case .fanRangeUnavailable:
            L10n.text("无法读取完整风扇范围，不能启动温控曲线。", "Complete fan ranges are unavailable, so the curve cannot start.")
        case .curveActivationFailed:
            L10n.text("无法确认温控曲线已启动。", "Fan-curve activation could not be confirmed.")
        case .curveUpdateFailed:
            L10n.text("无法确认温控曲线已更新。", "The fan-curve update could not be confirmed.")
        case .curveVerificationFailed:
            L10n.text("无法确认风扇目标转速已生效。", "The fan target could not be verified.")
        case .curveLeaseExpired:
            L10n.text("风扇控制租约已失效。", "The fan-control lease expired.")
        case .thermalProtectionActivated:
            L10n.text("系统温度较高，温控曲线不可继续。", "The system thermal state is high; the fan curve cannot continue.")
        }
    }
}

private enum FanControlConnectionError: LocalizedError {
    case invalidRemoteObject
    case connectionChanged
    case reconnectDeferred
    case reconnectInProgress
    case helperRejected(String)
    case timedOut
    case untrustedBundledHelper

    var errorDescription: String? {
        switch self {
        case .invalidRemoteObject:
            L10n.text(
                "无法连接受信任的风扇控制辅助程序。",
                "Could not connect to the trusted fan-control helper."
            )
        case .connectionChanged:
            L10n.text("辅助程序连接已中断或意外退出，正在重新核对。", "The helper connection was interrupted or exited unexpectedly and needs verification again.")
        case .reconnectDeferred, .reconnectInProgress:
            L10n.text("辅助程序正在等待重新连接，请稍后重试。", "The helper is waiting to reconnect; try again later.")
        case .helperRejected(let message):
            message
        case .timedOut:
            L10n.text(
                "风扇控制辅助程序响应超时，已请求恢复系统自动控制。",
                "The fan-control helper timed out; automatic system control was requested."
            )
        case .untrustedBundledHelper:
            L10n.text(
                "App 与高级硬件控制 Helper 的签名身份不一致，已拒绝连接。",
                "The app and advanced hardware-control helper signing identities do not match; the connection was rejected."
            )
        }
    }
}

private final class FanControlReplyCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<FanControlHelperReply, any Error>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<FanControlHelperReply, any Error>) {
        self.continuation = continuation
    }

    func armTimeout(after timeout: TimeInterval) {
        let task = Task.detached(priority: .high) { [self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            resume(throwing: FanControlConnectionError.timedOut)
        }

        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask?.cancel()
        timeoutTask = task
        lock.unlock()
    }

    func resume(returning reply: FanControlHelperReply) {
        takeContinuation()?.resume(returning: reply)
    }

    func resume(throwing error: any Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation()
        -> CheckedContinuation<FanControlHelperReply, any Error>? {
        lock.lock()
        let result = continuation
        continuation = nil
        let pendingTimeout = timeoutTask
        timeoutTask = nil
        lock.unlock()
        pendingTimeout?.cancel()
        return result
    }
}
