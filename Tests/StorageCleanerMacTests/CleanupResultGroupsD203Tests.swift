import XCTest
@testable import StorageCleanerMac

/// D203 (decided by the user on 10-24, relayed by the 2.0.1 session): the
/// junk results show six groups again — System Junk, Developer Junk, AI
/// Clutter, Mail Attachments, Trash, Files to Review — while the landing
/// keeps D192's four switches, System Junk scanning the developer and
/// to-review rules too. The switches' rules, key and storage are unchanged.
final class CleanupResultGroupsD203Tests: XCTestCase {
    func testResultsSplitTheSystemJunkSwitchIntoThreeGroups() throws {
        let rules = try CleanupRuleSetLoader.loadBundled().rules
        var groups = Set<CareJunkGroup>()
        for rule in rules {
            let group = CareJunkGroup.group(for: rule)
            groups.insert(group)
            let expected: CareJunkGroup
            switch rule.categoryID {
            case "trash": expected = .trashBins
            case "mail": expected = .mailAttachments
            case "downloads", "applications", "user-data": expected = .filesToReview
            case "developer" where DeveloperTool.allCases.contains(where: { $0.isAITool && rule.id.contains($0.ruleKeyword) }):
                expected = .aiClutter
            case "developer": expected = .developerJunk
            default: expected = .systemJunk
            }
            XCTAssertEqual(group, expected, rule.id)
            // A switch takes in whole groups: the rule's switch is its group's.
            XCTAssertEqual(SafeCleanupScanScope.allCases.filter { $0.includes(rule) }, [group.scanScope], rule.id)
        }
        XCTAssertEqual(groups, Set(CareJunkGroup.allCases), "the bundled rules fill all six groups")
    }

    func testTheSwitchesStayFour() {
        XCTAssertEqual(SafeCleanupScanScope.allCases, [.systemJunk, .aiClutter, .mailAttachments, .trashBins])
        XCTAssertEqual(SafeCleanupScanScope.defaultsKey, "cleanup.selected-scopes.v1")
        XCTAssertEqual(CareJunkGroup.allCases.filter { $0.scanScope == .systemJunk },
                       [.systemJunk, .developerJunk, .filesToReview])
        for scope in SafeCleanupScanScope.allCases where scope != .systemJunk {
            XCTAssertEqual(CareJunkGroup.allCases.filter { $0.scanScope == scope }.map(\.rawValue), [scope.rawValue])
        }
    }
}
