import AppKit
import Combine
import Foundation

/// The two CleanMyMac Health Monitor reminders, rebuilt: “Uninstall
/// applications correctly” when an app lands in the Trash, and “It's time to
/// empty your Trash!” when the Trash grows past the chosen size
/// (`TrashedAppsIssueProducer`, `TrashSizeIssueProducer`, `MenuAlertsPresenter`).
///
/// Detection follows CleanMyMac's decompiled rules. What runs after a click
/// follows this app's own safety rules: leftovers move to the Trash with a
/// receipt, and emptying the Trash keeps D23's second confirmation over the
/// list frozen when it opened (D101 L5).
///
/// D219/D220 add two cards on the same panel, with the same Ignore menu and
/// the same waiting rules: a scan is due (CleanMyMac's regular Smart Care
/// reminder) and the startup disk is short of free space (its disk space
/// alert). Their buttons only open a page; “Scan Now” starts Smart Scan's
/// read-only scan and never cleans.
@MainActor
final class AppLifecycleReminderCenter: ObservableObject {
    static let shared = AppLifecycleReminderCenter()

    enum Alert: Equatable, Identifiable, Sendable {
        case trashedApplications([TrashedApplication])
        case trashSize(bytes: Int64, threshold: Int64, itemCount: Int)
        /// D220: free space on the startup disk is below the chosen threshold.
        case lowDiskSpace(StartupDiskSpace, threshold: Int64)
        /// D219: the chosen scan interval has passed since the last scan.
        case scanDue(lastScanAt: Date, cadence: MaintenanceReminderCadence)

        var id: String {
            switch self {
            case .trashedApplications(let apps): "apps:" + apps.map(\.discriminator).joined(separator: "|")
            case .trashSize: "trash-size"
            case .lowDiskSpace: "low-disk-space"
            case .scanDue: "scan-due"
            }
        }

        var kind: AppLifecycleIssueKind {
            switch self {
            case .trashedApplications: .trashedApplication
            case .trashSize: .trashSize
            case .lowDiskSpace: .lowDiskSpace
            case .scanDue: .scanDue
            }
        }

        var discriminators: [String] {
            switch self {
            case .trashedApplications(let apps): apps.map(\.discriminator)
            case .trashSize, .lowDiskSpace, .scanDue: [""]
            }
        }
    }

    /// D220: the startup disk's free space as the rest of the app shows it
    /// (`StorageCapacitySnapshot.userAvailableBytes`, which counts the space
    /// macOS can purge, as Finder does).
    struct StartupDiskSpace: Equatable, Sendable {
        let availableBytes: Int64
        let totalBytes: Int64
        let volumeName: String?
    }

    /// Where a reminder button leads.
    enum Destination: Equatable, Sendable {
        /// The Smart Scan page, starting its read-only scan (D219).
        case smartScan
        /// The Junk Cleanup page, nothing started (D220).
        case junkCleanup
        case uninstaller
    }

    /// The Empty Trash action inside the reminder card.
    enum EmptyTrashPhase: Equatable {
        case idle
        case freezing
        /// D23: both acknowledgements are required before anything is deleted.
        case confirming(FrozenTrash)
        case emptying(itemCount: Int, bytes: Int64)
        case finished(FrozenTrashEmptyResult)
        case failed(String)
    }

    @Published private(set) var measurement: TrashSizeMeasurer.Measurement?
    @Published private(set) var trashedApplications: [TrashedApplication] = []
    @Published private(set) var presentedAlert: Alert?
    @Published private(set) var emptyTrashPhase: EmptyTrashPhase = .idle
    @Published private(set) var preferences: AppLifecycleReminderPreferencesSnapshot
    /// D220: the last reading of the startup disk (none while the warning is off).
    @Published private(set) var startupDiskSpace: StartupDiskSpace?
    /// Apps handed to the uninstaller from the reminder; the uninstall page
    /// takes them and clears this.
    @Published var pendingTrashedUninstall: [TrashedApplication] = []

    let ignoreList: AppLifecycleIgnoreList
    /// Tests: where the buttons lead is recorded here instead of followed.
    var destinationOverride: (@MainActor (Destination) -> Void)?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let lastScanDateProvider: (@MainActor () -> Date?)?
    private let readStartupDiskSpace: @Sendable (_ thresholdBytes: Int64) -> StartupDiskSpace?
    /// False in tests: the decisions run without a panel or environment checks.
    private let presentsPanel: Bool
    private weak var store: ScanStore?
    private var heavyWork: ScanHeavyWorkService?
    private let measurer = TrashSizeMeasurer()
    private var monitor: TrashFolderMonitor?
    private var evaluationTask: Task<Void, Never>?
    private var evaluationQueued = false
    private var postponeTimer: Timer?
    private var periodicTimer: Timer?
    private var diskSpaceTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private lazy var panel = AppLifecycleAlertPanelController(center: self)

    private enum Key {
        /// D220: the low-space card was handled (ignored or acted on); it
        /// stays away until the free space is back at the threshold.
        static let lowDiskSpaceAwaitingRecovery = "appLifecycle.lowDiskSpaceAwaitingRecovery.v1"
        /// D219: when “Scan Now” was last clicked.
        static let scanDueActedAt = "appLifecycle.scanDueActedAt.v1"
    }

    /// D219/D220: nothing marks the passing of time or the filling of the
    /// disk, so both are looked at again every five minutes (D173's interval
    /// for the purgeable-space query) and after the Mac wakes.
    static let periodicCheckInterval: TimeInterval = 300
    /// D219: after “Scan Now” the scan card rests for a day, so stopping that
    /// scan does not bring the card straight back.
    static let scanDueRestAfterScanNow: TimeInterval = 24 * 60 * 60

    init(
        ignoreList: AppLifecycleIgnoreList = .live(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        lastScanDate: (@MainActor () -> Date?)? = nil,
        readStartupDiskSpace: @escaping @Sendable (_ thresholdBytes: Int64) -> StartupDiskSpace? = AppLifecycleReminderCenter.measureStartupDiskSpace,
        presentsPanel: Bool = true
    ) {
        self.ignoreList = ignoreList
        self.defaults = defaults
        self.now = now
        lastScanDateProvider = lastScanDate
        self.readStartupDiskSpace = readStartupDiskSpace
        self.presentsPanel = presentsPanel
        preferences = AppLifecycleReminderPreferences.snapshot(defaults: defaults)
    }

    // MARK: Lifecycle

    func start(store: ScanStore) {
        guard !started, !AcceptanceLaunch.isActive else { return }
#if DEBUG || STORAGE_CLEANER_BETA
        // Isolated visual sessions show fixture data; no live reminders.
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        started = true
        self.store = store
        heavyWork = ScanHeavyWorkService(coordinator: store.heavyWorkCoordinator)
        monitor = TrashFolderMonitor { [weak self] in
            Task { @MainActor in self?.scheduleEvaluation() }
        }
        NotificationCenter.default.publisher(for: AppLifecycleReminderPreferences.didChangeNotification)
            .sink { [weak self] _ in self?.reloadPreferences() }
            .store(in: &cancellables)
        // D219: a finished scan ends a due reminder at once.
        store.$scanHistorySummary
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshAlert() }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in self?.scheduleEvaluation() }
                .store(in: &cancellables)
        }
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.periodicCheck() }
            .store(in: &cancellables)
        let timer = Timer.scheduledTimer(withTimeInterval: Self.periodicCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodicCheck() }
        }
        timer.tolerance = 60
        periodicTimer = timer
        scheduleEvaluation()
        measureStartupDiskSpaceSoon()
    }

    /// Settings changed: a switch, a threshold, or the scan interval.
    func reloadPreferences() {
        preferences = AppLifecycleReminderPreferences.snapshot(defaults: defaults)
        if !preferences.notifiesLowDiskSpace { startupDiskSpace = nil }
        settleLowDiskSpaceRecovery()
        if started {
            measureStartupDiskSpaceSoon()
            scheduleEvaluation()
        } else if !presentsPanel {
            refreshAlert()
        }
    }

    /// D219/D220: time passed or the Mac woke; the scan may be due and the
    /// free space may have changed.
    func periodicCheck() {
        guard started else { return }
        measureStartupDiskSpaceSoon()
        refreshAlert()
    }

    private func measureStartupDiskSpaceSoon() {
        guard started, preferences.notifiesLowDiskSpace, diskSpaceTask == nil else { return }
        let threshold = preferences.lowDiskSpaceThresholdBytes
        let read = readStartupDiskSpace
        diskSpaceTask = Task { [weak self] in
            let space = await Task.detached(priority: .utility) { read(threshold) }.value
            guard let self else { return }
            diskSpaceTask = nil
            applyStartupDiskSpace(space)
        }
    }

    /// D220: a new reading of the startup disk.
    func applyStartupDiskSpace(_ space: StartupDiskSpace?) {
        guard preferences.notifiesLowDiskSpace else { return }
        startupDiskSpace = space
        settleLowDiskSpaceRecovery()
        if started || !presentsPanel { refreshAlert() }
    }

    /// D220: back at or above the threshold, a later drop may show the card
    /// again.
    private func settleLowDiskSpaceRecovery() {
        guard let startupDiskSpace,
              startupDiskSpace.availableBytes >= preferences.lowDiskSpaceThresholdBytes,
              defaults.bool(forKey: Key.lowDiskSpaceAwaitingRecovery) else { return }
        defaults.removeObject(forKey: Key.lowDiskSpaceAwaitingRecovery)
    }

    /// The startup disk's free space, the way every page of the app shows it.
    /// D173: the important-usage figure makes macOS query CacheDelete; it can
    /// only add the purgeable space, so it is asked for only when the plain
    /// free space is already below the threshold.
    nonisolated static func measureStartupDiskSpace(thresholdBytes: Int64) -> StartupDiskSpace? {
        guard let plain = StorageCapacityService.snapshot(path: "/", includeImportantUsage: false) else { return nil }
        let snapshot = plain.availableBytes >= thresholdBytes
            ? plain
            : StorageCapacityService.snapshot(path: "/", includeImportantUsage: true) ?? plain
        let name = try? URL(fileURLWithPath: "/", isDirectory: true).resourceValues(forKeys: [.volumeNameKey]).volumeName
        return StartupDiskSpace(availableBytes: snapshot.userAvailableBytes,
                                totalBytes: snapshot.totalBytes,
                                volumeName: name)
    }

    /// Re-reads the Trash soon (coalesced while one read is running).
    func scheduleEvaluation() {
        guard started else { return }
        guard evaluationTask == nil else {
            evaluationQueued = true
            return
        }
        // CleanMyMac sums every Trash folder (`TrashLocations`); here only the
        // user's own Trash counts, because it is the only one the Empty Trash
        // action can empty (D101 L5 freezes `~/.Trash`). A reminder that could
        // not be cleared by its own button would keep coming back.
        let userTrash = TrashLocations.userTrash()
        let locations = [userTrash]
        monitor?.watch(locations)
        let measurer = self.measurer
        evaluationTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let movedByThisApp = AppLifecycleReminderCenter.pathsThisAppMovedToTrash()
                let measurement = measurer.measure(locations: locations)
                let detected = measurement.isReadable
                    ? TrashedApplicationsDetector.trashedApplications(inTrash: userTrash).applications
                    : []
                let applications = detected.filter { app in
                    let path = PathSafety.normalizedPath(app.url.path)
                    return !movedByThisApp.contains { path == $0 || path.hasPrefix($0 + "/") }
                }
                return (measurement, applications)
            }.value
            guard let self else { return }
            measurement = result.0
            trashedApplications = result.1
            if result.0.isReadable { ignoreList.pruneTrashedApplications() }
            evaluationTask = nil
            refreshAlert()
            if evaluationQueued {
                evaluationQueued = false
                scheduleEvaluation()
            }
        }
    }

    /// What this app itself moved to the Trash (any recorded operation):
    /// those apps were removed here deliberately and are not reminded about.
    nonisolated static func pathsThisAppMovedToTrash() -> [String] {
        guard let reports = try? CleanupReportJournal.live.loadAvailable().reports else { return [] }
        return reports.flatMap { report in
            report.items.compactMap { item -> String? in
                guard case .moved(let receipt) = item.outcome else { return nil }
                return PathSafety.normalizedPath(receipt.resultingItemURL.path)
            }
        }
    }

    // MARK: Deciding what to show

    /// The reminder that should be on screen now, before environment checks:
    /// trashed apps first (the person just did something), then little free
    /// space (D220), the Trash size, and last a due scan (D219).
    func currentAlert() -> Alert? {
        if preferences.offersCorrectUninstall {
            let apps = trashedApplications.filter { !ignoreList.isIgnored(.trashedApplication, discriminator: $0.discriminator) }
            if !apps.isEmpty { return .trashedApplications(apps) }
        }
        if let lowDiskSpace = lowDiskSpaceAlert() { return lowDiskSpace }
        if preferences.notifiesTrashSize, let measurement, measurement.isReadable,
           measurement.totalBytes > preferences.trashSizeThresholdBytes,
           !ignoreList.isIgnored(.trashSize, discriminator: "") {
            return .trashSize(bytes: measurement.totalBytes, threshold: preferences.trashSizeThresholdBytes,
                              itemCount: measurement.itemCount)
        }
        return scanDueAlert()
    }

    /// D220: once per drop below the threshold; a handled card waits until
    /// the space has recovered, and the Ignore menu applies on top.
    private func lowDiskSpaceAlert() -> Alert? {
        let threshold = preferences.lowDiskSpaceThresholdBytes
        guard preferences.notifiesLowDiskSpace, let startupDiskSpace,
              startupDiskSpace.availableBytes < threshold,
              !defaults.bool(forKey: Key.lowDiskSpaceAwaitingRecovery),
              !ignoreList.isIgnored(.lowDiskSpace, discriminator: "") else { return nil }
        return .lowDiskSpace(startupDiskSpace, threshold: threshold)
    }

    /// D219: the interval chosen in Settings has passed since the last scan.
    /// A Mac never scanned is the first-launch guide's business, not this
    /// card's, and no card appears while a scan is running.
    private func scanDueAlert() -> Alert? {
        let cadence = MaintenanceReminderService.cadence(defaults: defaults)
        let summary = MaintenanceReminderService.summary(cadence: cadence, lastScanAt: latestScanAt,
                                                         referenceDate: now())
        guard summary.status == .due, let lastScanAt = summary.lastScanAt,
              store?.isPreparingScan != true,
              !isRestingAfterScanNow,
              !ignoreList.isIgnored(.scanDue, discriminator: "") else { return nil }
        return .scanDue(lastScanAt: lastScanAt, cadence: cadence)
    }

    private var latestScanAt: Date? {
        if let lastScanDateProvider { return lastScanDateProvider() }
        return store?.scanHistorySummary.latestScanAt
    }

    private var isRestingAfterScanNow: Bool {
        guard let actedAt = defaults.object(forKey: Key.scanDueActedAt) as? Date else { return false }
        let date = now()
        return date >= actedAt && date < actedAt.addingTimeInterval(Self.scanDueRestAfterScanNow)
    }

    /// Decides again what to show (the app's triggers call this; tests call
    /// it on a center without a panel).
    func refreshAlert() {
        // A card busy with the Empty Trash steps stays until they end.
        switch emptyTrashPhase {
        case .freezing, .confirming, .emptying, .finished: return
        case .idle, .failed: break
        }
        let wanted = currentAlert()
        guard let wanted else {
            if presentedAlert != nil, emptyTrashPhase == .idle { dismissAlert() }
            stopPostponing()
            return
        }
        if let presentedAlert, presentedAlert.kind == wanted.kind {
            // Same reminder, newer facts (another app trashed, size changed).
            if presentedAlert != wanted { self.presentedAlert = wanted }
            return
        }
        let factors = presentsPanel ? AlertEnvironmentWatcher.activeFactors() : []
        guard factors.isEmpty else {
            // CleanMyMac: "Postpone alert - Active factors: [...]".
            if presentedAlert != nil { panel.hide(animated: true) ; presentedAlert = nil }
            startPostponing()
            return
        }
        stopPostponing()
        emptyTrashPhase = .idle
        presentedAlert = wanted
        if presentsPanel { panel.show(animated: true) }
    }

    private func startPostponing() {
        guard postponeTimer == nil else { return }
        postponeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAlert() }
        }
    }

    private func stopPostponing() {
        postponeTimer?.invalidate()
        postponeTimer = nil
    }

    /// The menu-bar panel opened over the card, or the person started using
    /// the main window: the card steps aside and comes back later.
    func environmentChanged() {
        guard presentedAlert != nil else { return }
        if case .emptying = emptyTrashPhase { return }
        if !AlertEnvironmentWatcher.activeFactors().isEmpty {
            panel.hide(animated: true)
            presentedAlert = nil
            startPostponing()
        }
    }

    private func dismissAlert() {
        if presentsPanel { panel.hide(animated: true) }
        presentedAlert = nil
        emptyTrashPhase = .idle
    }

    // MARK: Actions

    func ignore(_ option: AppLifecycleIgnoreOption) {
        guard let alert = presentedAlert else { return }
        ignoreList.ignore(alert.kind, discriminators: alert.discriminators, option: option)
        if alert.kind == .lowDiskSpace { defaults.set(true, forKey: Key.lowDiskSpaceAwaitingRecovery) }
        dismissAlert()
        refreshAlert()
    }

    /// Settings → “Reset Ignored Reminders”, after `ignoreList.reset()`: a
    /// low-space card handled during this drop and a scan card resting after
    /// “Scan Now” may come back too. The Ignore List (D207) is not touched.
    func releaseHandledReminders() {
        defaults.removeObject(forKey: Key.lowDiskSpaceAwaitingRecovery)
        defaults.removeObject(forKey: Key.scanDueActedAt)
        if started { scheduleEvaluation() } else if !presentsPanel { refreshAlert() }
    }

    /// “Uninstall…”: hands the trashed apps to the uninstaller, which finds
    /// and removes their leftovers (the bundles are already in the Trash).
    func uninstallTrashedApplications() {
        guard case .trashedApplications(let apps) = presentedAlert else { return }
        pendingTrashedUninstall = apps
        dismissAlert()
        go(to: .uninstaller)
    }

    /// D219 “Scan Now”: the Smart Scan page and its read-only scan. Nothing
    /// is cleaned; cleaning stays behind Smart Scan's own Run button.
    func scanNow() {
        guard case .scanDue = presentedAlert else { return }
        defaults.set(now(), forKey: Key.scanDueActedAt)
        dismissAlert()
        go(to: .smartScan)
    }

    /// D220 “Open Junk Cleanup”: only the module page; nothing is scanned or
    /// cleaned. The card counts as handled for this drop.
    func openJunkCleanup() {
        guard case .lowDiskSpace = presentedAlert else { return }
        defaults.set(true, forKey: Key.lowDiskSpaceAwaitingRecovery)
        dismissAlert()
        go(to: .junkCleanup)
    }

    private func go(to destination: Destination) {
        if let destinationOverride {
            destinationOverride(destination)
            return
        }
        switch destination {
        case .smartScan: store?.showFilter(.overview)
        case .junkCleanup: store?.showFilter(.green)
        case .uninstaller: store?.showFilter(.uninstall)
        }
        if let open = MainWindowReopenCoordinator.shared.openMainWindow {
            open()
        } else {
            NotificationCenter.default.post(name: .storageCleanerShowMainWindow, object: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if destination == .smartScan, let store { startSmartScan(in: store) }
    }

    /// Smart Care's Scan, as the landing's round button starts it, never its
    /// Run. The main window hands Smart Care the browser privacy store when
    /// it appears, so the scan waits a moment for that.
    private func startSmartScan(in store: ScanStore) {
        let smartCare = SmartCareCoordinator.of(store)
        Task { [weak store] in
            var waits = 0
            while !smartCare.hasAttachedPrivacy, waits < 30 {
                try? await Task.sleep(for: .milliseconds(100))
                waits += 1
            }
            guard let store, !store.isPreparingScan else { return }
            smartCare.start()
        }
    }

    /// Called by the uninstaller once the trashed apps were handled, so they
    /// are not offered again while they sit in the Trash.
    func markHandled(_ apps: [TrashedApplication]) {
        ignoreList.ignore(.trashedApplication, discriminators: apps.map(\.discriminator), option: .forever)
        trashedApplications.removeAll { app in apps.contains { $0.discriminator == app.discriminator } }
        refreshAlert()
    }

    /// “Empty Trash”: freezes the Trash as it is now and asks for D23's two
    /// acknowledgements inside the card.
    func requestEmptyTrash() {
        guard case .trashSize = presentedAlert, let heavyWork else { return }
        emptyTrashPhase = .freezing
        Task { [weak self] in
            do {
                let frozen = try await heavyWork.freezeTrash()
                guard let self else { return }
                if let frozen, !frozen.entries.isEmpty {
                    emptyTrashPhase = .confirming(frozen)
                } else {
                    emptyTrashPhase = .idle
                    scheduleEvaluation()
                }
            } catch {
                self?.emptyTrashPhase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelEmptyTrash() {
        emptyTrashPhase = .idle
    }

    func confirmEmptyTrash(acknowledgesPermanentDeletion: Bool, acknowledgesTrashContentsReviewed: Bool) {
        guard case .confirming(let frozen) = emptyTrashPhase,
              acknowledgesPermanentDeletion, acknowledgesTrashContentsReviewed,
              let heavyWork else { return }
        emptyTrashPhase = .emptying(itemCount: frozen.entries.count, bytes: frozen.summary.totalBytes)
        let coordinator = heavyWork.coordinator
        Task { [weak self] in
            do {
                let result = try await coordinator.withLease(owner: .emptyTrash) { lease in
                    try await heavyWork.emptyTrash(frozen, lease: lease)
                }
                guard let self else { return }
                emptyTrashPhase = .finished(result)
                if result.deletedCount > 0 { AppLifecycleSounds.playEmptyTrash() }
                await store?.heavyWorkActivityStore.refresh()
                try? await Task.sleep(for: .seconds(2.6))
                guard case .finished = emptyTrashPhase else { return }
                dismissAlert()
                scheduleEvaluation()
            } catch {
                guard let self else { return }
                emptyTrashPhase = .failed(Self.describe(error))
            }
        }
    }

    func acknowledgeEmptyTrashFailure() {
        emptyTrashPhase = .idle
        scheduleEvaluation()
    }

    /// Opens the Trash in Finder (CleanMyMac does it with AppleScript; this
    /// app uses NSWorkspace, AppleScript being off limits here).
    func openTrash() {
        NSWorkspace.shared.open(TrashLocations.userTrash())
    }

    private static func describe(_ error: Error) -> String {
        if case HeavyWorkCoordinator.Error.busy = error {
            return L10n.text("另一项任务正在进行，请稍后再清倒废纸篓。", "Another task is running. Empty the Trash again in a moment.")
        }
        return error.localizedDescription
    }
}

/// The sound CleanMyMac plays when it empties the Trash: Finder's own.
enum AppLifecycleSounds {
    static let emptyTrashSoundPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"

    @MainActor
    static func playEmptyTrash() {
        guard let sound = NSSound(contentsOfFile: emptyTrashSoundPath, byReference: true) else { return }
        sound.play()
    }
}
