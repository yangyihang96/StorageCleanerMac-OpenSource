import AppKit
import XCTest
@testable import StorageCleanerMac

/// D255–D259 (10-28, the user's request relayed by the parent session): the
/// menu-bar panel runs without the main program, in the same process. Quitting
/// the main program keeps the panel unless the session ends, an update
/// relaunches, this app is uninstalled or the user quits completely.
@MainActor
final class MenuBarOnlyModeD255D259Tests: XCTestCase {
    // MARK: D256 the quit decision

    func testOnlyAUserQuitWithThePanelInstalledAndTheSettingOnKeepsThePanel() {
        XCTAssertEqual(AppQuitPolicy.decision(reason: .user, keepsMenuBarPanel: true, hasMenuBarPanel: true),
                       .keepMenuBarPanel)
        XCTAssertEqual(AppQuitPolicy.decision(reason: .user, keepsMenuBarPanel: false, hasMenuBarPanel: true),
                       .terminate, "the setting is off")
        XCTAssertEqual(AppQuitPolicy.decision(reason: .user, keepsMenuBarPanel: true, hasMenuBarPanel: false),
                       .terminate, "no panel to keep")
        for reason in [AppQuitReason.sessionEnding, .updateRelaunch, .final] {
            XCTAssertEqual(AppQuitPolicy.decision(reason: reason, keepsMenuBarPanel: true, hasMenuBarPanel: true),
                           .terminate, "\(reason)")
        }
    }

    func testTheQuitEventsReasonSeparatesLogOutRestartAndShutDownFromAUserQuit() {
        XCTAssertEqual(AppQuitReason.from(quitEvent: nil), .user, "⌘Q sends no Apple event")
        XCTAssertEqual(AppQuitReason.from(quitEvent: Self.quitEvent(reason: nil)), .user, "the Dock's Quit")
        for code in ["logo", "rlgo", "rrst", "rest", "rsdn", "shut"] {
            XCTAssertEqual(AppQuitReason.from(quitEvent: Self.quitEvent(reason: code)), .sessionEnding, code)
        }
        XCTAssertEqual(AppQuitReason.from(quitEvent: Self.openEvent(loginItem: false)), .user, "not a quit event")
    }

    func testAQuitAnotherProgramSendsEndsTheProcessButTheDocksDoesNot() {
        // install24 check (10-28): build_and_run.sh quits the installed Beta
        // with `osascript … to quit`; kept alive, the next install would stop.
        // The sender attribute is filled in only on delivery, so a locally
        // built event carries none: the classification is checked directly,
        // the delivered `osascript` quit on the device (install24).
        let dock: pid_t = 101, script: pid_t = 202
        let isDock: (pid_t) -> Bool = { $0 == dock }
        XCTAssertEqual(AppQuitReason.classify(reasonCode: nil, senderPID: dock, senderIsDock: isDock),
                       .user, "the Dock's Quit and the app switcher's")
        XCTAssertEqual(AppQuitReason.classify(reasonCode: nil, senderPID: script, senderIsDock: isDock),
                       .otherProgram, "a script, an installer or Activity Monitor wants the app gone")
        XCTAssertEqual(AppQuitReason.classify(reasonCode: Self.code("rest"), senderPID: script, senderIsDock: isDock),
                       .sessionEnding)
        XCTAssertEqual(AppQuitReason.classify(reasonCode: nil, senderPID: getpid(), senderIsDock: { _ in false }),
                       .user, "this app's own Quit menu item")
        XCTAssertEqual(AppQuitReason.from(quitEvent: Self.quitEvent(reason: nil), senderIsDock: { _ in false }),
                       .user, "no sender recorded: the user's quit")
        XCTAssertEqual(AppQuitPolicy.decision(reason: .otherProgram, keepsMenuBarPanel: true, hasMenuBarPanel: true),
                       .terminate)
    }

    func testAFinalRequestAPowerOffAndAnUpdateOutrankTheEvent() {
        let intent = AppQuitIntent()
        XCTAssertEqual(intent.reason(currentEvent: nil, isInstallingUpdate: false), .user)
        XCTAssertEqual(intent.reason(currentEvent: nil, isInstallingUpdate: true), .updateRelaunch)
        intent.noteSessionEnding()
        XCTAssertEqual(intent.reason(currentEvent: nil, isInstallingUpdate: true), .sessionEnding)
        intent.markFinal()
        XCTAssertEqual(intent.reason(currentEvent: nil, isInstallingUpdate: true), .final)
    }

    func testTheSettingDefaultsOn() throws {
        let defaults = TestPreferenceDomain.make(for: self)
        XCTAssertTrue(AppQuitPreferences.keepsMenuBarPanelAfterQuit(defaults))
        defaults.set(false, forKey: AppQuitPreferences.keepsMenuBarPanelKey)
        XCTAssertFalse(AppQuitPreferences.keepsMenuBarPanelAfterQuit(defaults))
    }

    // D256's app delegate tests are in MenuBarOnlyQuitDelegateD256Tests (D106:
    // a class that creates AppDelegate runs on the test display).

    // MARK: D258 a login launch

    func testALoginItemLaunchIsRecognizedFromTheOpenEvent() {
        XCTAssertTrue(AppLaunchKind.isLoginItemLaunch(Self.openEvent(loginItem: true)))
        XCTAssertFalse(AppLaunchKind.isLoginItemLaunch(Self.openEvent(loginItem: false)))
        XCTAssertFalse(AppLaunchKind.isLoginItemLaunch(nil))
        XCTAssertFalse(AppLaunchKind.isLoginItemLaunch(Self.quitEvent(reason: nil)))
    }

    func testTheLoginLaunchRehearsalIsOnlyInDebugAndBetaBuilds() throws {
        XCTAssertFalse(MenuBarOnlyMode.isLoginLaunchRehearsalRequested, "the test host passes no such argument")
        let mode = try source("Sources/StorageCleanerMac/App/MenuBarOnlyMode.swift")
        let rehearsal = try MiniWindowLogicFixtures.section(mode, from: "#if DEBUG || STORAGE_CLEANER_BETA\n    /// D258 on a device",
                                                            to: "#endif")
        XCTAssertTrue(rehearsal.contains("\"--rehearse-login-launch\""))
        XCTAssertTrue(mode.contains("#else\n    static let isLoginLaunchRehearsalRequested = false\n#endif"), "Release never rehearses")
    }

    func testTheFirstMainWindowIsSuppressedOnlyOnceForALoginLaunch() {
        let mode = MenuBarOnlyMode(dependencies: Recorder().dependencies)
        XCTAssertFalse(mode.takeLaunchWindowSuppression(), "a normal launch shows the main window")
        mode.beginAtLaunch()
        XCTAssertTrue(mode.isActive)
        XCTAssertTrue(mode.takeLaunchWindowSuppression())
        XCTAssertFalse(mode.takeLaunchWindowSuppression(), "Open Main Program shows the next window")
    }

    // MARK: D255 launch work

    func testLaunchWorkRunsOnceWhicheverEntryComesFirst() {
        let coordinator = AppLaunchCoordinator()
        var runs: [String] = []
        coordinator.prepare { _ in runs.append("launch work") }
        coordinator.start(delegate: nil)
        coordinator.start(delegate: nil)
        XCTAssertEqual(runs, ["launch work"])
        let unprepared = AppLaunchCoordinator()
        unprepared.start(delegate: nil)
        var late = 0
        unprepared.prepare { _ in late += 1 }
        XCTAssertEqual(late, 1, "work prepared after a start request still runs, once")
        unprepared.start(delegate: nil)
        XCTAssertEqual(late, 1)
    }

    // MARK: D257 the menu-bar-only state

    func testEnteringClosesTheMainProgramButKeepsFanControlAndLiveMonitoring() async {
        let recorder = Recorder()
        let mode = MenuBarOnlyMode(dependencies: recorder.dependencies)
        mode.enter()
        XCTAssertTrue(mode.isActive)
        XCTAssertEqual(Array(recorder.events.prefix(3)), ["cancelBenchmark", "closeWindows", "policy accessory"])
        let released = await recorder.eventually { recorder.events.contains("releaseMemory") }
        XCTAssertTrue(released)
        XCTAssertTrue(recorder.events.contains("flushMetrics"))
        XCTAssertFalse(recorder.events.contains { $0.localizedCaseInsensitiveContains("fan") })
        mode.enter()
        XCTAssertEqual(recorder.events.filter { $0 == "closeWindows" }.count, 1, "entering twice does nothing more")
        mode.leave()
        XCTAssertFalse(mode.isActive)
        XCTAssertEqual(Array(recorder.events.suffix(3)), ["policy regular", "openMainWindow", "activate"])
    }

    func testMemoryIsReleasedOnceTheAppIsIdle() async {
        let recorder = Recorder()
        recorder.releaseSucceeds = false
        let mode = MenuBarOnlyMode(dependencies: recorder.dependencies)
        mode.enter()
        let waited = await recorder.eventually { recorder.events.contains("waitUntilIdle") }
        XCTAssertTrue(waited, "busy work keeps the data")
        recorder.releaseSucceeds = true
        let released = await recorder.eventually { recorder.events.filter { $0 == "releaseMemory" }.count >= 2 }
        XCTAssertTrue(released, "released after the work finished")
    }

    // MARK: D259 what is released

    func testReleasingDropsTheMainWindowsDataOnlyWhenNothingRuns() async throws {
        let store = try ScanStore.makeForTests(for: self)
        store.installedApps = [Self.installedApp]
        store.hasScannedInstalledApps = true
        store.hasScannedStartupItems = true
        let lease = try await store.heavyWorkCoordinator.acquire(owner: .cleanup)
        await store.heavyWorkActivityStore.refresh()
        XCTAssertFalse(store.releaseMainWindowData(privacy: nil), "a cleanup is running")
        XCTAssertEqual(store.installedApps.count, 1)
        await store.heavyWorkCoordinator.release(lease)
        await store.heavyWorkActivityStore.refresh()
        XCTAssertTrue(store.releaseMainWindowData(privacy: nil))
        XCTAssertTrue(store.installedApps.isEmpty)
        XCTAssertFalse(store.hasScannedInstalledApps)
        XCTAssertFalse(store.hasScannedStartupItems)
        XCTAssertNil(store.result)
        XCTAssertNil(store.cleanupScanSession)
    }

    // MARK: Sources

    private func source(_ path: String) throws -> String {
        try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheMainWindowNoLongerCarriesTheLaunchWork() throws {
        let raw = try source("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift")
        let app = SwiftSourceScanning.code(raw)
        let window = try MiniWindowLogicFixtures.section(raw, from: "WindowGroup(\"\", id: \"main\"", to: "} defaultValue: {")
        let work = try MiniWindowLogicFixtures.section(raw, from: "struct AppLaunchWork {", to: "\n}\n")
        for moved in ["menuBarStatusController.install(", "prepareBenchmarkForTermination",
                      "AppLifecycleReminderCenter.shared.start(", "store.reconcileInterruptedOperationsOnLaunch()",
                      "store.startSystemEnergyMonitoring()"] {
            XCTAssertFalse(window.contains(moved), "the main window: \(moved)")
            XCTAssertTrue(work.contains(moved), "the launch work: \(moved)")
        }
        XCTAssertTrue(app.contains("AppLaunchCoordinator.shared.prepare"))
        XCTAssertTrue(window.contains("AppLaunchCoordinator.shared.start(delegate: nil)"), "the window is the fallback")
        let delegate = SwiftSourceScanning.code(try r2SourceDeclaration(
            "func applicationDidFinishLaunching(_ notification: Notification)", in: try source(
                "Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift")))
        XCTAssertTrue(delegate.contains("AppLaunchCoordinator.shared.start(delegate: self)"))
    }

    func testThePanelOffersQuitCompletelyAndOpenMainProgram() throws {
        let chrome = try source("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift")
        XCTAssertTrue(chrome.contains("AppQuitIntent.shared.requestFinalTermination()"))
        XCTAssertTrue(chrome.contains("L10n.text(\"完全退出\", \"Quit Completely\")"))
        XCTAssertTrue(chrome.contains("L10n.text(\"打开主程序\", \"Open Main Program\")"))
    }

    /// D257 supplement (install24, 10-28): with the panel open across a quit
    /// of the main program, its overview context menu kept "Open Main Window".
    func testThePanelsContextMenuIsRebuiltWhenTheModeChanges() throws {
        let overview = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        XCTAssertTrue(overview.contains(".modifier(MenuBarOnlyAwareContextMenu { overviewContextMenu })"))
        XCTAssertFalse(overview.contains(".contextMenu { overviewContextMenu }"))
        let mode = SwiftSourceScanning.code(try source("Sources/StorageCleanerMac/App/MenuBarOnlyMode.swift"))
        let modifier = try MiniWindowLogicFixtures.section(
            mode, from: "struct MenuBarOnlyAwareContextMenu<MenuItems: View>: ViewModifier {", to: "\n}\n")
        XCTAssertTrue(modifier.contains("@ObservedObject private var menuBarOnly = MenuBarOnlyMode.shared"))
        XCTAssertTrue(modifier.contains("content.contextMenu { menuItems() }"))
    }

    func testOtherFinalQuitsAreMarkedBeforeTheyTerminate() throws {
        let manager = SwiftSourceScanning.code(try source(
            "Sources/StorageCleanerMac/Features/AppLifecycle/Uninstaller/ApplicationsManagerModel.swift"))
        XCTAssertTrue(manager.contains("AppQuitIntent.shared.markFinal()\n                NSApp.terminate(nil)")
            || manager.contains("AppQuitIntent.shared.markFinal(); NSApp.terminate(nil)"),
                      "uninstalling this app quits completely")
        let updater = SwiftSourceScanning.code(try source("Sources/StorageCleanerMac/Services/AppUpdater.swift"))
        XCTAssertTrue(updater.contains("var isInstallingUpdate: Bool { installLease != nil }"))
    }

    func testTheSettingIsInLaunchBehavior() throws {
        let general = try source("Sources/StorageCleanerMac/Views/Settings/SettingsGeneral.swift")
        XCTAssertTrue(general.contains("KeepMenuBarPanelAfterQuitToggle()"))
        XCTAssertTrue(general.contains("L10n.text(\"退出主程序后保留菜单栏小窗\", \"Keep the Menu Bar Panel After Quitting\")"))
    }

    // MARK: Fixtures

    private static let installedApp = InstalledAppItem(
        id: "/Applications/Fixture.app", name: "Fixture", bundleIdentifier: "com.example.fixture",
        path: "/Applications/Fixture.app", version: "1", build: "1", category: "", appDescription: "",
        sizeBytes: 1_000, source: "", modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)

    private static func code(_ text: String) -> OSType {
        text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    private static func quitEvent(reason: String?, sender: pid_t? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: code("aevt"), eventID: code("quit"), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            event.setAttribute(NSAppleEventDescriptor(enumCode: code(reason)), forKeyword: code("why?"))
        }
        if let sender {
            event.setAttribute(NSAppleEventDescriptor(int32: sender), forKeyword: code("spid"))
        }
        return event
    }

    private static func openEvent(loginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: code("aevt"), eventID: code("oapp"), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if loginItem {
            event.setParam(NSAppleEventDescriptor(enumCode: code("lgit")), forKeyword: code("prdt"))
        }
        return event
    }
}

@MainActor
private final class Recorder {
    var events: [String] = []
    var releaseSucceeds = true

    var dependencies: MenuBarOnlyMode.Dependencies {
        MenuBarOnlyMode.Dependencies(
            cancelBenchmark: { [unowned self] in events.append("cancelBenchmark") },
            closeWindows: { [unowned self] in events.append("closeWindows") },
            setActivationPolicy: { [unowned self] in events.append($0 == .accessory ? "policy accessory" : "policy regular") },
            flushMetrics: { [unowned self] in events.append("flushMetrics") },
            releaseMemory: { [unowned self] in events.append("releaseMemory"); return releaseSucceeds },
            waitUntilIdle: { [unowned self] in events.append("waitUntilIdle"); try? await Task.sleep(for: .milliseconds(20)) },
            openMainWindow: { [unowned self] in events.append("openMainWindow") },
            activate: { [unowned self] in events.append("activate") },
            isPanelShown: { false })
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
