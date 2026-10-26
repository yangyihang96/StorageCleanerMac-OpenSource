import AppKit
import Foundation
import FileOperationShared

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

/// What a chart draws for a requested history window.
struct MenuBarDisplayHistorySlice: Equatable, Sendable {
    let points: [MenuBarTelemetryPoint]
    /// The window `points` were prepared for: the requested window, or, while
    /// that one is still being prepared, the window this chart drew last.
    let duration: TimeInterval
    /// The requested window is not prepared yet; `points` and `duration` are
    /// the previous window's.
    let isUpdating: Bool
    /// Facts the sensors pages show, prepared with a telemetry window.
    var summary: MenuBarTelemetryWindowSummary? = nil
}

@MainActor
final class MenuBarMonitorState: ObservableObject {
    @Published fileprivate(set) var snapshot: SystemMonitorSnapshot?
    /// The latest sample that had network rates (BOARD N16-3): a sample
    /// without them keeps the network card's reading (`MenuBarNetworkReadout`).
    private(set) var lastNetworkReading: MenuBarNetworkReading?
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
    /// Prepared with each telemetry window, off the main thread (P2-1).
    private var preparedTelemetrySummaries: [TimeInterval: MenuBarTelemetryWindowSummary] = [:]
    /// The windows whose summary is read: each consumer's most visible
    /// window (the open history's or the page's range, the first of
    /// `MenuBarHistoryDemandPlan.durations`). The other windows (the CPU and
    /// network cards) are only drawn, so no summary is prepared for them. A
    /// window read without a prepared summary is summarized where it is read
    /// (`MenuBarAdvancedStatusView.historySummary`).
    private var summaryDurations: Set<TimeInterval> = []
    /// How a prepared telemetry window is summarized (off the main thread).
    /// Tests replace it to tell a prepared summary from one computed where it
    /// is read.
    var windowSummary: @Sendable ([MenuBarTelemetryPoint]) -> MenuBarTelemetryWindowSummary = {
        MenuBarTelemetryWindowSummary(points: $0)
    }
    /// D39: the prepared windows are the ones kept from the last visible
    /// demand while nothing was on screen. They are drawn as updating until
    /// the windows prepared for the next demand replace them.
    private var keptTelemetry = false
    private var keptMemory = false

    /// At most this many distinct history windows are prepared for display.
    static let maximumDisplayDurationCount = 4

    /// Consumers in registration order, each with its windows in visible
    /// priority order (most visible first).
    private var displayConsumers: [(id: UUID, durations: [TimeInterval])] = []
    /// Requested windows that are not prepared because more than
    /// `maximumDisplayDurationCount` distinct windows were requested. Reading
    /// one of them returns no points; the least visible requests are the ones
    /// dropped.
    private(set) var droppedDisplayDurations: [TimeInterval] = []

    func updateDisplayHistoryConsumer(_ id: UUID, durations: [TimeInterval]) {
        if let index = displayConsumers.firstIndex(where: { $0.id == id }) {
            if durations.isEmpty {
                displayConsumers.remove(at: index)
            } else {
                // A consumer keeps its place when its windows change.
                displayConsumers[index].durations = durations
            }
        } else if !durations.isEmpty {
            displayConsumers.append((id, durations))
        }
        applyDisplayHistoryDemand(displayConsumers.map(\.durations))
    }

    /// `durations` in visible priority order, most visible first.
    func setDisplayHistoryDemand(_ durations: [TimeInterval]) {
        applyDisplayHistoryDemand([durations])
    }

    /// The windows to prepare for the given requests (one list per consumer,
    /// each most visible first): every consumer's most visible window, then
    /// every consumer's second one, and so on, without duplicates, up to
    /// `limit`. The rest is returned as dropped.
    static func selectDisplayDurations(
        _ requests: [[TimeInterval]],
        limit: Int = maximumDisplayDurationCount
    ) -> (kept: [TimeInterval], dropped: [TimeInterval]) {
        var ordered: [TimeInterval] = []
        for rank in 0..<(requests.map(\.count).max() ?? 0) {
            for request in requests where rank < request.count {
                let duration = request[rank]
                guard duration.isFinite, duration > 0, !ordered.contains(duration) else { continue }
                ordered.append(duration)
            }
        }
        let limit = max(0, limit)
        return (Array(ordered.prefix(limit)), Array(ordered.dropFirst(limit)))
    }

    private func applyDisplayHistoryDemand(_ requests: [[TimeInterval]]) {
        let selection = Self.selectDisplayDurations(requests)
        // Set before the unchanged-demand check: the same windows can be
        // asked for in another order. A newly first window gets its summary
        // with the next preparation; until then it is summarized where read.
        summaryDurations = Set(requests.compactMap(\.first)).intersection(selection.kept)
        if selection.dropped != droppedDisplayDurations {
            droppedDisplayDurations = selection.dropped
            if !selection.dropped.isEmpty {
                let kept = selection.kept.map { String(Int($0)) }.joined(separator: ",")
                let dropped = selection.dropped.map { String(Int($0)) }.joined(separator: ",")
                PerformanceTelemetry.logger.notice(
                    "MenuBar history demand exceeds \(Self.maximumDisplayDurationCount, privacy: .public) windows: prepared \(kept, privacy: .public) s, dropped \(dropped, privacy: .public) s"
                )
            }
        }
        // Compare what will be prepared. Comparing the untruncated request
        // made an oversized request look new every time and rebuilt all
        // windows on each call.
        let durations = Set(selection.kept)
        guard durations != displayDurations else { return }
        displayDurations = durations
        preparedTelemetrySourceVersion = nil
        preparedMemorySourceVersion = nil
        displayHistoryGeneration &+= 1
        displayHistoryTask?.cancel()
        displayHistoryTask = nil
        if displayDurations.isEmpty {
            // Nothing is on screen (D39): the last visible demand's windows
            // (at most `maximumDisplayDurationCount`) are kept for the next
            // opening, which draws them at once, as updating, until its own
            // windows are prepared. Nothing is prepared while hidden.
            keptTelemetry = !preparedTelemetry.isEmpty
            keptMemory = !preparedMemory.isEmpty
            MenuBarPresentationTrace.mark("history.kept", {
                let footprint = retainedDisplayHistoryBytes()
                let byWindow = [("telemetry", preparedTelemetry), ("memory", preparedMemory)].flatMap { kind, windows in
                    windows.sorted { $0.key < $1.key }.map { duration, points -> [String: Any] in
                        let window = MenuBarDisplayHistoryFootprint.of([points])
                        return ["kind": kind, "seconds": Int(duration), "points": window.points,
                                "arrayBytes": window.arrayBytes, "sharedReadingBytes": window.sharedReadingBytes]
                    }
                }
                return ["windows": footprint.windows, "points": footprint.points,
                        "arrayBytes": footprint.arrayBytes, "sharedReadingBytes": footprint.sharedReadingBytes,
                        "byWindow": byWindow]
            }())
        }
        // Otherwise the windows of the previous demand stay until the new
        // ones are prepared; the result below replaces them all at once.
        // Dropping them here left a chart empty while its newly selected
        // window was being prepared.
        scheduleDisplayHistory()
    }

    /// Releases the windows kept while nothing is on screen (memory pressure).
    func releaseKeptDisplayHistory() {
        guard displayDurations.isEmpty else { return }
        preparedTelemetry = [:]
        preparedMemory = [:]
        preparedTelemetrySummaries = [:]
        displayedDurations = [:]
        keptTelemetry = false
        keptMemory = false
    }

    func displayHistory(within duration: TimeInterval, memory: Bool = false) -> [MenuBarTelemetryPoint] {
        (memory ? preparedMemory : preparedTelemetry)[duration] ?? []
    }

    /// The buffers of the prepared windows the monitor holds.
    func retainedDisplayHistoryBytes() -> MenuBarDisplayHistoryFootprint {
        MenuBarDisplayHistoryFootprint.of(Array(preparedTelemetry.values) + Array(preparedMemory.values))
    }

    /// The window each chart drew last, by slot. A slot names one chart role
    /// (a metric or a page), so several charts can switch independently.
    private var displayedDurations: [String: TimeInterval] = [:]

    /// What the chart in `slot` draws for `duration`: that window once it is
    /// prepared. While it is still being prepared (a range was just selected),
    /// the window the same chart drew last is returned instead, marked as
    /// updating, so the chart never falls back to empty in between. A window
    /// kept from before the panel was hidden is also marked as updating until
    /// it is prepared again (D39). A chart that has drawn nothing yet starts
    /// empty.
    func displayHistorySlice(
        slot: String,
        within duration: TimeInterval,
        memory: Bool = false
    ) -> MenuBarDisplayHistorySlice {
        let prepared = memory ? preparedMemory : preparedTelemetry
        let key = (memory ? "memory:" : "telemetry:") + slot
        if let points = prepared[duration] {
            displayedDurations[key] = duration
            return MenuBarDisplayHistorySlice(points: points, duration: duration,
                                              isUpdating: memory ? keptMemory : keptTelemetry,
                                              summary: memory ? nil : preparedTelemetrySummaries[duration])
        }
        if let previous = displayedDurations[key], let points = prepared[previous] {
            return MenuBarDisplayHistorySlice(points: points, duration: previous, isUpdating: true,
                                              summary: memory ? nil : preparedTelemetrySummaries[previous])
        }
        return MenuBarDisplayHistorySlice(points: [], duration: duration, isUpdating: false)
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
                let summaryDurations = summaryDurations
                let summarize = windowSummary
                let result = await Task.detached(priority: .userInitiated) {
                    let windows = needsTelemetry
                        ? Dictionary(uniqueKeysWithValues: durations.map { ($0, telemetry.points(within: $0, referenceDate: date)) })
                        : nil
                    return (windows,
                            needsMemory ? Dictionary(uniqueKeysWithValues: durations.map { ($0, memory.points(within: $0, referenceDate: date)) }) : nil,
                            windows?.filter { summaryDurations.contains($0.key) }.mapValues(summarize))
                }.value
                guard !Task.isCancelled, generation == displayHistoryGeneration else { return }
                MenuBarPresentationTrace.measure("monitor.deliver") {
                    objectWillChange.send()
                    if let telemetry = result.0 {
                        preparedTelemetry = telemetry
                        preparedTelemetrySummaries = result.2 ?? [:]
                        preparedTelemetrySourceVersion = telemetryVersion
                        displayTelemetryVersion &+= 1
                        keptTelemetry = false
                    }
                    if let memory = result.1 {
                        preparedMemory = memory
                        preparedMemorySourceVersion = memoryVersion
                        displayMemoryVersion &+= 1
                        keptMemory = false
                    }
                }
            }
            // A task that was superseded before it ran must not clear the
            // handle of the task that replaced it.
            if let self, generation == displayHistoryGeneration {
                displayHistoryTask = nil
            }
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
        if let throughput = snapshot.networkThroughput {
            lastNetworkReading = MenuBarNetworkReading(
                date: snapshot.generatedAt,
                downBytesPerSecond: throughput.downBytesPerSecond,
                upBytesPerSecond: throughput.upBytesPerSecond
            )
        }
        MenuBarPresentationTrace.measure("monitor.update") {
            telemetryHistory.append(historyPoint)
            self.snapshot = snapshot
            telemetrySourceVersion &+= 1
            scheduleDisplayHistory()
        }
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
        let point = MenuBarTelemetryPoint(memorySnapshot: snapshot)
        MenuBarPresentationTrace.measure("monitor.memory") {
            objectWillChange.send()
            memoryTelemetryHistory.append(point)
            memorySourceVersion &+= 1
            scheduleDisplayHistory()
        }
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
    /// D202: the Smart Care part whose result the page on screen shows for
    /// Smart Care's Review; any other choice of page ends it.
    @Published private(set) var smartCareReview: SmartCareModule?

    var selectedFilter: ReviewFilter {
        route.filter
    }

    var selectedUtilityFilter: ReviewFilter {
        route.utilityTool
    }

    /// D202: called right after Smart Care's Review opened its page.
    func beginSmartCareReview(_ part: SmartCareModule) {
        smartCareReview = part
    }

    /// D202: ends a Review. Another page ends it (`update`); the sidebar's
    /// rows end it even for the page on screen. Without one it publishes
    /// nothing.
    func endSmartCareReview() {
        if smartCareReview != nil { smartCareReview = nil }
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
        // D202: another page ends a Review. Choosing the page on screen again
        // does not: `ContentView` echoes `showFilter`'s `requestedFilter` a
        // moment later (r42: that echo ended every Review at once).
        endSmartCareReview()
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
    @Published private(set) var cleanupScanSession: ScanSession? {
        didSet {
            if cleanupScanSession == nil {
                systemCacheInventoryTask?.cancel()
                systemCacheInventory = nil
                pendingSystemCacheClear = nil
            }
            // Retain only scalar totals for menu summaries. Candidate walks
            // happen once per result mutation, never during panel opening.
            currentCleanupHistoryEntry = cleanupScanSession.flatMap { session in
                guard session.outcome != .cancelled,
                      session.coversCleanupCandidates else { return nil }
                return ScanHistoryService.entry(from: session)
            }
        }
    }
    private var currentCleanupHistoryEntry: ScanHistoryEntry?

    /// D68: newest covered history or current result; clearing history does
    /// not turn a still-loaded junk result into an unscanned zero.
    var latestSafeCleanupEntry: ScanHistoryEntry? {
        guard let current = currentCleanupHistoryEntry else { return scanHistorySummary.latestCleanupEntry }
        if let previous = scanHistorySummary.latestCleanupEntry, previous.date > current.date {
            return previous
        }
        return current // Loaded, possibly cleaned totals win a date tie.
    }
    @Published private(set) var developerInactivityThresholdDays: Int
    @Published private(set) var selectedSmartScanScopes = SmartScanScope.defaultSelection
    @Published private(set) var smartScanHealthSnapshot: ComputerHealthSnapshot?
    @Published private(set) var selectedSafeCleanupScopes = SafeCleanupScanScope.defaultSelection
    /// D202: the Smart Care parts whose result in the shared stores came from
    /// Smart Care's own scan (kept across launches, as the duplicates result is).
    @Published private(set) var smartCareResultParts: Set<SmartCareModule> = []
    /// D202: the part Smart Care is scanning; its calls into the modules'
    /// entry points are Smart Care's own.
    @Published private(set) var smartCareScanningPart: SmartCareModule?
    /// D202: Smart Care's coordinator hears when a module's own scan replaced
    /// one of its parts.
    var onModuleScanReplacedSmartCarePart: (@MainActor (SmartCareModule) -> Void)?
    /// D202: set while Smart Care starts its junk scan.
    private var startsSmartCareJunkScan = false
    @Published private(set) var cleanupSelection = CleanupSelection()
    @Published private(set) var cleanupDryRunSummary: CleanupDryRunSummary?
    @Published private(set) var isCancellingMainScan = false
    @Published private(set) var cleanupWorkflowState = CleanupWorkflowState.idle
    @Published private(set) var pendingCleanPlan: CleanPlan?
    @Published private(set) var pendingCleanPreflight: CleanPreflightReport?
    @Published private(set) var cleanupExecutionProgress: CleanupExecutionProgress?
    @Published private(set) var lastCleanReport: CleanReport?
    /// The cleanup result that "完成" may leave for the results (review P2-1):
    /// the receipt this scan's cleanup published and the presentation token
    /// it was shown under. Another feature's receipt, or a scan started
    /// since, cannot reopen the results.
    private var cleanupResultReturn: (reportID: UUID, presentationSessionID: UUID)?
    /// A2: owner apps listed for the user to confirm before they quit.
    @Published private(set) var cleanupOwnerQuitRequest: CleanupOwnerQuitRequest?
    @Published private(set) var isQuittingCleanupOwners = false
    /// A2: the frozen plan is being checked again (the sheet stays open).
    @Published private(set) var isRecheckingCleanup = false
    @Published private(set) var cleanupRecoveryReport: CleanupRecoveryReport?
    @Published private(set) var operationReports: [CleanupReportIndex] = []
    @Published private(set) var operationReportDetail: CleanReport?
    @Published private(set) var isLoadingOperationReports = false
    @Published private(set) var hasMoreOperationReports = false
    private var operationReportCursor: CleanupReportIndex.Cursor?
    private var operationDetailRequest: UUID?
    private var loadsDefaultCleanReports = true
    @Published private(set) var operationReportWarning: String?
    /// Why receipts left unresolved by an interrupted move or restore remain so.
    @Published private(set) var operationReconcileNotice: OperationReconcileNotice?
    private var queuedOperationReportRefresh: Bool?
    /// Retain receipt workers so tests can join physical reads and queued refreshes.
    private var operationReportTasks: [UUID: Task<Void, Never>] = [:]
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
    @Published private(set) var systemCacheInventory: SystemCacheInventoryReply?
    @Published private(set) var pendingSystemCacheClear: SystemCacheClearPlan?
    @Published private(set) var isClearingSystemCaches = false
    @Published private(set) var systemCacheResultMessage: String?
    private let systemCacheService: any SystemCacheServicing
    private var systemCacheInventoryTask: Task<Void, Never>?
    @Published private(set) var monitoringHistoryWarning: String?
    private var actionMessageDismissalTask: Task<Void, Never>?
    let navigationState = AppNavigationState()
    @Published var selectedItemID: String?
    @Published var preferredItemScopeFilter: ItemScopeFilter?
    @Published var requestedFilter: ReviewFilter?
    @Published var memoryShowsAllProcesses = true
    @Published var pendingTrashItem: StorageItem?
    @Published var pendingBulkTrashItems: [StorageItem] = []
    /// D101 L5: the Trash frozen for the open confirmation.
    @Published var pendingEmptyTrash: FrozenTrash?
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
    /// True while "释放内存" pushes (D144), as opposed to quitting apps.
    @Published private(set) var isReclaimingMemory = false
    @Published var memoryOptimizationResult: MemoryOptimizationResult?
    @Published var selectedMemoryProcessIDs: Set<Int32> = []
    @Published var pendingMemoryProcess: MemoryProcess?
    @Published var pendingMemoryProcessesToQuit: [MemoryProcess] = []
    @Published var pendingMemoryQuitSummary: MemoryQuitSelectionSummary?
    @Published private(set) var pendingMemoryOptimizationPlan: MemoryOptimizationPlan?
    @Published private(set) var memoryOptimizationState: MemoryOptimizationState = .idle
    @Published var isMemoryBatchQuitConfirmationPresentedInMenuBar = false
    /// BOARD N19: when the recommended memory action turned into "退出高占用应用".
    /// A click on the changed button inside `recommendedMemoryActionDebounce`
    /// (the second half of a double click) is ignored.
    private var recommendedMemorySelectionPreparedAt: TimeInterval?
    /// Monotonic seconds for the recommended action's debounce (tests set it).
    var memoryActionUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The latest process measurement for the mini window's CPU, disk and
    /// power pages. It is kept while the panel is hidden (BOARD N16-2, as
    /// D39 keeps the history windows): a page shows it at once, with its
    /// sample time, while the next measurement is taken.
    @Published private(set) var menuBarPreparedProcesses: MenuBarPreparedProcesses?
    /// A process page is waiting for its first measurement and has none to
    /// show yet ("正在采样…", not "未测量"). D171: on the CPU and disk pages
    /// only while the first read runs; it is listed at once, rates 0.
    @Published private(set) var isMenuBarProcessSamplePending = false
    /// Review P2-8: the first measurement did not come within
    /// `menuBarProcessSampleTimeout`; the page says "未测量" and why.
    @Published private(set) var isMenuBarProcessSampleUnavailable = false
    private let menuBarProcessSampleTimeout: TimeInterval
    @Published private(set) var menuBarPreparedMemoryApps: [MemoryAppUsage] = []
    private(set) var menuBarPreparedMemoryAppsVersion: UInt64 = 0
    private var menuBarPreparedMemoryAppsDate: Date?
    var menuBarPreparedMemoryAppsSampledAt: Date? { menuBarPreparedMemoryAppsDate }
    /// The process counter reader of the mini window's process pages
    /// (injected at init; review P2-12).
    private let menuBarContinuousProcessSampler: MenuBarProcessSampler
    private(set) var menuBarProcessDemand: PanelSection = .overview
    private var menuBarVisibleProcessTask: Task<Void, Never>?
    private var menuBarProcessSampleTimeoutTask: Task<Void, Never>?
    private var menuBarVisibleProcessGeneration = 0
    private var menuBarResidentContext: MenuBarSamplingContext?
    private var menuBarResidentPrimaryGeneration = 0
    private var menuBarResidentFirstAttemptAt: Date?
    private var menuBarResidentProcessStartedAt: Date?
    /// D127: a page change asks the next read to start from a new baseline.
    private var menuBarResidentProcessBaselineReset = false
    private var menuBarResidentMemoryStartedAt: Date?
    private var menuBarResidentHelperTask: Task<Void, Never>?

    func attachMenuBarResidentSampling(_ context: MenuBarSamplingContext) {
        menuBarResidentContext = context
        menuBarAuxiliaryMonitorState.attachSamplingContext(context)
        helperPowerMetricsMonitor.useResidentScheduler()
    }

    /// Called by the sole resident clock; starting a finite worker never blocks
    /// that clock on ps/nettop/XPC.
    /// D127 (iStat `-[ItemManager startItemsForKey:]` / `stopItemsForKey:`):
    /// process lists are read only while a module page that shows one is open
    /// — at once, again after 0.5 s, then on each tick — and not prestored
    /// while the panel is closed (was every 10 s open / 15 s closed, D74).
    func refreshMenuBarResidentSamples(now: Date = Date()) {
        guard let cadence = menuBarResidentContext?.plan?.cadence,
              !cadence.suspended, !isMenuBarRefreshPaused else { return }
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        let readsProcessFrame = [.processor, .disk, .power].contains(menuBarProcessDemand)
        let processSpacing = MenuBarPerformancePolicy.processSpacing(cadence.processes, tick: cadence.cheap)
        if readsProcessFrame, menuBarPreparedProcesses == nil,
           let first = menuBarResidentFirstAttemptAt, now.timeIntervalSince(first) >= menuBarProcessSampleTimeout {
            setMenuBarProcessSampleState(pending: false, unavailable: true)
        }
        menuBarAuxiliaryMonitorState.refreshResidentSamples()
        if readsProcessFrame, menuBarVisibleProcessTask == nil,
           MenuBarPerformancePolicy.isDue(since: menuBarResidentProcessStartedAt, now: now, interval: processSpacing) {
            menuBarResidentProcessStartedAt = now
            if menuBarResidentFirstAttemptAt == nil { menuBarResidentFirstAttemptAt = now }
            let generation = menuBarVisibleProcessGeneration
            let sampler = menuBarContinuousProcessSampler
            let needsFirstDelta = menuBarPreparedProcesses == nil
            let listsFirstRead = needsFirstDelta && MenuBarProcessSamplingDemand.listsFirstRead(menuBarProcessDemand)
            // D127: the baseline is dropped inside the read, so no earlier
            // frame can pair with the first read of a newly opened page.
            let resetsBaseline = menuBarResidentProcessBaselineReset
            menuBarResidentProcessBaselineReset = false
            menuBarVisibleProcessTask = Task { @MainActor [weak self] in
                var prepared = await Self.readMenuBarProcesses(sampler, resettingBaseline: resetsBaseline,
                                                               listingFirstRead: listsFirstRead)
                if needsFirstDelta, prepared?.isFirstRead ?? true, !Task.isCancelled {
                    // D171: the first read is shown while the first delta is
                    // taken 0.5 s later; this task keeps the single flight.
                    if let prepared { self?.adoptFirstMenuBarProcessRead(prepared, generation: generation) }
                    try? await Task.sleep(for: .seconds(MenuBarPerformancePolicy.firstProcessSampleInterval))
                    if !Task.isCancelled {
                        prepared = await Self.readMenuBarProcesses(sampler, resettingBaseline: false,
                                                                   listingFirstRead: listsFirstRead)
                    }
                }
                guard let self else { return }
                menuBarVisibleProcessTask = nil
                guard !Task.isCancelled, generation == menuBarVisibleProcessGeneration,
                      menuBarResidentContext?.plan?.cadence.suspended == false else {
                    // D127: another page superseded this read. Its first read
                    // waited for this physical read to exit; start it now.
                    if generation != menuBarVisibleProcessGeneration { refreshMenuBarResidentSamples() }
                    return
                }
                if let prepared { adoptMenuBarProcesses(prepared) }
            }
        }
        if menuBarProcessDemand == .memory, menuBarMemoryProcessTask == nil,
           MenuBarPerformancePolicy.isDue(since: menuBarResidentMemoryStartedAt, now: now, interval: processSpacing) {
            menuBarResidentMemoryStartedAt = now
            refreshMenuBarMemoryProcesses(now: now)
        }
        helperPowerMetricsMonitor.setResidentCadence(cadence)
        if menuBarResidentHelperTask == nil {
            menuBarResidentHelperTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { menuBarResidentHelperTask = nil }
                await helperPowerMetricsMonitor.sampleIfDue()
            }
        }
    }

    func suspendMenuBarResidentSampling() {
        menuBarResidentPrimaryGeneration &+= 1
        menuBarMemoryStatusGeneration &+= 1
        menuBarMemoryStatusTask?.cancel()
        let primarySampler = SystemMonitorSampler.shared
        Task { await primarySampler.suspendResidentSampling() }
        menuBarVisibleProcessGeneration &+= 1
        // Keep handles until physical reads exit: cancel cannot free the gate.
        menuBarVisibleProcessTask?.cancel()
        cancelMenuBarMemoryProcessRefresh()
        menuBarResidentHelperTask?.cancel()
        helperPowerMetricsMonitor.setResidentSuspended(true)
        menuBarAuxiliaryMonitorState.suspendResidentSamples()
        menuBarResidentProcessStartedAt = nil
        menuBarResidentMemoryStartedAt = nil
        // D127: the next read also drops the baseline itself, in order.
        menuBarResidentProcessBaselineReset = true
        let sampler = menuBarContinuousProcessSampler
        Task { await sampler.reset() }
    }
    lazy var helperPowerMetricsMonitor = HelperPowerMetricsMonitor(
        availability: { [weak self] in
            guard let helper = self?.fanControlCoordinator else { return .needsHelper }
            helper.refreshStatus()
            if helper.macMiniHelperNeedsUpdate { return .needsUpdate }
            return helper.helperStatus == .enabled && !helper.isDataOnlyFixture ? .ready : .needsHelper
        },
        request: { [weak self] in
            guard let helper = self?.fanControlCoordinator else { return .failure(.unavailable) }
            return await helper.samplePowerMetrics()
        }
    )
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
            appPreferences.set(menuBarRefreshInterval.rawValue, forKey: Self.menuBarRefreshIntervalDefaultsKey)
        }
    }
    @Published var isMenuBarRefreshPaused = false
    @Published var installedApps: [InstalledAppItem] = []
    let applicationsScanCoordinator = ApplicationsScanCoordinator()
    @Published var isLoadingInstalledApps = false
    @Published var hasScannedInstalledApps = false
    @Published var installedAppsScanCoverage: AppUninstallScanCoverage?
    @Published var isUninstallingApp = false
    @Published var isPreparingUninstall = false
    @Published private(set) var residualUninstallReport: CleanReport?
    @Published var uninstallSelectedPaths = Set<String>()
    private var uninstallPreparationID: UUID?
    private var uninstallPreparationTask: Task<Void, Never>?
    /// While an uninstall runs: the saved receipts plus the running one.
    @Published private(set) var uninstallProgress: UninstallReviewResult?
    /// After it ends. Never set while `isUninstallingApp` (see `publishUninstallReview`).
    @Published private(set) var uninstallResult: UninstallReviewResult?
    /// Saved receipts of this review: the original run, then each retry.
    /// The review shows them merged by path; restore covers them all.
    @Published private(set) var uninstallResultReports: [CleanReport] = []
    private var uninstallInFlightReport: CleanReport?
    @Published var isCancellingUninstall = false
    private var uninstallTask: Task<Void, Never>?
    private var uninstallSessionID: UUID?
    private var confirmedUninstallPlan: UninstallPlan?
    private(set) var completedUninstallApplication: CleanupMoveReceipt?

    @Published var uninstallPermissionDenied = false
    @Published var uninstallDeniedApp: InstalledAppItem?
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
    @Published private(set) var externalUpdateRecheckingIDs: Set<String> = []
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
    /// D100 G5: roots the current scan could not read that are readable now.
    @Published private(set) var accessReturnNotice: ScanAccessReturnNotice?
    private var accessReturnTracker = ScanAccessReturnTracker()
    private var accessReturnCheckTask: Task<Void, Never>?

    private var menuBarNetworkSample: NetworkMonitorSample?
    private var menuBarMemoryStatusSnapshot: MemorySnapshot?
    private var menuBarMemorySnapshotRefreshedAt: Date?
    private let fanControlProvider: @MainActor () -> FanControlCoordinator
    private lazy var fanControlCoordinator = fanControlProvider()
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
    private let readableDirectories: @Sendable ([String]) -> Set<String>
    private let historyLoader: any ScanStoreHistoryLoading
    /// Where the scan history is written and read (tests isolate it).
    private let appPreferences: UserDefaults
    /// D207: the ignore list the scans read and the managers add to — the
    /// app's own file; none in tests unless a test gives one.
    var ignoreListStore: IgnoreListStore?
    /// D207 (CleanMyMac's Add to Ignore List): the note after a manager adds
    /// rows, with Put Back.
    lazy var ignoreFeedback = IgnoreListFeedback { [weak self] in self?.ignoreListStore }
    private let samplingGaps: MenuBarSamplingGaps
    private let scanHistoryDefaults: UserDefaults
    private let memoryCoordinator: MemoryCoordinator
    let heavyWorkCoordinator: HeavyWorkCoordinator
    let heavyWorkActivityStore: HeavyWorkActivityStore
    private let scanHeavyWorkService: ScanHeavyWorkService
    let cleanupFeatureConfiguration: CleanupFeatureConfiguration
    private let smartScanHealthOperation: SmartScanHealthOperation
    private let cleanupScanOperation: CleanupScanOperation
    private let cleanupRuleSetLoader: @Sendable () throws -> CleanupRuleSet
    private let cleanupPreferences: UserDefaults
    private let cleanupExecutor: SafeCleanupExecutor
    /// The home the cleanup scan and its execution checks work in (fixtures
    /// inject a temporary one).
    private let cleanupUserHomeURL: URL
    /// A2: running and installed apps, read again to refresh row owners.
    private let cleanupApplicationEnvironment: any CleanupApplicationEnvironment
    /// A2: asks owner apps to quit normally (never forced).
    private let cleanupOwnerQuitService: CleanupOwnerQuitService
    private let cleanupRecoveryService: CleanupRecoveryService
    private let interruptedOperationReconciler: @Sendable () -> Set<CleanupReportJournal.ReconcileIssue>
    private let operationJournal: CleanupReportJournal
    /// D154: My Activity totals the same journal Operation History lists.
    var activityJournal: CleanupReportJournal { operationJournal }
    /// The Trash that recorded restores read from (injected by fixtures).
    private let operationTrashURL: URL
    /// How uninstalls move files and request authorization (injected by fixtures).
    private let uninstallMoves: UninstallMoveEnvironment
    private var didStartLaunchReconcile = false
    private var cleanupActiveRuleSet: CleanupRuleSet?
    private var cleanupPlanTask: Task<Void, Never>?
    private var cleanupExecutionTask: Task<Void, Never>?
    private var cleanupPlanGeneration: UUID?
    private var cleanupExecutionGeneration: UUID?
    private var cleanupRecoveryTask: Task<Void, Never>?
    private var cleanupRecoveryGeneration: UUID?
    private var mainScanGeneration: UUID?
    private var mainScanTask: Task<Void, Never>?
    private var mainScanUsesRules = false
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
        largeFilesStorageMapTargets: [StorageMapScanTarget]? = nil,
        largeFilesStorageAnalysisOperation: LargeFilesStore.StorageAnalysisOperation? = nil,
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
        readableDirectories: @escaping @Sendable ([String]) -> Set<String> = {
            ScanReadinessService.readableDirectories($0)
        },
        historyLoader: any ScanStoreHistoryLoading = UserDefaultsScanStoreHistoryLoader(),
        scanHistoryDefaults: UserDefaults = .standard,
        metricHistoryStore: MetricHistoryStore? = nil,
        systemEnergyAccumulator: SystemEnergyAccumulator? = nil,
        menuBarPowerHistoryURL: URL? = MenuBarPowerHistoryStore.defaultURL,
        samplingGaps: MenuBarSamplingGaps = .shared,
        preferences: UserDefaults = .standard,
        fileAnalysisTrashEnvironment: FileAnalysisTrashEnvironment = .live,
        memoryCoordinator: MemoryCoordinator? = nil,
        fanControlProvider: @escaping @MainActor () -> FanControlCoordinator = { FanControlCoordinator.shared },
        menuBarMemoryStatusProvider: @escaping @Sendable () async -> MemorySnapshot = {
            await MemoryOptimizerService.statusSnapshot()
        },
        menuBarMemoryProcessProvider: @escaping @Sendable () async -> MemorySnapshot = {
            await MemoryOptimizerService.snapshot()
        },
        menuBarProcessSampler: MenuBarProcessSampler = MenuBarProcessSampler(),
        menuBarProcessSampleTimeout: TimeInterval = MenuBarPerformancePolicy.processSampleTimeout,
        startupScanCoordinator: StartupScanCoordinator = StartupScanCoordinator(),
        startupItemManager: StartupItemsDomain.UserLaunchAgentManager? = nil,
        applicationInventoryScanner: any ApplicationInventoryScanning = ApplicationInventoryScanner(),
        applicationUpdateCoordinator: ApplicationUpdateCoordinator? = nil,
        applicationUpdateGracefulQuitRequester: ApplicationUpdateGracefulQuitRequester? = nil,
        applicationUpdateRelauncher: ApplicationUpdateRelauncher? = nil,
        websiteUpdateWorkflow: WebsiteUpdateWorkflow? = nil,
        cleanupFeatureConfiguration: CleanupFeatureConfiguration = .productDefault,
        cleanupScanOperation: @escaping CleanupScanOperation = CleanupScanOperations.live,
        systemCacheService: (any SystemCacheServicing)? = nil,
        smartScanHealthOperation: @escaping SmartScanHealthOperation = {
            try await DefaultComputerHealthProbe().probe()
        },
        cleanupRuleSetLoader: @escaping @Sendable () throws -> CleanupRuleSet = {
            try CleanupRuleSetLoader.loadBundled()
        },
        cleanupPreferences: UserDefaults = .standard,
        cleanupExecutor: SafeCleanupExecutor? = nil,
        cleanupUserHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        cleanupApplicationEnvironment: any CleanupApplicationEnvironment = WorkspaceCleanupApplicationEnvironment(),
        cleanupOwnerQuitService: CleanupOwnerQuitService? = nil,
        cleanupRecoveryService: CleanupRecoveryService = CleanupRecoveryService(),
        cleanReportLoader: (() -> [CleanReport])? = nil,
        interruptedOperationReconciler: @escaping @Sendable () -> Set<CleanupReportJournal.ReconcileIssue> = {
            CleanupReportJournal.live.reconcileInterruptedOperations()
        },
        operationJournal: CleanupReportJournal = .live,
        operationTrashURL: URL = CleanupService.userTrashURL(),
        uninstallMoves: UninstallMoveEnvironment = .live
    ) {
        self.appPreferences = preferences
        self.ignoreListStore = preferences === UserDefaults.standard ? IgnoreListStore.shared : nil
        self.samplingGaps = samplingGaps
        self.cleanupPreferences = cleanupPreferences
#if DEBUG
        // Inert presentation captures do not read or overwrite saved checkbox state.
        if FeaturePresentationDemo.isEnabled {
            selectedSmartScanScopes = SmartScanScope.defaultSelection
            selectedSafeCleanupScopes = SafeCleanupScanScope.defaultSelection
        } else {
            selectedSmartScanScopes = SmartScanScope.selection(in: cleanupPreferences)
            selectedSafeCleanupScopes = SafeCleanupScanScope.selection(in: cleanupPreferences)
            smartCareResultParts = Self.smartCareResultParts(in: cleanupPreferences)
        }
#else
        selectedSmartScanScopes = SmartScanScope.selection(in: cleanupPreferences)
        selectedSafeCleanupScopes = SafeCleanupScanScope.selection(in: cleanupPreferences)
        smartCareResultParts = Self.smartCareResultParts(in: cleanupPreferences)
#endif
        self.fanControlProvider = fanControlProvider
        self.menuBarMemoryStatusProvider = menuBarMemoryStatusProvider
        self.menuBarMemoryProcessProvider = menuBarMemoryProcessProvider
        self.menuBarContinuousProcessSampler = menuBarProcessSampler
        self.menuBarProcessSampleTimeout = menuBarProcessSampleTimeout
        developerInactivityThresholdDays = DeveloperCleanupAgePolicy.normalizedThresholdDays(
            cleanupPreferences.integer(forKey: Self.developerInactivityThresholdDefaultsKey)
        )
        self.metricHistoryStore = metricHistoryStore
        self.systemEnergyAccumulator = systemEnergyAccumulator ?? SystemEnergyAccumulator(samplingGaps: samplingGaps)
        menuBarMonitorState = MenuBarMonitorState(
            metricHistoryStore: metricHistoryStore
        )
        menuBarAuxiliaryMonitorState = MenuBarAuxiliaryMonitorState(
            metricHistoryStore: metricHistoryStore,
            powerHistoryURL: metricHistoryStore == nil
                ? menuBarPowerHistoryURL
                : nil
        )
        self.heavyWorkCoordinator = heavyWorkCoordinator
        self.systemCacheService = systemCacheService ?? SystemCacheService(coordinator: heavyWorkCoordinator)
        let resolvedActivityStore = heavyWorkActivityStore
            ?? HeavyWorkActivityStore(coordinator: heavyWorkCoordinator)
        self.heavyWorkActivityStore = resolvedActivityStore
        self.duplicateFilesWorkspace = DuplicateFilesStore(
            defaults: preferences,
            coordinator: heavyWorkCoordinator,
            activityStore: resolvedActivityStore,
            scanOperation: duplicateFilesScanOperation,
            userHomeURL: cleanupUserHomeURL
        )
        self.largeFilesWorkspace = LargeFilesStore(
            coordinator: heavyWorkCoordinator,
            activityStore: resolvedActivityStore,
            defaults: preferences,
            scanOperation: largeFilesScanOperation,
            storageMapTargets: largeFilesStorageMapTargets,
            storageAnalysisOperation: largeFilesStorageAnalysisOperation,
            trashEnvironment: fileAnalysisTrashEnvironment
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
        self.readableDirectories = readableDirectories
        self.historyLoader = historyLoader
        self.scanHistoryDefaults = scanHistoryDefaults
        self.memoryCoordinator = memoryCoordinator ?? MemoryCoordinator()
        self.cleanupFeatureConfiguration = cleanupFeatureConfiguration
        self.cleanupScanOperation = cleanupScanOperation
        self.smartScanHealthOperation = smartScanHealthOperation
        self.cleanupRuleSetLoader = cleanupRuleSetLoader
        self.cleanupExecutor = cleanupExecutor ?? SafeCleanupExecutor(
            coordinator: heavyWorkCoordinator,
            persistReport: { report, identities in
                try CleanupReportJournal.live.checkpoint(report, expectedIdentities: identities)
            }
        )
        self.cleanupUserHomeURL = cleanupUserHomeURL
        self.cleanupApplicationEnvironment = cleanupApplicationEnvironment
        self.cleanupOwnerQuitService = cleanupOwnerQuitService ?? CleanupOwnerQuitService()
        self.cleanupRecoveryService = cleanupRecoveryService
        self.interruptedOperationReconciler = interruptedOperationReconciler
        self.operationJournal = operationJournal
        self.operationTrashURL = operationTrashURL
        self.uninstallMoves = uninstallMoves
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
        // D127: a stored 5 s choice (no longer offered) reads as 3 s.
        menuBarRefreshInterval = MenuBarRefreshInterval.stored(
            preferences.string(forKey: Self.menuBarRefreshIntervalDefaultsKey))
            ?? MenuBarRefreshInterval.defaultValue
        didCompleteInitialPermissionCheck = preferences.bool(forKey: Self.initialPermissionCheckDefaultsKey)
        loadsDefaultCleanReports = cleanReportLoader == nil
        duplicateCleanupReport = cleanReportLoader?().first {
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
            if loadsDefaultCleanReports, duplicateCleanupReport == nil {
                let journal = operationJournal
                let restored = await Task.detached(priority: .utility) {
                    guard let page = try? CleanReportStore.summaryPage(journal: journal),
                          let candidate = page.reports.first(where: {
                              $0.rulesVersion == VerifiedDuplicateCleanPlanBuilder.rulesVersion && $0.recoverableCount > 0
                          }) else { return Optional<CleanReport>.none }
                    return try? CleanReportStore.report(planID: candidate.planID, journal: journal)
                }.value
                // A new in-session cleanup always wins over a late startup read.
                if duplicateCleanupReport == nil { duplicateCleanupReport = restored }
            }
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
        if startsSmartCareJunkScan { return .overview }
        return navigationState.selectedFilter == .utilityHub
            ? navigationState.selectedUtilityFilter
            : navigationState.selectedFilter
    }

    /// D202: the page a scan starting now is for. Smart Care's junk scan is
    /// the Smart Care page's whatever page is on screen; it used to follow
    /// the page on screen (on Cleanup it became that page's scan, on Space
    /// Map, Migration or Duplicates it started that page's scan instead).
    private var scanPage: ReviewFilter {
        startsSmartCareJunkScan ? .overview : selectedFilter
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
    /// D202: `page: .green` installs the rows as the Cleanup page's own scan.
    func installDebugSmartScanSessionFixture(
        _ scenario: DebugSmartScanSessionFixture.Scenario, page: ReviewFilter = .overview
    ) {
        guard scenario == .results else { return }
        let session = page == .green ? DebugSmartScanSessionFixture.cleanupPageSession
            : DebugSmartScanSessionFixture.session

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
        cleanupScanSession = session
        cleanupSelection = DebugSmartScanSessionFixture.selection
        cleanupDryRunSummary = nil
        cleanupWorkflowState = .results(sessionID: session.id)
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
        // D106: the first check lists protected folders, and macOS shows its
        // permission prompts on the menu-bar display.
        guard !AcceptanceLaunch.isActive else { return }

        refreshScanReadiness(
            markInitialPermissionCheckCompleted: true,
            showInitialFolderAccessPromptWhenNeeded: true
        )
    }

    func prepareInitialFolderAccessPrompt() {
        guard !didCompleteInitialPermissionCheck else { return }
        guard FolderAccessGrantService.shouldShowInitialPrompt(defaults: appPreferences) else { return }
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
            await metricHistoryStore.setPersistenceIssueHandler { [weak self] issue in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let warning = issue.map { _ in L10n.text(
                        "监测历史未保存，原记录已保留；当前读数仍可使用。",
                        "Monitoring history is not saved. Existing records are preserved; current readings remain available."
                    ) }
                    guard warning != self.monitoringHistoryWarning else { return }
                    self.monitoringHistoryWarning = warning
                    if let warning { self.showActionMessage(warning) }
                }
            }
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
        FolderAccessGrantService.markInitialPromptShown(defaults: appPreferences)
        isShowingInitialFolderAccessPrompt = false
    }

    func requestRequiredFolderAccess() {
        guard !folderAccessPanelCoordinator.isPresenting else { return }

        FolderAccessGrantService.markInitialPromptShown(defaults: appPreferences)
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

            let savedCount = FolderAccessGrantService.saveAccess(for: panel.urls, defaults: appPreferences)
            self.refreshScanReadiness(markInitialPermissionCheckCompleted: true)

            if savedCount == 0 {
                self.showActionMessage(
                    L10n.text("未保存新的文件夹授权。", "No new folder access was saved.")
                )
            } else {
                self.showActionMessage(
                    L10n.text(
                        "已保存 \(ByteFormat.count(savedCount)) 个文件夹授权，下次打开会自动恢复。",
                        "Saved access for \(ByteFormat.count(savedCount)) folder(s); it will be restored next time."
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
        guard scanPage != .overview || !selectedSmartScanScopes.isEmpty else {
            showActionMessage(L10n.text("请至少选择一个扫描项目。", "Select at least one scan item."))
            return
        }
        guard !isPreparingScan else { return }
        guard !isCleanupExecutionActive else {
            showActionMessage(L10n.text(
                "当前安全清理尚未结束，暂不能开始新的扫描。",
                "Safe cleanup is still in progress, so a new scan cannot start yet."
            ))
            return
        }
        // File workspaces own their scan/access pipeline. Cmd-R must not
        // run the main scanner or replace another page's cleanup session.
        if refreshFileWorkspaceIfSelected() { return }
        if cleanupFeatureConfiguration.mode != .legacy {
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

    /// Starts a new main scan, including a new presentation identity. Page
    /// refresh commands enter through startScanRespectingAccessGuide instead.
    func startScan() {
        beginScan(rescanning: nil)
    }

    /// Review A-R3: with `session`, the scan covers what that finished
    /// session covered, whatever the scan preferences say now.
    private func beginScan(rescanning session: ScanSession?) {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        guard session != nil || scanPage != .overview || !selectedSmartScanScopes.isEmpty else {
            showActionMessage(L10n.text("请至少选择一个扫描项目。", "Select at least one scan item."))
            return
        }
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
        if let session {
            startCleanupV2Scan(rescanning: session)
            return
        }
        guard (cleanupFeatureConfiguration.mode == .legacy
                && !(scanPage == .overview && selectedSmartScanScopes != SmartScanScope.defaultSelection))
                || ReviewFilter.fileWorkspaceCases.contains(scanPage) else {
            startCleanupV2Scan()
            return
        }

        mainScanUsesRules = false
        // Only a main legacy scan replaces this session. Reset its dependent
        // state together so no selection, plan or workflow outlives the result.
        cleanupScanSession = nil
        accessReturnNotice = nil
        cleanupActiveRuleSet = nil
        cleanupSelection = CleanupSelection()
        cleanupDryRunSummary = nil
        cleanupPlanTask?.cancel()
        cleanupPlanTask = nil
        cleanupPlanGeneration = nil
        pendingCleanPlan = nil
        pendingCleanPreflight = nil
        // A finished receipt remains available until dismissed, as before.
        // It cannot reopen results after this new scan replaces their token.
        cleanupResultReturn = nil
        cleanupWorkflowState = .idle
        let generation = UUID()
        let mode = currentScanMode
        let scansSmartHealth = scanPage == .overview && selectedSmartScanScopes.contains(.health)
        let healthOperation = smartScanHealthOperation
        smartScanHealthSnapshot = nil
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
                let (scanResult, healthSnapshot, healthUnavailable) = try await coordinator.withLease(owner: .mainScan) { lease in
                    await activityStore.refresh()
                    let scanned = try await service.scan(
                        mode: mode,
                        lease: lease
                    ) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.mainScanGeneration == generation else { return }
                            self.mainScanProgress = progress
                        }
                    }
                    try Task.checkCancellation()
                    var healthSnapshot: ComputerHealthSnapshot? = nil
                    var healthUnavailable = false
                    if scansSmartHealth {
                        do { healthSnapshot = try await healthOperation() }
                        catch is CancellationError { throw CancellationError() }
                        catch { healthUnavailable = true }
                    }
                    return (scanned, healthSnapshot, healthUnavailable)
                }
                await activityStore.refresh()
                guard mainScanGeneration == generation else { return }

                isFinalizingMainScan = true

                result = scanResult
                smartScanHealthSnapshot = healthSnapshot
                if healthUnavailable {
                    showActionMessage(L10n.text("健康信息不可用；已保留完成的只读文件结果。",
                        "Health information unavailable; completed read-only file results were kept."))
                }
                scanReadinessSummary = ScanReadinessService.summary(fromScanDeniedPaths: scanResult.deniedPaths)
                scanReadinessCheckedAt = nil
                ScanHistoryService.record(scanResult, defaults: scanHistoryDefaults)
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
        (cleanupFeatureConfiguration.mode != .legacy || mainScanUsesRules)
            && isScanning
            && !isFinalizingMainScan
            && !isCancellingMainScan
    }

    /// Uses the same feature-owned entry points as the page's refresh action.
    /// Returning true also covers a feature refusing a refresh while busy.
    private func refreshFileWorkspaceIfSelected() -> Bool {
        switch scanPage {
        case .largeFiles:
            largeFilesWorkspace.startStorageAnalysis()
        case .migration:
            if largeFilesWorkspace.migrationKind == .application {
                refreshInstalledApps()
            } else {
                largeFilesWorkspace.startScan()
            }
        case .duplicates:
            scanDuplicateFiles()
        default:
            return false
        }
        return true
    }

    func cancelMainScan() {
        guard canCancelMainScan else { return }
        isCancellingMainScan = true
        if let generation = mainScanGeneration {
            transitionScanPresentation(to: .cancelling, matching: generation)
        }
        mainScanTask?.cancel()
    }

    private func refreshSystemCachesAfterScan(_ session: ScanSession) {
        systemCacheInventoryTask?.cancel()
        systemCacheInventory = nil
        pendingSystemCacheClear = nil
        guard session.outcome != .cancelled, session.smartScanScopes != [.health] else { return }
        systemCacheInventoryTask = Task { @MainActor [weak self] in
            await self?.refreshSystemCacheInventory(sessionID: session.id)
        }
    }

    func refreshSystemCacheInventory(sessionID: ScanSessionID? = nil) async {
        let inventory = await systemCacheService.inventory()
        guard !Task.isCancelled, sessionID == nil || cleanupScanSession?.id == sessionID else { return }
        systemCacheInventory = inventory
    }

    func cancelSystemCacheInventory() async {
        systemCacheInventoryTask?.cancel()
        await systemCacheInventoryTask?.value
        systemCacheInventoryTask = nil
    }

    func requestSystemCacheClear(_ selected: Set<SystemCacheID>) {
        guard !isClearingSystemCaches, !selected.isEmpty, let inventory = systemCacheInventory else { return }
        let items = inventory.items.filter { selected.contains($0.cache) && SystemCachePresentation.isSelectable($0) }
        guard items.count == selected.count, Set(items.map(\.cache)) == selected else { return }
        pendingSystemCacheClear = .init(items: items)
    }

    func cancelSystemCacheClear() { pendingSystemCacheClear = nil }

    func confirmSystemCacheClear(planID: UUID) async {
        guard !isClearingSystemCaches, let plan = pendingSystemCacheClear, plan.id == planID else { return }
        pendingSystemCacheClear = nil
        isClearingSystemCaches = true
        systemCacheResultMessage = nil
        do {
            let reply = try await systemCacheService.clear(plan.directories)
            systemCacheResultMessage = SystemCachePresentation.result(reply)
        } catch {
            systemCacheResultMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.text("系统缓存未能全部清除，请稍后重试。", "System caches could not all be cleared. Try again later.")
        }
        await refreshSystemCacheInventory()
        isClearingSystemCaches = false
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

    func toggleSmartScanScope(_ scope: SmartScanScope) {
        guard !isPreparingScan, !isCleanupExecutionActive else { return }
        if selectedSmartScanScopes.contains(scope) { selectedSmartScanScopes.remove(scope) }
        else { selectedSmartScanScopes.insert(scope) }
        SmartScanScope.save(selectedSmartScanScopes, in: cleanupPreferences)
    }

    /// D168: Smart Care's cleanup card scans both file scopes; health is no
    /// longer part of Smart Scan (it stays in My Tools).
    func prepareSmartCareCleanupScopes() {
        guard selectedSmartScanScopes != SmartCareModule.cleanupScopes,
              !isPreparingScan, !isCleanupExecutionActive else { return }
        selectedSmartScanScopes = SmartCareModule.cleanupScopes
        SmartScanScope.save(selectedSmartScanScopes, in: cleanupPreferences)
    }

    /// Where Smart Care keeps which modules it scans (D168), beside the
    /// Smart Scan scopes.
    var smartCarePreferences: UserDefaults { cleanupPreferences }

    // MARK: D202 — Smart Care's results and the modules' own

    static let smartCareResultPartsKey = "smart-care.result-parts.v1"

    static func smartCareResultParts(in defaults: UserDefaults) -> Set<SmartCareModule> {
        Set((defaults.stringArray(forKey: smartCareResultPartsKey) ?? []).compactMap(SmartCareModule.init(rawValue:)))
    }

    /// D202: Smart Care's junk scan, the Smart Care page's own whatever page is
    /// on screen (its scopes, its session, its route).
    func startSmartCareJunkScan() {
        prepareSmartCareCleanupScopes()
        startsSmartCareJunkScan = true
        defer { startsSmartCareJunkScan = false }
        startScanRespectingAccessGuide()
    }

    /// D202: Smart Care is about to scan `part`; what the scan leaves in the
    /// shared stores is Smart Care's.
    func beginSmartCarePart(_ part: SmartCareModule) {
        smartCareScanningPart = part
        markSmartCareResultParts(smartCareResultParts.union([part]))
    }

    func endSmartCarePart(_ part: SmartCareModule) {
        if smartCareScanningPart == part { smartCareScanningPart = nil }
    }

    /// D202: a scan of `part` that Smart Care did not start, a module page's
    /// own. Its result is the module's; Smart Care, whose cards read the
    /// shared stores, goes back to its landing. On Smart Care's Review of
    /// `part` a scan stays Smart Care's: it is that page's refresh, as after
    /// disabling a login item there.
    func noteModuleScan(_ part: SmartCareModule) {
        guard smartCareScanningPart != part, smartCareResultParts.contains(part),
              navigationState.smartCareReview != part else { return }
        markSmartCareResultParts(smartCareResultParts.subtracting([part]))
        onModuleScanReplacedSmartCarePart?(part)
    }

    /// D202: whether `part`'s result in the shared stores is Smart Care's. A
    /// mark whose result is gone (cleared since, or not restored at launch)
    /// counts as none. Without the privacy store a protection mark counts.
    func smartCareHolds(_ part: SmartCareModule, privacy: BrowserPrivacyStore? = nil) -> Bool {
        guard smartCareResultParts.contains(part) else { return false }
        if smartCareScanningPart == part { return true }
        switch part {
        case .cleanup: return cleanupScanSession?.smartScanScopes != nil
        case .protection: return privacy.map { $0.state != .idle } ?? true
        case .performance: return hasScannedStartupItems || isLoadingStartupItems
        case .applications: return isLoadingAppUpdates || appUpdatesLastScannedAt != nil
        case .clutter: return duplicateFilesWorkspace.hasScanned || duplicateFilesWorkspace.isScanning
        }
    }

    /// D202: whether a module page shows `part`'s result: its own, or Smart
    /// Care's while Smart Care's Review is on it.
    func moduleShowsResult(_ part: SmartCareModule, privacy: BrowserPrivacyStore? = nil) -> Bool {
        !smartCareHolds(part, privacy: privacy) || navigationState.smartCareReview == part
    }

    /// D202: Smart Care's Review opens `filter` on Smart Care's result for
    /// `part`; the sidebar keeps Smart Care until another page is chosen.
    func showSmartCareReview(_ filter: ReviewFilter, part: SmartCareModule) {
        showFilter(filter)
        navigationState.beginSmartCareReview(part)
    }

    /// D202: Smart Care's Start Over, and Done after its Run, clear what Smart
    /// Care's scan left in the shared stores, and only that (a module's own
    /// result is not marked). App update checks are the app's facts; their
    /// mark only goes.
    func clearSmartCareResults(privacy: BrowserPrivacyStore?) {
        let parts = smartCareResultParts.filter { smartCareHolds($0, privacy: privacy) }
        // A junk part Smart Care stopped or could not finish has no session
        // but leaves its page; that goes too (a module's own session stays).
        let junkIsSmartCares = smartCareResultParts.contains(.cleanup)
            && (cleanupScanSession.map { $0.smartScanScopes != nil } ?? true)
        markSmartCareResultParts([])
        if junkIsSmartCares { startOverV2Results() }
        if parts.contains(.protection), let privacy, privacy.state != .scanning { privacy.clearSession() }
        if parts.contains(.performance) { startOverStartupItems() }
        if parts.contains(.clutter) { duplicateFilesWorkspace.startOver() }
    }

    /// D202: whether the junk flow on screen belongs to a module page's own
    /// scan, which Smart Care's page does not show. Cleaning, verifying and
    /// the cleanup's completed page stay everyone's.
    static func junkFlowIsAModules(state: SmartScanPresentationState, route: ReviewFilter?,
                                   session: ScanSession?, cancellingCleanup: Bool) -> Bool {
        switch state {
        case .preparing, .scanning, .finalizing:
            return route.map { $0 != .overview } ?? false
        case .cancelling:
            return !cancellingCleanup && (route.map { $0 != .overview } ?? false)
        case .results, .confirming:
            return session.map { scanRoute(of: $0) != .overview } ?? false
        case .idle, .cleaning, .verifying, .completed, .cancelled, .failed:
            return false
        }
    }

    private func markSmartCareResultParts(_ parts: Set<SmartCareModule>) {
        guard parts != smartCareResultParts else { return }
        smartCareResultParts = parts
        cleanupPreferences.set(SmartCareModule.allCases.filter(parts.contains).map(\.rawValue),
                               forKey: Self.smartCareResultPartsKey)
    }

    func toggleSafeCleanupScope(_ scope: SafeCleanupScanScope) {
        guard !isPreparingScan, !isCleanupExecutionActive else { return }
        if selectedSafeCleanupScopes.contains(scope) {
            selectedSafeCleanupScopes.remove(scope)
        } else {
            selectedSafeCleanupScopes.insert(scope)
        }
        SafeCleanupScanScope.save(selectedSafeCleanupScopes, in: cleanupPreferences)
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
        // Review P2-1: a request needs this scan in its results state, with
        // its presentation token and the rule set it was scanned with.
        // Without them `requestV2Cleanup` does nothing, so the button is off.
        return canEditV2CleanupSelection
            && scanPresentationState == .results
            && scanPresentationSessionID != nil
            && cleanupActiveRuleSet != nil
    }

    /// The one test for showing the confirmation sheet; ContentView binds to
    /// it (`CleanupPlanConfirmationPresentation`). A2: it also holds when
    /// nothing passed the check, so each item's reason is visible and the
    /// sheet cannot be confirmed; closing it returns to the results.
    var isV2CleanupConfirmationPresented: Bool {
        guard case .awaitingConfirmation = cleanupWorkflowState else { return false }
        return scanPresentationState == .confirming
            && pendingCleanPlan != nil
            && pendingCleanPreflight != nil
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
            isRecheckingCleanup = false
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
                // A2: with items to show, the confirmation opens even when none
                // passed, listing each reason; only a check that could not run
                // at all returns to the results.
                if report.isConfirmable || (report.failure == nil && !report.items.isEmpty) {
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
        isRecheckingCleanup = false
        if cleanupOwnerQuitRequest?.isFromConfirmation == true {
            cleanupOwnerQuitRequest = nil
        }
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
        protectedTrashMoveAcknowledged: Bool = false,
        permanentDeletionAcknowledged: Bool = false,
        scaleAcknowledged: CleanPlanScaleAlert? = nil
    ) {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        guard cleanupFeatureConfiguration.mode == .v2Full,
              cleanupExecutionTask == nil,
              !isRecheckingCleanup,
              !isQuittingCleanupOwners,
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
        guard plan.protectedMoveItems.isEmpty
            || (protectedRiskAcknowledged && protectedTrashMoveAcknowledged) else {
            errorMessage = L10n.text(
                "请先完成红色高风险项目的两项确认。",
                "Complete both confirmations for the selected red high-risk items."
            )
            return
        }
        // D23/A2: emptying the Trash is confirmed on its own, separately from
        // red items that only move to Trash.
        guard plan.permanentDeletionItems.isEmpty || permanentDeletionAcknowledged else {
            errorMessage = L10n.text(
                "请先完成清空废纸篓的两项确认。",
                "Complete both confirmations for emptying the Trash."
            )
            return
        }
        // D101 G13: an unusually large run is confirmed for the very summary
        // shown; a check again that changes it needs a new confirmation.
        guard preflight.scaleAlert == nil || preflight.scaleAlert == scaleAcknowledged else {
            errorMessage = L10n.text(
                "本次清理规模异常，请先核对规模摘要并确认。",
                "This cleanup is unusually large. Review its summary and confirm first."
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
            if !(await CleanReportStore.recordDetached(report, journal: operationJournal)) {
                errorMessage = L10n.text("回执保存失败；本次已完成的移动仍保留在结果中。", "Receipt saving failed; completed moves remain in this result.")
            }
            lastCleanReport = report
            // A2: rows moved to Trash or deleted leave the results; skipped and
            // failed rows stay listed.
            if let current = cleanupScanSession, current.id == plan.sessionID {
                cleanupScanSession = current.removingCleanedItems(report: report, plan: plan)
            }
            pendingCleanPlan = nil
            cleanupWorkflowState = .completed(reportID: report.id)
            cleanupResultReturn = (report.id, presentationSessionID)
            // D214: a run that never started keeps the selection for a retry.
            if report.startRefusal == nil {
                cleanupSelection = CleanupSelection()
            }
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

    // MARK: - A2: running owner apps

    /// D22/A2: reads again which owner apps are running and updates the rows'
    /// running labels. The user's selection is never changed.
    func refreshCleanupOwnerRunningState() async {
        guard cleanupScanSession != nil, cleanupExecutionTask == nil else { return }
        let applications = await cleanupApplicationEnvironment.snapshot(checkingInstalled: [])
        guard cleanupExecutionTask == nil, let current = cleanupScanSession else { return }
        cleanupScanSession = current.updatingRunningOwners(from: applications)
    }

    /// Round 3 (P2-1): which running owners of a row can be asked to quit
    /// and which must be quit by hand. Duplicate app copies are not offered:
    /// a running copy is kept (D25), and it is identified by path.
    func cleanupOwnerQuitOptions(for candidate: ScanCandidate) -> CleanupOwnerQuitService.Options {
        guard candidate.ownerResolution != .applicationBundle else { return .init() }
        return cleanupOwnerQuitService.options(among: Self.quitIdentifiers(of: candidate))
    }

    /// Round 3 (P2-1): the running owners of the items the sheet skipped
    /// because their app is still running.
    var pendingCleanupOwnerQuitOptions: CleanupOwnerQuitService.Options {
        guard let plan = pendingCleanPlan,
              let preflight = pendingCleanPreflight,
              preflight.planID == plan.id else { return .init() }
        let blocked = Set(preflight.items.compactMap { item in
            item.status == .skipped(.relatedAppStillRunning) ? item.planItemID : nil
        })
        guard !blocked.isEmpty else { return .init() }
        return cleanupOwnerQuitService.options(among: Set(plan.items
            .filter { blocked.contains($0.id) }
            .flatMap { $0.requiredClosedBundleIDs + $0.inferredOwnerBundleIDs }))
    }

    private static func quitIdentifiers(of candidate: ScanCandidate) -> Set<String> {
        Set(candidate.requiredClosedBundleIDs
            + (candidate.ownerResolution == .inferredFromName ? candidate.ownerBundleIdentifiers : []))
    }

    /// A2: "正常退出并清理" on a running row. Lists, for confirmation, every
    /// running instance of the apps that own the selected rows among
    /// `candidateIDs`; nothing quits until the user confirms. Apps that can
    /// only be quit by hand are named instead (round 3, P2-1).
    func requestQuitCleanupOwners(
        for candidateIDs: Set<ScanCandidateID>,
        cleanupScope: Set<ScanCandidateID>? = nil
    ) {
        guard canEditV2CleanupSelection,
              !isQuittingCleanupOwners,
              let session = cleanupScanSession else { return }
        let identifiers = Set(cleanupSelection.selectedCandidates(in: session)
            .filter { candidateIDs.contains($0.id) && $0.ownerResolution != .applicationBundle }
            .flatMap { Self.quitIdentifiers(of: $0) })
        presentCleanupOwnerQuitRequest(
            source: .results(cleanupScope: cleanupScope),
            options: cleanupOwnerQuitService.options(among: identifiers)
        )
    }

    /// A2: on the confirmation sheet, the running apps of items skipped
    /// because their app is still running.
    func requestQuitCleanupOwnersForPendingPlan() {
        guard cleanupExecutionTask == nil,
              !isQuittingCleanupOwners,
              pendingCleanPlan != nil else { return }
        presentCleanupOwnerQuitRequest(source: .confirmation, options: pendingCleanupOwnerQuitOptions)
    }

    func cancelQuitCleanupOwners() {
        cleanupOwnerQuitRequest = nil
    }

    /// A2: asks the listed apps to quit normally (`terminate()`, never
    /// forced), waits until a 5-second deadline, refreshes the rows, then continues:
    /// from a row, the cleanup of the current selection is checked; from the
    /// sheet, the same frozen plan is checked again. Apps that stay open keep
    /// their items skipped.
    func quitOwnersAndRecheckCleanup() {
        guard let request = cleanupOwnerQuitRequest,
              !isQuittingCleanupOwners,
              cleanupExecutionTask == nil else { return }
        cleanupOwnerQuitRequest = nil
        isQuittingCleanupOwners = true
        let service = cleanupOwnerQuitService
        Task { @MainActor [weak self] in
            let stillRunning = await service.quitNormally(request.owners)
            guard let self else { return }
            await refreshCleanupOwnerRunningState()
            isQuittingCleanupOwners = false
            if !stillRunning.isEmpty {
                let names = CleanupOwnerQuitPresentation.names(
                    request.owners.filter { stillRunning.contains($0.bundleIdentifier) }
                )
                let seconds = Int(CleanupOwnerQuitService.waitSeconds)
                errorMessage = L10n.text(
                    "\(names) 没有在 \(seconds) 秒内退出，相关项目会被跳过。",
                    "\(names) did not quit within \(seconds) seconds; related items are skipped."
                )
            }
            // Round 3 (P2-3): continue only for the scan (and on the sheet the
            // plan) the request was made for; otherwise the rows were just
            // refreshed and nothing starts on its own.
            guard cleanupScanSession?.id == request.sessionID,
                  request.planID == nil || pendingCleanPlan?.id == request.planID else {
                return
            }
            switch request.source {
            case let .results(cleanupScope):
                requestV2Cleanup(disposition: .trash, candidateIDs: cleanupScope)
            case .confirmation:
                recheckPendingCleanup()
            }
        }
    }

    /// A2: checks the frozen plan again, for example after its apps quit;
    /// the confirmation stays open meanwhile and cannot be confirmed.
    func recheckPendingCleanup() {
        guard cleanupExecutionTask == nil,
              let plan = pendingCleanPlan,
              let session = cleanupScanSession,
              session.id == plan.sessionID,
              let activeRules = cleanupActiveRuleSet,
              let presentationSessionID = scanPresentationSessionID else { return }
        cleanupPlanTask?.cancel()
        let generation = UUID()
        cleanupPlanGeneration = generation
        isRecheckingCleanup = true
        let executor = cleanupExecutor
        let context = cleanupExecutionContext(session: session, activeRules: activeRules)
        cleanupPlanTask = Task { @MainActor [weak self] in
            let report = await executor.preflight(plan: plan, context: context)
            guard let self, cleanupPlanGeneration == generation else { return }
            cleanupPlanTask = nil
            isRecheckingCleanup = false
            guard pendingCleanPlan?.id == plan.id,
                  scanPresentationSessionID == presentationSessionID else { return }
            pendingCleanPreflight = report
            cleanupWorkflowState = .awaitingConfirmation(planID: plan.id)
        }
    }

    private func presentCleanupOwnerQuitRequest(
        source: CleanupOwnerQuitRequest.Source,
        options: CleanupOwnerQuitService.Options
    ) {
        if !options.manual.isEmpty {
            // Round 3 (P2-1): running, but they cannot be asked to quit.
            showActionMessage(CleanupOwnerQuitPresentation.manualQuitText(for: options.manual))
        }
        guard options.quittable.isEmpty else {
            cleanupOwnerQuitRequest = CleanupOwnerQuitRequest(
                source: source,
                owners: options.quittable,
                sessionID: cleanupScanSession?.id,
                planID: source == .confirmation ? pendingCleanPlan?.id : nil
            )
            return
        }
        guard options.manual.isEmpty else { return }
        // Nothing runs any more: refresh the rows; on the sheet, check again.
        Task { [weak self] in await self?.refreshCleanupOwnerRunningState() }
        if source == .confirmation {
            recheckPendingCleanup()
        } else {
            showActionMessage(L10n.text(
                "相关应用已经退出，可以继续清理。",
                "The related apps have already quit; cleanup can continue."
            ))
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

    /// Test observation points only. The test support layer owns bounded joining;
    /// production task creation, cancellation and publication stay unchanged.
    var operationReportProducersForTesting: [(name: String, task: Task<Void, Never>)] {
        let producers: [(String, Task<Void, Never>?)] = [
            ("uninstallPreparationTask", uninstallPreparationTask), ("uninstallTask", uninstallTask),
            ("cleanupExecutionTask", cleanupExecutionTask), ("cleanupRecoveryTask", cleanupRecoveryTask),
            ("duplicateCleanupTask", duplicateCleanupTask), ("duplicateRecoveryTask", duplicateRecoveryTask),
            ("menuBarVisibleProcessTask", menuBarVisibleProcessTask),
            ("menuBarMemoryProcessTask", menuBarMemoryProcessTask),
            ("menuBarResidentHelperTask", menuBarResidentHelperTask)
        ]
        return producers.compactMap { name, task in task.map { (name: name, task: $0) } }
    }

    var operationReportWorkersForTesting: [(name: String, task: Task<Void, Never>)] {
        operationReportTasks.map { (name: "operationReportTasks[\($0.key.uuidString)]", task: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func refreshOperationReports(loadMore: Bool = false, reconcile: Bool = false) {
        guard !isLoadingOperationReports else {
            // Run once more after the current load instead of dropping the request.
            if !loadMore { queuedOperationReportRefresh = (queuedOperationReportRefresh ?? false) || reconcile }
            return
        }
        isLoadingOperationReports = true
        let cursor = loadMore ? operationReportCursor : nil
        let receiptTaskID = UUID()
        operationReportTasks[receiptTaskID] = Task {
            defer { operationReportTasks[receiptTaskID] = nil }
            defer {
                isLoadingOperationReports = false
                if let queuedReconcile = queuedOperationReportRefresh {
                    queuedOperationReportRefresh = nil
                    refreshOperationReports(reconcile: queuedReconcile)
                }
            }
            if reconcile { await reconcileInterruptedOperations() }
            let journal = operationJournal
            let loaded = await Task.detached(priority: .utility) {
                try? CleanReportStore.summaryPage(after: cursor, journal: journal)
            }.value
            if let loaded {
                if loadMore {
                    let known = Set(operationReports.map(\.id))
                    operationReports.append(contentsOf: loaded.reports.filter { !known.contains($0.id) })
                } else { operationReports = loaded.reports }
                operationReportCursor = loaded.next
                hasMoreOperationReports = loaded.next != nil
            }
            if loaded == nil || loaded?.unreadableEntries.isEmpty == false {
                operationReportWarning = L10n.text(
                    "部分回执无法读取；有效回执仍可查看，损坏记录已保留。",
                    "Some receipts cannot be read. Valid receipts remain available; damaged records were retained.")
            } else { operationReportWarning = nil }
        }
    }

    /// Resolves receipts that an interrupted move or restore left "outcome
    /// unknown". It only reads identities and updates evidence. While another
    /// heavy task holds the lease it reports that instead of waiting; the next
    /// Operation History refresh tries again.
    func reconcileInterruptedOperations() async {
        let reconciler = interruptedOperationReconciler
        do {
            let issues = try await heavyWorkCoordinator.withLease(owner: .restore) { _ in
                await Task.detached(priority: .utility) { reconciler() }.value
            }
            operationReconcileNotice = OperationReconcileNotice(issues)
        } catch HeavyWorkCoordinator.Error.busy {
            // Only worth saying when a loaded receipt actually awaits verification.
            operationReconcileNotice = operationReports.contains(where: \.needsVerification)
                ? .deferredWhileBusy : nil
        } catch {
            operationReconcileNotice = .incomplete
        }
    }

    func reconcileInterruptedOperationsOnLaunch() {
        guard !didStartLaunchReconcile else { return }
        didStartLaunchReconcile = true
        let receiptTaskID = UUID()
        operationReportTasks[receiptTaskID] = Task {
            defer { operationReportTasks[receiptTaskID] = nil }
            await reconcileInterruptedOperations()
        }
    }

    func loadOperationReportDetail(_ planID: CleanPlanID) {
        let request = UUID()
        operationDetailRequest = request
        operationReportDetail = nil
        let receiptTaskID = UUID()
        operationReportTasks[receiptTaskID] = Task {
            defer { operationReportTasks[receiptTaskID] = nil }
            let journal = operationJournal
            let report = await Task.detached(priority: .utility) { try? CleanReportStore.report(planID: planID, journal: journal) }.value
            guard operationDetailRequest == request else { return }
            operationReportDetail = report
            if report == nil {
                operationReportWarning = L10n.text("回执详情无法读取，原始记录已保留。", "Receipt details cannot be read. Original evidence was retained.")
            }
        }
    }

    func closeOperationReportDetail() {
        operationDetailRequest = nil
        operationReportDetail = nil
    }

    func restoreRecordedOperation(_ report: CleanReport) {
        restoreRecordedOperations([report])
    }

    /// Restores what this uninstall review moved: the original receipt and
    /// every retry receipt, so files moved by the first run come back too.
    func restoreUninstallResult() {
        restoreRecordedOperations(uninstallResultReports)
    }

    private func restoreRecordedOperations(_ requested: [CleanReport]) {
        let reports = requested.filter { !$0.restorableReceipts.isEmpty }
        guard !isRestoringRecordedOperation, !reports.isEmpty else { return }
        isRestoringRecordedOperation = true
        let service = cleanupRecoveryService
        let receiptTaskID = UUID()
        operationReportTasks[receiptTaskID] = Task {
            defer { operationReportTasks[receiptTaskID] = nil }
            defer { isRestoringRecordedOperation = false }
            do {
                let coordinator = heavyWorkCoordinator
                let journal = operationJournal, trashURL = operationTrashURL
                let results = try await coordinator.withLease(owner: .restore) { lease in
                    await service.restore(reports: reports, coordinator: coordinator, lease: lease,
                                          journal: journal, userHomeURL: cleanupUserHomeURL, trashURL: trashURL)
                }
                operationRecoveryResult = Self.combinedRecovery(results.map(\.recovery))
                var restoredReceipts: [CleanupMoveReceipt] = []
                var uninstallReportsChanged = false
                for result in results {
                    if operationReportDetail?.planID == result.report.planID {
                        // Invalidate older disk reads before publishing the recovered detail.
                        operationDetailRequest = UUID()
                        operationReportDetail = result.report
                    }
                    if let index = uninstallResultReports.firstIndex(where: { $0.id == result.report.id }) {
                        uninstallResultReports[index] = result.report
                        uninstallReportsChanged = true
                    }
                    if lastCleanReport?.id == result.report.id { lastCleanReport = result.report }
                    let restoredPaths = Set(result.recovery.items.filter { $0.outcome == .restored }
                        .map { PathSafety.lexicalPath($0.originalPath) })
                    restoredReceipts += result.report.items.compactMap { item in
                        guard case .moved(let receipt) = item.outcome,
                              restoredPaths.contains(PathSafety.lexicalPath(receipt.originalPath)) else { return nil }
                        return receipt
                    }
                }
                if uninstallReportsChanged { publishUninstallReview() }
                // The file pages under the Operation History sheet update now.
                largeFilesWorkspace.operationHistoryDidRestore(restoredReceipts)
                if !restoredReceipts.isEmpty {
                    CleanupHistoryService.removeMoveRecords(restoredBy: restoredReceipts, defaults: cleanupPreferences)
                    refreshCleanupHistory()
                    if let application = completedUninstallApplication,
                       restoredReceipts.contains(where: { $0.originalPath == application.originalPath }) {
                        completedUninstallApplication = nil
                    }
                }
                if results.contains(where: { $0.recovery.persistenceFailure != nil }) {
                    operationReportWarning = L10n.text("恢复结果写入失败，请保留当前回执。", "Recovery result could not be saved. Keep this receipt.")
                } else { refreshOperationReports() }
            } catch { handleHeavyWorkError(error) }
        }
    }

    /// One message for a restore that covered several receipts.
    private static func combinedRecovery(_ recoveries: [CleanupRecoveryReport]) -> CleanupRecoveryReport? {
        guard let last = recoveries.last else { return nil }
        guard recoveries.count > 1 else { return last }
        return CleanupRecoveryReport(completedAt: recoveries.map(\.completedAt).max() ?? last.completedAt,
                                     items: recoveries.flatMap(\.items),
                                     persistenceFailure: recoveries.lazy.compactMap(\.persistenceFailure).first)
    }

    /// "完成" on the cleanup result page (Smart Scan, Safe Cleanup and
    /// Developer Files share it). Live test 2026-10-06: while the cleaned scan
    /// still lists rows, return to those results — moved and deleted rows are
    /// already gone, skipped and failed rows stay, nothing is selected — and
    /// keep the scan's presentation token so the rows can be cleaned without
    /// scanning again. Only when nothing is left does the page go back to the
    /// start. "重新扫描" is a separate action (`rescanAfterV2Cleanup`).
    func dismissV2CleanupReport() {
        let report = lastCleanReport
        let resultReturn = cleanupResultReturn
        lastCleanReport = nil
        cleanupRecoveryReport = nil
        cleanupResultReturn = nil
        // Review P2-1: only the receipt this scan's cleanup published, still
        // shown under the token it was published with, returns; not another
        // feature's receipt (uninstall) and not after another scan started.
        if let report,
           let resultReturn,
           report.id == resultReturn.reportID,
           cleanupWorkflowState == .completed(reportID: report.id),
           let session = cleanupScanSession,
           report.sessionID == session.id,
           session.candidates.contains(where: \.isSelectable),
           scanPresentation.returnToResults(matching: resultReturn.presentationSessionID) {
            scanPresentationTimingTask?.cancel()
            scanPresentationTimingTask = nil
            scanPresentationPhaseStartedAt = Date()
            // D214: after a run that never started, the rows come back as they
            // were selected.
            if report.startRefusal == nil {
                cleanupSelection = CleanupSelection()
            }
            cleanupWorkflowState = .results(sessionID: session.id)
            return
        }
        cleanupWorkflowState = .idle
        resetSmartScanPresentation()
    }

    /// "重新扫描" on the cleanup result page scans the same scope again —
    /// Smart Scan, Safe Cleanup or Developer Files — on that scope's page,
    /// even if another page was selected while the result was showing.
    func rescanAfterV2Cleanup() {
        guard scanPresentationState.isTerminal, !isCleanupExecutionActive, !isPreparingScan else { return }
        if let session = cleanupScanSession {
            selectedFilter = Self.scanRoute(of: session)
        }
        // Review P2-1: the receipt belongs to the scan being replaced. A scan
        // that fails before it starts (rules not loaded) shows its own
        // failure, not this receipt again.
        lastCleanReport = nil
        cleanupRecoveryReport = nil
        cleanupResultReturn = nil
        if let session = cleanupScanSession, selectedFilter == .green {
            // D192 / A-R3: a results-page rescan keeps that run's rule scope.
            beginScan(rescanning: session)
        } else {
            startScanRespectingAccessGuide()
        }
    }

    /// D141 revision (live check 2026-10-20): "重新开始" on a studio result
    /// page, before anything is cleaned, returns Smart Scan, Safe Cleanup and
    /// Developer Files to their start pages. Its confirmation says the results
    /// are not kept, so the session and what depends on it go, as when a new
    /// scan replaces them; a receipt stays until dismissed.
    /// `resetSmartScanPresentation` only leaves a terminal page, so on a
    /// result page it did nothing.
    func startOverV2Results() {
        guard !scanPresentationState.isTerminal else {
            resetSmartScanPresentation()
            return
        }
        guard canLeaveV2Results else { return }
        cleanupPlanTask?.cancel()
        cleanupPlanTask = nil
        cleanupPlanGeneration = nil
        cleanupScanSession = nil
        accessReturnNotice = nil
        smartScanHealthSnapshot = nil
        cleanupActiveRuleSet = nil
        cleanupSelection = CleanupSelection()
        cleanupDryRunSummary = nil
        pendingCleanPlan = nil
        pendingCleanPreflight = nil
        cleanupResultReturn = nil
        cleanupWorkflowState = .idle
        scanPresentationTimingTask?.cancel()
        scanPresentationTimingTask = nil
        scanPresentation.reset()
        scanPresentationRoute = nil
    }

    /// D141 revision: "重新扫描" on a studio result page scans the shown
    /// session's scope again on that scope's page, as the classic list's
    /// refresh button does. `rescanAfterV2Cleanup` only runs after a terminal
    /// outcome, so on a result page it did nothing.
    func rescanV2Results() {
        guard !scanPresentationState.isTerminal else {
            rescanAfterV2Cleanup()
            return
        }
        guard canLeaveV2Results else { return }
        if let session = cleanupScanSession {
            selectedFilter = Self.scanRoute(of: session)
        }
        if let session = cleanupScanSession, selectedFilter == .green {
            // D192 / A-R3: a results-page rescan keeps that run's rule scope.
            beginScan(rescanning: session)
        } else {
            startScanRespectingAccessGuide()
        }
    }

    /// Nothing is planned, confirmed or running for the shown results.
    private var canLeaveV2Results: Bool {
        guard !isCleanupExecutionActive, !isPreparingScan, canEditV2CleanupSelection else { return false }
        switch cleanupWorkflowState {
        case .idle, .results:
            return true
        case .buildingPlan, .preflighting, .awaitingConfirmation, .executing,
             .cancellingExecution, .completed, .failed:
            return false
        }
    }

    /// The page whose scan produced `session`.
    static func scanRoute(of session: ScanSession) -> ReviewFilter {
        if session.smartScanScopes != nil { return .overview }
        if session.includedRuleIDs != nil { return .green }
        if session.includedCategoryIDs != nil { return .devCaches }
        return .overview
    }

    /// Coverage is fixed by the completed run, not the current checkboxes or
    /// an empty candidate list. Health-only/review-only scans did not scan junk.
    func cleanupSession(for filter: ReviewFilter) -> ScanSession? {
        guard let session = cleanupScanSession else { return nil }
        // D202: Smart Care's junk scan shows on Smart Care only (it used to
        // fill the Cleanup and developer pages too).
        if session.smartScanScopes != nil, filter == .green || filter == .devCaches { return nil }
        if filter == .devCaches {
            // A dedicated Safe Cleanup run only updates its own page.
            guard session.includedRuleIDs == nil else { return nil }
            let includesDeveloper = session.includedCategoryIDs?.contains("developer") ?? true
            return includesDeveloper ? session : nil
        }
        if filter == .green, session.includedRuleIDs != nil { return session }
        return session.includedCategoryIDs == nil ? session : nil
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
                    await recoveryService.restore(report: report, coordinator: coordinator, lease: lease,
                        journal: operationJournal, userHomeURL: cleanupUserHomeURL, trashURL: operationTrashURL)
                }
                let recovery = restored.recovery
                await activityStore.refresh()
                guard self.cleanupRecoveryGeneration == recoveryGeneration,
                      self.lastCleanReport?.id == report.id else { return }
                cleanupRecoveryReport = recovery
                if recovery.persistenceFailure == nil {
                    lastCleanReport = restored.report
                } else {
                    errorMessage = recovery.resultMessage
                }
                showActionMessage(recovery.resultMessage)
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
            userHomeURL: cleanupUserHomeURL,
            excludedURLs: currentV2ExcludedURLs(),
            approvedPlanItemIDs: approvedPlanItemIDs
        )
    }

    private func currentV2ExcludedURLs() -> [URL] {
        CleanupMigration.v2ExcludedURLs(defaults: appPreferences, userHomeURL: cleanupUserHomeURL)
    }

    /// `session`: review A-R3, a rescan takes its coverage (Smart Scan
    /// scopes, categories and rules) from that finished session, so scan
    /// preferences changed since neither narrow it nor are changed by it.
    private func startCleanupV2Scan(rescanning session: ScanSession? = nil) {
        guard !isCleanupExecutionActive else {
            showActionMessage(L10n.text(
                "当前安全清理尚未结束，暂不能开始新的扫描。",
                "Safe cleanup is still in progress, so a new scan cannot start yet."
            ))
            return
        }
        guard session != nil || scanPage != .green || !selectedSafeCleanupScopes.isEmpty else {
            showActionMessage(L10n.text(
                "请至少选择一个扫描项目。",
                "Select at least one scan item."
            ))
            return
        }
        let smartScopes = session.map(\.smartScanScopes) ?? (scanPage == .overview ? selectedSmartScanScopes : nil)
        let safeCleanupScopes = session == nil && scanPage == .green ? selectedSafeCleanupScopes : nil
        let healthOperation = smartScanHealthOperation
        let generation = UUID()
        beginScanPresentation(sessionID: generation)
        // D202: a junk scan of the Cleanup or developer page is the module's own.
        if (session.map(Self.scanRoute(of:)) ?? scanPage) != .overview { noteModuleScan(.cleanup) }
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

        mainScanUsesRules = true
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
        accessReturnNotice = nil
        smartScanHealthSnapshot = nil
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
        let selectedRules = smartScopes.map { scopes in
            activeRules.rules.filter { rule in scopes.contains { $0.includes(rule) } }
        } ?? (scanPage == .green
            ? activeRules.rules.filter { rule in
                safeCleanupScopes?.contains(where: { $0.includes(rule) }) ?? false
            }
            : [])
        let narrowedSmartScan = smartScopes.map { !$0.contains(.cleanupCandidates) || !$0.contains(.filesToReview) } ?? false
        let pageCategoryIDs: Set<String>? = narrowedSmartScan
            ? Set(selectedRules.map(\.categoryID))
            : scanPage == .devCaches
            ? ["developer"]
            : scanPage == .green
                ? Set(selectedRules.map(\.categoryID))
                : nil
        let pageRuleIDs: Set<String>? = scanPage == .green || narrowedSmartScan
            ? Set(selectedRules.map(\.id))
            : nil
        // A rescan covers its session's categories and rules; exclusions and
        // the developer threshold are always the current ones.
        let request = CleanupScanRequest(
            userHomeURL: cleanupUserHomeURL,
            excludedURLs: appPreferences === UserDefaults.standard ? [] : currentV2ExcludedURLs(),
            ignoreList: currentIgnoreListSnapshot(),
            developerInactivityThresholdDays: developerInactivityThresholdDays,
            includedCategoryIDs: session.map(\.includedCategoryIDs) ?? pageCategoryIDs,
            includedRuleIDs: session.map(\.includedRuleIDs) ?? pageRuleIDs
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
                    let publish: CleanupScanProgressHandler = { [weak self] progress in
                        await MainActor.run {
                            guard let self,
                                  self.mainScanGeneration == generation else { return }
                            let diskProgress = DiskScanProgress(
                                cleanupProgress: progress
                            )
                            self.publishMainScanProgress(
                                diskProgress,
                                force: progress.phase != .enumerating || progress.currentRuleID == "smart.health"
                            )
                        }
                    }
                    if let smartScopes {
                        return try await SmartScanReadOperation.run(request: request, scopes: smartScopes,
                            rulesVersion: activeRules.rulesVersion, fileRuleCount: selectedRules.count, cleanup: operation,
                            health: healthOperation, progress: publish)
                    }
                    return try await operation(request, publish)
                }
                await activityStore.refresh()
                guard mainScanGeneration == generation else { return }

                if session.outcome != .cancelled {
                    isFinalizingMainScan = true
                }

                cleanupScanSession = session
                refreshSystemCachesAfterScan(session)
                smartScanHealthSnapshot = session.smartScanHealthSnapshot
                cleanupSelection = .defaults(in: session)
                cleanupWorkflowState = .results(sessionID: session.id)
                // D68: keep file history by actual coverage. Health-only runs
                // update reminder time without inventing file counts or scores.
                let recordsFileScan = smartScopes.map {
                    $0.contains(.cleanupCandidates) || $0.contains(.filesToReview)
                } ?? (request.includedCategoryIDs == nil && request.includedRuleIDs == nil)
                if session.outcome != .cancelled, recordsFileScan || smartScopes != nil {
                    if recordsFileScan {
                        ScanHistoryService.record(session, scanMode: currentScanMode, defaults: scanHistoryDefaults)
                    } else {
                        ScanHistoryService.recordCompletedScan(at: session.completedAt, defaults: scanHistoryDefaults)
                    }
                    refreshScanHistory()
                }
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

    /// D100 G5: the app became active again, for example after access was
    /// granted in System Settings. Only the roots the current scan could not
    /// read are read again, read-only, and only once each per run; a root
    /// that became readable is offered for a rescan. Nothing scans here.
    func checkAccessAfterReturn() {
        // D106: no protected-folder probe in an acceptance session (see above).
        guard !AcceptanceLaunch.isActive else { return }
        // Read the roots first: a readiness refresh counts as preparing a
        // scan and would hold the check back.
        offerRescanIfAccessReturned()
        if scanReadinessSummary?.blockedCount ?? 0 > 0 {
            refreshScanReadiness()
        }
    }

    private func offerRescanIfAccessReturned() {
        guard accessReturnCheckTask == nil,
              let session = cleanupScanSession,
              showsSettledScanResults else { return }
        let paths = accessReturnTracker.pathsToCheck(in: session.permissions)
        guard !paths.isEmpty else { return }
        let probe = readableDirectories
        let ruleTitles = Dictionary(
            (cleanupActiveRuleSet?.rules ?? []).map { ($0.id, CleanupRuleCopy.title(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        accessReturnCheckTask = Task { [weak self] in
            let readable = await Task.detached(priority: .utility) { probe(paths) }.value
            guard let self else { return }
            accessReturnCheckTask = nil
            guard cleanupScanSession?.id == session.id else { return }
            let newlyReadable = accessReturnTracker.recordReadable(readable, among: paths)
            guard !newlyReadable.isEmpty else { return }
            accessReturnNotice = ScanAccessReturnNotice(
                session: session,
                readablePaths: newlyReadable,
                ruleTitles: ruleTitles
            )
        }
    }

    /// D104 G5: the user asked to scan the locations that became readable.
    /// Only the rules whose roots this session could not read, and that are
    /// readable now, run again, under the same heavy-work lease as any scan;
    /// what they find joins this session's results (`mergingRescan`) and
    /// nothing else is read again. When the rules changed since the session,
    /// or one of them is gone, the session's own coverage runs again instead
    /// (review A-R3). Starting clears the notice; a stopped or failed scan of
    /// the new locations leaves the results as they were and offers it again.
    func rescanAfterAccessReturn() {
        guard let session = cleanupScanSession, showsSettledScanResults,
              let notice = accessReturnNotice, notice.sessionID == session.id else { return }
        selectedFilter = Self.scanRoute(of: session)
        let ruleIDs = session.deniedRuleIDs(at: notice.paths)
        guard !ruleIDs.isEmpty,
              let rules = try? cleanupRuleSetLoader(),
              rules.rulesVersion == session.rulesVersion,
              session.rulesProvenance.map({ $0 == rules.effectiveProvenance }) ?? true,
              ruleIDs.isSubset(of: Set(rules.rules.map(\.id))),
              CleanupMigration.migrateIfNeeded(activeRules: rules).didComplete else {
            // Review A-R3: the finished session's own coverage, so the
            // locations the notice names are scanned even if the scan
            // preferences changed.
            beginScan(rescanning: session)
            return
        }
        beginNewLocationScan(of: session, ruleIDs: ruleIDs, rules: rules, notice: notice)
    }

    /// D104 G5: scans `ruleIDs` as part of `session` and merges what they
    /// find. The progress page shows while it runs, so the results cannot be
    /// selected or cleaned in between; a plan or dry run made before is
    /// dropped because the results change.
    private func beginNewLocationScan(
        of session: ScanSession,
        ruleIDs: Set<String>,
        rules: CleanupRuleSet,
        notice: ScanAccessReturnNotice
    ) {
#if DEBUG
        guard !isDebugSmartScanSessionFixtureActive else { return }
#endif
        guard !isScanning,
              !isScanningDuplicates,
              !largeFilesWorkspace.isScanning,
              !largeFilesWorkspace.isAnalyzingStorage,
              !duplicateFilesWorkspace.isScanning,
              !isCleanupExecutionActive else { return }
        scanPresentationRoute = activePresentationRoute
        let generation = UUID()
        beginScanPresentation(sessionID: generation)
        mainScanUsesRules = true
        mainScanGeneration = generation
        mainScanProgress = .starting(mode: currentScanMode)
        mainScanLastProgressPublishedAt = nil
        isScanning = true
        isFinalizingMainScan = false
        isCancellingMainScan = false
        scheduleScanningPresentation(for: generation)
        errorMessage = nil
        actionMessage = nil
        accessReturnNotice = nil
        cleanupDryRunSummary = nil
        cleanupPlanTask?.cancel()
        cleanupPlanTask = nil
        cleanupPlanGeneration = nil
        pendingCleanPlan = nil
        pendingCleanPreflight = nil

        let coordinator = heavyWorkCoordinator
        let activityStore = heavyWorkActivityStore
        let operation = cleanupScanOperation
        // The session's own threshold keeps its rows judged alike; exclusions
        // are always the current ones.
        let request = CleanupScanRequest(
            userHomeURL: cleanupUserHomeURL,
            excludedURLs: appPreferences === UserDefaults.standard ? [] : currentV2ExcludedURLs(),
            ignoreList: currentIgnoreListSnapshot(),
            developerInactivityThresholdDays: session.developerInactivityThresholdDays,
            includedRuleIDs: ruleIDs,
            sessionID: session.id
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
                let rescan = try await coordinator.withLease(owner: .mainScan) { _ in
                    await activityStore.refresh()
                    let publish: CleanupScanProgressHandler = { [weak self] progress in
                        await MainActor.run {
                            guard let self,
                                  self.mainScanGeneration == generation else { return }
                            self.publishMainScanProgress(
                                DiskScanProgress(cleanupProgress: progress),
                                force: progress.phase != .enumerating
                            )
                        }
                    }
                    return try await operation(request, publish)
                }
                await activityStore.refresh()
                guard mainScanGeneration == generation else { return }
                guard rescan.outcome != .cancelled,
                      let current = cleanupScanSession, current.id == session.id else {
                    returnToUnchangedResults(.cancelled, matching: generation, offering: notice)
                    showActionMessage(L10n.text(
                        "已停止扫描新位置，结果保持不变，未改动任何文件",
                        "Scanning the new locations stopped; the results are unchanged and no files changed"
                    ))
                    return
                }
                guard let merged = current.mergingRescan(rescan, ofRules: ruleIDs) else {
                    returnToUnchangedResults(.failed, matching: generation, offering: notice)
                    errorMessage = L10n.text(
                        "没能把新位置加入本次结果，结果保持不变，未改动任何文件；可以再试一次",
                        "The new locations could not be added to these results; they are unchanged and no files changed. Try again."
                    )
                    return
                }
                isFinalizingMainScan = true
                // A plan checks its rows against the rules they were found
                // with; these are the session's (same version and fingerprint).
                cleanupActiveRuleSet = rules
                cleanupSelection = cleanupSelection.addingDefaults(forRowsAddedTo: current, in: merged)
                cleanupScanSession = merged
                cleanupWorkflowState = .results(sessionID: merged.id)
                finishScanPresentation(with: .results, matching: generation)
                let stillDenied = merged.permissions.contains {
                    ruleIDs.contains($0.ruleID) && $0.status == .permissionDenied
                }
                showActionMessage(stillDenied
                    ? L10n.text(
                        "已扫描新可读的位置并加入本次结果；仍有位置无法读取，详见扫描范围",
                        "The newly readable locations were scanned and added; some still cannot be read, see the scan coverage"
                    )
                    : L10n.text(
                        "已扫描新可读的位置并加入本次结果；其他结果保持不变",
                        "The newly readable locations were scanned and added; the other results are unchanged"
                    ))
            } catch {
                guard mainScanGeneration == generation else {
                    await activityStore.refresh()
                    return
                }
                if error is CancellationError {
                    returnToUnchangedResults(.cancelled, matching: generation, offering: notice)
                    showActionMessage(L10n.text(
                        "已停止扫描新位置，结果保持不变，未改动任何文件",
                        "Scanning the new locations stopped; the results are unchanged and no files changed"
                    ))
                } else {
                    returnToUnchangedResults(.failed, matching: generation, offering: notice)
                    errorMessage = error.localizedDescription
                }
                await activityStore.refresh()
            }
        }
    }

    /// D104 G5: the scan of the new locations stopped or failed. The results
    /// it would have added to are shown again unchanged, with the notice.
    private func returnToUnchangedResults(
        _ terminalState: SmartScanPresentationState,
        matching generation: UUID,
        offering notice: ScanAccessReturnNotice
    ) {
        finishScanPresentation(with: terminalState, matching: generation)
        if scanPresentation.returnToResults(matching: generation) {
            scanPresentationPhaseStartedAt = Date()
        }
        if cleanupScanSession?.id == notice.sessionID {
            accessReturnNotice = notice
        }
    }

    /// A finished scan's results are on screen (they are also kept after a
    /// cancel or a cleanup) and nothing scans or cleans.
    private var showsSettledScanResults: Bool {
        (scanPresentationState == .results || scanPresentationState.isTerminal)
            && !isPreparingScan
            && !isCleanupExecutionActive
    }

    func dismissAccessReturnNotice() {
        accessReturnNotice = nil
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
        pendingEmptyTrash = nil
        isCheckingTrashSummary = true
        let service = scanHeavyWorkService

        Task {
            do {
                // D101 L5: the confirmation and the deletion use this one frozen list.
                if let frozen = try await service.freezeTrash(), !frozen.entries.isEmpty {
                    pendingEmptyTrash = frozen
                } else {
                    removeTrashItemsFromCurrentResult()
                    showActionMessage(L10n.text("废纸篓已经是空的", "Trash is already empty"))
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            isCheckingTrashSummary = false
        }
    }

    func cancelEmptyTrash() {
        pendingEmptyTrash = nil
    }

    func refreshScanHistory() {
        scanHistorySummary = ScanHistoryService.summary(defaults: scanHistoryDefaults)
    }

    func clearScanHistory() {
        guard canClearScanHistory else { return }
        ScanHistoryService.clear(defaults: scanHistoryDefaults)
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

        let receiptTaskID = UUID()
        operationReportTasks[receiptTaskID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { operationReportTasks[receiptTaskID] = nil }
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
                CleanupHistoryService.recordMovedItems([item], moveRecords: moveRecords, defaults: cleanupPreferences)
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
                _ = await CleanReportStore.recordDetached(partial.report, journal: operationJournal)
                lastCleanReport = partial.report
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

        let receiptTaskID = UUID()
        operationReportTasks[receiptTaskID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { operationReportTasks[receiptTaskID] = nil }
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
                    moveRecords: outcome.moveRecords,
                    defaults: cleanupPreferences
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
                        "清理已停止。已移动的路径保留恢复回执，另有 \(ByteFormat.count(outcome.notProcessedPaths.count)) 条路径未执行。",
                        "Cleanup stopped. Moved paths retain recovery receipts; \(ByteFormat.count(outcome.notProcessedPaths.count)) paths were not executed.")
                } else if outcome.failedTitles.isEmpty {
                    showActionMessage(L10n.text(
                        "\(ByteFormat.count(movedCount)) 个可安全清理项目已移到废纸篓，清空后才释放空间",
                        "\(L10n.items(movedCount)) marked safe to clean moved to Trash; space is freed after Trash is emptied"
                    ))
                } else {
                    let titleList = outcome.failedTitles.prefix(3).joined(
                        separator: L10n.text("、", ", ")
                    )
                    errorMessage = L10n.text(
                        "\(ByteFormat.count(movedCount)) 项已移到废纸篓，\(ByteFormat.count(outcome.failedTitles.count)) 项失败：\(titleList)。清空后才释放空间",
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

    /// D101 L5: D23's two confirmations. Deletes only the entries frozen when
    /// the confirmation opened.
    func confirmEmptyTrash(
        acknowledgesPermanentDeletion: Bool,
        acknowledgesTrashContentsReviewed: Bool
    ) {
        guard let frozen = pendingEmptyTrash,
              acknowledgesPermanentDeletion,
              acknowledgesTrashContentsReviewed,
              canRequestEmptyTrash else { return }
        pendingEmptyTrash = nil
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
                let result = try await coordinator.withLease(owner: .emptyTrash) { lease in
                    await activityStore.refresh()
                    return try await service.emptyTrash(frozen, lease: lease)
                }
                await activityStore.refresh()
                guard emptyTrashGeneration == generation else { return }

                removeTrashItemsFromCurrentResult(deleted: result.deletedNames, in: frozen.trashURL)

                let message = Self.emptyTrashResultMessage(result)
                if result.failedCount > 0 {
                    errorMessage = message
                } else {
                    showActionMessage(message)
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

    /// D101 L5: entries kept or not deleted are named in the result.
    nonisolated static func emptyTrashResultMessage(_ result: FrozenTrashEmptyResult) -> String {
        var parts = [L10n.text(
            "已清空废纸篓：\(ByteFormat.count(result.deletedCount)) 项 · \(ByteFormat.storageString(result.deletedBytes))",
            "Emptied Trash: \(L10n.items(result.deletedCount)) · \(ByteFormat.storageString(result.deletedBytes))"
        )]
        if result.skippedCount > 0 {
            parts.append(L10n.text(
                "\(ByteFormat.count(result.skippedCount)) 项在确认后有变化，已保留",
                "\(L10n.items(result.skippedCount)) changed after confirmation and were kept"
            ))
        }
        if result.failedCount > 0 {
            parts.append(L10n.text(
                "\(ByteFormat.count(result.failedCount)) 项未能删除",
                "\(L10n.items(result.failedCount)) could not be deleted"
            ))
        }
        return parts.joined(separator: L10n.text("；", "; "))
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

    /// Report §4 item 12 (CleanMyMac's Start Over): Performance goes back to
    /// its landing page. The items read stay, so the landing page can say how
    /// many were read last time; Scan there reads them again. Nothing while
    /// they are read or a change runs.
    func startOverStartupItems() {
        guard canRefreshStartupItems else { return }
        hasScannedStartupItems = false
    }

    func refreshStartupItems(
        priority: TaskPriority = .userInitiated,
        includeBackgroundTaskDiagnostic: Bool = false
    ) {
        guard canRefreshStartupItems else { return }
        noteModuleScan(.performance)
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
                    try await fanControlCoordinator.manageStartupItem(plan)
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
        showActionMessage(L10n.text("已在访达中显示，未修改启动项", "Shown in Finder; no startup item was changed"))
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
        let resident = menuBarResidentContext != nil
        guard menuBarMemoryProcessTask == nil, resident ? !isMenuBarRefreshPaused : canAdoptLiveMemoryProcesses,
              resident || memorySnapshot.map({ now.timeIntervalSince($0.generatedAt) >= MenuBarPerformancePolicy.visibleProcessInterval }) ?? true else { return }
        let generation = menuBarMemoryProcessGeneration
        let provider = menuBarMemoryProcessProvider
        menuBarMemoryProcessTask = Task { @MainActor [weak self] in
            let snapshot = await provider()
            let apps = await Task.detached(priority: .utility) {
                resident ? MenuBarProcessCacheBudget.memoryApps(snapshot.appsByResidentUsage) : snapshot.appsByResidentUsage
            }.value
            guard let self else { return }
            menuBarMemoryProcessTask = nil
            guard !Task.isCancelled, generation == menuBarMemoryProcessGeneration else {
                // D127: the memory page reopened while this read ran; its
                // immediate read waited for this one to exit.
                if resident, generation != menuBarMemoryProcessGeneration, menuBarProcessDemand == .memory {
                    refreshMenuBarResidentSamples()
                }
                return
            }
            guard resident ? menuBarResidentContext?.plan?.cadence.suspended == false : canAdoptLiveMemoryProcesses,
                  (resident ? menuBarPreparedMemoryAppsDate : memorySnapshot?.generatedAt)
                    .map({ snapshot.generatedAt >= $0 }) ?? true else { return }
            menuBarPreparedMemoryAppsVersion &+= 1
            menuBarPreparedMemoryAppsDate = snapshot.generatedAt
            menuBarPreparedMemoryApps = apps
            // Background prewarming does not overwrite the main memory page,
            // pending quit selections, optimization or confirmation state.
            if !resident || canAdoptLiveMemoryProcesses { adoptMenuBarMemorySnapshot(snapshot, as: .primaryAndMenuFromRefresh) }
        }
    }

    /// A single visible-page driver. UI callbacks only declare demand; all
    /// enumeration and measurement preparation occurs after the current turn.
    private var menuBarProcessConsumers: [UUID: (PanelSection, UInt64)] = [:]
    private var menuBarProcessConsumerOrder: UInt64 = 0
    func updateMenuBarProcessConsumer(_ id: UUID, section: PanelSection?) {
        // SwiftUI may replay the current plan when rebuilding an onReceive
        // subscription. A replay must not publish or steal another page's
        // priority by advancing this consumer's order.
        if menuBarProcessConsumers[id]?.0 != section {
            menuBarProcessConsumerOrder &+= 1
            menuBarProcessConsumers[id] = section.map { ($0, menuBarProcessConsumerOrder) }
        }
        // Resolve even a replay: pause/resume can change the effective demand
        // while retaining the consumer's declared page and priority.
        let selected = menuBarProcessConsumers.values.filter {
            [.processor, .disk, .power, .memory].contains($0.0)
        }.max { $0.1 < $1.1 }?.0 ?? .overview
        setMenuBarProcessDemand(selected)
    }

    func setMenuBarProcessDemand(_ section: PanelSection) {
        let resolved: PanelSection = isMenuBarRefreshPaused ? .overview : section
        guard resolved != menuBarProcessDemand else { return }
        if menuBarResidentContext != nil {
            if menuBarProcessDemand == .power, resolved != .power { systemEnergyAccumulator.endAttributedObservation() }
            menuBarProcessDemand = resolved
            // D127 (iStat `stopItemsForKey:` then `startItemsForKey:`): leaving a
            // page stops its reads and drops its rates, which described an
            // interval that is over; the next page starts from a new baseline
            // at once. A running physical read keeps the gate (handle kept);
            // its completion starts the new read. Pausing keeps what is shown.
            menuBarVisibleProcessGeneration &+= 1
            menuBarVisibleProcessTask?.cancel()
            cancelMenuBarMemoryProcessRefresh()
            menuBarResidentProcessStartedAt = nil
            menuBarResidentMemoryStartedAt = nil
            menuBarResidentFirstAttemptAt = nil
            menuBarResidentProcessBaselineReset = true
            // D171: assigning nil to nil would still publish (@Published), so
            // a page change with nothing shown and the same pending state
            // published once per change (MenuBarPublishLoopTests).
            if !isMenuBarRefreshPaused, menuBarPreparedProcesses != nil { menuBarPreparedProcesses = nil }
            setMenuBarProcessSampleState(
                pending: [.processor, .disk, .power].contains(resolved) && menuBarPreparedProcesses == nil,
                unavailable: false)
            if [.processor, .disk, .power, .memory].contains(resolved) { refreshMenuBarResidentSamples() }
            return
        }
        menuBarVisibleProcessGeneration &+= 1
        menuBarVisibleProcessTask?.cancel()
        menuBarVisibleProcessTask = nil
        menuBarProcessSampleTimeoutTask?.cancel()
        menuBarProcessSampleTimeoutTask = nil
        cancelMenuBarMemoryProcessRefresh()
        if menuBarProcessDemand == .power, resolved != .power {
            systemEnergyAccumulator.endAttributedObservation()
        }
        menuBarProcessDemand = resolved
        // BOARD N16-2: a page with nothing kept says it is sampling; a kept
        // measurement is shown at once with its time.
        setMenuBarProcessSampleState(
            pending: [.processor, .disk, .power].contains(resolved)
                && menuBarPreparedProcesses == nil,
            unavailable: false)
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else {
            setMenuBarProcessSampleState(pending: false, unavailable: false)
            return
        }
#endif
        guard [.processor, .disk, .power, .memory].contains(resolved) else { return }
        let generation = menuBarVisibleProcessGeneration
        let sampler = menuBarContinuousProcessSampler
        // D171: a page with nothing kept lists its first read at once.
        let listsFirstRead = menuBarPreparedProcesses == nil && MenuBarProcessSamplingDemand.listsFirstRead(resolved)
        // Review P2-8: "正在采样…" lasts until the first measurement or the
        // timeout; then the page says "未测量" and why. Sampling continues.
        if isMenuBarProcessSamplePending {
            let timeout = menuBarProcessSampleTimeout
            menuBarProcessSampleTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled,
                      menuBarVisibleProcessGeneration == generation,
                      isMenuBarProcessSamplePending else { return }
                setMenuBarProcessSampleState(pending: false, unavailable: true)
            }
        }
        menuBarVisibleProcessTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await sampler.reset()
            // The first read is the baseline (D171: listed at once on the CPU
            // and disk pages); the first measurement follows after a short
            // interval, later ones at the regular cadence.
            var isBaseline = resolved != .memory
            while !Task.isCancelled {
                let started = ContinuousClock.now
                guard let self, !isMenuBarRefreshPaused,
                      menuBarVisibleProcessGeneration == generation else { return }
                if resolved == .memory {
                    refreshMenuBarMemoryProcesses()
                } else {
                    let worker = Task.detached(priority: .utility) {
                        guard let snapshot = await sampler.sample(listingFirstRead: listsFirstRead),
                              !Task.isCancelled else { return Optional<MenuBarPreparedProcesses>.none }
                        return MenuBarPreparedProcesses(snapshot: snapshot)
                    }
                    let prepared = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, !isMenuBarRefreshPaused,
                          menuBarVisibleProcessGeneration == generation else { return }
                    if let prepared { adoptMenuBarProcesses(prepared) }
                }
                let interval = isBaseline
                    ? MenuBarPerformancePolicy.firstProcessSampleInterval
                    : max(MenuBarPerformancePolicy.visibleProcessInterval, menuBarRefreshInterval.seconds)
                isBaseline = false
                let elapsed = started.duration(to: .now)
                let remaining = Duration.seconds(interval) - elapsed
                do { try await Task.sleep(for: max(.milliseconds(1), remaining)) }
                catch { return }
            }
        }
    }

    /// Demand callbacks and sampler completions share the same equality gate.
    /// @Published sends objectWillChange even when a Bool is assigned itself.
    private func setMenuBarProcessSampleState(pending: Bool, unavailable: Bool) {
        if isMenuBarProcessSamplePending != pending {
            isMenuBarProcessSamplePending = pending
        }
        if isMenuBarProcessSampleUnavailable != unavailable {
            isMenuBarProcessSampleUnavailable = unavailable
        }
    }

    /// Shows a process read of the current page (both drivers).
    private func adoptMenuBarProcesses(_ prepared: MenuBarPreparedProcesses) {
        menuBarPreparedProcesses = prepared
        setMenuBarProcessSampleState(pending: false, unavailable: false)
        if menuBarProcessDemand == .power {
            systemEnergyAccumulator.recordAttributed(prepared.snapshot,
                powerSource: menuBarAuxiliaryMonitorState.batterySnapshot?.powerSource ?? .unknown,
                continuous: true)
        }
    }

    /// D171: the resident first read, unless a page change or a suspension
    /// superseded it while it ran.
    private func adoptFirstMenuBarProcessRead(_ prepared: MenuBarPreparedProcesses, generation: Int) {
        guard !Task.isCancelled, generation == menuBarVisibleProcessGeneration,
              menuBarResidentContext?.plan?.cadence.suspended == false else { return }
        adoptMenuBarProcesses(prepared)
    }

    /// One counter-frame read off the main actor; cancelling the caller
    /// cancels it, and the caller's handle stays until the read exits.
    nonisolated private static func readMenuBarProcesses(
        _ sampler: MenuBarProcessSampler, resettingBaseline: Bool, listingFirstRead: Bool
    ) async -> MenuBarPreparedProcesses? {
        let worker = Task.detached(priority: .utility) {
            if resettingBaseline { await sampler.reset() }
            return await sampler.sample(listingFirstRead: listingFirstRead).flatMap { snapshot in
                MenuBarPreparedProcesses.fitsCache(snapshot) ? MenuBarPreparedProcesses(snapshot: snapshot) : nil
            }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
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

    /// D144 "释放内存": the bounded push (`MemoryReclaimer`) under the
    /// memory lease. `cancelMemoryOptimization()` stops it between steps.
    func optimizeMemory() {
        guard canOptimizeMemory else { return }
        isOptimizingMemory = true
        isReclaimingMemory = true
        errorMessage = nil
        let generation = UUID()
        memoryOptimizationGeneration = generation
        let coordinator = heavyWorkCoordinator
        let service = scanHeavyWorkService
        let activityStore = heavyWorkActivityStore

        memoryOptimizationTask = Task { @MainActor [weak self] in
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
                showActionMessage(result.reclaim.map(Self.memoryReclaimMessage)
                    ?? memoryOptimizationMessage(for: result.status))
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
            isReclaimingMemory = false
            refreshMenuBarMonitor()
        }
    }

    /// One line for the push, from what was measured (never "已释放 N" for
    /// cache macOS already counted as available).
    nonisolated static func memoryReclaimMessage(_ outcome: MemoryReclaimer.Outcome) -> String {
        switch outcome.stopReason {
        case .nothingToReclaim:
            return L10n.text("可收回的文件缓存不多，无需释放", "Little file cache to hand back; nothing was done")
        case .pressureAlreadyRaised:
            return L10n.text("内存压力已升高，请退出占用多的应用", "Memory pressure is raised; quit apps that use a lot of memory")
        case .cancelled:
            return L10n.text("已取消释放内存，占用的内存已归还", "Freeing up memory was cancelled; memory was returned")
        default:
            guard let gained = outcome.idleDeltaBytes, gained > 0 else {
                return L10n.text("已请求系统收回缓存，空闲内存没有明显变化", "Asked the system to hand back cache; idle memory did not change noticeably")
            }
            return L10n.text("空闲内存增加 \(ByteFormat.memoryString(gained))", "Idle memory up by \(ByteFormat.memoryString(gained))")
        }
    }

    /// A click on the changed "退出高占用应用" button sooner than this after the
    /// first click is the second half of a double click and does nothing.
    /// Review P2-9: the user's double-click interval (System Settings;
    /// 0.5 s by default), at least `minimumRecommendedMemoryActionDebounce`.
    static var recommendedMemoryActionDebounce: TimeInterval {
        recommendedMemoryActionDebounce(doubleClickInterval: NSEvent.doubleClickInterval)
    }

    static let minimumRecommendedMemoryActionDebounce: TimeInterval = 0.6

    static func recommendedMemoryActionDebounce(doubleClickInterval: TimeInterval) -> TimeInterval {
        guard doubleClickInterval.isFinite else { return minimumRecommendedMemoryActionDebounce }
        return max(minimumRecommendedMemoryActionDebounce, doubleClickInterval)
    }

    /// The memory page's recommended action. The first click selects the
    /// suggested apps and the button becomes "退出高占用应用"; a later click asks
    /// for confirmation (the main window's "退出所选应用？", which names the
    /// apps). Nothing quits before the confirmation's own button (BOARD N19).
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
                if let preparedAt = recommendedMemorySelectionPreparedAt,
                   memoryActionUptime() - preparedAt < Self.recommendedMemoryActionDebounce {
                    return
                }
                requestQuitSelectedMemoryProcesses()
                return
            }
            guard selectRecommendedMemoryApps() else {
                showActionMessage(L10n.text("当前没有适合自动建议退出的后台应用", "No background app is currently suitable for a quit recommendation"))
                return
            }
            recommendedMemorySelectionPreparedAt = memoryActionUptime()
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
        guard menuBarRefreshInterval != interval else { return }
        menuBarRefreshInterval = interval
    }

    func toggleMenuBarRefreshPaused() {
        isMenuBarRefreshPaused.toggle()
        if isMenuBarRefreshPaused {
            if menuBarResidentContext != nil { suspendMenuBarResidentSampling() }
            systemEnergyAccumulator.markObservationGap()
            setMenuBarProcessDemand(.overview)
            cancelMenuBarMemoryProcessRefresh()
            menuBarMemoryStatusGeneration &+= 1
            menuBarMemoryStatusTask?.cancel()
            samplingGaps.begin(.paused)
        } else {
            samplingGaps.end(.paused)
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
        if menuBarResidentContext != nil,
           isMenuBarRefreshPaused || menuBarResidentContext?.plan?.cadence.suspended == true { return }
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

        let primaryGeneration = menuBarResidentPrimaryGeneration
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

        guard primaryGeneration == menuBarResidentPrimaryGeneration,
              menuBarResidentContext?.plan?.cadence.suspended != true else { return }
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
        fanControlCoordinator.process(snapshot: result.snapshot)
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
                    let resident = menuBarResidentContext != nil
                    Task { @MainActor [weak self] in
                        let apps = await Task.detached(priority: .utility) {
                            resident ? MenuBarProcessCacheBudget.memoryApps(snapshot.appsByResidentUsage) : snapshot.appsByResidentUsage
                        }.value
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
            estimatedBytes: selectedApps.reduce(0) { $0 + $1.bytes },
            appNames: selectedApps.map(\.name)
        )
        isMemoryBatchQuitConfirmationPresentedInMenuBar = presentConfirmationInMenuBar
    }

    /// D2 supplement: the simple panel asks to quit exactly the suggested
    /// apps its card lists. They become the selection and the confirmation
    /// names them; nothing quits before the user confirms.
    func requestQuitMemoryApps(_ apps: [MemoryAppUsage], presentConfirmationInMenuBar: Bool) {
        guard canRequestMemoryQuitActions, canEditMemorySelection else { return }
        let processIDs = Set(apps.filter(\.canQuit).flatMap(\.selectableProcessIDs))
        guard !processIDs.isEmpty else {
            showActionMessage(L10n.text("当前没有适合自动建议退出的后台应用", "No background app is currently suitable for a quit recommendation"))
            return
        }
        let previousSelection = selectedMemoryProcessIDs
        selectedMemoryProcessIDs = processIDs
        requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: presentConfirmationInMenuBar)
        if pendingMemoryQuitSummary != nil {
            memorySelectionBeforeQuitRequest = previousSelection
        }
    }

    /// The selection `requestQuitMemoryApps` replaced for its confirmation;
    /// cancelling that confirmation gives it back (BOARD N11-3).
    private var memorySelectionBeforeQuitRequest: Set<Int32>?

    func cancelQuitSelectedMemoryProcesses() {
        memoryCoordinator.cancel()
        memoryOptimizationState = memoryCoordinator.state
        let replacedSelection = memorySelectionBeforeQuitRequest
        clearPendingMemoryQuitConfirmation()
        if let replacedSelection {
            selectedMemoryProcessIDs = replacedSelection
        }
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
        isReclaimingMemory = false
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

    /// Report §4 item 12 (CleanMyMac's Start Over): Applications goes back to
    /// its landing page; Scan there reads the apps again. Nothing while they
    /// are read, an uninstall runs or related files are being cleaned. (The
    /// manager clears its own ticks: `ApplicationsManagerModel.startOver`.)
    func startOverInstalledApps() {
        guard canRefreshInstalledApps else { return }
        hasScannedInstalledApps = false
    }

    func refreshInstalledApps(priority: TaskPriority = .userInitiated) {
        guard canRefreshInstalledApps else { return }
        cancelUninstall()
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
        uninstallResult = nil
        uninstallResultReports = []
        uninstallInFlightReport = nil
        uninstallProgress = nil
        residualUninstallReport = nil
        completedUninstallApplication = nil
        operationRecoveryResult = nil
        pendingUninstallApp = app
        uninstallSelectedPaths = []
        isPreparingUninstall = true
        uninstallPreparationTask?.cancel()
        let generation = UUID()
        uninstallPreparationID = generation
        let inventory = installedApps
        let complete = installedAppsScanCoverage?.isComplete == true
        let homeDirectory = cleanupUserHomeURL
        uninstallPreparationTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                UninstallOwnershipVerifier.prepare(app, inventory: inventory, complete: complete, homeDirectory: homeDirectory)
            }
            let prepared = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, uninstallPreparationID == generation else { return }
            pendingUninstallApp = prepared
            // D1: only the application itself by default. Verified related
            // files stay unchecked until the user selects them.
            uninstallSelectedPaths = []
            isPreparingUninstall = false
        }
    }

    func prepareResidualUninstall(_ report: CleanReport) {
        guard !isUninstallingApp, !isRestoringRecordedOperation else { return }
        cancelUninstall()
        let generation = UUID(); uninstallPreparationID = generation
        let homeDirectory = cleanupUserHomeURL
        isPreparingUninstall = true
        uninstallPreparationTask = Task {
            defer { if uninstallPreparationID == generation { isPreparingUninstall = false } }
            do {
                let inventory = await AppUninstallService.scanInstalledAppsFromSharedInventory()
                guard !Task.isCancelled, uninstallPreparationID == generation else { return }
                let (app, receipt) = try await Task.detached(priority: .userInitiated) {
                    try AppUninstallService.residualReview(report, inventory: inventory.apps, complete: inventory.coverage.isComplete, homeDirectory: homeDirectory)
                }.value
                guard !Task.isCancelled, uninstallPreparationID == generation else { return }
                pendingUninstallApp = app
                uninstallResult = nil; uninstallResultReports = []; uninstallInFlightReport = nil
                uninstallProgress = nil; operationRecoveryResult = nil
                residualUninstallReport = report; completedUninstallApplication = receipt
                // D1: leftovers are not preselected either; cleaning needs a choice.
                uninstallSelectedPaths = []
            } catch { if uninstallPreparationID == generation { errorMessage = error.localizedDescription } }
        }
    }

    /// "Retry unfinished" is offered only once the application itself moved
    /// (in this result or, for leftovers, by an earlier receipt) or was
    /// refused in place; never after an unknown move, a restore or a receipt
    /// that could not be saved.
    var canRetryUninstall: Bool {
        guard let app = pendingUninstallApp, let result = uninstallResult,
              confirmedUninstallPlan?.app.path == app.path,
              !isUninstallingApp, !isRestoringRecordedOperation else { return false }
        return AppUninstallService.canRetryUninstall(result.display, applicationPath: app.path,
                                                     applicationAlreadyMoved: completedUninstallApplication != nil)
    }

    /// One place that keeps the review consistent: while an uninstall runs only
    /// the progress changes (the saved receipts plus the running one) and
    /// `uninstallResult` stays nil; otherwise the result shows the receipts.
    private func publishUninstallReview() {
        if isUninstallingApp {
            uninstallProgress = UninstallReviewResult(receipts: uninstallResultReports, inFlight: uninstallInFlightReport)
        } else {
            uninstallResult = UninstallReviewResult(receipts: uninstallResultReports)
            uninstallProgress = uninstallResult
        }
    }

    func confirmUninstall(selectedPaths: Set<String> = [], retrying: Bool = false) {
        guard let app = pendingUninstallApp, !isPreparingUninstall, canRequestUninstall(app) else { return }
        guard !retrying || canRetryUninstall else { return }
        let plan: UninstallPlan
        do {
            if retrying, let confirmedUninstallPlan { plan = confirmedUninstallPlan }
            else { plan = try UninstallPlan(app: app, selectedPaths: selectedPaths, homeDirectory: cleanupUserHomeURL) }
        }
        catch { errorMessage = error.localizedDescription; return }
        errorMessage = nil
        uninstallPermissionDenied = false
        uninstallDeniedApp = nil
        isUninstallingApp = true
        isCancellingUninstall = false
        // A retry adds a receipt. Earlier receipts stay part of this result,
        // so items they moved are never shown as kept or left out of restore.
        let previous = retrying ? uninstallResult?.display : nil
        if !retrying { uninstallResultReports = [] }
        uninstallInFlightReport = nil
        confirmedUninstallPlan = plan
        uninstallResult = nil
        publishUninstallReview()
        uninstallSessionID = plan.id
        let coordinator = heavyWorkCoordinator
        let applicationReceipt = completedUninstallApplication
        let journal = operationJournal, moves = uninstallMoves
        uninstallTask = Task {
            defer {
                if uninstallSessionID == plan.id {
                    isUninstallingApp = false
                    isCancellingUninstall = false
                    uninstallTask = nil
                    uninstallInFlightReport = nil
                    // The result appears exactly when the run ends, from the
                    // receipts as they are now (never a copy captured earlier).
                    publishUninstallReview()
                }
            }
            do {
                let result = try await coordinator.withLease(owner: .cleanup) { lease in
                    await AppUninstallService.execute(plan, coordinator: coordinator, lease: lease, retrying: previous,
                        completedApplication: applicationReceipt,
                        recycle: moves.recycle, authorization: moves.authorization,
                        persist: { try journal.checkpoint($0, expectedIdentities: $1) },
                        progress: { report in
                            await MainActor.run {
                                guard self.uninstallSessionID == plan.id else { return }
                                self.uninstallInFlightReport = report
                                self.publishUninstallReview()
                            }
                        })
                }
                guard uninstallSessionID == plan.id, let report = result.report else { return }
                // Save before publishing: a restore started from the result must
                // never be followed by this older copy of the receipt.
                let saved = await CleanReportStore.recordDetached(report, journal: journal)
                guard uninstallSessionID == plan.id else { return }
                lastCleanReport = report
                // Append to the receipts as they are now: a restore from Operation
                // History may have updated an earlier one while this was saved.
                uninstallResultReports.append(report)
                if !saved || report.persistenceFailure != nil {
                    errorMessage = L10n.text("卸载回执未能完整保存，请保留当前结果。", "The uninstall receipt could not be fully saved. Keep this result.")
                }
                if let receipt = report.restorableReceipts.first(where: { $0.originalPath == app.path }) {
                    completedUninstallApplication = receipt
                    installedApps.removeAll { $0.id == app.id }
                }
                // Keep the review open as an itemized result. No second cleanup prompt.
            } catch {
                // A retry that could not start keeps showing the earlier result.
                guard uninstallSessionID == plan.id else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelUninstall() {
        guard isUninstallingApp else {
            uninstallPreparationTask?.cancel()
            uninstallPreparationID = nil
            isPreparingUninstall = false
            pendingUninstallApp = nil
            uninstallSelectedPaths = []
            return
        }
        isCancellingUninstall = true
        uninstallTask?.cancel()
    }

    /// Finder can request macOS authorization for an installer-owned app. A
    /// handoff is not an uninstall receipt: only the user can complete it there.
    func revealDeniedUninstallAppInFinder() {
        defer {
            uninstallDeniedApp = nil
            uninstallPermissionDenied = false
            errorMessage = nil
        }
        guard let app = uninstallDeniedApp else { return }
        guard AppUninstallService.scannedApplicationStillAtPath(app) else {
            showActionMessage(L10n.text(
                "应用已变化，请重新读取应用列表后再操作。",
                "The app changed. Refresh the application list before continuing."
            ))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }

    func keepRelatedAppFiles() {
        pendingRelatedCleanupApp = nil
    }

    func confirmRelatedAppCleanup(selectedPaths: Set<String>) {
        guard let app = pendingRelatedCleanupApp, !isCleaningRelatedAppFiles else { return }
        let reviewed = Set(AppUninstallService.reviewableRelatedItems(for: app, homeDirectory: cleanupUserHomeURL).map(\.path))
        guard !selectedPaths.isEmpty, selectedPaths.isSubset(of: reviewed) else { return }
        errorMessage = nil
        isCleaningRelatedAppFiles = true
        let homeDirectory = cleanupUserHomeURL
        let journal = operationJournal

        let receiptTaskID = UUID()
        operationReportTasks[receiptTaskID] = Task {
            defer { operationReportTasks[receiptTaskID] = nil }
            let result: AppUninstallTrashResult
            do {
                result = try await heavyWorkCoordinator.withLease(owner: .cleanup) { _ in
                    try Task.checkCancellation()
                    return await Task.detached(priority: .userInitiated) {
                        AppUninstallService.moveRelatedItemsToTrash(for: app, selectedPaths: selectedPaths,
                            homeDirectory: homeDirectory,
                            persist: { try journal.checkpoint($0, expectedIdentities: $1) })
                    }.value
                }
            } catch {
                errorMessage = error.localizedDescription
                isCleaningRelatedAppFiles = false
                pendingRelatedCleanupApp = nil
                return
            }
            if let report = result.report {
                let saved = await CleanReportStore.recordDetached(report, journal: operationJournal)
                lastCleanReport = report
                if !saved || report.persistenceFailure != nil {
                    errorMessage = L10n.text("关联文件回执未能完整保存，请保留当前结果。", "Related file receipts could not be fully saved. Keep this result.")
                }
                refreshOperationReports()
            }
            if result.movedRelatedItems.isEmpty && result.unresolvedRelatedCount == 0 {
                showActionMessage(L10n.text(
                    "没有可清除的关联文件，原有数据已保留",
                    "No associated files were removed; existing data was kept"
                ))
            } else if !result.movedRelatedItems.isEmpty {
                showActionMessage(L10n.text(
                    "已将 \(ByteFormat.count(result.movedRelatedItems.count)) 个关联文件移到废纸篓，共 \(ByteFormat.storageString(result.movedRelatedBytes))",
                    "\(ByteFormat.count(result.movedRelatedItems.count)) associated files moved to Trash, \(ByteFormat.storageString(result.movedRelatedBytes)) total"
                ))
            }
            if result.unresolvedRelatedCount > 0 && errorMessage == nil {
                errorMessage = L10n.text(
                    "有 \(ByteFormat.count(result.unresolvedRelatedCount)) 个关联文件未能处理",
                    "\(ByteFormat.count(result.unresolvedRelatedCount)) associated files could not be processed"
                )
            }
            isCleaningRelatedAppFiles = false
            pendingRelatedCleanupApp = nil
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
            "已将 \(app.name) 和 \(ByteFormat.count(result.movedRelatedItems.count)) 个关联文件移到废纸篓，共 \(ByteFormat.storageString(result.movedBytes))；清空后才释放空间",
            "\(app.name) and \(ByteFormat.count(result.movedRelatedItems.count)) associated files moved to Trash, \(ByteFormat.storageString(result.movedBytes)) total; space is freed after Trash is emptied"
        )

        guard result.unresolvedRelatedCount > 0 else { return base }

        return L10n.text(
            "\(base)。\(ByteFormat.count(result.unresolvedRelatedCount)) 个关联文件未处理，可在详情里复核。",
            "\(base). \(ByteFormat.count(result.unresolvedRelatedCount)) associated files were not processed; review details if needed."
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

    private func refreshVisibleAppUpdateInventory() {
        switch appUpdatePresentationState.phase {
        case .managing:
            showAppUpdateManager()
        case .scanSummary:
            showAppUpdateScanSummary()
        default:
            break
        }
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
            applicationIDs.contains($0.id) && $0.canJoinSelectedUpdateBatch
        }
        guard !selected.isEmpty else {
            showActionMessage(L10n.text(
                "所选项目没有可处理的更新",
                "The selection has no eligible updates"
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
                      [.failed, .cancelled].contains(task.state)
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
            appUpdateCancellationRequestedSessionID = nil
            pendingAppUpdateReport = nil
            isRunningOneClickUpdate = true
            do {
                try await coordinator.retry(applicationIDs: Set(retryableIDs))
                guard let current = await coordinator.currentSnapshot() else {
                    throw ApplicationUpdateCoordinatorError.noActiveSession
                }
                appUpdateExpectedSessionID = current.plan.id
                beginAppUpdatePresentationSession(sessionID: current.plan.id)
                appUpdateQueueSnapshot = current
                publishAppUpdateSession(current)
                // Subscribe before retry, then bind the buffered stream to the
                // new batch. A fast worker cannot drain before monitoring starts.
                startApplicationUpdateCoordinatorMonitor(sessionID: current.plan.id, events: events)
            } catch {
                stopApplicationUpdateCoordinatorMonitor()
                isRunningOneClickUpdate = false
                errorMessage = error.localizedDescription
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
        // D106: the scan runs brew, mas and msupdate, contacts update servers
        // and can resume a saved queue that relaunches or installs apps.
        guard !AcceptanceLaunch.isActive else {
            showActionMessage(L10n.text("验收模式不检查应用更新。", "Acceptance mode does not check for app updates."))
            return
        }
        // D202: the updater's own check; what it finds is not Smart Care's.
        if appUpdateScanOperation == nil, canRefreshAppUpdates { noteModuleScan(.applications) }
        runAppUpdateCheck(resumesSavedQueue: true)
    }

    /// D168: Smart Care's check only reads. It neither resumes a saved update
    /// queue nor the website update assistant, nor runs the automatic-update
    /// policy; the updater's own check (above) still does all three.
    func checkAppUpdatesForSmartCare() {
        // D106: an acceptance session checks nothing (see above).
        guard !AcceptanceLaunch.isActive else { return }
        runAppUpdateCheck(resumesSavedQueue: false)
    }

    private func runAppUpdateCheck(resumesSavedQueue: Bool) {
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
        let ignoreSnapshot = currentIgnoreListSnapshot()
        let ignoredVersionSnapshot = appPreferences === UserDefaults.standard ? [:] : AppUpdateIgnoreService.ignoredVersions(defaults: appPreferences)
        let sourceConfiguration = AppUpdateSourcePreferences.configuration(defaults: appPreferences)
        let preferences = ApplicationUpdatePreferences.snapshot(defaults: appPreferences)
        let additionalDirectoryBookmarks = FolderAccessGrantService.savedAccessBookmarkData(defaults: appPreferences)
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
                                self.upsertIncrementalAppUpdates(ignoreSnapshot.applying(to: applications))
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
                    if ignoreSnapshot.ignoresApplication(bundleIdentifier: item.bundleIdentifier, path: item.path, category: .updates, latestVersion: item.latestVersion)
                        || (item.latestVersion.map { ignoredVersionSnapshot[AppUpdateIgnoreService.identifier(for: item)] == $0.trimmed } ?? false) {
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
                ApplicationUpdateCheckSchedule.markChecked(defaults: appPreferences)
                appUpdateScanState = .ready
                if !isPostUpdateRefresh, let presentationToken {
                    transitionAppUpdatePresentation(
                        to: .managing(AppUpdateCatalogSnapshot(sessionID: generation, applications: apps)),
                        token: presentationToken
                    )
                }
                if resumesSavedQueue {
                    await restoreApplicationUpdateQueueIfNeeded(applications: apps)
                    await restoreWebsiteUpdateAssistantIfNeeded(applications: apps)
                }
                if isPostUpdateRefresh {
                    finishPendingAppUpdateReportAfterRefresh()
                } else if !isRunningOneClickUpdate, resumesSavedQueue {
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
        guard !AcceptanceLaunch.isActive else { return }
        guard ApplicationUpdateCheckSchedule.shouldCheck(preferences: ApplicationUpdatePreferences.snapshot(defaults: appPreferences), defaults: appPreferences), canRefreshAppUpdates else { return }
        pendingAutomaticUpdateEvaluation = true
        refreshAppUpdates()
    }

    private func evaluateAutomaticUpdatePolicyAfterScanIfNeeded() {
        guard allowsLiveAppUpdateActions else { return }
        guard pendingAutomaticUpdateEvaluation else { return }
        pendingAutomaticUpdateEvaluation = false
        let preferences = ApplicationUpdatePreferences.snapshot(defaults: appPreferences)
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
                detail: "\(ByteFormat.count(progress.scannedCount)) / \(ByteFormat.count(progress.discoveredCount))",
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
                detail: "\(ByteFormat.count(progress.scannedCount)) / \(ByteFormat.count(progress.discoveredCount))",
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

    // Feature-owned recovery UI uses the existing coordinator and presentation.
    // No second queue/executor is created by the view.
    func appUpdateRecoveryStatus() async -> ApplicationUpdateRecoveryStatus {
        await applicationUpdateCoordinator.recoveryStatus()
    }

    func verifyAndReleaseAppUpdate(applicationID: String) async throws {
        try await applicationUpdateCoordinator.verifyAndRelease(applicationID: applicationID, applications: appUpdates)
        appUpdateQueueSnapshot = await applicationUpdateCoordinator.currentSnapshot()
        if let current = appUpdateQueueSnapshot {
            publishAppUpdateSession(current)
            if current.tasks.allSatisfy(\.state.isTerminal), !current.tasks.contains(where: \.requiresInstallationReconciliation) {
                appUpdatesAutoRescanPending = true
                refreshAppUpdates()
            }
        }
    }

    func acknowledgeDamagedAppUpdateQueue() async throws {
        try await applicationUpdateCoordinator.acknowledgeDamagedQueue()
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
               restored.tasks.contains(where: { !$0.state.isTerminal || $0.requiresInstallationReconciliation }) {
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

    func currentIgnoreListSnapshot() -> IgnoreListSnapshot {
        ignoreListStore?.snapshot() ?? .empty
    }

    // MARK: D207 ignore list in the managers (CleanMyMac: Add to Ignore List · Put Back)

    /// D207: each candidate's ignore-list category, as the scan files its rule
    /// (`IgnoreCategory.cleanup(for:)`).
    func cleanupIgnoreCategories(in session: ScanSession) -> [ScanCandidateID: IgnoreCategory] {
        var categories: [ScanCandidateID: IgnoreCategory] = [:]
        for category in session.categories {
            for subcategory in category.subcategories {
                for candidate in subcategory.candidates {
                    categories[candidate.id] = .cleanup(for: CareJunkGroup.group(categoryID: category.id, candidates: [candidate]))
                }
            }
        }
        return categories
    }

    var canIgnoreCleanupCandidates: Bool { canEditV2CleanupSelection && cleanupScanSession != nil }

    /// D207 (CleanMyMac's Add to Ignore List in the Cleanup Manager): the
    /// candidates go on the ignore list under their rule's junk category and
    /// leave this result as a scan leaves out what the list covers — out of
    /// the groups, the totals and the selection, among the ignored. A whole
    /// folder holding what the list now covers leaves too. Put Back returns
    /// them, selected as they were. Not while a cleanup is planned or runs.
    func ignoreCleanupCandidates(_ ids: [ScanCandidateID]) {
        guard canIgnoreCleanupCandidates, let session = cleanupScanSession else { return }
        let requested = Set(ids)
        let categories = cleanupIgnoreCategories(in: session)
        let chosen = session.candidates.filter { requested.contains($0.id) }
        guard !chosen.isEmpty, let snapshot = ignoreFeedback.add(chosen.map { candidate in
            IgnoreListFeedback.Item(target: IgnoreListTarget(path: candidate.snapshot.standardizedPath),
                                    category: categories[candidate.id] ?? .systemJunk,
                                    name: CareStudioCandidateRow.title(for: candidate))
        }) else { return }
        let covered = Set(session.candidates.filter {
            snapshot.ignores(path: $0.snapshot.standardizedPath, category: categories[$0.id] ?? .systemJunk,
                             includingDescendants: true)
        }.map(\.id))
        guard !covered.isEmpty else { return }
        let wasSelected = cleanupSelection.selectedCandidateIDs.intersection(covered)
        setCleanupCandidates(Array(covered), selected: false)
        let (remaining, held) = session.holdingBack(covered)
        cleanupScanSession = remaining
        ignoreFeedback.onPutBack { [weak self] snapshot in
            self?.putBackCleanupCandidates(held, categories: categories, selected: wasSelected, snapshot: snapshot)
        }
    }

    /// Put Back: what the list no longer covers returns to this session.
    private func putBackCleanupCandidates(_ held: [HeldCleanupCandidate], categories: [ScanCandidateID: IgnoreCategory],
                                          selected: Set<ScanCandidateID>, snapshot: IgnoreListSnapshot) {
        guard canIgnoreCleanupCandidates, let session = cleanupScanSession else { return }
        let returning = held.filter {
            !snapshot.ignores(path: $0.candidate.snapshot.standardizedPath, category: categories[$0.candidate.id] ?? .systemJunk,
                              includingDescendants: true)
        }
        cleanupScanSession = session.puttingBack(returning)
        setCleanupCandidates(Array(selected.intersection(returning.map(\.candidate.id))), selected: true)
    }

    func canAddAppUpdateToIgnoreList(_ app: AppUpdateItem) -> Bool {
        canModifyAppUpdateList && app.updateStatus != .ignored && appUpdates.contains { $0.id == app.id }
    }

    /// D207 (CleanMyMac's Add to Ignore List in the updater): these apps'
    /// updates go on the ignore list for good. Their rows say "已忽略" and
    /// leave the counts, the plan and the batches, as a check marks them; Put
    /// Back gives each row the state it had.
    func ignoreAppUpdates(_ apps: [AppUpdateItem]) {
        let chosen = apps.filter(canAddAppUpdateToIgnoreList)
        guard !chosen.isEmpty, let snapshot = ignoreFeedback.add(chosen.map { app in
            IgnoreListFeedback.Item(target: .application(bundleIdentifier: app.bundleIdentifier, path: app.path),
                                    category: .updates, name: app.name)
        }) else { return }
        let marked = snapshot.applying(to: appUpdates)
        var previous: [String: AppUpdateItem] = [:]
        for (old, new) in zip(appUpdates, marked) where new.updateStatus == .ignored && old.updateStatus != .ignored {
            previous[old.id] = old
        }
        guard !previous.isEmpty else { return }
        appUpdates = marked
        ignoredAppUpdateCount = appUpdates.filter { $0.updateStatus == .ignored }.count
        refreshVisibleAppUpdateInventory()
        ignoreFeedback.onPutBack { [weak self] snapshot in self?.putBackAppUpdates(previous, snapshot: snapshot) }
    }

    /// Put Back: rows the list no longer covers get the state they had.
    private func putBackAppUpdates(_ previous: [String: AppUpdateItem], snapshot: IgnoreListSnapshot) {
        guard canModifyAppUpdateList else { return }
        appUpdates = appUpdates.map { app in
            guard let old = previous[app.id], app.updateStatus == .ignored,
                  !snapshot.ignoresApplication(bundleIdentifier: app.bundleIdentifier, path: app.path, category: .updates,
                                               latestVersion: app.latestVersion) else { return app }
            var restored = app
            restored.updateStatus = old.updateStatus
            restored.canAutomaticallyUpdate = old.canAutomaticallyUpdate
            restored.requiresUserInteraction = old.requiresUserInteraction
            return restored
        }
        ignoredAppUpdateCount = appUpdates.filter { $0.updateStatus == .ignored }.count
        refreshVisibleAppUpdateInventory()
    }

    func ignoreAppUpdate(_ app: AppUpdateItem) {
        guard canIgnoreAppUpdate(app) else { return }
        AppUpdateIgnoreService.ignore(app, defaults: appPreferences)
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
        AppUpdateIgnoreService.clear(defaults: appPreferences)
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
        let guidedIDs = plan.guidedWebsiteApps.map(\.id)
        if !guidedIDs.isEmpty {
            prepareWebsiteUpdateAssistant(applicationIDs: guidedIDs)
        }
        guard plan.hasAutomaticUpdates else {
            showActionMessage(L10n.text(
                "已准备需你确认的更新；打开入口并复查版本后才会标记完成",
                "Updates requiring your confirmation are ready; completion requires opening the source and rechecking the installed version"
            ))
            return
        }
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
                   existing.tasks.allSatisfy(\.state.isTerminal), !existing.tasks.contains(where: \.requiresInstallationReconciliation) {
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
        let skipped = snapshot.tasks.filter { $0.state == .skipped }.count
        let skipReasons = snapshot.tasks.filter { $0.state == .skipped }.compactMap(\.detail).joined(separator: "；")
        let providers = Set(snapshot.tasks.map { task in
            appUpdates.first(where: { $0.id == task.applicationID })?.source.trimmed.nonEmpty
                ?? task.providerIdentifier.rawValue
        }).sorted().joined(separator: " / ")
        let executableApplicationIDs = Set(
            snapshot.plan.automaticApplicationIDs + snapshot.plan.requiresQuitApplicationIDs
                + snapshot.plan.requiresAuthorizationApplicationIDs
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
                status: appStoreFailed > 0 || appStoreCancelled > 0 ? .failed : (appStoreSkipped == automaticAppStoreTasks.count ? .skipped : .succeeded),
                command: nil,
                detail: L10n.text(
                    "App Store 自动队列：\(ByteFormat.count(appStoreCompleted)) 个成功，\(ByteFormat.count(appStoreFailed)) 个失败，\(ByteFormat.count(appStoreCancelled)) 个取消，\(ByteFormat.count(appStoreSkipped)) 个跳过",
                    "App Store automatic queue: \(ByteFormat.count(appStoreCompleted)) succeeded, \(ByteFormat.count(appStoreFailed)) failed, \(ByteFormat.count(appStoreCancelled)) cancelled, \(ByteFormat.count(appStoreSkipped)) skipped"
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
                status: failed > 0 || cancelled > 0 ? .failed : (completed == 0 && skipped > 0 ? .skipped : .succeeded),
                command: nil,
                detail: L10n.text(
                    "\(providers)：\(ByteFormat.count(completed)) 个成功，\(ByteFormat.count(failed)) 个失败，\(ByteFormat.count(cancelled)) 个取消，\(ByteFormat.count(skipped)) 个跳过",
                    "\(providers): \(ByteFormat.count(completed)) succeeded, \(ByteFormat.count(failed)) failed, \(ByteFormat.count(cancelled)) cancelled, \(ByteFormat.count(skipped)) skipped"
                )
            ),
            generatedAt: Date()
        )
        showActionMessage(L10n.text(
            "更新完成：\(ByteFormat.count(completed)) 个成功，\(ByteFormat.count(failed)) 个失败，\(ByteFormat.count(cancelled)) 个取消，\(ByteFormat.count(skipped)) 个跳过",
            "Updates finished: \(ByteFormat.count(completed)) succeeded, \(ByteFormat.count(failed)) failed, \(ByteFormat.count(cancelled)) cancelled, \(ByteFormat.count(skipped)) skipped"
        ) + (skipReasons.isEmpty ? "" : "：" + skipReasons))
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
                  !task.requiresInstallationReconciliation,
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
        guard ApplicationUpdatePreferences.snapshot(defaults: appPreferences).updatesAfterApplicationQuits,
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
        noteModuleScan(.clutter)
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
        let homeURL = cleanupUserHomeURL
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
            if !(await CleanReportStore.recordDetached(report, journal: operationJournal)) {
                errorMessage = L10n.text("回执保存失败；本次已完成的移动仍保留在结果中。", "Receipt saving failed; completed moves remain in this result.")
            }
            finishVerifiedDuplicateCleanup(with: report)
        }
    }

    /// The duplicates' results and selection after a run. D214: a run that
    /// never started says so and why, and keeps the selection for a retry.
    func finishVerifiedDuplicateCleanup(with report: CleanReport) {
        duplicateCleanupReport = report
        if let refusal = report.startRefusal {
            showActionMessage(CleanStartRefusalPresentation.title + L10n.text("：", ": ")
                + CleanStartRefusalPresentation.message(refusal))
            return
        }
        let movedPaths = Set(report.items.compactMap { item -> String? in
            guard case .moved = item.outcome else { return nil }
            return PathSafety.lexicalPath(item.sourcePath)
        })
        markDuplicateItemsMoved(at: movedPaths)
        duplicateFilesWorkspace.clearSelection()
        showActionMessage(L10n.text(
            "已处理 \(ByteFormat.count(report.summary.movedItemCount)) 个重复副本；项目仍可从废纸篓或隔离区恢复。",
            "Handled \(ByteFormat.count(report.summary.movedItemCount)) duplicate copies; items remain recoverable from Trash or quarantine."
        ))
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
                    await recoveryService.restore(report: report, coordinator: coordinator, lease: lease,
                        journal: operationJournal, userHomeURL: cleanupUserHomeURL, trashURL: operationTrashURL)
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
                    "已恢复 \(ByteFormat.count(recovery.restoredCount)) 个重复副本。",
                    "Restored \(ByteFormat.count(recovery.restoredCount)) duplicate copies."
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
            userHomeURL: cleanupUserHomeURL,
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

    func recheckExternalUpdate(_ app: AppUpdateItem) {
        guard allowsLiveAppUpdateActions,
              !externalUpdateRecheckingIDs.contains(app.id),
              let original = appUpdates.first(where: { $0.id == app.id }) else { return }
        externalUpdateRecheckingIDs.insert(app.id)
        Task { @MainActor [weak self] in
            defer { self?.externalUpdateRecheckingIDs.remove(app.id) }
            do {
                let result = try await ExternalUpdateVersionVerifier().verify(original)
                guard let self else { return }
                guard allowsLiveAppUpdateActions else { return }
                switch result {
                case let .updated(version):
                    guard let index = appUpdates.firstIndex(where: { $0.id == original.id }),
                          appUpdates[index].bundleURL == original.bundleURL,
                          appUpdates[index].identity == original.identity,
                          appUpdates[index].installedVersion == original.installedVersion else {
                        showActionMessage(L10n.text(
                            "应用清单已变化，请重新扫描后复查",
                            "The application inventory changed; scan again before rechecking"
                        ))
                        return
                    }
                    appUpdates[index].installedVersion = version
                    appUpdates[index].buildNumber = version.build
                    appUpdates[index].reportedCurrentVersion = version.preferred
                    appUpdates[index].versionCheckState = .upToDate
                    appUpdates[index].updateStatus = .completed
                    refreshVisibleAppUpdateInventory()
                    showActionMessage(L10n.text(
                        "已核实 \(original.displayName) 更新至 \(version.display)",
                        "Verified \(original.displayName) updated to \(version.display)"
                    ))
                case .unchanged:
                    showActionMessage(L10n.text(
                        "\(original.displayName) 的安装版本尚未变化",
                        "The installed version of \(original.displayName) has not changed"
                    ))
                case let .targetNotReached(version):
                    showActionMessage(L10n.text(
                        "检测到 \(version.display)，仍未达到已确认的目标版本",
                        "Detected \(version.display), below the confirmed target version"
                    ))
                case .identityUnverifiable:
                    showActionMessage(L10n.text(
                        "缺少原应用的签名身份，不能将版本变化记为更新成功",
                        "The original signing identity is missing; a version change cannot be recorded as a successful update"
                    ))
                case .identityChanged:
                    showActionMessage(L10n.text(
                        "应用路径或签名身份已变化，未将更新记为成功",
                        "The app path or signing identity changed; the update was not marked successful"
                    ))
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    var currentWebsiteUpdateItem: WebsiteUpdateQueueItem? {
        websiteUpdateQueueSnapshot?.items.first { !$0.state.isTerminal }
    }

    private func restoreWebsiteUpdateAssistantIfNeeded(
        applications: [AppUpdateItem]
    ) async {
        guard allowsLiveAppUpdateActions,
              websiteUpdateQueueSnapshot == nil,
              !isPreparingWebsiteUpdateQueue else { return }
        do {
            websiteUpdateQueueSnapshot = try await websiteUpdateWorkflow.restore(
                applications: applications
            )
        } catch {
            appUpdateScanWarnings.append(L10n.text(
                "未能恢复上次官网更新引导：\(error.localizedDescription)",
                "Could not restore the previous website update guidance: \(error.localizedDescription)"
            ))
        }
    }

    func prepareWebsiteUpdateAssistant(applicationIDs: [String]) {
        guard allowsLiveAppUpdateActions, !isPreparingWebsiteUpdateQueue else { return }
        let selectedIDs = Set(applicationIDs)
        let applications = appUpdates.filter {
            selectedIDs.contains($0.id)
                && AppUpdateService.validatedManualUpdateURL(for: $0) != nil
        }
        guard !applications.isEmpty else { return }
        isPreparingWebsiteUpdateQueue = true
        websiteUpdateResultMessage = nil
        let workflow = websiteUpdateWorkflow
        // Restore against the complete inventory. A newly selected subset must
        // not invalidate unrelated pending receipts in the persisted queue.
        let inventory = appUpdates

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isPreparingWebsiteUpdateQueue = false }
            do {
                _ = try await workflow.restore(applications: inventory)
                websiteUpdateQueueSnapshot = try await workflow.enqueue(applications: applications)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openCurrentWebsiteUpdate() {
        guard !isRunningOneClickUpdate else { return }
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
                    showActionMessage(websiteUpdateResultMessage ?? "")
                    if let completed = websiteUpdateQueueSnapshot?.items.last(where: {
                        $0.state == .completed && $0.observedVersion == version
                    }), let index = appUpdates.firstIndex(where: { $0.id == completed.applicationID }) {
                        appUpdates[index].installedVersion = version
                        appUpdates[index].buildNumber = version.build
                        appUpdates[index].reportedCurrentVersion = version.preferred
                        appUpdates[index].updateStatus = .completed
                        refreshVisibleAppUpdateInventory()
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
                websiteUpdateResultMessage = L10n.text(
                    "已保留此项供下次处理",
                    "This item remains available for later review"
                )
                websiteUpdateQueueSnapshot = await workflow.currentSnapshot()
                showActionMessage(websiteUpdateResultMessage ?? "")
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
        cleanupHistorySummary = CleanupHistoryService.summary(defaults: cleanupPreferences)
    }

    func clearCleanupHistory() {
        guard canClearCleanupHistory else { return }
        pendingCleanupRestoreEntry = nil
        CleanupHistoryService.clear(defaults: cleanupPreferences)
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
        let recovery = cleanupRecoveryService
        let journal = operationJournal
        let activityStore = heavyWorkActivityStore

        let receiptTaskID = UUID()
        operationReportTasks[receiptTaskID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { operationReportTasks[receiptTaskID] = nil }
            do {
                let summary = try await coordinator.withLease(owner: .restore) { lease in
                    await activityStore.refresh()
                    // Records with a receipt of the same file restore through the journal,
                    // and only the confirmed files: never the rest of that receipt.
                    let reports: [CleanReport]
                    do {
                        reports = try await Task.detached(priority: .utility) {
                            try journal.loadAvailable().reports
                        }.value
                    } catch { throw OperationJournalUnavailableError() }
                    let plan = LegacyCleanupRestore.plan(for: records, reports: reports)
                    var recoveries: [CleanupRecoveryReport] = []
                    for match in plan.matches {
                        try await coordinator.requireValid(lease, owner: .restore)
                        recoveries.append(await recovery.restore(
                            report: match.report, coordinator: coordinator, lease: lease,
                            journal: journal, userHomeURL: cleanupUserHomeURL, trashURL: operationTrashURL,
                            onlyOriginalPaths: match.originalPaths
                        ).recovery)
                    }
                    let legacy = plan.unmatched.isEmpty ? nil : try await service.restoreFromTrash(
                        records: plan.unmatched,
                        lease: lease
                    )
                    return LegacyCleanupRestore.summary(
                        records: records, plan: plan, recoveries: recoveries, legacy: legacy
                    )
                }
                await activityStore.refresh()
                guard restoreGeneration == generation else { return }

                let completedRecordIDs = Set(
                    (summary.restored + summary.missing).map(\.id)
                )
                CleanupHistoryService.removeMoveRecords(
                    entryID: entry.id,
                    recordIDs: completedRecordIDs,
                    defaults: cleanupPreferences
                )

                if var current = result, !summary.restored.isEmpty {
                    current.markRestoredFromTrash(
                        paths: Set(summary.restored.map(\.originalPath))
                    )
                    result = current
                }

                refreshCleanupHistory()
                refreshOperationReports()
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
            "已恢复 \(ByteFormat.count(summary.restoredCount)) 项到原位置",
            "Restored \(ByteFormat.count(summary.restoredCount)) item(s) to their original locations"
        )
        let skippedCount = summary.conflictCount + summary.missingCount + summary.failedCount
        guard skippedCount > 0 else {
            showActionMessage(restoredText)
            return
        }

        errorMessage = L10n.text(
            "\(restoredText)。跳过 \(ByteFormat.count(skippedCount)) 项：同名冲突 \(ByteFormat.count(summary.conflictCount))，废纸篓中已不存在 \(ByteFormat.count(summary.missingCount))，恢复失败 \(ByteFormat.count(summary.failedCount))。未覆盖或删除任何现有文件。",
            "\(restoredText). Skipped \(ByteFormat.count(skippedCount)): \(ByteFormat.count(summary.conflictCount)) name conflict(s), \(ByteFormat.count(summary.missingCount)) no longer in Trash, and \(ByteFormat.count(summary.failedCount)) failed. No existing files were overwritten or deleted."
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
        app.canMoveToTrash(homeDirectory: cleanupUserHomeURL)
            && !isRestoringRecordedOperation
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
        scanHistorySummary.latestScanAt != nil && !isPreparingScan
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
        appPreferences.set(true, forKey: Self.initialPermissionCheckDefaultsKey)
    }

    private func shouldShowInitialFolderAccessPrompt(after summary: ScanReadinessSummary) -> Bool {
        !summary.isFullDiskAccessVerified
            && summary.folderAuthorizationRequiredCount > 0
            && FolderAccessGrantService.shouldShowInitialPrompt(defaults: appPreferences)
    }

    private func showPermissionCheckCompletion(_ summary: ScanReadinessSummary) {
        if summary.isFullDiskAccessVerified, summary.blockedCount == 0 {
            showActionMessage(L10n.text("权限检查完成：完整磁盘访问已生效", "Permission check complete: Full Disk Access is active"))
        } else if summary.blockedCount == 0 {
            showActionMessage(L10n.text("权限检查完成：关键位置可读", "Permission check complete: key locations are readable"))
        } else {
            showActionMessage(L10n.text("权限检查完成：\(ByteFormat.count(summary.blockedCount)) 个位置仍受限", "Permission check complete: \(ByteFormat.count(summary.blockedCount)) location(s) still limited"))
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

    /// B-R3: after emptying a frozen Trash, only the rows for entries it
    /// deleted leave the scan result; an entry kept, not deleted or not read
    /// back stays listed.
    private func removeTrashItemsFromCurrentResult(deleted names: [String], in trashURL: URL) {
        guard var current = result, !names.isEmpty else { return }
        let trash = PathSafety.lexicalPath(trashURL.path)
        let deleted = names.map { PathSafety.lexicalPath(trash + "/" + $0) }
        let kept = current.items.filter { item in
            guard item.sourceID == "trash_bins" else { return false }
            let path = PathSafety.lexicalPath(item.path)
            return !deleted.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        current.replaceItems(sourceID: "trash_bins", with: kept)
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
            "已验证退出 \(ByteFormat.count(verified)) 个进程；操作前已退出 \(ByteFormat.count(exitedBeforeRequest)) 个；未完成或无法验证 \(ByteFormat.count(unresolved)) 个。实际内存变化已单独重测。",
            "Verified \(ByteFormat.count(verified)) process exits; \(ByteFormat.count(exitedBeforeRequest)) had already exited; \(ByteFormat.count(unresolved)) were incomplete or unverifiable. Actual memory change was remeasured separately."
        )
    }

    private func clearPendingMemoryQuitConfirmation() {
        pendingMemoryProcessesToQuit = []
        pendingMemoryQuitSummary = nil
        pendingMemoryOptimizationPlan = nil
        pendingMemoryPlanSnapshot = nil
        isMemoryBatchQuitConfirmationPresentedInMenuBar = false
        memorySelectionBeforeQuitRequest = nil
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

#if DEBUG
extension ScanStore {
    /// Offscreen layout evidence only (D119): renders the mini window's pages
    /// with the demo processes without starting a process sampler.
    func publishMenuBarPreparedProcessesForTesting(_ prepared: MenuBarPreparedProcesses?, memoryApps: [MemoryAppUsage] = []) {
        menuBarPreparedProcesses = prepared
        menuBarPreparedMemoryApps = memoryApps
    }
}
#endif
