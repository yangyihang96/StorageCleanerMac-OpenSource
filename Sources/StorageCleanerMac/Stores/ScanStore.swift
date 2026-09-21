import AppKit
import Foundation

@MainActor
struct ApplicationUpdateGracefulQuitRequester {
    struct RunningApplication {
        let bundleIdentifier: String?
        let bundleURL: URL?
        let requestTermination: @MainActor () -> Bool
    }

    private let runningApplications: @MainActor () -> [RunningApplication]

    init(workspace: NSWorkspace = .shared) {
        runningApplications = {
            workspace.runningApplications.map { application in
                RunningApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    bundleURL: application.bundleURL,
                    requestTermination: { application.terminate() }
                )
            }
        }
    }

    init(runningApplications: @escaping @MainActor () -> [RunningApplication]) {
        self.runningApplications = runningApplications
    }

    @discardableResult
    func requestGracefulQuit(for application: InstalledApplication) -> Bool {
        guard !application.bundleIdentifier.isEmpty else { return false }
        let expectedPath = Self.comparisonKey(for: application.bundleURL)
        let matches = runningApplications().filter { runningApplication in
            runningApplication.bundleIdentifier == application.bundleIdentifier
                && runningApplication.bundleURL.map {
                    Self.comparisonKey(for: $0)
                } == expectedPath
        }
        guard !matches.isEmpty else { return false }

        var allRequestsAccepted = true
        for match in matches {
            if !match.requestTermination() {
                allRequestsAccepted = false
            }
        }
        return allRequestsAccepted
    }

    nonisolated static func comparisonKey(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
    }
}

@MainActor
struct ApplicationUpdateRelauncher {
    struct Target: Equatable {
        let applicationID: String
        let displayName: String
        let identity: ApplicationIdentity
        let bundleURL: URL

        init?(application: InstalledApplication) {
            guard !application.bundleIdentifier.isEmpty,
                  application.bundleURL.isFileURL,
                  !application.bundleURL.path.isEmpty else { return nil }
            applicationID = application.id
            displayName = application.displayName
            identity = application.identity
            bundleURL = URL(
                fileURLWithPath: ApplicationUpdateGracefulQuitRequester.comparisonKey(
                    for: application.bundleURL
                ),
                isDirectory: true
            )
        }
    }

    struct RunningApplication {
        let bundleIdentifier: String?
        let bundleURL: URL?
    }

    enum Outcome: Equatable {
        case opened
        case alreadyRunning
    }

    enum RelaunchError: LocalizedError {
        case installedIdentityChanged(String)

        var errorDescription: String? {
            switch self {
            case let .installedIdentityChanged(name):
                return L10n.text(
                    "\(name) 的安装路径或应用身份已变化",
                    "The installed path or application identity changed for \(name)"
                )
            }
        }
    }

    private let runningApplications: @MainActor () -> [RunningApplication]
    private let installedIdentity: @MainActor (URL) async throws -> ApplicationIdentity
    private let openApplication: @MainActor (URL) async throws -> Void

    init(workspace: NSWorkspace = .shared) {
        runningApplications = {
            workspace.runningApplications.map {
                RunningApplication(
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL
                )
            }
        }
        installedIdentity = { url in
            try await SignatureVerification.shared.identity(at: url)
        }
        openApplication = { url in
            try await withCheckedThrowingContinuation { continuation in
                workspace.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private actor SignatureVerification {
        static let shared = SignatureVerification()
        func identity(at url: URL) throws -> ApplicationIdentity {
            let signature = try CodeSignatureVerifier().verifyCode(at: url)
            guard signature.isValid,
                  let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
                throw RelaunchError.installedIdentityChanged(url.lastPathComponent)
            }
            return ApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                signingTeamIdentifier: signature.teamIdentifier,
                codeSigningIdentifier: signature.codeSigningIdentifier
            )
        }
    }

    init(
        runningApplications: @escaping @MainActor () -> [RunningApplication],
        installedIdentity: @escaping @MainActor (URL) async throws -> ApplicationIdentity,
        openApplication: @escaping @MainActor (URL) async throws -> Void
    ) {
        self.runningApplications = runningApplications
        self.installedIdentity = installedIdentity
        self.openApplication = openApplication
    }

    func relaunch(_ target: Target) async throws -> Outcome {
        let expectedPath = ApplicationUpdateGracefulQuitRequester.comparisonKey(
            for: target.bundleURL
        )
        guard try await installedIdentity(target.bundleURL) == target.identity else {
            throw RelaunchError.installedIdentityChanged(target.displayName)
        }
        try Task.checkCancellation()
        if runningApplications().contains(where: {
            $0.bundleIdentifier == target.identity.bundleIdentifier
                && $0.bundleURL.map {
                    ApplicationUpdateGracefulQuitRequester.comparisonKey(for: $0)
                } == expectedPath
        }) {
            return .alreadyRunning
        }
        try await openApplication(target.bundleURL)
        return .opened
    }
}

struct AppUpdateProgress: Equatable {
    let title: String
    let detail: String
    let fraction: Double
    let systemImage: String
}

private enum ApplicationUpdateBatchOutcome: Equatable {
    case running
    case cancelRequested
    case completed
}

private struct ApplicationUpdateBatchContext {
    let generation: UUID
    let sessionID: UUID
    var outcome: ApplicationUpdateBatchOutcome
}

struct ScanStoreHistorySnapshot: Equatable, Sendable {
    let scanHistory: ScanHistorySummary
    let cleanupHistory: CleanupHistorySummary
}

protocol ScanStoreHistoryLoading: Sendable {
    func load() async -> ScanStoreHistorySnapshot
}

protocol ApplicationInventoryScanning: Sendable {
    func scan(
        configuration: ApplicationScanConfiguration,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication]
}

extension ApplicationInventoryScanner: ApplicationInventoryScanning {}

struct UserDefaultsScanStoreHistoryLoader: ScanStoreHistoryLoading {
    func load() async -> ScanStoreHistorySnapshot {
        await Task.detached(priority: .utility) {
            ScanStoreHistorySnapshot(
                scanHistory: ScanHistoryService.summary(),
                cleanupHistory: CleanupHistoryService.summary()
            )
        }.value
    }
}

enum MemoryRefreshPolicy: Int, Comparable, Sendable {
    case lightweight
    case automatic
    case fullMemory

    static func < (lhs: MemoryRefreshPolicy, rhs: MemoryRefreshPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MenuBarRefreshRequest: Equatable, Sendable {
    let policy: MemoryRefreshPolicy
    let showLoadingWhenEmpty: Bool

    func merging(_ other: Self) -> Self {
        Self(
            policy: max(policy, other.policy),
            showLoadingWhenEmpty: showLoadingWhenEmpty || other.showLoadingWhenEmpty
        )
    }
}

enum MenuBarMemoryRefreshThrottle {
    static func shouldRefresh(
        now: Date,
        force: Bool,
        primarySnapshotAvailable: Bool,
        menuStatusSnapshotAvailable: Bool,
        refreshedAt: Date?,
        interval: TimeInterval
    ) -> Bool {
        if force { return true }
        if !primarySnapshotAvailable, !menuStatusSnapshotAvailable { return true }
        guard let refreshedAt else { return true }
        // Allow timer/publish jitter without accidentally skipping every other tick.
        // Coalescing still guarantees at most one memory read in flight.
        return now.timeIntervalSince(refreshedAt) >= interval - min(0.05, interval * 0.05)
    }
}

enum MenuBarMemorySnapshotAdoption: Equatable, Sendable {
    case none
    case menuStatusOnly
    case primaryAndMenuFromRefresh
    case primaryAndMenuFromMonitor

    static func resolve(
        policy: MemoryRefreshPolicy,
        shouldRefreshMemorySnapshot: Bool,
        sampledSnapshotAvailable: Bool,
        primarySnapshotMissing: Bool,
        monitorCreatedSnapshot: Bool
    ) -> Self {
        if sampledSnapshotAvailable {
            if policy == .fullMemory {
                return .primaryAndMenuFromRefresh
            }
            if policy == .automatic, shouldRefreshMemorySnapshot {
                return .menuStatusOnly
            }
        }

        if primarySnapshotMissing, monitorCreatedSnapshot {
            return .primaryAndMenuFromMonitor
        }
        return .none
    }
}

enum MenuBarDisplayMemorySnapshotSelection {
    static func resolve(
        menuStatusSnapshot: MemorySnapshot?,
        primarySnapshot: MemorySnapshot?
    ) -> MemorySnapshot? {
        guard let menuStatusSnapshot else { return primarySnapshot }
        guard let primarySnapshot else { return menuStatusSnapshot }
        return shouldReplace(current: menuStatusSnapshot, with: primarySnapshot)
            ? primarySnapshot
            : menuStatusSnapshot
    }

    static func shouldReplace(
        current: MemorySnapshot?,
        with candidate: MemorySnapshot
    ) -> Bool {
        guard let current else { return true }
        if let currentInstant = current.capturedInstant,
           let candidateInstant = candidate.capturedInstant {
            return candidateInstant >= currentInstant
        }
        return candidate.generatedAt >= current.generatedAt
    }
}

@MainActor
final class MenuBarRefreshCoordinator {
    typealias Operation = @MainActor (MenuBarRefreshRequest) async -> Void

    private let operation: Operation
    private var currentRequest: MenuBarRefreshRequest?
    private var pendingRequest: MenuBarRefreshRequest?
    private var isExecutingCurrent = false
    private var driverTask: Task<Void, Never>?
    private(set) var isRefreshInFlight = false

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func request(
        policy: MemoryRefreshPolicy,
        showLoadingWhenEmpty: Bool = false
    ) {
        let request = MenuBarRefreshRequest(
            policy: policy,
            showLoadingWhenEmpty: showLoadingWhenEmpty
        )

        guard driverTask != nil else {
            currentRequest = request
            isRefreshInFlight = true
            startDriver()
            return
        }

        guard let currentRequest else {
            self.currentRequest = request
            return
        }

        if !isExecutingCurrent {
            self.currentRequest = currentRequest.merging(request)
        } else if request.policy <= currentRequest.policy {
            self.currentRequest = currentRequest.merging(request)
        } else if let pendingRequest {
            self.pendingRequest = pendingRequest.merging(request)
        } else {
            pendingRequest = request
        }
    }

    func waitUntilIdle(maximumYields: Int) async -> Bool {
        for _ in 0..<maximumYields {
            if driverTask == nil { return true }
            await Task.yield()
        }
        return driverTask == nil
    }

    func cancelForTesting() {
        driverTask?.cancel()
    }

    private func startDriver() {
        driverTask = Task { @MainActor [weak self] in
            defer { self?.finishDriver() }
            while !Task.isCancelled {
                guard let request = self?.beginCurrentRequest(),
                      let operation = self?.operation else {
                    return
                }
                await operation(request)
                self?.completeCurrentRequest()
            }
        }
    }

    private func beginCurrentRequest() -> MenuBarRefreshRequest? {
        guard let currentRequest else { return nil }
        isExecutingCurrent = true
        return currentRequest
    }

    private func completeCurrentRequest() {
        isExecutingCurrent = false
        currentRequest = pendingRequest
        pendingRequest = nil
    }

    private func finishDriver() {
        currentRequest = nil
        pendingRequest = nil
        isExecutingCurrent = false
        driverTask = nil
        isRefreshInFlight = false
    }
}

@MainActor
final class MenuBarMonitorState: ObservableObject {
    @Published fileprivate(set) var snapshot: SystemMonitorSnapshot?
    private var telemetryHistory = MenuBarTelemetryHistory()
    private var memoryTelemetryHistory = MenuBarTelemetryHistory()
    private var displayDurations: Set<TimeInterval> = []
    private var displayHistoryTask: Task<Void, Never>?
    private var displayHistoryGeneration = 0
    private var displayHistoryPending = false
    private var telemetrySourceVersion: UInt64 = 0
    private var memorySourceVersion: UInt64 = 0
    private var preparedTelemetrySourceVersion: UInt64?
    private var preparedMemorySourceVersion: UInt64?
    private(set) var displayTelemetryVersion: UInt64 = 0
    private(set) var displayMemoryVersion: UInt64 = 0
    private var preparedTelemetry: [TimeInterval: [MenuBarTelemetryPoint]] = [:]
    private var preparedMemory: [TimeInterval: [MenuBarTelemetryPoint]] = [:]

    private var displayConsumers: [UUID: Set<TimeInterval>] = [:]
    func updateDisplayHistoryConsumer(_ id: UUID, durations: Set<TimeInterval>) {
        displayConsumers[id] = durations.isEmpty ? nil : durations
        setDisplayHistoryDemand(Set(displayConsumers.values.flatMap { $0 }))
    }

    func setDisplayHistoryDemand(_ durations: Set<TimeInterval>) {
        guard durations != displayDurations else { return }
        displayDurations = Set(durations.sorted().prefix(4))
        preparedTelemetrySourceVersion = nil
        preparedMemorySourceVersion = nil
        displayHistoryGeneration &+= 1
        displayHistoryTask?.cancel()
        displayHistoryTask = nil
        preparedTelemetry = preparedTelemetry.filter { displayDurations.contains($0.key) }
        preparedMemory = preparedMemory.filter { displayDurations.contains($0.key) }
        scheduleDisplayHistory()
    }

    func displayHistory(within duration: TimeInterval, memory: Bool = false) -> [MenuBarTelemetryPoint] {
        (memory ? preparedMemory : preparedTelemetry)[duration] ?? []
    }

    private func scheduleDisplayHistory() {
        guard !displayDurations.isEmpty else { return }
        displayHistoryPending = true
        guard displayHistoryTask == nil else { return }
        let generation = displayHistoryGeneration
        displayHistoryTask = Task { @MainActor [weak self] in
            while let self, displayHistoryPending, generation == displayHistoryGeneration {
                displayHistoryPending = false
                let telemetry = telemetryHistory
                let memory = memoryTelemetryHistory
                let durations = displayDurations
                let date = chartReferenceDate
                let telemetryVersion = telemetrySourceVersion
                let memoryVersion = memorySourceVersion
                let needsTelemetry = preparedTelemetrySourceVersion != telemetryVersion
                let needsMemory = preparedMemorySourceVersion != memoryVersion
                let result = await Task.detached(priority: .userInitiated) {
                    (needsTelemetry ? Dictionary(uniqueKeysWithValues: durations.map { ($0, telemetry.points(within: $0, referenceDate: date)) }) : nil,
                     needsMemory ? Dictionary(uniqueKeysWithValues: durations.map { ($0, memory.points(within: $0, referenceDate: date)) }) : nil)
                }.value
                guard !Task.isCancelled, generation == displayHistoryGeneration else { return }
                objectWillChange.send()
                if let telemetry = result.0 {
                    preparedTelemetry = telemetry
                    preparedTelemetrySourceVersion = telemetryVersion
                    displayTelemetryVersion &+= 1
                }
                if let memory = result.1 {
                    preparedMemory = memory
                    preparedMemorySourceVersion = memoryVersion
                    displayMemoryVersion &+= 1
                }
            }
            self?.displayHistoryTask = nil
        }
    }

    private let metricHistoryStore: MetricHistoryStore?
    private(set) var sessionDownloadedBytes: Int64 = 0
    private(set) var sessionUploadedBytes: Int64 = 0

    init(metricHistoryStore: MetricHistoryStore? = nil) {
        self.metricHistoryStore = metricHistoryStore
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            let fixture = MiniWindowDemoData.fixture
            telemetryHistory.restore(fixture.telemetry)
            memoryTelemetryHistory.restore(fixture.telemetry)
            snapshot = fixture.snapshot
        }
#endif
    }

    var history: [MenuBarTelemetryPoint] {
        telemetryHistory.points
    }

    var memoryHistory: [MenuBarTelemetryPoint] {
        memoryTelemetryHistory.points
    }

    /// Chart consumers request only their visible window; the full 28-day
    /// history is never materialized on the render path.
    private var chartReferenceDate: Date {
#if DEBUG || STORAGE_CLEANER_BETA
        MiniWindowDemoData.chartDate(liveDate: Date())
#else
        Date()
#endif
    }

    func history(
        within duration: TimeInterval,
        referenceDate: Date? = nil
    ) -> [MenuBarTelemetryPoint] {
        telemetryHistory.points(within: duration, referenceDate: referenceDate ?? chartReferenceDate)
    }

    func memoryHistory(
        within duration: TimeInterval,
        referenceDate: Date? = nil
    ) -> [MenuBarTelemetryPoint] {
        memoryTelemetryHistory.points(within: duration, referenceDate: referenceDate ?? chartReferenceDate)
    }

    func needsRefresh(at now: Date = Date(), interval: TimeInterval) -> Bool {
        guard let generatedAt = snapshot?.generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) >= max(0, interval)
    }

    func restoreHistory(
        _ points: [MenuBarTelemetryPoint],
        memoryPoints: [MenuBarTelemetryPoint] = []
    ) {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        telemetryHistory.restore(points)
        memoryTelemetryHistory.restore(memoryPoints)
        telemetrySourceVersion &+= 1
        memorySourceVersion &+= 1
        scheduleDisplayHistory()
    }

    func update(_ snapshot: SystemMonitorSnapshot) {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        if let previous = telemetryHistory.latest,
           snapshot.generatedAt > previous.date {
            let interval = min(5, snapshot.generatedAt.timeIntervalSince(previous.date))
            if let download = snapshot.networkThroughput?.downBytesPerSecond {
                sessionDownloadedBytes = accumulatedSessionBytes(
                    current: sessionDownloadedBytes,
                    rate: download,
                    interval: interval
                )
            }
            if let upload = snapshot.networkThroughput?.upBytesPerSecond {
                sessionUploadedBytes = accumulatedSessionBytes(
                    current: sessionUploadedBytes,
                    rate: upload,
                    interval: interval
                )
            }
        }
        let point = MenuBarTelemetryPoint(snapshot: snapshot)
        let historyPoint = point.replacingMemory(with: nil)
        telemetryHistory.append(historyPoint)
        self.snapshot = snapshot
        telemetrySourceVersion &+= 1
        scheduleDisplayHistory()
        if let metricHistoryStore {
            Task {
                await metricHistoryStore.appendTelemetry(historyPoint)
            }
        }
    }

    func recordMemorySample(_ snapshot: MemorySnapshot) {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        objectWillChange.send()
        let point = MenuBarTelemetryPoint(memorySnapshot: snapshot)
        memoryTelemetryHistory.append(point)
        memorySourceVersion &+= 1
        scheduleDisplayHistory()
        if let metricHistoryStore {
            Task {
                await metricHistoryStore.appendMemoryTelemetry(point)
            }
        }
    }

    private func accumulatedSessionBytes(
        current: Int64,
        rate: Int64,
        interval: TimeInterval
    ) -> Int64 {
        guard rate > 0, interval > 0 else { return current }
        let delta = (Double(rate) * interval).rounded()
        guard delta.isFinite, delta > 0 else { return current }
        let remaining = Double(Int64.max - current)
        guard delta < remaining else { return Int64.max }
        return current + Int64(delta)
    }
}

struct AppNavigationRoute: Equatable {
    let filter: ReviewFilter
    let utilityTool: ReviewFilter
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published private(set) var route = AppNavigationRoute(filter: .overview, utilityTool: .memory)

    var selectedFilter: ReviewFilter {
        route.filter
    }

    var selectedUtilityFilter: ReviewFilter {
        route.utilityTool
    }

    @discardableResult
    func select(_ filter: ReviewFilter) -> Bool {
        let destination = filter.sidebarDestination
        let utilityTool = filter.utilityToolDestination ?? route.utilityTool
        return update(filter: destination, utilityTool: utilityTool)
    }

    @discardableResult
    func selectSidebarDestination(_ filter: ReviewFilter) -> Bool {
        let destination = filter.sidebarDestination
        let utilityTool = filter.utilityToolDestination ?? route.utilityTool
        return update(filter: destination, utilityTool: utilityTool)
    }

    @discardableResult
    func selectUtilityTool(_ filter: ReviewFilter) -> Bool {
        guard ReviewFilter.utilityToolCases.contains(filter) else { return false }
        return update(filter: route.filter, utilityTool: filter)
    }

    @discardableResult
    private func update(filter: ReviewFilter, utilityTool: ReviewFilter) -> Bool {
        let nextRoute = AppNavigationRoute(filter: filter, utilityTool: utilityTool)
        guard nextRoute != route else { return false }
        route = nextRoute
        return true
    }
}

@MainActor
final class ScanStore: ObservableObject {
    private static let menuBarRefreshIntervalDefaultsKey = "menuBar.refreshInterval"
    private static let developerInactivityThresholdDefaultsKey =
        "cleanup.developerInactivityThresholdDays"
    static let initialPermissionCheckDefaultsKey = "scanReadiness.initialLaunchCheckCompleted.v1"
    // Keep the opt-in BTM diagnostic bounded; normal refreshes never invoke it.
    private static let startupBackgroundTaskDiagnosticTimeout: TimeInterval = 60
    private enum SmartScanPresentationTiming {
        static let preparingMinimum: TimeInterval = 0.20
        static let progressPublicationMinimum: TimeInterval = 0.12
    }

    @Published var result: ScanResult?
    @Published var isScanning = false
    @Published private(set) var scanPresentation = ScanPresentation()
    @Published private(set) var isFinalizingMainScan = false
    @Published private(set) var scanPresentationRoute: ReviewFilter?
    @Published private(set) var mainScanProgress: DiskScanProgress?
    @Published private(set) var cleanupScanSession: ScanSession?
    @Published private(set) var developerInactivityThresholdDays: Int
    @Published private(set) var selectedSafeCleanupScopes = Set(SafeCleanupScanScope.allCases)
    @Published private(set) var cleanupSelection = CleanupSelection()
    @Published private(set) var cleanupDryRunSummary: CleanupDryRunSummary?
    @Published private(set) var isCancellingMainScan = false
    @Published private(set) var cleanupWorkflowState = CleanupWorkflowState.idle
    @Published private(set) var pendingCleanPlan: CleanPlan?
    @Published private(set) var pendingCleanPreflight: CleanPreflightReport?
    @Published private(set) var cleanupExecutionProgress: CleanupExecutionProgress?
    @Published private(set) var lastCleanReport: CleanReport?
    @Published private(set) var cleanupRecoveryReport: CleanupRecoveryReport?
    @Published private(set) var operationReports: [CleanReport] = []
    @Published private(set) var operationReportWarning: String?
    @Published private(set) var operationRecoveryResult: CleanupRecoveryReport?
    @Published private(set) var isRestoringRecordedOperation = false
#if DEBUG
    @Published private(set) var isDebugSmartScanSessionFixtureActive = false
    // The launch flag is visible before any parent view can schedule the
    // automatic startup scan; ContentView installs the deterministic state later.
    @Published private(set) var isDebugAppUpdatePresentationFixtureActive =
        DebugAppUpdatePresentationFixture.launchScenario != nil
#endif
    @Published var isV2RestoreConfirmationPresented = false
    @Published private(set) var isRestoringV2Cleanup = false
    @Published var errorMessage: String?
    @Published var actionMessage: String?
    private var actionMessageDismissalTask: Task<Void, Never>?
    let navigationState = AppNavigationState()
    @Published var selectedItemID: String?
    @Published var preferredItemScopeFilter: ItemScopeFilter?
    @Published var requestedFilter: ReviewFilter?
    @Published var memoryShowsAllProcesses = true
    @Published var pendingTrashItem: StorageItem?
    @Published var pendingBulkTrashItems: [StorageItem] = []
    @Published var pendingEmptyTrashSummary: TrashSummary?
    @Published var isCheckingTrashSummary = false
    @Published private(set) var isMovingItemsToTrash = false
    @Published private(set) var cleanupOperationSnapshot: CleanupOperationSnapshot?
    @Published var isEmptyingTrash = false
    @Published var scanHistorySummary = ScanHistorySummary(entries: []) {
        didSet { noteScanHistoryMutation() }
    }
    @Published var cleanupHistorySummary = CleanupHistorySummary(entries: []) {
        didSet { noteCleanupHistoryMutation() }
    }
    @Published var pendingCleanupRestoreEntry: CleanupHistoryEntry?
    @Published var isRestoringCleanup = false
    @Published var startupDomainItems: [StartupItemsDomain.Item] = []
    @Published var startupCoverage: StartupCoverageReport = .empty
    @Published var startupScanProgress: StartupItemsScanProgress?
    @Published var isLoadingStartupItems = false
    @Published var hasScannedStartupItems = false
    @Published var selectedStartupCandidate: StartupItemsDomain.Candidate?
    @Published var pendingStartupOperationPlan: StartupItemsDomain.StartupOperationPlan?
    @Published var pendingStartupOperationCandidate: StartupItemsDomain.Candidate?
    @Published var isPerformingStartupOperation = false
    @Published private(set) var lastStartupUndoRecordID: UUID?
    @Published private(set) var lastStartupUndoCandidate: StartupItemsDomain.Candidate?
    @Published var memorySnapshot: MemorySnapshot?
    @Published var isLoadingMemory = false
    @Published var isOptimizingMemory = false
    @Published var memoryOptimizationResult: MemoryOptimizationResult?
    @Published var selectedMemoryProcessIDs: Set<Int32> = []
    @Published var pendingMemoryProcess: MemoryProcess?
    @Published var pendingMemoryProcessesToQuit: [MemoryProcess] = []
    @Published var pendingMemoryQuitSummary: MemoryQuitSelectionSummary?
    @Published private(set) var pendingMemoryOptimizationPlan: MemoryOptimizationPlan?
    @Published private(set) var memoryOptimizationState: MemoryOptimizationState = .idle
    @Published var isMemoryBatchQuitConfirmationPresentedInMenuBar = false
    @Published private(set) var menuBarPreparedProcesses: MenuBarPreparedProcesses?
    @Published private(set) var menuBarPreparedMemoryApps: [MemoryAppUsage] = []
    private(set) var menuBarPreparedMemoryAppsVersion: UInt64 = 0
    private var menuBarPreparedMemoryAppsDate: Date?
    private let menuBarContinuousProcessSampler = MenuBarProcessSampler()
    private var menuBarProcessDemand: PanelSection = .overview
    private var menuBarVisibleProcessTask: Task<Void, Never>?
    private var menuBarVisibleProcessGeneration = 0
    @Published var energyImpactSnapshot: EnergyImpactSnapshot?
    @Published var isLoadingEnergyImpact = false
    @Published private(set) var hasScannedEnergyImpact = false
    @Published private(set) var isEnergyImpactPageScanActive = false
    @Published private(set) var energyImpactScanPhase: EnergyImpactScanPhase?
    @Published private(set) var systemEnergySnapshot: SystemEnergySessionSnapshot?
    let systemEnergyAccumulator: SystemEnergyAccumulator
    let menuBarMonitorState: MenuBarMonitorState
    let menuBarAuxiliaryMonitorState: MenuBarAuxiliaryMonitorState
    @Published var menuBarRefreshInterval: MenuBarRefreshInterval {
        didSet {
            UserDefaults.standard.set(menuBarRefreshInterval.rawValue, forKey: Self.menuBarRefreshIntervalDefaultsKey)
        }
    }
    @Published var isMenuBarRefreshPaused = false
    @Published var installedApps: [InstalledAppItem] = []
    @Published var isLoadingInstalledApps = false
    @Published var hasScannedInstalledApps = false
    @Published var installedAppsScanCoverage: AppUninstallScanCoverage?
    @Published var isUninstallingApp = false
    @Published var pendingUninstallApp: InstalledAppItem?
    @Published var pendingRelatedCleanupApp: InstalledAppItem?
    @Published var isCleaningRelatedAppFiles = false
    @Published var appUpdates: [AppUpdateItem] = []
    @Published var isLoadingAppUpdates = false
    @Published var appUpdateProgress: AppUpdateProgress?
    /// Real inventory lifecycle, independent from the persisted update queue.
    /// In particular, an empty queue does not imply that a scan is idle.
    @Published private(set) var appUpdateScanState: ApplicationUpdateScanState = .idle
    @Published private(set) var appUpdatePresentationState: AppUpdatePresentationState = .idle(nil)
    @Published var ignoredAppUpdateCount = 0
    @Published var appUpdatesLastScannedAt: Date?
    @Published var appUpdatesLastScanSeconds: TimeInterval?
    @Published var appUpdatesAutoRescanPending = false
    @Published var pendingOneClickUpdatePlan: AppUpdateOneClickPlan?
    @Published var isRunningOneClickUpdate = false
    @Published var oneClickUpdateResult: AppUpdateOneClickResult?
    @Published private(set) var appUpdateQueueSnapshot: ApplicationUpdateQueueSnapshot?
    @Published private(set) var appUpdateScanWarnings: [String] = []
    @Published private(set) var websiteUpdateQueueSnapshot: WebsiteUpdateQueueSnapshot?
    @Published private(set) var websiteUpdateResultMessage: String?
    @Published private(set) var isPreparingWebsiteUpdateQueue = false
    @Published var duplicateItems: [StorageItem] = []
    @Published var isScanningDuplicates = false
    @Published var hasScannedDuplicates = false
    @Published var duplicateScanSeconds: TimeInterval?
    @Published private(set) var duplicateScanProgress: DuplicateFileScanProgress?
    @Published private(set) var duplicateScanCoverage: DuplicateFileScanCoverage?
    @Published private(set) var duplicateScanOutcome: DuplicateFileScanOutcome?
    @Published private(set) var pendingDuplicateCleanPlan: CleanPlan?
    @Published private(set) var pendingDuplicateCleanPreflight: CleanPreflightReport?
    @Published private(set) var duplicateCleanupProgress: CleanupExecutionProgress?
    @Published private(set) var duplicateCleanupReport: CleanReport?
    @Published private(set) var duplicateCleanupRecoveryReport: CleanupRecoveryReport?
    @Published var isDuplicateCleanupConfirmationPresented = false
    @Published var isDuplicateRestoreConfirmationPresented = false
    let duplicateFilesWorkspace: DuplicateFilesStore
    let largeFilesWorkspace: LargeFilesStore
    @Published var scanReadinessSummary: ScanReadinessSummary?
    @Published var scanReadinessCheckedAt: Date?
    @Published var isCheckingScanReadiness = false
    @Published var didCompleteInitialPermissionCheck: Bool
    @Published var isShowingAccessRepairGuide = false
    @Published var isShowingInitialFolderAccessPrompt = false

    private var menuBarNetworkSample: NetworkMonitorSample?
    private var menuBarMemoryStatusSnapshot: MemorySnapshot?
    private var menuBarMemorySnapshotRefreshedAt: Date?
    private let menuBarMemoryStatusProvider: @Sendable () async -> MemorySnapshot
    private var menuBarMemoryStatusTask: Task<Void, Never>?
    private var menuBarMemoryStatusGeneration = 0
    private let menuBarMemoryProcessProvider: @Sendable () async -> MemorySnapshot
    private var menuBarMemoryProcessTask: Task<Void, Never>?
    private var menuBarMemoryProcessGeneration = 0
    private let metricHistoryStore: MetricHistoryStore?
    private var didStartMetricHistoryLoad = false
    private var metricHistoryLoadTask: Task<Void, Never>?
    private lazy var menuBarRefreshCoordinator = MenuBarRefreshCoordinator { [weak self] request in
        guard let self else { return }
        await self.performMenuBarRefresh(
            policy: request.policy,
            showLoadingWhenEmpty: request.showLoadingWhenEmpty
        )
    }
    private var didPrepareFolderAccessThisLaunch = false
    private let folderAccessPanelCoordinator = AppOpenPanelCoordinator()
    private var activeFolderAccessRestoreID: UUID?
    private var activeScanReadinessCheckID: UUID?
    private var scanReadinessPhysicalTask: Task<ScanReadinessSummary, Never>?
    private var duplicateCleanupBundle: VerifiedDuplicatePlanBundle?
    private var duplicateCleanupTask: Task<Void, Never>?
    private var duplicateCleanupGeneration: UUID?
    private var duplicateRecoveryTask: Task<Void, Never>?
    private var duplicateWorkspaceMirrorTask: Task<Void, Never>?
    private var duplicateWorkspaceMirrorGeneration: UUID?
    private var scanReadinessPhysicalTaskID: UUID?
    private var scanReadinessSuccessHandler: (@MainActor (ScanReadinessSummary) -> Void)?
    private var persistedHistoryLoadTask: Task<Void, Never>?
    private var didStartPersistedHistoryLoad = false
    private var scanHistoryRevision: UInt = 0
    private var cleanupHistoryRevision: UInt = 0
    private var isPublishingPersistedScanHistory = false
    private var isPublishingPersistedCleanupHistory = false
    private let folderAccessRestoreTimeout: Duration
    private let scanReadinessTimeout: Duration
    private let restoreSavedAccessOperation: @Sendable () -> Void
    private let loadScanReadinessSummary: @Sendable () -> ScanReadinessSummary
    private let historyLoader: any ScanStoreHistoryLoading
    private let memoryCoordinator: MemoryCoordinator
    let heavyWorkCoordinator: HeavyWorkCoordinator
    let heavyWorkActivityStore: HeavyWorkActivityStore
    private let scanHeavyWorkService: ScanHeavyWorkService
    let cleanupFeatureConfiguration: CleanupFeatureConfiguration
    private let cleanupScanOperation: CleanupScanOperation
    private let cleanupRuleSetLoader: @Sendable () throws -> CleanupRuleSet
    private let cleanupPreferences: UserDefaults
    private let cleanupExecutor: SafeCleanupExecutor
    private let cleanupRecoveryService: CleanupRecoveryService
    private var cleanupActiveRuleSet: CleanupRuleSet?
    private var cleanupPlanTask: Task<Void, Never>?
    private var cleanupExecutionTask: Task<Void, Never>?
    private var cleanupPlanGeneration: UUID?
    private var cleanupExecutionGeneration: UUID?
    private var cleanupRecoveryTask: Task<Void, Never>?
    private var cleanupRecoveryGeneration: UUID?
    private var mainScanGeneration: UUID?
    private var mainScanTask: Task<Void, Never>?
    private var scanPresentationTimingTask: Task<Void, Never>?
    private var scanPresentationPhaseStartedAt: Date?
    private var mainScanLastProgressPublishedAt: Date?
    private var cleanupGeneration: UUID?
    private var emptyTrashGeneration: UUID?
    private var restoreGeneration: UUID?
    private var memoryOptimizationGeneration: UUID?
    private var memoryOptimizationTask: Task<Void, Never>?
    private var pendingMemoryPlanSnapshot: MemorySnapshot?
    private var startupScanGeneration: UUID?
    private var startupScanOperation: Task<Void, Never>?
    private var startupOperationPreviewGeneration: UUID?
    private var startupOperationPreviewTask: Task<Void, Never>?
    private var startupManagementOperation: Task<Void, Never>?
    private var appUpdateScanGeneration: UUID?
    private var appUpdateScanOperation: Task<Void, Never>?
    private var appUpdateLastProgressPublishedAt: Date?
    private var appUpdateLastProgressStage: ApplicationScanStage?
    private var appUpdateGeneration: UUID?
    private var appUpdateOperation: Task<Void, Never>?
    private var appUpdatePresentationMachine = AppUpdatePresentationMachine()
    private var pendingAppUpdateReport: AppUpdateReport?
    private var appUpdateCoordinatorMonitorTask: Task<Void, Never>?
    private var appUpdateCoordinatorMonitorToken: UUID?
    private var appUpdateExpectedSessionID: UUID?
    private var appUpdateCancellationRequestedSessionID: UUID?
    private var appUpdateBatchContext: ApplicationUpdateBatchContext?
    private var appUpdateGracefulQuitConsentSessionID: UUID?
    private var appUpdateGracefulQuitRequestedApplicationIDs = Set<String>()
    private var appUpdateRelaunchConsentSessionID: UUID?
    private var appUpdateRelaunchTargets = [String: ApplicationUpdateRelauncher.Target]()
    private var appUpdateRelaunchAttemptedApplicationIDs = Set<String>()
    private var isPreparingApplicationUpdatesForTermination = false
    private let applicationInventoryScanner: any ApplicationInventoryScanning
    private let startupScanCoordinator: StartupScanCoordinator
    private let startupItemManager: StartupItemsDomain.UserLaunchAgentManager
    private let applicationUpdateCoordinator: ApplicationUpdateCoordinator
    private let applicationUpdateGracefulQuitRequester: ApplicationUpdateGracefulQuitRequester
    private let applicationUpdateRelauncher: ApplicationUpdateRelauncher
    private let officialSourceRegistry = OfficialSourceRegistry()
    private let websiteUpdateWorkflow: WebsiteUpdateWorkflow
    private var didRestoreApplicationUpdateQueue = false
    private var pendingAutomaticUpdateEvaluation = false
    private var currentScanMode: ScanMode {
        .fallback
    }

    var menuBarMonitorSnapshot: SystemMonitorSnapshot? {
        menuBarMonitorState.snapshot
    }

    var menuBarDisplayMemorySnapshot: MemorySnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return memorySnapshot ?? MiniWindowDemoData.memorySnapshot
        }
#endif
        return MenuBarDisplayMemorySnapshotSelection.resolve(
            menuStatusSnapshot: menuBarMemoryStatusSnapshot,
            primarySnapshot: memorySnapshot
        )
    }

    /// Single production projection consumed by the App Updates UI.  The
    /// coordinator queue remains the only batch source of truth; scan state is
    /// supplied by the real inventory operation above it.
    var appUpdateOrchestratorState: UpdateOrchestratorState {
        UpdateOrchestratorState.project(
            scanState: appUpdateScanState,
            queue: appUpdateQueueSnapshot,
            presentationSessionID: appUpdatePresentationState.sessionID
        )
    }

    var selectedFilter: ReviewFilter {
        get { navigationState.selectedFilter }
        set { navigationState.selectSidebarDestination(newValue) }
    }

    var selectedUtilityFilter: ReviewFilter {
        get { navigationState.selectedUtilityFilter }
        set { navigationState.selectUtilityTool(newValue) }
    }

    init(
        heavyWorkCoordinator: HeavyWorkCoordinator = HeavyWorkCoordinator(),
        scanHeavyWorkOperations: ScanHeavyWorkService.Operations = .init(),
        largeFilesScanOperation: LargeFilesStore.ScanOperation? = nil,
        duplicateFilesScanOperation: DuplicateFilesStore.ScanOperation? = nil,
        heavyWorkActivityStore: HeavyWorkActivityStore? = nil,
        folderAccessRestoreTimeout: Duration = .seconds(5),
        scanReadinessTimeout: Duration = .seconds(8),
        restoreSavedAccessOperation: @escaping @Sendable () -> Void = {
            _ = FolderAccessGrantService.restoreSavedAccess()
        },
        loadScanReadinessSummary: @escaping @Sendable () -> ScanReadinessSummary = {
            ScanReadinessService.summary()
        },
        historyLoader: any ScanStoreHistoryLoading = UserDefaultsScanStoreHistoryLoader(),
        metricHistoryStore: MetricHistoryStore? = nil,
        systemEnergyAccumulator: SystemEnergyAccumulator? = nil,
        memoryCoordinator: MemoryCoordinator? = nil,
        menuBarMemoryStatusProvider: @escaping @Sendable () async -> MemorySnapshot = {
            await MemoryOptimizerService.statusSnapshot()
        },
        menuBarMemoryProcessProvider: @escaping @Sendable () async -> MemorySnapshot = {
            await MemoryOptimizerService.snapshot()
        },
        startupScanCoordinator: StartupScanCoordinator = StartupScanCoordinator(),
        startupItemManager: StartupItemsDomain.UserLaunchAgentManager? = nil,
        applicationInventoryScanner: any ApplicationInventoryScanning = ApplicationInventoryScanner(),
        applicationUpdateCoordinator: ApplicationUpdateCoordinator? = nil,
        applicationUpdateGracefulQuitRequester: ApplicationUpdateGracefulQuitRequester? = nil,
        applicationUpdateRelauncher: ApplicationUpdateRelauncher? = nil,
        websiteUpdateWorkflow: WebsiteUpdateWorkflow? = nil,
        cleanupFeatureConfiguration: CleanupFeatureConfiguration = .productDefault,
        cleanupScanOperation: @escaping CleanupScanOperation = CleanupScanOperations.live,
        cleanupRuleSetLoader: @escaping @Sendable () throws -> CleanupRuleSet = {
            try CleanupRuleSetLoader.loadBundled()
        },
        cleanupPreferences: UserDefaults = .standard,
        cleanupExecutor: SafeCleanupExecutor? = nil,
        cleanupRecoveryService: CleanupRecoveryService = CleanupRecoveryService(),
        cleanReportLoader: @escaping () -> [CleanReport] = {
            CleanReportStore.load()
        }
    ) {
        self.cleanupPreferences = cleanupPreferences
        self.menuBarMemoryStatusProvider = menuBarMemoryStatusProvider
        self.menuBarMemoryProcessProvider = menuBarMemoryProcessProvider
        developerInactivityThresholdDays = DeveloperCleanupAgePolicy.normalizedThresholdDays(
            cleanupPreferences.integer(forKey: Self.developerInactivityThresholdDefaultsKey)
        )
        self.metricHistoryStore = metricHistoryStore
        self.systemEnergyAccumulator = systemEnergyAccumulator ?? SystemEnergyAccumulator()
        menuBarMonitorState = MenuBarMonitorState(
            metricHistoryStore: metricHistoryStore
        )
        menuBarAuxiliaryMonitorState = MenuBarAuxiliaryMonitorState(
            metricHistoryStore: metricHistoryStore,
            powerHistoryURL: metricHistoryStore == nil
                ? MenuBarPowerHistoryStore.defaultURL
                : nil
        )
        self.heavyWorkCoordinator = heavyWorkCoordinator
        let resolvedActivityStore = heavyWorkActivityStore
            ?? HeavyWorkActivityStore(coordinator: heavyWorkCoordinator)
        self.heavyWorkActivityStore = resolvedActivityStore
        self.duplicateFilesWorkspace = DuplicateFilesStore(
            coordinator: heavyWorkCoordinator,
            activityStore: resolvedActivityStore,
            scanOperation: duplicateFilesScanOperation
        )
        self.largeFilesWorkspace = LargeFilesStore(
            coordinator: heavyWorkCoordinator,
            activityStore: resolvedActivityStore,
            scanOperation: largeFilesScanOperation
        )
        scanHeavyWorkService = ScanHeavyWorkService(
            coordinator: heavyWorkCoordinator,
            operations: scanHeavyWorkOperations,
            onCleanupQuarantineCleared: {
                await resolvedActivityStore.refresh()
            }
        )
        self.folderAccessRestoreTimeout = folderAccessRestoreTimeout
        self.scanReadinessTimeout = scanReadinessTimeout
        self.restoreSavedAccessOperation = restoreSavedAccessOperation
        self.loadScanReadinessSummary = loadScanReadinessSummary
        self.historyLoader = historyLoader
        self.memoryCoordinator = memoryCoordinator ?? MemoryCoordinator()
        self.cleanupFeatureConfiguration = cleanupFeatureConfiguration
        self.cleanupScanOperation = cleanupScanOperation
        self.cleanupRuleSetLoader = cleanupRuleSetLoader
        self.cleanupExecutor = cleanupExecutor ?? SafeCleanupExecutor(
            coordinator: heavyWorkCoordinator,
            persistReport: { report, identities in
                try CleanupReportJournal.live.checkpoint(report, expectedIdentities: identities)
            }
        )
        self.cleanupRecoveryService = cleanupRecoveryService
        self.startupScanCoordinator = startupScanCoordinator
        self.startupItemManager = startupItemManager ?? .live()
        self.applicationInventoryScanner = applicationInventoryScanner
        self.applicationUpdateCoordinator = applicationUpdateCoordinator
            ?? ApplicationUpdateCoordinator(
                repository: ApplicationUpdateQueueRepository(fileURL: ApplicationUpdateQueueLocation.defaultURL),
                executor: ProviderBackedApplicationUpdateExecutor(
                    heavyWorkCoordinator: heavyWorkCoordinator
                )
            )
        self.applicationUpdateGracefulQuitRequester = applicationUpdateGracefulQuitRequester
            ?? ApplicationUpdateGracefulQuitRequester()
        self.applicationUpdateRelauncher = applicationUpdateRelauncher
            ?? ApplicationUpdateRelauncher()
        self.websiteUpdateWorkflow = websiteUpdateWorkflow
            ?? WebsiteUpdateWorkflow(
                queue: WebsiteUpdateQueue(
                    store: FileWebsiteUpdateQueueStore(fileURL: WebsiteUpdateQueueLocation.defaultURL)
                ),
                opener: ClosureWebsiteUpdatePageOpener { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
            )
        menuBarRefreshInterval = UserDefaults.standard.string(forKey: Self.menuBarRefreshIntervalDefaultsKey)
            .flatMap(MenuBarRefreshInterval.init(rawValue:))
            ?? MenuBarRefreshInterval.defaultValue
        didCompleteInitialPermissionCheck = UserDefaults.standard.bool(forKey: Self.initialPermissionCheckDefaultsKey)
        duplicateCleanupReport = cleanReportLoader().first {
            $0.rulesVersion == VerifiedDuplicateCleanPlanBuilder.rulesVersion
                && !$0.restorableReceipts.isEmpty
        }
    }

    func loadPersistedHistoryIfNeeded() async {
        if let persistedHistoryLoadTask {
            await persistedHistoryLoadTask.value
            return
        }
        guard !didStartPersistedHistoryLoad else { return }

        didStartPersistedHistoryLoad = true
        let scanRevision = scanHistoryRevision
        let cleanupRevision = cleanupHistoryRevision
        let loader = historyLoader
        let task = Task { [weak self] in
            let snapshot = await loader.load()
            guard let self else { return }
            persistedHistoryLoadTask = nil
            if scanHistoryRevision == scanRevision {
                isPublishingPersistedScanHistory = true
                scanHistorySummary = snapshot.scanHistory
                isPublishingPersistedScanHistory = false
            }
            if cleanupHistoryRevision == cleanupRevision {
                isPublishingPersistedCleanupHistory = true
                cleanupHistorySummary = snapshot.cleanupHistory
                isPublishingPersistedCleanupHistory = false
            }
        }
        persistedHistoryLoadTask = task
        await task.value
    }

    private func noteScanHistoryMutation() {
        guard !isPublishingPersistedScanHistory else { return }
        scanHistoryRevision &+= 1
    }

    private func noteCleanupHistoryMutation() {
        guard !isPublishingPersistedCleanupHistory else { return }
        cleanupHistoryRevision &+= 1
    }

    var isPreparingMainScan: Bool {
        isScanning || isCheckingScanReadiness
    }

    var activeScanStatusText: String? {
        if largeFilesWorkspace.isAnalyzingStorage {
            return L10n.text("正在分析磁盘空间", "Analyzing disk space")
        }
        if isScanningDuplicates || duplicateFilesWorkspace.isScanning {
            return L10n.text("正在扫描重复文件", "Scanning duplicate files")
        }
        if largeFilesWorkspace.isScanning {
            return L10n.text("正在扫描大型文件", "Scanning large files")
        }
        if isCheckingScanReadiness {
            return L10n.text("正在检查扫描权限", "Checking scan access")
        }
        if isScanning {
            return L10n.text("正在扫描可清理项目", "Scanning cleanup candidates")
        }
        return nil
    }

    var isPreparingScan: Bool {
        isScanning
            || isCheckingScanReadiness
            || isScanningDuplicates
            || largeFilesWorkspace.isScanning
            || largeFilesWorkspace.isAnalyzingStorage
            || duplicateFilesWorkspace.isScanning
    }

    var scanPresentationState: SmartScanPresentationState {
        scanPresentation.state
    }

    var scanPresentationSessionID: UUID? {
        scanPresentation.sessionID
    }

    private var isCleanupExecutionActive: Bool {
        cleanupExecutionTask != nil || cleanupRecoveryTask != nil || isRestoringV2Cleanup
    }

    private var activePresentationRoute: ReviewFilter {
        navigationState.selectedFilter == .utilityHub
            ? navigationState.selectedUtilityFilter
            : navigationState.selectedFilter
    }

    private func beginScanPresentation(sessionID: UUID) {
        scanPresentationTimingTask?.cancel()
        scanPresentationTimingTask = nil
        scanPresentation.begin(sessionID: sessionID)
        scanPresentationPhaseStartedAt = Date()
    }

    @discardableResult
    private func transitionScanPresentation(
        to state: SmartScanPresentationState,
        matching sessionID: UUID
    ) -> Bool {
        guard scanPresentation.transition(to: state, matching: sessionID) else {
            return false
        }
        scanPresentationPhaseStartedAt = Date()
        return true
    }

    private func scheduleScanningPresentation(for sessionID: UUID) {
        scanPresentationTimingTask?.cancel()
        scanPresentationTimingTask = Task { @MainActor [weak self] in
            guard let self,
                  await self.waitForMinimumPresentationDuration(
                    SmartScanPresentationTiming.preparingMinimum,
                    state: .preparing,
                    matching: sessionID
                  ),
                  self.isScanning else {
                return
            }
            self.transitionScanPresentation(to: .scanning, matching: sessionID)
        }
    }

    private func publishMainScanProgress(
        _ progress: DiskScanProgress,
        force: Bool = false,
        now: Date = Date()
    ) {
        guard progress != mainScanProgress else { return }
        if !force,
           let lastPublishedAt = mainScanLastProgressPublishedAt,
           now.timeIntervalSince(lastPublishedAt)
            < SmartScanPresentationTiming.progressPublicationMinimum {
            return
        }
        mainScanProgress = progress
        mainScanLastProgressPublishedAt = now
    }

    /// Called only after the operation and its required persistence/drain return.
    /// Finish synchronously; presentation must not hold a completed result.
    private func finishScanPresentation(
        with terminalState: SmartScanPresentationState,
        matching sessionID: UUID
    ) {
        guard scanPresentationSessionID == sessionID else { return }
        scanPresentationTimingTask?.cancel()
        scanPresentationTimingTask = nil
        if terminalState == .results {
            if scanPresentationState == .preparing {
                transitionScanPresentation(to: .scanning, matching: sessionID)
            }
            if scanPresentationState == .scanning {
                transitionScanPresentation(to: .finalizing, matching: sessionID)
            }
        }
        guard transitionScanPresentation(to: terminalState, matching: sessionID) else { return }
        mainScanProgress = nil
        scanPresentationRoute = nil
    }

    /// Execution, identity revalidation and report persistence already completed.
    private func finishCleanupVerificationPresentation(
        with terminalState: SmartScanPresentationState,
        matching sessionID: UUID
    ) {
        guard scanPresentationSessionID == sessionID else { return }
        scanPresentationTimingTask?.cancel()
        scanPresentationTimingTask = nil
        transitionScanPresentation(to: terminalState, matching: sessionID)
    }

    private func waitForMinimumPresentationDuration(
        _ minimumDuration: TimeInterval,
        state: SmartScanPresentationState,
        matching sessionID: UUID
    ) async -> Bool {
        guard scanPresentationSessionID == sessionID,
              scanPresentationState == state else {
            return false
        }

        let elapsed = Date().timeIntervalSince(scanPresentationPhaseStartedAt ?? Date())
        let remaining = max(0, minimumDuration - elapsed)
        if remaining > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return false
            }
        }

        return !Task.isCancelled
            && scanPresentationSessionID == sessionID
            && scanPresentationState == state
    }

    /// Leaves retained scan and cleanup reports untouched; this only returns
    /// the Smart Scan shell to its start state after a terminal outcome.
    func resetSmartScanPresentation() {
        guard scanPresentationState.isTerminal else { return }
        scanPresentation.reset()
    }

#if DEBUG
    /// Installs a static session into the existing Store so screenshots exercise
    /// the production results views without starting a scanner or executor.
    func installDebugSmartScanSessionFixture(
        _ scenario: DebugSmartScanSessionFixture.Scenario
    ) {
        guard scenario == .results else { return }

        scanPresentationTimingTask?.cancel()
        scanPresentationTimingTask = nil
        mainScanTask?.cancel()
        mainScanTask = nil
        mainScanGeneration = nil
        cleanupPlanTask?.cancel()
        cleanupPlanTask = nil
        cleanupPlanGeneration = nil

        result = nil
        isScanning = false
        isFinalizingMainScan = false
        isCancellingMainScan = false
        mainScanProgress = nil
        cleanupScanSession = DebugSmartScanSessionFixture.session
        cleanupSelection = DebugSmartScanSessionFixture.selection
        cleanupDryRunSummary = nil
        cleanupWorkflowState = .results(sessionID: DebugSmartScanSessionFixture.session.id)
        pendingCleanPlan = nil
        pendingCleanPreflight = nil
        cleanupExecutionProgress = nil
        cleanupActiveRuleSet = nil
        lastCleanReport = nil
        cleanupRecoveryReport = nil
        errorMessage = nil
        actionMessage = nil
        scanPresentation = ScanPresentation(
            sessionID: DebugSmartScanSessionFixture.presentationID,
            state: .results
        )
        scanPresentationPhaseStartedAt = DebugSmartScanSessionFixture.referenceDate
        scanPresentationRoute = nil
        isDebugSmartScanSessionFixtureActive = true
    }

    /// Replaces only app-update presentation data. No scanner, provider,
    /// coordinator or executor is started while this fixture is active.
    func installDebugAppUpdatePresentationFixture(
        _ scenario: DebugAppUpdatePresentationFixture.Scenario
    ) {
        appUpdateScanOperation?.cancel()
        appUpdateScanOperation = nil
        appUpdateScanGeneration = nil
        appUpdateLastProgressPublishedAt = nil
        appUpdateLastProgressStage = nil
        appUpdateOperation?.cancel()
        appUpdateOperation = nil
        appUpdateGeneration = nil
        appUpdateCoordinatorMonitorTask?.cancel()
        appUpdateCoordinatorMonitorTask = nil
        appUpdateExpectedSessionID = nil
        appUpdateCancellationRequestedSessionID = nil
        appUpdateBatchContext = nil
        appUpdateGracefulQuitConsentSessionID = nil
        appUpdateGracefulQuitRequestedApplicationIDs.removeAll()
        pendingAppUpdateReport = nil
        pendingAutomaticUpdateEvaluation = false

        isLoadingAppUpdates = false
        isRunningOneClickUpdate = false
        isPreparingWebsiteUpdateQueue = false
        appUpdateProgress = nil
        appUpdatesAutoRescanPending = false
        pendingOneClickUpdatePlan = nil
        oneClickUpdateResult = nil
        websiteUpdateQueueSnapshot = nil
        websiteUpdateResultMessage = nil
        appUpdates = DebugAppUpdatePresentationFixture.applications
        ignoredAppUpdateCount = 0
        appUpdatesLastScannedAt = DebugAppUpdatePresentationFixture.lastScannedAt(for: scenario)
        appUpdatesLastScanSeconds = appUpdatesLastScannedAt == nil ? nil : 2.4
        appUpdateQueueSnapshot = DebugAppUpdatePresentationFixture.queueSnapshot(for: scenario)
        appUpdateScanWarnings = DebugAppUpdatePresentationFixture.warnings(for: scenario)
        errorMessage = nil
        actionMessage = nil

        let state = DebugAppUpdatePresentationFixture.presentationState(for: scenario)
        appUpdateScanState = switch state {
        case let .scanning(progress): .scanning(progress)
        case .failed: .failed("Debug fixture failure")
        case .cancelled: .cancelled
        default: .ready
        }
        appUpdatePresentationMachine = AppUpdatePresentationMachine(
            state: state,
            sessionID: DebugAppUpdatePresentationFixture.sessionID,
            generation: 1
        )
        appUpdatePresentationState = state
        isDebugAppUpdatePresentationFixtureActive = true
    }
#endif

    var scanActionSystemImage: String {
        if isCheckingScanReadiness {
            return "lock.open"
        }
        return isScanning ? "waveform.path.ecg" : "arrow.clockwise"
    }

    func scanActionTitle(normalTitle: String) -> String {
        isCheckingScanReadiness ? L10n.text("检查权限", "Checking Access") : normalTitle
    }

    func scanActionSystemImage(normalSystemImage: String) -> String {
        isPreparingScan ? scanActionSystemImage : normalSystemImage
    }

    func requestAccessRepairGuide() {
        isShowingAccessRepairGuide = true
    }

    var shouldShowPermissionPanelInMainInterface: Bool {
        !didCompleteInitialPermissionCheck
    }

    func prepareInitialPermissionCheckOnLaunch() {
        guard !didPrepareFolderAccessThisLaunch else { return }
        didPrepareFolderAccessThisLaunch = true

        if didCompleteInitialPermissionCheck {
            restoreFolderAccessForLaunch()
            return
        }

        refreshScanReadiness(
            markInitialPermissionCheckCompleted: true,
            showInitialFolderAccessPromptWhenNeeded: true
        )
    }

    func prepareInitialFolderAccessPrompt() {
        guard !didCompleteInitialPermissionCheck else { return }
        guard FolderAccessGrantService.shouldShowInitialPrompt() else { return }
        isShowingInitialFolderAccessPrompt = true
    }

    func prepareMenuBarLiveStatusOnLaunch() {
        guard menuBarMonitorSnapshot == nil, memorySnapshot == nil else { return }
        guard let metricHistoryStore else {
            refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
            return
        }
        guard !didStartMetricHistoryLoad else { return }
        didStartMetricHistoryLoad = true
        metricHistoryLoadTask = Task { @MainActor [weak self] in
            let snapshot = await metricHistoryStore.load()
            let historyLoadFailed = await metricHistoryStore.loadFailure != nil
            guard let self else { return }
            if historyLoadFailed {
                showActionMessage(L10n.text(
                    "监测历史无法读取，原文件已保留。新读数暂时仅保留在本次运行中。",
                    "Monitoring history could not be read. The original is preserved; new readings are kept only for this session."
                ))
            }
            menuBarMonitorState.restoreHistory(
                snapshot.telemetry,
                memoryPoints: snapshot.memoryTelemetry
            )
            menuBarAuxiliaryMonitorState.restoreHistory(snapshot)
            metricHistoryLoadTask = nil
            guard menuBarMonitorSnapshot == nil, memorySnapshot == nil else { return }
            refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
        }
    }

    func flushMenuBarMetricHistory() async {
        try? await metricHistoryStore?.flush()
    }

    func startSystemEnergyMonitoring() {
        systemEnergyAccumulator.onSnapshot = { [weak self] snapshot in
            self?.systemEnergySnapshot = snapshot
        }
        systemEnergySnapshot = systemEnergyAccumulator.snapshot
        menuBarAuxiliaryMonitorState.onBatterySample = { [weak self] battery, electrical in
            self?.systemEnergyAccumulator.recordBattery(battery, electrical: electrical)
        }
        systemEnergyAccumulator.start(passive: true)
    }

    func stopAndFlushSystemEnergyMonitoring() async {
        await systemEnergyAccumulator.stopAndFlush()
        systemEnergySnapshot = systemEnergyAccumulator.snapshot
    }

    func skipInitialFolderAccessPrompt() {
        FolderAccessGrantService.markInitialPromptShown()
        isShowingInitialFolderAccessPrompt = false
    }

    func requestRequiredFolderAccess() {
        guard !folderAccessPanelCoordinator.isPresenting else { return }

        FolderAccessGrantService.markInitialPromptShown()
        isShowingInitialFolderAccessPrompt = false

        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要授权读取的文件夹", "Choose Folders to Allow")
        panel.message = L10n.text(
            "建议选择下载、桌面、文稿或 iCloud Drive。应用会保存系统安全授权，下次打开自动恢复。",
            "Choose folders such as Downloads, Desktop, Documents, or iCloud Drive. The app saves macOS security access and restores it next time."
        )
        panel.prompt = L10n.text("保存授权", "Save Access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: PathSafety.homePath, isDirectory: true)

        let completion: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK else {
                self.showActionMessage(
                    L10n.text("未保存新的文件夹授权。", "No new folder access was saved.")
                )
                return
            }

            let savedCount = FolderAccessGrantService.saveAccess(for: panel.urls)
            self.refreshScanReadiness(markInitialPermissionCheckCompleted: true)

            if savedCount == 0 {
                self.showActionMessage(
                    L10n.text("未保存新的文件夹授权。", "No new folder access was saved.")
                )
            } else {
                self.showActionMessage(
                    L10n.text(
                        "已保存 \(savedCount) 个文件夹授权，下次打开会自动恢复。",
                        "Saved access for \(savedCount) folder(s); it will be restored next time."
                    )
                )
            }
        }

        folderAccessPanelCoordinator.present(
            panel,
            attachedTo: AppOpenPanelCoordinator.preferredHostWindow(),
            completion: completion
        )
    }

    func showFilter(_ filter: ReviewFilter) {
        navigationState.select(filter)
        let destination = filter.sidebarDestination
        if requestedFilter != destination {
            requestedFilter = destination
        }
    }

    func showCleanupReview(scope: ItemScopeFilter = .all, selectedItemID: String? = nil) {
        preferredItemScopeFilter = scope
        self.selectedItemID = selectedItemID
        showFilter(.green)
    }

    func startScanRespectingAccessGuide() {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        guard !isPreparingScan else { return }
        guard !isCleanupExecutionActive else {
            showActionMessage(L10n.text(
                "当前安全清理尚未结束，暂不能开始新的扫描。",
                "Safe cleanup is still in progress, so a new scan cannot start yet."
            ))
            return
        }
        if cleanupFeatureConfiguration.mode != .legacy,
           !ReviewFilter.fileWorkspaceCases.contains(selectedFilter) {
            startScan()
            return
        }

        let latestStatus = scanHistorySummary.latestStatus()
        if AccessRepairGuideService.shouldRefreshCurrentReadinessBeforeScan(
            latestStatus: latestStatus
        ) {
            performScanReadinessCheck { [weak self] summary in
                guard let self else { return }
                scanReadinessSummary = summary

                if AccessRepairGuideService.shouldPromptBeforeScan(
                    latestStatus: latestStatus,
                    currentReadiness: summary
                ) {
                    requestAccessRepairGuide()
                } else {
                    startScan()
                }
            } onTimeout: { [weak self] in
                guard let self else { return }
                startScan()
                showActionMessage(L10n.text(
                    "权限检查响应超时，已继续扫描；无法读取的目录会在结果中标记。",
                    "The access check timed out, so scanning continued; unreadable folders will be marked in the results."
                ))
            }
            return
        }

        if AccessRepairGuideService.shouldPromptBeforeScan(
            latestStatus: latestStatus,
            currentReadiness: scanReadinessSummary
        ) {
            requestAccessRepairGuide()
            return
        }

        startScan()
    }

    func startScan() {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        guard !isScanning,
              !isScanningDuplicates,
              !largeFilesWorkspace.isScanning,
              !largeFilesWorkspace.isAnalyzingStorage,
              !duplicateFilesWorkspace.isScanning else { return }
        guard !isCleanupExecutionActive else {
            showActionMessage(L10n.text(
                "当前安全清理尚未结束，暂不能开始新的扫描。",
                "Safe cleanup is still in progress, so a new scan cannot start yet."
            ))
            return
        }
        scanPresentationRoute = activePresentationRoute
        guard cleanupFeatureConfiguration.mode == .legacy
                || ReviewFilter.fileWorkspaceCases.contains(selectedFilter) else {
            startCleanupV2Scan()
            return
        }

        let generation = UUID()
        let mode = currentScanMode
        mainScanGeneration = generation
        beginScanPresentation(sessionID: generation)
        mainScanProgress = .starting(mode: mode)
        isScanning = true
        isFinalizingMainScan = false
        scheduleScanningPresentation(for: generation)
        errorMessage = nil
        actionMessage = nil
        let coordinator = heavyWorkCoordinator
        let service = scanHeavyWorkService
        let activityStore = heavyWorkActivityStore

        mainScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if mainScanGeneration == generation {
                    mainScanGeneration = nil
                    mainScanTask = nil
                    isScanning = false
                    isFinalizingMainScan = false
                }
            }
            do {
                let scanResult = try await coordinator.withLease(owner: .mainScan) { lease in
                    await activityStore.refresh()
                    return try await service.scan(
                        mode: mode,
                        lease: lease
                    ) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.mainScanGeneration == generation else { return }
                            self.mainScanProgress = progress
                        }
                    }
                }
                await activityStore.refresh()
                guard mainScanGeneration == generation else { return }

                isFinalizingMainScan = true

                result = scanResult
                scanReadinessSummary = ScanReadinessService.summary(fromScanDeniedPaths: scanResult.deniedPaths)
                scanReadinessCheckedAt = nil
                ScanHistoryService.record(scanResult)
                refreshScanHistory()
                selectedItemID = scanResult.topItems.first?.id
                finishScanPresentation(
                    with: .results,
                    matching: generation
                )
            } catch {
                guard mainScanGeneration == generation else {
                    await activityStore.refresh()
                    return
                }
                finishScanPresentation(
                    with: error is CancellationError ? .cancelled : .failed,
                    matching: generation
                )
                handleHeavyWorkError(error)
                await activityStore.refresh()
            }
        }
    }

    var canCancelMainScan: Bool {
        cleanupFeatureConfiguration.mode != .legacy
            && isScanning
            && !isFinalizingMainScan
            && !isCancellingMainScan
    }

    func cancelMainScan() {
        guard canCancelMainScan else { return }
        isCancellingMainScan = true
        if let generation = mainScanGeneration {
            transitionScanPresentation(to: .cancelling, matching: generation)
        }
        mainScanTask?.cancel()
    }

    func setCleanupCandidate(_ candidateID: ScanCandidateID, selected: Bool) {
        guard pendingCleanPlan == nil,
              cleanupExecutionTask == nil,
              let cleanupScanSession else { return }
        cleanupSelection.setCandidate(
            candidateID,
            selected: selected,
            in: cleanupScanSession
        )
        cleanupDryRunSummary = nil
    }

    func setDeveloperInactivityThresholdDays(_ days: Int) {
        let normalized = DeveloperCleanupAgePolicy.normalizedThresholdDays(days)
        guard normalized != developerInactivityThresholdDays else { return }
        developerInactivityThresholdDays = normalized
        cleanupPreferences.set(
            normalized,
            forKey: Self.developerInactivityThresholdDefaultsKey
        )
    }

    func toggleSafeCleanupScope(_ scope: SafeCleanupScanScope) {
        if selectedSafeCleanupScopes.contains(scope) {
            selectedSafeCleanupScopes.remove(scope)
        } else {
            selectedSafeCleanupScopes.insert(scope)
        }
    }

    func setCleanupCandidates(_ candidateIDs: [ScanCandidateID], selected: Bool) {
        guard pendingCleanPlan == nil,
              cleanupExecutionTask == nil,
              let cleanupScanSession else { return }
        cleanupSelection.setCandidates(
            candidateIDs,
            selected: selected,
            in: cleanupScanSession
        )
        cleanupDryRunSummary = nil
    }

    /// 用户主动选择可再生的绿色推荐项；黄色和红色始终需要单独明确选择。
    func selectRecommendedCleanupCandidates() {
        guard canEditV2CleanupSelection, let cleanupScanSession else { return }
        cleanupSelection = .recommended(
            in: cleanupScanSession,
            preservingExplicitReviewFrom: cleanupSelection
        )
        cleanupDryRunSummary = nil
    }

    func restoreDefaultCleanupSelection() {
        guard canEditV2CleanupSelection, let cleanupScanSession else { return }
        cleanupSelection = .defaults(in: cleanupScanSession)
        cleanupDryRunSummary = nil
    }

    /// 顶层快速全选只包含绿色候选；黄色和红色必须由用户明确选择。
    func selectAllCleanupCandidates() {
        guard canEditV2CleanupSelection, let cleanupScanSession else { return }
        setCleanupCandidates(
            cleanupScanSession.candidates
                .filter { $0.risk == .safe && $0.isSelectable }
                .map(\.id),
            selected: true
        )
    }

    /// 一键清空全部勾选。
    func clearCleanupCandidates() {
        guard canEditV2CleanupSelection, let cleanupScanSession else { return }
        setCleanupCandidates(
            cleanupScanSession.candidates.map(\.id),
            selected: false
        )
    }

    func prepareCleanupDryRun(candidateIDs: Set<ScanCandidateID>? = nil) {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        guard cleanupFeatureConfiguration.mode != .legacy,
              let cleanupScanSession,
              cleanupScanSession.outcome != .cancelled else {
            return
        }
        cleanupDryRunSummary = CleanupDryRunSummary.make(
            session: cleanupScanSession,
            selection: cleanupSelection,
            limitingTo: candidateIDs
        )
        showActionMessage(L10n.text(
            "Dry-run 已生成：未移动、未删除任何文件",
            "Dry run created: no files were moved or deleted"
        ))
    }

    func revealCleanupCandidate(_ candidate: ScanCandidate) {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        reveal(candidate.snapshot.standardizedPath)
    }

    var canEditV2CleanupSelection: Bool {
        return pendingCleanPlan == nil && cleanupExecutionTask == nil
    }

    var canRequestV2Cleanup: Bool {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return false }
#endif
        return canEditV2CleanupSelection
    }

    var isV2CleanupConfirmationPresented: Bool {
        if case .awaitingConfirmation = cleanupWorkflowState {
            return pendingCleanPlan != nil && pendingCleanPreflight?.isConfirmable == true
        }
        return false
    }

    func requestV2Cleanup(
        disposition: CleanupDisposition,
        candidateIDs: Set<ScanCandidateID>? = nil
    ) {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        guard cleanupFeatureConfiguration.mode == .v2Full,
              cleanupExecutionTask == nil,
              pendingCleanPlan == nil,
              let session = cleanupScanSession,
              let activeRules = cleanupActiveRuleSet,
              let presentationSessionID = scanPresentationSessionID else {
            return
        }

        let selectedIDs = cleanupSelection.selectedCandidateIDs.filter {
            candidateIDs?.contains($0) ?? true
        }
        let selection = cleanupSelection.limited(to: Set(selectedIDs))
        cleanupWorkflowState = .buildingPlan(sessionID: session.id)
        transitionScanPresentation(to: .verifying, matching: presentationSessionID)
        do {
            let plan = try CleanPlanBuilder.makePlan(
                session: session,
                selection: selection,
                activeRules: activeRules,
                disposition: disposition
            )
            pendingCleanPlan = plan
            pendingCleanPreflight = nil
            cleanupWorkflowState = .preflighting(planID: plan.id)
            let generation = UUID()
            cleanupPlanGeneration = generation
            let executor = cleanupExecutor
            let context = cleanupExecutionContext(
                session: session,
                activeRules: activeRules
            )
            let task = Task { @MainActor [weak self] in
                let report = await executor.preflight(plan: plan, context: context)
                guard let self else {
                    return
                }
                defer {
                    if self.cleanupPlanGeneration == generation {
                        self.cleanupPlanTask = nil
                    }
                }
                guard cleanupPlanGeneration == generation,
                      pendingCleanPlan?.id == plan.id,
                      scanPresentationSessionID == presentationSessionID else { return }
                pendingCleanPreflight = report
                if report.isConfirmable {
                    cleanupWorkflowState = .awaitingConfirmation(planID: plan.id)
                    transitionScanPresentation(
                        to: .confirming,
                        matching: presentationSessionID
                    )
                } else {
                    pendingCleanPlan = nil
                    cleanupPlanTask = nil
                    cleanupPlanGeneration = nil
                    cleanupWorkflowState = .results(sessionID: session.id)
                    transitionScanPresentation(
                        to: .results,
                        matching: presentationSessionID
                    )
                    errorMessage = L10n.text(
                        "执行前检查没有发现可安全处理的项目，请查看跳过原因或重新扫描。",
                        "Preflight found no items that are safe to process. Review skipped reasons or scan again."
                    )
                }
            }
            cleanupPlanTask = task
        } catch {
            cleanupWorkflowState = .results(sessionID: session.id)
            transitionScanPresentation(to: .results, matching: presentationSessionID)
            errorMessage = error.localizedDescription
        }
    }

    func cancelV2CleanupConfirmation() {
        guard cleanupExecutionTask == nil else { return }
        cleanupPlanTask?.cancel()
        cleanupPlanTask = nil
        cleanupPlanGeneration = nil
        pendingCleanPlan = nil
        pendingCleanPreflight = nil
        if let session = cleanupScanSession {
            cleanupWorkflowState = .results(sessionID: session.id)
        } else {
            cleanupWorkflowState = .idle
        }
        if let presentationSessionID = scanPresentationSessionID {
            transitionScanPresentation(to: .results, matching: presentationSessionID)
        }
    }

    func confirmV2Cleanup(
        reviewRiskAcknowledged: Bool = false,
        protectedRiskAcknowledged: Bool = false,
        protectedTrashMoveAcknowledged: Bool = false
    ) {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        guard cleanupFeatureConfiguration.mode == .v2Full,
              cleanupExecutionTask == nil,
              let plan = pendingCleanPlan,
              let preflight = pendingCleanPreflight,
              preflight.planID == plan.id,
              preflight.isConfirmable,
              let session = cleanupScanSession,
              session.id == plan.sessionID,
              let activeRules = cleanupActiveRuleSet,
              let presentationSessionID = scanPresentationSessionID else {
            return
        }
        guard plan.reviewItems.isEmpty || reviewRiskAcknowledged else {
            errorMessage = L10n.text(
                "请先确认已核对所选黄色项目及其风险。",
                "Confirm that you reviewed the selected yellow items and their risks."
            )
            return
        }
        guard plan.protectedItems.isEmpty
            || (protectedRiskAcknowledged && protectedTrashMoveAcknowledged) else {
            errorMessage = L10n.text(
                "请先完成红色高风险项目的两项确认。",
                "Complete both confirmations for the selected red high-risk items."
            )
            return
        }

        let executor = cleanupExecutor
        let activityStore = heavyWorkActivityStore
        let approvedPlanItemIDs = Set(preflight.items.compactMap { item in
            item.status == .ready ? item.planItemID : nil
        })
        let context = cleanupExecutionContext(
            session: session,
            activeRules: activeRules,
            approvedPlanItemIDs: approvedPlanItemIDs
        )
        let initialProgress = CleanupExecutionProgress(
            planID: plan.id,
            processedItemCount: 0,
            totalItemCount: plan.items.count,
            movedItemCount: 0,
            skippedItemCount: 0,
            failedItemCount: 0,
            currentRuleID: nil
        )
        cleanupExecutionProgress = initialProgress
        cleanupWorkflowState = .executing(planID: plan.id, progress: initialProgress)
        transitionScanPresentation(to: .cleaning, matching: presentationSessionID)
        cleanupPlanTask?.cancel()
        cleanupPlanTask = nil
        cleanupPlanGeneration = nil
        pendingCleanPreflight = nil
        let executionGeneration = UUID()
        cleanupExecutionGeneration = executionGeneration

        cleanupExecutionTask = Task { @MainActor [weak self] in
            let report = await executor.execute(
                plan: plan,
                context: context
            ) { [weak self] progress in
                await MainActor.run {
                    guard let self,
                          self.cleanupExecutionGeneration == executionGeneration,
                          self.scanPresentationSessionID == presentationSessionID,
                          self.pendingCleanPlan?.id == progress.planID else { return }
                    self.cleanupExecutionProgress = progress
                    if case .cancellingExecution = self.cleanupWorkflowState {
                        return
                    }
                    self.cleanupWorkflowState = .executing(
                        planID: progress.planID,
                        progress: progress
                    )
                }
            }
            await activityStore.refresh()
            guard let self,
                  self.cleanupExecutionGeneration == executionGeneration,
                  self.scanPresentationSessionID == presentationSessionID else { return }
            defer {
                self.cleanupExecutionProgress = nil
                self.cleanupExecutionTask = nil
                self.cleanupExecutionGeneration = nil
            }
            guard pendingCleanPlan?.id == plan.id else { return }
            if !CleanReportStore.record(report) {
                errorMessage = L10n.text("回执保存失败；本次已完成的移动仍保留在结果中。", "Receipt saving failed; completed moves remain in this result.")
            }
            lastCleanReport = report
            pendingCleanPlan = nil
            cleanupWorkflowState = .completed(reportID: report.id)
            cleanupSelection = CleanupSelection()
            let terminalPresentationState: SmartScanPresentationState
            switch report.outcome {
            case .completed, .partiallyCompleted:
                terminalPresentationState = .completed
            case .cancelled:
                terminalPresentationState = .cancelled
            case .failed:
                terminalPresentationState = .failed
            }
            if scanPresentationState == .cancelling,
               terminalPresentationState == .cancelled {
                transitionScanPresentation(to: .cancelled, matching: presentationSessionID)
                return
            }
            guard transitionScanPresentation(to: .verifying, matching: presentationSessionID) else {
                return
            }
            finishCleanupVerificationPresentation(
                with: terminalPresentationState,
                matching: presentationSessionID
            )
        }
    }

    func cancelV2CleanupExecution() {
        guard let task = cleanupExecutionTask,
              let planID = pendingCleanPlan?.id else { return }
        cleanupWorkflowState = .cancellingExecution(planID: planID)
        if let presentationSessionID = scanPresentationSessionID {
            transitionScanPresentation(to: .cancelling, matching: presentationSessionID)
        }
        task.cancel()
    }

    func refreshOperationReports() {
        Task {
            _ = try? await heavyWorkCoordinator.withLease(owner: .restore) { _ in
                try await Task.detached(priority: .utility) {
                    try CleanupReportJournal.live.reconcileInterruptedTrashMoves()
                    try CleanupReportJournal.live.reconcileInterruptedRecoveries()
                }.value
            }
            let loaded = await Task.detached(priority: .utility) {
                let reports = CleanReportStore.load()
                let journal = try? CleanupReportJournal.live.loadAvailable()
                return (reports, journal?.unreadableEntries.count)
            }.value
            operationReports = loaded.0
            if loaded.1 == nil || loaded.1! > 0 {
                operationReportWarning = L10n.text(
                    "部分回执无法读取；有效回执仍可查看，损坏记录已保留。",
                    "Some receipts cannot be read. Valid receipts remain available; damaged records were retained.")
            } else { operationReportWarning = nil }
        }
    }

    func restoreRecordedOperation(_ report: CleanReport) {
        guard !isRestoringRecordedOperation, !report.restorableReceipts.isEmpty else { return }
        isRestoringRecordedOperation = true
        let service = cleanupRecoveryService
        Task {
            defer { isRestoringRecordedOperation = false }
            do {
                let coordinator = heavyWorkCoordinator
                let result = try await coordinator.withLease(owner: .restore) { lease in
                    await service.restore(report: report, coordinator: coordinator, lease: lease)
                }
                operationRecoveryResult = result.recovery
                if result.recovery.persistenceFailure != nil {
                    operationReportWarning = L10n.text("恢复结果写入失败，请保留当前回执。", "Recovery result could not be saved. Keep this receipt.")
                } else { refreshOperationReports() }
            } catch { handleHeavyWorkError(error) }
        }
    }

    func dismissV2CleanupReport() {
        lastCleanReport = nil
        cleanupRecoveryReport = nil
        cleanupWorkflowState = .idle
        resetSmartScanPresentation()
    }

    func requestRestoreLatestV2Cleanup() {
        guard lastCleanReport?.restorableReceipts.isEmpty == false,
              cleanupExecutionTask == nil,
              !isRestoringV2Cleanup else { return }
        isV2RestoreConfirmationPresented = true
    }

    func openLatestV2CleanupLocation() {
        guard let report = lastCleanReport else { return }
        let url = report.disposition == .trash
            ? CleanupService.userTrashURL()
            : CleanupQuarantineLocation.defaultURL
        guard NSWorkspace.shared.open(url) else {
            errorMessage = L10n.text(
                "无法打开恢复位置，未改动任何文件",
                "Could not open the recovery location; no files changed"
            )
            return
        }
        showActionMessage(L10n.text(
            "已打开恢复位置，尚未永久删除任何文件",
            "Recovery location opened; nothing was permanently deleted"
        ))
    }

    func cancelRestoreLatestV2Cleanup() {
        isV2RestoreConfirmationPresented = false
    }

    func confirmRestoreLatestV2Cleanup() {
        guard let report = lastCleanReport,
              !report.restorableReceipts.isEmpty,
              !isRestoringV2Cleanup else { return }
        isV2RestoreConfirmationPresented = false
        isRestoringV2Cleanup = true
        let recoveryGeneration = UUID()
        cleanupRecoveryGeneration = recoveryGeneration
        let recoveryService = cleanupRecoveryService
        let coordinator = heavyWorkCoordinator
        let activityStore = heavyWorkActivityStore

        cleanupRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.cleanupRecoveryGeneration == recoveryGeneration {
                    self.cleanupRecoveryTask = nil
                    self.cleanupRecoveryGeneration = nil
                    self.isRestoringV2Cleanup = false
                }
            }
            do {
                let restored = try await coordinator.withLease(owner: .restore) { lease in
                    await recoveryService.restore(report: report, coordinator: coordinator, lease: lease)
                }
                let recovery = restored.recovery
                await activityStore.refresh()
                guard self.cleanupRecoveryGeneration == recoveryGeneration,
                      self.lastCleanReport?.id == report.id else { return }
                cleanupRecoveryReport = recovery
                if recovery.persistenceFailure == nil {
                    lastCleanReport = restored.report
                } else {
                    errorMessage = L10n.text(
                        "文件已恢复，但恢复结果写入失败，请保留当前结果。",
                        "Files were restored, but the recovery result could not be saved. Keep this result.")
                }
                showActionMessage(L10n.text(
                    "已恢复 \(recovery.restoredCount) 项；冲突或身份变化的项目保持原状。",
                    "Restored \(recovery.restoredCount) item(s); conflicts or identity changes were left untouched."
                ))
            } catch {
                await activityStore.refresh()
                guard self.cleanupRecoveryGeneration == recoveryGeneration else { return }
                handleHeavyWorkError(error)
            }
        }
    }

    private func cleanupExecutionContext(
        session: ScanSession,
        activeRules: CleanupRuleSet,
        approvedPlanItemIDs: Set<UUID>? = nil
    ) -> CleanupExecutionContext {
        CleanupExecutionContext(
            featureConfiguration: cleanupFeatureConfiguration,
            activeSessionID: session.id,
            activeRules: activeRules,
            userHomeURL: FileManager.default.homeDirectoryForCurrentUser,
            excludedURLs: currentV2ExcludedURLs(),
            approvedPlanItemIDs: approvedPlanItemIDs
        )
    }

    private func currentV2ExcludedURLs() -> [URL] {
        CleanupMigration.v2ExcludedURLs()
    }

    private func startCleanupV2Scan() {
        guard !isCleanupExecutionActive else {
            showActionMessage(L10n.text(
                "当前安全清理尚未结束，暂不能开始新的扫描。",
                "Safe cleanup is still in progress, so a new scan cannot start yet."
            ))
            return
        }
        guard selectedFilter != .green || !selectedSafeCleanupScopes.isEmpty else {
            showActionMessage(L10n.text(
                "请至少选择一个扫描项目。",
                "Select at least one scan item."
            ))
            return
        }
        let generation = UUID()
        beginScanPresentation(sessionID: generation)
        let activeRules: CleanupRuleSet
        do {
            activeRules = try cleanupRuleSetLoader()
            let migration = CleanupMigration.migrateIfNeeded(activeRules: activeRules)
            guard migration.didComplete else {
                throw CleanPlanBuildError.rulesChanged
            }
        } catch {
            cleanupActiveRuleSet = nil
            cleanupWorkflowState = .failed
            transitionScanPresentation(to: .failed, matching: generation)
            scanPresentationRoute = nil
            errorMessage = error.localizedDescription
            return
        }

        mainScanGeneration = generation
        mainScanProgress = .starting(mode: currentScanMode)
        mainScanLastProgressPublishedAt = nil
        isScanning = true
        isFinalizingMainScan = false
        isCancellingMainScan = false
        scheduleScanningPresentation(for: generation)
        errorMessage = nil
        actionMessage = nil
        cleanupScanSession = nil
        cleanupSelection = CleanupSelection()
        cleanupDryRunSummary = nil
        cleanupActiveRuleSet = activeRules
        cleanupPlanTask?.cancel()
        cleanupPlanTask = nil
        cleanupPlanGeneration = nil
        pendingCleanPlan = nil
        pendingCleanPreflight = nil
        lastCleanReport = nil
        cleanupRecoveryReport = nil
        cleanupWorkflowState = .idle

        let coordinator = heavyWorkCoordinator
        let activityStore = heavyWorkActivityStore
        let operation = cleanupScanOperation
        let selectedRules = selectedFilter == .green
            ? activeRules.rules.filter { rule in
                selectedSafeCleanupScopes.contains { $0.includes(rule) }
            }
            : []
        let request = CleanupScanRequest(
            excludedURLs: currentV2ExcludedURLs(),
            developerInactivityThresholdDays: developerInactivityThresholdDays,
            includedCategoryIDs: selectedFilter == .devCaches
                ? ["developer"]
                : selectedFilter == .green
                    ? Set(selectedRules.map(\.categoryID))
                    : nil,
            includedRuleIDs: selectedFilter == .green
                ? Set(selectedRules.map(\.id))
                : nil
        )

        mainScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if mainScanGeneration == generation {
                    mainScanGeneration = nil
                    mainScanTask = nil
                    isScanning = false
                    isFinalizingMainScan = false
                    isCancellingMainScan = false
                }
            }
            do {
                let session = try await coordinator.withLease(owner: .mainScan) { _ in
                    await activityStore.refresh()
                    return try await operation(request) { [weak self] progress in
                        await MainActor.run {
                            guard let self,
                                  self.mainScanGeneration == generation else { return }
                            let diskProgress = DiskScanProgress(
                                cleanupProgress: progress
                            )
                            self.publishMainScanProgress(
                                diskProgress,
                                force: progress.phase != .enumerating
                            )
                        }
                    }
                }
                await activityStore.refresh()
                guard mainScanGeneration == generation else { return }

                if session.outcome != .cancelled {
                    isFinalizingMainScan = true
                }

                cleanupScanSession = session
                cleanupSelection = .defaults(in: session)
                cleanupWorkflowState = .results(sessionID: session.id)
                finishScanPresentation(
                    with: session.outcome == .cancelled ? .cancelled : .results,
                    matching: generation
                )
                if session.outcome == .cancelled {
                    showActionMessage(L10n.text(
                        "扫描已取消；保留已完成的只读结果，未改动任何文件",
                        "Scan cancelled; completed read-only results were kept and no files changed"
                    ))
                }
            } catch {
                guard mainScanGeneration == generation else {
                    await activityStore.refresh()
                    return
                }
                if error is CancellationError {
                    finishScanPresentation(
                        with: .cancelled,
                        matching: generation
                    )
                    showActionMessage(L10n.text(
                        "扫描已取消，未改动任何文件",
                        "Scan cancelled; no files changed"
                    ))
                } else {
                    cleanupWorkflowState = .failed
                    finishScanPresentation(
                        with: .failed,
                        matching: generation
                    )
                    errorMessage = error.localizedDescription
                }
                await activityStore.refresh()
            }
        }
    }

    func refreshScanReadiness(
        markInitialPermissionCheckCompleted: Bool = false,
        showInitialFolderAccessPromptWhenNeeded: Bool = false,
        showCompletionMessage: Bool = false
    ) {
        performScanReadinessCheck { [weak self] summary in
            guard let self else { return }
            scanReadinessSummary = summary
            scanReadinessCheckedAt = Date()
            if markInitialPermissionCheckCompleted {
                completeInitialPermissionCheck()
            }
            if showInitialFolderAccessPromptWhenNeeded,
               shouldShowInitialFolderAccessPrompt(after: summary) {
                isShowingInitialFolderAccessPrompt = true
            }
            if showCompletionMessage {
                showPermissionCheckCompletion(summary)
            }
        } onTimeout: { [weak self] in
            guard let self, showCompletionMessage else { return }
            showActionMessage(L10n.text(
                "权限检查响应超时，操作已恢复，可稍后重试。",
                "The access check timed out. Controls are available again; please retry later."
            ))
        }
    }

    private func restoreFolderAccessForLaunch() {
        guard !isCheckingScanReadiness else { return }
        let requestID = UUID()
        activeFolderAccessRestoreID = requestID
        isCheckingScanReadiness = true

        let operation = restoreSavedAccessOperation
        let restoreTask = Task.detached(priority: .utility) {
            operation()
        }

        Task { [weak self] in
            await restoreTask.value
            guard let self, activeFolderAccessRestoreID == requestID else { return }
            activeFolderAccessRestoreID = nil
            isCheckingScanReadiness = false
        }

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: folderAccessRestoreTimeout)
            guard activeFolderAccessRestoreID == requestID else { return }
            activeFolderAccessRestoreID = nil
            isCheckingScanReadiness = false
        }
    }

    private func performScanReadinessCheck(
        onSuccess: @escaping @MainActor (ScanReadinessSummary) -> Void,
        onTimeout: @escaping @MainActor () -> Void = {}
    ) {
        guard !isCheckingScanReadiness else { return }
        let requestID = UUID()
        activeScanReadinessCheckID = requestID
        scanReadinessSuccessHandler = onSuccess
        isCheckingScanReadiness = true

        if scanReadinessPhysicalTask == nil || scanReadinessPhysicalTaskID == nil {
            let operation = loadScanReadinessSummary
            let physicalTaskID = UUID()
            let readinessTask = Task.detached(priority: .userInitiated) {
                operation()
            }
            scanReadinessPhysicalTaskID = physicalTaskID
            scanReadinessPhysicalTask = readinessTask

            // Exactly one completion watcher belongs to each physical task.
            // UI timeout retries only replace the current handler below and
            // never add an unbounded queue of continuations to a stuck call.
            Task { [weak self] in
                let summary = await readinessTask.value
                guard let self, scanReadinessPhysicalTaskID == physicalTaskID else { return }
                scanReadinessPhysicalTaskID = nil
                scanReadinessPhysicalTask = nil
                let successHandler = scanReadinessSuccessHandler
                scanReadinessSuccessHandler = nil
                guard activeScanReadinessCheckID != nil else { return }
                activeScanReadinessCheckID = nil
                isCheckingScanReadiness = false
                successHandler?(summary)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: scanReadinessTimeout)
            guard activeScanReadinessCheckID == requestID else { return }
            activeScanReadinessCheckID = nil
            scanReadinessSuccessHandler = nil
            isCheckingScanReadiness = false
            onTimeout()
        }
    }

    func checkCurrentPermissionsFromMenu() {
        refreshScanReadiness(showCompletionMessage: true)
    }

    func items(for filter: ReviewFilter) -> [StorageItem] {
        if filter == .duplicates,
           duplicateFilesWorkspace.hasScanned || duplicateFilesWorkspace.isScanning || !duplicateFilesWorkspace.items.isEmpty {
            return duplicateFilesWorkspace.items
        }
        if filter == .green {
            return result?.cleanupReviewItems ?? []
        }
        return result?.items(for: filter) ?? []
    }

    func selectedItem(for filter: ReviewFilter) -> StorageItem? {
        let filtered = items(for: filter)
        if let selectedItemID, let selected = filtered.first(where: { $0.id == selectedItemID }) {
            return selected
        }
        return filtered.first
    }

    func requestTrash(_ item: StorageItem) {
        guard canRequestTrash(item) else { return }
        pendingTrashItem = item
    }

    func requestTrashAllGreen() {
        guard canRequestGreenTrash else { return }
        pendingBulkTrashItems = greenTrashCandidates
    }

    func removePendingBulkTrashItem(_ item: StorageItem) {
        pendingBulkTrashItems.removeAll { $0.id == item.id }
    }

    func cancelTrashAllGreenPreview() {
        pendingBulkTrashItems = []
    }

    func requestEmptyTrash() {
        guard canRequestEmptyTrash else { return }
        actionMessage = nil
        pendingEmptyTrashSummary = nil
        isCheckingTrashSummary = true

        Task {
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try CleanupService.trashSummary()
                }.value

                if summary.isEmpty {
                    removeTrashItemsFromCurrentResult()
                    showActionMessage(L10n.text("废纸篓已经是空的", "Trash is already empty"))
                } else {
                    pendingEmptyTrashSummary = summary
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            isCheckingTrashSummary = false
        }
    }

    func cancelEmptyTrash() {
        pendingEmptyTrashSummary = nil
    }

    func refreshScanHistory() {
        scanHistorySummary = ScanHistoryService.summary()
    }

    func clearScanHistory() {
        guard canClearScanHistory else { return }
        ScanHistoryService.clear()
        refreshScanHistory()
        showActionMessage(L10n.text("已清空体检历史，仅移除本机记录，不会删除任何文件", "Scan history cleared; only local records were removed, no files were deleted"))
    }

    func confirmTrash() {
        guard let item = pendingTrashItem,
              canRequestTrash(item),
              let current = result else { return }
        pendingTrashItem = nil
        isMovingItemsToTrash = true
        let startedAt = Date()
        cleanupOperationSnapshot = CleanupOperationSnapshot(
            requestedCount: 1,
            requestedBytes: item.sizeBytes,
            movedCount: 0,
            movedBytes: 0,
            failedCount: 0,
            duration: nil
        )
        let generation = UUID()
        cleanupGeneration = generation
        let allowedPaths = current.allowedTrashPaths
        let coordinator = heavyWorkCoordinator
        let service = scanHeavyWorkService
        let activityStore = heavyWorkActivityStore

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let moveRecords = try await coordinator.withLease(owner: .cleanup) { lease in
                    await activityStore.refresh()
                    return try await service.moveToTrash(
                        item: item,
                        allowedPaths: allowedPaths,
                        lease: lease
                    )
                }
                await activityStore.refresh()
                guard cleanupGeneration == generation else { return }

                if var latest = result {
                    latest.markMovedToTrash(itemID: item.id)
                    result = latest
                }
                CleanupHistoryService.recordMovedItems([item], moveRecords: moveRecords)
                refreshCleanupHistory()
                cleanupOperationSnapshot = CleanupOperationSnapshot(
                    requestedCount: 1,
                    requestedBytes: item.sizeBytes,
                    movedCount: 1,
                    movedBytes: item.sizeBytes,
                    failedCount: 0,
                    duration: Date().timeIntervalSince(startedAt)
                )
                showActionMessage(L10n.text(
                    "\(item.title) 已移到废纸篓，清空前可恢复",
                    "\(item.title) moved to Trash and remains recoverable until Trash is emptied"
                ))
            } catch let partial as PartialTrashOperationError {
                lastCleanReport = partial.report
                _ = CleanReportStore.record(partial.report)
                refreshOperationReports()
                cleanupOperationSnapshot = nil
                errorMessage = partial.localizedDescription
                await activityStore.refresh()
            } catch {
                guard cleanupGeneration == generation else {
                    await activityStore.refresh()
                    return
                }
                cleanupOperationSnapshot = nil
                handleHeavyWorkError(error)
                await activityStore.refresh()
            }

            guard cleanupGeneration == generation else { return }
            cleanupGeneration = nil
            isMovingItemsToTrash = false
        }
    }

    func confirmTrashAllGreen(selectedItemIDs: Set<String>? = nil) {
        guard !pendingBulkTrashItems.isEmpty,
              canRequestGreenTrash,
              let current = result else { return }

        let previewIDs = Set(pendingBulkTrashItems.map(\.id))
        let requestedIDs = (selectedItemIDs ?? previewIDs).intersection(previewIDs)
        guard !requestedIDs.isEmpty else {
            showActionMessage(L10n.text("请至少选择一个清理项目", "Select at least one cleanup item"))
            return
        }

        let candidates = current.items.filter { item in
            requestedIDs.contains(item.id) && item.canMoveToTrash
        }

        guard !candidates.isEmpty else {
            showActionMessage(L10n.text("没有可清理项目", "No cleanable items"))
            return
        }

        pendingBulkTrashItems = []
        isMovingItemsToTrash = true
        let requestedBytes = candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let startedAt = Date()
        cleanupOperationSnapshot = CleanupOperationSnapshot(
            requestedCount: candidates.count,
            requestedBytes: requestedBytes,
            movedCount: 0,
            movedBytes: 0,
            failedCount: 0,
            duration: nil
        )
        let generation = UUID()
        cleanupGeneration = generation
        let allowedPaths = current.allowedTrashPaths
        let coordinator = heavyWorkCoordinator
        let service = scanHeavyWorkService
        let activityStore = heavyWorkActivityStore

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await coordinator.withLease(owner: .cleanup) { lease in
                    await activityStore.refresh()
                    return try await service.moveToTrash(
                        items: candidates,
                        allowedPaths: allowedPaths,
                        lease: lease
                    )
                }
                await activityStore.refresh()
                guard cleanupGeneration == generation else { return }

                if var latest = result {
                    latest.markMovedToTrash(itemIDs: outcome.movedItemIDs)
                    result = latest
                }
                CleanupHistoryService.recordMovedItems(
                    outcome.movedItems,
                    moveRecords: outcome.moveRecords
                )
                refreshCleanupHistory()

                if let report = outcome.reports.last { lastCleanReport = report }
                refreshOperationReports()
                let movedCount = outcome.movedItems.count
                cleanupOperationSnapshot = CleanupOperationSnapshot(
                    requestedCount: candidates.count,
                    requestedBytes: requestedBytes,
                    movedCount: movedCount,
                    movedBytes: outcome.movedItems.reduce(Int64(0)) { $0 + $1.sizeBytes },
                    failedCount: outcome.failedTitles.count,
                    duration: Date().timeIntervalSince(startedAt)
                )
                if outcome.cancelled {
                    errorMessage = L10n.text(
                        "清理已停止。已移动的路径保留恢复回执，另有 \(outcome.notProcessedPaths.count) 条路径未执行。",
                        "Cleanup stopped. Moved paths retain recovery receipts; \(outcome.notProcessedPaths.count) paths were not executed.")
                } else if outcome.failedTitles.isEmpty {
                    showActionMessage(L10n.text(
                        "\(movedCount) 个可安全清理项目已移到废纸篓，清空后才释放空间",
                        "\(L10n.items(movedCount)) marked safe to clean moved to Trash; space is freed after Trash is emptied"
                    ))
                } else {
                    let titleList = outcome.failedTitles.prefix(3).joined(
                        separator: L10n.text("、", ", ")
                    )
                    errorMessage = L10n.text(
                        "\(movedCount) 项已移到废纸篓，\(outcome.failedTitles.count) 项失败：\(titleList)。清空后才释放空间",
                        "\(L10n.items(movedCount)) moved to Trash; \(L10n.items(outcome.failedTitles.count)) failed: \(titleList). Space is freed after Trash is emptied"
                    )
                }
            } catch {
                guard cleanupGeneration == generation else {
                    await activityStore.refresh()
                    return
                }
                cleanupOperationSnapshot = nil
                handleHeavyWorkError(error)
                await activityStore.refresh()
            }

            guard cleanupGeneration == generation else { return }
            cleanupGeneration = nil
            isMovingItemsToTrash = false
        }
    }

    func dismissCleanupOperationSummary() {
        guard cleanupOperationSnapshot?.isComplete == true else { return }
        cleanupOperationSnapshot = nil
    }

    func confirmEmptyTrash() {
        guard pendingEmptyTrashSummary != nil, canRequestEmptyTrash else { return }
        pendingEmptyTrashSummary = nil
        isEmptyingTrash = true
        errorMessage = nil
        let generation = UUID()
        emptyTrashGeneration = generation
        let coordinator = heavyWorkCoordinator
        let service = scanHeavyWorkService
        let activityStore = heavyWorkActivityStore

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await coordinator.withLease(owner: .emptyTrash) { lease in
                    await activityStore.refresh()
                    return try await service.emptyTrash(lease: lease)
                }
                await activityStore.refresh()
                guard emptyTrashGeneration == generation else { return }

                removeTrashItemsFromCurrentResult()

                if summary.isEmpty {
                    showActionMessage(L10n.text("废纸篓已经是空的", "Trash is already empty"))
                } else {
                    showActionMessage(
                        L10n.text(
                            "已清空废纸篓：\(summary.itemCount) 项 · \(ByteFormat.string(summary.totalBytes))",
                            "Emptied Trash: \(L10n.items(summary.itemCount)) · \(ByteFormat.string(summary.totalBytes))"
                        )
                    )
                }
            } catch {
                guard emptyTrashGeneration == generation else {
                    await activityStore.refresh()
                    return
                }
                handleHeavyWorkError(error)
                await activityStore.refresh()
            }

            guard emptyTrashGeneration == generation else { return }
            emptyTrashGeneration = nil
            isEmptyingTrash = false
        }
    }

    func reveal(_ path: String) {
        do {
            try CleanupService.reveal(path)
            showActionMessage(L10n.text("已在访达中显示，仅打开位置，不会移动或删除文件", "Shown in Finder; this only opens the location and does not move or delete files"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openStorageSettings() {
        guard CleanupService.openStorageSettings() else {
            errorMessage = L10n.text("无法打开系统存储设置", "Could not open System Storage settings")
            return
        }
        showActionMessage(L10n.text("已打开系统存储设置，仅用于查看系统建议，不会执行清理", "System Storage settings opened for review only; no cleanup was run"))
    }

    func openLoginItemsSettings() {
        guard CleanupService.openLoginItemsSettings() else {
            errorMessage = L10n.text("无法打开登录项设置", "Could not open Login Items settings")
            return
        }
        showActionMessage(L10n.text("已打开登录项设置；仍需在系统设置里手动确认更改", "Login Items settings opened; changes still need manual confirmation in System Settings"))
    }

    func refreshStartupItems(
        priority: TaskPriority = .userInitiated,
        includeBackgroundTaskDiagnostic: Bool = false
    ) {
        guard canRefreshStartupItems else { return }
        startupOperationPreviewTask?.cancel()
        startupOperationPreviewTask = nil
        startupOperationPreviewGeneration = nil
        pendingStartupOperationPlan = nil
        pendingStartupOperationCandidate = nil
        selectedStartupCandidate = nil
        lastStartupUndoRecordID = nil
        lastStartupUndoCandidate = nil
        isLoadingStartupItems = true
        startupScanProgress = StartupItemsScanProgress(
            title: L10n.text("正在扫描登录项", "Scanning login items"),
            discoveredCount: 0
        )
        errorMessage = nil
        let generation = UUID()
        startupScanGeneration = generation
        let coordinator = startupScanCoordinator
        let manager = startupItemManager
        let scanContext = includeBackgroundTaskDiagnostic
            ? StartupScanContext(
                includeBackgroundTaskDiagnostic: true,
                commandTimeout: Self.startupBackgroundTaskDiagnosticTimeout
            )
            : StartupScanContext()

        let operation = Task(priority: priority) { [weak self] in
            guard let self else { return }
            do {
                let result = try await coordinator.scan(context: scanContext) { progress in
                    await MainActor.run { [weak self] in
                        guard let self, self.startupScanGeneration == generation else { return }
                        self.startupScanProgress = StartupItemsScanProgress(
                            title: progress.message,
                            discoveredCount: progress.discoveredCount
                        )
                    }
                }
                guard startupScanGeneration == generation else { return }
                let recovery = try? await manager.latestRecoverableUndo(candidates: result.candidates)
                try Task.checkCancellation()
                guard startupScanGeneration == generation else { return }
                startupDomainItems = result.items
                startupCoverage = result.coverage
                lastStartupUndoRecordID = recovery?.recordID
                lastStartupUndoCandidate = recovery?.candidate
                hasScannedStartupItems = true
            } catch is CancellationError {
                guard startupScanGeneration == generation else { return }
                showActionMessage(L10n.text("已取消启动项扫描", "Startup item scan cancelled"))
            } catch {
                guard startupScanGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }

            guard startupScanGeneration == generation else { return }
            startupScanGeneration = nil
            startupScanOperation = nil
            startupScanProgress = nil
            isLoadingStartupItems = false
        }
        startupScanOperation = operation
    }

    func cancelStartupScan() {
        guard isLoadingStartupItems else { return }
        startupScanOperation?.cancel()
    }

    func requestStartupItemCancellation() {
        startupScanOperation?.cancel()
        startupOperationPreviewTask?.cancel()
        startupManagementOperation?.cancel()
    }

    func prepareStartupItemsForTermination() async {
        let scanOperation = startupScanOperation
        let previewOperation = startupOperationPreviewTask
        let managementOperation = startupManagementOperation
        scanOperation?.cancel()
        previewOperation?.cancel()
        managementOperation?.cancel()
        await scanOperation?.value
        await previewOperation?.value
        await managementOperation?.value
    }

    func selectStartupCandidate(_ candidate: StartupItemsDomain.Candidate?) {
        selectedStartupCandidate = candidate
    }

    func requestStartupOperation(
        _ operation: StartupItemsDomain.StartupOperationKind,
        candidate: StartupItemsDomain.Candidate
    ) {
        guard canRequestStartupOperation(candidate, operation: operation) else { return }
        errorMessage = nil
        let manager = startupItemManager
        startupOperationPreviewTask?.cancel()
        let generation = UUID()
        startupOperationPreviewGeneration = generation

        let previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if startupOperationPreviewGeneration == generation {
                    startupOperationPreviewGeneration = nil
                    startupOperationPreviewTask = nil
                }
            }
            do {
                let plan = try await manager.preview(candidate: candidate, operation: operation)
                guard !Task.isCancelled,
                      startupOperationPreviewGeneration == generation else { return }
                pendingStartupOperationCandidate = candidate
                pendingStartupOperationPlan = plan
            } catch is CancellationError {
                return
            } catch {
                guard startupOperationPreviewGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
        startupOperationPreviewTask = previewTask
    }

    func cancelPendingStartupOperation() {
        guard !isPerformingStartupOperation else { return }
        startupOperationPreviewTask?.cancel()
        startupOperationPreviewTask = nil
        startupOperationPreviewGeneration = nil
        pendingStartupOperationPlan = nil
        pendingStartupOperationCandidate = nil
    }

    func confirmStartupOperation() {
        guard let plan = pendingStartupOperationPlan,
              let candidate = pendingStartupOperationCandidate,
              canRequestStartupOperation(candidate, operation: plan.kind) else { return }
        isPerformingStartupOperation = true
        errorMessage = nil
        let manager = startupItemManager

        let operation = Task { [weak self] in
            guard let self else { return }
            var shouldRefresh = false
            defer {
                pendingStartupOperationPlan = nil
                pendingStartupOperationCandidate = nil
                isPerformingStartupOperation = false
                startupManagementOperation = nil
                if shouldRefresh {
                    refreshStartupItems(priority: .utility)
                }
            }
            do {
                if plan.requiresAdministrator {
                    // The helper repeats path, digest and signing checks at the
                    // root boundary. Administrative operations deliberately do
                    // not reuse the current-user undo-record execution path.
                    shouldRefresh = true
                    try await FanControlCoordinator.shared.manageStartupItem(plan)
                    lastStartupUndoRecordID = nil
                    lastStartupUndoCandidate = nil
                } else {
                    let result = try await manager.perform(plan, candidate: candidate)
                    _ = await manager.consumeRecoveryRecordID(for: plan.id)
                    lastStartupUndoRecordID = result.undoRecordID
                    lastStartupUndoCandidate = result.undoRecordID == nil ? nil : candidate
                }
                shouldRefresh = true
                showActionMessage(startupOperationSuccessMessage(plan.kind, candidate: candidate))
            } catch is CancellationError {
                let recoveryRecordID = await manager.consumeRecoveryRecordID(for: plan.id)
                lastStartupUndoRecordID = recoveryRecordID
                lastStartupUndoCandidate = recoveryRecordID == nil ? nil : candidate
                shouldRefresh = shouldRefresh || recoveryRecordID != nil
                showActionMessage(L10n.text("已取消启动项操作；如果 launchctl 已部分执行，仍保留撤销记录", "Startup operation cancelled; an undo record remains if launchctl partially ran"))
            } catch {
                let recoveryRecordID = await manager.consumeRecoveryRecordID(for: plan.id)
                lastStartupUndoRecordID = recoveryRecordID
                lastStartupUndoCandidate = recoveryRecordID == nil ? nil : candidate
                shouldRefresh = shouldRefresh || recoveryRecordID != nil
                errorMessage = error.localizedDescription
            }
        }
        startupManagementOperation = operation
    }

    func cancelStartupOperation() {
        guard isPerformingStartupOperation else { return }
        startupManagementOperation?.cancel()
    }

    func undoLastStartupOperation() {
        guard let recordID = lastStartupUndoRecordID,
              let candidate = lastStartupUndoCandidate,
              !isPerformingStartupOperation,
              !isLoadingStartupItems else { return }
        isPerformingStartupOperation = true
        let manager = startupItemManager

        let operation = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await manager.restore(undoRecordID: recordID, candidate: candidate)
                lastStartupUndoRecordID = nil
                lastStartupUndoCandidate = nil
                isPerformingStartupOperation = false
                showActionMessage(L10n.text("已撤销上一次启动项操作，并重新验证 launchd 状态", "Last startup-item operation was undone and launchd state was revalidated"))
                refreshStartupItems(priority: .utility)
            } catch is CancellationError {
                isPerformingStartupOperation = false
                showActionMessage(L10n.text("已取消撤销", "Undo cancelled"))
            } catch {
                isPerformingStartupOperation = false
                errorMessage = error.localizedDescription
            }
            startupManagementOperation = nil
        }
        startupManagementOperation = operation
    }

    func revealStartupCandidate(_ candidate: StartupItemsDomain.Candidate) {
        guard let url = candidate.plistURL ?? candidate.executableURL ?? candidate.applicationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        showActionMessage(L10n.text("已在 Finder 中显示，未修改启动项", "Shown in Finder; no startup item was changed"))
    }

    func openParentApplication(for candidate: StartupItemsDomain.Candidate) {
        guard let url = candidate.attribution?.applicationURL ?? candidate.applicationURL else { return }
        guard NSWorkspace.shared.open(url) else {
            errorMessage = L10n.text("无法打开所属应用", "Could not open the parent application")
            return
        }
        showActionMessage(L10n.text("已打开所属应用，未更改启动项", "Parent application opened; no startup item was changed"))
    }

    private func startupOperationSuccessMessage(
        _ operation: StartupItemsDomain.StartupOperationKind,
        candidate: StartupItemsDomain.Candidate
    ) -> String {
        switch operation {
        case .disable:
            L10n.text(
                "已停用 \(candidate.name)；仅阻止自动载入，不会卸载所属应用",
                "\(candidate.name) was disabled; this prevents automatic loading and does not uninstall its application"
            )
        case .enable:
            L10n.text("已启用 \(candidate.name)，并验证 launchd 状态", "\(candidate.name) was enabled and launchd state was verified")
        case .stopCurrentSession:
            L10n.text("已停止 \(candidate.name) 的本次运行；不会永久停用", "\(candidate.name) was stopped for this session and was not permanently disabled")
        }
    }

    func refreshMemory(priority: TaskPriority = .userInitiated) {
        guard canRefreshMemory else { return }
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            memorySnapshot = menuBarDisplayMemorySnapshot
            return
        }
#endif
        _ = priority
        memoryCoordinator.cancel()
        memoryOptimizationState = memoryCoordinator.state
        pendingMemoryProcess = nil
        clearPendingMemoryQuitConfirmation()
        selectedMemoryProcessIDs.removeAll()
        isLoadingMemory = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await memoryCoordinator.observe()
            adoptMenuBarMemorySnapshot(snapshot, as: .primaryAndMenuFromRefresh)
            memoryOptimizationState = memoryCoordinator.state
            isLoadingMemory = false
            refreshMenuBarMonitor()
        }
    }

    /// Refresh the visible process list without invoking the explicit refresh
    /// action, which resets the user's quit selection and confirmation state.
    func refreshMenuBarMemoryProcesses(now: Date = Date()) {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        guard menuBarMemoryProcessTask == nil, canAdoptLiveMemoryProcesses,
              memorySnapshot.map({ now.timeIntervalSince($0.generatedAt) >= MenuBarPerformancePolicy.visibleProcessInterval }) ?? true else { return }
        let generation = menuBarMemoryProcessGeneration
        let provider = menuBarMemoryProcessProvider
        menuBarMemoryProcessTask = Task { @MainActor [weak self] in
            let snapshot = await provider()
            let apps = await Task.detached(priority: .utility) { snapshot.appsByResidentUsage }.value
            guard let self else { return }
            menuBarMemoryProcessTask = nil
            guard !Task.isCancelled, generation == menuBarMemoryProcessGeneration else { return }
            guard canAdoptLiveMemoryProcesses,
                  memorySnapshot.map({ snapshot.generatedAt >= $0.generatedAt }) ?? true else { return }
            menuBarPreparedMemoryAppsVersion &+= 1
            menuBarPreparedMemoryAppsDate = snapshot.generatedAt
            menuBarPreparedMemoryApps = apps
            adoptMenuBarMemorySnapshot(snapshot, as: .primaryAndMenuFromRefresh)
        }
    }

    /// A single visible-page driver. UI callbacks only declare demand; all
    /// enumeration and measurement preparation occurs after the current turn.
    private var menuBarProcessConsumers: [UUID: (PanelSection, UInt64)] = [:]
    private var menuBarProcessConsumerOrder: UInt64 = 0
    func updateMenuBarProcessConsumer(_ id: UUID, section: PanelSection?) {
        menuBarProcessConsumerOrder &+= 1
        menuBarProcessConsumers[id] = section.map { ($0, menuBarProcessConsumerOrder) }
        let selected = menuBarProcessConsumers.values.filter {
            [.processor, .disk, .power, .memory].contains($0.0)
        }.max { $0.1 < $1.1 }?.0 ?? .overview
        setMenuBarProcessDemand(selected)
    }

    func setMenuBarProcessDemand(_ section: PanelSection) {
        let resolved: PanelSection = isMenuBarRefreshPaused ? .overview : section
        guard resolved != menuBarProcessDemand || (menuBarVisibleProcessTask == nil && resolved != .overview) else { return }
        menuBarVisibleProcessGeneration &+= 1
        menuBarVisibleProcessTask?.cancel()
        menuBarVisibleProcessTask = nil
        cancelMenuBarMemoryProcessRefresh()
        if menuBarProcessDemand == .power, resolved != .power {
            systemEnergyAccumulator.endAttributedObservation()
        }
        menuBarProcessDemand = resolved
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        guard [.processor, .disk, .power, .memory].contains(resolved) else { return }
        let generation = menuBarVisibleProcessGeneration
        let sampler = menuBarContinuousProcessSampler
        menuBarVisibleProcessTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await sampler.reset()
            while !Task.isCancelled {
                let started = ContinuousClock.now
                guard let self, !isMenuBarRefreshPaused,
                      menuBarVisibleProcessGeneration == generation else { return }
                if resolved == .memory {
                    refreshMenuBarMemoryProcesses()
                } else {
                    let worker = Task.detached(priority: .utility) {
                        guard let snapshot = await sampler.sample(), !Task.isCancelled else { return Optional<MenuBarPreparedProcesses>.none }
                        return MenuBarPreparedProcesses(snapshot: snapshot)
                    }
                    let prepared = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, !isMenuBarRefreshPaused,
                          menuBarVisibleProcessGeneration == generation else { return }
                    if let prepared {
                        menuBarPreparedProcesses = prepared
                        if resolved == .power {
                            systemEnergyAccumulator.recordAttributed(prepared.snapshot,
                                powerSource: menuBarAuxiliaryMonitorState.batterySnapshot?.powerSource ?? .unknown,
                                continuous: true)
                        }
                    }
                }
                let elapsed = started.duration(to: .now)
                let remaining = Duration.seconds(max(MenuBarPerformancePolicy.visibleProcessInterval, menuBarRefreshInterval.seconds)) - elapsed
                do { try await Task.sleep(for: max(.milliseconds(1), remaining)) }
                catch { return }
            }
        }
    }

    private var canAdoptLiveMemoryProcesses: Bool {
        !isMenuBarRefreshPaused && canRefreshMemory
            && selectedMemoryProcessIDs.isEmpty && pendingMemoryProcess == nil
            && !isMemoryBatchQuitConfirmationPresentedInMenuBar
            && menuBarAuxiliaryMonitorState.activeConsumerCount > 0
    }

    func cancelMenuBarMemoryProcessRefresh() {
        menuBarMemoryProcessGeneration &+= 1
        menuBarMemoryProcessTask?.cancel()
    }

    func optimizeMemory() {
        guard canOptimizeMemory else { return }
        isOptimizingMemory = true
        errorMessage = nil
        let generation = UUID()
        memoryOptimizationGeneration = generation
        let coordinator = heavyWorkCoordinator
        let service = scanHeavyWorkService
        let activityStore = heavyWorkActivityStore

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await coordinator.withLease(owner: .memoryOptimization) { lease in
                    await activityStore.refresh()
                    return try await service.optimizeMemory(lease: lease)
                }
                await activityStore.refresh()
                guard memoryOptimizationGeneration == generation else { return }

                adoptMenuBarMemorySnapshot(result.snapshot, as: .primaryAndMenuFromRefresh)
                memoryOptimizationResult = result
                showActionMessage(memoryOptimizationMessage(for: result.status))
            } catch {
                guard memoryOptimizationGeneration == generation else {
                    await activityStore.refresh()
                    return
                }
                handleHeavyWorkError(error)
                await activityStore.refresh()
            }

            guard memoryOptimizationGeneration == generation else { return }
            memoryOptimizationGeneration = nil
            isOptimizingMemory = false
            refreshMenuBarMonitor()
        }
    }

    func performRecommendedMemoryAction(presentConfirmationInMenuBar: Bool = false) {
        guard canRefreshMemory else { return }
        guard let memorySnapshot else {
            refreshMemory()
            return
        }

        switch memorySnapshot.cleanupPlan.primaryAction {
        case .observe:
            showActionMessage(memorySnapshot.cleanupPlan.title)
        case .quitHighUsageApps:
            if !presentConfirmationInMenuBar, isRecommendedMemorySelectionPrepared {
                requestQuitSelectedMemoryProcesses()
                confirmQuitSelectedMemoryProcesses()
                return
            }
            guard selectRecommendedMemoryApps() else {
                showActionMessage(L10n.text("当前没有适合自动建议退出的后台应用", "No background app is currently suitable for a quit recommendation"))
                return
            }
            guard presentConfirmationInMenuBar else { return }
            requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: presentConfirmationInMenuBar)
        }
    }

    func scanEnergyImpact() {
        startEnergyImpactRefresh(priority: .userInitiated, presentsInEnergyPage: true)
    }

    func refreshEnergyImpact(priority: TaskPriority = .userInitiated) {
        startEnergyImpactRefresh(priority: priority, presentsInEnergyPage: false)
    }

    private func startEnergyImpactRefresh(
        priority: TaskPriority,
        presentsInEnergyPage: Bool
    ) {
        guard canRefreshEnergyImpact else { return }
        isLoadingEnergyImpact = true
        isEnergyImpactPageScanActive = presentsInEnergyPage
        energyImpactScanPhase = .readingProcesses
        let shouldPublishProcessPreview = energyImpactSnapshot == nil
        let samplingPriority: TaskPriority = energyImpactSnapshot == nil ? .userInitiated : priority
        let publishProgress: @MainActor @Sendable (EnergyImpactScanPhase) -> Void = { [weak self] phase in
            guard let self, isLoadingEnergyImpact else { return }
            energyImpactScanPhase = phase
        }
        let publishProcessSnapshot: @MainActor @Sendable (EnergyImpactSnapshot) -> Void = { [weak self] snapshot in
            guard let self,
                  shouldPublishProcessPreview,
                  isLoadingEnergyImpact,
                  (energyImpactSnapshot?.generatedAt ?? .distantPast) < snapshot.generatedAt else { return }
            energyImpactSnapshot = snapshot
        }

        Task {
            let snapshot = await Task.detached(priority: samplingPriority) {
                await EnergyImpactService.snapshot(
                    onProgress: publishProgress,
                    onProcessSnapshot: publishProcessSnapshot
                )
            }.value
            energyImpactSnapshot = snapshot
            systemEnergyAccumulator.recordAttributed(snapshot,
                powerSource: menuBarAuxiliaryMonitorState.batterySnapshot?.powerSource ?? .unknown)
            if presentsInEnergyPage {
                hasScannedEnergyImpact = true
            }
            isEnergyImpactPageScanActive = false
            energyImpactScanPhase = nil
            isLoadingEnergyImpact = false
        }
    }

    func setMenuBarRefreshInterval(_ interval: MenuBarRefreshInterval) {
        menuBarRefreshInterval = interval
    }

    func toggleMenuBarRefreshPaused() {
        isMenuBarRefreshPaused.toggle()
        if isMenuBarRefreshPaused {
            systemEnergyAccumulator.markObservationGap()
            setMenuBarProcessDemand(.overview)
            cancelMenuBarMemoryProcessRefresh()
            menuBarMemoryStatusGeneration &+= 1
            menuBarMemoryStatusTask?.cancel()
            MenuBarSamplingGaps.shared.begin(.paused)
        } else {
            MenuBarSamplingGaps.shared.end(.paused)
        }
        menuBarAuxiliaryMonitorState.setPaused(isMenuBarRefreshPaused)
        if !isMenuBarRefreshPaused {
            refreshMenuBarLiveStatus()
        }
    }

    func refreshMenuBarNow() {
        refreshMenuBarLiveStatus(forceMemorySnapshot: true)
        if energyImpactSnapshot != nil {
            refreshEnergyImpact()
        }
    }

    func refreshMenuBarMonitor() {
        requestMenuBarRefresh(policy: .lightweight)
    }

    func refreshMenuBarLiveStatus(showLoadingWhenEmpty: Bool = false, forceMemorySnapshot: Bool = false) {
        requestMenuBarRefresh(
            policy: isLoadingMemory || isOptimizingMemory ? .lightweight
                : (forceMemorySnapshot ? .fullMemory : .automatic),
            showLoadingWhenEmpty: showLoadingWhenEmpty
        )
    }

    private func requestMenuBarRefresh(
        policy: MemoryRefreshPolicy,
        showLoadingWhenEmpty: Bool = false
    ) {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        menuBarRefreshCoordinator.request(
            policy: policy,
            showLoadingWhenEmpty: showLoadingWhenEmpty
        )
    }

    private func performMenuBarRefresh(
        policy: MemoryRefreshPolicy,
        showLoadingWhenEmpty: Bool
    ) async {
        let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
        let signpostState = PerformanceTelemetry.signposter.beginInterval(
            "TelemetryPoll",
            id: signpostID
        )
        defer {
            PerformanceTelemetry.signposter.endInterval(
                "TelemetryPoll",
                signpostState
            )
        }
        // Process enumeration/optimization may own memory. Retain its last
        // snapshot while continuing independent CPU and network telemetry.
        let policy: MemoryRefreshPolicy = isLoadingMemory || isOptimizingMemory ? .lightweight : policy

        let shouldShowLoading = policy != .lightweight && showLoadingWhenEmpty && memorySnapshot == nil
        if shouldShowLoading {
            isLoadingMemory = true
        }
        defer {
            if shouldShowLoading {
                isLoadingMemory = false
            }
        }

        let enabledKinds = MenuBarMetricKind.defaultSelection
        let previousNetworkSample = menuBarNetworkSample
        let now = Date()
        let primarySnapshotWasMissing = memorySnapshot == nil
        let shouldRefreshMemorySnapshot = policy != .lightweight
            && shouldRefreshMenuBarMemorySnapshot(now: now, force: policy == .fullMemory)
        let currentMemorySnapshot = menuBarDisplayMemorySnapshot

        var snapshot: MemorySnapshot?
        switch policy {
        case .fullMemory:
            snapshot = await MemoryOptimizerService.snapshot()
        case .automatic where shouldRefreshMemorySnapshot:
            refreshMenuBarMemoryStatus()
            snapshot = currentMemorySnapshot
        case .lightweight, .automatic:
            snapshot = currentMemorySnapshot
        }

        if let sampledSnapshot = snapshot {
            let adoption = MenuBarMemorySnapshotAdoption.resolve(
                policy: policy,
                shouldRefreshMemorySnapshot: policy == .fullMemory,
                sampledSnapshotAvailable: true,
                primarySnapshotMissing: primarySnapshotWasMissing,
                monitorCreatedSnapshot: false
            )
            _ = adoptMenuBarMemorySnapshot(sampledSnapshot, as: adoption)
            snapshot = menuBarDisplayMemorySnapshot ?? sampledSnapshot
        }

        let result = await SystemMonitorService.snapshot(
            enabledKinds: enabledKinds,
            memorySnapshot: snapshot,
            previousNetworkSample: previousNetworkSample,
            thermalSamplingInterval: menuBarAuxiliaryMonitorState.activeConsumerCount > 0
                ? SystemMonitorSamplingInterval.interactive
                : SystemMonitorSamplingInterval.background,
            resolvesMissingMemorySnapshot: false
        )

        if snapshot == nil, let resolvedMemorySnapshot = result.memorySnapshot {
            let adoption = MenuBarMemorySnapshotAdoption.resolve(
                policy: policy,
                shouldRefreshMemorySnapshot: shouldRefreshMemorySnapshot,
                sampledSnapshotAvailable: false,
                primarySnapshotMissing: primarySnapshotWasMissing,
                monitorCreatedSnapshot: true
            )
            adoptMenuBarMemorySnapshot(resolvedMemorySnapshot, as: adoption)
        }
        menuBarMonitorState.update(result.snapshot)
        PerformanceTelemetry.signposter.emitEvent("StatePublish")
        PerformanceTelemetry.samplePublished(result.snapshot, interval: menuBarRefreshInterval.seconds,
            memorySnapshot: snapshot)
        if menuBarAuxiliaryMonitorState.activeConsumerCount == 0 {
            menuBarAuxiliaryMonitorState.refreshBackgroundMetricHistory()
        }
        FanControlCoordinator.shared.process(snapshot: result.snapshot)
        menuBarNetworkSample = result.networkSample
    }

    /// Memory pressure can require a slow system query. Keep it single-flight
    /// and publish independently so it cannot stall CPU/network sampling.
    private func refreshMenuBarMemoryStatus() {
        guard menuBarMemoryStatusTask == nil, !isMenuBarRefreshPaused else { return }
        let generation = menuBarMemoryStatusGeneration
        let provider = menuBarMemoryStatusProvider
        menuBarMemoryStatusTask = Task { @MainActor [weak self] in
            let snapshot = await provider()
            guard let self else { return }
            menuBarMemoryStatusTask = nil
            guard !Task.isCancelled, generation == menuBarMemoryStatusGeneration,
                  !isMenuBarRefreshPaused else { return }
            adoptMenuBarMemorySnapshot(snapshot, as: .menuStatusOnly)
        }
    }

    private func shouldRefreshMenuBarMemorySnapshot(now: Date, force: Bool) -> Bool {
        MenuBarMemoryRefreshThrottle.shouldRefresh(
            now: now,
            force: force,
            primarySnapshotAvailable: memorySnapshot != nil,
            menuStatusSnapshotAvailable: menuBarMemoryStatusSnapshot != nil,
            refreshedAt: menuBarMemorySnapshotRefreshedAt,
            interval: menuBarRefreshInterval.memorySnapshotSeconds
        )
    }

    private func markMenuBarMemorySnapshotRefreshed(at date: Date) {
        menuBarMemorySnapshotRefreshedAt = date
    }

    @discardableResult
    private func adoptMenuBarMemorySnapshot(
        _ snapshot: MemorySnapshot,
        as adoption: MenuBarMemorySnapshotAdoption
    ) -> MemorySnapshot {
        switch adoption {
        case .primaryAndMenuFromRefresh, .primaryAndMenuFromMonitor:
            let replacesPrimary = MenuBarDisplayMemorySnapshotSelection.shouldReplace(
                current: memorySnapshot,
                with: snapshot
            )
            let replacesMenuStatus = MenuBarDisplayMemorySnapshotSelection.shouldReplace(
                current: menuBarMemoryStatusSnapshot,
                with: snapshot
            )
            if replacesPrimary {
                if menuBarPreparedMemoryAppsDate != snapshot.generatedAt {
                    Task { @MainActor [weak self] in
                        let apps = await Task.detached(priority: .utility) { snapshot.appsByResidentUsage }.value
                        guard let self, memorySnapshot?.generatedAt == snapshot.generatedAt else { return }
                        menuBarPreparedMemoryAppsDate = snapshot.generatedAt
                        menuBarPreparedMemoryAppsVersion &+= 1
                        menuBarPreparedMemoryApps = apps
                    }
                }
                memorySnapshot = snapshot
                pruneMemoryProcessSelection(using: snapshot)
            }
            if replacesMenuStatus {
                menuBarMemoryStatusSnapshot = snapshot
            }
            menuBarMonitorState.recordMemorySample(snapshot)
            if replacesPrimary || replacesMenuStatus {
                markMenuBarMemorySnapshotRefreshed(at: snapshot.generatedAt)
            }
        case .menuStatusOnly:
            let replacesMenuStatus = MenuBarDisplayMemorySnapshotSelection.shouldReplace(
                current: menuBarMemoryStatusSnapshot,
                with: snapshot
            )
            if replacesMenuStatus {
                menuBarMemoryStatusSnapshot = snapshot
                markMenuBarMemorySnapshotRefreshed(at: snapshot.generatedAt)
            }
            menuBarMonitorState.recordMemorySample(snapshot)
        case .none:
            break
        }
        return menuBarDisplayMemorySnapshot ?? snapshot
    }

    func requestQuitProcess(_ process: MemoryProcess) {
        guard canRequestMemoryQuit(process) else { return }
        pendingMemoryProcess = process
    }

    var selectedMemoryAppUsages: [MemoryAppUsage] {
        guard let memorySnapshot else { return [] }
        return memorySnapshot.appsByResidentUsage.filter { app in
            let selectableIDs = Set(app.selectableProcessIDs)
            return !selectableIDs.isEmpty
                && !selectableIDs.isDisjoint(with: selectedMemoryProcessIDs)
        }
    }

    var selectedMemoryAppEstimatedBytes: Int64 {
        selectedMemoryAppUsages.reduce(0) { $0 + $1.bytes }
    }

    var selectedMemoryAppCount: Int {
        selectedMemoryAppUsages.count
    }

    var isRecommendedMemorySelectionPrepared: Bool {
        guard let recommendedIDs = memorySnapshot?.recommendedQuitProcessIDs,
              !recommendedIDs.isEmpty else { return false }
        return selectedMemoryProcessIDs == recommendedIDs
    }

    /// Every selected regular application instance is a safe normal-quit
    /// target. Helper RSS remains part of the displayed application estimate,
    /// but helpers are never included in this target list.
    var selectedMemoryProcessesForQuit: [MemoryProcess] {
        guard let memorySnapshot else { return [] }
        return memorySnapshot.selectableQuitProcesses.filter {
            selectedMemoryProcessIDs.contains($0.id)
        }
    }

    func isMemoryProcessSelected(_ process: MemoryProcess) -> Bool {
        selectedMemoryProcessIDs.contains(process.id)
    }

    func setMemoryProcessSelection(_ process: MemoryProcess, isSelected: Bool) {
        guard canEditMemorySelection, process.canQuit,
              let app = memorySnapshot?.appsByResidentUsage.first(where: {
                  $0.selectableProcessIDs.contains(process.id)
              }) else { return }
        setMemoryAppUsageSelection(app, isSelected: isSelected)
    }

    func toggleMemoryProcessSelection(_ process: MemoryProcess) {
        setMemoryProcessSelection(process, isSelected: !isMemoryProcessSelected(process))
    }

    func isMemoryAppUsageSelected(_ app: MemoryAppUsage) -> Bool {
        let selectableIDs = Set(app.selectableProcessIDs)
        return !selectableIDs.isEmpty
            && !selectableIDs.isDisjoint(with: selectedMemoryProcessIDs)
    }

    func setMemoryAppUsageSelection(_ app: MemoryAppUsage, isSelected: Bool) {
        guard canEditMemorySelection else { return }
        let selectableIDs = Set(app.selectableProcessIDs)
        guard !selectableIDs.isEmpty else { return }
        if isSelected {
            selectedMemoryProcessIDs.formUnion(selectableIDs)
        } else {
            selectedMemoryProcessIDs.subtract(selectableIDs)
        }
    }

    func toggleMemoryAppUsageSelection(_ app: MemoryAppUsage) {
        setMemoryAppUsageSelection(app, isSelected: !isMemoryAppUsageSelected(app))
    }

    func selectAllMemoryProcessesForQuit() {
        guard canEditMemorySelection, let memorySnapshot else { return }
        selectedMemoryProcessIDs = Set(memorySnapshot.selectableQuitProcesses.map(\.id))
    }

    func clearMemoryProcessSelection() {
        selectedMemoryProcessIDs.removeAll()
    }

    @discardableResult
    func selectRecommendedMemoryApps() -> Bool {
        guard canEditMemorySelection, let memorySnapshot else { return false }
        let recommendedIDs = memorySnapshot.recommendedQuitProcessIDs
        guard !recommendedIDs.isEmpty else { return false }
        selectedMemoryProcessIDs = recommendedIDs
        return true
    }

    @discardableResult
    func ensureMemorySelectionForQuit() -> Bool {
        guard canRequestMemoryQuitActions else { return false }
        return selectedMemoryAppCount > 0 || selectRecommendedMemoryApps()
    }

    func requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: Bool = false) {
        guard canRequestMemoryQuitActions else { return }
        guard let memorySnapshot else {
            refreshMemory()
            return
        }
        let selectedApps = selectedMemoryAppUsages
        let selectedProcesses = selectedMemoryProcessesForQuit
        guard !selectedApps.isEmpty, !selectedProcesses.isEmpty else {
            showActionMessage(L10n.text("先选择要退出的应用", "Select apps to quit first"))
            return
        }
        do {
            let plan = try memoryCoordinator.makePlan(
                processes: selectedProcesses,
                snapshot: memorySnapshot
            )
            pendingMemoryOptimizationPlan = plan
            pendingMemoryPlanSnapshot = memorySnapshot
            memoryOptimizationState = memoryCoordinator.state
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        pendingMemoryProcessesToQuit = selectedProcesses
        pendingMemoryQuitSummary = MemoryQuitSelectionSummary(
            appCount: selectedApps.count,
            estimatedBytes: selectedApps.reduce(0) { $0 + $1.bytes }
        )
        isMemoryBatchQuitConfirmationPresentedInMenuBar = presentConfirmationInMenuBar
    }

    func cancelQuitSelectedMemoryProcesses() {
        memoryCoordinator.cancel()
        memoryOptimizationState = memoryCoordinator.state
        clearPendingMemoryQuitConfirmation()
    }

    func confirmQuitProcess() {
        guard let process = pendingMemoryProcess,
              let memorySnapshot,
              canRequestMemoryQuit(process) else { return }
        pendingMemoryProcess = nil

        do {
            let plan = try memoryCoordinator.makePlan(
                processes: [process],
                snapshot: memorySnapshot
            )
            executeMemoryPlan(plan, before: memorySnapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmQuitSelectedMemoryProcesses() {
        guard let plan = pendingMemoryOptimizationPlan,
              let before = pendingMemoryPlanSnapshot,
              pendingMemoryQuitSummary != nil,
              !pendingMemoryProcessesToQuit.isEmpty,
              canRequestMemoryQuitActions else { return }
        clearPendingMemoryQuitConfirmation()
        executeMemoryPlan(plan, before: before)
    }

    func cancelMemoryOptimization() {
        memoryOptimizationTask?.cancel()
        memoryCoordinator.cancel()
        memoryOptimizationState = memoryCoordinator.state
        isOptimizingMemory = false
    }

    func prepareMemoryOptimizationForTermination() async {
        cancelMemoryOptimization()
        await memoryOptimizationTask?.value
    }

    private func executeMemoryPlan(
        _ plan: MemoryOptimizationPlan,
        before: MemorySnapshot
    ) {
        guard !isOptimizingMemory else { return }
        isOptimizingMemory = true
        errorMessage = nil
        memoryOptimizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isOptimizingMemory = false
                memoryOptimizationTask = nil
            }
            do {
                let execution = try await memoryCoordinator.execute(
                    planID: plan.id,
                    before: before
                )
                memoryOptimizationState = memoryCoordinator.state
                let after = execution.snapshotAfter ?? before
                adoptMenuBarMemorySnapshot(after, as: .primaryAndMenuFromRefresh)

                let successfulIDs = Set(execution.targetResults.compactMap { result -> Int32? in
                    switch result.outcome {
                    case .gracefulQuitSucceeded, .forceQuitSucceeded, .targetExitedBeforeRequest:
                        result.target.identity.processIdentifier
                    default:
                        nil
                    }
                })
                selectedMemoryProcessIDs.subtract(successfulIDs)

                let status: MemoryOptimizationStatus
                switch execution.completion {
                case .completed: status = .completed
                case .partial: status = .partial
                case .cancelled: status = .cancelled
                case .verificationFailed: status = .verificationFailed
                }
                memoryOptimizationResult = MemoryOptimizationResult(
                    beforeSnapshot: before,
                    snapshot: after,
                    status: status,
                    detail: execution.attributionNotice,
                    durationSeconds: execution.completedAt.timeIntervalSince(execution.startedAt),
                    executionResult: execution
                )
                showActionMessage(memoryExecutionMessage(execution))
                refreshMenuBarMonitor()
            } catch {
                memoryOptimizationState = .failed(
                    error as? MemoryOptimizationCoordinatorError ?? .probeUnavailable
                )
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshInstalledApps(priority: TaskPriority = .userInitiated) {
        guard canRefreshInstalledApps else { return }
        pendingUninstallApp = nil
        isLoadingInstalledApps = true
        hasScannedInstalledApps = true
        installedAppsScanCoverage = nil

        Task(priority: priority) {
            let scanResult = await AppUninstallService.scanInstalledAppsFromSharedInventory()
            installedApps = scanResult.apps
            installedAppsScanCoverage = scanResult.coverage
            isLoadingInstalledApps = false

            let scannedIDs = scanResult.apps.map(\.id)
            let enrichedApps = await AppUninstallService.enrichUninstallRecommendations(in: scanResult.apps)
            guard installedApps.map(\.id) == scannedIDs else { return }
            installedApps = enrichedApps
        }
    }

    func requestUninstall(_ app: InstalledAppItem) {
        guard canRequestUninstall(app) else { return }
        pendingUninstallApp = app
    }

    func confirmUninstall() {
        guard let app = pendingUninstallApp, canRequestUninstall(app) else { return }
        isUninstallingApp = true

        Task {
            do {
                let result = try await heavyWorkCoordinator.withLease(owner: .cleanup) { _ in
                    try Task.checkCancellation()
                    return try await Task.detached(priority: .userInitiated) {
                        try AppUninstallService.moveToTrash(app)
                    }.value
                }
                guard let report = result.report else { throw AppUninstallError.moveNotVerified(app.path) }
                lastCleanReport = report
                if !CleanReportStore.record(report) || report.persistenceFailure != nil {
                    errorMessage = L10n.text("卸载回执未能完整保存，请保留当前结果。", "The uninstall receipt could not be fully saved. Keep this result.")
                }
                guard report.summary.movedItemCount > 0 else {
                    if errorMessage == nil { errorMessage = L10n.text("应用未移走，请查看操作回执。", "The app was not moved. Review the operation receipt.") }
                    isUninstallingApp = false
                    return
                }
                installedApps.removeAll { $0.id == app.id }
                pendingUninstallApp = nil
                showActionMessage(uninstallMessage(for: app, result: result))
                if app.relatedItems.contains(where: { $0.verifiedExclusiveOwnerBundleID == app.bundleIdentifier }) {
                    await Task.yield()
                    pendingRelatedCleanupApp = app
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isUninstallingApp = false
        }
    }

    func keepRelatedAppFiles() {
        pendingRelatedCleanupApp = nil
    }

    func confirmRelatedAppCleanup() {
        guard let app = pendingRelatedCleanupApp, !isCleaningRelatedAppFiles else { return }
        pendingRelatedCleanupApp = nil
        isCleaningRelatedAppFiles = true

        Task {
            let result: AppUninstallTrashResult
            do {
                result = try await heavyWorkCoordinator.withLease(owner: .cleanup) { _ in
                    try Task.checkCancellation()
                    return await Task.detached(priority: .userInitiated) {
                        AppUninstallService.moveRelatedItemsToTrash(for: app)
                    }.value
                }
            } catch {
                errorMessage = error.localizedDescription
                isCleaningRelatedAppFiles = false
                return
            }
            if let report = result.report {
                lastCleanReport = report
                if !CleanReportStore.record(report) || report.persistenceFailure != nil {
                    errorMessage = L10n.text("关联文件回执未能完整保存，请保留当前结果。", "Related file receipts could not be fully saved. Keep this result.")
                }
                refreshOperationReports()
            }
            if result.movedRelatedItems.isEmpty {
                showActionMessage(L10n.text(
                    "没有可清除的关联文件，原有数据已保留",
                    "No associated files were removed; existing data was kept"
                ))
            } else {
                showActionMessage(L10n.text(
                    "已将 \(result.movedRelatedItems.count) 个关联文件移到废纸篓，共 \(ByteFormat.string(result.movedRelatedBytes))",
                    "\(result.movedRelatedItems.count) associated files moved to Trash, \(ByteFormat.string(result.movedRelatedBytes)) total"
                ))
            }
            if result.unresolvedRelatedCount > 0 {
                errorMessage = L10n.text(
                    "有 \(result.unresolvedRelatedCount) 个关联文件未能处理",
                    "\(result.unresolvedRelatedCount) associated files could not be processed"
                )
            }
            isCleaningRelatedAppFiles = false
        }
    }

    private func uninstallMessage(for app: InstalledAppItem, result: AppUninstallTrashResult) -> String {
        if result.movedRelatedItems.isEmpty {
            return L10n.text(
                "已将 \(app.name) 移到废纸篓，清空前可恢复",
                "\(app.name) moved to Trash and remains recoverable until Trash is emptied"
            )
        }

        let base = L10n.text(
            "已将 \(app.name) 和 \(result.movedRelatedItems.count) 个关联文件移到废纸篓，共 \(ByteFormat.string(result.movedBytes))；清空后才释放空间",
            "\(app.name) and \(result.movedRelatedItems.count) associated files moved to Trash, \(ByteFormat.string(result.movedBytes)) total; space is freed after Trash is emptied"
        )

        guard result.unresolvedRelatedCount > 0 else { return base }

        return L10n.text(
            "\(base)。\(result.unresolvedRelatedCount) 个关联文件未处理，可在详情里复核。",
            "\(base). \(result.unresolvedRelatedCount) associated files were not processed; review details if needed."
        )
    }

    @discardableResult
    private func beginAppUpdatePresentationSession(
        sessionID: UUID
    ) -> AppUpdatePresentationToken {
        appUpdatePresentationMachine.beginSession(sessionID: sessionID)
    }

    @discardableResult
    private func transitionAppUpdatePresentation(
        to state: AppUpdatePresentationState,
        token: AppUpdatePresentationToken
    ) -> Bool {
        let result = appUpdatePresentationMachine.transition(to: state, token: token)
        guard result == .applied else {
#if DEBUG
            if case let .rejected(.invalidTransition(from, to)) = result {
                assertionFailure("Invalid app-update presentation transition: \(from.rawValue) -> \(to.rawValue)")
            }
#endif
            return false
        }
        appUpdatePresentationState = appUpdatePresentationMachine.state
        return true
    }

    func showAppUpdateManager() {
        guard !isLoadingAppUpdates, !isRunningOneClickUpdate else { return }
        let token = appUpdatePresentationMachine.activeToken
        transitionAppUpdatePresentation(
            to: .managing(
                AppUpdateCatalogSnapshot(
                    sessionID: token.sessionID,
                    applications: appUpdates
                )
            ),
            token: token
        )
    }

    func showAppUpdateScanSummary() {
        guard !isLoadingAppUpdates, !isRunningOneClickUpdate else { return }
        let token = appUpdatePresentationMachine.activeToken
        transitionAppUpdatePresentation(
            to: .scanSummary(
                AppScanSummary(
                    sessionID: token.sessionID,
                    generatedAt: appUpdatesLastScannedAt ?? Date(),
                    applications: appUpdates
                )
            ),
            token: token
        )
    }

    func resetAppUpdatePresentation() {
        guard !isLoadingAppUpdates, !isRunningOneClickUpdate else { return }
        let token = appUpdatePresentationMachine.activeToken
        let lastSummary: LastAppScanSummary?
        if appUpdatesLastScannedAt != nil {
            lastSummary = LastAppScanSummary(
                summary: AppScanSummary(
                    sessionID: token.sessionID,
                    generatedAt: appUpdatesLastScannedAt ?? Date(),
                    applications: appUpdates
                )
            )
        } else {
            lastSummary = nil
        }
        transitionAppUpdatePresentation(to: .idle(lastSummary), token: token)
    }

    func requestSelectedAppUpdates(applicationIDs: Set<String>) {
        guard canRequestOneClickAppUpdates else { return }
        let selected = appUpdates.filter {
            guard applicationIDs.contains($0.id) else { return false }
            switch ApplicationUpdatePlanBuilder.destination(for: $0) {
            case .automatic, .requiresQuit:
                return true
            default:
                return false
            }
        }
        guard !selected.isEmpty else {
            showActionMessage(L10n.text(
                "所选项目没有符合安全条件的自动更新",
                "The selection has no updates that meet the automatic safety requirements"
            ))
            return
        }
        pendingOneClickUpdatePlan = AppUpdateService.oneClickPlan(for: selected)
    }

    func retryAppUpdate(applicationID: String) {
        retryAppUpdates(applicationIDs: [applicationID])
    }

    func retryAppUpdates(applicationIDs: Set<String>) {
        guard allowsLiveAppUpdateActions,
              !applicationIDs.isEmpty,
              !isLoadingAppUpdates,
              !isRunningOneClickUpdate,
              appUpdateOperation == nil else { return }
        let coordinator = applicationUpdateCoordinator

        Task { @MainActor [weak self] in
            guard let self,
                  let queue = await coordinator.currentSnapshot(),
                  queue.plan.id == appUpdatePresentationMachine.activeToken.sessionID else {
                self?.showActionMessage(L10n.text(
                    "原更新会话已不可用，请重新扫描后再试",
                    "The original update session is no longer available; scan again before retrying"
                ))
                return
            }
            let retryableIDs = queue.tasks.compactMap { task -> String? in
                guard applicationIDs.contains(task.applicationID),
                      [.failed, .cancelled, .needsReconciliation].contains(task.state)
                else { return nil }
                return task.applicationID
            }
            guard !retryableIDs.isEmpty else {
                showActionMessage(L10n.text(
                    "所选项目当前不可重试",
                    "The selected items cannot be retried in their current state"
                ))
                return
            }

            stopApplicationUpdateCoordinatorMonitor()
            let events = await coordinator.events()
            appUpdateExpectedSessionID = queue.plan.id
            appUpdateCancellationRequestedSessionID = nil
            pendingAppUpdateReport = nil
            isRunningOneClickUpdate = true
            startApplicationUpdateCoordinatorMonitor(
                sessionID: queue.plan.id,
                events: events
            )

            var retriedCount = 0
            var errors = [String]()
            for applicationID in retryableIDs {
                do {
                    try await coordinator.retry(applicationID: applicationID)
                    retriedCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            guard retriedCount > 0 else {
                stopApplicationUpdateCoordinatorMonitor()
                isRunningOneClickUpdate = false
                errorMessage = errors.first
                return
            }
            if let current = await coordinator.currentSnapshot(),
               current.plan.id == queue.plan.id {
                appUpdateQueueSnapshot = current
                publishAppUpdateSession(current)
            }
            if !errors.isEmpty {
                appUpdateScanWarnings.append(contentsOf: errors)
            }
        }
    }

    private static func appScanProgressSnapshot(
        from progress: ApplicationScanProgress,
        sessionID: UUID
    ) -> AppScanProgressSnapshot {
        let stage: AppScanStage = switch progress.stage {
        case .scanningStandardDirectories, .scanningSpotlight,
             .scanningFallbackDirectories, .scanningHomebrew:
            .discoveringApplications
        case .readingMetadata:
            .readingMetadata
        case .identifyingSources:
            .resolvingSources
        case .completed:
            .finishing
        }
        let hasStableTotal = progress.stage == .identifyingSources
            || progress.stage == .completed
        return AppScanProgressSnapshot(
            sessionID: sessionID,
            generatedAt: Date(),
            stage: stage,
            completedUnitCount: progress.scannedCount,
            totalUnitCount: hasStableTotal && progress.discoveredCount > 0
                ? progress.discoveredCount
                : nil,
            currentApplicationID: nil,
            currentApplicationName: nil
        )
    }

    private func shouldPublishAppUpdateScanProgress(
        _ progress: ApplicationScanProgress,
        now: Date = Date()
    ) -> Bool {
        let stageChanged = progress.stage != appUpdateLastProgressStage
        let elapsed = now.timeIntervalSince(appUpdateLastProgressPublishedAt ?? .distantPast)
        guard stageChanged || elapsed >= (1.0 / 12.0) || progress.stage == .completed else {
            return false
        }
        appUpdateLastProgressPublishedAt = now
        appUpdateLastProgressStage = progress.stage
        return true
    }

    private func finishPendingAppUpdateReportAfterRefresh() {
        guard let report = pendingAppUpdateReport else { return }
        let token = appUpdatePresentationMachine.activeToken
        guard token.sessionID == report.sessionID else { return }
        let didTransition: Bool
        switch report.outcome {
        case .allFailed:
            didTransition = transitionAppUpdatePresentation(to: .failed(report), token: token)
        case .cancelled:
            didTransition = transitionAppUpdatePresentation(to: .cancelled(report), token: token)
        case .allSucceeded, .partialSuccess, .noEligibleUpdates, .requiresAction:
            didTransition = transitionAppUpdatePresentation(to: .completed(report), token: token)
        }
        guard didTransition else { return }
        pendingAppUpdateReport = nil
        appUpdateCancellationRequestedSessionID = nil
    }

    private func publishAppUpdateSession(
        _ queue: ApplicationUpdateQueueSnapshot,
        finalizing: Bool = false
    ) {
        let token = appUpdatePresentationMachine.activeToken
        guard token.sessionID == queue.plan.id else { return }
        let snapshot = AppUpdateSessionSnapshot(
            queue: queue,
            applications: appUpdates,
            isCancellationRequested: appUpdateCancellationRequestedSessionID == queue.plan.id
        )
        transitionAppUpdatePresentation(
            to: finalizing ? .finalizing(snapshot) : .updating(snapshot),
            token: token
        )
    }

    func refreshAppUpdates() {
        guard appUpdateScanOperation == nil, canRefreshAppUpdates else { return }
        let isPostUpdateRefresh = appUpdatesAutoRescanPending
        pendingOneClickUpdatePlan = nil
        errorMessage = nil
        appUpdateScanWarnings = []
        isLoadingAppUpdates = true
        appUpdateProgress = AppUpdateProgress(
            title: isPostUpdateRefresh
                ? L10n.text("正在验证更新后的环境", "Verifying the Updated Environment")
                : L10n.text("正在扫描应用", "Scanning applications"),
            detail: isPostUpdateRefresh
                ? L10n.text("重新读取磁盘版本与更新来源", "Re-reading on-disk versions and update sources")
                : L10n.text("先读取标准目录", "Reading standard application folders first"),
            fraction: 0.04,
            systemImage: "magnifyingglass"
        )
        let startedAt = Date()
        let generation = UUID()
        appUpdateScanGeneration = generation
        let initialScanProgress = AppScanProgressSnapshot(
            sessionID: generation,
            generatedAt: startedAt,
            stage: .discoveringApplications,
            completedUnitCount: 0,
            totalUnitCount: nil,
            currentApplicationID: nil,
            currentApplicationName: nil
        )
        appUpdateScanState = .scanning(initialScanProgress)
        appUpdateLastProgressPublishedAt = nil
        appUpdateLastProgressStage = nil
        let presentationToken: AppUpdatePresentationToken?
        if isPostUpdateRefresh {
            presentationToken = nil
        } else {
            let token = beginAppUpdatePresentationSession(sessionID: generation)
            transitionAppUpdatePresentation(
                to: .scanning(initialScanProgress),
                token: token
            )
            presentationToken = token
        }
        if !isPostUpdateRefresh {
            appUpdates.removeAll()
        }
        let sourceConfiguration = AppUpdateSourcePreferences.configuration()
        let preferences = ApplicationUpdatePreferences.snapshot()
        let additionalDirectoryBookmarks = FolderAccessGrantService.savedAccessBookmarkData()
        let configuration = ApplicationScanConfiguration(
            includeSpotlightResults: true,
            includeExternalVolumes: preferences.scansExternalVolumes,
            includeHomebrewFormulae: preferences.includesHomebrewFormulae,
            checkSelfUpdatingHomebrewCasks: preferences.checksSelfUpdatingHomebrewCasks,
            additionalDirectoryBookmarks: additionalDirectoryBookmarks
        )
        let scanner = applicationInventoryScanner
        let shouldLoadLocalAppStoreUpdates = sourceConfiguration.includes(.appStore)
            && scanner is ApplicationInventoryScanner
        let coordinator = heavyWorkCoordinator
        let activityStore = heavyWorkActivityStore

        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if appUpdateScanGeneration == generation {
                    appUpdateScanOperation = nil
                    appUpdateScanGeneration = nil
                    isLoadingAppUpdates = false
                    appUpdateProgress = nil
                    appUpdatesAutoRescanPending = false
                    appUpdateLastProgressPublishedAt = nil
                    appUpdateLastProgressStage = nil
                }
            }

            do {
                let (scannedApps, appStoreOutdated) = try await coordinator.withLease(
                    owner: .appUpdates
                ) { lease in
                    await activityStore.refresh()
                    try await coordinator.requireValid(lease, owner: .appUpdates)
                    let appStoreOutdatedTask = Task.detached(priority: .utility) {
                        shouldLoadLocalAppStoreUpdates
                            ? AppUpdateService.appStoreOutdatedByBundleIdentifier()
                            : [:]
                    }
                    defer { appStoreOutdatedTask.cancel() }

                    let applications = try await scanner.scan(
                        configuration: configuration,
                        onProgress: { [weak self] progress in
                            await MainActor.run { [weak self] in
                                guard let self, self.appUpdateScanGeneration == generation else { return }
                                if let detail = progress.detail,
                                   detail.hasPrefix("official-registry: ") {
                                    let warning = String(detail.dropFirst("official-registry: ".count))
                                    if !self.appUpdateScanWarnings.contains(warning) {
                                        self.appUpdateScanWarnings.append(warning)
                                    }
                                }
                                let progressSnapshot = Self.appScanProgressSnapshot(
                                    from: progress,
                                    sessionID: generation
                                )
                                self.appUpdateScanState = .scanning(progressSnapshot)
                                guard self.shouldPublishAppUpdateScanProgress(progress) else { return }
                                self.appUpdateProgress = Self.presentationProgress(progress)
                                if let presentationToken {
                                    self.transitionAppUpdatePresentation(
                                        to: .scanning(progressSnapshot),
                                        token: presentationToken
                                    )
                                }
                            }
                        },
                        onApplications: { [weak self] applications in
                            await MainActor.run { [weak self] in
                                guard let self, self.appUpdateScanGeneration == generation else { return }
                                self.upsertIncrementalAppUpdates(applications)
                            }
                        }
                    )
                    try Task.checkCancellation()
                    let outdated = await withTaskCancellationHandler(
                        operation: { await appStoreOutdatedTask.value },
                        onCancel: { appStoreOutdatedTask.cancel() }
                    )
                    try Task.checkCancellation()
                    return (applications, outdated)
                }
                await activityStore.refresh()
                try Task.checkCancellation()
                guard appUpdateScanGeneration == generation else { return }

                var apps = AppUpdateService.mergingAppStoreOutdated(
                    appStoreOutdated,
                    into: scannedApps
                )

                apps = apps.map { app in
                    var item = app
                    if !sourceConfiguration.includes(item.method) {
                        item.canAutomaticallyUpdate = false
                        item.requiresUserInteraction = true
                        item.versionCheckState = .unavailable
                        item.updateError = L10n.text(
                            "此更新来源已在设置中关闭。",
                            "This update source is disabled in Settings."
                        )
                    }
                    if AppUpdateIgnoreService.isIgnored(item) {
                        item.updateStatus = .ignored
                        item.canAutomaticallyUpdate = false
                        item.requiresUserInteraction = true
                    }
                    return item
                }
                appUpdates = apps
                ignoredAppUpdateCount = apps.filter { $0.updateStatus == .ignored }.count
                let completedAt = Date()
                appUpdatesLastScannedAt = completedAt
                appUpdatesLastScanSeconds = completedAt.timeIntervalSince(startedAt)
                ApplicationUpdateCheckSchedule.markChecked()
                appUpdateScanState = .ready
                if !isPostUpdateRefresh, let presentationToken {
                    transitionAppUpdatePresentation(
                        to: .scanSummary(
                            AppScanSummary(
                                sessionID: generation,
                                generatedAt: completedAt,
                                applications: apps
                            )
                        ),
                        token: presentationToken
                    )
                }
                await restoreApplicationUpdateQueueIfNeeded(applications: apps)
                if isPostUpdateRefresh {
                    finishPendingAppUpdateReportAfterRefresh()
                } else if !isRunningOneClickUpdate {
                    evaluateAutomaticUpdatePolicyAfterScanIfNeeded()
                }
            } catch is CancellationError {
                await activityStore.refresh()
                guard appUpdateScanGeneration == generation else { return }
                appUpdateScanState = .cancelled
                pendingAutomaticUpdateEvaluation = false
                if isPostUpdateRefresh {
                    finishPendingAppUpdateReportAfterRefresh()
                } else if let presentationToken {
                    transitionAppUpdatePresentation(to: .cancelled(nil), token: presentationToken)
                }
                showActionMessage(L10n.text("应用扫描已取消", "Application scan cancelled"))
            } catch {
                await activityStore.refresh()
                guard appUpdateScanGeneration == generation else { return }
                appUpdateScanState = .failed(error.localizedDescription)
                pendingAutomaticUpdateEvaluation = false
                errorMessage = error.localizedDescription
                if isPostUpdateRefresh {
                    if !appUpdateScanWarnings.contains(error.localizedDescription) {
                        appUpdateScanWarnings.append(error.localizedDescription)
                    }
                    finishPendingAppUpdateReportAfterRefresh()
                } else if let presentationToken {
                    transitionAppUpdatePresentation(
                        to: .failed(
                            AppUpdateReport(
                                sessionID: generation,
                                sessionError: error.localizedDescription
                            )
                        ),
                        token: presentationToken
                    )
                }
            }
        }
        appUpdateScanOperation = operation
    }

    func cancelAppUpdateScan() {
        guard isLoadingAppUpdates else { return }
        appUpdateScanOperation?.cancel()
        appUpdateProgress = AppUpdateProgress(
            title: L10n.text("正在取消扫描", "Cancelling scan"),
            detail: L10n.text("正在停止 Spotlight 和 Homebrew 查询", "Stopping Spotlight and Homebrew queries"),
            fraction: appUpdateProgress?.fraction ?? 0,
            systemImage: "xmark.circle"
        )
    }

    func requestApplicationUpdateCancellation() {
        guard allowsLiveAppUpdateActions else { return }
        markApplicationUpdateBatchCancellationRequested()
        appUpdateScanOperation?.cancel()
        appUpdateOperation?.cancel()
        Task { [applicationUpdateCoordinator] in
            try? await applicationUpdateCoordinator.cancel()
        }
    }

    func prepareApplicationUpdatesForTermination() async {
        guard allowsLiveAppUpdateActions else { return }
        isPreparingApplicationUpdatesForTermination = true
        markApplicationUpdateBatchCancellationRequested()
        let scanOperation = appUpdateScanOperation
        let updateOperation = appUpdateOperation
        scanOperation?.cancel()
        updateOperation?.cancel()
        appUpdateCoordinatorMonitorTask?.cancel()
        appUpdateCoordinatorMonitorTask = nil
        try? await applicationUpdateCoordinator.suspendForTermination()
        await scanOperation?.value
        await updateOperation?.value
    }

    func prepareApplicationUpdatesOnLaunch() {
        guard ApplicationUpdateCheckSchedule.shouldCheck(), canRefreshAppUpdates else { return }
        pendingAutomaticUpdateEvaluation = true
        refreshAppUpdates()
    }

    private func evaluateAutomaticUpdatePolicyAfterScanIfNeeded() {
        guard allowsLiveAppUpdateActions else { return }
        guard pendingAutomaticUpdateEvaluation else { return }
        pendingAutomaticUpdateEvaluation = false
        let preferences = ApplicationUpdatePreferences.snapshot()
        guard preferences.automaticallyExecutesSilentUpdates,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            return
        }
        let plan = AppUpdateService.oneClickPlan(for: appUpdates)
        guard plan.hasAutomaticUpdates else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.runOneClickAppUpdates(
                plan: plan,
                requestsGracefulQuit: false,
                reopensUpdatedApplications: false
            )
        }
    }

    private func upsertIncrementalAppUpdates(_ applications: [InstalledApplication]) {
        guard !applications.isEmpty else { return }
        var merged = Dictionary(uniqueKeysWithValues: appUpdates.map { ($0.id, $0) })
        for application in applications {
            merged[application.id] = application
        }
        appUpdates = merged.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func presentationProgress(_ progress: ApplicationScanProgress) -> AppUpdateProgress {
        let ratio: Double = progress.discoveredCount > 0
            ? min(1, Double(progress.scannedCount) / Double(progress.discoveredCount))
            : 0
        switch progress.stage {
        case .scanningStandardDirectories:
            return AppUpdateProgress(
                title: L10n.text("正在扫描应用", "Scanning applications"),
                detail: L10n.text("标准目录", "Standard folders"),
                fraction: 0.06,
                systemImage: "folder"
            )
        case .readingMetadata:
            return AppUpdateProgress(
                title: L10n.text("正在读取应用信息", "Reading application metadata"),
                detail: "\(progress.scannedCount) / \(progress.discoveredCount)",
                fraction: 0.08 + ratio * 0.42,
                systemImage: "app.badge.checkmark"
            )
        case .scanningSpotlight:
            return AppUpdateProgress(
                title: L10n.text("正在查询 Spotlight", "Querying Spotlight"),
                detail: L10n.text("合并非标准位置", "Merging non-standard locations"),
                fraction: 0.52,
                systemImage: "magnifyingglass"
            )
        case .scanningFallbackDirectories:
            return AppUpdateProgress(
                title: L10n.text("正在扫描备用目录", "Scanning fallback folders"),
                detail: L10n.text("Spotlight 不可用或超时", "Spotlight unavailable or timed out"),
                fraction: 0.56,
                systemImage: "folder.badge.questionmark"
            )
        case .scanningHomebrew:
            return AppUpdateProgress(
                title: L10n.text("正在读取 Homebrew", "Reading Homebrew"),
                detail: L10n.text("Formula 与 Cask", "Formulae and casks"),
                fraction: 0.62,
                systemImage: "terminal"
            )
        case .identifyingSources:
            return AppUpdateProgress(
                title: L10n.text("正在识别更新来源", "Identifying update sources"),
                detail: "\(progress.scannedCount) / \(progress.discoveredCount)",
                fraction: 0.64 + ratio * 0.34,
                systemImage: "checkmark.shield"
            )
        case .completed:
            return AppUpdateProgress(
                title: L10n.text("已完成扫描", "Scan complete"),
                detail: L10n.items(progress.discoveredCount),
                fraction: 1,
                systemImage: "checkmark.circle"
            )
        }
    }

    private func restoreApplicationUpdateQueueIfNeeded(
        applications: [InstalledApplication]
    ) async {
        guard !didRestoreApplicationUpdateQueue else { return }
        didRestoreApplicationUpdateQueue = true
        do {
            // Subscribe before auto-resume can schedule a fast worker. The
            // stream buffers task/drain events until the monitor starts.
            let events = await applicationUpdateCoordinator.events()
            let restored = try await applicationUpdateCoordinator.restore(
                applications: applications,
                autoResume: true
            )
            appUpdateQueueSnapshot = restored
            if let restored,
               restored.tasks.contains(where: { !$0.state.isTerminal }) {
                appUpdateExpectedSessionID = restored.plan.id
                startApplicationUpdateCoordinatorMonitor(
                    sessionID: restored.plan.id,
                    events: events
                )
                isRunningOneClickUpdate = true
                let token = beginAppUpdatePresentationSession(sessionID: restored.plan.id)
                transitionAppUpdatePresentation(
                    to: .updating(
                        AppUpdateSessionSnapshot(
                            queue: restored,
                            applications: applications
                        )
                    ),
                    token: token
                )
            } else {
                appUpdateExpectedSessionID = nil
                stopApplicationUpdateCoordinatorMonitor()
            }
        } catch {
            appUpdateScanWarnings.append(error.localizedDescription)
        }
    }

    private func startApplicationUpdateCoordinatorMonitor(
        sessionID: UUID,
        events preparedEvents: AsyncStream<ApplicationUpdateCoordinatorEvent>? = nil
    ) {
        guard appUpdateCoordinatorMonitorTask == nil else { return }
        let coordinator = applicationUpdateCoordinator
        let monitorToken = UUID()
        appUpdateCoordinatorMonitorToken = monitorToken
        appUpdateCoordinatorMonitorTask = Task { @MainActor [weak self] in
            defer {
                self?.finishApplicationUpdateCoordinatorMonitor(
                    matching: monitorToken
                )
            }
            let events: AsyncStream<ApplicationUpdateCoordinatorEvent>
            if let preparedEvents {
                events = preparedEvents
            } else {
                events = await coordinator.events()
            }
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                let didApply = applyApplicationUpdateCoordinatorEvent(
                    event,
                    expectedSessionID: sessionID
                )
                if didApply,
                   case let .drained(snapshot) = event,
                   snapshot.tasks.allSatisfy(\.state.isTerminal) {
                    return
                }
            }
        }
    }

    private func stopApplicationUpdateCoordinatorMonitor() {
        appUpdateCoordinatorMonitorTask?.cancel()
        appUpdateCoordinatorMonitorTask = nil
        appUpdateCoordinatorMonitorToken = nil
    }

    private func finishApplicationUpdateCoordinatorMonitor(matching token: UUID) {
        guard appUpdateCoordinatorMonitorToken == token else { return }
        appUpdateCoordinatorMonitorTask = nil
        appUpdateCoordinatorMonitorToken = nil
    }

    @discardableResult
    func applyApplicationUpdateCoordinatorEvent(
        _ event: ApplicationUpdateCoordinatorEvent,
        expectedSessionID: UUID?
    ) -> Bool {
        guard allowsLiveAppUpdateActions else { return false }
        switch event {
        case let .restored(snapshot), let .started(snapshot),
             let .snapshotChanged(snapshot), let .paused(snapshot),
             let .resumed(snapshot):
            guard snapshot.plan.id == expectedSessionID else { return false }
            appUpdateQueueSnapshot = snapshot
            requestGracefulQuitForWaitingTasks(snapshot)
            if appUpdateOperation == nil {
                publishAppUpdateSession(snapshot)
            }
            return true
        case let .drained(snapshot):
            guard snapshot.plan.id == expectedSessionID else { return false }
            appUpdateQueueSnapshot = snapshot
            guard appUpdateOperation == nil else { return true }
            if snapshot.tasks.allSatisfy(\.state.isTerminal) {
                finishApplicationUpdateQueue(snapshot)
                isRunningOneClickUpdate = false
                appUpdateProgress = nil
                if let report = pendingAppUpdateReport,
                   report.outcome == .cancelled {
                    let token = appUpdatePresentationMachine.activeToken
                    pendingAppUpdateReport = nil
                    appUpdateCancellationRequestedSessionID = nil
                    transitionAppUpdatePresentation(
                        to: .cancelled(report),
                        token: token
                    )
                } else {
                    appUpdatesAutoRescanPending = true
                    refreshAppUpdates()
                }
            } else {
                publishAppUpdateSession(snapshot)
            }
            return true
        case let .taskChanged(task):
            guard task.sessionID == expectedSessionID else { return false }
            applyApplicationUpdateTask(task)
            requestGracefulQuitIfNeeded(for: task)
            return true
        case let .persistenceFailed(sessionID, detail):
            guard sessionID == expectedSessionID else { return false }
            if !appUpdateScanWarnings.contains(detail) {
                appUpdateScanWarnings.append(detail)
            }
            return true
        }
    }

    func ignoreAppUpdate(_ app: AppUpdateItem) {
        guard canIgnoreAppUpdate(app) else { return }
        AppUpdateIgnoreService.ignore(app)
        if let index = appUpdates.firstIndex(where: { $0.id == app.id }) {
            appUpdates[index].updateStatus = .ignored
            appUpdates[index].canAutomaticallyUpdate = false
            appUpdates[index].requiresUserInteraction = true
        }
        ignoredAppUpdateCount = appUpdates.filter { $0.updateStatus == .ignored }.count
        showActionMessage(L10n.text("已忽略 \(app.name) 的 \(app.latestVersionDisplay) 版本", "Ignored \(app.name) version \(app.latestVersionDisplay)"))
    }

    func clearIgnoredAppUpdates() {
        guard canClearIgnoredAppUpdates else { return }
        AppUpdateIgnoreService.clear()
        ignoredAppUpdateCount = 0
        showActionMessage(L10n.text("已恢复显示被忽略的更新，仅影响更新列表，不会安装软件", "Ignored updates are visible again; this only affects the update list and does not install software"))
        refreshAppUpdates()
    }

    func requestOneClickAppUpdates() {
        previewOneClickAppUpdates()
    }

    func previewOneClickAppUpdates() {
        guard canRequestOneClickAppUpdates else { return }

        guard let plan = appUpdateOneClickPlan() else { return }
        pendingOneClickUpdatePlan = plan
    }

    func previewAppUpdate(_ app: AppUpdateItem) {
        guard canRequestOneClickAppUpdates,
              let currentApp = appUpdates.first(where: { $0.id == app.id }),
              currentApp.canJoinAutomaticUpdateBatch else { return }
        let plan = AppUpdateService.oneClickPlan(for: [currentApp])
        guard plan.automaticCount > 0 else { return }
        pendingOneClickUpdatePlan = plan
    }

    func requestAppUpdate(_ app: AppUpdateItem) {
        previewAppUpdate(app)
    }

    func requestAppStoreUpdate(_ app: AppUpdateItem) {
        guard allowsLiveAppUpdateActions,
              !isLoadingAppUpdates,
              !isRunningOneClickUpdate,
              let currentApp = appUpdates.first(where: { $0.id == app.id }),
              currentApp.primaryUpdateProvider == .macAppStore,
              currentApp.sourceEvidence.contains("verified-app-store-receipt"),
              currentApp.effectiveVersionCheckState == .updateAvailable,
              currentApp.availableVersion.map({ currentApp.installedVersion < $0 }) == true
        else { return }
        // App Store software remains system-managed. Opening a validated public
        // product page is an action hand-off, never evidence that an update ran.
        openUpdateEntry(currentApp)
    }

    func cancelOneClickAppUpdates() {
        if isRunningOneClickUpdate {
            appUpdateGracefulQuitConsentSessionID = nil
            appUpdateGracefulQuitRequestedApplicationIDs.removeAll()
            appUpdateRelaunchConsentSessionID = nil
            appUpdateRelaunchTargets.removeAll()
            appUpdateRelaunchAttemptedApplicationIDs.removeAll()
            markApplicationUpdateBatchCancellationRequested()
            if let queue = appUpdateQueueSnapshot {
                appUpdateCancellationRequestedSessionID = queue.plan.id
                publishAppUpdateSession(queue)
            }
            appUpdateOperation?.cancel()
            if appUpdateOperation == nil {
                Task { [applicationUpdateCoordinator] in
                    try? await applicationUpdateCoordinator.cancel()
                }
            }
            appUpdateProgress = AppUpdateProgress(
                title: L10n.text("正在取消更新", "Cancelling updates"),
                detail: L10n.text(
                    "正在等待当前 Provider 在安全边界停止",
                    "Waiting for the active provider to stop at a safe boundary"
                ),
                fraction: 0.9,
                systemImage: "xmark.octagon"
            )
            return
        }
        pendingOneClickUpdatePlan = nil
    }

    func dismissOneClickUpdatePreview() {
        pendingOneClickUpdatePlan = nil
    }

    private func markApplicationUpdateBatchCancellationRequested() {
        guard var context = appUpdateBatchContext,
              context.outcome == .running else { return }
        context.outcome = .cancelRequested
        appUpdateBatchContext = context
    }

    func confirmOneClickAppUpdates(
        reopensUpdatedApplications: Bool = true
    ) {
        guard let plan = pendingOneClickUpdatePlan, canRequestOneClickAppUpdates else { return }

        pendingOneClickUpdatePlan = nil
        runOneClickAppUpdates(
            plan: plan,
            requestsGracefulQuit: true,
            reopensUpdatedApplications: reopensUpdatedApplications
        )
    }

    private func appUpdateOneClickPlan() -> AppUpdateOneClickPlan? {
        if appUpdates.isEmpty {
            showActionMessage(L10n.text("请先检查更新，再执行批量更新", "Check for updates before running a batch update"))
            refreshAppUpdates()
            return nil
        }

        let plan = AppUpdateService.oneClickPlan(for: appUpdates)
        guard !plan.isEmpty else {
            showActionMessage(L10n.text("没有可处理的更新来源", "No update sources to process"))
            return nil
        }

        return plan
    }

    private func runOneClickAppUpdates(
        plan: AppUpdateOneClickPlan,
        requestsGracefulQuit: Bool,
        reopensUpdatedApplications: Bool
    ) {
        guard allowsLiveAppUpdateActions, appUpdateOperation == nil else { return }
        let selectedApps = plan.automaticApps.filter(\.canAutomaticallyUpdate)
        guard !selectedApps.isEmpty else {
            showActionMessage(L10n.text(
                "没有符合安全条件的可自动更新项目",
                "No updates meet the verified automatic-update requirements"
            ))
            return
        }
        stopApplicationUpdateCoordinatorMonitor()
        appUpdateCancellationRequestedSessionID = nil
        isRunningOneClickUpdate = true
        oneClickUpdateResult = nil
        errorMessage = nil
        appUpdateProgress = AppUpdateProgress(
            title: L10n.text("准备批量更新", "Preparing batch update"),
            detail: L10n.text("整理可自动处理项目", "Preparing automatic items"),
            fraction: 0.12,
            systemImage: "wand.and.stars"
        )
        let generation = UUID()
        appUpdateGracefulQuitConsentSessionID = requestsGracefulQuit ? generation : nil
        appUpdateGracefulQuitRequestedApplicationIDs.removeAll()
        appUpdateRelaunchConsentSessionID = requestsGracefulQuit && reopensUpdatedApplications
            ? generation
            : nil
        appUpdateRelaunchTargets.removeAll()
        appUpdateRelaunchAttemptedApplicationIDs.removeAll()
        let frozenPlan = FrozenUpdatePlan(
            applications: plan.applications,
            sessionID: generation
        )
        let queuePlan = frozenPlan.executionPlan
        let presentationToken = beginAppUpdatePresentationSession(sessionID: generation)
        transitionAppUpdatePresentation(
            to: .preparingUpdate(frozenPlan),
            token: presentationToken
        )
        appUpdateGeneration = generation
        appUpdateExpectedSessionID = queuePlan.id
        appUpdateBatchContext = ApplicationUpdateBatchContext(
            generation: generation,
            sessionID: queuePlan.id,
            outcome: .running
        )
        let coordinator = applicationUpdateCoordinator

        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var completedBatchSnapshot: ApplicationUpdateQueueSnapshot?
            appUpdateProgress = AppUpdateProgress(
                title: L10n.text("正在执行更新", "Running updates"),
                detail: L10n.text(
                    "安装将串行执行，单项失败不会中止队列",
                    "Installations run serially; one failure does not stop the queue"
                ),
                fraction: 0.18,
                systemImage: "arrow.triangle.2.circlepath"
            )

            do {
                try checkApplicationUpdateBatchCancellation(generation: generation)
                if let existing = await coordinator.currentSnapshot(),
                   existing.tasks.contains(where: { !$0.state.isTerminal }) {
                    try await coordinator.cancel()
                }
                try checkApplicationUpdateBatchCancellation(generation: generation)
                if let existing = await coordinator.currentSnapshot(),
                   existing.tasks.allSatisfy(\.state.isTerminal) {
                    try await coordinator.clearFinishedSession()
                }
                try checkApplicationUpdateBatchCancellation(generation: generation)

                let events = await coordinator.events()
                appUpdateQueueSnapshot = try await coordinator.start(
                    plan: queuePlan,
                    applications: frozenPlan.applications
                )
                if let appUpdateQueueSnapshot {
                    publishAppUpdateSession(appUpdateQueueSnapshot)
                    requestGracefulQuitForWaitingTasks(appUpdateQueueSnapshot)
                }
                try checkApplicationUpdateBatchCancellation(generation: generation)
                for await event in events {
                    guard appUpdateGeneration == generation else { break }
                    var shouldStopListening = false
                    switch event {
                    case let .started(snapshot), let .snapshotChanged(snapshot),
                         let .paused(snapshot), let .resumed(snapshot):
                        guard snapshot.plan.id == queuePlan.id else { continue }
                        appUpdateQueueSnapshot = snapshot
                        updateApplicationQueueProgress(snapshot)
                        publishAppUpdateSession(snapshot)
                        requestGracefulQuitForWaitingTasks(snapshot)
                    case let .taskChanged(task):
                        guard task.sessionID == queuePlan.id else { continue }
                        applyApplicationUpdateTask(task)
                        requestGracefulQuitIfNeeded(for: task)
                    case let .drained(snapshot):
                        guard snapshot.plan.id == queuePlan.id else { continue }
                        appUpdateQueueSnapshot = snapshot
                        if snapshot.tasks.allSatisfy(\.state.isTerminal) {
                            let cancellationRequested = appUpdateBatchContext?.generation == generation
                                && appUpdateBatchContext?.outcome == .cancelRequested
                            if !cancellationRequested,
                               !Task.isCancelled,
                               !isPreparingApplicationUpdatesForTermination {
                                finishApplicationUpdateQueue(snapshot)
                                completedBatchSnapshot = snapshot
                                if var context = appUpdateBatchContext,
                                   context.generation == generation {
                                    context.outcome = .completed
                                    appUpdateBatchContext = context
                                }
                            }
                            shouldStopListening = true
                        } else {
                            updateApplicationQueueProgress(snapshot)
                        }
                    case let .persistenceFailed(sessionID, detail):
                        guard sessionID == queuePlan.id else { continue }
                        appUpdateScanWarnings.append(detail)
                    case let .restored(snapshot):
                        guard snapshot.plan.id == queuePlan.id else { continue }
                        appUpdateQueueSnapshot = snapshot
                    }
                    if shouldStopListening { break }
                }
                if Task.isCancelled
                    || (appUpdateBatchContext?.generation == generation
                        && appUpdateBatchContext?.outcome == .cancelRequested) {
                    throw CancellationError()
                }
            } catch is CancellationError {
                guard appUpdateGeneration == generation else { return }
                if !isPreparingApplicationUpdatesForTermination {
                    var cancellationPersisted = true
                    do {
                        try await coordinator.cancel()
                    } catch ApplicationUpdateCoordinatorError.noActiveSession {
                        // The user cancelled before a queue snapshot existed.
                    } catch {
                        cancellationPersisted = false
                        errorMessage = L10n.text(
                            "更新已停止，但无法保存取消状态：\(error.localizedDescription)",
                            "Updates stopped, but the cancellation state could not be saved: \(error.localizedDescription)"
                        )
                    }
                    if cancellationPersisted {
                        showActionMessage(L10n.text(
                            "更新队列已取消，未完成项目不会记为成功",
                            "The update queue was cancelled; unfinished items were not marked successful"
                        ))
                    }
                    let cancelledSnapshot: ApplicationUpdateQueueSnapshot? = await coordinator.currentSnapshot()
                    let cancelledReport: AppUpdateReport?
                    if let cancelledSnapshot,
                       cancelledSnapshot.plan.id == generation {
                        cancelledReport = AppUpdateReport(
                            snapshot: AppUpdateSessionSnapshot(
                                queue: cancelledSnapshot,
                                applications: appUpdates
                            )
                        )
                    } else {
                        cancelledReport = nil
                    }
                    pendingAppUpdateReport = nil
                    appUpdateCancellationRequestedSessionID = nil
                    transitionAppUpdatePresentation(
                        to: .cancelled(cancelledReport),
                        token: presentationToken
                    )
                }
            } catch {
                guard appUpdateGeneration == generation else { return }
                errorMessage = error.localizedDescription
                let failureReport: AppUpdateReport
                if let snapshot = await coordinator.currentSnapshot(),
                   snapshot.plan.id == generation {
                    failureReport = AppUpdateReport(
                        snapshot: AppUpdateSessionSnapshot(
                            queue: snapshot,
                            applications: appUpdates
                        ),
                        sessionError: error.localizedDescription
                    )
                } else {
                    failureReport = AppUpdateReport(
                        sessionID: generation,
                        sessionError: error.localizedDescription
                    )
                }
                pendingAppUpdateReport = nil
                appUpdateCancellationRequestedSessionID = nil
                transitionAppUpdatePresentation(
                    to: .failed(failureReport),
                    token: presentationToken
                )
            }

            guard appUpdateGeneration == generation else { return }
            appUpdateGeneration = nil
            appUpdateOperation = nil
            if appUpdateGracefulQuitConsentSessionID == generation {
                appUpdateGracefulQuitConsentSessionID = nil
                appUpdateGracefulQuitRequestedApplicationIDs.removeAll()
            }
            if appUpdateRelaunchConsentSessionID == generation {
                appUpdateRelaunchConsentSessionID = nil
                appUpdateRelaunchTargets.removeAll()
                appUpdateRelaunchAttemptedApplicationIDs.removeAll()
            }
            isRunningOneClickUpdate = false
            appUpdateProgress = nil
            let batchCompleted = appUpdateBatchContext?.generation == generation
                && appUpdateBatchContext?.outcome == .completed
            if appUpdateBatchContext?.generation == generation {
                appUpdateBatchContext = nil
            }
            // The queue executes the immutable click-time snapshot. Rebuild the
            // complete inventory exactly once only after every member reaches a
            // terminal state. Explicit cancellation deliberately leaves the
            if batchCompleted,
               completedBatchSnapshot != nil,
               !Task.isCancelled,
               !isPreparingApplicationUpdatesForTermination {
                appUpdatesAutoRescanPending = true
                refreshAppUpdates()
            }
        }
        appUpdateOperation = operation
    }

    private func checkApplicationUpdateBatchCancellation(generation: UUID) throws {
        guard !Task.isCancelled,
              appUpdateGeneration == generation,
              let context = appUpdateBatchContext,
              context.generation == generation,
              context.outcome == .running else {
            throw CancellationError()
        }
    }

    private func applyApplicationUpdateTask(_ task: ApplicationUpdateTask) {
        guard let index = appUpdates.firstIndex(where: { $0.id == task.applicationID }) else { return }
        let previousStatus = appUpdates[index].updateStatus
        let status: ApplicationUpdateStatus = switch task.state {
        case .queued: .queued
        case .checking: .checking
        case .downloading: .downloading
        case .waitingForQuit: .waitingForQuit
        case .waitingForAuthorization: .waitingForAuthorization
        case .installing: .installing
        case .verifying, .needsReconciliation: .verifying
        case .completed: .completed
        case .skipped: .skipped
        case .cancelled: .cancelled
        case .failed: .failed
        }
        appUpdates[index].updateStatus = status
        if status == .completed, previousStatus != .completed {
            let path = appUpdates[index].bundleURL.path
            Task {
                await AppIconCache.shared.invalidate(path: path)
                NotificationCenter.default.post(name: .storageCleanerAppIconChanged, object: path)
            }
        }
        appUpdates[index].updateError = task.errorDescription ?? task.detail
        if task.state == .waitingForQuit {
            // The targeted execution-time preflight can discover an app that
            // launched after the click-time inventory was captured.
            appUpdates[index].isRunning = true
            appUpdates[index].requiresApplicationQuit = true
        } else if task.state == .queued, previousStatus == .waitingForQuit {
            appUpdates[index].isRunning = false
            appUpdates[index].requiresApplicationQuit = false
        }
    }

    private func requestGracefulQuitForWaitingTasks(
        _ snapshot: ApplicationUpdateQueueSnapshot
    ) {
        guard snapshot.plan.id == appUpdateGracefulQuitConsentSessionID else { return }
        for task in snapshot.tasks where task.state == .waitingForQuit {
            requestGracefulQuitIfNeeded(for: task)
        }
    }

    private func requestGracefulQuitIfNeeded(for task: ApplicationUpdateTask) {
        guard task.state == .waitingForQuit,
              task.sessionID == appUpdateGracefulQuitConsentSessionID,
              !appUpdateGracefulQuitRequestedApplicationIDs.contains(task.applicationID),
              let application = appUpdates.first(where: { $0.id == task.applicationID }) else {
            return
        }
        // One confirmation authorizes one normal-quit request. A refusal or an
        // app that remains open stays waiting for the existing termination event.
        appUpdateGracefulQuitRequestedApplicationIDs.insert(task.applicationID)
        let requestAccepted = applicationUpdateGracefulQuitRequester.requestGracefulQuit(
            for: application
        )
        if requestAccepted,
           task.sessionID == appUpdateRelaunchConsentSessionID,
           let target = ApplicationUpdateRelauncher.Target(application: application) {
            appUpdateRelaunchTargets[task.applicationID] = target
        }
    }

    private func updateApplicationQueueProgress(_ snapshot: ApplicationUpdateQueueSnapshot) {
        let total = max(1, snapshot.tasks.count)
        let terminalCount = snapshot.tasks.filter(\.state.isTerminal).count
        let active = snapshot.tasks.first { !$0.state.isTerminal }
        appUpdateProgress = AppUpdateProgress(
            title: L10n.text("正在执行更新队列", "Running update queue"),
            detail: active?.detail ?? L10n.text("整理更新结果", "Preparing update results"),
            fraction: Double(terminalCount) / Double(total),
            systemImage: "arrow.triangle.2.circlepath"
        )
    }

    private func finishApplicationUpdateQueue(_ snapshot: ApplicationUpdateQueueSnapshot) {
        for task in snapshot.tasks {
            applyApplicationUpdateTask(task)
        }
        let sessionSnapshot = AppUpdateSessionSnapshot(
            queue: snapshot,
            applications: appUpdates
        )
        pendingAppUpdateReport = AppUpdateReport(snapshot: sessionSnapshot)
        publishAppUpdateSession(snapshot, finalizing: true)
        let completed = snapshot.tasks.filter { $0.state == .completed }.count
        let failed = snapshot.tasks.filter { $0.state == .failed }.count
        let cancelled = snapshot.tasks.filter { $0.state == .cancelled }.count
        let providers = Set(snapshot.tasks.map { task in
            appUpdates.first(where: { $0.id == task.applicationID })?.source.trimmed.nonEmpty
                ?? task.providerIdentifier.rawValue
        }).sorted().joined(separator: " / ")
        let executableApplicationIDs = Set(
            snapshot.plan.automaticApplicationIDs + snapshot.plan.requiresQuitApplicationIDs
        )
        let automaticAppStoreTasks = snapshot.tasks.filter {
            $0.providerIdentifier == .macAppStore
                && executableApplicationIDs.contains($0.applicationID)
        }
        let appStoreResult: AppUpdateAppStoreRunResult
        if automaticAppStoreTasks.isEmpty {
            appStoreResult = AppUpdateAppStoreRunResult(
                status: .skipped,
                command: nil,
                detail: L10n.text(
                    "没有 App Store 项目进入自动队列。",
                    "No App Store items entered the automatic queue."
                )
            )
        } else {
            let appStoreCompleted = automaticAppStoreTasks.filter { $0.state == .completed }.count
            let appStoreFailed = automaticAppStoreTasks.filter { $0.state == .failed }.count
            let appStoreCancelled = automaticAppStoreTasks.filter { $0.state == .cancelled }.count
            let appStoreSkipped = automaticAppStoreTasks.filter { $0.state == .skipped }.count
            appStoreResult = AppUpdateAppStoreRunResult(
                status: appStoreCompleted == automaticAppStoreTasks.count ? .succeeded : .failed,
                command: nil,
                detail: L10n.text(
                    "App Store 自动队列：\(appStoreCompleted) 个成功，\(appStoreFailed) 个失败，\(appStoreCancelled) 个取消，\(appStoreSkipped) 个跳过",
                    "App Store automatic queue: \(appStoreCompleted) succeeded, \(appStoreFailed) failed, \(appStoreCancelled) cancelled, \(appStoreSkipped) skipped"
                )
            )
        }
        oneClickUpdateResult = AppUpdateOneClickResult(
            launched: AppUpdateOneClickLaunchResult(
                openedAppStore: false,
                copiedManualReviewList: false
            ),
            appStore: appStoreResult,
            automatic: AppUpdateAutomaticRunResult(
                status: failed == 0 && cancelled == 0 ? .succeeded : .failed,
                command: nil,
                detail: L10n.text(
                    "\(providers)：\(completed) 个成功，\(failed) 个失败，\(cancelled) 个取消",
                    "\(providers): \(completed) succeeded, \(failed) failed, \(cancelled) cancelled"
                )
            ),
            generatedAt: Date()
        )
        showActionMessage(L10n.text(
            "更新完成：\(completed) 个成功，\(failed) 个失败，\(cancelled) 个取消",
            "Updates finished: \(completed) succeeded, \(failed) failed, \(cancelled) cancelled"
        ))
        relaunchApplicationsAfterSuccessfulUpdate(snapshot)
        Task {
            await ApplicationUpdateNotificationService.notifyQueueFinished(
                completed: completed,
                failed: failed,
                cancelled: cancelled
            )
        }
    }

    private func relaunchApplicationsAfterSuccessfulUpdate(
        _ snapshot: ApplicationUpdateQueueSnapshot
    ) {
        guard snapshot.plan.id == appUpdateRelaunchConsentSessionID else { return }
        let targets = snapshot.tasks.compactMap { task -> ApplicationUpdateRelauncher.Target? in
            guard task.state == .completed,
                  !appUpdateRelaunchAttemptedApplicationIDs.contains(task.applicationID),
                  let target = appUpdateRelaunchTargets.removeValue(forKey: task.applicationID) else {
                return nil
            }
            appUpdateRelaunchAttemptedApplicationIDs.insert(task.applicationID)
            return target
        }
        guard !targets.isEmpty else { return }

        let relauncher = applicationUpdateRelauncher
        Task { @MainActor [weak self] in
            for target in targets {
                do {
                    _ = try await relauncher.relaunch(target)
                } catch {
                    guard let self else { return }
                    let detail = L10n.text(
                        "更新已成功，但未能重新打开 \(target.displayName)：\(error.localizedDescription)",
                        "The update succeeded, but \(target.displayName) could not be reopened: \(error.localizedDescription)"
                    )
                    if !appUpdateScanWarnings.contains(detail) {
                        appUpdateScanWarnings.append(detail)
                    }
                    showActionMessage(detail)
                }
            }
        }
    }

    func applicationDidTerminateForUpdates(
        bundleIdentifier: String?,
        bundleURL: URL?
    ) {
        guard ApplicationUpdatePreferences.snapshot().updatesAfterApplicationQuits,
              let snapshot = appUpdateQueueSnapshot,
              snapshot.tasks.contains(where: { $0.state == .waitingForQuit }) else {
            return
        }
        let runningState = ApplicationRunningStateSnapshot.capture()
        let stoppedApplicationIDs = Self.applicationIDsStoppedByTermination(
            applications: appUpdates,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            runningState: runningState
        )
        guard !stoppedApplicationIDs.isEmpty else { return }
        var changed = false
        for index in appUpdates.indices {
            if stoppedApplicationIDs.contains(appUpdates[index].id) {
                appUpdates[index].isRunning = false
                appUpdates[index].requiresApplicationQuit = false
                changed = true
            }
        }
        guard changed else { return }
        let applications = appUpdates
        Task { @MainActor [weak self, applicationUpdateCoordinator] in
            guard let self else { return }
            do {
                appUpdateQueueSnapshot = try await applicationUpdateCoordinator.refreshApplications(applications)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    static func applicationIDsStoppedByTermination(
        applications: [InstalledApplication],
        bundleIdentifier: String?,
        bundleURL: URL?,
        runningState: ApplicationRunningStateSnapshot
    ) -> Set<String> {
        // NSWorkspace normally supplies the exact bundle URL. Without it, a
        // Bundle ID can refer to several installed copies, so fail closed and
        // wait for the next inventory scan instead of releasing every copy.
        guard let bundleURL else { return [] }
        let terminatedPath = ApplicationUpdateGracefulQuitRequester.comparisonKey(
            for: bundleURL
        )
        let stillRunningPaths = Set(
            runningState.normalizedBundlePaths.map {
                ApplicationUpdateGracefulQuitRequester.comparisonKey(
                    for: URL(fileURLWithPath: $0)
                )
            }
        )
        guard !stillRunningPaths.contains(terminatedPath) else { return [] }
        let expectedIdentifier = bundleIdentifier?.trimmed.nonEmpty
        return Set(applications.compactMap { application in
            guard application.isRunning,
                  ApplicationUpdateGracefulQuitRequester.comparisonKey(
                    for: application.bundleURL
                  ) == terminatedPath,
                  expectedIdentifier == nil || application.bundleIdentifier == expectedIdentifier else {
                return nil
            }
            return application.id
        })
    }

    /// Compatibility entry point for menu commands and older callers. The
    /// feature-owned workspace is the only physical scan pipeline; these
    /// published fields are a read-through mirror for legacy presentation
    /// contracts and never feed a second scanner.
    func scanDuplicateFiles() {
        guard canScanDuplicates else { return }
        errorMessage = nil
        actionMessage = nil
        isScanningDuplicates = true
        duplicateScanProgress = .initial
        duplicateScanCoverage = nil
        duplicateScanOutcome = nil
        duplicateFilesWorkspace.startScan()
        mirrorDuplicateWorkspaceState()
    }

    func pauseDuplicateFileScan() {
        duplicateFilesWorkspace.pauseScan()
    }

    func resumeDuplicateFileScan() {
        duplicateFilesWorkspace.resumeScan()
    }

    func cancelDuplicateFileScan() {
        duplicateFilesWorkspace.cancelScan()
    }

    private func mirrorDuplicateWorkspaceState() {
        duplicateWorkspaceMirrorTask?.cancel()
        let mirrorGeneration = UUID()
        duplicateWorkspaceMirrorGeneration = mirrorGeneration
        duplicateWorkspaceMirrorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if duplicateWorkspaceMirrorGeneration == mirrorGeneration {
                    duplicateWorkspaceMirrorGeneration = nil
                    duplicateWorkspaceMirrorTask = nil
                }
            }
            await duplicateFilesWorkspace.waitForCurrentScan()
            guard !Task.isCancelled,
                  duplicateWorkspaceMirrorGeneration == mirrorGeneration else { return }
            duplicateScanProgress = duplicateFilesWorkspace.scanProgress
            duplicateScanCoverage = duplicateFilesWorkspace.scanCoverage
            duplicateScanOutcome = duplicateFilesWorkspace.scanOutcome
            duplicateScanSeconds = duplicateFilesWorkspace.scanSeconds
            duplicateItems = duplicateFilesWorkspace.items
            hasScannedDuplicates = duplicateFilesWorkspace.hasScanned
            isScanningDuplicates = false
            if let error = duplicateFilesWorkspace.errorMessage {
                errorMessage = error
                showActionMessage(error)
            }
            if duplicateFilesWorkspace.phase == .cancelled {
                showActionMessage(L10n.text(
                    "重复文件扫描已取消，保留上次结果。",
                    "Duplicate scan cancelled; previous results were kept."
                ))
            }
        }
    }

    func requestVerifiedDuplicateCleanup(disposition: CleanupDisposition) {
        guard duplicateCleanupTask == nil,
              duplicateRecoveryTask == nil,
              !isPreparingScan,
              !isCleanupExecutionActive,
              pendingCleanPlan == nil,
              !isScanningDuplicates,
              !duplicateFilesWorkspace.isScanning,
              pendingDuplicateCleanPlan == nil else { return }
        let selectedIDs = duplicateFilesWorkspace.selectedItemIDs
        let currentItems = duplicateFilesWorkspace.items
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let generation = UUID()
        duplicateCleanupGeneration = generation
        pendingDuplicateCleanPreflight = nil
        duplicateCleanupReport = nil
        duplicateCleanupRecoveryReport = nil
        errorMessage = nil

        let executor = cleanupExecutor
        duplicateCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if duplicateCleanupGeneration == generation {
                    duplicateCleanupTask = nil
                }
            }
            do {
                let requests = try await Task.detached(priority: .userInitiated) {
                    try VerifiedDuplicateRequestFactory.makeRequests(
                        selectedItemIDs: selectedIDs,
                        items: currentItems,
                        userHomeURL: homeURL
                    )
                }.value
                let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(
                    requests: requests,
                    disposition: disposition,
                    userHomeURL: homeURL
                )
                let report = await executor.preflight(
                    plan: bundle.plan,
                    context: duplicateCleanupContext(bundle: bundle)
                )
                guard duplicateCleanupGeneration == generation else { return }
                guard report.isConfirmable else {
                    duplicateCleanupBundle = nil
                    pendingDuplicateCleanPlan = nil
                    pendingDuplicateCleanPreflight = report
                    errorMessage = L10n.text(
                        "执行前检查拒绝了全部重复副本；文件身份、保留副本或内容可能已变化。",
                        "Preflight rejected every duplicate copy because identity, retained-copy, or content evidence changed."
                    )
                    return
                }
                duplicateCleanupBundle = bundle
                pendingDuplicateCleanPlan = bundle.plan
                pendingDuplicateCleanPreflight = report
                isDuplicateCleanupConfirmationPresented = true
            } catch {
                guard duplicateCleanupGeneration == generation else { return }
                duplicateCleanupBundle = nil
                pendingDuplicateCleanPlan = nil
                pendingDuplicateCleanPreflight = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Cleanup is still executed by the shared safe-cleanup coordinator, but
    /// the feature-owned store supplies the immutable scan snapshot.  The
    /// main ScanResult is deliberately not mutated by this route.
    func requestVerifiedDuplicateCleanup(
        disposition: CleanupDisposition,
        workspace: DuplicateFilesStore
    ) {
        duplicateItems = workspace.items
        requestVerifiedDuplicateCleanup(disposition: disposition)
    }

    func cancelVerifiedDuplicateCleanupConfirmation() {
        guard duplicateCleanupProgress == nil else { return }
        duplicateCleanupGeneration = nil
        duplicateCleanupTask?.cancel()
        duplicateCleanupTask = nil
        duplicateCleanupBundle = nil
        pendingDuplicateCleanPlan = nil
        pendingDuplicateCleanPreflight = nil
        isDuplicateCleanupConfirmationPresented = false
    }

    func confirmVerifiedDuplicateCleanup() {
        guard duplicateCleanupTask == nil,
              let bundle = duplicateCleanupBundle,
              let preflight = pendingDuplicateCleanPreflight,
              preflight.planID == bundle.plan.id,
              preflight.isConfirmable else { return }
        let approvedIDs = Set(preflight.items.compactMap {
            $0.status == .ready ? $0.planItemID : nil
        })
        guard !approvedIDs.isEmpty else { return }

        isDuplicateCleanupConfirmationPresented = false
        let generation = UUID()
        duplicateCleanupGeneration = generation
        duplicateCleanupProgress = CleanupExecutionProgress(
            planID: bundle.plan.id,
            processedItemCount: 0,
            totalItemCount: bundle.plan.items.count,
            movedItemCount: 0,
            skippedItemCount: 0,
            failedItemCount: 0,
            currentRuleID: nil
        )
        let executor = cleanupExecutor
        let activityStore = heavyWorkActivityStore
        duplicateCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await executor.execute(
                plan: bundle.plan,
                context: duplicateCleanupContext(
                    bundle: bundle,
                    approvedPlanItemIDs: approvedIDs
                )
            ) { [weak self] progress in
                await MainActor.run {
                    guard let self,
                          self.duplicateCleanupGeneration == generation else { return }
                    self.duplicateCleanupProgress = progress
                }
            }
            await activityStore.refresh()
            guard duplicateCleanupGeneration == generation else { return }
            defer {
                duplicateCleanupTask = nil
                duplicateCleanupProgress = nil
                pendingDuplicateCleanPlan = nil
                pendingDuplicateCleanPreflight = nil
                duplicateCleanupBundle = nil
            }
            if !CleanReportStore.record(report) {
                errorMessage = L10n.text("回执保存失败；本次已完成的移动仍保留在结果中。", "Receipt saving failed; completed moves remain in this result.")
            }
            duplicateCleanupReport = report
            let movedPaths = Set(report.items.compactMap { item -> String? in
                guard case .moved = item.outcome else { return nil }
                return PathSafety.lexicalPath(item.sourcePath)
            })
            markDuplicateItemsMoved(at: movedPaths)
            duplicateFilesWorkspace.clearSelection()
            showActionMessage(L10n.text(
                "已处理 \(report.summary.movedItemCount) 个重复副本；项目仍可从废纸篓或隔离区恢复。",
                "Handled \(report.summary.movedItemCount) duplicate copies; items remain recoverable from Trash or quarantine."
            ))
        }
    }

    func cancelVerifiedDuplicateCleanupExecution() {
        duplicateCleanupTask?.cancel()
    }

    func requestRestoreLatestVerifiedDuplicateCleanup() {
        guard duplicateCleanupReport?.restorableReceipts.isEmpty == false,
              duplicateRecoveryTask == nil else { return }
        isDuplicateRestoreConfirmationPresented = true
    }

    func cancelRestoreLatestVerifiedDuplicateCleanup() {
        isDuplicateRestoreConfirmationPresented = false
    }

    func confirmRestoreLatestVerifiedDuplicateCleanup() {
        guard let report = duplicateCleanupReport,
              !report.restorableReceipts.isEmpty,
              duplicateRecoveryTask == nil else { return }
        isDuplicateRestoreConfirmationPresented = false
        let recoveryService = cleanupRecoveryService
        let coordinator = heavyWorkCoordinator
        let activityStore = heavyWorkActivityStore
        duplicateRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { duplicateRecoveryTask = nil }
            do {
                let restored = try await coordinator.withLease(owner: .restore) { lease in
                    await recoveryService.restore(report: report, coordinator: coordinator, lease: lease)
                }
                let recovery = restored.recovery
                await activityStore.refresh()
                duplicateCleanupRecoveryReport = recovery
                let restoredPaths = Set(recovery.items.compactMap {
                    $0.outcome == .restored ? PathSafety.lexicalPath($0.originalPath) : nil
                })
                markDuplicateItemsRestored(at: restoredPaths)
                if recovery.persistenceFailure == nil {
                    duplicateCleanupReport = restored.report.restorableReceipts.isEmpty ? nil : restored.report
                } else {
                    errorMessage = L10n.text("恢复结果写入失败，请保留当前回执。", "Recovery result could not be saved. Keep this receipt.")
                }
                showActionMessage(L10n.text(
                    "已恢复 \(recovery.restoredCount) 个重复副本。",
                    "Restored \(recovery.restoredCount) duplicate copies."
                ))
            } catch {
                await activityStore.refresh()
                handleHeavyWorkError(error)
            }
        }
    }

    func dismissVerifiedDuplicateCleanupReport() {
        duplicateCleanupReport = nil
        duplicateCleanupRecoveryReport = nil
    }

    private func duplicateCleanupContext(
        bundle: VerifiedDuplicatePlanBundle,
        approvedPlanItemIDs: Set<UUID>? = nil
    ) -> CleanupExecutionContext {
        CleanupExecutionContext(
            featureConfiguration: cleanupFeatureConfiguration,
            activeSessionID: bundle.sessionID,
            activeRules: bundle.activeRules,
            userHomeURL: FileManager.default.homeDirectoryForCurrentUser,
            excludedURLs: currentV2ExcludedURLs(),
            approvedPlanItemIDs: approvedPlanItemIDs
        )
    }

    private func markDuplicateItemsMoved(at paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for index in duplicateItems.indices
        where paths.contains(PathSafety.lexicalPath(duplicateItems[index].path)) {
            duplicateItems[index].status = .movedToTrash
        }
        duplicateFilesWorkspace.markItemsMoved(at: paths)
    }

    private func markDuplicateItemsRestored(at paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for index in duplicateItems.indices
        where paths.contains(PathSafety.lexicalPath(duplicateItems[index].path)) {
            duplicateItems[index].status = .available
        }
        duplicateFilesWorkspace.markItemsRestored(at: paths)
    }

    func openUpdateEntry(_ app: AppUpdateItem) {
        guard allowsLiveAppUpdateActions else { return }
        let message = AppUpdateService.openUpdateEntry(for: app)
        showActionMessage(message)
    }

    var currentWebsiteUpdateItem: WebsiteUpdateQueueItem? {
        websiteUpdateQueueSnapshot?.items.first { !$0.state.isTerminal }
    }

    func prepareWebsiteUpdateAssistant(applicationIDs: [String]) {
        guard allowsLiveAppUpdateActions, !isPreparingWebsiteUpdateQueue else { return }
        isPreparingWebsiteUpdateQueue = true
        websiteUpdateResultMessage = nil
        let workflow = websiteUpdateWorkflow
        let applications = appUpdates.filter { applicationIDs.contains($0.id) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isPreparingWebsiteUpdateQueue = false }
            do {
                if let restored = try await workflow.restore(applications: applications),
                   restored.items.contains(where: { !$0.state.isTerminal }) {
                    websiteUpdateQueueSnapshot = restored
                } else {
                    websiteUpdateQueueSnapshot = try await workflow.start(applications: applications)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openCurrentWebsiteUpdate() {
        guard allowsLiveAppUpdateActions else { return }
        let workflow = websiteUpdateWorkflow
        websiteUpdateResultMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await workflow.openCurrentWebsite()
                websiteUpdateQueueSnapshot = await workflow.currentSnapshot()
            } catch {
                errorMessage = error.localizedDescription
                websiteUpdateQueueSnapshot = await workflow.currentSnapshot()
            }
        }
    }

    func recheckCurrentWebsiteUpdate() {
        guard allowsLiveAppUpdateActions else { return }
        let workflow = websiteUpdateWorkflow
        websiteUpdateResultMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await workflow.recheckCurrentVersion()
                websiteUpdateQueueSnapshot = await workflow.currentSnapshot()
                switch result {
                case let .updated(version):
                    websiteUpdateResultMessage = L10n.text(
                        "已更新至 \(version.display)",
                        "Updated to \(version.display)"
                    )
                    if let completed = websiteUpdateQueueSnapshot?.items.last(where: {
                        $0.state == .completed && $0.observedVersion == version
                    }), let index = appUpdates.firstIndex(where: { $0.id == completed.applicationID }) {
                        appUpdates[index].installedVersion = version
                        appUpdates[index].updateStatus = .completed
                    }
                case .unchanged:
                    websiteUpdateResultMessage = L10n.text(
                        "尚未检测到新版本",
                        "No new version has been detected yet"
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
                websiteUpdateQueueSnapshot = await workflow.currentSnapshot()
            }
        }
    }

    func deferCurrentWebsiteUpdate() {
        guard allowsLiveAppUpdateActions else { return }
        let workflow = websiteUpdateWorkflow
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await workflow.deferCurrent()
                websiteUpdateResultMessage = nil
                websiteUpdateQueueSnapshot = await workflow.currentSnapshot()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func ignoreCurrentWebsiteUpdate() {
        guard allowsLiveAppUpdateActions else { return }
        let workflow = websiteUpdateWorkflow
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await workflow.ignoreCurrentVersion()
                websiteUpdateResultMessage = nil
                websiteUpdateQueueSnapshot = await workflow.currentSnapshot()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func searchCandidateOfficialWebsite(for app: AppUpdateItem) {
        guard allowsLiveAppUpdateActions else { return }
        do {
            let candidate = try OfficialWebsiteSearchService().candidateSearch(for: app)
            guard NSWorkspace.shared.open(candidate.searchURL) else {
                throw OfficialWebsiteSearchError.invalidSearchURL
            }
            showActionMessage(L10n.text(
                "搜索结果仅用于发现候选来源，不会自动信任或下载",
                "Search results are candidate sources only and are never trusted or downloaded automatically"
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmOfficialWebsite(_ rawValue: String, for app: AppUpdateItem) {
        guard allowsLiveAppUpdateActions else { return }
        let trimmed = rawValue.trimmed
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host?.trimmed.nonEmpty != nil else {
            errorMessage = L10n.text("请输入有效的 HTTPS 官网地址。", "Enter a valid HTTPS official website URL.")
            return
        }

        Task { @MainActor [weak self, officialSourceRegistry] in
            guard let self else { return }
            do {
                try await officialSourceRegistry.confirmWebsite(
                    for: app,
                    homepageURL: url,
                    updatePageURL: url,
                    developerName: app.signingTeamIdentifier
                )
                guard var updated = appUpdates.first(where: { $0.id == app.id }) else { return }
                updated.officialSource = await officialSourceRegistry.source(for: updated)
                updated = await ApplicationUpdateProviderRegistry().classify(updated)
                if let index = appUpdates.firstIndex(where: { $0.id == updated.id }) {
                    appUpdates[index] = updated
                }
                showActionMessage(L10n.text(
                    "已保存用户确认的官网；默认仅允许打开网页",
                    "The user-confirmed website was saved; it may only be opened by default"
                ))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revokeOfficialWebsite(for app: AppUpdateItem) {
        guard allowsLiveAppUpdateActions else { return }
        Task { @MainActor [weak self, officialSourceRegistry] in
            guard let self else { return }
            do {
                try await officialSourceRegistry.revokeUserConfirmation(for: app)
                guard var updated = appUpdates.first(where: { $0.id == app.id }) else { return }
                updated.officialSource = nil
                updated = await ApplicationUpdateProviderRegistry().classify(updated)
                if let index = appUpdates.firstIndex(where: { $0.id == updated.id }) {
                    appUpdates[index] = updated
                }
                showActionMessage(L10n.text("已取消官网确认", "Official website confirmation removed"))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func copyAppUpdateList(_ apps: [AppUpdateItem]) {
        guard !apps.isEmpty else {
            showActionMessage(L10n.text("没有可复制的更新清单", "No update list to copy"))
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UtilityListExportService.appUpdatesMarkdown(for: apps), forType: .string)
        showActionMessage(L10n.text("应用更新清单已复制，仅供复核，不代表已执行更新", "App update list copied for review only; no updates were run"))
    }

    func copyInstalledAppList(_ apps: [InstalledAppItem]) {
        guard !apps.isEmpty else {
            showActionMessage(L10n.text("没有可复制的卸载清单", "No uninstall list to copy"))
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UtilityListExportService.installedAppsMarkdown(for: apps), forType: .string)
        showActionMessage(L10n.text("应用卸载清单已复制，仅供复核，不会卸载应用", "Uninstall list copied for review only; no apps were uninstalled"))
    }

    func copyCleanupHistoryEntry(_ entry: CleanupHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CleanupHistoryService.markdown(for: entry), forType: .string)
        showActionMessage(L10n.text("清理记录已复制，仅记录已移到废纸篓的项目", "Cleanup record copied; it only lists items moved to Trash"))
    }

    func exportReport() {
        guard let result, canExportCurrentScanArtifacts else {
            if result != nil {
                showActionMessage(L10n.text("扫描完成后再导出报告", "Export after the scan finishes"))
                return
            }
            showActionMessage(L10n.text("先完成一次扫描再导出报告", "Scan first, then export a report"))
            return
        }

        do {
            let url = try ScanReportService.export(result: result)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showActionMessage(L10n.text("扫描报告已导出，并已在访达中选中；报告仅记录当前结果", "Scan report exported and selected in Finder; it only records the current results"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportMaintenanceChecklist(plan: SmartMaintenancePlan) {
        guard let result, canExportCurrentScanArtifacts else {
            if result != nil {
                showActionMessage(L10n.text("扫描完成后再导出维护清单", "Export after the scan finishes"))
                return
            }
            showActionMessage(L10n.text("先完成一次扫描再导出维护清单", "Scan first, then export a maintenance checklist"))
            return
        }

        do {
            let url = try MaintenanceChecklistService.export(plan: plan, result: result)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            showActionMessage(L10n.text("维护清单已导出，并已在访达中选中；导出不会执行清理", "Maintenance checklist exported and selected in Finder; exporting does not run cleanup"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportCurrentMaintenanceChecklist() {
        guard let result, canExportCurrentScanArtifacts else {
            showFilter(.overview)
            if result != nil {
                showActionMessage(L10n.text("扫描完成后再导出维护清单", "Export after the scan finishes"))
                return
            }
            showActionMessage(L10n.text("先完成一次扫描再导出维护清单", "Scan first, then export a maintenance checklist"))
            return
        }

        let plan = SmartMaintenanceService.plan(
            result: result,
            appUpdateCount: appUpdates.count,
            hasScannedAppUpdates: appUpdatesLastScannedAt != nil,
            startupItemCount: startupDomainItems
                .flatMap(\.components)
                .filter { $0.actionCapability.canDisableDirectly && $0.state.enablement == .enabled }
                .count,
            hasScannedStartupItems: hasScannedStartupItems,
            memorySnapshot: memorySnapshot,
            hasScannedDuplicates: duplicateFilesWorkspace.hasScanned,
            duplicateCount: duplicateFilesWorkspace.items.count
        )
        exportMaintenanceChecklist(plan: plan)
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showActionMessage(L10n.text("路径已复制，仅用于定位复核", "Path copied for locating and review only"))
    }

    func refreshCleanupHistory() {
        cleanupHistorySummary = CleanupHistoryService.summary()
    }

    func clearCleanupHistory() {
        guard canClearCleanupHistory else { return }
        pendingCleanupRestoreEntry = nil
        CleanupHistoryService.clear()
        refreshCleanupHistory()
        showActionMessage(L10n.text("清理记录已清空，仅移除记录，不会清空废纸篓或删除文件", "Cleanup history cleared; only records were removed, Trash and files were not deleted"))
    }

    var canRestoreLatestCleanup: Bool {
        !isRestoringCleanup
            && !isMovingItemsToTrash
            && !isEmptyingTrash
            && cleanupHistorySummary.latestRestorable != nil
    }

    func requestRestoreLatestCleanup() {
        guard canRestoreLatestCleanup,
              let entry = cleanupHistorySummary.latestRestorable else { return }
        pendingCleanupRestoreEntry = entry
    }

    func cancelRestoreLatestCleanup() {
        pendingCleanupRestoreEntry = nil
    }

    func confirmRestoreLatestCleanup() {
        guard !isRestoringCleanup,
              let entry = pendingCleanupRestoreEntry,
              !entry.restorableMoveRecords.isEmpty else { return }

        pendingCleanupRestoreEntry = nil
        isRestoringCleanup = true
        let records = entry.restorableMoveRecords
        let generation = UUID()
        restoreGeneration = generation
        let coordinator = heavyWorkCoordinator
        let service = scanHeavyWorkService
        let activityStore = heavyWorkActivityStore

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary = try await coordinator.withLease(owner: .restore) { lease in
                    await activityStore.refresh()
                    return try await service.restoreFromTrash(
                        records: records,
                        lease: lease
                    )
                }
                await activityStore.refresh()
                guard restoreGeneration == generation else { return }

                let completedRecordIDs = Set(
                    (summary.restored + summary.missing).map(\.id)
                )
                CleanupHistoryService.removeMoveRecords(
                    entryID: entry.id,
                    recordIDs: completedRecordIDs
                )

                if var current = result, !summary.restored.isEmpty {
                    current.markRestoredFromTrash(
                        paths: Set(summary.restored.map(\.originalPath))
                    )
                    result = current
                }

                refreshCleanupHistory()
                presentRestoreSummary(summary)
            } catch {
                guard restoreGeneration == generation else {
                    await activityStore.refresh()
                    return
                }
                handleHeavyWorkError(error)
                await activityStore.refresh()
            }

            guard restoreGeneration == generation else { return }
            restoreGeneration = nil
            isRestoringCleanup = false
        }
    }

    private func presentRestoreSummary(_ summary: TrashRestoreSummary) {
        let restoredText = L10n.text(
            "已恢复 \(summary.restoredCount) 项到原位置",
            "Restored \(summary.restoredCount) item(s) to their original locations"
        )
        let skippedCount = summary.conflictCount + summary.missingCount + summary.failedCount
        guard skippedCount > 0 else {
            showActionMessage(restoredText)
            return
        }

        errorMessage = L10n.text(
            "\(restoredText)。跳过 \(skippedCount) 项：同名冲突 \(summary.conflictCount)，废纸篓中已不存在 \(summary.missingCount)，恢复失败 \(summary.failedCount)。未覆盖或删除任何现有文件。",
            "\(restoredText). Skipped \(skippedCount): \(summary.conflictCount) name conflict(s), \(summary.missingCount) no longer in Trash, and \(summary.failedCount) failed. No existing files were overwritten or deleted."
        )
    }

    func openTrashFolder() {
        guard NSWorkspace.shared.open(CleanupService.userTrashURL()) else {
            errorMessage = L10n.text("无法打开废纸篓，未删除任何内容", "Could not open Trash; nothing was deleted")
            return
        }
        showActionMessage(L10n.text("已打开废纸篓供复核，尚未清空或删除任何文件", "Trash opened for review; nothing was emptied or deleted"))
    }

    var greenTrashCandidates: [StorageItem] {
        result?.items.filter(\.canMoveToTrash) ?? []
    }

    var canRequestTrashActions: Bool {
        !isPreparingScan
            && !isCheckingTrashSummary
            && !isMovingItemsToTrash
            && !isEmptyingTrash
            && !isRestoringCleanup
    }

    func canRequestTrash(_ item: StorageItem) -> Bool {
        cleanupFeatureConfiguration.mode == .legacy
            && item.canMoveToTrash
            && canRequestTrashActions
    }

    var canRequestGreenTrash: Bool {
        cleanupFeatureConfiguration.mode == .legacy
            && !greenTrashCandidates.isEmpty
            && canRequestTrashActions
    }

    var canRequestEmptyTrash: Bool {
        cleanupFeatureConfiguration.mode == .legacy && canRequestTrashActions
    }

    var canOptimizeMemory: Bool {
        canRequestMemoryQuitActions
    }

    var canRefreshMemory: Bool {
        !isLoadingMemory && !isOptimizingMemory
    }

    var canRefreshEnergyImpact: Bool {
        !isLoadingEnergyImpact
    }

    // A selection is only a draft. Fixture previews may edit it, while every
    // request and confirmation still requires permission to quit real apps.
    var canEditMemorySelection: Bool {
        !isLoadingMemory && !isOptimizingMemory
    }

    var canRequestMemoryQuitActions: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return false }
#endif
        return canEditMemorySelection
    }

    func canRequestMemoryQuit(_ process: MemoryProcess) -> Bool {
        process.canQuit && canRequestMemoryQuitActions
    }

    func canRequestStartupOperation(
        _ candidate: StartupItemsDomain.Candidate,
        operation: StartupItemsDomain.StartupOperationKind
    ) -> Bool {
        guard !isLoadingStartupItems, !isPerformingStartupOperation else { return false }
        switch operation {
        case .enable:
            return candidate.actionCapability.canEnableDirectly
                && (candidate.state.enablement == .disabled
                    || candidate.state.enablement == .temporarilyStopped)
        case .disable:
            return candidate.actionCapability.canDisableDirectly
                && candidate.state.enablement == .enabled
        case .stopCurrentSession:
            guard candidate.actionCapability.canStopCurrentSession else { return false }
            if case .running = candidate.state.process { return true }
            return false
        }
    }

    var canRefreshStartupItems: Bool {
        !isLoadingStartupItems && !isPerformingStartupOperation
    }

    var canUndoLastStartupOperation: Bool {
        lastStartupUndoRecordID != nil
            && lastStartupUndoCandidate != nil
            && !isLoadingStartupItems
            && !isPerformingStartupOperation
    }

    func canRequestUninstall(_ app: InstalledAppItem) -> Bool {
        app.canMoveToTrash
            && !isLoadingInstalledApps
            && !isUninstallingApp
            && !isCleaningRelatedAppFiles
            && pendingRelatedCleanupApp == nil
    }

    var canRefreshInstalledApps: Bool {
        !isLoadingInstalledApps
            && !isUninstallingApp
            && !isCleaningRelatedAppFiles
            && pendingRelatedCleanupApp == nil
    }

    var canScanDuplicates: Bool {
        !isScanningDuplicates
            && !isPreparingScan
            && duplicateCleanupTask == nil
            && duplicateRecoveryTask == nil
            && duplicateFilesWorkspace.canScan
    }

    var canExportCurrentScanArtifacts: Bool {
        result != nil && !isPreparingScan
    }

    var canClearScanHistory: Bool {
        !scanHistorySummary.entries.isEmpty && !isPreparingScan
    }

    var canClearCleanupHistory: Bool {
        !cleanupHistorySummary.entries.isEmpty && canRequestTrashActions
    }

    var canRequestOneClickAppUpdates: Bool {
        allowsLiveAppUpdateActions && !isLoadingAppUpdates && !isRunningOneClickUpdate
    }

    var canRefreshAppUpdates: Bool {
        allowsLiveAppUpdateActions
            && !isLoadingAppUpdates
            && !isRunningOneClickUpdate
            && heavyWorkActivityStore.activeOwner == nil
    }

    var canRunAutomaticAppUpdateRecheck: Bool {
        canRefreshAppUpdates && pendingOneClickUpdatePlan == nil
    }

    var canModifyAppUpdateList: Bool {
        allowsLiveAppUpdateActions && !isLoadingAppUpdates && !isRunningOneClickUpdate
    }

    private var allowsLiveAppUpdateActions: Bool {
#if DEBUG
        !isDebugAppUpdatePresentationFixtureActive
#else
        true
#endif
    }

    func canIgnoreAppUpdate(_ app: AppUpdateItem) -> Bool {
        canModifyAppUpdateList && appUpdates.contains { $0.id == app.id }
    }

    var canClearIgnoredAppUpdates: Bool {
        canModifyAppUpdateList && ignoredAppUpdateCount > 0
    }

    private func completeInitialPermissionCheck() {
        didCompleteInitialPermissionCheck = true
        UserDefaults.standard.set(true, forKey: Self.initialPermissionCheckDefaultsKey)
    }

    private func shouldShowInitialFolderAccessPrompt(after summary: ScanReadinessSummary) -> Bool {
        !summary.isFullDiskAccessVerified
            && summary.folderAuthorizationRequiredCount > 0
            && FolderAccessGrantService.shouldShowInitialPrompt()
    }

    private func showPermissionCheckCompletion(_ summary: ScanReadinessSummary) {
        if summary.isFullDiskAccessVerified, summary.blockedCount == 0 {
            showActionMessage(L10n.text("权限检查完成：完整磁盘访问已生效", "Permission check complete: Full Disk Access is active"))
        } else if summary.blockedCount == 0 {
            showActionMessage(L10n.text("权限检查完成：关键位置可读", "Permission check complete: key locations are readable"))
        } else {
            showActionMessage(L10n.text("权限检查完成：\(summary.blockedCount) 个位置仍受限", "Permission check complete: \(summary.blockedCount) location(s) still limited"))
        }
    }

    private func showActionMessage(_ message: String) {
        actionMessageDismissalTask?.cancel()
        actionMessage = message

        actionMessageDismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(2_400))
            } catch {
                return
            }
            guard let self else { return }
            actionMessage = nil
            actionMessageDismissalTask = nil
        }
    }

    private func handleHeavyWorkError(_ error: Swift.Error) {
        if let coordinatorError = error as? HeavyWorkCoordinator.Error {
            switch coordinatorError {
            case let .busy(activeOwner):
                heavyWorkActivityStore.reportConflict(activeOwner: activeOwner)
                showActionMessage(
                    HeavyWorkActivityStore.conflictMessage(activeOwner: activeOwner)
                )
            case .invalidLease:
                errorMessage = L10n.text(
                    "操作安全凭证已失效，未继续执行。",
                    "The operation safety token expired; no further work was performed."
                )
            }
            return
        }

        if error is CancellationError {
            showActionMessage(L10n.text("操作已取消", "Operation cancelled"))
            return
        }

        errorMessage = error.localizedDescription
    }

    private func removeTrashItemsFromCurrentResult() {
        guard var current = result else { return }
        current.replaceItems(sourceID: "trash_bins", with: [])
        result = current
    }

    private func memoryExecutionMessage(
        _ result: MemoryOptimizationExecutionResult
    ) -> String {
        let verified = result.targetResults.filter {
            $0.outcome == .gracefulQuitSucceeded || $0.outcome == .forceQuitSucceeded
        }.count
        let exitedBeforeRequest = result.targetResults.filter {
            $0.outcome == .targetExitedBeforeRequest
        }.count
        let unresolved = max(0, result.targetResults.count - verified - exitedBeforeRequest)
        return L10n.text(
            "已验证退出 \(verified) 个进程；操作前已退出 \(exitedBeforeRequest) 个；未完成或无法验证 \(unresolved) 个。实际内存变化已单独重测。",
            "Verified \(verified) process exits; \(exitedBeforeRequest) had already exited; \(unresolved) were incomplete or unverifiable. Actual memory change was remeasured separately."
        )
    }

    private func clearPendingMemoryQuitConfirmation() {
        pendingMemoryProcessesToQuit = []
        pendingMemoryQuitSummary = nil
        pendingMemoryOptimizationPlan = nil
        pendingMemoryPlanSnapshot = nil
        isMemoryBatchQuitConfirmationPresentedInMenuBar = false
    }

    private func pruneMemoryProcessSelection(using snapshot: MemorySnapshot) {
        let validIDs = Set(snapshot.selectableQuitProcesses.map(\.id))
        selectedMemoryProcessIDs.formIntersection(validIDs)
    }

    private func memoryOptimizationMessage(for status: MemoryOptimizationStatus) -> String {
        switch status {
        case .completed:
            L10n.text("应用退出已验证，内存状态已重测", "App exits verified and memory status remeasured")
        case .partial:
            L10n.text("部分应用已退出，未完成项已明确列出", "Some apps exited; incomplete items are reported")
        case .cancelled:
            L10n.text("操作已取消，未继续处理剩余应用", "Operation cancelled; remaining apps were not processed")
        case .verificationFailed:
            L10n.text("退出请求已结束，但无法完成内存重测", "Quit requests ended, but memory remeasurement was unavailable")
        case .notNeeded:
            L10n.text("未清空系统缓存，内存状态已刷新", "System cache was not purged; memory status refreshed")
        case .restricted:
            L10n.text("当前操作受系统限制，内存状态已刷新", "The operation is restricted; memory status refreshed")
        case .timedOut:
            L10n.text("等待应用退出超时，已停止等待", "Timed out waiting for app exit")
        case .unavailable:
            L10n.text("内存测量当前不可用", "Memory measurement is unavailable")
        }
    }
}
