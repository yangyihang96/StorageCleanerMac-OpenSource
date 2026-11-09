import Foundation

/// The App's stores as an `AgentReadSource`. Each read copies values on the
/// main thread and returns; nothing here starts a scan or a sample (D268), so
/// an AI reading in a loop costs the App no more than the reads themselves.
struct AgentStoreReadSource: AgentReadSource {
    private let store: ScanStore
    private let healthStore: ComputerHealthStore
    private let journal: CleanupReportJournal
    private let isMenuBarOnly: @MainActor @Sendable () -> Bool

    @MainActor
    init(store: ScanStore, health: ComputerHealthStore, isMenuBarOnly: @escaping @MainActor @Sendable () -> Bool = { MenuBarOnlyMode.shared.isActive }) {
        self.store = store
        healthStore = health
        journal = store.activityJournal
        self.isMenuBarOnly = isMenuBarOnly
    }

    /// D259: the main window's results are released while only the panel runs.
    @MainActor
    private var noResults: AgentResultStatus { isMenuBarOnly() ? .released : .notScanned }

    func overview() async -> AgentOverviewState {
        var state = await MainActor.run {
            var state = AgentOverviewState()
            state.isMenuBarOnly = isMenuBarOnly()
            state.capacity = store.menuBarAuxiliaryMonitorState.storageSnapshot
            state.memory = store.menuBarDisplayMemorySnapshot
            state.health = healthStore.evaluation
            return state
        }
        state.capacity = state.capacity ?? Self.startupDiskCapacity()
        return state
    }

    func live() async -> AgentLiveState {
        var state = await MainActor.run {
            let auxiliary = store.menuBarAuxiliaryMonitorState
            var state = AgentLiveState()
            state.snapshot = store.menuBarMonitorSnapshot
            state.memory = store.menuBarDisplayMemorySnapshot
            state.capacity = auxiliary.storageSnapshot
            state.battery = Self.battery(live: auxiliary.batterySnapshot, liveTime: auxiliary.batteryRefreshedAt, checked: healthStore.snapshot?.battery)
            return state
        }
        state.capacity = state.capacity ?? Self.startupDiskCapacity()
        return state
    }

    /// The panel's reading while it has one; otherwise the last health check's.
    static func battery(live: BatteryPowerSnapshot?, liveTime: Date?, checked: BatteryHealthSnapshot?) -> AgentBatteryReading? {
        if let live {
            return AgentBatteryReading(chargePercent: live.chargePercent, isCharging: live.isCharging, powerSource: live.powerSource,
                                       minutesRemaining: live.timeToEmptyMinutes ?? live.timeToFullChargeMinutes, sampledAt: liveTime)
        }
        guard let checked else { return nil }
        return AgentBatteryReading(chargePercent: checked.currentChargePercent, isCharging: checked.isCharging, powerSource: checked.powerSource,
                                   minutesRemaining: checked.remainingTimeMinutes, sampledAt: checked.sampledAt)
    }

    /// Without the important-usage figure, which would wake CacheDelete (D173).
    private static func startupDiskCapacity() -> StorageCapacitySnapshot? {
        StorageCapacityService.snapshot(path: "/", includeImportantUsage: false)
    }

    func health() async -> AgentHealthState {
        await MainActor.run {
            var state = AgentHealthState()
            state.evaluation = healthStore.evaluation
            state.snapshot = healthStore.snapshot
            state.storageForecast = healthStore.storageForecast
            state.batteryTrend = healthStore.batteryTrend
            return state
        }
    }

    func junk() async -> AgentModuleResults<ScanCandidate> {
        let (status, session): (AgentResultStatus, ScanSession?) = await MainActor.run {
            switch store.scanPresentationState {
            case .preparing, .scanning, .finalizing: return (.scanning, nil)
            default: return store.cleanupScanSession.map { (.ready, $0) } ?? (noResults, nil)
            }
        }
        guard let session else { return .init(status: status) }
        let candidates = session.candidates
        // A cleanup removes what it cleaned from the same session.
        return .init(status: .ready, updatedAt: session.completedAt, generation: "\(session.id.rawValue.uuidString)-\(candidates.count)", items: candidates)
    }

    func startupItems() async -> AgentModuleResults<StartupItemsDomain.Item> {
        await MainActor.run {
            if store.isLoadingStartupItems { return .init(status: .scanning) }
            return store.hasScannedStartupItems ? .init(status: .ready, items: store.startupDomainItems) : .init(status: noResults)
        }
    }

    func installedApps() async -> AgentModuleResults<InstalledAppItem> {
        await MainActor.run {
            if store.isLoadingInstalledApps { return .init(status: .scanning) }
            return store.hasScannedInstalledApps ? .init(status: .ready, items: store.installedApps) : .init(status: noResults)
        }
    }

    func appUpdates() async -> AgentModuleResults<AppUpdateItem> {
        await MainActor.run {
            if store.isLoadingAppUpdates { return .init(status: .scanning) }
            guard let scanned = store.appUpdatesLastScannedAt else { return .init(status: noResults) }
            return .init(status: .ready, updatedAt: scanned, items: store.appUpdates)
        }
    }

    func lastCleanupScan() async -> ScanHistoryEntry? {
        await MainActor.run { store.scanHistorySummary.latestCleanupEntry }
    }

    func scanHistory() async -> [ScanHistoryEntry] {
        await MainActor.run { store.scanHistorySummary.entries }
    }

    func operationRecords(after cursor: CleanupReportIndex.Cursor?, limit: Int) throws -> CleanupReportJournal.SummaryPage {
        try CleanReportStore.summaryPage(after: cursor, limit: limit, journal: journal)
    }

    func operationRecord(_ id: CleanPlanID) throws -> CleanReport {
        try CleanReportStore.report(planID: id, journal: journal)
    }

    func hardwareOperations() async throws -> [HardwareOperationRecord] {
        try await HardwareOperationHistory.shared.load()
    }

    func capacityHistory() throws -> [CapacityHistoryPoint] {
        try CapacityHistoryService().load()
    }
}
