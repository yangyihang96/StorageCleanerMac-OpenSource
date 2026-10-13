import Combine
import Foundation

/// D74: resident prestored demand is independent of the user's 1/2/5-second display setting.
/// A disabled source contributes no fabricated point to background history.
struct MenuBarSamplingPlan: Equatable, Sendable {
    let primaryKinds: Set<MenuBarMetricKind>
    let panelVisible: Bool
    let needsStatusBattery: Bool
    let needsStatusWiFi: Bool
    let thermalInterval: TimeInterval
    let gpuInterval: TimeInterval
    let cadence: MenuBarSamplingCadence
    var permitsStartupHardware = true

    static func resolve(
        statusMode: MenuBarStatusDisplayMode,
        statusVisible: Bool,
        panelVisible: Bool,
        visibleKinds: Set<MenuBarMetricKind>,
        customFanControlActive: Bool,
        paused: Bool,
        lowPower: Bool = false,
        suspended: Bool = false,
        selectedInterval: TimeInterval = 1
    ) -> Self {
        let stopped = paused || suspended
        let cadence = MenuBarSamplingCadence.resolve(visible: panelVisible,
            lowPower: lowPower, suspended: stopped, selectedInterval: selectedInterval)
        // Every page can open without a new source/baseline. Keep source dates;
        // this does not manufacture history points from a presentation cache.
        let kinds = stopped ? Set<MenuBarMetricKind>() : MenuBarMetricKind.defaultSelection
        return Self(
            primaryKinds: kinds,
            panelVisible: panelVisible && !stopped,
            needsStatusBattery: !stopped && statusVisible && statusMode == .deviceStatus,
            needsStatusWiFi: !stopped && statusVisible && statusMode == .deviceStatus,
            thermalInterval: customFanControlActive && !lowPower
                ? SystemMonitorSamplingInterval.interactive : cadence.expensive,
            gpuInterval: cadence.expensive,
            cadence: cadence
        )
    }
}

/// Attached only by the resident controller. Standalone probes/tests retain
/// their explicit arguments, avoiding an implicit dependency on an installed UI.
@MainActor
final class MenuBarSamplingContext {
    static let shared = MenuBarSamplingContext()
    /// Source freshness threshold retained for diagnostics. D74 presentation
    /// keeps older readings with their age instead of resetting to a wait state.
    static let keptPresentationMaxAge: TimeInterval = max(10, 2 * MenuBarPerformancePolicy.visibleExpensiveInterval)
    /// Read synchronously by samplers and the controller.
    private(set) var plan: MenuBarSamplingPlan?
    /// Observers get at most one value per main-thread turn, deduplicated,
    /// so opening the panel does not fan out several intermediate plans.
    private let planSubject = CurrentValueSubject<MenuBarSamplingPlan?, Never>(nil)
    private var isPublishScheduled = false
    var planChanges: AnyPublisher<MenuBarSamplingPlan?, Never> {
        planSubject.removeDuplicates().eraseToAnyPublisher()
    }
    private var statusMode = MenuBarStatusDisplayMode.deviceStatus
    private var statusVisible = true
    private var panelVisible = false
    private var customFanControlActive = false
    private var paused = false
    private var lowPower = false
    private var suspended = false
    private var selectedInterval: TimeInterval = 1
    private var visibleKinds: Set<MenuBarMetricKind> = []
    private var cachedPanelSnapshot: SystemMonitorSnapshot?
    private var visibleReadTasks: [String: Task<Void, Never>] = [:]
    private var visibleReadStartedAt: [String: Date] = [:]
    var activeVisibleReadCount: Int { visibleReadTasks.count }
    private var startupSchedule: ResidentStartupSchedule?
    private var startupPromoted = false
    private(set) var hasFirstPresentationTurn = false
    var startupPriorityReady: Bool {
        hasFirstPresentationTurn && permitsStartupSource(.metadata)
    }

    /// Opt in only on the production controller; isolated readers stay immediate.
    func beginStartup(now: Date = Date()) {
        guard startupSchedule == nil else { return }
        startupSchedule = ResidentStartupSchedule(beganAt: now)
        reconcile(now: now)
        Task { @MainActor [weak self] in
            await Self.awaitPresentationTurn()
            self?.hasFirstPresentationTurn = true
        }
    }

    func permitsStartupSource(_ source: ResidentStartupSchedule.Source, now: Date = Date()) -> Bool {
        startupSchedule?.permits(source, now: now, promoted: panelVisible || startupPromoted) ?? true
    }

    func configure(statusMode: MenuBarStatusDisplayMode, statusVisible: Bool,
                   panelVisible: Bool, customFanControlActive: Bool, paused: Bool, now: Date = Date(),
                   lowPower: Bool = false, suspended: Bool = false, selectedInterval: TimeInterval = 1) {
        self.statusMode = statusMode
        self.statusVisible = statusVisible
        self.panelVisible = panelVisible
        if panelVisible { startupPromoted = true }
        self.customFanControlActive = customFanControlActive
        self.paused = paused
        self.lowPower = lowPower
        self.suspended = suspended
        self.selectedInterval = selectedInterval
        reconcile(now: now)
    }

    func rememberPanelSnapshot(_ snapshot: SystemMonitorSnapshot) {
        guard plan?.cadence.suspended != true else { return }
        let waitingForBaseline = cachedPanelSnapshot?.cpuUsageBreakdown != nil && snapshot.cpuUsageBreakdown == nil
        if !waitingForBaseline {
            cachedPanelSnapshot = cachedPanelSnapshot.map { snapshot.retainingStoredHardwareReadings(from: $0) } ?? snapshot
        }
    }

    /// Presentation only: the kept reading never becomes a new history sample
    /// and its original timestamp is used for the draw/freshness probes.
    func presentationSnapshot(live: SystemMonitorSnapshot?, now: Date = Date()) -> SystemMonitorSnapshot? {
        let live = live.flatMap { snapshot in
            snapshot.generatedAt.timeIntervalSinceReferenceDate.isFinite && snapshot.generatedAt <= now ? snapshot : nil
        }
        guard plan?.panelVisible == true else { return live }
        // D74: a stopped/sleeping source is still stored data. Age is shown
        // by the UI, never replaced by an empty "sampling" state on reopen.
        guard let cachedPanelSnapshot else { return live }
        guard let live else { return cachedPanelSnapshot }
        let waitingForBaseline = cachedPanelSnapshot.cpuUsageBreakdown != nil && live.cpuUsageBreakdown == nil
        if waitingForBaseline { return cachedPanelSnapshot }
        return live.generatedAt >= cachedPanelSnapshot.generatedAt
            ? live.retainingStoredHardwareReadings(from: cachedPanelSnapshot) : cachedPanelSnapshot
    }

    /// Wait for AppKit's display/commit opportunity before declaring process
    /// demand. A MainActor Task alone can start before the opening frame.
    static func awaitPresentationTurn() async {
        await withCheckedContinuation { continuation in
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
                CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    func setVisibleKinds(_ kinds: Set<MenuBarMetricKind>) {
        visibleKinds = kinds
        reconcile()
    }

    /// Cached connection/mode state stays on its existing owner. Rapid panel
    /// opens coalesce these read-only XPC requests; user actions bypass this gate.
    func refreshVisibleRead(_ source: String, now: Date = Date(),
                            operation: @escaping @MainActor @Sendable () async -> Void) {
        guard plan?.panelVisible == true else { return }
        enqueueRead(source, now: now, interval: plan?.cadence.expensive ?? MenuBarPerformancePolicy.visibleExpensiveInterval,
                    requiresVisible: true, operation: operation)
    }

    /// Read-only metadata (connection and pmset modes) uses the same tick and
    /// the same per-source flight gate as its visible requests.
    func refreshResidentRead(_ source: String, now: Date = Date(),
                             operation: @escaping @MainActor @Sendable () async -> Void) {
        guard let plan, !plan.cadence.suspended, permitsStartupSource(.metadata, now: now) else { return }
        enqueueRead(source, now: now, interval: plan.cadence.helperPower,
                    requiresVisible: false, operation: operation)
    }

    private func enqueueRead(_ source: String, now: Date, interval: TimeInterval, requiresVisible: Bool,
                             operation: @escaping @MainActor @Sendable () async -> Void) {
        guard visibleReadTasks[source] == nil,
              visibleReadStartedAt[source].map({
                  now.timeIntervalSince($0) >= interval
              }) != false else { return }
        visibleReadTasks[source] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { visibleReadTasks[source] = nil }
            guard !Task.isCancelled, plan?.cadence.suspended == false,
                  !requiresVisible || plan?.panelVisible == true else { return }
            visibleReadStartedAt[source] = now
            await MenuBarPresentationTrace.measureAsyncSample(source) { await operation() }
        }
    }

    private func reconcile(now: Date = Date()) {
        var next = MenuBarSamplingPlan.resolve(
            statusMode: statusMode, statusVisible: statusVisible,
            panelVisible: panelVisible, visibleKinds: visibleKinds,
            customFanControlActive: customFanControlActive, paused: paused,
            lowPower: lowPower, suspended: suspended, selectedInterval: selectedInterval
        )
        next.permitsStartupHardware = permitsStartupSource(.hardware, now: now)
        guard next != plan else { return }
        plan = next
        if !isPublishScheduled {
            isPublishScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPublishScheduled = false
                    self.planSubject.send(self.plan)
                }
            }
        }
        MenuBarPresentationTrace.mark("sampling.plan", [
            "panelVisible": next.panelVisible,
            "statusVisible": statusVisible,
            "primarySources": next.primaryKinds.map(\.rawValue).sorted(),
            "thermalInterval": next.thermalInterval,
            "gpuInterval": next.gpuInterval
        ])
    }
}

/// The existing status facade is used only by menu-bar collection. Keep the
/// real timestamp when no visible reader needs memory; full process/optimizer
/// snapshots continue through SystemMemoryProbe without this cache.
actor MenuBarMemoryStatusSampler {
    static let shared = MenuBarMemoryStatusSampler {
        await SystemMemoryProbe.shared.snapshot(includeProcesses: false)
    }
    private let provider: @Sendable () async -> MemorySnapshot
    private var cached: MemorySnapshot?
    private var inFlight: Task<MemorySnapshot, Never>?

    init(provider: @escaping @Sendable () async -> MemorySnapshot) {
        self.provider = provider
    }

    func snapshot(needsRefresh: Bool) async -> MemorySnapshot {
        if !needsRefresh, let cached { return cached }
        if let inFlight { return await inFlight.value }
        let provider = provider
        let task = Task {
            await MenuBarPresentationTrace.measureAsyncSample("memory.status", operation: provider)
        }
        inFlight = task
        let value = await task.value
        cached = value
        inFlight = nil
        return value
    }
}

/// Visible page attribution only. D74 resident enumeration continues even
/// without this consumer, using its slower process cadence.
enum MenuBarProcessSamplingDemand {
    static func section(_ section: PanelSection, tertiaryVisible: Bool) -> PanelSection? {
        guard tertiaryVisible,
              [.processor, .memory, .disk, .power].contains(section) else { return nil }
        return section
    }
}
