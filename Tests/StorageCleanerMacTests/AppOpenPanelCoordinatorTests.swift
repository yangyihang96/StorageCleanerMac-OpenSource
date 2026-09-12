import AppKit
import XCTest
@testable import StorageCleanerMac

@MainActor
final class AppOpenPanelCoordinatorTests: XCTestCase {
    func testRejectsDuplicatePresentationUntilCompletion() throws {
        try requireUnlockedGUISession()
        var completions: [AppOpenPanelCoordinator.Completion] = []
        var presentationCount = 0
        let coordinator = AppOpenPanelCoordinator { _, _, completion in
            presentationCount += 1
            completions.append(completion)
            return nil
        }

        XCTAssertTrue(coordinator.present(NSOpenPanel(), attachedTo: nil) { _ in })
        XCTAssertFalse(coordinator.present(NSOpenPanel(), attachedTo: nil) { _ in })
        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertEqual(presentationCount, 1)

        completions[0](.cancel)

        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertTrue(coordinator.present(NSOpenPanel(), attachedTo: nil) { _ in })
        XCTAssertEqual(presentationCount, 2)
    }

    func testStaleCompletionCannotDismissNewPresentation() throws {
        try requireUnlockedGUISession()
        var completions: [AppOpenPanelCoordinator.Completion] = []
        let coordinator = AppOpenPanelCoordinator { _, _, completion in
            completions.append(completion)
            return nil
        }

        XCTAssertTrue(coordinator.present(NSOpenPanel(), attachedTo: nil) { _ in })
        completions[0](.OK)
        XCTAssertTrue(coordinator.present(NSOpenPanel(), attachedTo: nil) { _ in })

        completions[0](.cancel)
        XCTAssertTrue(coordinator.isPresenting)

        completions[1](.cancel)
        XCTAssertFalse(coordinator.isPresenting)
    }

    func testCancelClearsInFlightGate() throws {
        try requireUnlockedGUISession()
        let coordinator = AppOpenPanelCoordinator { _, _, _ in nil }

        XCTAssertTrue(coordinator.present(NSOpenPanel(), attachedTo: nil) { _ in })
        coordinator.cancel()

        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertTrue(coordinator.present(NSOpenPanel(), attachedTo: nil) { _ in })
    }

    func testPreferredHostUsesKeyWindowThenMainWindow() {
        let keyWindow = NSWindow()
        let mainWindow = NSWindow()

        XCTAssertTrue(
            AppOpenPanelCoordinator.preferredHostWindow(
                keyWindow: keyWindow,
                mainWindow: mainWindow
            ) === keyWindow
        )
        XCTAssertTrue(
            AppOpenPanelCoordinator.preferredHostWindow(
                keyWindow: nil,
                mainWindow: mainWindow
            ) === mainWindow
        )
    }

    private func requireUnlockedGUISession() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipIf(
            session?["CGSSessionScreenIsLocked"] as? Bool == true,
            "NSOpenPanel cannot initialize while the GUI session is locked"
        )
    }
}
