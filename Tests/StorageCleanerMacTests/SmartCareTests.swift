import XCTest
@testable import StorageCleanerMac

/// D168: Smart Care scans five modules one after another (their scans share
/// one heavy-work lease), Stop skips the modules after the current one, the
/// module choice is kept, and its update check only reads.
@MainActor
final class SmartCareTests: XCTestCase {
    func testScansTheSelectedModulesOneAtATimeInCardOrder() async {
        let scanner = RecordingSmartCareScanner()
        let care = SmartCareCoordinator(scanner: scanner, defaults: TestPreferenceDomain.make(for: self))
        XCTAssertEqual(care.selection, SmartCareModule.defaultSelection)

        care.start()
        XCTAssertEqual(care.stage, .scanning(.cleanup))
        await waitUntil("results") { care.stage == .results }

        XCTAssertEqual(scanner.order, SmartCareModule.allCases)
        XCTAssertFalse(scanner.overlapped, "two module scans never run at once")
        for module in SmartCareModule.allCases { XCTAssertEqual(care.card(module), .done, "\(module)") }
    }

    func testModulesTurnedOffAreNeitherScannedNorShownAsWaiting() async {
        let defaults = TestPreferenceDomain.make(for: self)
        let scanner = RecordingSmartCareScanner()
        let care = SmartCareCoordinator(scanner: scanner, defaults: defaults)
        care.toggle(.protection)
        care.toggle(.clutter)
        XCTAssertEqual(SmartCareModule.selection(in: defaults), [.cleanup, .performance, .applications])
        XCTAssertEqual(SmartCareCoordinator(scanner: scanner, defaults: defaults).selection,
                       [.cleanup, .performance, .applications], "the choice is kept")

        care.start()
        await waitUntil("results") { care.stage == .results }

        XCTAssertEqual(scanner.order, [.cleanup, .performance, .applications])
        XCTAssertEqual(care.card(.protection), .off)
        XCTAssertEqual(care.card(.clutter), .off)
    }

    func testStopEndsTheModuleScanningAndSkipsTheOnesAfterIt() async {
        let scanner = RecordingSmartCareScanner()
        scanner.holds = [.performance]
        let care = SmartCareCoordinator(scanner: scanner, defaults: TestPreferenceDomain.make(for: self))

        care.start()
        await waitUntil("performance scanning") { scanner.isHeld(.performance) }
        XCTAssertEqual(care.stage, .scanning(.performance))
        care.toggle(.clutter)
        XCTAssertEqual(care.selection, SmartCareModule.defaultSelection, "the choice is fixed while scanning")
        care.reset()
        XCTAssertEqual(care.stage, .scanning(.performance), "Start Over waits for the scan")
        care.stop()
        await waitUntil("results") { care.stage == .results }

        XCTAssertEqual(scanner.order, [.cleanup, .protection, .performance])
        XCTAssertEqual(scanner.stopped, [.performance])
        XCTAssertEqual(care.card(.cleanup), .done)
        XCTAssertEqual(care.card(.protection), .done)
        XCTAssertEqual(care.card(.performance), .stopped)
        XCTAssertEqual(care.card(.applications), .stopped)
        XCTAssertEqual(care.card(.clutter), .stopped)

        care.reset()
        XCTAssertEqual(care.stage, .idle)
        XCTAssertTrue(care.cards.isEmpty)
    }

    func testACardKeepsWhyItsModuleDidNotRun() async {
        let scanner = RecordingSmartCareScanner()
        scanner.results[.applications] = .skipped("没有网络连接")
        scanner.results[.clutter] = .failed("读取失败")
        let care = SmartCareCoordinator(scanner: scanner, defaults: TestPreferenceDomain.make(for: self))

        care.start()
        await waitUntil("results") { care.stage == .results }

        XCTAssertEqual(scanner.order, SmartCareModule.allCases, "a skipped module does not stop the next one")
        XCTAssertEqual(care.card(.applications), .skipped("没有网络连接"))
        XCTAssertEqual(care.card(.clutter), .failed("读取失败"))
    }

    func testAnEmptyChoiceStartsNothingAndIsKept() {
        let defaults = TestPreferenceDomain.make(for: self)
        let scanner = RecordingSmartCareScanner()
        let care = SmartCareCoordinator(scanner: scanner, defaults: defaults)
        for module in SmartCareModule.allCases { care.toggle(module) }

        care.start()

        XCTAssertEqual(care.stage, .idle)
        XCTAssertTrue(scanner.order.isEmpty)
        XCTAssertEqual(SmartCareModule.selection(in: defaults), [])
    }

    /// D154 batch 3O: the first scan is remembered, so the landing greets a
    /// first visit only; a start that scans nothing does not count.
    func testTheFirstScanIsRemembered() async {
        let defaults = TestPreferenceDomain.make(for: self)
        let care = SmartCareCoordinator(scanner: RecordingSmartCareScanner(), defaults: defaults)
        XCTAssertFalse(care.hasStartedScan)
        for module in SmartCareModule.allCases { care.toggle(module) }
        care.start()
        XCTAssertFalse(care.hasStartedScan, "nothing was scanned")

        care.toggle(.performance)
        care.start()
        XCTAssertTrue(care.hasStartedScan)
        await waitUntil("results") { care.stage == .results }
        XCTAssertTrue(SmartCareCoordinator(scanner: RecordingSmartCareScanner(), defaults: defaults).hasStartedScan,
                      "it is kept")
    }

    /// D154 batch 3O: CleanMyMac's "Welcome to …" — the landing shows the
    /// app's name and its own line until the first scan: none in the history
    /// (an older version's scan counts) and Smart Care never started.
    func testTheLandingGreetsAFirstVisitOnly() throws {
        let welcome = try XCTUnwrap(SmartCareLandingView.welcome(latestStatus: nil, hasStartedScan: false))
        XCTAssertEqual(welcome.title, L10n.text("欢迎使用\(L10n.productName)", "Welcome to \(L10n.productName)"))
        XCTAssertNotEqual(welcome.subtitle, CareStudioModule.smartScan.subtitle)
        XCTAssertNil(SmartCareLandingView.welcome(latestStatus: nil, hasStartedScan: true))
        XCTAssertNil(SmartCareLandingView.welcome(latestStatus: Self.scannedBefore(), hasStartedScan: false))
    }

    /// A scan in the history from a minute ago.
    static func scannedBefore() -> LastScanStatusSummary {
        let entry = ScanHistoryEntry(date: Date().addingTimeInterval(-60), scanSeconds: 1, score: 90,
                                     diskUsedBytes: 400, diskFreeBytes: 600, greenBytes: 0, yellowBytes: 0,
                                     redBytes: 0, itemCount: 0, greenCount: 0, yellowCount: 0, redCount: 0,
                                     deniedCount: 0)
        guard let status = ScanHistorySummary(entries: [entry]).latestStatus() else {
            preconditionFailure("a history with one scan has a latest status")
        }
        return status
    }

    /// The cleanup card scans both file scopes and never the health check,
    /// whatever an older Smart Scan saved (D168; was the three D64 scopes).
    func testTheCleanupCardScansBothFileScopesAndNoHealthCheck() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.toggleSmartScanScope(.filesToReview)
        XCTAssertEqual(store.selectedSmartScanScopes, [.cleanupCandidates, .health])

        store.prepareSmartCareCleanupScopes()

        XCTAssertEqual(store.selectedSmartScanScopes, [.cleanupCandidates, .filesToReview])
        XCTAssertFalse(SmartCareModule.cleanupScopes.contains(.health))
    }

#if DEBUG
    // The results fixture exists only in DEBUG builds (release tests build without it).
    /// The cleanup card counts what the junk results count: junk, else the
    /// files to review; Run needs a ticked item.
    func testTheCleanupCardCountsLikeTheJunkResults() throws {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let session = try XCTUnwrap(store.cleanupScanSession)
        let summaries = CareJunkGrouping.summaries(for: session, filter: .overview)
        let junk = CleanupByteCount.sum(summaries.filter { $0.group != .filesToReview }.map(\.totalBytes))
        XCTAssertGreaterThan(junk, 0)

        let card = SmartCareSummaries.summary(for: .cleanup, state: .done, store: store, privacy: nil)

        // D178: decimal, as Finder writes it, "3.24 GB" on this fixture (was
        // `ByteFormat.string`, binary: "3.0 GiB").
        // Report §4 item 14: CleanMyMac's one large line and what it is for
        // ("73 GB of junk" / "to clean", cmm/14). Was
        // `XCTAssertEqual(card.value, ByteFormat.storageString(junk))` and
        // `XCTAssertEqual(card.caption, "垃圾 · 可清理")`; the states below
        // were read from `.caption`. The summary now has a headline and a
        // subtitle instead of a value and a caption.
        XCTAssertEqual(card.headline, "\(ByteFormat.storageString(junk)) 垃圾")
        XCTAssertEqual(card.subtitle, "可清理")
        XCTAssertTrue(card.reviews)
        XCTAssertEqual(card.line, "\(ByteFormat.storageString(junk)) 垃圾 · 可清理", "the scanning page's line, as before")
        let off = SmartCareSummaries.summary(for: .cleanup, state: .off, store: store, privacy: nil)
        XCTAssertEqual(off.headline, "已关闭")
        XCTAssertFalse(off.reviews, "an off module has nothing to review")
        XCTAssertEqual(SmartCareSummaries.summary(for: .clutter, state: .stopped, store: store, privacy: nil).headline, "已停止")
        XCTAssertEqual(SmartCareSummaries.summary(for: .applications, state: .skipped("没有网络连接"),
                                                  store: store, privacy: nil).headline, "没有网络连接")
    }
#endif

    /// Report §4 item 14: a card that found nothing says so in CleanMyMac's
    /// pattern ("No vital updates" / "to install", cmm/14) and has no Review.
    func testACardThatFoundNothingSaysSoWithoutReview() throws {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        let store = try ScanStore.makeForTests(for: self)
        let clutter = SmartCareSummaries.summary(for: .clutter, state: .done, store: store, privacy: nil)
        XCTAssertEqual(clutter.headline, "没有重复文件")
        XCTAssertEqual(clutter.subtitle, "不用处理")
        XCTAssertFalse(clutter.reviews)
        let cleanup = SmartCareSummaries.summary(for: .cleanup, state: .done, store: store, privacy: nil)
        XCTAssertEqual(cleanup.headline, "没有结果", "no session to read")
        XCTAssertTrue(cleanup.reviews, "Review opens Cleanup to scan")
    }

    /// Report §4 item 15 (CleanMyMac, cmm/11–13): while a part scans, its card
    /// grows in its row and its row in the page; with none scanning the cards
    /// share evenly.
    func testTheScanningCollageGrowsThePartScanning() {
        let size = CGSize(width: 1_000, height: 600)
        let gap = CareStudioMetrics.tileSpacing
        let height = size.height - gap
        let top = SmartCareScanningCollage.frames(count: 5, current: 0, in: size)
        XCTAssertEqual(top[0].height, height * 0.7, accuracy: 0.5)
        XCTAssertEqual(top[3].height, height * 0.3, accuracy: 0.5)
        XCTAssertEqual(top[0].width, (size.width - 2 * gap) * 0.58, accuracy: 0.5)
        XCTAssertEqual(top[1].width, top[2].width, accuracy: 0.5)
        XCTAssertEqual(top[3].width, top[4].width, accuracy: 0.5, "the short row shares evenly")
        let bottom = SmartCareScanningCollage.frames(count: 5, current: 3, in: size)
        XCTAssertEqual(bottom[3].height, height * 0.7, accuracy: 0.5)
        XCTAssertEqual(bottom[3].width, (size.width - gap) * 0.67, accuracy: 0.5)
        XCTAssertEqual(bottom[0].width, bottom[1].width, accuracy: 0.5)
        let none = SmartCareScanningCollage.frames(count: 5, current: nil, in: size)
        XCTAssertEqual(none[0].height, none[3].height, accuracy: 0.5)
        for frames in [top, bottom, none] {
            for frame in frames {
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame)")
            }
            XCTAssertEqual(frames[2].maxX, size.width, accuracy: 0.5)
            XCTAssertEqual(frames[4].maxX, size.width, accuracy: 0.5)
        }
    }

    /// Report §4 item 14: three cards above, the other two below, rows as
    /// tall as each other and no taller than CleanMyMac's.
    func testTheResultsGridPutsThreeCardsAboveAndTwoBelow() {
        let frames = SmartCareResultsGrid.frames(count: 5, in: CGSize(width: 1_000, height: 600))
        XCTAssertEqual(frames.count, 5)
        let gap = CareStudioMetrics.tileSpacing
        XCTAssertEqual(Set(frames.prefix(3).map(\.minY)), [0])
        XCTAssertEqual(Set(frames.suffix(2).map(\.minY)).count, 1)
        XCTAssertEqual(frames[3].minY, frames[0].maxY + gap, accuracy: 0.5)
        XCTAssertEqual(frames[0].height, SmartCareResultsGrid.maximumRowHeight, accuracy: 0.5)
        XCTAssertEqual(frames[3].height, frames[0].height, accuracy: 0.5)
        XCTAssertEqual(frames[2].maxX, 1_000, accuracy: 0.5)
        XCTAssertEqual(frames[4].maxX, 1_000, accuracy: 0.5)
        XCTAssertEqual(frames[0].width, (1_000 - 2 * gap) / 3, accuracy: 0.5)
        XCTAssertEqual(frames[3].width, (1_000 - gap) / 2, accuracy: 0.5)
        // A short window keeps the least height, and the grid scrolls.
        let short = SmartCareResultsGrid.frames(count: 5, in: CGSize(width: 700, height: 250))
        XCTAssertEqual(short[0].height, SmartCareResultsGrid.minimumRowHeight, accuracy: 0.5)
        XCTAssertGreaterThan(CareStudioTileGrid.contentHeight(of: short), 250)
    }

    /// 2.0.1 session's request: a check Smart Care starts only reads — it
    /// does not resume a saved update queue (so nothing is installed); the
    /// updater's own check still resumes it.
    func testSmartCareUpdateCheckNeitherResumesTheSavedQueueNorInstalls() async throws {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "waiting-for-quit", isRunning: true)
        let sessionID = UUID()
        let plan = ApplicationUpdatePlan(
            id: sessionID, automaticApplicationIDs: [], requiresQuitApplicationIDs: [application.id],
            requiresAuthorizationApplicationIDs: [], appStoreApplicationIDs: [], websiteApplicationIDs: [],
            manualApplicationIDs: [], skippedApplicationIDs: [])
        let queue = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion, plan: plan,
            tasks: [ApplicationUpdateTask(sessionID: sessionID, application: application, state: .waitingForQuit)],
            isPaused: false, updatedAt: Date())
        let coordinator = ApplicationUpdateCoordinator(repository: SmartCareQueueRepository(snapshot: queue),
                                                       executor: UnsupportedApplicationUpdateExecutor())
        let store = try ScanStore.makeForTests(for: self,
            applicationInventoryScanner: SmartCareInventoryScanner(applications: [application]),
            applicationUpdateCoordinator: coordinator)

        store.checkAppUpdatesForSmartCare()
        XCTAssertTrue(store.isLoadingAppUpdates)
        await waitUntil("Smart Care check") { !store.isLoadingAppUpdates }

        XCTAssertNotEqual(store.appUpdatePresentationState.phase, .updating, "the saved queue was not resumed")
        XCTAssertFalse(store.isRunningOneClickUpdate, "nothing is installing")

        store.refreshAppUpdates()
        await waitUntil("the updater's own check resumes the queue") {
            !store.isLoadingAppUpdates && store.appUpdatePresentationState.phase == .updating
        }
    }

    /// D168, batch 3L: Run cleans first (its plan and confirmations), then
    /// runs the confirmed maintenance tasks, and ends on the finished page.
    func testRunCleansFirstThenRunsTheMaintenanceTasks() async {
        let runner = RecordingSmartCareRunner()
        let care = await finishedSmartCare(runner: runner)

        care.run(cleanup: true, maintenanceTasks: [.speedUpMail])
        XCTAssertEqual(care.stage, .running(.cleanup))
        XCTAssertEqual(care.plannedRun, [.cleanup, .performance])
        care.toggle(.clutter)
        care.reset()
        XCTAssertEqual(care.selection, SmartCareModule.defaultSelection, "the choice is fixed while Run goes")
        XCTAssertEqual(care.stage, .running(.cleanup), "Start Over waits for Run")
        await waitUntil("finished") { care.stage == .finished }

        XCTAssertEqual(runner.order, ["clean", "maintenance"])
        XCTAssertEqual(runner.ranTasks, [.speedUpMail], "batch 3M: the tasks confirmed are the ones run")
        XCTAssertEqual(care.confirmedTasks, [.speedUpMail])
        XCTAssertEqual(care.runOutcomes, [.cleanup: .done, .performance: .done])
        care.reset()
        XCTAssertEqual(care.stage, .idle)
        XCTAssertTrue(care.runOutcomes.isEmpty)
    }

    /// Cancelling at the cleanup confirmation runs nothing else and goes back
    /// to the cards.
    func testCancellingTheCleanupConfirmationRunsNothingElse() async {
        let runner = RecordingSmartCareRunner()
        runner.cleanOutcome = .cancelled
        let care = await finishedSmartCare(runner: runner)

        care.run(cleanup: true, maintenanceTasks: [.speedUpMail])
        await waitUntil("back to the cards") { care.stage == .results }

        XCTAssertEqual(runner.order, ["clean"])
        XCTAssertTrue(care.plannedRun.isEmpty)
        XCTAssertTrue(care.runOutcomes.isEmpty)
    }

    /// Stopping the cleanup while it runs keeps what was moved and does not
    /// start the maintenance tasks (CleanMyMac: "wasn't run").
    func testStoppingTheCleanupLeavesTheMaintenanceTasksUnrun() async {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        let runner = RecordingSmartCareRunner()
        runner.cleanOutcome = .stopped
        let care = await finishedSmartCare(runner: runner)

        care.run(cleanup: true, maintenanceTasks: [.speedUpMail])
        await waitUntil("finished") { care.stage == .finished }

        XCTAssertEqual(runner.order, ["clean"])
        XCTAssertEqual(care.runOutcomes, [.cleanup: .stopped])
        XCTAssertEqual(SmartCareRunLines.lines(care), ["性能：没有运行（清理已停止）"])
        XCTAssertFalse(SmartCareRunLines.hasFailure(care))
    }

    func testRunWithOnlyTheMaintenanceTasksSkipsTheCleanup() async {
        let runner = RecordingSmartCareRunner()
        runner.maintenanceOutcome = .failed("无法运行")
        let care = await finishedSmartCare(runner: runner)

        care.run(cleanup: false, maintenanceTasks: [])
        XCTAssertEqual(care.stage, .results, "nothing ticked, nothing runs")
        care.run(cleanup: false, maintenanceTasks: [.speedUpMail])
        XCTAssertEqual(care.stage, .running(.performance))
        await waitUntil("finished") { care.stage == .finished }

        XCTAssertEqual(runner.order, ["maintenance"])
        XCTAssertEqual(care.runOutcomes, [.performance: .failed("无法运行")])
        care.run(cleanup: true, maintenanceTasks: [.speedUpMail])
        XCTAssertEqual(runner.order, ["maintenance"], "Run starts only from the cards")
    }

    /// 2.0.1 session's request: Run asks the maintenance page's own question,
    /// so its wording lives in one place and both pages use it.
    func testRunAsksTheMaintenancePagesOwnQuestion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
        }
        let page = try source("Views/Toolbox/SystemMaintenancePage.swift")
        let smartCare = try source("Views/CareStudio/CareStudioSmartCare.swift")
        XCTAssertEqual(page.components(separatedBy: "运行选中的维护任务？").count, 2, "the question is written once")
        XCTAssertTrue(page.contains("func maintenanceRunConfirmation("))
        XCTAssertTrue(page.contains(".maintenanceRunConfirmation(store, isPresented: $confirmsRun) { store.runSelected() }"))
        XCTAssertTrue(smartCare.contains(".maintenanceRunConfirmation(ToolboxStores.of(store).maintenance, isPresented: $confirmsMaintenance)"))
        XCTAssertFalse(smartCare.contains("运行选中的维护任务"))
    }

    /// A Smart Care whose stand-in scans all finished, on the cards.
    private func finishedSmartCare(runner: RecordingSmartCareRunner) async -> SmartCareCoordinator {
        let care = SmartCareCoordinator(scanner: RecordingSmartCareScanner(), runner: runner,
                                        defaults: TestPreferenceDomain.make(for: self))
        care.start()
        await waitUntil("results") { care.stage == .results }
        return care
    }

    private func waitUntil(_ description: String, timeout: Duration = .seconds(3),
                           _ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

/// Records the order of the scans, whether two overlapped, and holds a
/// module until it is stopped.
@MainActor
private final class RecordingSmartCareScanner: SmartCareScanning {
    var order: [SmartCareModule] = []
    var results: [SmartCareModule: SmartCareCardState] = [:]
    var holds: Set<SmartCareModule> = []
    private(set) var stopped: [SmartCareModule] = []
    private(set) var overlapped = false
    private var running: SmartCareModule?
    private var gates: [SmartCareModule: CheckedContinuation<Void, Never>] = [:]

    func isHeld(_ module: SmartCareModule) -> Bool { gates[module] != nil }

    func scan(_ module: SmartCareModule) async -> SmartCareCardState {
        if running != nil { overlapped = true }
        running = module
        order.append(module)
        if holds.contains(module) {
            await withCheckedContinuation { gates[module] = $0 }
        } else {
            await Task.yield()
        }
        running = nil
        return stopped.contains(module) ? .stopped : (results[module] ?? .done)
    }

    func stop(_ module: SmartCareModule) {
        stopped.append(module)
        gates.removeValue(forKey: module)?.resume()
    }
}

/// Records Run's parts in order and answers each with a set outcome.
@MainActor
private final class RecordingSmartCareRunner: SmartCareRunning {
    var order: [String] = []
    var cleanOutcome: SmartCareRunOutcome = .done
    var maintenanceOutcome: SmartCareRunOutcome = .done

    func clean() async -> SmartCareRunOutcome {
        order.append("clean")
        await Task.yield()
        return cleanOutcome
    }

    private(set) var ranTasks: [SystemMaintenanceTaskID] = []

    func runMaintenance(_ tasks: [SystemMaintenanceTaskID]) async -> SmartCareRunOutcome {
        order.append("maintenance")
        ranTasks = tasks
        await Task.yield()
        return maintenanceOutcome
    }
}

private actor SmartCareQueueRepository: ApplicationUpdateQueuePersisting {
    private var snapshot: ApplicationUpdateQueueSnapshot?

    init(snapshot: ApplicationUpdateQueueSnapshot?) {
        self.snapshot = snapshot
    }

    func load() -> ApplicationUpdateQueueSnapshot? { snapshot }
    func save(_ snapshot: ApplicationUpdateQueueSnapshot) { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

private struct SmartCareInventoryScanner: ApplicationInventoryScanning {
    let applications: [InstalledApplication]

    func scan(
        configuration: ApplicationScanConfiguration,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication] {
        try Task.checkCancellation()
        await onApplications(applications)
        await onProgress(ApplicationScanProgress(stage: .completed, scannedCount: applications.count,
                                                 discoveredCount: applications.count))
        return applications
    }
}
