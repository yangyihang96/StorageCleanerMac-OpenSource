import AppKit
import XCTest
@testable import StorageCleanerMac

/// D270–D271 (10-28, the parent session's review of D255–D259, relayed with
/// the user's words "你发现的两处交给执行会话排进下一批，提交前修好"; D271 is
/// the user's choice "装好并重开到小窗"). The panel stays after a quit only
/// while its status item shows, and a silently downloaded update installs from
/// the menu-bar-only state and relaunches into it. After install25 showed that
/// `isVisible` stays true for an item System Settings hides, the user chose
/// "改判断依据" (10-29): an item shows once the system has placed it in a menu
/// bar. The frames below are the probe's (`review-fixes/d270-signal`, 10-29/30).
@MainActor
final class MenuBarOnlyModeD270D271Tests: XCTestCase {
    // MARK: D270 a status item that does not show

    func testAQuitWithoutAShownStatusItemEndsTheProcess() throws {
        XCTAssertEqual(AppQuitPolicy.decision(reason: .user, keepsMenuBarPanel: true, hasMenuBarPanel: false), .terminate)
        let decision = SwiftSourceScanning.code(try MiniWindowLogicFixtures.section(
            try source(Self.appPath), from: "var quitDecision:", to: "var enterMenuBarOnly:"))
        XCTAssertTrue(decision.contains("hasMenuBarPanel: MenuBarStatusController.shared.isShowingStatusItem"),
                      "the live visibility, not whether an item was ever installed")
        XCTAssertFalse(decision.contains("hasMenuBarPanel: true"))
    }

    func testALaunchWithThePanelAloneAndNoShownStatusItemOpensTheMainProgram() {
        let recorder = Recorder()
        let mode = MenuBarOnlyMode(dependencies: recorder.dependencies)
        mode.beginAtLaunch()
        mode.statusItemVisibilityChanged(isShowing: false)
        XCTAssertFalse(mode.isActive)
        XCTAssertEqual(recorder.events, ["policy regular", "openMainWindow", "activate"])
        XCTAssertFalse(mode.isLaunchWindowSuppressionPending, "the window SwiftUI opens next is shown")
        XCTAssertFalse(mode.takeLaunchWindowSuppression())
    }

    func testAStatusItemThatStopsShowingBringsBackTheMainProgram() {
        let recorder = Recorder()
        let mode = MenuBarOnlyMode(dependencies: recorder.dependencies)
        mode.statusItemVisibilityChanged(isShowing: false)
        XCTAssertTrue(recorder.events.isEmpty, "with the main program open nothing changes")
        mode.enter()
        mode.statusItemVisibilityChanged(isShowing: true)
        XCTAssertTrue(mode.isActive)
        mode.statusItemVisibilityChanged(isShowing: false)
        XCTAssertFalse(mode.isActive)
        XCTAssertEqual(Array(recorder.events.suffix(3)), ["policy regular", "openMainWindow", "activate"])
    }

    func testTheLaunchWorkReportsWhetherTheSystemPlacedTheStatusItemInTime() throws {
        let work = SwiftSourceScanning.code(try MiniWindowLogicFixtures.section(
            try source(Self.appPath), from: "struct AppLaunchWork {", to: "private func installTerminationWork("))
        let configure = try XCTUnwrap(work.range(of: "MenuBarOnlyMode.shared.configure("))
        let wait = try XCTUnwrap(work.range(of:
            "await menuBarStatusController.waitForStatusItemPlacement(timeout: MenuBarStatusItemPlacement.launchWait)"))
        let report = try XCTUnwrap(work.range(of:
            "MenuBarOnlyMode.shared.statusItemVisibilityChanged(isShowing: menuBarStatusController.isShowingStatusItem)"))
        XCTAssertLessThan(configure.lowerBound, wait.lowerBound, "reported once the item is installed")
        XCTAssertLessThan(wait.lowerBound, report.lowerBound, "after the system had time to place it")
        let controller = SwiftSourceScanning.code(try source(Self.controllerPath))
        XCTAssertTrue(controller.contains(
            "var isShowingStatusItem: Bool { statusItem?.isVisible == true && statusItemPlacement.measure() }"))
        XCTAssertFalse(controller.contains("var isShowingStatusItem: Bool { statusItem?.isVisible == true }"),
                       "isVisible alone stays true for an item System Settings hides")
        let observer = try MiniWindowLogicFixtures.section(
            controller, from: "statusVisibilityObservation = statusItem.observe(\\.isVisible", to: "samplingEnvironmentCancellable")
        XCTAssertTrue(observer.contains("MenuBarOnlyMode.shared.statusItemVisibilityChanged(isShowing: self.isShowingStatusItem)"))
        let install = try MiniWindowLogicFixtures.section(
            controller, from: "self.statusItem = statusItem", to: "statusVisibilityObservation =")
        XCTAssertTrue(install.contains("watchStatusItemPlacement(button)"), "measured from the moment it exists")
    }

    func testThePanelRestoredAtLaunchWaitsForThePlacedStatusItem() throws {
        let controller = SwiftSourceScanning.code(try source(Self.controllerPath))
        let restore = try MiniWindowLogicFixtures.section(controller, from: "if shouldOpenPanel {", to: "@objc")
        let wait = try XCTUnwrap(restore.range(of:
            "await self.waitForStatusItemPlacement(timeout: MenuBarStatusItemPlacement.launchWait)"))
        let present = try XCTUnwrap(restore.range(of: "self.presentPanel(from: button)"))
        XCTAssertLessThan(wait.lowerBound, present.lowerBound, "an item the system never places opens no panel")
        XCTAssertFalse(restore.contains("DispatchQueue.main.asyncAfter"), "not on a fixed delay alone")
    }

    // MARK: D270 where the system put the status item's button

    func testButtonFramesInAMenuBarCountAsPlaced() {
        for frame in [Self.button(759, 852),    // right of the notch
                      Self.button(318, 852),    // left of the notch
                      Self.button(749, 852),    // touching the notch
                      Self.button(0, 852),      // the built-in's left end, mid-animation
                      Self.button(759, 853),    // 3 pt below the top
                      Self.button(759, 823),    // mid-animation, 33 pt below the top
                      Self.button(796, 1932),   // the Mi Monitor
                      Self.button(-337, 1932),  // its left end, mid-animation
                      Self.button(3356, 1932)] { // 虚拟屏 3
            XCTAssertTrue(MenuBarStatusItemPlacement.isInMenuBar(buttonFrame: frame, screenFrames: Self.screens), "\(frame)")
        }
    }

    func testThePlaceholderAndTheFramesOnTheWayAreNotPlaced() {
        for frame in [Self.button(0, -11),      // never placed (not allowed): its center is on the built-in's bottom edge
                      Self.button(0, -26),      // below every screen
                      Self.button(0, 4),        // the built-in's bottom
                      Self.button(0, 882),      // the Mi Monitor's bottom
                      Self.button(1530, 1947),  // above the Mi Monitor's top
                      NSRect(x: 759, y: 852, width: 0, height: 22),
                      NSRect(x: CGFloat.nan, y: 852, width: 53, height: 22),
                      NSRect(x: 759, y: CGFloat.infinity, width: 53, height: 22)] {
            XCTAssertFalse(MenuBarStatusItemPlacement.isInMenuBar(buttonFrame: frame, screenFrames: Self.screens), "\(frame)")
        }
        XCTAssertFalse(MenuBarStatusItemPlacement.isInMenuBar(buttonFrame: Self.button(759, 852), screenFrames: []))
    }

    func testAPlacedItemStaysCountedWhileItMovesToAnotherDisplay() {
        let frames = FrameSequence([Self.button(0, -11), Self.button(0, -26), Self.button(759, 852), Self.button(1530, 1947)])
        let placement = MenuBarStatusItemPlacement(buttonFrame: { frames.next() }, screenFrames: { Self.screens })
        XCTAssertFalse(placement.measure(), "just created")
        XCTAssertFalse(placement.measure(), "on its way")
        XCTAssertTrue(placement.measure(), "placed in the built-in's menu bar")
        XCTAssertTrue(placement.measure(), "a frame on the way to another display does not undo it")
        XCTAssertTrue(placement.isPlaced)
        XCTAssertFalse(MenuBarStatusItemPlacement(buttonFrame: { nil }, screenFrames: { Self.screens }).measure(),
                       "no button")
    }

    func testTheLaunchWaitEndsWhenTheItemIsPlacedOrWhenTheTimeRunsOut() async {
        let frames = FrameSequence([Self.button(0, -11), Self.button(0, -11), Self.button(796, 1932)])
        let shown = MenuBarStatusItemPlacement(buttonFrame: { frames.next() }, screenFrames: { Self.screens })
        let clock = ContinuousClock()
        let started = clock.now
        let placed = await shown.wait(timeout: .seconds(5))
        XCTAssertTrue(placed)
        XCTAssertLessThan(clock.now - started, .seconds(2), "it answers as soon as the item is placed")

        let hidden = MenuBarStatusItemPlacement(buttonFrame: { Self.button(0, -11) }, screenFrames: { Self.screens })
        let hiddenStarted = clock.now
        let hiddenPlaced = await hidden.wait(timeout: .milliseconds(300))
        XCTAssertFalse(hiddenPlaced, "System Settings does not allow it, so it is never placed")
        XCTAssertGreaterThanOrEqual(clock.now - hiddenStarted, .milliseconds(300))
        XCTAssertFalse(hidden.isPlaced)
    }

    /// The built-in Retina display (with the notch), the Mi Monitor above it
    /// and 虚拟屏 3, as their NSScreen frames during the probe.
    private static let screens = [NSRect(x: 0, y: 0, width: 1352, height: 878),
                                  NSRect(x: -337, y: 878, width: 1920, height: 1080),
                                  NSRect(x: 1583, y: 518, width: 2560, height: 1440)]

    /// The probe's status item button: 53×22 pt.
    private static func button(_ x: CGFloat, _ y: CGFloat) -> NSRect {
        NSRect(x: x, y: y, width: 53, height: 22)
    }

    // MARK: D271 the held update

    func testAHeldUpdateInstallsOnceTheMainProgramIsClosedAndNothingRuns() async {
        let recorder = Recorder()
        let mode = MenuBarOnlyMode(dependencies: recorder.dependencies)
        var installs = 0
        mode.holdUpdateInstall { installs += 1 }
        XCTAssertTrue(mode.holdsUpdateInstall)
        XCTAssertEqual(installs, 0, "the main program is open")
        mode.enter()
        let installed = await recorder.eventually { installs == 1 }
        XCTAssertTrue(installed)
        XCTAssertFalse(mode.holdsUpdateInstall)
        let released = recorder.events.firstIndex(of: "releaseMemory")
        XCTAssertNotNil(released, "after the data is released")
    }

    func testAHeldUpdateWaitsForRunningWorkAndAnOpenPanel() async {
        let recorder = Recorder()
        recorder.releaseSucceeds = false
        recorder.panelShown = true
        let mode = MenuBarOnlyMode(dependencies: recorder.dependencies)
        var installs = 0
        mode.holdUpdateInstall { installs += 1 }
        mode.enter()
        let waited = await recorder.eventually { recorder.events.filter { $0 == "waitUntilIdle" }.count >= 2 }
        XCTAssertTrue(waited)
        XCTAssertEqual(installs, 0, "a cleanup is running")
        recorder.releaseSucceeds = true
        let waitedForPanel = await recorder.eventually { recorder.events.filter { $0 == "isPanelShown" }.count >= 2 }
        XCTAssertTrue(waitedForPanel)
        XCTAssertEqual(installs, 0, "the panel is open")
        recorder.panelShown = false
        let installed = await recorder.eventually { installs == 1 }
        XCTAssertTrue(installed)
    }

    func testAnUpdateReadyWhileOnlyThePanelRunsInstallsWithoutAnotherQuit() async {
        let recorder = Recorder()
        let mode = MenuBarOnlyMode(dependencies: recorder.dependencies)
        mode.enter()
        let released = await recorder.eventually { recorder.events.contains("releaseMemory") }
        XCTAssertTrue(released)
        var installs = 0
        mode.holdUpdateInstall { installs += 1 }
        let installed = await recorder.eventually { installs == 1 }
        XCTAssertTrue(installed)
    }

    func testOpeningTheMainProgramKeepsTheUpdateForTheNextQuit() async {
        let recorder = Recorder()
        recorder.panelShown = true
        let mode = MenuBarOnlyMode(dependencies: recorder.dependencies)
        var installs = 0
        mode.holdUpdateInstall { installs += 1 }
        mode.enter()
        _ = await recorder.eventually { recorder.events.contains("isPanelShown") }
        mode.leave()
        recorder.panelShown = false
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(installs, 0, "the main program is open again")
        XCTAssertTrue(mode.holdsUpdateInstall)
        mode.enter()
        let installed = await recorder.eventually { installs == 1 }
        XCTAssertTrue(installed)
    }

    func testTheRelaunchMarkStartsOnlyTheNextBuildWithThePanelAlone() {
        let defaults = TestPreferenceDomain.make(for: self)
        let marked = Date(timeIntervalSince1970: 1_800_000_000)
        MenuBarOnlyRelaunch.mark(fromBuild: "20261028075356", at: marked, defaults)
        XCTAssertTrue(MenuBarOnlyRelaunch.consume(currentBuild: "20261029010101",
                                                  now: marked.addingTimeInterval(40), defaults))
        XCTAssertFalse(MenuBarOnlyRelaunch.consume(currentBuild: "20261029010101",
                                                   now: marked.addingTimeInterval(41), defaults), "once")
        MenuBarOnlyRelaunch.mark(fromBuild: "20261028075356", at: marked, defaults)
        XCTAssertFalse(MenuBarOnlyRelaunch.consume(currentBuild: "20261028075356",
                                                   now: marked.addingTimeInterval(40), defaults),
                       "the install failed and the same build opened")
        XCTAssertNil(defaults.object(forKey: MenuBarOnlyRelaunch.key), "and the mark is gone")
        MenuBarOnlyRelaunch.mark(fromBuild: "20261028075356", at: marked, defaults)
        XCTAssertFalse(MenuBarOnlyRelaunch.consume(currentBuild: "20261029010101",
                                                   now: marked.addingTimeInterval(MenuBarOnlyRelaunch.validity + 1), defaults),
                       "a later launch of the new build opens normally")
        MenuBarOnlyRelaunch.mark(fromBuild: "20261028075356", at: marked, defaults)
        MenuBarOnlyRelaunch.clear(defaults)
        XCTAssertFalse(MenuBarOnlyRelaunch.consume(currentBuild: "20261029010101",
                                                   now: marked.addingTimeInterval(40), defaults))
    }

    func testTheUpdaterHoldsTheSilentInstallOnlyWhileThePanelIsKept() throws {
        let updater = SwiftSourceScanning.code(try source("Sources/StorageCleanerMac/Services/AppUpdater.swift"))
        let hold = try r2SourceDeclaration("willInstallUpdateOnQuit item: SUAppcastItem", in: updater)
        XCTAssertTrue(hold.contains("guard MenuBarOnlyMode.shared.isConfigured, AppQuitPreferences.keepsMenuBarPanelAfterQuit() else {"))
        XCTAssertTrue(hold.contains("return false"), "without the panel Sparkle installs at exit")
        let mark = try XCTUnwrap(hold.range(of: "MenuBarOnlyRelaunch.mark(fromBuild: build)"))
        let install = try XCTUnwrap(hold.range(of: "immediateInstallHandler()"))
        XCTAssertLessThan(mark.lowerBound, install.lowerBound, "the mark is written before the relaunch")
        XCTAssertTrue(hold.contains("MenuBarOnlyMode.shared.holdUpdateInstall {"))
        XCTAssertTrue(hold.contains("return true"))
        let cycle = try r2SourceDeclaration("didFinishUpdateCycleFor updateCheck: SPUUpdateCheck", in: updater)
        XCTAssertTrue(cycle.contains("if error != nil { MenuBarOnlyRelaunch.clear() }"))
        let launch = SwiftSourceScanning.code(try r2SourceDeclaration(
            "func applicationWillFinishLaunching(_ notification: Notification)", in: try source(Self.appPath)))
        XCTAssertTrue(launch.contains("MenuBarOnlyRelaunch.consume("))
        XCTAssertTrue(launch.contains("isLoginLaunch || isRelaunchAfterUpdate || MenuBarOnlyMode.isLoginLaunchRehearsalRequested"))
    }

    // MARK: Sources

    private static let appPath = "Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"
    private static let controllerPath = "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"

    private func source(_ path: String) throws -> String {
        try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(path), encoding: .utf8)
    }
}

/// The button frames a status item reports one measurement after another; the
/// last one repeats.
@MainActor
private final class FrameSequence {
    private var frames: [NSRect]

    init(_ frames: [NSRect]) { self.frames = frames }

    func next() -> NSRect? {
        frames.count > 1 ? frames.removeFirst() : frames.first
    }
}

/// Weakly held: a cancelled release task can still run its first step after
/// a synchronous test has returned.
@MainActor
private final class Recorder {
    var events: [String] = []
    var releaseSucceeds = true
    var panelShown = false

    var dependencies: MenuBarOnlyMode.Dependencies {
        MenuBarOnlyMode.Dependencies(
            cancelBenchmark: { [weak self] in self?.events.append("cancelBenchmark") },
            closeWindows: { [weak self] in self?.events.append("closeWindows") },
            setActivationPolicy: { [weak self] in self?.events.append($0 == .accessory ? "policy accessory" : "policy regular") },
            flushMetrics: { [weak self] in self?.events.append("flushMetrics") },
            releaseMemory: { [weak self] in
                self?.events.append("releaseMemory")
                return self?.releaseSucceeds ?? false
            },
            waitUntilIdle: { [weak self] in
                self?.events.append("waitUntilIdle")
                try? await Task.sleep(for: .milliseconds(20))
            },
            openMainWindow: { [weak self] in self?.events.append("openMainWindow") },
            activate: { [weak self] in self?.events.append("activate") },
            isPanelShown: { [weak self] in
                self?.events.append("isPanelShown")
                return self?.panelShown ?? true
            })
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
