import Foundation
import XCTest
@testable import StorageCleanerMac

/// D248: the main window's focused command values compare equal while they
/// would act the same. Made of closures, they were new on every body
/// evaluation of ContentView and SwiftUI could not compare them, so every
/// redraw was an update of the focused value; several redraws in one frame
/// logged "FocusedValue update tried to update multiple times per frame"
/// (install22 12:44:25.097 at launch; beta 10-25 11:36:04 in use).
@MainActor
final class FocusedCommandValuesD248Tests: XCTestCase {
    func testTheFocusedCommandValuesAreEquatable() {
        let sidebar: Any.Type = MainWindowSidebarAction.self
        let startupItems: Any.Type = StartupItemsKeyboardActions.self
        XCTAssertTrue(sidebar is any Equatable.Type)
        XCTAssertTrue(startupItems is any Equatable.Type)
    }

    /// One scope per window, kept in the window's state, so every body of the
    /// same window publishes an equal value.
    func testTheMainWindowPublishesThemUnderItsOwnScope() throws {
        let source = SwiftSourceScanning.compact(SwiftSourceScanning.code(try String(
            contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8)))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "@StateprivatevarcommandScope=MainWindowCommandScope()", in: source), 1)
        XCTAssertTrue(source.contains(".focusedSceneValue(\\.mainWindowSidebarAction,"
            + "MainWindowSidebarAction(scope:commandScope,reducesMotion:reduceMotion){toggleSidebarPresentation()})"))
        XCTAssertTrue(source.contains("returnStartupItemsKeyboardActions(scope:commandScope,refresh:"))
    }

    /// Equal for the same window whatever closures a body made; a new window,
    /// or Reduce Motion turned on, is a new value.
    func testTheValuesCompareByWindowAndWhatTheirClosuresRead() {
        let window = MainWindowCommandScope()
        let other = MainWindowCommandScope()
        var ran = 0
        XCTAssertNotEqual(window, other)
        XCTAssertEqual(MainWindowSidebarAction(scope: window, reducesMotion: false) { ran += 1 },
                       MainWindowSidebarAction(scope: window, reducesMotion: false) { ran += 2 })
        XCTAssertNotEqual(MainWindowSidebarAction(scope: window, reducesMotion: false) {},
                          MainWindowSidebarAction(scope: other, reducesMotion: false) {})
        XCTAssertNotEqual(MainWindowSidebarAction(scope: window, reducesMotion: false) {},
                          MainWindowSidebarAction(scope: window, reducesMotion: true) {})
        XCTAssertEqual(StartupItemsKeyboardActions(scope: window, refresh: { ran += 1 }, focusSearch: {}),
                       StartupItemsKeyboardActions(scope: window, refresh: {}, focusSearch: { ran += 1 }))
        XCTAssertNotEqual(StartupItemsKeyboardActions(scope: window, refresh: {}, focusSearch: {}),
                          StartupItemsKeyboardActions(scope: other, refresh: {}, focusSearch: {}))
        XCTAssertEqual(ran, 0, "comparing never runs an action")

        let action = MainWindowSidebarAction(scope: window, reducesMotion: false) { ran += 1 }
        action()
        XCTAssertEqual(ran, 1)
    }
}
