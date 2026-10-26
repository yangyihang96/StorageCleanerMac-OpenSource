import XCTest
@testable import StorageCleanerMac

/// Report §4 item 20 (CleanMyMac's My Tools, `1比1对照-20261023/cmm/09`):
/// this version's tools wear "New" and come first until they are opened
/// from My Tools, My Tools in the sidebar wears it while one is untried, the
/// cards go three a row, and they carry no title until a tool is saved.
final class MyToolsCatalogTests: XCTestCase {
    private let newTools = ["maintenance", "extensions", "chatFiles"]

    func testThisVersionsToolsAreNewAndComeFirst() {
        XCTAssertEqual(MyToolsCatalog.tools.filter(\.isNew).map(\.id), newTools, "D160–D162, in the catalog's order")
        let ordered = MyToolsCatalog.ordered(tried: []).map(\.id)
        XCTAssertEqual(Array(ordered.prefix(3)), newTools)
        XCTAssertEqual(Array(ordered.dropFirst(3)), MyToolsCatalog.tools.map(\.id).filter { !newTools.contains($0) })
    }

    func testANewToolLosesItsTagOnceOpenedAndGoesBackToItsPlace() throws {
        let maintenance = try XCTUnwrap(MyToolsCatalog.tools.first { $0.id == "maintenance" })
        XCTAssertTrue(MyToolsCatalog.showsNewTag(maintenance, tried: []))
        XCTAssertFalse(MyToolsCatalog.showsNewTag(maintenance, tried: ["maintenance"]))
        let ordered = MyToolsCatalog.ordered(tried: ["maintenance"]).map(\.id)
        XCTAssertEqual(Array(ordered.prefix(2)), ["extensions", "chatFiles"])
        XCTAssertEqual(Array(ordered.dropFirst(2)),
                       MyToolsCatalog.tools.map(\.id).filter { !["extensions", "chatFiles"].contains($0) },
                       "back among the others, in the catalog's order")
        for tool in MyToolsCatalog.tools where !tool.isNew {
            XCTAssertFalse(MyToolsCatalog.showsNewTag(tool, tried: []), tool.id)
        }
    }

    func testTheSidebarWearsNewWhileANewToolIsUntried() {
        XCTAssertTrue(MyToolsCatalog.hasUntriedNewTool(tried: []))
        XCTAssertTrue(MyToolsCatalog.hasUntriedNewTool(tried: ["maintenance", "extensions", "benchmark"]))
        XCTAssertFalse(MyToolsCatalog.hasUntriedNewTool(tried: Set(newTools)))
    }

    func testTheCardsGoThreeARow() {
        let tools = MyToolsCatalog.tools
        let rows = MyToolsCatalog.rows(of: tools)
        XCTAssertEqual(MyToolsCatalog.columns, 3)
        XCTAssertTrue(rows.dropLast().allSatisfy { $0.count == 3 })
        XCTAssertEqual(rows.last?.count, tools.count % 3 == 0 ? 3 : tools.count % 3)
        XCTAssertEqual(rows.flatMap { $0 }.map(\.id), tools.map(\.id))
        XCTAssertTrue(MyToolsCatalog.rows(of: []).isEmpty)
    }

    func testTheCardsHaveNoTitleUntilAToolIsSaved() {
        let tools = MyToolsCatalog.ordered(tried: [])
        let unsaved = MyToolsCatalog.sections(tools, favorites: [])
        XCTAssertEqual(unsaved.count, 1)
        XCTAssertNil(unsaved[0].title, "CleanMyMac has no All Tools title")
        XCTAssertEqual(unsaved[0].tools.map(\.id), tools.map(\.id))

        let saved = MyToolsCatalog.sections(tools, favorites: ["benchmark"])
        XCTAssertEqual(saved.map(\.title), [L10n.text("收藏", "Favorites"), L10n.text("其他工具", "Other Tools")])
        XCTAssertEqual(saved[0].tools.map(\.id), ["benchmark"])
        XCTAssertEqual(saved[1].tools.count, tools.count - 1)

        let all = MyToolsCatalog.sections(tools, favorites: Set(tools.map(\.id)))
        XCTAssertEqual(all.map(\.title), [L10n.text("收藏", "Favorites")], "no empty Other Tools")
    }

    func testTheSavedAndTriedIdsRoundTrip() {
        XCTAssertEqual(MyToolsCatalog.encode(["b", "a"]), "a,b")
        XCTAssertEqual(MyToolsCatalog.ids(from: "a,b,"), ["a", "b"])
        XCTAssertTrue(MyToolsCatalog.ids(from: "").isEmpty)
        XCTAssertNotEqual(MyToolsCatalog.triedDefaultsKey, MyToolsCatalog.favoritesDefaultsKey)
    }
}
