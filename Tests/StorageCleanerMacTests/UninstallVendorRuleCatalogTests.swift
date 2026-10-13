import Foundation
import XCTest
@testable import StorageCleanerMac

/// D87: vendor residual rules are exact, sourced and fail closed.
final class UninstallVendorRuleCatalogTests: XCTestCase {
    private let officialHosts: [String: String] = [
        "com.microsoft.VSCode": "code.visualstudio.com",
        "com.microsoft.teams2": "learn.microsoft.com",
        "com.microsoft.teams": "learn.microsoft.com",
        "com.google.Chrome": "support.google.com",
        "com.spotify.client": "support.spotify.com",
        "com.docker.docker": "docs.docker.com",
        "com.hnc.Discord": "support.discord.com",
        "com.figma.Desktop": "help.figma.com",
    ]

    func testEveryGrantingEntryHasOfficialSourceTeamAndUniqueRevision() throws {
        var revisions = Set<String>()
        var paths = Set<String>()
        for entry in UninstallVendorRules.entries {
            let source = try XCTUnwrap(URL(string: entry.source), entry.bundleID)
            XCTAssertEqual(source.scheme, "https", entry.bundleID)
            let expectedHost = entry.bundleID.hasPrefix("com.jetbrains.") ? "www.jetbrains.com" : officialHosts[entry.bundleID]
            XCTAssertEqual(source.host, expectedHost, entry.bundleID)
            XCTAssertEqual(entry.teamID.count, 10, entry.bundleID)
            XCTAssertTrue(entry.teamID.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }, entry.bundleID)
            XCTAssertTrue(UninstallCandidatePathPolicy.isSafeComponent(entry.bundleID))
            XCTAssertTrue(revisions.insert(entry.revision).inserted, "revision reused: \(entry.revision)")
            let entryPaths = Set(entry.paths("2026.2.1") + entry.paths("1.100.0")).sorted()
            for path in entryPaths {
                XCTAssertTrue(UninstallVendorRules.isSafeRelativePath(path), path)
                XCTAssertFalse(path.hasPrefix("Library/Group Containers/"), "shared groups never grant: \(path)")
                XCTAssertTrue(paths.insert(path).inserted, "two vendors claim \(path)")
            }
        }
    }

    func testRequestedApplicationsAreAllCovered() {
        let covered = Set(UninstallVendorRules.entries.map(\.bundleID)).union(UninstallVendorRules.discoveryOnlyPaths.keys)
        for bundleID in ["com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.tinyspeck.slackmacgap",
                         "us.zoom.xos", "com.hnc.Discord", "com.spotify.client", "com.docker.docker",
                         "com.jetbrains.toolbox", "com.jetbrains.intellij", "com.adobe.acc.AdobeCreativeCloud",
                         "com.getdropbox.dropbox", "ru.keepcoder.Telegram", "com.tencent.xinWeChat", "notion.id",
                         "com.figma.Desktop"] {
            XCTAssertTrue(covered.contains(bundleID), bundleID)
        }
    }

    func testWrongTeamSimilarBundleIDAndEmptyTeamGrantNothing() {
        for entry in UninstallVendorRules.entries {
            let version = entry.bundleID.hasPrefix("com.jetbrains.") ? "2026.2.1" : "1.100"
            XCTAssertFalse(UninstallVendorRules.rules(bundleID: entry.bundleID, version: version, teamID: entry.teamID).isEmpty, entry.bundleID)
            XCTAssertTrue(UninstallVendorRules.rules(bundleID: entry.bundleID, version: version, teamID: "ABCDE12345").isEmpty, entry.bundleID)
            XCTAssertTrue(UninstallVendorRules.rules(bundleID: entry.bundleID, version: version, teamID: "").isEmpty, entry.bundleID)
            XCTAssertTrue(UninstallVendorRules.rules(bundleID: entry.bundleID + ".helper", version: version, teamID: entry.teamID).isEmpty)
            XCTAssertTrue(UninstallVendorRules.rules(bundleID: entry.bundleID.lowercased() + "x", version: version, teamID: entry.teamID).isEmpty)
        }
        XCTAssertTrue(UninstallVendorRules.rules(bundleID: "com.google.Chrome.beta", version: "1", teamID: UninstallVendorRules.googleTeamID).isEmpty)
        XCTAssertTrue(UninstallVendorRules.rules(bundleID: "com.google.Chrome", version: "1", teamID: UninstallVendorRules.microsoftTeamID).isEmpty)
    }

    func testJetBrainsRulesAreBoundToTheInstalledMajorMinorVersion() {
        let rules = UninstallVendorRules.rules(bundleID: "com.jetbrains.intellij", version: "2026.2.1",
                                               teamID: UninstallVendorRules.jetBrainsTeamID)
        XCTAssertEqual(rules.map(\.relativePath), [
            "Library/Application Support/JetBrains/IntelliJIdea2026.2",
            "Library/Caches/JetBrains/IntelliJIdea2026.2",
        ])
        XCTAssertEqual(UninstallVendorRules.jetBrainsVersionFolder("2026.2"), "2026.2")
        for version in ["", "2026", "abc", "1.0", "26.2", "2026..1", "2026.x", "2026.123", "２０２６.2"] {
            XCTAssertNil(UninstallVendorRules.jetBrainsVersionFolder(version), version)
        }
        XCTAssertTrue(UninstallVendorRules.rules(bundleID: "com.jetbrains.pycharm", version: "2026",
                                                 teamID: UninstallVendorRules.jetBrainsTeamID).isEmpty)
        // The shared JetBrains parent folders are never a rule by themselves.
        XCTAssertFalse(UninstallVendorRules.entries.flatMap { $0.paths("2026.2") }.contains {
            $0 == "Library/Application Support/JetBrains" || $0 == "Library/Caches/JetBrains"
        })
    }

    func testDiscoveryOnlyPathsNeverOverlapGrantingRulesOrProtectedData() {
        let granting = Set(UninstallVendorRules.entries.flatMap { $0.paths("2026.2.1") + $0.paths("1.0") })
        for (bundleID, paths) in UninstallVendorRules.discoveryOnlyPaths {
            XCTAssertEqual(UninstallVendorRules.discoveryOnly(bundleID: bundleID), paths, bundleID)
            for path in paths {
                XCTAssertTrue(UninstallVendorRules.isSafeRelativePath(path), path)
                XCTAssertFalse(granting.contains(path), path)
                XCTAssertFalse(granting.contains { $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }, path)
            }
        }
        let everything = granting.union(UninstallVendorRules.discoveryOnlyPaths.values.flatMap { $0 })
        for path in everything {
            XCTAssertFalse(path.hasPrefix("Library/Application Support/Adobe"), "Adobe shared components: \(path)")
            XCTAssertFalse(path.localizedCaseInsensitiveContains("dropbox"), path)
            XCTAssertFalse(path.contains("CloudStorage") || path.contains("Mobile Documents"), path)
        }
        XCTAssertEqual(UninstallVendorRules.discoveryOnly(bundleID: "com.adobe.acc.AdobeCreativeCloud"), [])
        XCTAssertEqual(UninstallVendorRules.discoveryOnly(bundleID: "com.getdropbox.dropbox"), [])
    }

    func testDiscoveryCandidatesIgnoreTheSignerButRulesDoNot() {
        let candidates = UninstallVendorRules.discoveryCandidates(bundleID: "com.google.Chrome", version: "1")
        XCTAssertEqual(candidates, ["Library/Application Support/Google/Chrome"])
        XCTAssertTrue(UninstallVendorRules.rules(bundleID: "com.google.Chrome", version: "1", teamID: "").isEmpty)
        XCTAssertEqual(UninstallVendorRules.discoveryCandidates(bundleID: "com.docker.docker", version: "4"),
                       ["Library/Containers/com.docker.docker", "Library/Group Containers/group.com.docker"])
        XCTAssertTrue(UninstallVendorRules.discoveryCandidates(bundleID: "../evil", version: "1").isEmpty)
    }

    func testRelativePathTemplatesStayInsideSafeRoots() {
        for path in ["Library/Application Support", "Library/Logs/App", "Library/Application Support/../Mail",
                     "Library/Caches//x", ".docker", "Documents/App", "Library/LaunchAgents/x.plist", "/Library/Caches/x"] {
            XCTAssertFalse(UninstallVendorRules.isSafeRelativePath(path), path)
        }
        XCTAssertTrue(UninstallVendorRules.isSafeRelativePath("Library/Caches/com.spotify.client"))
    }

    /// 修复轮 1: a rule may name a product folder, never a vendor-level
    /// folder shared by several products (for example all of Google's).
    func testRulesNeverNameASharedVendorFolder() {
        for folder in UninstallVendorRules.sharedVendorFolders {
            XCTAssertFalse(UninstallVendorRules.isSafeRelativePath(folder), folder)
        }
        XCTAssertFalse(UninstallVendorRules.isSafeRelativePath("Library/Application Support/Google"))
        XCTAssertTrue(UninstallVendorRules.isSafeRelativePath("Library/Application Support/Google/Chrome"))
        var byBundle: [String: Set<String>] = [:]
        for entry in UninstallVendorRules.entries {
            for version in ["2026.2.1", "1.100.0", "1"] {
                byBundle[entry.bundleID, default: []].formUnion(entry.paths(version))
            }
        }
        for (bundleID, paths) in UninstallVendorRules.discoveryOnlyPaths { byBundle[bundleID, default: []].formUnion(paths) }
        for (bundleID, paths) in byBundle {
            for path in paths {
                XCTAssertFalse(UninstallVendorRules.sharedVendorFolders.contains(path), "\(bundleID): \(path)")
                // No path of one application contains another application's path.
                for (otherID, otherPaths) in byBundle where otherID != bundleID {
                    XCTAssertFalse(otherPaths.contains { $0 == path || $0.hasPrefix(path + "/") },
                                   "\(bundleID) \(path) covers \(otherID)")
                }
            }
        }
    }

    /// 修复轮 1: browser profiles and Docker data are labelled high value;
    /// shared group containers are listed without measuring.
    func testHighValueDataAndUnmeasuredSharedGroupsAreDeclared() {
        let home = "/Users/fixture"
        XCTAssertEqual(UninstallVendorRules.highValueData(path: home + "/Library/Application Support/Google/Chrome"), .personalProfile)
        XCTAssertEqual(UninstallVendorRules.highValueData(path: home + "/Library/Containers/com.docker.docker"), .imagesAndVolumes)
        XCTAssertNil(UninstallVendorRules.highValueData(path: home + "/Library/Caches/com.spotify.client"))
        XCTAssertNil(UninstallVendorRules.highValueData(path: home + "/Library/Application Support/Google/Chrome Beta"))
        for kind in UninstallVendorRules.HighValueData.allCases { XCTAssertFalse(kind.title.isEmpty) }
        for bundleID in ["com.tencent.xinWeChat", "ru.keepcoder.Telegram", "com.docker.docker"] {
            let unmeasured = UninstallVendorRules.unmeasuredDiscoveryPaths(bundleID: bundleID)
            XCTAssertFalse(unmeasured.isEmpty, bundleID)
            XCTAssertTrue(unmeasured.allSatisfy { $0.hasPrefix("Library/Group Containers/") }, bundleID)
        }
        XCTAssertFalse(UninstallVendorRules.unmeasuredDiscoveryPaths(bundleID: "com.docker.docker")
            .contains("Library/Containers/com.docker.docker"), "the granting container is still measured")
    }
}
