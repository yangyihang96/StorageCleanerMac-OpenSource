import Foundation
import XCTest
@testable import StorageCleanerMac

/// D-FP6（竞品对比 2026-10-20）：系统垃圾里的“损坏的偏好设置”。只列出
/// `~/Library/Preferences` 下直接放着、macOS 读不出的 `.plist`：空文件、不是属性列表、
/// 根不是字典。黄色、默认不选、逐个确认；读不了的文件不列出，太大的不读。
final class BrokenPreferencesRuleTests: XCTestCase {
    func testRuleIsYellowUnselectedAndInTheReviewedBaseline() throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rule = try XCTUnwrap(bundled.rules.first { $0.id == "system.broken-preferences" })
        XCTAssertEqual(rule.categoryID, "system")
        XCTAssertEqual(rule.root.path, "Library/Preferences")
        XCTAssertEqual(rule.include.entryKinds, [.regularFile])
        XCTAssertEqual(rule.include.extensions, ["plist"])
        XCTAssertEqual(rule.risk, .reviewOnly)
        XCTAssertEqual(rule.defaultSelection, .unselected)
        XCTAssertEqual(rule.action, .moveToTrashAfterReview)
        XCTAssertEqual(rule.contentRequirement, .unreadablePropertyList)
        let maintenance = try XCTUnwrap(rule.maintenance)
        XCTAssertNotNil(CleanupImpactText.englishByChinese[maintenance.impact])
        let baseline = try CleanupRuleTestFixtures.baseline()
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(bundled, baseline: baseline))
        let hash = try CleanupRuleFingerprint.contentHash(for: rule)
        let entry = try XCTUnwrap(baseline.entries.first { $0.ruleID == rule.id }, "baseline entry; content hash \(hash)")
        XCTAssertEqual(entry.revision, 1)
        XCTAssertEqual(entry.contentHash, hash)
        XCTAssertEqual(CareJunkGroup.group(categoryID: rule.categoryID, candidates: []), .systemJunk,
                       "放在“系统垃圾”里")
    }

    func testAContentRuleCannotBeAutomaticOrPreselected() throws {
        let rule = CleanupCoverageCatalog.brokenPreferencesRule
        for fields: [String: Any] in [["action": "moveToTrash"], ["defaultSelection": "selected"], ["risk": "safe"],
                                      ["include": ["entryKinds": ["regularFile", "directory"], "extensions": ["plist"],
                                                   "nameMatcher": ["mode": "any", "values": []]]]] {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: fields)
            XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([changed])), "\(fields)")
        }
    }

    func testBrokenMeansEmptyUnparsableOrNotADictionary() throws {
        XCTAssertTrue(BrokenPropertyListCheck.isBroken(Data()))
        XCTAssertTrue(BrokenPropertyListCheck.isBroken(Data("not a property list".utf8)))
        XCTAssertTrue(BrokenPropertyListCheck.isBroken(
            try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .binary, options: 0)))
        XCTAssertFalse(BrokenPropertyListCheck.isBroken(
            try PropertyListSerialization.data(fromPropertyList: ["Key": 1], format: .binary, options: 0)))
        XCTAssertFalse(BrokenPropertyListCheck.isBroken(
            try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)))
    }

    func testOnlyUnreadablePreferenceFilesAreListed() async throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "broken-preferences")
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        func write(_ name: String, _ data: Data) throws {
            let url = preferences.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try write("com.example.good.plist",
                  try PropertyListSerialization.data(fromPropertyList: ["Theme": "dark"], format: .binary, options: 0))
        try write("com.example.broken.plist", Data("bplist00 garbage that is cut off".utf8))
        try write("com.example.empty.plist", Data())
        try write("com.example.array.plist",
                  try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .xml, options: 0))
        try write("com.example.huge.plist", Data(repeating: 0x41, count: 9 * 1_024 * 1_024))
        try write("notes.txt", Data("garbage".utf8))
        try write("ByHost/com.example.byhost.plist", Data("garbage".utf8))
        try FileManager.default.createSymbolicLink(at: preferences.appendingPathComponent("com.example.link.plist"),
                                                   withDestinationURL: preferences.appendingPathComponent("com.example.broken.plist"))

        let session = try await CleanupRuleTestFixtures.scan(
            CleanupRuleTestFixtures.set([CleanupCoverageCatalog.brokenPreferencesRule]), home: home)
        let listed = session.candidates.filter { $0.ruleID == "system.broken-preferences" }
        XCTAssertEqual(Set(listed.map(\.sourceURL.lastPathComponent)),
                       ["com.example.broken.plist", "com.example.empty.plist", "com.example.array.plist"],
                       "Scan issues: \(session.issues)")
        for candidate in listed {
            XCTAssertFalse(candidate.isPreselectedByDefault, "默认不选")
            XCTAssertEqual(candidate.risk, .reviewOnly)
            XCTAssertFalse(candidate.action.permanentlyDeletes, "只移入废纸篓")
        }
    }
}
