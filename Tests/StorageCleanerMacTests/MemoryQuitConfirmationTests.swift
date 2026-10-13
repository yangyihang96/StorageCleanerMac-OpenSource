import AppKit
import XCTest
@testable import StorageCleanerMac

/// BOARD N19 (P1, live test 2026-10-07): the memory page's recommended action
/// selected the suggested apps on the first click and, on the second click,
/// quit them without asking (`requestQuit…` followed by `confirmQuit…`), so a
/// double click quit real apps. Every quit now goes through a confirmation
/// that names the apps; a click right after the button changed is ignored;
/// the app the user is working in is never suggested.
@MainActor
final class MemoryQuitConfirmationTests: XCTestCase {
    private let suggested = MiniWindowLogicFixtures.memoryProcess(
        id: 7_601, name: "Suggested", residentBytes: 900 * 1024 * 1024)
    private let second = MiniWindowLogicFixtures.memoryProcess(
        id: 7_602, name: "Second", residentBytes: 800 * 1024 * 1024)

    private final class Clock {
        var now: TimeInterval
        init(_ now: TimeInterval) { self.now = now }
    }

    private func makeStore(processes: [MemoryProcess]? = nil, clock: Clock) throws -> ScanStore {
        let store = try ScanStore.makeForTests(for: self)
        store.memorySnapshot = MiniWindowLogicFixtures.memorySnapshot(processes: processes ?? [suggested, second])
        store.memoryActionUptime = { clock.now }
        return store
    }

    func testTheSecondClickAsksForConfirmationAndNeverQuitsByItself() throws {
        let clock = Clock(100)
        let store = try makeStore(clock: clock)
        XCTAssertEqual(store.memorySnapshot?.cleanupPlan.primaryAction, .quitHighUsageApps)

        store.performRecommendedMemoryAction()
        XCTAssertTrue(store.isRecommendedMemorySelectionPrepared)
        XCTAssertNil(store.pendingMemoryQuitSummary, "the first click only selects")

        clock.now += 2
        store.performRecommendedMemoryAction()
        XCTAssertFalse(store.isOptimizingMemory, "nothing quits before the confirmation")
        let summary = try XCTUnwrap(store.pendingMemoryQuitSummary, "the second click asks first")
        XCTAssertEqual(Set(summary.appNames), ["Suggested", "Second"])
        XCTAssertFalse(store.isMemoryBatchQuitConfirmationPresentedInMenuBar, "the main window's confirmation")
        XCTAssertEqual(Set(store.pendingMemoryProcessesToQuit.map(\.id)), [suggested.id, second.id])

        store.cancelQuitSelectedMemoryProcesses()
        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertFalse(store.isOptimizingMemory)
        XCTAssertTrue(store.isRecommendedMemorySelectionPrepared, "cancelling keeps the selection")
    }

    func testAClickRightAfterTheButtonChangesIsIgnored() throws {
        let clock = Clock(100)
        let store = try makeStore(clock: clock)
        store.performRecommendedMemoryAction()

        clock.now += 0.2
        store.performRecommendedMemoryAction()
        XCTAssertNil(store.pendingMemoryQuitSummary, "the second half of a double click does nothing")
        XCTAssertFalse(store.isOptimizingMemory)
        XCTAssertTrue(store.isRecommendedMemorySelectionPrepared, "the selection stays")

        clock.now += ScanStore.recommendedMemoryActionDebounce
        store.performRecommendedMemoryAction()
        XCTAssertNotNil(store.pendingMemoryQuitSummary, "a later click asks for confirmation")
        XCTAssertFalse(store.isOptimizingMemory)
        store.cancelQuitSelectedMemoryProcesses()
    }

    /// Review P2-9: the debounce follows the user's double-click interval
    /// (System Settings; 0.5 s by default), at least 0.6 s.
    func testTheDebounceCoversADoubleClick() {
        XCTAssertEqual(ScanStore.recommendedMemoryActionDebounce(doubleClickInterval: 0.5), 0.6)
        XCTAssertEqual(ScanStore.recommendedMemoryActionDebounce(doubleClickInterval: 1.2), 1.2,
                       "a slower double click is still one double click")
        XCTAssertEqual(ScanStore.recommendedMemoryActionDebounce(doubleClickInterval: .nan), 0.6)
        XCTAssertEqual(ScanStore.recommendedMemoryActionDebounce,
                       max(0.6, NSEvent.doubleClickInterval), "this Mac's setting")
    }

    /// Suggestions selected in the list ("选择建议项") also turn the button
    /// into "退出高占用应用"; its first click then asks for confirmation.
    func testTheChangedButtonAsksAtOnceWhenTheListSelectedTheSuggestions() throws {
        let store = try makeStore(clock: Clock(100))
        XCTAssertTrue(store.selectRecommendedMemoryApps())
        XCTAssertTrue(store.isRecommendedMemorySelectionPrepared)
        store.performRecommendedMemoryAction()
        XCTAssertNotNil(store.pendingMemoryQuitSummary)
        XCTAssertFalse(store.isOptimizingMemory)
        store.cancelQuitSelectedMemoryProcesses()
    }

    func testTheListsQuitButtonOnlyAsksForConfirmation() throws {
        let store = try makeStore(clock: Clock(1))
        let app = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first { $0.name == "Second" })
        store.setMemoryAppUsageSelection(app, isSelected: true)
        store.requestQuitSelectedMemoryProcesses()
        XCTAssertEqual(store.pendingMemoryQuitSummary?.appNames, ["Second"])
        XCTAssertFalse(store.isOptimizingMemory)
        store.cancelQuitSelectedMemoryProcesses()

        let utilities = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let button = try MiniWindowLogicFixtures.section(
            utilities, from: "private func quitSelectionButton(selectedAppCount: Int) -> some View {",
            to: "private struct MemoryReadOnlyProcessRow")
        XCTAssertTrue(button.contains("store.requestQuitSelectedMemoryProcesses()"))
        XCTAssertFalse(button.contains("confirmQuit"))

        // Only a confirmation's own button confirms; no other code path quits.
        let storeSource = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let action = try MiniWindowLogicFixtures.section(
            storeSource, from: "func performRecommendedMemoryAction(", to: "func scanEnergyImpact()")
        XCTAssertFalse(action.contains("confirmQuitSelectedMemoryProcesses"), "N19: the button never confirms by itself")
        for path in ["Sources/StorageCleanerMac/Views/ContentView.swift",
                     "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"] {
            let view = try MiniWindowLogicFixtures.source(path)
            XCTAssertEqual(view.components(separatedBy: "store.confirmQuitSelectedMemoryProcesses()").count - 1, 1,
                           "\(path): only the confirmation's quit button confirms")
        }
    }

    func testEveryConfirmationNamesTheAppsAndLeavesUnsavedWorkToThem() throws {
        let summary = MemoryQuitSelectionSummary(
            appCount: 2, estimatedBytes: 2 * 1024 * 1024 * 1024, appNames: ["Alpha", "Beta"])
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertTrue(summary.confirmationMessage.contains("Alpha、Beta"), summary.confirmationMessage)
        XCTAssertTrue(summary.confirmationMessage.contains("未保存的内容由各应用自行处理"), summary.confirmationMessage)
        XCTAssertTrue(summary.confirmationMessage.contains("不会强制退出"), summary.confirmationMessage)
        let twelve = MemoryQuitSelectionSummary(
            appCount: 12, estimatedBytes: 1, appNames: (1...12).map { "App\($0)" })
        XCTAssertTrue(twelve.confirmationMessage.contains("App1、App2、App3、App4"), "more than three names are listed")
        XCTAssertTrue(twelve.confirmationMessage.contains("App10"))
        XCTAssertTrue(twelve.confirmationMessage.contains("等 12 个"))
        chinese.restore()
        let english = MiniWindowLogicLanguageScope(.english)
        XCTAssertTrue(summary.confirmationMessage.contains("Alpha, Beta"), summary.confirmationMessage)
        XCTAssertTrue(summary.confirmationMessage.contains("unsaved"), summary.confirmationMessage)
        // Review P2-9: reads as English.
        XCTAssertTrue(summary.confirmationMessage.hasPrefix("These apps will quit normally: Alpha, Beta."),
                      summary.confirmationMessage)
        XCTAssertTrue(summary.confirmationMessage.hasSuffix(
            "the memory freed is measured again after they quit."), summary.confirmationMessage)
        english.restore()

        // D64: both remaining production confirmation hosts show it.
        for (path, start, end) in [
            ("Sources/StorageCleanerMac/Views/ContentView.swift",
             ".alert(L10n.text(\"退出所选应用？\", \"Quit Selected Apps?\")", ".alert(L10n.text(\"操作失败\""),
            ("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift",
             "L10n.text(\"退出所选应用？\", \"Quit Selected Apps?\")", "private struct GeekMemoryQuitResultCard"),
        ] {
            let alert = try MiniWindowLogicFixtures.section(try MiniWindowLogicFixtures.source(path), from: start, to: end)
            XCTAssertTrue(alert.contains("Text(summary.confirmationMessage)"), path)
        }
    }

    func testSuggestionsSkipTheAppTheUserIsWorkingIn() throws {
        XCTAssertEqual(UserFrontmostApplicationTracker.resolve(frontmost: 501, lastOther: 400, own: 300), 501)
        XCTAssertEqual(UserFrontmostApplicationTracker.resolve(frontmost: 300, lastOther: 400, own: 300), 400,
                       "while this app is in front, the app that was in front before it")
        XCTAssertNil(UserFrontmostApplicationTracker.resolve(frontmost: 300, lastOther: nil, own: 300))
        XCTAssertEqual(UserFrontmostApplicationTracker.resolve(frontmost: nil, lastOther: 400, own: 300), 400)

        let tracker = UserFrontmostApplicationTracker(ownProcessIdentifier: 300)
        tracker.recordActivation(of: 400)
        tracker.recordActivation(of: 300)
        XCTAssertEqual(tracker.userFrontmostProcessIdentifier(frontmost: 300), 400,
                       "activating this app keeps the app before it")
        tracker.recordActivation(of: 401)
        XCTAssertEqual(tracker.userFrontmostProcessIdentifier(frontmost: 401), 401)

        let applications = [FakeApplication(pid: 400), FakeApplication(pid: 401)]
        let identities = RunningApplicationIdentityCache.identities(
            of: applications, startTime: { _ in nil }, userFrontmostProcessIdentifier: 400)
        XCTAssertEqual(identities.first { $0.0 == 400 }?.1.isActive, true, "the user's app counts as active")
        XCTAssertEqual(identities.first { $0.0 == 401 }?.1.isActive, false)

        var inUse = suggested
        inUse.isActive = true
        let store = try makeStore(processes: [inUse, second], clock: Clock(1))
        XCTAssertEqual(store.memorySnapshot?.recommendedQuitApps.map(\.name), ["Second"])

        let app = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift")
        let launch = try MiniWindowLogicFixtures.section(
            app, from: "func applicationDidFinishLaunching(", to: "func applicationShouldTerminateAfterLastWindowClosed(")
        XCTAssertTrue(launch.contains("UserFrontmostApplicationTracker.shared.start()"),
                      "activations are followed from launch")
    }
}

private final class FakeApplication: RunningApplicationIdentitySource {
    let processIdentifier: pid_t
    let localizedName: String?
    let activationPolicy: NSApplication.ActivationPolicy = .regular
    let isActive = false
    let bundleIdentifier: String?
    let bundleURL: URL?
    let executableURL: URL?
    let launchDate: Date? = Date(timeIntervalSince1970: 1_000)

    init(pid: pid_t) {
        processIdentifier = pid
        localizedName = "App \(pid)"
        bundleIdentifier = "com.example.app\(pid)"
        bundleURL = URL(fileURLWithPath: "/Applications/App\(pid).app")
        executableURL = URL(fileURLWithPath: "/Applications/App\(pid).app/Contents/MacOS/App\(pid)")
    }
}
