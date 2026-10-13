import AppKit
import XCTest
@testable import StorageCleanerMac

@MainActor final class WindowCloseGuardTests: XCTestCase {
    private final class ExistingDelegate: NSObject, NSWindowDelegate {
        var calls = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { calls += 1; return true }
    }
    func testUnsavedDraftVetoPreservesDelegateAndDoesNotCommit() {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let original = ExistingDelegate()
        window.delegate = original
        let guardDelegate = WindowCloseGuard.Coordinator()
        var draft = GeekDashboardDraft(.defaultValue)
        draft.value.setModule(.disk, isVisible: false)
        guardDelegate.shouldClose = { _ in !draft.isDirty }
        guardDelegate.attach(to: window)
        XCTAssertFalse(guardDelegate.windowShouldClose(window))
        XCTAssertEqual(original.calls, 0)
        XCTAssertTrue(draft.isDirty)
        draft.cancel()
        XCTAssertTrue(guardDelegate.windowShouldClose(window))
        XCTAssertEqual(original.calls, 1)
        guardDelegate.detach()
        XCTAssertTrue(window.delegate === original)
        window.close()
    }
}
