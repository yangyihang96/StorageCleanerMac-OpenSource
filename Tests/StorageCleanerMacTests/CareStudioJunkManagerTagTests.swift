#if DEBUG
import XCTest
@testable import StorageCleanerMac

/// Report §4 item 18 (CleanMyMac's Cleanup Manager, `1比1对照-20261023/cmm/16`):
/// a subgroup carries a pink tag with the size selected in it, none when
/// nothing is, instead of a tick; the groups carry no tick.
@MainActor
final class CareStudioJunkManagerTagTests: XCTestCase {
    func testTheSubgroupTagShowsWhatIsSelectedInIt() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let session = try XCTUnwrap(store.cleanupScanSession)
        let subgroups = CareJunkGrouping.summaries(for: session, filter: .overview).flatMap(\.subgroups)
        let subgroup = try XCTUnwrap(subgroups.first { $0.candidates.count > 1 }, "a subgroup with two items")
        let first = subgroup.candidates[0], second = subgroup.candidates[1]

        XCTAssertEqual(CareStudioJunkManager.selectedBytes(in: subgroup, selected: []), 0, "nothing selected, no tag")
        XCTAssertEqual(CareStudioJunkManager.selectedBytes(in: subgroup, selected: [first.id]), first.estimatedSizeBytes,
                       "part of the subgroup: the part selected")
        XCTAssertEqual(CareStudioJunkManager.selectedBytes(in: subgroup, selected: [first.id, second.id]),
                       CleanupByteCount.sum([first.estimatedSizeBytes, second.estimatedSizeBytes]))
        let elsewhere = subgroups.flatMap(\.candidates).filter { !subgroup.candidates.map(\.id).contains($0.id) }.map(\.id)
        XCTAssertEqual(CareStudioJunkManager.selectedBytes(in: subgroup, selected: Set(elsewhere)), 0,
                       "items of other subgroups do not count")
    }

    func testTheRowsSayHowMuchIsSelected() {
        XCTAssertNotEqual(CareStudioJunkManager.selectionText(.checked), CareStudioJunkManager.selectionText(.unchecked))
        XCTAssertNotEqual(CareStudioJunkManager.selectionText(.mixed), CareStudioJunkManager.selectionText(.checked))
    }
}
#endif
