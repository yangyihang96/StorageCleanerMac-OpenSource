import XCTest
@testable import StorageCleanerMac

/// D213: the managers' primary button (Remove Selected, Uninstall Selected,
/// Clean…) runs on one click (D205 附) but never on Return. On 10-25 a Return
/// press removed the leftovers and installers the Applications manager had
/// preselected. Back keeps Escape.
final class ManagerPrimaryReturnKeyD213Tests: XCTestCase {
    func testThePrimaryButtonHasNoReturnKeyAndBackKeepsEscape() throws {
        let source = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/CareStudio/CareStudioManagerChrome.swift"), encoding: .utf8)
        let primaryStart = try XCTUnwrap(source.range(of: "Button(action: onPrimary)"))
        let primaryEnd = try XCTUnwrap(source.range(of: "careStudio.manager.primary", range: primaryStart.upperBound..<source.endIndex))
        let primary = source[primaryStart.lowerBound..<primaryEnd.upperBound]
        XCTAssertFalse(primary.contains(".keyboardShortcut("), "the primary action starts only on a click")
        let backStart = try XCTUnwrap(source.range(of: "Button(action: onBack)"))
        let back = source[backStart.lowerBound..<primaryStart.lowerBound]
        XCTAssertTrue(back.contains(".keyboardShortcut(.cancelAction)"), "Back keeps Escape")
    }
}
