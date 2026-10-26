import Foundation
import XCTest
@testable import StorageCleanerMac

/// CleanMyMac-style resource finding (`UninstallerScanning` fetchers) on an
/// isolated home and system root. Read-only: nothing here moves a file.
final class ApplicationResourceFinderTests: XCTestCase {
    func testNameMatcherComparesWordsAndIgnoresTrailingVersions() {
        XCTAssertTrue(ApplicationNameMatcher.matches(resourceName: "Spotify", applicationName: "Spotify"))
        XCTAssertTrue(ApplicationNameMatcher.matches(resourceName: "Adobe Photoshop 2024", applicationName: "Adobe Photoshop 2024"))
        XCTAssertTrue(ApplicationNameMatcher.matches(resourceName: "Foo-Bar_2", applicationName: "Foo Bar"))
        XCTAssertTrue(ApplicationNameMatcher.matches(resourceName: "foo.bar", applicationName: "Foo Bar"))
        XCTAssertFalse(ApplicationNameMatcher.matches(resourceName: "Code", applicationName: "Visual Studio Code"))
        XCTAssertFalse(ApplicationNameMatcher.matches(resourceName: "Foo Bar Pro", applicationName: "Foo Bar"))
        // Too generic to claim a folder by name alone.
        XCTAssertNil(ApplicationNameMatcher.identifyingWords(of: "Notes"))
        XCTAssertNil(ApplicationNameMatcher.identifyingWords(of: "Go"))
        XCTAssertFalse(ApplicationNameMatcher.matches(resourceName: "Notes", applicationName: "Notes"))
        XCTAssertTrue(ApplicationNameMatcher.isIdentifierOrDerived("com.vendor.App.helper", identifier: "com.vendor.app"))
        XCTAssertFalse(ApplicationNameMatcher.isIdentifierOrDerived("com.vendor.AppOther", identifier: "com.vendor.App"))
    }

    func testFinderCollectsCleanMyMacGroupsAndSkipsOthersAndProtectedLocations() throws {
        // Strict path checks reject `/var` → `/private/var`; use the hidden
        // operation home (no link on the path), as moving fixtures do.
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "app-resources")
        let system = home.appendingPathComponent("SystemRoot", isDirectory: true)
        try TestFileSystem.createDirectory(at: system.appendingPathComponent("Library"))
        let fm = FileManager.default
        let id = "com.example.Photon"
        let app = home.appendingPathComponent("Applications/Photon Studio.app")
        try TestFileSystem.createDirectory(at: app.appendingPathComponent("Contents/MacOS"))
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Photon Studio",
                                   "CFBundleExecutable": "PhotonStudio", "CFBundleShortVersionString": "3.1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        func touchFolder(_ relative: String) throws { try TestFileSystem.createDirectory(at: home.appendingPathComponent(relative)) }
        func touchFile(_ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try TestFileSystem.createDirectory(at: url.deletingLastPathComponent())
            try Data("x".utf8).write(to: url)
        }
        try touchFolder("Library/Containers/\(id)")
        try touchFile("Library/Preferences/\(id).plist")
        try touchFile("Library/Preferences/ByHost/\(id).ABCDEF.plist")
        try touchFolder("Library/Caches/\(id)")
        try touchFolder("Library/Application Support/Photon Studio")
        try touchFolder("Library/Logs/Photon Studio 3")
        try touchFolder("Library/Saved Application State/\(id).savedState")
        try touchFile("Library/Logs/DiagnosticReports/PhotonStudio-2026-10-19-101010.ips")
        try touchFile("Downloads/Photon Studio 3.1.dmg")
        let agent: [String: Any] = ["Label": "\(id).updater", "ProgramArguments": ["/usr/bin/true"]]
        let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(id).updater.plist")
        try TestFileSystem.createDirectory(at: agentURL.deletingLastPathComponent())
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: agentURL)
        // Decoys: a more specific installed app owns `.Pro`; a protected
        // system store; an unrelated folder; a symlink.
        try touchFile("Library/Preferences/\(id).Pro.plist")
        try touchFolder("Library/Application Support/AddressBook")
        try touchFolder("Library/Caches/Unrelated")
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/Photon Studio"),
                                  withDestinationURL: home.appendingPathComponent("Library/Caches/Unrelated"))

        let profile = try XCTUnwrap(ApplicationProfileReader.profile(at: app))
        let appURLString = URL(fileURLWithPath: app.path, isDirectory: true).absoluteString
        let finder = ApplicationResourceFinder(
            homeDirectory: home, systemRoot: system,
            installedBundleIdentifiers: [id, "\(id).Pro"],
            installedApplicationPaths: [app.path],
            dockTileURLs: { [appURLString] },
            darwinUserCacheDirectory: nil, darwinUserTempDirectory: nil,
            measuresSizes: false
        )
        let resources = finder.resources(for: profile)
        let byName = Dictionary(grouping: resources, by: { ($0.path as NSString).lastPathComponent })

        XCTAssertEqual(byName["Photon Studio.app"]?.first?.group, .binaries)
        XCTAssertEqual(byName[id]?.map(\.group).sorted(by: { $0.rawValue < $1.rawValue }), [.caches, .container])
        XCTAssertEqual(byName["\(id).plist"]?.first?.group, .preferences)
        XCTAssertEqual(byName["\(id).ABCDEF.plist"]?.first?.group, .preferences)
        XCTAssertEqual(byName["Photon Studio"]?.first?.group, .supportingFiles)
        XCTAssertEqual(byName["Photon Studio"]?.first?.evidence, .nameMatch)
        XCTAssertEqual(byName["Photon Studio 3"]?.first?.group, .logs)
        XCTAssertEqual(byName["\(id).savedState"]?.first?.group, .supportingFiles)
        XCTAssertEqual(byName["PhotonStudio-2026-10-19-101010.ips"]?.first?.group, .crashes)
        XCTAssertEqual(byName["Photon Studio 3.1.dmg"]?.first?.group, .installers)
        let launch = try XCTUnwrap(byName["\(id).updater.plist"]?.first)
        XCTAssertEqual(launch.group, .loginItems)
        XCTAssertEqual(launch.kind, .launchdJob(label: "\(id).updater"))
        XCTAssertTrue(resources.contains { $0.group == .dockIcon })

        XCTAssertNil(byName["\(id).Pro.plist"], "a more specific installed app owns it")
        XCTAssertNil(byName["AddressBook"], "protected location")
        XCTAssertNil(byName["Unrelated"])
        XCTAssertFalse(resources.contains { $0.path.hasSuffix("Caches/Photon Studio") }, "symlinks are not followed")
        XCTAssertTrue(resources.allSatisfy { $0.domain == .user })
    }

    func testProtectedSystemApplicationOnlyOffersAReset() throws {
        let profile = ApplicationProfile(
            bundleURL: URL(fileURLWithPath: "/System/Applications/Chess.app"), bundleIdentifier: "com.apple.Chess",
            displayName: "Chess", bundleName: "Chess", executableName: "Chess", version: "3",
            teamIdentifier: nil, applicationGroups: [], helperBundleIdentifiers: [], privilegedExecutables: []
        )
        XCTAssertTrue(profile.isProtectedSystemApplication)
        XCTAssertTrue(profile.isAppleApplication)
    }

    func testSharedVendorGroupIsSkippedWhileAnotherVendorAppIsInstalled() {
        let profile = ApplicationProfile(
            bundleURL: URL(fileURLWithPath: "/Applications/Word.app"), bundleIdentifier: "com.microsoft.Word",
            displayName: "Microsoft Word", bundleName: "Microsoft Word", executableName: "Microsoft Word", version: "16",
            teamIdentifier: "UBF8T346G9", applicationGroups: ["UBF8T346G9.Office", "UBF8T346G9.com.microsoft.Word"],
            helperBundleIdentifiers: [], privilegedExecutables: []
        )
        let alone = ApplicationResourceFinder(installedBundleIdentifiers: ["com.microsoft.Word"])
        XCTAssertTrue(alone.ownsApplicationGroup("UBF8T346G9.Office", profile: profile))
        let suite = ApplicationResourceFinder(installedBundleIdentifiers: ["com.microsoft.Word", "com.microsoft.Excel"])
        XCTAssertFalse(suite.ownsApplicationGroup("UBF8T346G9.Office", profile: profile))
        XCTAssertTrue(suite.ownsApplicationGroup("UBF8T346G9.com.microsoft.Word", profile: profile))
        // D151 review: another vendor's group is never Word's own, even alone;
        // the vendor's own groups are those under its Team ID or its prefix.
        XCTAssertFalse(alone.ownsApplicationGroup("group.com.othervendor.shared", profile: profile))
        XCTAssertFalse(alone.ownsApplicationGroup("ABCDE12345.Shared", profile: profile))
        XCTAssertTrue(alone.ownsApplicationGroup("group.com.microsoft.shared", profile: profile))
        XCTAssertTrue(ApplicationResourceFinder.isVendorGroup("ubf8t346g9.office", vendor: "com.microsoft", teamIdentifier: "UBF8T346G9"))
        XCTAssertFalse(ApplicationResourceFinder.isVendorGroup("group.com.micro", vendor: "com.microsoft", teamIdentifier: nil))
    }

    /// D151 review: a declared group the app cannot be shown to own alone (here
    /// another vendor's) is listed with its note but cannot be removed; the
    /// app's own groups stay removable.
    func testAnotherVendorsGroupIsListedButNotOffered() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "app-groups")
        let system = home.appendingPathComponent("SystemRoot", isDirectory: true)
        try TestFileSystem.createDirectory(at: system.appendingPathComponent("Library"))
        let id = "com.example.photon"
        let own = "ABCDE12345.com.example.photon"
        let vendor = "group.com.example.shared"
        let foreign = "group.com.othervendor.shared"
        for group in [own, vendor, foreign] {
            try TestFileSystem.createDirectory(at: home.appendingPathComponent("Library/Group Containers/\(group)"))
        }
        let profile = ApplicationProfile(
            bundleURL: home.appendingPathComponent("Applications/Photon.app"), bundleIdentifier: id,
            displayName: "Photon", bundleName: "Photon", executableName: "Photon", version: "1",
            teamIdentifier: "ABCDE12345", applicationGroups: [own, vendor, foreign],
            helperBundleIdentifiers: [], privilegedExecutables: []
        )
        let finder = ApplicationResourceFinder(
            homeDirectory: home, systemRoot: system, installedBundleIdentifiers: [id],
            dockTileURLs: { [] }, darwinUserCacheDirectory: nil, darwinUserTempDirectory: nil, measuresSizes: false
        )
        let containers = Dictionary(uniqueKeysWithValues: finder.resources(for: profile, includeBundle: false)
            .filter { $0.group == .container }.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0) })
        let shared = try XCTUnwrap(containers[foreign], "another vendor's group is still listed")
        XCTAssertFalse(shared.isRemovable)
        XCTAssertEqual(shared.note, ApplicationResourceFinder.sharedGroupNote)
        for group in [own, vendor] {
            let container = try XCTUnwrap(containers[group])
            XCTAssertTrue(container.isRemovable, group)
            XCTAssertNil(container.note, group)
        }
    }
}
