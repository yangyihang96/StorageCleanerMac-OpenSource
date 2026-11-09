import AppKit
import XCTest
@testable import StorageCleanerMac

/// D256 (10-28): the app delegate's side of "quitting keeps the menu-bar
/// panel". The quit decision and the panel state are injected, so no alert or
/// window appears; the class creates AppDelegate and therefore runs with the
/// display-bound classes (D106).
@MainActor
final class MenuBarOnlyQuitDelegateD256Tests: XCTestCase {
    func testAUserQuitThatKeepsThePanelCancelsAndRunsNoTerminationWork() {
        let delegate = AppDelegate()
        var entered = 0, prepared = 0
        delegate.quitDecision = { .keepMenuBarPanel }
        delegate.enterMenuBarOnly = { entered += 1 }
        delegate.prepareFanControlForTermination = { prepared += 1 }
        delegate.prepareBenchmarkForTermination = { prepared += 1 }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(entered, 1)
        XCTAssertEqual(prepared, 0, "fan control and the rest keep running for the panel")
    }

    func testATerminatingDecisionKeepsTheUsualTermination() {
        let delegate = AppDelegate()
        var entered = 0
        delegate.quitDecision = { .terminate }
        delegate.enterMenuBarOnly = { entered += 1 }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow,
                       "no termination work was installed")
        XCTAssertEqual(entered, 0)
    }

    func testTheDefaultDecisionTerminatesWithoutAPanelInTheMenuBar() {
        // The launch work configures the mode only after installing a status
        // item; the test host runs no launch work, so quitting ends the process.
        XCTAssertFalse(MenuBarOnlyMode.shared.isConfigured)
        XCTAssertEqual(AppDelegate().quitDecision(), .terminate)
    }

    func testTheLaunchWorkReceivesTheDelegateThatStartedIt() {
        let coordinator = AppLaunchCoordinator()
        let delegate = AppDelegate()
        var received: [AppDelegate?] = []
        coordinator.prepare { received.append($0) }
        coordinator.start(delegate: delegate)
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(received.first.flatMap { $0 } === delegate, "the termination work is installed on it")
        let fallback = AppLaunchCoordinator()
        fallback.register(delegate: delegate)
        var fromWindow: [AppDelegate?] = []
        fallback.prepare { fromWindow.append($0) }
        fallback.start(delegate: nil)
        XCTAssertTrue(fromWindow.first.flatMap { $0 } === delegate, "a window that comes first uses the registered one")
    }
}
