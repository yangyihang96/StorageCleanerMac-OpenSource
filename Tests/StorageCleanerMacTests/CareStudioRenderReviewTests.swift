#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D141: renders every studio page off screen (no window, no scanner, no
/// executor) so the CleanMyMac-style layout can be compared with the
/// recorded screenshots. PNGs are written only when
/// `STORAGE_CLEANER_CARESTUDIO_EVIDENCE` names a directory.
@MainActor
final class CareStudioRenderReviewTests: XCTestCase {
    private static let detailSize = CGSize(width: 1_070, height: 735)
    private static let compactSize = CGSize(width: 780, height: 540)

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func preloadedArt() async -> GeneratedArtLibrary {
        let library = GeneratedArtLibrary(directory: projectRoot.appendingPathComponent("Resources/Art", isDirectory: true))
        for art in GeneratedArt.allCases {
            _ = await library.image(named: art.resourceName(.landing))
            _ = await library.image(named: art.resourceName(.header))
        }
        return library
    }

    /// The appearance the next renders use (the studio follows it: CleanMyMac
    /// colours at night, the daylight palette by day).
    private var scheme: ColorScheme = .dark

    @discardableResult
    private func render<V: View>(_ view: V, name: String, size: CGSize = detailSize,
                                 library: GeneratedArtLibrary) throws -> NSBitmapImageRep {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
            .environment(\.generatedArtLibrary, library)
            .environment(\.generatedArtWindowVisible, true)
            .environment(\.featureDisablesLayoutAnimations, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, name)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, size.width, accuracy: 0.5, name)
        if let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CARESTUDIO_EVIDENCE"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    static func scanProgress() -> DiskScanProgress {
        DiskScanProgress(cleanupProgress: CleanupScanProgress(
            phase: .enumerating,
            currentRuleID: "system.user-caches",
            currentRuleTitle: "用户缓存",
            currentPath: "/Users/fixture/Library/Caches/com.example.editor/Cache.db",
            currentRuleCompletedItemCount: 18,
            currentRuleTotalItemCount: 40,
            completedRuleCount: 9,
            totalRuleCount: 21,
            discoveredItemCount: 132,
            discoveredBytes: 7_350_000_000,
            groups: [
                .init(id: "system.user-caches", title: "用户缓存", itemCount: 40, bytes: 5_100_000_000, state: .scanning),
                .init(id: "system.user-logs", title: "用户日志", itemCount: 12, bytes: 640_000_000, state: .found),
                .init(id: "developer.xcode-derived-data", title: "Xcode", itemCount: 3, bytes: 1_200_000_000, state: .found),
                .init(id: "developer.codex-cache", title: "Codex", itemCount: 2, bytes: 410_000_000, state: .found),
                .init(id: "mail.downloaded-attachments", title: "邮件附件", itemCount: 0, bytes: 0, state: .clean),
                .init(id: "trash.user-trash", title: "废纸篓", itemCount: 0, bytes: 0, state: .pending),
                .init(id: "downloads.installers", title: "安装包", itemCount: 0, bytes: 0, state: .pending)
            ]))
    }

    func testRendersStudioPagesForReview() async throws {
        for (language, appearance) in [(AppLanguage.zhHans, ColorScheme.dark), (.zhHans, .light), (.english, .dark)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            scheme = appearance
            try await renderAllPages(suffix: (language == .english ? "en" : "zh") + (appearance == .dark ? "-dark" : "-light"))
        }
    }

    /// D187: the complete activity page and its no-snapshot state, rendered
    /// without a window, live probes, account access, or journal loading.
    func testRendersD187ActivityEvidenceAndNoSnapshotInBothLanguages() async throws {
        let library = await preloadedArt()
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)
        let home = try MyActivityD187Fixtures.cloudHome(for: self)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/Dropbox-Fixture"),
                                                withIntermediateDirectories: true)
        let cloud = CloudCleanupModel(home: home)
        XCTAssertEqual(cloud.providers.count, 1)
        let mac = MyActivityMacInfo(modelName: "Mac14,12", startupDiskName: "Fixture Disk",
            capacity: StorageCapacitySnapshot(totalBytes: 500_000_000_000, availableBytes: 100_000_000_000))
        var summary = MyActivitySummary()
        summary.timeSavingsRecords = [.init(id: "fixture-uninstall", category: .uninstall),
                                      .init(id: "fixture-update", category: .update)]
        summary.recoverableTrashBytes = 1_000_000_000
        for (language, appearance) in [(AppLanguage.zhHans, ColorScheme.dark), (.zhHans, .light), (.english, .dark)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            scheme = appearance
            let healthStore = ComputerHealthStore(probe: TestUnavailableComputerHealthProbe(),
                batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
            let tag = (language == .english ? "en" : "zh") + (appearance == .dark ? "-dark" : "-light")
            let page = CareStudioMyActivityPage(store: store, healthStore: healthStore, privacy: BrowserPrivacyStore(),
                cloud: cloud, summary: summary, mac: mac, now: { MyActivityD187Fixtures.now }, onNavigate: { _ in })
            try render(page, name: "d187-activity-no-snapshot-\(tag)", size: CGSize(width: 1_070, height: 1_800), library: library)
            let snapshot = ComputerHealthSecurityFixture.snapshot(smart: .failing)
            healthStore.installDebugPresentationFixture(snapshot: snapshot,
                evaluation: ComputerHealthScoring.evaluate(snapshot: snapshot, referenceDate: MyActivityD187Fixtures.now))
            try render(page, name: "d187-activity-evidence-\(tag)", size: CGSize(width: 1_070, height: 1_800), library: library)
        }
    }

    /// 10-24: the Applications done page when the removal could not start
    /// (another task held the lease): why, nothing moved, Back only.
    func testRendersApplicationsRemovalThatCouldNotStart() async throws {
        let library = await preloadedArt()
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let store = try ScanStore.makeForTests(for: self)
        let model = ApplicationsManagerModel.of(store)
        model.removal.trashResource = { _ in throw CancellationError() }
        model.removal.moves.recycle = { _ in throw CancellationError() }
        let path = "/Applications/Photon.app"
        let item = InstalledAppItem(id: path, name: "Photon", bundleIdentifier: "com.example.photon", path: path,
                                    version: "1", build: "1", category: "", appDescription: "", sizeBytes: 1_000, source: "",
                                    modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)
        let binary = ApplicationResource(path: path, group: .binaries, evidence: .bundle, domain: .user, kind: .file,
                                         sizeBytes: 100, identity: nil, isRemovable: true, note: nil)
        model.replaceEntries([ApplicationEntry(item: item, profile: nil,
            classification: ApplicationClassification(store: .other, vendor: .other, isUnused: false,
                                                      isThirtyTwoBitOnly: false, suspiciousReason: nil),
            resources: [binary], isThisApplication: false)])
        model.toggle(try XCTUnwrap(model.entries.first))
        let held = try await store.heavyWorkCoordinator.acquire(owner: .appUpdates)
        model.requestRemoval()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.phase != .finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.startFailure)
        try render(CareStudioApplicationsCompletion(model: model, showLog: {}), name: "applications-could-not-start",
                   library: library)
        await store.heavyWorkCoordinator.release(held)
        model.returnToBrowsing()
    }

    /// D214: a cleanup refused before it started — “Could Not Start”, why and
    /// that nothing moved; no success mark, no tally, only Back.
    func testRendersCleanupThatCouldNotStart() async throws {
        let library = await preloadedArt()
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let store = try ScanStore.makeForTests(for: self)
        let items = (1...3).map { index in
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "system.user-caches",
                            sourcePath: "/DebugFixture/Library/Caches/com.example.cache\(index)",
                            estimatedBytes: 1_000_000, outcome: .notProcessed)
        }
        var report = CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
            rulesVersion: "render-fixture", disposition: .trash, scanWasPartial: false,
            startedAt: Date(), completedAt: Date(), outcome: .failed, items: items,
            summary: CleanReportSummary(requestedItemCount: 3, movedItemCount: 0, skippedItemCount: 0,
                failedItemCount: 0, notProcessedItemCount: 3, unverifiedMoveCount: 0,
                plannedBytes: 3_000_000, movedToRecoverableLocationBytes: 0,
                reclaimableAfterEmptyingTrashBytes: 0, permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil))
        report.startRefusal = CleanFailure(code: .coordinatorBusy, detailCode: "lease-busy:appUpdates")
        XCTAssertEqual(OperationResultPresentation(report: report).title, "没能开始")
        try render(SmartScanCleanupCompletedPage(store: store, report: report, onDone: {}),
                   name: "cleanup-could-not-start", library: library)
        try render(SmartScanCleanupCompletedPage(store: store, report: report, onDone: {},
                                                 otherResults: ["性能：维护任务已运行完"]),
                   name: "cleanup-could-not-start-smart-care-run", library: library)
    }

    /// D219/D220: the scan-due and low-space cards that hang under the
    /// menu-bar icon, in both appearances (off screen the material draws
    /// plain). The center runs without its panel.
    func testRendersD219D220ReminderCards() async throws {
        let library = await preloadedArt()
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let defaults = TestPreferenceDomain.make(for: self)
        var preferences = AppLifecycleReminderPreferences.snapshot(defaults: defaults, startupDiskCapacity: { 494_384_795_648 })
        XCTAssertEqual(preferences.lowDiskSpaceThresholdBytes, 50_000_000_000)
        preferences.lowDiskSpaceThresholdBytes = 20_000_000_000
        AppLifecycleReminderPreferences.set(preferences, defaults: defaults)
        let now = Date()
        let center = AppLifecycleReminderCenter(ignoreList: AppLifecycleIgnoreList(directory: nil), defaults: defaults,
                                                now: { now }, lastScanDate: { now.addingTimeInterval(-9 * 24 * 60 * 60) },
                                                readStartupDiskSpace: { _ in nil }, presentsPanel: false)
        center.refreshAlert()
        XCTAssertEqual(center.presentedAlert?.kind, .scanDue)
        func card(_ name: String) throws {
            for appearance in [ColorScheme.dark, .light] {
                scheme = appearance
                let page = ZStack {
                    Rectangle().fill(appearance == .dark ? Color(white: 0.16) : Color(white: 0.9))
                    AppLifecycleAlertCard(center: center)
                }
                try render(page, name: "\(name)-\(appearance == .dark ? "dark" : "light")",
                           size: CGSize(width: 420, height: 280), library: library)
            }
        }
        try card("reminder-scan-due")
        center.applyStartupDiskSpace(.init(availableBytes: 12_400_000_000, totalBytes: 494_384_795_648, volumeName: "Macintosh HD"))
        XCTAssertEqual(center.presentedAlert?.kind, .lowDiskSpace)
        try card("reminder-low-disk-space")
        scheme = .dark
    }

    /// D221 补: the My Clutter results with the Large & Old Files tile, which
    /// counts the large-file list's files and offers only Review.
    func testRendersD221LargeOldTile() async throws {
        let library = await preloadedArt()
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let store = try ScanStore.makeForTests(for: self)
        let items = (0..<14).map { index -> StorageItem in
            let path = "/DebugFixture/Documents/Large file \(index).mov"
            return StorageItem(id: "large-\(index)", title: "Large file \(index).mov", path: path, sourceID: "large_files",
                               groupTitle: "", sizeBytes: Int64(index + 1) * 450_000_000, tier: .yellow, kind: "file", reason: "",
                               recommendation: "", risk: "", requiresClose: "", trashPaths: [path], openPath: path, status: .available)
        }
        store.largeFilesWorkspace.replaceItemsForTesting(items)
        let results = CareStudioClutterResults(store: store, confirmedGroups: 12, confirmedFiles: 31, logicalBytes: 4_820_000_000,
                                               physicalBytes: 3_100_000_000, candidateGroups: 5, onReview: { _ in }, onStartOver: {})
        // D226＋旧值：was ["duplicates", "candidates", "similarPhotos", "largeOld", "chatFiles"]; Downloads follows
        // Large & Old Files.
        XCTAssertEqual(results.tiles.map(\.id), ["duplicates", "candidates", "similarPhotos", "largeOld", "downloads", "chatFiles"])
        for appearance in [ColorScheme.dark, .light] {
            scheme = appearance
            try render(results, name: "clutter-results-large-old-\(appearance == .dark ? "dark" : "light")", library: library)
        }
        scheme = .dark
    }

    /// D226: the Downloads tile after Large & Old Files on the clutter
    /// results page, with what the category lists and only Review.
    func testRendersD226DownloadsTile() async throws {
        let library = await preloadedArt()
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let store = try ScanStore.makeForTests(for: self)
        let folder = "/DebugFixture/Downloads"
        let entries = (0..<9).map { index in
            StorageMapIndexedEntry(name: "Download \(index).zip", kind: "file", sizeBytes: Int64(index + 1) * 210_000_000,
                                   isDirectory: false, canDescend: false, isEstimated: false)
        }
        let index = StorageMapAnalysisIndex(rootPath: folder, rootVolumeIdentifier: nil,
                                            directories: [folder: StorageMapDirectoryAggregate(immediateChildCount: entries.count)],
                                            childrenByDirectory: [folder: entries], blockedDirectoryPaths: [], duplicateFilePaths: [])
        let analysis = StorageMapAnalysisResult(
            target: .init(path: folder, title: "Downloads", kind: .homeDirectory), volumeTotalBytes: 1_000_000_000_000,
            volumeAvailableBytes: 500_000_000_000, inspectedItemCount: entries.count, omittedItemCount: 0, scanSeconds: 1,
            index: index, rootSnapshot: try DiskScanner(excludedPaths: []).storageMapSnapshot(at: folder, using: index))
        ToolboxStores.of(store).downloads.replaceReadingForTesting(.init(analysis: analysis, sources: [:], modifiedDates: [:]))
        let results = CareStudioClutterResults(store: store, confirmedGroups: 12, confirmedFiles: 31, logicalBytes: 4_820_000_000,
                                               physicalBytes: 3_100_000_000, candidateGroups: 5, onReview: { _ in }, onStartOver: {})
        let tile = try XCTUnwrap(results.tiles.first { $0.id == "downloads" })
        XCTAssertEqual(tile.valueCaption, "9 个项目，按下载来源分组")
        XCTAssertNil(tile.onClean)
        for appearance in [ColorScheme.dark, .light] {
            scheme = appearance
            try render(results, name: "clutter-results-downloads-\(appearance == .dark ? "dark" : "light")", library: library)
        }
        scheme = .dark
    }

    /// D207: the note after a manager adds a row to the ignore list, with Put
    /// Back, at the bottom of the cleanup gradient (off screen its glass
    /// draws plain).
    func testRendersD207IgnoreNote() async throws {
        let library = await preloadedArt()
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let home = try TestFileSystem.makeHome(for: self)
        let list = IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
        let feedback = IgnoreListFeedback { list }
        XCTAssertNotNil(feedback.add([IgnoreListFeedback.Item(target: IgnoreListTarget(path: "/fixture/Library/Caches/com.example.editor"),
                                                              category: .systemJunk, name: "com.example.editor")]))
        let page = ZStack(alignment: .bottom) {
            CareStudioBackdrop(module: .cleanup)
            CareStudioIgnoreNote(feedback: feedback, place: .window).padding(.bottom, 84)
        }
        try render(page, name: "d207-ignore-note", size: CGSize(width: 780, height: 260), library: library)
    }

    /// D202 补二: Back to Smart Scan on the App Updates page Smart Care's
    /// Review opens. Off screen there is no title bar band, so the row takes
    /// room of its own at the top, as a studio page's does in full screen (in
    /// the window the module gradient is under it); the window class checks
    /// the band, and the manager, whose AppKit controls do not render here.
    func testRendersD202ReviewBackOnTheAppUpdatesPage() async throws {
        let library = await preloadedArt()
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugAppUpdatePresentationFixture(.summary)
        let page = try render(AppUpdaterView(store: store), name: "d202-updater-summary", library: library)
        let review = try render(AppUpdaterView(store: store).environment(\.careStudioReviewReturn, CareStudioReviewReturn {}),
                                name: "d202-updater-summary-review", library: library)
        XCTAssertNotEqual(page.tiffRepresentation, review.tiffRepresentation, "the Review draws Back")
    }

    private func renderAllPages(suffix: String) async throws {
        let library = await preloadedArt()
        // D187: old setup created an operation home even for read-only
        // offscreen renders. Keep factory guards without creating that home.
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)

        try render(SmartCareLandingView(store: store, latestStatus: nil), name: "01-smartscan-landing-\(suffix)", library: library)
        try render(ToolPreparationView(store: store, filter: .green), name: "02-cleanup-landing-\(suffix)", library: library)
        try render(ToolPreparationView(store: store, filter: .devCaches), name: "03-devtools-landing-\(suffix)", library: library)
        try render(ToolPreparationView(store: store, filter: .green), name: "02b-cleanup-landing-compact-\(suffix)",
                   size: Self.compactSize, library: library)

        let progress = Self.scanProgress()
        try render(SmartScanScanningPage(progress: progress, module: .green, canCancel: true, onCancel: {}),
                   name: "04-cleanup-scanning-\(suffix)", library: library)
        try render(SmartScanScanningPage(progress: progress, module: .overview, canCancel: true, onCancel: {}),
                   name: "05-smartscan-scanning-\(suffix)", library: library)

        store.installDebugSmartScanSessionFixture(.results)
        let session = try XCTUnwrap(store.cleanupScanSession)
        let summaries = CareJunkGrouping.summaries(for: session, filter: .green)
        XCTAssertFalse(summaries.isEmpty, "the fixture session lists junk")
        try render(CleanupScanResultsView(store: store, filter: .green, session: session),
                   name: "06-cleanup-results-\(suffix)", library: library)
        try render(CleanupScanResultsView(store: store, filter: .overview, session: session),
                   name: "07-smartscan-results-\(suffix)", library: library)
        try render(CareStudioJunkManager(store: store, module: .cleanup, session: session, summaries: summaries,
                                         focus: summaries.first?.group, onShowClassicList: {}, onBack: {}),
                   name: "08-cleanup-manager-\(suffix)", library: library)

        try render(SmartScanCleanupProgressPage(store: store, progress: Self.executionFixture(), onCancel: {}),
                   name: "09-cleaning-\(suffix)", library: library)
        // The fixture store holds no plan, so the task list is drawn from
        // plan items directly.
        try render(CareStudioCleaningPage(module: .cleanup, title: L10n.text("正在安全清理", "Cleaning Safely"),
                                          detail: "", progress: Self.executionFixture(processed: 6),
                                          planItems: Self.planItemsFixture()) { EmptyView() },
                   name: "09b-cleaning-tasks-\(suffix)", library: library)
        // Its issue list still scrolls (blank here); the window review
        // (`CareStudioWindowReviewTests`) shows that part.
        try render(SmartScanCleanupCompletedPage(store: store, report: Self.completedReportFixture(), onDone: {}),
                   name: "10-completed-\(suffix)", library: library)

        // D144: the memory pages, from a fixture snapshot and a measured push.
        let memory = Self.memorySnapshotFixture()
        try render(CareStudioMemoryLanding(snapshot: memory, isLoading: false, canFreeUp: true, onFreeUp: {}, onShowApps: {}),
                   name: "11-memory-landing-\(suffix)", library: library)
        try render(CareStudioMemoryRunning(onStop: {}), name: "12-memory-running-\(suffix)", library: library)
        let (result, outcome) = Self.memoryResultFixture()
        try render(CareStudioMemoryResultPage(result: result, reclaim: outcome, onDone: {}, onShowApps: {}),
                   name: "13-memory-result-\(suffix)", library: library)
        try render(CareStudioMemoryResultPage(result: result, reclaim: outcome, onDone: {}, onShowApps: {}),
                   name: "13b-memory-result-compact-\(suffix)", size: Self.compactSize, library: library)

        // Report §4 item 13 (`cmm/24`): the maintenance tile leads the
        // Performance results with Review and Run Tasks.
        let maintenance = ToolboxStores.of(store).maintenance
        var statuses = ToolboxWindowReviewTests.maintenanceStatuses()
        statuses[.rebuildLaunchServices]?.isRecommended = true
        maintenance.installPreview(statuses: statuses)
        XCTAssertEqual(maintenance.recommendedTasks, [.speedUpMail, .rebuildLaunchServices])
        let actions = CareStudioStartupActions(onRefresh: {}, onEnable: { _ in }, onDisable: { _ in },
                                               onStop: { _ in }, onReveal: { _ in },
                                               onOpenParentApplication: { _ in }, onCopyText: { _ in },
                                               onOpenSystemSettings: {}, onUndo: nil, onStartOver: {})
        // The window review's own items: `MainWindowSnapshotPipeline` would mark
        // this off-screen class display-bound (script/display_bound_tests.py).
        try render(CareStudioStartupResultsPage(items: CareStudioWindowReviewTests.startupItems(),
                                                activeOperationCandidateID: nil, isPerformingOperation: false,
                                                coverageAction: AnyView(EmptyView()), actions: actions,
                                                leadingTiles: [.maintenance(maintenance, onReview: {}) { _ in }],
                                                coverage: CareStudioWindowReviewTests.readStartupCoverage()),
                   name: "14-performance-results-\(suffix)", library: library)
    }

    /// A 16 GB Mac with 4.25 GB of file cache and normal pressure.
    static func memorySnapshotFixture() -> MemorySnapshot {
        let gib: Int64 = 1 << 30
        return MemorySnapshot(generatedAt: Date(), physicalBytes: 16 * gib, freeBytes: gib + gib / 4,
            inactiveBytes: 5 * gib, speculativeBytes: gib / 4, fileBackedBytes: 4 * gib + gib / 4,
            purgeableBytes: gib / 2, wiredBytes: 2 * gib + gib / 2, compressedBytes: gib + gib * 3 / 4,
            swapUsedBytes: gib / 4, pressureFreePercentage: 62, pressureSummary: "fixture", topProcesses: [])
    }

    /// A measured push on that Mac: about 3 GB more idle memory, stopped
    /// when the compressor began to grow.
    static func memoryResultFixture() -> (MemoryOptimizationResult, MemoryReclaimer.Outcome) {
        let gib: UInt64 = 1 << 30
        let memory = memorySnapshotFixture()
        let before = MemoryReclaimer.Reading(snapshot: memory)
        var after = before
        after.freeBytes += 3 * gib
        after.fileBackedBytes -= 2 * gib + gib * 3 / 4
        after.inactiveBytes -= 2 * gib + gib * 3 / 4
        let outcome = MemoryReclaimer.Outcome(before: before, after: after, budgetBytes: 5 * gib,
                                              pushedBytes: 4 * gib + gib * 3 / 4,
                                              stopReason: .compressorGrowing, duration: 2.4)
        let result = MemoryOptimizationResult(beforeSnapshot: memory, snapshot: memory, status: .completed,
                                              detail: MemoryOptimizerService.reclaimDetail(outcome),
                                              durationSeconds: 2.6, reclaim: outcome)
        return (result, outcome)
    }

    static func executionFixture(processed: Int = 8) -> CleanupExecutionProgress {
        CleanupExecutionProgress(planID: CleanPlanID(), processedItemCount: processed, totalItemCount: 12,
                                 movedItemCount: max(0, processed - 2), skippedItemCount: min(1, processed),
                                 failedItemCount: processed > 1 ? 1 : 0, currentRuleID: "system.user-caches")
    }

    /// Five caches, two logs, three Xcode folders and two mail downloads, in
    /// the order the executor would walk them.
    static func planItemsFixture() -> [CleanPlanItem] {
        let rules: [(String, Int, Int64)] = [("system.user-caches", 5, 1_200_000_000),
                                             ("system.user-logs", 2, 300_000_000),
                                             ("developer.xcode-derived-data", 3, 2_400_000_000),
                                             ("mail.downloaded-attachments", 2, 180_000_000)]
        return rules.flatMap { rule, count, bytes in
            (0..<count).map { _ in planItem(bytes: bytes / Int64(count), ruleID: rule) }
        }
    }

    private static func planItem(bytes: Int64, ruleID: String) -> CleanPlanItem {
        let url = URL(fileURLWithPath: "/DebugFixture/\(UUID().uuidString)")
        let snapshot = FileSnapshot(
            identity: FileIdentity(deviceID: 1, inode: 1, entryKind: .regularFile, creationTimeNanoseconds: 1),
            standardizedPath: url.path, volumeIdentifier: "volume-a", logicalSizeBytes: bytes,
            allocatedSizeBytes: bytes, modificationTimeNanoseconds: 1, isWritableVolume: true,
            isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
        return CleanPlanItem(id: UUID(), candidateID: ScanCandidateID(), ruleID: ruleID,
            ruleSelectionPolicyVersion: 1, sourceURL: url, allowedRootURL: url.deletingLastPathComponent(),
            expectedSnapshot: snapshot, action: .moveToTrash, riskLevel: .safe,
            executionEligibility: .eligible, measurementCompleteness: .complete, requiredClosedBundleIDs: [],
            reasonCode: "render", reasonCodes: ["render"], explicitUserSelection: true,
            verifiedDuplicateEvidence: nil, protectedRetainedCopies: [])
    }

    func testCleaningTasksFollowThePlanOrder() {
        let items = Self.planItemsFixture()
        let waiting = CareStudioCleaningTask.make(planItems: items, progress: nil, isCancelling: false)
        // D203＋旧值（D192）：开发者垃圾又单列一组。D192 时是 systemJunk(10)、
        // mailAttachments(2)，状态数组两项；D192 之前就是下面的三组。
        XCTAssertEqual(waiting.map(\.id), ["systemJunk", "developerJunk", "mailAttachments"])
        XCTAssertEqual(waiting.map(\.state), [.waiting, .waiting, .waiting], "nothing runs before the executor reports")
        XCTAssertEqual(waiting.map(\.total), [7, 3, 2])

        let midway = CareStudioCleaningTask.make(planItems: items, progress: Self.executionFixture(processed: 6),
                                                 isCancelling: false)
        XCTAssertEqual(midway.map(\.state), [.working, .waiting, .waiting], "item 7 is the second log")
        XCTAssertEqual(midway.map(\.processed), [6, 0, 0])

        let nextGroup = CareStudioCleaningTask.make(planItems: items, progress: Self.executionFixture(processed: 7),
                                                    isCancelling: false)
        XCTAssertEqual(nextGroup.map(\.state), [.done, .working, .waiting],
                       "D203＋旧值（D192）：[working, waiting]，非 AI 开发者在系统垃圾里执行")
        let mail = CareStudioCleaningTask.make(planItems: items, progress: Self.executionFixture(processed: 10),
                                              isCancelling: false)
        XCTAssertEqual(mail.map(\.state), [.done, .done, .working])
        XCTAssertEqual(mail.map(\.processed), [7, 3, 0], "Mail starts after the developer items (D192: [10, 0])")

        let stopping = CareStudioCleaningTask.make(planItems: items, progress: Self.executionFixture(processed: 7),
                                                   isCancelling: true)
        XCTAssertEqual(stopping.map(\.state), [.done, .waiting, .waiting],
                       "no spinner while stopping (D203＋旧值（D192）：[waiting, waiting])")

        let finished = CareStudioCleaningTask.make(planItems: items, progress: Self.executionFixture(processed: 12),
                                                   isCancelling: false)
        XCTAssertEqual(finished.map(\.state), [.done, .done, .done])
    }

    /// Six moves and one skip, so the tally, the title and the moved size
    /// agree (fixture paths only; nothing is touched).
    static func completedReportFixture() -> CleanReport {
        let moved = (1...6).map { index -> CleanReportItem in
            let path = "/DebugFixture/Library/Caches/com.example.cache\(index)"
            let receipt = CleanupMoveReceipt(originalPath: path,
                resultingItemURL: URL(fileURLWithPath: "/DebugFixture/.Trash/com.example.cache\(index)"),
                disposition: .trash,
                movedIdentity: FileIdentity(deviceID: 1, inode: UInt64(index), entryKind: .directory,
                                            creationTimeNanoseconds: 1),
                verification: .identityVerified, movedAt: Date())
            return CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "system.user-caches", sourcePath: path,
                                   estimatedBytes: 1_050_000_000, outcome: .moved(receipt))
        }
        return CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
            rulesVersion: "render-fixture", disposition: .trash, scanWasPartial: false,
            startedAt: Date(), completedAt: Date(), outcome: .partiallyCompleted, items: moved + [
                CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "system.user-caches",
                    sourcePath: "/DebugFixture/Library/Caches/com.example.running",
                    estimatedBytes: 1_000_000, outcome: .skipped(.relatedAppStillRunning))
            ],
            summary: CleanReportSummary(requestedItemCount: 7, movedItemCount: 6, skippedItemCount: 1,
                failedItemCount: 0, notProcessedItemCount: 0, unverifiedMoveCount: 0,
                plannedBytes: 6_400_000_000, movedToRecoverableLocationBytes: 6_300_000_000,
                reclaimableAfterEmptyingTrashBytes: 6_300_000_000, permanentlyFreedBytes: 0,
                availableSpaceDeltaBytes: nil))
    }

    func testJunkGroupingFollowsCleanMyMacOrder() throws {
        XCTAssertEqual(CareJunkGroup.group(ruleID: "system.user-caches"), .systemJunk)
        XCTAssertEqual(CareJunkGroup.group(ruleID: "developer.codex-cache"), .aiClutter)
        XCTAssertEqual(CareJunkGroup.group(ruleID: "developer.lmstudio-web-cache"), .aiClutter)
        XCTAssertEqual(CareJunkGroup.group(ruleID: "developer.xcode-derived-data"), .developerJunk,
                       "D203＋旧值（D192）：systemJunk")
        XCTAssertEqual(CareJunkGroup.group(ruleID: "mail.downloaded-attachments"), .mailAttachments)
        XCTAssertEqual(CareJunkGroup.group(ruleID: "trash.user-trash"), .trashBins)
        XCTAssertEqual(CareJunkGroup.group(ruleID: "downloads.installers"), .filesToReview,
                       "D203＋旧值（D192）：systemJunk")
        let categories = CareStudioScanCategories.make(Self.scanProgress())
        XCTAssertEqual(categories.map(\.id), ["systemJunk", "developerJunk", "aiClutter", "mailAttachments", "trashBins", "filesToReview"],
                       "D203＋旧值（D192）：[systemJunk, aiClutter, mailAttachments, trashBins]")
        XCTAssertEqual(categories.first?.state, .working)
        XCTAssertEqual(categories.first { $0.id == "mailAttachments" }?.state, .clean)
        XCTAssertEqual(categories.first { $0.id == "trashBins" }?.state, .pending)
    }

    func testBentoFramesPutTheFirstGroupInATallLeftTile() {
        let frames = CareStudioTileGrid.frames(count: 5, in: CGSize(width: 900, height: 400))
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames[0].minX, 0)
        XCTAssertGreaterThan(frames[0].height, frames[1].height)
        XCTAssertEqual(frames[1].minY, frames[2].minY)
        XCTAssertGreaterThan(frames[3].minY, frames[1].minY)
        // An odd remainder spans both right columns.
        let three = CareStudioTileGrid.frames(count: 4, in: CGSize(width: 900, height: 400))
        XCTAssertEqual(three[3].width, three[1].width * 2 + CareStudioMetrics.tileSpacing, accuracy: 0.5)
    }

    /// D141 revision (live check 2026-10-20): in a 1280 x 681 window the
    /// seven Smart Scan tiles needed 118 pt rows and ran under the round
    /// button. Rows now go down to what a small tile holds; below that the
    /// grid is taller than its area, and the view scrolls it there.
    func testTileGridFitsItsAreaOrReportsThatItScrolls() {
        for height in stride(from: CGFloat(200), through: 720, by: 20) {
            let frames = CareStudioTileGrid.frames(count: 7, in: CGSize(width: 905, height: height))
            for frame in frames.dropFirst() {
                XCTAssertGreaterThanOrEqual(frame.height, CareStudioTileGrid.minimumRowHeight - 0.5, "\(height)")
            }
            let content = CareStudioTileGrid.contentHeight(of: frames)
            if content > height + 0.5 {
                XCTAssertEqual(content, 3 * CareStudioTileGrid.minimumRowHeight + 2 * CareStudioMetrics.tileSpacing,
                               accuracy: 0.5, "only rows at their minimum overflow (\(height))")
            }
        }
        let live = CareStudioTileGrid.frames(count: 7, in: CGSize(width: 905, height: 340))
        XCTAssertLessThanOrEqual(CareStudioTileGrid.contentHeight(of: live), 340, "the live-check size now fits")
        // The window review found one or two large tiles squeezed to 192 pt
        // in a 604 x 490 window, their content running over the grid.
        for count in 1...3 {
            for height in [CGFloat(62), 192, 300, 420] {
                let frames = CareStudioTileGrid.frames(count: count, in: CGSize(width: 548, height: height))
                XCTAssertGreaterThanOrEqual(frames[0].height, CareStudioTileGrid.minimumLargeHeight - 0.5,
                                            "\(count) tiles in \(height) pt")
            }
        }
    }

    /// D141 revision (live check 2026-10-20): going from Smart Scan's results
    /// to Safe Cleanup's, the window showed a second copy of the new page,
    /// which then disappeared (`CareStudioNavigationTests` recorded: claim
    /// smart scan, claim cleanup, claim cleanup copy, release copy, release
    /// smart scan). The page still on screen decides the chrome — since D176
    /// only whether the gradient drifts. (Was
    /// `testSidebarChromeFollowsTheNewestPageStillOnScreen`, which checked
    /// `prefersSidebarRail` — true while the Safe Cleanup results stayed,
    /// false from the later landing — before pages stopped folding the
    /// sidebar.)
    func testStudioChromeFollowsTheNewestPageStillOnScreen() {
        let canvas = CareStudioCanvas()
        let smartScan = UUID(), cleaning = UUID(), copy = UUID(), landing = UUID()
        canvas.claim(smartScan, animating: false)
        canvas.claim(cleaning, animating: true)
        canvas.claim(copy, animating: true)
        canvas.release(copy)
        canvas.release(smartScan)
        XCTAssertTrue(canvas.isAnimating, "the cleaning page is still on screen")

        canvas.claim(landing, animating: false)
        XCTAssertFalse(canvas.isAnimating, "a landing page that appears later decides")
        canvas.release(cleaning)
        XCTAssertFalse(canvas.isAnimating)
        canvas.release(landing)
        XCTAssertFalse(canvas.isAnimating, "with no studio page the gradient is still")
    }

    /// D141 revision (live check 2026-10-20): the Safe Cleanup headline said
    /// "68.4 GiB of junk" counting the files to review, while the tiles
    /// showed only what was recommended. Junk is now every group but the
    /// files to review, which the headline names apart.
    func testCleanupHeadlineCountsJunkAndNamesTheFilesToReviewApart() throws {
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let session = try XCTUnwrap(store.cleanupScanSession)
        let first = try XCTUnwrap(CareJunkGrouping.summaries(for: session, filter: .green).first)
        let junk = CareJunkGroupSummary(group: .systemJunk, subgroups: first.subgroups)
        let review = CareJunkGroupSummary(group: .filesToReview, subgroups: first.subgroups)
        // D178: the headline writes sizes in decimal units, as Finder does,
        // "2.16 GB" on this fixture (was `ByteFormat.string`, binary: "2.0 GiB").
        let size = ByteFormat.storageString(first.totalBytes)

        let both = CareStudioJunkResultsPage.cleanupHeadline([junk, review])
        XCTAssertEqual(both.components(separatedBy: size).count - 1, 2, "junk and files to review, each once: \(both)")
        XCTAssertFalse(both.contains(ByteFormat.storageString(first.totalBytes * 2)), "files to review are not junk: \(both)")
        XCTAssertEqual(CareStudioJunkResultsPage.cleanupHeadline([junk]).components(separatedBy: size).count - 1, 1)
        XCTAssertEqual(CareStudioJunkResultsPage.cleanupHeadline([review]).components(separatedBy: size).count - 1, 1)
        XCTAssertNotEqual(CareStudioJunkResultsPage.cleanupHeadline([junk]),
                          CareStudioJunkResultsPage.cleanupHeadline([review]))
    }
}
#endif
