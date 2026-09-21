import Combine
import Foundation
import Network
import SystemConfiguration

struct MenuBarAuxiliaryMonitorDemand: Equatable, Sendable {
    let needsProcessorTelemetry: Bool
    let needsDiskIOSampling: Bool
    let needsNetworkInterface: Bool
    let needsPublicNetworkAddress: Bool
    let needsNetworkProcesses: Bool
    let needsStorageVolumes: Bool

    init(
        needsProcessorTelemetry: Bool,
        needsDiskIOSampling: Bool,
        needsNetworkInterface: Bool,
        needsPublicNetworkAddress: Bool,
        needsNetworkProcesses: Bool,
        needsStorageVolumes: Bool = false
    ) {
        self.needsProcessorTelemetry = needsProcessorTelemetry
        self.needsDiskIOSampling = needsDiskIOSampling
        self.needsNetworkInterface = needsNetworkInterface
        self.needsPublicNetworkAddress = needsPublicNetworkAddress
        self.needsNetworkProcesses = needsNetworkProcesses
        self.needsStorageVolumes = needsStorageVolumes
    }
}

struct MenuBarPowerHistoryPoint: Codable, Equatable, Sendable {
    let date: Date
    let chargePercent: Double?
    let batteryPowerWatts: Double?
    let isCharging: Bool?
    let powerSource: BatteryPowerSource?

    init(
        date: Date,
        chargePercent: Double?,
        batteryPowerWatts: Double?,
        isCharging: Bool? = nil,
        powerSource: BatteryPowerSource? = nil
    ) {
        self.date = date
        self.chargePercent = chargePercent
        self.batteryPowerWatts = batteryPowerWatts
        self.isCharging = isCharging
        self.powerSource = powerSource
    }

    var isValid: Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        let levelIsValid = chargePercent.map {
            $0.isFinite && (0...100).contains($0)
        } ?? true
        let powerIsValid = batteryPowerWatts.map(\.isFinite) ?? true
        return levelIsValid && powerIsValid
            && (chargePercent != nil || batteryPowerWatts != nil)
    }
}

enum MenuBarNetworkProcessSamplingState: Equatable, Sendable {
    case idle
    case sampling
    case available
    case unavailable
}

private struct MenuBarLocalMonitorData {
    var storageSnapshot: StorageCapacitySnapshot?
    var externalStorageVolumes: [MountedStorageVolumeSnapshot] = []
    var networkStorageVolumes: [MountedStorageVolumeSnapshot] = []
    var storageRefreshedAt: Date?
    var internalBatteryAvailability: InternalBatteryAvailability = .unknown
    var batterySnapshot: BatteryPowerSnapshot?
    var batteryElectricalSnapshot: NativeBatteryElectricalSnapshot?
    var batteryChargeLimitState: BatteryChargeLimitState?
    var batteryRefreshedAt: Date?
    var networkInterfaceSnapshot: NativeNetworkInterfaceSnapshot?
    var networkTopologySnapshot: NetworkTopologySnapshot?
    var networkInterfaceRefreshedAt: Date?
    var powerHistory: [MenuBarPowerHistoryPoint] = []
    var volumeName = L10n.text("启动磁盘", "Startup Disk")
    var isRefreshing = false
}

private struct MenuBarProcessorMonitorData {
    var telemetry: CPUPerformanceStateService.Snapshot?
    var refreshedAt: Date?
}

private struct MenuBarDiskMonitorData {
    var counters: NativeDiskIOCounters?
    var history: [NativeDiskIOPoint] = []
}

private struct MenuBarPublicNetworkData {
    var snapshot: PublicNetworkAddressSnapshot?
    var lastAttemptAt: Date?
    var networkSignature: String?
    var isRefreshing = false
}

private struct MenuBarNetworkProcessData {
    var snapshot: NativeNetworkProcessSnapshot?
    var lastAttemptAt: Date?
    var samplingState = MenuBarNetworkProcessSamplingState.idle
}

/// Bridges SystemConfiguration's background callback onto the state's existing
/// main-actor debounce without creating another polling loop.
private final class NetworkTopologyObservationRelay: @unchecked Sendable {
    weak var state: MenuBarAuxiliaryMonitorState?

    init(state: MenuBarAuxiliaryMonitorState) {
        self.state = state
    }

    nonisolated func scheduleRefresh() {
        Task { @MainActor [weak self] in
            self?.state?.scheduleNetworkTopologyRefresh()
        }
    }
}

/// A C callback must not inherit `MenuBarAuxiliaryMonitorState`'s main-actor
/// isolation because SystemConfiguration invokes it on its configured queue.
private func networkTopologyStoreCallback(
    _: SCDynamicStore,
    _: CFArray,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let relay = Unmanaged<NetworkTopologyObservationRelay>
        .fromOpaque(info)
        .takeUnretainedValue()
    relay.scheduleRefresh()
}

/// App-scoped owner for the supplemental monitor probes that are not part of
/// the primary one-second `SystemMonitorService` snapshot. Complex and geek
/// Panel surfaces register demand here so switching density never creates two
/// processor, disk-I/O, storage, battery, or network-interface probe tasks.
@MainActor
final class MenuBarAuxiliaryMonitorState: ObservableObject {
    typealias StatusWiFiProvider = @Sendable (Date) -> MenuBarWiFiStatusSnapshot
    @Published private(set) var statusWiFiSnapshot: MenuBarWiFiStatusSnapshot?
    private let statusWiFiProvider: StatusWiFiProvider
    private var statusWiFiTask: Task<Void, Never>?
    private var statusWiFiGeneration = 0
    typealias DiskCounterProvider = @Sendable () -> NativeDiskIOCounters?
    typealias StorageVolumeProvider = @Sendable () -> MountedStorageVolumeInventory
    typealias BatterySnapshotProvider = @Sendable () -> (
        BatteryPowerSnapshot?,
        NativeBatteryElectricalSnapshot?
    )
    typealias PublicNetworkAddressProvider = @Sendable () async -> PublicNetworkAddressSnapshot
    typealias NetworkProcessProvider = @Sendable () -> NativeNetworkProcessSnapshot?
    static let batteryHistorySamplingInterval: TimeInterval = 30
    static let visibleBatterySamplingInterval: TimeInterval = 2
    static let storageVolumeSamplingInterval: TimeInterval = 300
    static let diskIOSamplingInterval: Duration = .seconds(2)

    /// Each logical domain publishes one immutable value. A storage refresh or
    /// disk tick therefore invalidates the Panel once instead of once per field.
    @Published private var localData = MenuBarLocalMonitorData()
    @Published private var processorData = MenuBarProcessorMonitorData()
    @Published private var diskData = MenuBarDiskMonitorData()
    @Published private var publicNetworkData = MenuBarPublicNetworkData()
    @Published private var networkProcessData = MenuBarNetworkProcessData()

    var storageSnapshot: StorageCapacitySnapshot? { localData.storageSnapshot }
    var externalStorageVolumes: [MountedStorageVolumeSnapshot] {
        localData.externalStorageVolumes
    }
    var networkStorageVolumes: [MountedStorageVolumeSnapshot] {
        localData.networkStorageVolumes
    }
    var storageRefreshedAt: Date? { localData.storageRefreshedAt }
    var internalBatteryAvailability: InternalBatteryAvailability { localData.internalBatteryAvailability }
    var batterySnapshot: BatteryPowerSnapshot? { localData.batterySnapshot }
    var batteryElectricalSnapshot: NativeBatteryElectricalSnapshot? {
        localData.batteryElectricalSnapshot
    }
    var batteryChargeLimitState: BatteryChargeLimitState? {
        localData.batteryChargeLimitState
    }
    var batteryRefreshedAt: Date? { localData.batteryRefreshedAt }
    var networkInterfaceSnapshot: NativeNetworkInterfaceSnapshot? {
        localData.networkInterfaceSnapshot
    }
    var networkTopologySnapshot: NetworkTopologySnapshot? {
        localData.networkTopologySnapshot
    }
    var networkConnectionSnapshot: NetworkConnectionSnapshot {
        NetworkConnectionSnapshot.resolve(
            native: localData.networkInterfaceSnapshot,
            topology: localData.networkTopologySnapshot
        )
    }
    var networkInterfaceRefreshedAt: Date? { localData.networkInterfaceRefreshedAt }
    var publicNetworkAddressSnapshot: PublicNetworkAddressSnapshot? {
        publicNetworkData.snapshot
    }
    var isRefreshingPublicNetworkAddress: Bool { publicNetworkData.isRefreshing }
    var networkProcessSnapshot: NativeNetworkProcessSnapshot? {
        networkProcessData.snapshot
    }
    var networkProcessSamplingState: MenuBarNetworkProcessSamplingState {
        networkProcessData.samplingState
    }
    var isRefreshingNetworkProcesses: Bool {
        networkProcessData.samplingState == .sampling
    }
    var powerHistory: [MenuBarPowerHistoryPoint] { localData.powerHistory }
    var processorTelemetry: CPUPerformanceStateService.Snapshot? { processorData.telemetry }
    var processorTelemetryRefreshedAt: Date? { processorData.refreshedAt }
    var volumeName: String { localData.volumeName }
    var isRefreshingLocalData: Bool {
        localData.isRefreshing
            || publicNetworkData.isRefreshing
            || networkProcessData.samplingState == .sampling
    }
    var nativeDiskIOCounters: NativeDiskIOCounters? { diskData.counters }
    var nativeDiskIOHistory: [NativeDiskIOPoint] { diskData.history }

    private var consumers: [UUID: MenuBarAuxiliaryMonitorDemand] = [:]
    private var isPaused = false
    var onBatterySample: ((BatteryPowerSnapshot?, NativeBatteryElectricalSnapshot?) -> Void)?
    private var batteryRefreshTask: Task<Void, Never>?
    private var storageRefreshTask: Task<Void, Never>?
    private var networkInterfaceRefreshTask: Task<Void, Never>?
    private var localDataGeneration = 0
    private var storageVolumesRefreshedAt: Date?
    private var processorTelemetryTask: Task<Void, Never>?
    private var processorTelemetryGeneration = 0
    private var nativeDiskIOSamplingTask: Task<Void, Never>?
    private var nativeDiskIOGeneration = 0
    private var backgroundDiskRefreshTask: Task<Void, Never>?
    private var backgroundDiskRefreshGeneration = 0
    private var backgroundDiskRefreshedAt: Date?
    private let publicNetworkConsentProvider: @Sendable () -> Bool
    private var privacySubscription: AnyCancellable?
    private var lastNetworkConsent = [PublicNetworkConsent.allowsAddress, PublicNetworkConsent.allowsCountry]
    private var publicNetworkAddressTask: Task<Void, Never>?
    private var publicNetworkAddressGeneration = 0
    private var pendingPublicNetworkSignature: String?
    private var networkProcessTask: Task<Void, Never>?
    private var networkProcessGeneration = 0
    private var networkPathMonitor: NWPathMonitor?
    private let networkPathMonitorQueue = DispatchQueue(
        label: "StorageCleanerMac.NetworkTopologyPath"
    )
    private let networkConfigurationStoreQueue = DispatchQueue(
        label: "StorageCleanerMac.NetworkTopologyConfiguration"
    )
    private var networkConfigurationStore: SCDynamicStore?
    private lazy var networkTopologyObservationRelay = NetworkTopologyObservationRelay(state: self)
    private var networkTopologyRefreshTask: Task<Void, Never>?
    private let diskCounterProvider: DiskCounterProvider
    private let storageVolumeProvider: StorageVolumeProvider
    private let batteryAvailabilityProvider: @Sendable () -> InternalBatteryAvailability
    private let batterySnapshotProvider: BatterySnapshotProvider
    private let publicNetworkAddressProvider: PublicNetworkAddressProvider
    private let networkProcessProvider: NetworkProcessProvider
    private let metricHistoryStore: MetricHistoryStore?
    private let powerHistoryURL: URL?
    private var batteryPowerSourceObserver: BatteryPowerSourceObserver?
    private var lastPowerHistoryPersistedAt: Date?
    private var powerHistorySaveTask: Task<Void, Never>?

    init(
        statusWiFiProvider: @escaping StatusWiFiProvider = {
            NativeNetworkInterfaceService.statusWiFiSnapshot(now: $0)
        },
        batteryAvailabilityProvider: @escaping @Sendable () -> InternalBatteryAvailability = {
            BatteryPowerService.internalBatteryAvailability()
        },
        diskCounterProvider: @escaping DiskCounterProvider = {
            NativeDiskIOMonitorService.counters()
        },
        storageVolumeProvider: @escaping StorageVolumeProvider = {
            MountedStorageVolumeService.snapshots()
        },
        batterySnapshotProvider: @escaping BatterySnapshotProvider = {
            (
                BatteryPowerService.internalBatterySnapshot(),
                NativeBatteryElectricalService.snapshot()
            )
        },
        publicNetworkAddressProvider: @escaping PublicNetworkAddressProvider = {
            await PublicNetworkAddressService.snapshot()
        },
        publicNetworkConsentProvider: @escaping @Sendable () -> Bool = { PublicNetworkConsent.allowsAddress },
        networkProcessProvider: @escaping NetworkProcessProvider = {
            NativeNetworkProcessService.snapshot(
                cancellationCheck: { Task.isCancelled }
            )
        },
        metricHistoryStore: MetricHistoryStore? = nil,
        powerHistoryURL: URL? = MenuBarPowerHistoryStore.defaultURL
    ) {
        self.statusWiFiProvider = statusWiFiProvider
        self.batteryAvailabilityProvider = batteryAvailabilityProvider
        self.diskCounterProvider = diskCounterProvider
        self.storageVolumeProvider = storageVolumeProvider
        self.batterySnapshotProvider = batterySnapshotProvider
        self.publicNetworkAddressProvider = publicNetworkAddressProvider
        self.publicNetworkConsentProvider = publicNetworkConsentProvider
        self.networkProcessProvider = networkProcessProvider
        self.metricHistoryStore = metricHistoryStore
        self.powerHistoryURL = powerHistoryURL
        if metricHistoryStore == nil, let powerHistoryURL {
            localData.powerHistory = MenuBarPowerHistoryStore.load(from: powerHistoryURL)
        }
        batteryPowerSourceObserver = BatteryPowerSourceObserver { [weak self] in
            self?.refreshFromPowerSourceNotification()
        }
        batteryPowerSourceObserver?.start()
        privacySubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let consent = [PublicNetworkConsent.allowsAddress, PublicNetworkConsent.allowsCountry]
                    guard consent != self.lastNetworkConsent else { return }
                    self.lastNetworkConsent = consent
                    self.cancelPublicNetworkAddressRefresh()
                    self.publicNetworkData = MenuBarPublicNetworkData()
                    if PublicNetworkConsent.allowsAddress {
                        self.refreshPublicNetworkAddressIfReady(force: true)
                    }
                }
            }
    }

    func restoreHistory(_ snapshot: MetricHistorySnapshot) {
        var restoredLocalData = localData
        restoredLocalData.powerHistory = mergedHistory(
            snapshot.power,
            with: localData.powerHistory,
            date: \.date
        )
        localData = restoredLocalData

        var restoredDiskData = diskData
        restoredDiskData.history = mergedHistory(
            snapshot.diskIO,
            with: diskData.history,
            date: \.date
        )
        diskData = restoredDiskData
    }

    func registerConsumer(
        _ id: UUID,
        demand: MenuBarAuxiliaryMonitorDemand,
        paused: Bool
    ) {
        cancelBackgroundDiskRefresh()
        consumers[id] = demand
        isPaused = paused
        reconcile(forceLocalData: false, forceProcessor: false)
    }

    func updateConsumer(
        _ id: UUID,
        demand: MenuBarAuxiliaryMonitorDemand
    ) {
        guard consumers[id] != demand else { return }
        consumers[id] = demand
        reconcile(forceLocalData: false, forceProcessor: false)
    }

    func unregisterConsumer(_ id: UUID) {
        consumers.removeValue(forKey: id)
        if consumers.isEmpty {
            cancelLocalDataRefresh()
            cancelProcessorTelemetryRefresh()
            stopNativeDiskIOSampling()
            cancelPublicNetworkAddressRefresh()
            cancelNetworkProcessRefresh()
            stopNetworkTopologyObservation()
        } else {
            reconcile(forceLocalData: false, forceProcessor: false)
        }
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            statusWiFiGeneration &+= 1
            statusWiFiTask?.cancel()
            cancelLocalDataRefresh()
            cancelProcessorTelemetryRefresh()
            stopNativeDiskIOSampling()
            cancelBackgroundDiskRefresh()
            cancelPublicNetworkAddressRefresh()
            cancelNetworkProcessRefresh()
            stopNetworkTopologyObservation()
        } else {
            reconcile(forceLocalData: true, forceProcessor: true)
        }
    }

    func refreshFromPrimaryMonitorUpdate() {
        guard !isPaused, !consumers.isEmpty else { return }
        refreshLocalData()
        refreshProcessorTelemetry()
        refreshPublicNetworkAddressIfReady()
        refreshNetworkProcesses()
    }

    func refreshNetworkConnectionSnapshot() {
        refreshLocalData(
            forceNetworkInterface: true,
            networkOnly: true,
            refreshesPublicAddressOnNetworkChange: false
        )
    }

    private func refreshFromPowerSourceNotification() {
        guard !isPaused else { return }
        if consumers.isEmpty {
            refreshBackgroundBatteryHistory(force: true)
        } else {
            refreshLocalData(force: true)
        }
    }

    func refreshBackgroundBatteryHistory(force: Bool = false) {
        guard !isPaused,
              consumers.isEmpty,
              batteryRefreshTask == nil else { return }

        let now = Date()
        guard force
            || batteryRefreshedAt.map({
                now.timeIntervalSince($0) >= Self.batteryHistorySamplingInterval
            }) != false else { return }

        refreshBattery(allowsNoConsumers: true)
    }

    private var hasPendingLocalReads: Bool {
        batteryRefreshTask != nil || storageRefreshTask != nil || networkInterfaceRefreshTask != nil
    }

    private func refreshBattery(allowsNoConsumers: Bool = false) {
        guard batteryRefreshTask == nil else { return }
        let generation = localDataGeneration
        let provider = batterySnapshotProvider
        let availabilityProvider = batteryAvailabilityProvider
        let previousAvailability = internalBatteryAvailability
        batteryRefreshTask = Task { @MainActor [weak self] in
            let resolvedBattery = await Task.detached(priority: .utility) {
                (provider(), previousAvailability == .unknown ? availabilityProvider() : previousAvailability)
            }.value
            guard let self else { return }
            batteryRefreshTask = nil
            guard canPublishLocalData(generation, allowsNoConsumers: allowsNoConsumers) else {
                if !isPaused, !consumers.isEmpty { refreshLocalData() }
                return
            }
            // Merge into the latest state: a slow volume read must neither hold
            // a battery sample nor overwrite a newer battery/network result.
            var nextLocalData = localData
            recordBatterySample(resolvedBattery.0, availability: resolvedBattery.1, in: &nextLocalData)
            nextLocalData.isRefreshing = hasPendingLocalReads
            localData = nextLocalData
        }
        var refreshingData = localData
        refreshingData.isRefreshing = true
        localData = refreshingData
    }

    /// The menu-bar agent already owns the primary refresh cadence. Reusing it
    /// for one disk counter read per minute preserves real history while the
    /// panel is closed without keeping the one-second detail sampler alive.
    func refreshBackgroundDiskHistory(force: Bool = false) {
        guard !isPaused,
              consumers.isEmpty,
              nativeDiskIOSamplingTask == nil,
              backgroundDiskRefreshTask == nil else { return }

        let now = Date()
        guard force
            || backgroundDiskRefreshedAt.map({ now.timeIntervalSince($0) >= 60 }) != false else {
            return
        }

        backgroundDiskRefreshGeneration &+= 1
        let generation = backgroundDiskRefreshGeneration
        let counterProvider = diskCounterProvider
        backgroundDiskRefreshTask = Task { @MainActor [weak self] in
            let current = await Task.detached(priority: .utility) {
                counterProvider()
            }.value
            guard let self else { return }
            backgroundDiskRefreshTask = nil
            if !isPaused, combinedDemand.needsDiskIOSampling { startNativeDiskIOSampling() }
            guard !Task.isCancelled,
                  generation == backgroundDiskRefreshGeneration,
                  !isPaused,
                  consumers.isEmpty,
                  nativeDiskIOSamplingTask == nil else { return }

            var nextDiskData = diskData
            if let previous = nextDiskData.counters,
               let current,
               let point = NativeDiskIOMonitorService.throughput(
                   current: current,
                   previous: previous
               ) {
                MenuBarHistoryRetention.append(point, to: &nextDiskData.history, date: \.date)
                if let metricHistoryStore {
                    Task {
                        await metricHistoryStore.appendDiskIO(point)
                    }
                }
            }
            nextDiskData.counters = current
            diskData = nextDiskData
            backgroundDiskRefreshedAt = now
            backgroundDiskRefreshTask = nil
        }
    }

    func refreshBackgroundMetricHistory() {
        refreshBackgroundBatteryHistory()
        refreshBackgroundDiskHistory()
    }

    /// The resident status item uses the existing primary refresh clock. This
    /// demand does not register a visible panel or activate expensive probes.
    func refreshStatusWiFi(
        lowPower: Bool, force: Bool = false, now: Date = Date()
    ) {
        guard !isPaused, statusWiFiTask == nil else { return }
        let interval: TimeInterval = lowPower ? 30 : 5
        guard force || statusWiFiSnapshot.map({
            now.timeIntervalSince($0.sampledAt) >= interval
        }) != false else { return }
        statusWiFiGeneration &+= 1
        let generation = statusWiFiGeneration
        let provider = statusWiFiProvider
        statusWiFiTask = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) { provider(now) }.value
            guard let self else { return }
            statusWiFiTask = nil
            guard !Task.isCancelled, !isPaused, generation == statusWiFiGeneration else { return }
            statusWiFiSnapshot = snapshot
        }
    }

    func requestManualRefresh() {
        guard !isPaused, !consumers.isEmpty else { return }
        refreshLocalData(force: true)
        refreshProcessorTelemetry(force: true)
        refreshPublicNetworkAddressIfReady(force: true)
        refreshNetworkProcesses(force: true)
    }

    func refreshBatteryChargeLimitState() {
        var nextLocalData = localData
        nextLocalData.batteryChargeLimitState = BatteryFullChargeService.currentChargeLimitState()
        localData = nextLocalData
    }

    func setBatteryChargeTarget(
        _ target: BatteryChargeTarget
    ) async -> BatteryChargeTargetUpdateResult {
        let result = await BatteryFullChargeService.setPreferredTarget(target)
        if result == .applied {
            refreshBatteryChargeLimitState()
        }
        return result
    }

    var activeConsumerCount: Int { consumers.count }
    var isDiskIOSamplingActive: Bool { nativeDiskIOSamplingTask != nil }
    var isProcessorRefreshActive: Bool { processorTelemetryTask != nil }
    var isNetworkProcessRefreshActive: Bool { networkProcessTask != nil }

    private var combinedDemand: MenuBarAuxiliaryMonitorDemand {
        MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: consumers.values.contains { $0.needsProcessorTelemetry },
            needsDiskIOSampling: consumers.values.contains { $0.needsDiskIOSampling },
            needsNetworkInterface: consumers.values.contains { $0.needsNetworkInterface },
            needsPublicNetworkAddress: consumers.values.contains { $0.needsPublicNetworkAddress },
            needsNetworkProcesses: consumers.values.contains { $0.needsNetworkProcesses },
            needsStorageVolumes: consumers.values.contains { $0.needsStorageVolumes }
        )
    }

    private func reconcile(forceLocalData: Bool, forceProcessor: Bool) {
        guard !isPaused, !consumers.isEmpty else { return }
        let demand = combinedDemand

        refreshLocalData(force: forceLocalData)
        if demand.needsProcessorTelemetry {
            refreshProcessorTelemetry(force: forceProcessor)
        } else {
            cancelProcessorTelemetryRefresh()
        }

        if demand.needsDiskIOSampling {
            startNativeDiskIOSampling()
        } else {
            stopNativeDiskIOSampling()
        }

        if demand.needsPublicNetworkAddress {
            refreshPublicNetworkAddressIfReady(force: forceLocalData)
        } else {
            cancelPublicNetworkAddressRefresh()
        }

        if demand.needsNetworkProcesses {
            refreshNetworkProcesses(force: forceLocalData)
        } else {
            cancelNetworkProcessRefresh()
        }

        if demand.needsNetworkInterface {
            startNetworkTopologyObservationIfNeeded()
        } else {
            stopNetworkTopologyObservation()
        }
    }

    private func refreshNetworkProcesses(force: Bool = false) {
        guard !isPaused,
              combinedDemand.needsNetworkProcesses,
              networkProcessTask == nil else { return }

        let now = Date()
        let refreshInterval = MenuBarPerformancePolicy.visibleProcessInterval
        guard force || networkProcessData.lastAttemptAt.map({
            now.timeIntervalSince($0) >= refreshInterval
        }) != false else { return }

        networkProcessGeneration &+= 1
        let generation = networkProcessGeneration
        let provider = networkProcessProvider
        var loadingData = networkProcessData
        loadingData.samplingState = .sampling
        loadingData.lastAttemptAt = now
        networkProcessData = loadingData

        networkProcessTask = Task { @MainActor [weak self] in
            let samplingTask = Task.detached(priority: .utility) {
                provider()
            }
            let snapshot = await withTaskCancellationHandler {
                await samplingTask.value
            } onCancel: {
                samplingTask.cancel()
            }

            guard let self else { return }
            networkProcessTask = nil
            guard !Task.isCancelled,
                  generation == networkProcessGeneration,
                  !isPaused,
                  combinedDemand.needsNetworkProcesses else {
                if !isPaused, combinedDemand.needsNetworkProcesses { refreshNetworkProcesses(force: true) }
                return
            }
            networkProcessData = MenuBarNetworkProcessData(
                snapshot: snapshot,
                lastAttemptAt: now,
                samplingState: snapshot == nil ? .unavailable : .available
            )
        }
    }

    private func cancelNetworkProcessRefresh() {
        networkProcessGeneration &+= 1
        networkProcessTask?.cancel()
        if networkProcessData.samplingState == .sampling {
            var nextData = networkProcessData
            nextData.samplingState = nextData.snapshot == nil ? .idle : .available
            networkProcessData = nextData
        }
    }

    private func refreshPublicNetworkAddress(
        force: Bool = false,
        networkSignature: String? = nil
    ) {
        guard publicNetworkConsentProvider(), !isPaused,
              combinedDemand.needsPublicNetworkAddress else { return }

        if publicNetworkAddressTask != nil {
            if let networkSignature,
               networkSignature != publicNetworkData.networkSignature {
                pendingPublicNetworkSignature = networkSignature
            }
            return
        }

        let now = Date()
        let resolvedNetworkSignature = networkSignature ?? publicNetworkData.networkSignature
        guard Self.shouldRefreshPublicNetworkAddress(
            force: force,
            networkSignature: resolvedNetworkSignature,
            previousNetworkSignature: publicNetworkData.networkSignature,
            lastAttemptAt: publicNetworkData.lastAttemptAt,
            hasPublicAddress: publicNetworkData.snapshot?.hasAddress == true,
            now: now
        ) else { return }

        publicNetworkAddressGeneration &+= 1
        let generation = publicNetworkAddressGeneration
        let provider = publicNetworkAddressProvider
        var loadingData = publicNetworkData
        loadingData.isRefreshing = true
        loadingData.lastAttemptAt = now
        publicNetworkData = loadingData

        publicNetworkAddressTask = Task { @MainActor [weak self] in
            let snapshot = await provider()
            guard let self,
                  !Task.isCancelled,
                  generation == publicNetworkAddressGeneration,
                  !isPaused,
                  combinedDemand.needsPublicNetworkAddress else { return }

            publicNetworkAddressTask = nil
            publicNetworkData = MenuBarPublicNetworkData(
                snapshot: snapshot,
                lastAttemptAt: now,
                networkSignature: resolvedNetworkSignature,
                isRefreshing: false
            )
            if let pendingNetworkSignature = pendingPublicNetworkSignature {
                pendingPublicNetworkSignature = nil
                if pendingNetworkSignature != resolvedNetworkSignature {
                    refreshPublicNetworkAddress(
                        force: false,
                        networkSignature: pendingNetworkSignature
                    )
                }
            }
        }
    }

    private func refreshPublicNetworkAddressIfReady(force: Bool = false) {
        let demand = combinedDemand
        guard demand.needsPublicNetworkAddress,
              !demand.needsNetworkInterface || localData.networkTopologySnapshot != nil else {
            return
        }
        refreshPublicNetworkAddress(
            force: force,
            networkSignature: localData.networkTopologySnapshot?.networkSignature
        )
    }

    static func shouldRefreshPublicNetworkAddress(
        force: Bool,
        networkSignature: String?,
        previousNetworkSignature: String?,
        lastAttemptAt: Date?,
        hasPublicAddress: Bool,
        now: Date
    ) -> Bool {
        if force { return true }
        if let networkSignature, networkSignature != previousNetworkSignature {
            return true
        }
        let retryInterval: TimeInterval = hasPublicAddress ? 15 * 60 : 60
        return lastAttemptAt.map { now.timeIntervalSince($0) >= retryInterval } ?? true
    }

    private func cancelPublicNetworkAddressRefresh() {
        publicNetworkAddressGeneration &+= 1
        publicNetworkAddressTask?.cancel()
        publicNetworkAddressTask = nil
        pendingPublicNetworkSignature = nil
        if publicNetworkData.isRefreshing {
            var nextData = publicNetworkData
            nextData.isRefreshing = false
            nextData.lastAttemptAt = nextData.snapshot?.generatedAt
            publicNetworkData = nextData
        }
    }

    private func refreshProcessorTelemetry(force: Bool = false) {
        guard !isPaused,
              combinedDemand.needsProcessorTelemetry,
              processorTelemetryTask == nil else { return }

        let now = Date()
        let refreshInterval: TimeInterval = 2
        guard force || processorTelemetryRefreshedAt.map({
            now.timeIntervalSince($0) >= refreshInterval
        }) != false else { return }

        processorTelemetryGeneration &+= 1
        let generation = processorTelemetryGeneration
        processorTelemetryTask = Task { @MainActor [weak self] in
            let dynamicSnapshot = await CPUPerformanceStateService.currentSnapshot()
            guard let self else { return }
            processorTelemetryTask = nil
            guard !Task.isCancelled,
                  generation == processorTelemetryGeneration else { return }
            let resolvedSnapshot = dynamicSnapshot ?? CPUPerformanceStateService.staticSnapshot()
            guard !isPaused, combinedDemand.needsProcessorTelemetry else { return }
            processorData = MenuBarProcessorMonitorData(
                telemetry: resolvedSnapshot,
                refreshedAt: Date()
            )
        }
    }

    private func cancelProcessorTelemetryRefresh() {
        processorTelemetryGeneration &+= 1
        processorTelemetryTask?.cancel()
    }

    private func startNativeDiskIOSampling() {
        guard !isPaused,
              combinedDemand.needsDiskIOSampling,
              nativeDiskIOSamplingTask == nil,
              backgroundDiskRefreshTask == nil else { return }

        nativeDiskIOGeneration &+= 1
        let generation = nativeDiskIOGeneration
        let counterProvider = diskCounterProvider
        nativeDiskIOSamplingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                nativeDiskIOSamplingTask = nil
                if generation != nativeDiskIOGeneration, !isPaused, combinedDemand.needsDiskIOSampling {
                    startNativeDiskIOSampling()
                }
            }
            guard !Task.isCancelled else { return }
            var previous = await Task.detached(priority: .utility) {
                counterProvider()
            }.value
            guard !Task.isCancelled,
                  generation == nativeDiskIOGeneration else { return }
            var initialDiskData = diskData
            initialDiskData.counters = previous
            diskData = initialDiskData

            while !Task.isCancelled,
                  generation == nativeDiskIOGeneration,
                  !isPaused,
                  combinedDemand.needsDiskIOSampling {
                do {
                    try await Task.sleep(for: Self.diskIOSamplingInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled,
                      generation == nativeDiskIOGeneration,
                      !isPaused,
                      combinedDemand.needsDiskIOSampling else { break }

                let current = await Task.detached(priority: .utility) {
                    counterProvider()
                }.value
                guard !Task.isCancelled,
                      generation == nativeDiskIOGeneration else { break }
                guard let current else {
                    previous = nil
                    var unavailableDiskData = diskData
                    unavailableDiskData.counters = nil
                    diskData = unavailableDiskData
                    continue
                }

                var nextDiskData = diskData
                if let previous,
                   let point = NativeDiskIOMonitorService.throughput(
                       current: current,
                       previous: previous
                   ) {
                    MenuBarHistoryRetention.append(
                        point,
                        to: &nextDiskData.history,
                        date: \.date
                    )
                    if let metricHistoryStore {
                        Task {
                            await metricHistoryStore.appendDiskIO(point)
                        }
                    }
                }
                nextDiskData.counters = current
                diskData = nextDiskData
                previous = current
            }

            if generation == nativeDiskIOGeneration {
                nativeDiskIOSamplingTask = nil
            }
        }
    }

    private func stopNativeDiskIOSampling() {
        nativeDiskIOGeneration &+= 1
        nativeDiskIOSamplingTask?.cancel()
    }

    private func cancelBackgroundDiskRefresh() {
        backgroundDiskRefreshGeneration &+= 1
        backgroundDiskRefreshTask?.cancel()
    }

    private func refreshLocalData(
        force: Bool = false,
        forceNetworkInterface: Bool = false,
        networkOnly: Bool = false,
        refreshesPublicAddressOnNetworkChange: Bool = true
    ) {
        guard !isPaused, !consumers.isEmpty else { return }

        let now = Date()
        let needsStorageCapacity = !networkOnly && (force
            || storageRefreshedAt.map { now.timeIntervalSince($0) >= 30 } != false
        )
        let needsStorageVolumes = !networkOnly
            && combinedDemand.needsStorageVolumes
            && (storageVolumesRefreshedAt.map {
                now.timeIntervalSince($0) >= Self.storageVolumeSamplingInterval
            } != false)
        let needsStorage = needsStorageCapacity || needsStorageVolumes
        // Capacity changes slowly; the visible power graph also contains watts
        // and current. Read it at 2s while observed, retain 30s background cadence.
        let needsBattery = !networkOnly && (force
            || batteryRefreshedAt.map {
                now.timeIntervalSince($0) >= Self.visibleBatterySamplingInterval - 0.05
            } != false
        )
        let needsNetworkInterface = combinedDemand.needsNetworkInterface
            && (force
                || forceNetworkInterface
                || networkInterfaceRefreshedAt.map { now.timeIntervalSince($0) >= 60 } != false)
        guard needsStorage || needsBattery || needsNetworkInterface else { return }

        let generation = localDataGeneration
        if needsStorage, storageRefreshTask == nil {
            let volumeProvider = needsStorageVolumes ? storageVolumeProvider : nil
            storageRefreshTask = Task { @MainActor [weak self] in
                let resolvedStorage = await Task.detached(priority: .utility) {
                    let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
                    return (
                        StorageCapacityService.snapshot(),
                        (try? rootURL.resourceValues(forKeys: [.volumeNameKey]).volumeName),
                        volumeProvider?()
                    )
                }.value
                guard let self else { return }
                storageRefreshTask = nil
                guard canPublishLocalData(generation) else {
                    if !isPaused, !consumers.isEmpty { refreshLocalData() }
                    return
                }
                var nextLocalData = localData
                nextLocalData.storageSnapshot = resolvedStorage.0
                if let volumes = resolvedStorage.2 {
                    nextLocalData.externalStorageVolumes = volumes.external
                    nextLocalData.networkStorageVolumes = volumes.network
                    storageVolumesRefreshedAt = Date()
                }
                nextLocalData.storageRefreshedAt = Date()
                if let resolvedName = resolvedStorage.1, !resolvedName.isEmpty {
                    nextLocalData.volumeName = resolvedName
                }
                nextLocalData.isRefreshing = hasPendingLocalReads
                localData = nextLocalData
            }
        }

        if needsBattery {
            refreshBattery()
        }

        if needsNetworkInterface, networkInterfaceRefreshTask == nil {
            networkInterfaceRefreshTask = Task { @MainActor [weak self] in
                let resolvedNetwork = await Task.detached(priority: .utility) {
                    (
                        NativeNetworkInterfaceService.snapshot(),
                        NativeNetworkInterfaceService.topologySnapshot()
                    )
                }.value
                guard let self else { return }
                networkInterfaceRefreshTask = nil
                guard canPublishLocalData(generation) else {
                    if !isPaused, !consumers.isEmpty { refreshLocalData() }
                    return
                }
                let previousSignature = localData.networkTopologySnapshot?.networkSignature
                PerformanceTelemetry.signposter.emitEvent("SnapshotRefresh")
                var nextLocalData = localData
                nextLocalData.networkInterfaceSnapshot = resolvedNetwork.0
                nextLocalData.networkTopologySnapshot = resolvedNetwork.1
                nextLocalData.networkInterfaceRefreshedAt = Date()
                nextLocalData.isRefreshing = hasPendingLocalReads
                localData = nextLocalData
                if previousSignature != resolvedNetwork.1.networkSignature {
                    PerformanceTelemetry.signposter.emitEvent("ActiveInterfaceChanged")
                    if refreshesPublicAddressOnNetworkChange {
                        refreshPublicNetworkAddress(
                            force: false,
                            networkSignature: resolvedNetwork.1.networkSignature
                        )
                    }
                }
            }
        }
        if hasPendingLocalReads, !localData.isRefreshing {
            var refreshingData = localData
            refreshingData.isRefreshing = true
            localData = refreshingData
        }
    }

    private func recordBatterySample(
        _ resolvedBattery: (BatteryPowerSnapshot?, NativeBatteryElectricalSnapshot?),
        availability: InternalBatteryAvailability,
        in data: inout MenuBarLocalMonitorData
    ) {
        if resolvedBattery.0 != nil || resolvedBattery.1?.hasBatteryData == true {
            data.internalBatteryAvailability = .present
        } else if availability != .unknown {
            data.internalBatteryAvailability = availability
        }
        data.batterySnapshot = resolvedBattery.0
        data.batteryElectricalSnapshot = resolvedBattery.1
        data.batteryChargeLimitState = BatteryFullChargeService.reconcileSystemTarget(
            for: resolvedBattery.0
        )
        data.batteryRefreshedAt = Date()
        onBatterySample?(resolvedBattery.0, resolvedBattery.1)
        let timestamp = resolvedBattery.1?.generatedAt ?? Date()
        let monotonicTimestamp = Duration.nanoseconds(
            Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
        let sample = BatterySample(
            timestamp: timestamp,
            monotonicTimestamp: monotonicTimestamp,
            snapshot: resolvedBattery.0,
            adapterWatts: resolvedBattery.1?.adapterPowerWatts.map { Int($0.rounded()) }
        )
        let powerPoint = MenuBarPowerHistoryPoint(
            date: sample.timestamp,
            chargePercent: sample.levelPercent,
            batteryPowerWatts: resolvedBattery.1?.powerWatts,
            isCharging: sample.isCharging,
            powerSource: sample.powerSource
        )
        if sample.isValid && powerPoint.isValid {
            MenuBarHistoryRetention.append(
                powerPoint,
                to: &data.powerHistory,
                date: \.date
            )
            if let metricHistoryStore {
                Task {
                    await metricHistoryStore.appendPower(powerPoint)
                }
            } else {
                persistPowerHistoryIfNeeded(data.powerHistory)
            }
        }
    }

    private func mergedHistory<T>(
        _ restored: [T],
        with current: [T],
        date: KeyPath<T, Date>
    ) -> [T] {
        let ordered = (restored + current).enumerated().sorted {
            let lhs = $0.element[keyPath: date]
            let rhs = $1.element[keyPath: date]
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }
        var result: [T] = []
        for point in ordered.map(\.element) {
            MenuBarHistoryRetention.append(point, to: &result, date: date)
        }
        return result
    }

    private func persistPowerHistoryIfNeeded(_ points: [MenuBarPowerHistoryPoint]) {
        guard let powerHistoryURL else { return }
        let now = Date()
        guard powerHistorySaveTask == nil,
              lastPowerHistoryPersistedAt.map({
                  now.timeIntervalSince($0) >= MenuBarPowerHistoryStore.saveInterval
              })
            ?? true else { return }
        lastPowerHistoryPersistedAt = now
        powerHistorySaveTask = Task { [weak self] in
            await Task.detached(priority: .utility) {
                try? MenuBarPowerHistoryStore.save(points, to: powerHistoryURL)
            }.value
            self?.powerHistorySaveTask = nil
        }
    }

    private func canPublishLocalData(
        _ generation: Int,
        allowsNoConsumers: Bool = false
    ) -> Bool {
        !Task.isCancelled
            && generation == localDataGeneration
            && !isPaused
            && (allowsNoConsumers || !consumers.isEmpty)
    }

    private func cancelLocalDataRefresh() {
        localDataGeneration &+= 1
        batteryRefreshTask?.cancel()
        storageRefreshTask?.cancel()
        networkInterfaceRefreshTask?.cancel()
        if localData.isRefreshing {
            var nextLocalData = localData
            nextLocalData.isRefreshing = false
            localData = nextLocalData
        }
    }

    private func startNetworkTopologyObservationIfNeeded() {
        if networkPathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleNetworkTopologyRefresh()
                }
            }
            monitor.start(queue: networkPathMonitorQueue)
            networkPathMonitor = monitor
        }

        guard networkConfigurationStore == nil else { return }
        let relay = networkTopologyObservationRelay
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(relay).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil,
            "StorageCleanerMac.NetworkTopologyObservation" as CFString,
            networkTopologyStoreCallback,
            &context
        ) else {
            return
        }

        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Global/DNS"
        ] as CFArray
        let patterns = [
            "State:/Network/Service/.*/IPv4",
            "State:/Network/Service/.*/IPv6",
            "State:/Network/Service/.*/DNS",
            "State:/Network/Service/.*/PPP",
            "State:/Network/Service/.*/IPSec"
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, patterns),
              SCDynamicStoreSetDispatchQueue(store, networkConfigurationStoreQueue) else {
            return
        }
        networkConfigurationStore = store
    }

    private func stopNetworkTopologyObservation() {
        networkTopologyRefreshTask?.cancel()
        networkTopologyRefreshTask = nil
        networkPathMonitor?.cancel()
        networkPathMonitor = nil
        if let networkConfigurationStore {
            SCDynamicStoreSetDispatchQueue(networkConfigurationStore, nil)
        }
        networkConfigurationStore = nil
    }

    fileprivate func scheduleNetworkTopologyRefresh() {
        guard !isPaused, combinedDemand.needsNetworkInterface else { return }
        networkTopologyRefreshTask?.cancel()
        networkTopologyRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            refreshLocalData(forceNetworkInterface: true)
        }
    }
}
