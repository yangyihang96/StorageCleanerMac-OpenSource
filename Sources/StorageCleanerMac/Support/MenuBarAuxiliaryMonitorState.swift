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
    /// D57: SMC power, backlight and Energy Model readings (power page).
    let needsPowerTelemetry: Bool
    let needsChargeLimit: Bool
    let needsStorageCapacity: Bool
    let needsBattery: Bool
    let primaryKinds: Set<MenuBarMetricKind>

    init(
        needsProcessorTelemetry: Bool,
        needsDiskIOSampling: Bool,
        needsNetworkInterface: Bool,
        needsPublicNetworkAddress: Bool,
        needsNetworkProcesses: Bool,
        needsStorageVolumes: Bool = false,
        needsPowerTelemetry: Bool = false,
        needsChargeLimit: Bool = false,
        needsStorageCapacity: Bool = true,
        needsBattery: Bool = true,
        primaryKinds: Set<MenuBarMetricKind> = []
    ) {
        self.needsProcessorTelemetry = needsProcessorTelemetry
        self.needsDiskIOSampling = needsDiskIOSampling
        self.needsNetworkInterface = needsNetworkInterface
        self.needsPublicNetworkAddress = needsPublicNetworkAddress
        self.needsNetworkProcesses = needsNetworkProcesses
        self.needsStorageVolumes = needsStorageVolumes
        self.needsPowerTelemetry = needsPowerTelemetry
        self.needsChargeLimit = needsChargeLimit
        self.needsStorageCapacity = needsStorageCapacity
        self.needsBattery = needsBattery
        self.primaryKinds = primaryKinds
    }
}

struct MenuBarPowerHistoryPoint: Codable, Equatable, Sendable {
    var bucketStatistics: MenuBarHistoryStatistics? = nil
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

private struct MenuBarPowerMonitorData {
    var telemetry: MenuBarPowerTelemetry?
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
    /// The startup volume's capacity; `true` asks for the important-usage
    /// (purgeable) figure too, which costs a CacheDelete query (D173).
    typealias StorageCapacityProvider = @Sendable (_ includeImportantUsage: Bool) -> StorageCapacitySnapshot?
    typealias BatterySnapshotProvider = @Sendable () -> (
        BatteryPowerSnapshot?,
        NativeBatteryElectricalSnapshot?
    )
    typealias PublicNetworkAddressProvider = @Sendable () async -> PublicNetworkAddressSnapshot
    typealias PowerTelemetryProvider = @Sendable () -> MenuBarPowerTelemetry
    /// D71④: expensive visible probes share a five-second floor. Their
    /// original values, timestamps and units remain provider-owned.
    static let powerTelemetrySamplingInterval = MenuBarPerformancePolicy.visibleExpensiveInterval
    typealias NetworkProcessProvider = @Sendable () -> NativeNetworkProcessSnapshot?
    static let batteryHistorySamplingInterval: TimeInterval = 30
    static let visibleBatterySamplingInterval = MenuBarPerformancePolicy.visibleExpensiveInterval
    static let storageVolumeSamplingInterval: TimeInterval = 300
    /// D173: iStat reads the purgeable space every 5 minutes (its CacheDelete
    /// queries, 10-22); free space is still read on every tick.
    static let purgeableSamplingInterval: TimeInterval = 300
    static let diskIOSamplingInterval: Duration = .seconds(MenuBarPerformancePolicy.visibleExpensiveInterval)

    /// Each logical domain publishes one immutable value. A storage refresh or
    /// disk tick therefore invalidates the Panel once instead of once per field.
    @Published private var localData = MenuBarLocalMonitorData()
    @Published private var processorData = MenuBarProcessorMonitorData()
    @Published private var powerData = MenuBarPowerMonitorData()
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
    var internalBatteryAvailabilityPublisher: AnyPublisher<InternalBatteryAvailability, Never> {
        $localData.map(\.internalBatteryAvailability).removeDuplicates().eraseToAnyPublisher()
    }
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
    var powerTelemetry: MenuBarPowerTelemetry? { powerData.telemetry }
    var powerTelemetryRefreshedAt: Date? { powerData.refreshedAt }
    var volumeName: String { localData.volumeName }
    var isRefreshingLocalData: Bool {
        localData.isRefreshing
            || publicNetworkData.isRefreshing
            || networkProcessData.samplingState == .sampling
    }
    var nativeDiskIOCounters: NativeDiskIOCounters? { diskData.counters }
    var nativeDiskIOHistory: [NativeDiskIOPoint] { diskData.history }

    private var consumers: [UUID: MenuBarAuxiliaryMonitorDemand] = [:]
    private let chargeLimitReadCache: BatteryChargeLimitReadCache
    private var isChargeLimitDataOnlyFixture = false
    private var isPaused = false
    private var isPresentationVisible = true
    private var samplingContext: MenuBarSamplingContext?
    private var residentDiskAttemptAt: Date?
    private var residentDiskTask: Task<Void, Never>?
    private var residentDiskGeneration = 0

    private var residentEnabled: Bool { samplingContext?.plan?.cadence.suspended == false && !isPaused }
    private var collectionAllowed: Bool { !isPaused && (samplingContext == nil || residentEnabled) }
    private var cheapInterval: TimeInterval { samplingContext?.plan?.cadence.expensive ?? Self.visibleBatterySamplingInterval }
    private var networkProcessInterval: TimeInterval { samplingContext?.plan?.cadence.networkProcesses ?? MenuBarPerformancePolicy.networkProcessInterval }
    private let collectionClock: @Sendable () -> Date
    var onBatterySample: ((BatteryPowerSnapshot?, NativeBatteryElectricalSnapshot?) -> Void)?
    private var batteryRefreshTask: Task<Void, Never>?
    private var storageRefreshTask: Task<Void, Never>?
    private var residentBatteryAttemptAt: Date?
    private var residentStorageAttemptAt: Date?
    /// D173: when the purgeable space was last asked for, and what it was.
    private var purgeableAttemptAt: Date?
    private var measuredPurgeableBytes: Int64?
    private var networkInterfaceRefreshTask: Task<Void, Never>?
    private var localDataGeneration = 0
    private var storageVolumesRefreshedAt: Date?
    private var processorTelemetryTask: Task<Void, Never>?
    private var processorTelemetryGeneration = 0
    private var powerTelemetryTask: Task<Void, Never>?
    private var powerTelemetryGeneration = 0
    private var isPowerTelemetryActive = false
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
    private let storageCapacityProvider: StorageCapacityProvider
    private let batteryAvailabilityProvider: @Sendable () -> InternalBatteryAvailability
    private let batterySnapshotProvider: BatterySnapshotProvider
    private let publicNetworkAddressProvider: PublicNetworkAddressProvider
    private let networkProcessProvider: NetworkProcessProvider
    private let processorTelemetryProvider: (@Sendable () async -> CPUPerformanceStateService.Snapshot?)?
    private let powerTelemetryProvider: PowerTelemetryProvider
    private let powerTelemetryPause: @Sendable () -> Void
    private let metricHistoryStore: MetricHistoryStore?
    private let powerHistoryURL: URL?
    private var batteryPowerSourceObserver: BatteryPowerSourceObserver?
    private var lastPowerHistoryPersistedAt: Date?
    private var powerHistorySaveTask: Task<Void, Never>?

    init(
        collectionClock: @escaping @Sendable () -> Date = { Date() },
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
        storageCapacityProvider: @escaping StorageCapacityProvider = {
            StorageCapacityService.snapshot(includeImportantUsage: $0)
        },
        batterySnapshotProvider: @escaping BatterySnapshotProvider = {
            (
                BatteryPowerService.internalBatterySnapshot(),
                MenuBarBatteryElectricalCache.shared.snapshot()
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
        processorTelemetryProvider: (@Sendable () async -> CPUPerformanceStateService.Snapshot?)? = nil,
        powerTelemetryProvider: @escaping PowerTelemetryProvider = {
            PowerTelemetryService.sample()
        },
        powerTelemetryPause: @escaping @Sendable () -> Void = {
            PowerTelemetryService.pause()
        },
        metricHistoryStore: MetricHistoryStore? = nil,
        powerHistoryURL: URL? = MenuBarPowerHistoryStore.defaultURL,
        chargeLimitClock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        chargeLimitReader: @escaping @MainActor () -> BatteryChargeLimitState? = {
            BatteryFullChargeService.reconcileSystemTarget()
        }
    ) {
        self.collectionClock = collectionClock
        self.statusWiFiProvider = statusWiFiProvider
        self.batteryAvailabilityProvider = batteryAvailabilityProvider
        self.diskCounterProvider = diskCounterProvider
        self.storageVolumeProvider = storageVolumeProvider
        self.storageCapacityProvider = storageCapacityProvider
        self.batterySnapshotProvider = batterySnapshotProvider
        self.publicNetworkAddressProvider = publicNetworkAddressProvider
        self.publicNetworkConsentProvider = publicNetworkConsentProvider
        self.networkProcessProvider = networkProcessProvider
        self.processorTelemetryProvider = processorTelemetryProvider
        self.powerTelemetryProvider = powerTelemetryProvider
        self.powerTelemetryPause = powerTelemetryPause
        self.metricHistoryStore = metricHistoryStore
        self.powerHistoryURL = powerHistoryURL
        self.chargeLimitReadCache = BatteryChargeLimitReadCache(clock: chargeLimitClock, read: chargeLimitReader)
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

#if DEBUG
    /// Offscreen page tests: the volumes as the local refresh would publish
    /// them, without the system probes.
    func seedVolumesForTesting(
        storageSnapshot: StorageCapacitySnapshot?,
        volumeName: String,
        networkStorageVolumes: [MountedStorageVolumeSnapshot] = []
    ) {
        var next = localData
        next.storageSnapshot = storageSnapshot
        next.volumeName = volumeName
        next.networkStorageVolumes = networkStorageVolumes
        localData = next
    }

    /// Offscreen page tests: the battery, power and processor readings as
    /// their refreshes would publish them at `date`, without the probes.
    func seedSensorsForTesting(
        battery: BatteryPowerSnapshot?,
        electrical: NativeBatteryElectricalSnapshot?,
        power: MenuBarPowerTelemetry?,
        processor: CPUPerformanceStateService.Snapshot?,
        at date: Date
    ) {
        var next = localData
        next.internalBatteryAvailability = battery == nil ? .absent : .present
        next.batterySnapshot = battery
        next.batteryElectricalSnapshot = electrical
        next.batteryRefreshedAt = date
        localData = next
        powerData = MenuBarPowerMonitorData(telemetry: power, refreshedAt: power.map { _ in date })
        processorData = MenuBarProcessorMonitorData(telemetry: processor, refreshedAt: processor.map { _ in date })
    }
#endif

    func attachSamplingContext(_ context: MenuBarSamplingContext) {
        guard samplingContext !== context else { return }
        samplingContext = context
        updatePrimaryDemand()
    }

    func setPresentationVisible(_ visible: Bool) {
        guard visible != isPresentationVisible else { return }
        isPresentationVisible = visible
        if samplingContext != nil {
            if visible { refreshPublicNetworkAddressIfReady() }
            else { cancelPublicNetworkAddressRefresh() }
            reconcileResidentNetworkProcessDemand()
            return
        }
        if visible {
            reconcile(forceLocalData: false, forceProcessor: false)
        } else {
            cancelLocalDataRefresh()
            cancelProcessorTelemetryRefresh()
            cancelPowerTelemetryRefresh()
            stopNativeDiskIOSampling()
            cancelPublicNetworkAddressRefresh()
            cancelNetworkProcessRefresh()
            stopNetworkTopologyObservation()
        }
    }

    private func updatePrimaryDemand() {
        samplingContext?.setVisibleKinds(consumers.values.reduce(into: Set<MenuBarMetricKind>()) {
            $0.formUnion($1.primaryKinds)
        })
    }

    func registerConsumer(
        _ id: UUID,
        demand: MenuBarAuxiliaryMonitorDemand,
        paused: Bool
    ) {
        guard consumers[id] != demand || isPaused != paused else { return }
        cancelBackgroundDiskRefresh()
        consumers[id] = demand
        isPaused = paused
        updatePrimaryDemand()
        reconcilePublicNetworkAddressDemand()
        reconcile(forceLocalData: false, forceProcessor: false)
        reconcileResidentNetworkProcessDemand()
    }

    func updateConsumer(
        _ id: UUID,
        demand: MenuBarAuxiliaryMonitorDemand
    ) {
        guard consumers[id] != demand else { return }
        consumers[id] = demand
        updatePrimaryDemand()
        reconcilePublicNetworkAddressDemand()
        reconcile(forceLocalData: false, forceProcessor: false)
        reconcileResidentNetworkProcessDemand()
    }

    func unregisterConsumer(_ id: UUID) {
        guard consumers.removeValue(forKey: id) != nil else { return }
        updatePrimaryDemand()
        reconcilePublicNetworkAddressDemand()
        if consumers.isEmpty, samplingContext == nil {
            cancelLocalDataRefresh()
            cancelProcessorTelemetryRefresh()
            cancelPowerTelemetryRefresh()
            stopNativeDiskIOSampling()
            cancelPublicNetworkAddressRefresh()
            cancelNetworkProcessRefresh()
            stopNetworkTopologyObservation()
        } else {
            reconcile(forceLocalData: false, forceProcessor: false)
        }
        reconcileResidentNetworkProcessDemand()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            statusWiFiGeneration &+= 1
            statusWiFiTask?.cancel()
            cancelLocalDataRefresh()
            cancelProcessorTelemetryRefresh()
            cancelPowerTelemetryRefresh()
            stopNativeDiskIOSampling()
            cancelBackgroundDiskRefresh()
            cancelPublicNetworkAddressRefresh()
            cancelNetworkProcessRefresh()
            stopNetworkTopologyObservation()
            residentDiskGeneration &+= 1
            residentDiskTask?.cancel()
        } else {
            reconcile(forceLocalData: true, forceProcessor: true)
            reconcileResidentNetworkProcessDemand()
        }
    }

    /// Production sampling uses only the resident controller's tick. Providers
    /// may finish independently; no supplemental polling loop is started.
    private func permitsStartup(_ source: ResidentStartupSchedule.Source) -> Bool {
        samplingContext?.permitsStartupSource(source, now: collectionClock()) ?? true
    }

    func refreshResidentSamples() {
        guard residentEnabled else { return }
        if permitsStartup(.localData) { refreshLocalData(); refreshResidentDisk() }
        if permitsStartup(.processor) { refreshProcessorTelemetry() }
        if permitsStartup(.power) { refreshPowerTelemetry() }
        if permitsStartup(.processes) { refreshNetworkProcesses() }
        refreshPublicNetworkAddressIfReady()
    }

    func suspendResidentSamples() {
        cancelLocalDataRefresh()
        residentBatteryAttemptAt = nil
        residentStorageAttemptAt = nil
        cancelProcessorTelemetryRefresh()
        cancelPowerTelemetryRefresh()
        cancelNetworkProcessRefresh()
        cancelPublicNetworkAddressRefresh()
        residentDiskGeneration &+= 1
        residentDiskTask?.cancel()
        residentDiskAttemptAt = nil
        // A sleep gap must not be averaged into the next disk rate.
        diskData.counters = nil
    }

    private func refreshResidentDisk() {
        let now = collectionClock()
        guard residentEnabled, residentDiskTask == nil,
              MenuBarPerformancePolicy.isDue(since: residentDiskAttemptAt, now: now, interval: cheapInterval) else { return }
        residentDiskAttemptAt = now
        let generation = residentDiskGeneration
        let provider = diskCounterProvider
        residentDiskTask = Task { @MainActor [weak self] in
            let current = await Task.detached(priority: .utility) {
                MenuBarPresentationTrace.measureSample("disk.iokit") { provider() }
            }.value
            guard let self else { return }
            defer { residentDiskTask = nil }
            guard !Task.isCancelled, generation == residentDiskGeneration, residentEnabled else { return }
            var next = diskData
            if let previous = next.counters, let current,
               let point = NativeDiskIOMonitorService.throughput(current: current, previous: previous) {
                MenuBarHistoryRetention.append(point, to: &next.history, date: \.date)
                if let metricHistoryStore { Task { await metricHistoryStore.appendDiskIO(point) } }
            }
            next.counters = current
            diskData = next
        }
    }

    func refreshFromPrimaryMonitorUpdate() {
        if samplingContext != nil { return } // resident owns production polling
        guard !isPaused else { return }
        guard isPresentationVisible, !consumers.isEmpty else {
            refreshBackgroundBatteryHistory()
            return
        }
        refreshLocalData()
        if !combinedDemand.needsBattery { refreshBackgroundBatteryHistory() }
        refreshProcessorTelemetry()
        refreshPowerTelemetry()
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
        if consumers.isEmpty || !isPresentationVisible {
            refreshBackgroundBatteryHistory(force: true)
        } else {
            refreshLocalData(force: true)
        }
    }

    func refreshBackgroundBatteryHistory(force: Bool = false) {
        guard samplingContext == nil, !isPaused,
              (consumers.isEmpty || !combinedDemand.needsBattery),
              batteryRefreshTask == nil else { return }

        let now = collectionClock()
        guard force
            || batteryRefreshedAt.map({
                now.timeIntervalSince($0) >= Self.batteryHistorySamplingInterval
            }) != false else { return }

        // Review P1-2 (N16-5): the whole-machine energy integration keeps
        // its read-only battery/SMC electrical reading about every 30 s while
        // the panel is hidden, in every status mode. D5 forbids changing the
        // charging state; this path never reads the charge limit live (the
        // cache only reads while a visible panel demands it) and writes nothing.
        refreshBattery(allowsNoConsumers: true)
    }

    private var hasPendingLocalReads: Bool {
        batteryRefreshTask != nil || storageRefreshTask != nil || networkInterfaceRefreshTask != nil
    }

    private func refreshBattery(allowsNoConsumers: Bool = false) {
        guard batteryRefreshTask == nil else { return }
        if samplingContext != nil { residentBatteryAttemptAt = collectionClock() }
        let generation = localDataGeneration
        let provider = batterySnapshotProvider
        let availabilityProvider = batteryAvailabilityProvider
        let previousAvailability = internalBatteryAvailability
        batteryRefreshTask = Task { @MainActor [weak self] in
            if Task.isCancelled {
                guard let self else { return }
                batteryRefreshTask = nil
                if !isPaused, isPresentationVisible, !consumers.isEmpty { refreshLocalData() }
                return
            }
            let resolvedBattery = await Task.detached(priority: .utility) {
                MenuBarPresentationTrace.measureSample("battery.electrical") {
                    (provider(), previousAvailability == .unknown ? availabilityProvider() : previousAvailability)
                }
            }.value
            guard let self else { return }
            batteryRefreshTask = nil
            guard canPublishLocalData(generation, allowsNoConsumers: allowsNoConsumers),
                  allowsNoConsumers || combinedDemand.needsBattery else {
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
        // D71④: disk history has no resident status-item consumer.
        guard samplingContext == nil else { return }
        guard !isPaused,
              consumers.isEmpty,
              nativeDiskIOSamplingTask == nil,
              backgroundDiskRefreshTask == nil else { return }

        let now = collectionClock()
        guard force
            || backgroundDiskRefreshedAt.map({ now.timeIntervalSince($0) >= 60 }) != false else {
            return
        }

        backgroundDiskRefreshGeneration &+= 1
        let generation = backgroundDiskRefreshGeneration
        let counterProvider = diskCounterProvider
        backgroundDiskRefreshTask = Task { @MainActor [weak self] in
            let current = await Task.detached(priority: .utility) {
                MenuBarPresentationTrace.measureSample("disk.iokit") { counterProvider() }
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
            let snapshot = await Task.detached(priority: .utility) {
                MenuBarPresentationTrace.measureSample("wifi.status") { provider(now) }
            }.value
            guard let self else { return }
            statusWiFiTask = nil
            guard !Task.isCancelled, !isPaused, generation == statusWiFiGeneration else { return }
            statusWiFiSnapshot = snapshot
        }
    }

    func requestManualRefresh() {
        guard !isPaused, isPresentationVisible, !consumers.isEmpty else { return }
        refreshLocalData(force: true)
        refreshProcessorTelemetry(force: true)
        refreshPowerTelemetry(force: true)
        refreshPublicNetworkAddressIfReady(force: true)
        refreshNetworkProcesses(force: true)
    }

    /// D140: iStat's refresh icon on the public addresses
    /// (`onPublicAddressRefresh`): looks the public addresses up again now,
    /// within the same consent and demand as any lookup.
    func requestPublicNetworkAddressRefresh() {
        guard !isPaused, isPresentationVisible, !consumers.isEmpty else { return }
        refreshPublicNetworkAddressIfReady(force: true)
    }

    func setChargeLimitDataOnlyFixture(_ isFixture: Bool) {
        isChargeLimitDataOnlyFixture = isFixture
    }

    func refreshBatteryChargeLimitState(reason: BatteryChargeLimitReadReason = .visibleSampling) {
        var nextLocalData = localData
        nextLocalData.batteryChargeLimitState = chargeLimitReadCache.refresh(
            reason: reason,
            hasInternalBattery: batteryAvailabilityProvider() == .present,
            isPanelVisible: !isPaused && combinedDemand.needsChargeLimit,
            allowsLiveAccess: BatteryChargeLimitAccess.allowsLiveAccess && !isChargeLimitDataOnlyFixture
        )
        localData = nextLocalData
    }

    func setBatteryChargeTarget(
        _ target: BatteryChargeTarget
    ) async -> BatteryChargeTargetUpdateResult {
        guard BatteryChargeLimitAccess.allowsLiveAccess, !isChargeLimitDataOnlyFixture,
              batteryAvailabilityProvider() == .present else { return .unsupported }
        let result = await BatteryFullChargeService.setPreferredTarget(target)
        // 拒绝或验证失败也要立即只读刷新，展示真实状态。
        refreshBatteryChargeLimitState(reason: .userOperation)
        return result
    }

    var activeConsumerCount: Int { consumers.count }
    func isConsumerRegistered(_ id: UUID) -> Bool { consumers[id] != nil }
    var isLocalDataRefreshActive: Bool { hasPendingLocalReads }
    var isDiskIOSamplingActive: Bool { nativeDiskIOSamplingTask != nil || residentDiskTask != nil }
    var isProcessorRefreshActive: Bool { processorTelemetryTask != nil }
    var isPowerTelemetryRefreshActive: Bool { powerTelemetryTask != nil }
    var isNetworkProcessRefreshActive: Bool { networkProcessTask != nil }

    private var combinedDemand: MenuBarAuxiliaryMonitorDemand {
        let values = isPresentationVisible && samplingContext?.plan?.panelVisible != false
            ? Array(consumers.values) : []
        let prestored = residentEnabled
        return MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: prestored || values.contains { $0.needsProcessorTelemetry },
            needsDiskIOSampling: prestored || values.contains { $0.needsDiskIOSampling },
            needsNetworkInterface: prestored || values.contains { $0.needsNetworkInterface },
            needsPublicNetworkAddress: values.contains { $0.needsPublicNetworkAddress },
            // D127: a process list is read only while its page is open.
            needsNetworkProcesses: values.contains { $0.needsNetworkProcesses },
            needsStorageVolumes: prestored || values.contains { $0.needsStorageVolumes },
            needsPowerTelemetry: prestored || values.contains { $0.needsPowerTelemetry },
            needsChargeLimit: isPresentationVisible && values.contains { $0.needsChargeLimit },
            needsStorageCapacity: prestored || values.contains { $0.needsStorageCapacity },
            needsBattery: prestored || values.contains { $0.needsBattery },
            primaryKinds: values.reduce(into: Set<MenuBarMetricKind>()) { $0.formUnion($1.primaryKinds) }
        )
    }

    private func reconcilePublicNetworkAddressDemand() {
        guard samplingContext != nil else { return }
        if combinedDemand.needsPublicNetworkAddress { refreshPublicNetworkAddressIfReady() }
        else { cancelPublicNetworkAddressRefresh() }
    }

    private func reconcile(forceLocalData: Bool, forceProcessor: Bool) {
        guard !isPaused, isPresentationVisible, !consumers.isEmpty else { return }
        if samplingContext != nil { return }
        let demand = combinedDemand

        refreshLocalData(force: forceLocalData)
        if demand.needsProcessorTelemetry {
            refreshProcessorTelemetry(force: forceProcessor)
        } else {
            cancelProcessorTelemetryRefresh()
        }

        if demand.needsPowerTelemetry {
            refreshPowerTelemetry(force: forceProcessor)
        } else {
            cancelPowerTelemetryRefresh()
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
        guard permitsStartup(.processes), collectionAllowed,
              combinedDemand.needsNetworkProcesses,
              networkProcessTask == nil else { return }

        let now = collectionClock()
        let refreshInterval = networkProcessInterval
        guard force || (samplingContext == nil
            ? networkProcessData.lastAttemptAt.map({ now.timeIntervalSince($0) >= refreshInterval }) != false
            : MenuBarPerformancePolicy.isDue(since: networkProcessData.lastAttemptAt, now: now,
                                             interval: refreshInterval)) else { return }

        networkProcessGeneration &+= 1
        let generation = networkProcessGeneration
        let provider = networkProcessProvider
        var loadingData = networkProcessData
        if samplingContext == nil || loadingData.snapshot == nil { loadingData.samplingState = .sampling }
        loadingData.lastAttemptAt = now
        networkProcessData = loadingData

        networkProcessTask = Task { @MainActor [weak self] in
            if Task.isCancelled {
                guard let self else { return }
                networkProcessTask = nil
                // No process was launched, so this is not a sampling attempt.
                var nextData = networkProcessData
                nextData.lastAttemptAt = nil
                networkProcessData = nextData
                if !isPaused, combinedDemand.needsNetworkProcesses { refreshNetworkProcesses() }
                return
            }
            let samplingTask = Task.detached(priority: .utility) {
                MenuBarPresentationTrace.measureSample("process.network.nettop") { provider() }
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
                if !isPaused, combinedDemand.needsNetworkProcesses { refreshNetworkProcesses() }
                return
            }
            let keptSnapshot = snapshot ?? (samplingContext != nil ? networkProcessData.snapshot : nil)
            networkProcessData = MenuBarNetworkProcessData(
                snapshot: keptSnapshot,
                lastAttemptAt: now,
                samplingState: keptSnapshot == nil ? .unavailable : .available
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

    /// D127 (iStat `startItemsForKey:` / `stopItemsForKey:`): the per-app
    /// network list is read only while its page is open — at once, then on
    /// each tick — and dropped when the page closes (was prestored every
    /// 10 s open / 60 s closed, D74). Pausing keeps what is shown.
    private func reconcileResidentNetworkProcessDemand() {
        guard samplingContext != nil, !isPaused else { return }
        if combinedDemand.needsNetworkProcesses {
            refreshNetworkProcesses()
        } else if networkProcessTask != nil || networkProcessData.snapshot != nil
                    || networkProcessData.lastAttemptAt != nil {
            // The running nettop keeps the gate (handle kept); its completion
            // starts the next read if the page opens again meanwhile.
            cancelNetworkProcessRefresh()
            networkProcessData = MenuBarNetworkProcessData()
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

        let now = collectionClock()
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
            guard !Task.isCancelled else { return }
            let snapshot = await MenuBarPresentationTrace.measureAsyncSample("network.public-address", operation: provider)
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
        guard permitsStartup(.processor), collectionAllowed,
              combinedDemand.needsProcessorTelemetry,
              processorTelemetryTask == nil else { return }

        let now = collectionClock()
        let refreshInterval = cheapInterval
        guard force || (samplingContext == nil
            ? processorTelemetryRefreshedAt.map({ now.timeIntervalSince($0) >= refreshInterval }) != false
            : MenuBarPerformancePolicy.isDue(since: processorTelemetryRefreshedAt, now: now,
                                             interval: refreshInterval)) else { return }

        processorTelemetryGeneration &+= 1
        let generation = processorTelemetryGeneration
        processorTelemetryTask = Task { @MainActor [weak self] in
            if Task.isCancelled {
                guard let self else { return }
                processorTelemetryTask = nil
                if !isPaused, combinedDemand.needsProcessorTelemetry { refreshProcessorTelemetry() }
                return
            }
            let provider = self?.processorTelemetryProvider
            let dynamicSnapshot = await MenuBarPresentationTrace.measureAsyncSample("processor.ioreport") {
                if let provider { return await provider() }
                return await CPUPerformanceStateService.currentSnapshot()
            }
            let resolvedSnapshot = await Task.detached(priority: .utility) {
                dynamicSnapshot ?? CPUPerformanceStateService.staticSnapshot()
            }.value
            guard let self else { return }
            defer { processorTelemetryTask = nil }
            guard !Task.isCancelled, generation == processorTelemetryGeneration,
                  collectionAllowed, combinedDemand.needsProcessorTelemetry else { return }
            processorData = MenuBarProcessorMonitorData(
                telemetry: resolvedSnapshot,
                refreshedAt: collectionClock()
            )
        }
    }

    private func cancelProcessorTelemetryRefresh() {
        processorTelemetryGeneration &+= 1
        processorTelemetryTask?.cancel()
    }

    /// D57: read-only SMC, backlight and Energy Model readings for the
    /// power page, on a background task, only while a visible page needs
    /// them. The last result is kept while hidden and shown as "更新中"
    /// until the next sample replaces it.
    private func refreshPowerTelemetry(force: Bool = false) {
        guard permitsStartup(.power), collectionAllowed,
              combinedDemand.needsPowerTelemetry,
              powerTelemetryTask == nil else { return }

        let now = collectionClock()
        guard force || powerTelemetryRefreshedAt.map({
            now.timeIntervalSince($0) >= cheapInterval - 0.05
        }) != false else { return }

        isPowerTelemetryActive = true
        powerTelemetryGeneration &+= 1
        let generation = powerTelemetryGeneration
        let provider = powerTelemetryProvider
        powerTelemetryTask = Task { @MainActor [weak self] in
            if Task.isCancelled {
                guard let self else { return }
                powerTelemetryTask = nil
                if !isPaused, combinedDemand.needsPowerTelemetry { refreshPowerTelemetry() }
                return
            }
            let telemetry = await Task.detached(priority: .utility) {
                MenuBarPresentationTrace.measureSample("power.smc-ioreport") { provider() }
            }.value
            guard let self else { return }
            powerTelemetryTask = nil
            guard !Task.isCancelled,
                  generation == powerTelemetryGeneration,
                  !isPaused,
                  combinedDemand.needsPowerTelemetry else {
                if !isPaused, combinedDemand.needsPowerTelemetry { refreshPowerTelemetry(force: powerTelemetry == nil) }
                return
            }
            powerData = MenuBarPowerMonitorData(
                telemetry: telemetry,
                refreshedAt: telemetry.generatedAt
            )
        }
    }

    private func cancelPowerTelemetryRefresh() {
        powerTelemetryGeneration &+= 1
        powerTelemetryTask?.cancel()
        // Keep the physical single-flight until its synchronous provider exits.
        guard isPowerTelemetryActive else { return }
        isPowerTelemetryActive = false
        // The Energy Model baseline is reset off the main actor: a sample in
        // flight holds the sampler's lock for a few milliseconds.
        let pause = powerTelemetryPause
        Task.detached(priority: .utility) { pause() }
    }

    private func startNativeDiskIOSampling() {
        guard samplingContext == nil, !isPaused,
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
                MenuBarPresentationTrace.measureSample("disk.iokit") { counterProvider() }
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
                    MenuBarPresentationTrace.measureSample("disk.iokit") { counterProvider() }
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

    /// D173: a reading with the important-usage figure remembers the purgeable
    /// space it shows; the free-space-only readings in between get it added.
    private func completingPurgeable(
        _ snapshot: StorageCapacitySnapshot,
        readImportantUsage: Bool
    ) -> StorageCapacitySnapshot {
        if readImportantUsage, let important = snapshot.availableForImportantUsageBytes {
            measuredPurgeableBytes = max(0, important - snapshot.availableBytes)
            return snapshot
        }
        return snapshot.addingPurgeableEstimate(measuredPurgeableBytes)
    }

    private func refreshLocalData(
        force: Bool = false,
        forceNetworkInterface: Bool = false,
        networkOnly: Bool = false,
        refreshesPublicAddressOnNetworkChange: Bool = true
    ) {
        guard permitsStartup(.localData), collectionAllowed, residentEnabled || (isPresentationVisible && !consumers.isEmpty) else { return }

        let now = collectionClock()
        let capacityAttempt = samplingContext == nil ? storageRefreshedAt : residentStorageAttemptAt
        let batteryAttempt = samplingContext == nil ? batteryRefreshedAt : residentBatteryAttemptAt
        let needsStorageCapacity = !networkOnly && combinedDemand.needsStorageCapacity && (force
            || (samplingContext == nil
                ? capacityAttempt.map { now.timeIntervalSince($0) >= 30 } != false
                : MenuBarPerformancePolicy.isDue(since: capacityAttempt, now: now, interval: cheapInterval))
        )
        let needsStorageVolumes = !networkOnly
            && combinedDemand.needsStorageVolumes
            && (storageVolumesRefreshedAt.map {
                now.timeIntervalSince($0) >= Self.storageVolumeSamplingInterval
            } != false)
        let needsStorage = needsStorageCapacity || needsStorageVolumes
        // D74: resident attempts are paced independently of successful source
        // dates, so a failed read keeps old data without speeding up retries.
        let needsBattery = !networkOnly && combinedDemand.needsBattery && (force
            || batteryAttempt.map {
                now.timeIntervalSince($0) >= cheapInterval - 0.05
            } != false
        )
        let needsNetworkInterface = combinedDemand.needsNetworkInterface
            && (force
                || forceNetworkInterface
                || networkInterfaceRefreshedAt.map { now.timeIntervalSince($0) >= 60 } != false)
        guard needsStorage || needsBattery || needsNetworkInterface else { return }

        let generation = localDataGeneration
        if needsStorage, storageRefreshTask == nil {
            if samplingContext != nil { residentStorageAttemptAt = now }
            let volumeProvider = needsStorageVolumes ? storageVolumeProvider : nil
            let capacityProvider = storageCapacityProvider
            // D173: free space on every capacity read, the purgeable space
            // (a CacheDelete query) only every five minutes, as iStat.
            let readsPurgeable = needsStorageCapacity && MenuBarPerformancePolicy.isDue(
                since: purgeableAttemptAt, now: now, interval: Self.purgeableSamplingInterval)
            if readsPurgeable { purgeableAttemptAt = now }
            storageRefreshTask = Task { @MainActor [weak self] in
                if Task.isCancelled {
                    guard let self else { return }
                    storageRefreshTask = nil
                    if !isPaused, isPresentationVisible, !consumers.isEmpty { refreshLocalData() }
                    return
                }
                let resolvedStorage = await Task.detached(priority: .utility) {
                    let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
                    return MenuBarPresentationTrace.measureSample("storage.capacity-volumes") { (
                        capacityProvider(readsPurgeable),
                        (try? rootURL.resourceValues(forKeys: [.volumeNameKey]).volumeName),
                        volumeProvider?()
                    ) }
                }.value
                guard let self else { return }
                storageRefreshTask = nil
                guard canPublishLocalData(generation),
                      combinedDemand.needsStorageCapacity || combinedDemand.needsStorageVolumes else {
                    if !isPaused, !consumers.isEmpty { refreshLocalData() }
                    return
                }
                var nextLocalData = localData
                if samplingContext == nil || resolvedStorage.0 != nil {
                    nextLocalData.storageSnapshot = resolvedStorage.0.map {
                        completingPurgeable($0, readImportantUsage: readsPurgeable)
                    }
                    nextLocalData.storageRefreshedAt = collectionClock()
                }
                if let volumes = resolvedStorage.2 {
                    nextLocalData.externalStorageVolumes = volumes.external
                    nextLocalData.networkStorageVolumes = volumes.network
                    storageVolumesRefreshedAt = collectionClock()
                }
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
                if Task.isCancelled {
                    guard let self else { return }
                    networkInterfaceRefreshTask = nil
                    if !isPaused, isPresentationVisible, !consumers.isEmpty { refreshLocalData() }
                    return
                }
                let resolvedNetwork = await Task.detached(priority: .utility) {
                    MenuBarPresentationTrace.measureSample("network.interface-topology") { (
                        NativeNetworkInterfaceService.snapshot(),
                        NativeNetworkInterfaceService.topologySnapshot()
                    ) }
                }.value
                guard let self else { return }
                networkInterfaceRefreshTask = nil
                guard canPublishLocalData(generation), combinedDemand.needsNetworkInterface else {
                    if !isPaused, !consumers.isEmpty { refreshLocalData() }
                    return
                }
                let previousSignature = localData.networkTopologySnapshot?.networkSignature
                PerformanceTelemetry.signposter.emitEvent("SnapshotRefresh")
                var nextLocalData = localData
                nextLocalData.networkInterfaceSnapshot = resolvedNetwork.0
                nextLocalData.networkTopologySnapshot = resolvedNetwork.1
                nextLocalData.networkInterfaceRefreshedAt = collectionClock()
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
        if samplingContext != nil, availability != .absent,
           resolvedBattery.0 == nil, resolvedBattery.1 == nil,
           data.batterySnapshot != nil || data.batteryElectricalSnapshot != nil {
            return // Keep the last actual reading/date; do not duplicate history.
        }
        if resolvedBattery.0 != nil || resolvedBattery.1?.hasBatteryData == true {
            data.internalBatteryAvailability = .present
        } else if availability != .unknown {
            data.internalBatteryAvailability = availability
        }
        data.batterySnapshot = resolvedBattery.0
        data.batteryElectricalSnapshot = resolvedBattery.1
        if isPresentationVisible, !isPaused, combinedDemand.needsChargeLimit {
            data.batteryChargeLimitState = chargeLimitReadCache.refresh(
                reason: .visibleSampling,
                hasInternalBattery: data.internalBatteryAvailability == .present,
                isPanelVisible: !isPaused && combinedDemand.needsChargeLimit,
                allowsLiveAccess: BatteryChargeLimitAccess.allowsLiveAccess && !isChargeLimitDataOnlyFixture
            )
        }
        data.batteryRefreshedAt = collectionClock()
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
        let now = collectionClock()
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
            && collectionAllowed
            && (residentEnabled || allowsNoConsumers || (isPresentationVisible && !consumers.isEmpty))
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
