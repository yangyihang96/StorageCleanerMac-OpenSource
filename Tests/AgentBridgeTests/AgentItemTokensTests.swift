import AgentGatewayCore
import AgentShared
import Foundation
import XCTest

/// D266: an AI refers to an item by a token, never by the App's own ID. Those
/// IDs are often paths (`InstalledAppItem`, `StorageItem`), or hold one
/// (`launchd:/Users/…/x.plist`, `com.foo|/Applications/Foo.app`).
final class AgentItemTokensTests: XCTestCase {
    private let path = "/Users/fixture/Applications/Foo.app"

    func testTheSameItemKeepsItsTokenAndTheTokenLeadsBack() throws {
        let tokens = AgentItemTokens()
        let token = tokens.token(for: path, module: "installed_apps")
        XCTAssertEqual(tokens.token(for: path, module: "installed_apps"), token, "Paging twice shows the same item the same way")
        XCTAssertEqual(tokens.internalID(for: token, module: "installed_apps"), path)
        XCTAssertTrue(token.hasPrefix("installed_apps-"))
        XCTAssertLessThanOrEqual(token.count, 60)
        XCTAssertFalse(token.contains("/"), "No path, no user name")
        XCTAssertFalse(token.contains("fixture"))
    }

    func testAnythingNotHandedOutLeadsNowhere() {
        let tokens = AgentItemTokens()
        let token = tokens.token(for: path, module: "installed_apps")
        XCTAssertNil(tokens.internalID(for: path, module: "installed_apps"), "D266: an arbitrary path is never accepted")
        XCTAssertNil(tokens.internalID(for: "~/Applications/Foo.app", module: "installed_apps"))
        XCTAssertNil(tokens.internalID(for: "installed_apps-00000000000000000000", module: "installed_apps"))
        XCTAssertNil(tokens.internalID(for: token, module: "junk"), "A token belongs to its module")
        XCTAssertNotEqual(tokens.token(for: path, module: "junk"), token)
    }

    func testTokensCannotBeWorkedOutFromTheItem() {
        XCTAssertNotEqual(AgentItemTokens().token(for: path, module: "junk"), AgentItemTokens().token(for: path, module: "junk"),
                          "A secret of this run: another process cannot compute a valid token")
    }

    func testNewResultsRetireOldTokensAndMemoryStaysBounded() {
        let tokens = AgentItemTokens(maximumPerModule: 3)
        let first = tokens.token(for: "a", module: "junk")
        let other = tokens.token(for: "a", module: "startup_items")
        tokens.forget(module: "junk")
        XCTAssertNil(tokens.internalID(for: first, module: "junk"), "A rescan: old numbers read as unknown items")
        XCTAssertEqual(tokens.internalID(for: other, module: "startup_items"), "a")

        for name in ["a", "b", "c"] { _ = tokens.token(for: name, module: "junk") }
        let last = tokens.token(for: "d", module: "junk")
        XCTAssertEqual(tokens.internalID(for: last, module: "junk"), "d")
        XCTAssertNil(tokens.internalID(for: tokens.tokenWithoutRemembering(for: "a", module: "junk"), module: "junk"),
                     "Past the limit the module starts over; an old token reads as unknown")
    }

    func testTheGuardRefusesAnIDThatIsAPath() {
        let check = AgentResultGuard(home: "/Users/fixture")
        for leak in ["/Users/fixture/Applications/x.app", "launchd:/Library/LaunchDaemons/x.plist", "com.foo|/Applications/Foo.app"] {
            XCTAssertThrowsError(try check.cleaned(["items": [["id": .string(leak)]]]), leak) {
                XCTAssertEqual(($0 as? AgentResultViolation)?.path, "items[0].id")
            }
            XCTAssertThrowsError(try check.cleaned(["item_id": .string(leak)]), leak)
        }
        XCTAssertNoThrow(try check.cleaned(["id": "junk-0a1b2c", "bundle_id": "com.apple.Terminal", "path": "/Applications/x.app",
                                            "request_id": "Q-1234ABCD"]))
    }
}
