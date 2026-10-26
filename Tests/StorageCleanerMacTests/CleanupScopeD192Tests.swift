import Foundation
import XCTest
@testable import StorageCleanerMac

final class CleanupScopeD192Tests: XCTestCase {
    func testAllFourScopesPartitionExactlySmartCareCleanupRules() throws {
        let rules = try CleanupRuleSetLoader.loadBundled().rules
        XCTAssertEqual(SafeCleanupScanScope.allCases, [.systemJunk, .aiClutter, .mailAttachments, .trashBins],
                       "D192＋旧值：caches / logs / temporaryFiles / downloadResidue，旧范围只取 32 条")
        XCTAssertEqual(SafeCleanupScanScope.defaultSelection, Set(SafeCleanupScanScope.allCases))
        let selected = rules.filter { rule in SafeCleanupScanScope.defaultSelection.contains { $0.includes(rule) } }
        let smartCare = rules.filter { rule in SmartCareModule.cleanupScopes.contains { $0.includes(rule) } }
        XCTAssertEqual(Set(selected.map(\.id)), Set(smartCare.map(\.id)))
        XCTAssertEqual(Set(selected.map(\.id)), Set(rules.map(\.id)))
        for rule in rules {
            XCTAssertEqual(SafeCleanupScanScope.allCases.filter { $0.includes(rule) }.count, 1, rule.id)
            let result = CareJunkGroup.group(for: rule)
            XCTAssertEqual(CareJunkGroup.group(ruleID: rule.id), result, rule.id)
            let candidate = RescanFixtureRows.candidate(rule.id, "/Fixture/\(rule.id)",
                                                       sessionID: ScanSessionID(), inode: 192, bytes: 1)
            XCTAssertEqual(CareJunkGroup.group(categoryID: rule.categoryID, candidates: [candidate]), result, rule.id)
        }
        for scope in SafeCleanupScanScope.allCases { XCTAssertTrue(rules.contains(where: scope.includes), scope.rawValue) }
    }

    func testSystemJunkIncludesDeveloperAndReviewRulesWhileAIStaysSeparate() throws {
        let rules = try CleanupRuleSetLoader.loadBundled().rules
        for rule in rules {
            let expected: SafeCleanupScanScope
            switch rule.categoryID {
            case "trash": expected = .trashBins
            case "mail": expected = .mailAttachments
            case "developer" where DeveloperTool.allCases.contains(where: { $0.isAITool && rule.id.contains($0.ruleKeyword) }):
                expected = .aiClutter
            default: expected = .systemJunk
            }
            XCTAssertTrue(expected.includes(rule), rule.id)
        }
        // D227＋旧值：the list also had "downloads.installers", retired with its rule.
        for id in ["system.broken-preferences", "system-cache.cloudkit",
                   "applications.duplicate-installed-apps", "developer.xcode-derived-data"] {
            let rule = try XCTUnwrap(rules.first { $0.id == id })
            XCTAssertTrue(SafeCleanupScanScope.systemJunk.includes(rule), "D192＋旧值：原范围遗漏 \(id)")
        }
        XCTAssertTrue(SafeCleanupScanScope.trashBins.includes(CleanupCoverageCatalog.iCloudDriveTrashRule))
    }

    func testScopePreferencesRoundTripIncludingExplicitlyEmptySelection() {
        let defaults = TestPreferenceDomain.make(for: self)
        XCTAssertEqual(SafeCleanupScanScope.selection(in: defaults), SafeCleanupScanScope.defaultSelection)
        for selection: Set<SafeCleanupScanScope> in [[], [.trashBins], [.systemJunk, .mailAttachments], Set(SafeCleanupScanScope.allCases)] {
            SafeCleanupScanScope.save(selection, in: defaults)
            XCTAssertEqual(SafeCleanupScanScope.selection(in: defaults), selection)
            XCTAssertEqual(defaults.stringArray(forKey: SafeCleanupScanScope.defaultsKey),
                           SafeCleanupScanScope.allCases.filter(selection.contains).map(\.rawValue))
        }
    }

    func testUnreadableOrUnknownScopePreferenceDefaultsToAllFour() {
        let defaults = TestPreferenceDomain.make(for: self)
        for invalid: Any in ["trashBins", 42, ["legacy"], ["trashBins", "legacy"], [1, 2]] {
            defaults.set(invalid, forKey: SafeCleanupScanScope.defaultsKey)
            XCTAssertEqual(SafeCleanupScanScope.selection(in: defaults), SafeCleanupScanScope.defaultSelection)
        }
    }
}
