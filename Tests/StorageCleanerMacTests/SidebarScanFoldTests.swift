import XCTest
@testable import StorageCleanerMac

/// D176 (the user's choice A, CleanMyMac 1:1): the first scan of a launch
/// folds the sidebar to icons on every page and keeps it so; the user's own
/// toggle wins for the rest of the run; nothing is kept across launches.
@MainActor
final class SidebarScanFoldTests: XCTestCase {
    func testTheFirstScanFoldsTheSidebarUntilTheUserChooses() {
        var state = SidebarPresentationState()
        state.update(windowWidth: 1_280)
        XCTAssertEqual(state.effective, .full, "before the first scan the sidebar is full")
        state.scanStarted()
        XCTAssertEqual(state.effective, .rail, "the first scan folds it")
        state.update(windowWidth: 1_400)
        XCTAssertEqual(state.effective, .rail, "it stays folded on a wide window")
        state.toggle()
        XCTAssertEqual(state.effective, .full, "the user expands it")
        state.scanStarted()
        XCTAssertEqual(state.effective, .full, "a later scan does not fold it again")
        state.update(windowWidth: 900)
        XCTAssertEqual(state.effective, .rail, "a narrow window still folds it")
        state.update(windowWidth: 1_280)
        XCTAssertEqual(state.effective, .full)
        XCTAssertEqual(SidebarPresentationState().effective, .full, "a new launch starts full")
    }

    func testAUserWhoChoseBeforeTheFirstScanKeepsTheirChoice() {
        var state = SidebarPresentationState()
        state.update(windowWidth: 1_280)
        state.toggle()
        state.toggle()
        state.scanStarted()
        XCTAssertEqual(state.effective, .full, "expanded by hand before the scan")
    }

    func testTheCanvasRemembersTheFirstWorkingPageForTheLaunch() {
        let canvas = CareStudioCanvas()
        let landing = UUID(), scanning = UUID()
        canvas.claim(landing, animating: false)
        XCTAssertFalse(canvas.hasWorked, "a landing page is not a scan")
        canvas.claim(scanning, animating: true)
        XCTAssertTrue(canvas.hasWorked)
        canvas.release(scanning)
        XCTAssertFalse(canvas.isAnimating)
        XCTAssertTrue(canvas.hasWorked, "the rest of the launch keeps it")
        canvas.release(landing)
        XCTAssertTrue(canvas.hasWorked)
    }
}
