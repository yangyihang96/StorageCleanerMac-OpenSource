import Foundation

/// D168: CleanMyMac's Smart Care — Smart Scan scans five modules, one card
/// each, in place of the three D64 scopes (junk, files to review, health).
/// The cleanup card always scans both file scopes; health stays in My Tools.
enum SmartCareModule: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case cleanup, protection, performance, applications, clutter

    static let defaultsKey = "smart-care.selected-modules"
    static var defaultSelection: Set<Self> { Set(allCases) }
    /// What the cleanup card scans (was the landing's three D64 scopes).
    static let cleanupScopes: Set<SmartScanScope> = [.cleanupCandidates, .filesToReview]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: L10n.text("清理", "Cleanup")
        case .protection: L10n.text("防护", "Protection")
        case .performance: L10n.text("性能", "Performance")
        case .applications: L10n.text("应用", "Applications")
        case .clutter: L10n.text("杂乱文件", "My Clutter")
        }
    }

    /// What the module looks at, for the landing list.
    var scope: String {
        switch self {
        case .cleanup: L10n.text("系统垃圾、开发者垃圾、废纸篓和待确认文件", "System junk, developer junk, Trash and files to review")
        case .protection: L10n.text("浏览器里的浏览记录", "Browsing records in your browsers")
        case .performance: L10n.text("维护任务和登录项", "Maintenance tasks and login items")
        case .applications: L10n.text("应用更新（会联网查询）", "App updates (checked online)")
        case .clutter: L10n.text("内容完全相同的重复文件", "Files with identical contents")
        }
    }

    /// The user's choice (D168): Run cleans junk and runs maintenance tasks;
    /// the other cards are reviewed in their modules.
    var takesPartInRun: Bool { self == .cleanup || self == .performance }

    static func selection(in defaults: UserDefaults) -> Set<Self> {
        guard let values = defaults.array(forKey: defaultsKey) as? [String] else { return defaultSelection }
        // An explicitly saved empty array stays empty: starting is disabled.
        guard !values.isEmpty else { return [] }
        let recognized = Set(values.compactMap(Self.init(rawValue:)))
        return recognized.isEmpty ? defaultSelection : recognized
    }

    static func save(_ selection: Set<Self>, in defaults: UserDefaults) {
        defaults.set(allCases.filter(selection.contains).map(\.rawValue), forKey: defaultsKey)
    }
}

/// How far one Smart Care card got. What it found is read from the module
/// itself when the card is drawn, so a review that changes the selection
/// shows at once.
enum SmartCareCardState: Equatable, Sendable {
    /// Turned off on the landing.
    case off
    case waiting
    case scanning
    case done
    /// The module did not run, and why.
    case skipped(String)
    case failed(String)
    case stopped
}

/// How one card's part of Run ended (D168, batch 3L).
enum SmartCareRunOutcome: Equatable, Sendable {
    case done
    /// The user cancelled at the cleanup confirmation: nothing else runs.
    case cancelled
    /// The user stopped the cleanup while it ran: what was moved stays moved,
    /// and the rest of Run is not started (CleanMyMac: "wasn't run").
    case stopped
    case failed(String)
}

/// One module's scan for Smart Care, so the coordinator can be tested with
/// stand-ins.
@MainActor
protocol SmartCareScanning: AnyObject {
    /// Scans the module and returns once it has finished, failed or stopped.
    func scan(_ module: SmartCareModule) async -> SmartCareCardState
    /// Stops the module's scan that is running.
    func stop(_ module: SmartCareModule)
}

/// Run's two parts, through each module's own flow (D168: the cleanup plan
/// with all its confirmations; the maintenance tasks the user confirmed).
@MainActor
protocol SmartCareRunning: AnyObject {
    /// Opens the cleanup plan of the ticked junk and returns once it was
    /// carried out, failed, or cancelled at its confirmation.
    func clean() async -> SmartCareRunOutcome
    /// Runs the maintenance tasks the user confirmed (2.0.1 review: not
    /// whatever is ticked by the time the cleanup is done) and returns when
    /// they are done.
    func runMaintenance(_ tasks: [SystemMaintenanceTaskID]) async -> SmartCareRunOutcome
}

/// D168: runs the Smart Care modules one after another — their scans share
/// the app's one heavy-work lease, so never at once — and keeps one card
/// per module.
@MainActor
final class SmartCareCoordinator: ObservableObject {
    enum Stage: Equatable {
        case idle
        case scanning(SmartCareModule)
        case results
        /// Run is carrying out this card's part.
        case running(SmartCareModule)
        case finished
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var cards: [SmartCareModule: SmartCareCardState] = [:]
    @Published private(set) var selection: Set<SmartCareModule>
    /// What Run is carrying out, and how each part ended.
    @Published private(set) var plannedRun: Set<SmartCareModule> = []
    /// The maintenance tasks the user confirmed for this run.
    @Published private(set) var confirmedTasks: [SystemMaintenanceTaskID] = []
    @Published private(set) var runOutcomes: [SmartCareModule: SmartCareRunOutcome] = [:]
    /// D154 batch 3O: whether a Smart Care scan was ever started here; until
    /// then the landing greets a first visit.
    @Published private(set) var hasStartedScan: Bool

    static let startedScanKey = "smart-care.has-started-scan"

    let scanner: SmartCareScanning
    private let runner: SmartCareRunning?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var isStopping = false

    init(scanner: SmartCareScanning, runner: SmartCareRunning? = nil, defaults: UserDefaults) {
        self.scanner = scanner
        self.runner = runner
        self.defaults = defaults
        selection = SmartCareModule.selection(in: defaults)
        hasStartedScan = defaults.bool(forKey: Self.startedScanKey)
    }

    var isScanning: Bool {
        if case .scanning = stage { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = stage { return true }
        return false
    }

    func card(_ module: SmartCareModule) -> SmartCareCardState {
        cards[module] ?? (selection.contains(module) ? .waiting : .off)
    }

    func toggle(_ module: SmartCareModule) {
        guard !isScanning, !isRunning else { return }
        if selection.contains(module) { selection.remove(module) } else { selection.insert(module) }
        SmartCareModule.save(selection, in: defaults)
    }

    /// Scans the selected modules in card order.
    func start() {
        guard !isScanning, !isRunning, !selection.isEmpty else { return }
        if !hasStartedScan {
            hasStartedScan = true
            defaults.set(true, forKey: Self.startedScanKey)
        }
        let order = SmartCareModule.allCases.filter(selection.contains)
        isStopping = false
        cards = Dictionary(uniqueKeysWithValues: SmartCareModule.allCases.map {
            ($0, selection.contains($0) ? SmartCareCardState.waiting : .off)
        })
        stage = .scanning(order[0])
        task = Task { [weak self] in
            for module in order {
                guard let self, !self.isStopping else { break }
                self.stage = .scanning(module)
                self.cards[module] = .scanning
                self.cards[module] = await self.scanner.scan(module)
            }
            guard let self else { return }
            for module in order where self.cards[module] == .waiting { self.cards[module] = .stopped }
            self.stage = .results
            self.task = nil
        }
    }

    /// Stops the module that is scanning; the ones after it are not started.
    func stop() {
        guard case .scanning(let module) = stage, !isStopping else { return }
        isStopping = true
        scanner.stop(module)
    }

    /// D168, batch 3L: Run cleans the ticked junk first (its plan and every
    /// confirmation), then runs the maintenance tasks the user confirmed
    /// before (batch 3M: exactly those); cancelling at the cleanup
    /// confirmation runs nothing else.
    func run(cleanup: Bool, maintenanceTasks: [SystemMaintenanceTaskID]) {
        let maintenance = !maintenanceTasks.isEmpty
        guard stage == .results, let runner, cleanup || maintenance else { return }
        plannedRun = Set([cleanup ? .cleanup : nil, maintenance ? .performance : nil].compactMap { $0 })
        confirmedTasks = maintenanceTasks
        runOutcomes = [:]
        stage = .running(cleanup ? .cleanup : .performance)
        task = Task { [weak self] in
            guard let self else { return }
            if cleanup {
                let outcome = await runner.clean()
                self.runOutcomes[.cleanup] = outcome
                if outcome == .cancelled {
                    self.plannedRun = []
                    self.confirmedTasks = []
                    self.runOutcomes = [:]
                    self.stage = .results
                    self.task = nil
                    return
                }
                if outcome == .stopped {
                    self.stage = .finished
                    self.task = nil
                    return
                }
            }
            if maintenance {
                self.stage = .running(.performance)
                self.runOutcomes[.performance] = await runner.runMaintenance(maintenanceTasks)
            }
            self.stage = .finished
            self.task = nil
        }
    }

    /// D202: a module page's own scan replaced one of the parts this
    /// Smart Care's cards read (they read the shared stores). Cards showing
    /// results go back to the landing, and the other parts' results Smart Care
    /// left are cleared with them; a Run in progress finishes first.
    func follow(_ store: ScanStore, privacy: @escaping () -> BrowserPrivacyStore?) {
        store.onModuleScanReplacedSmartCarePart = { [weak self, weak store] _ in
            guard let self, let store, self.stage == .results || self.stage == .finished else { return }
            self.reset()
            store.clearSmartCareResults(privacy: privacy())
        }
    }

    /// Back to the landing ("Start Over", or after a finished run).
    func reset() {
        guard !isScanning, !isRunning else { return }
        task?.cancel()
        task = nil
        cards = [:]
        plannedRun = []
        confirmedTasks = []
        runOutcomes = [:]
        stage = .idle
    }
}
