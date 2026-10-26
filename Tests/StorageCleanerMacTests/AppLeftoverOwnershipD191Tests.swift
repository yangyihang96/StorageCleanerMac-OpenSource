import XCTest
@testable import StorageCleanerMac

/// D191 (1:1 comparison round 2, 10-23): the Applications page listed 17
/// "removed apps" and preselected all 22 items (65 MB; CleanMyMac found
/// 184 KB). Several still had their owner installed: WeType's FinderSync
/// extension (WeType lives in /Library/Input Methods), Office's
/// `com.microsoft.office`/`com.microsoft.shared`, `com.setapp.defaults`,
/// `com.raycast.shared`, a running launch agent's logs, plus library and
/// toolchain caches (SDWebImage, Kingfisher, Firebase, SwiftPM).
final class AppLeftoverOwnershipD191Tests: XCTestCase {
    func testStoresOfInstalledOwnersVendorsLibrariesAndLaunchJobsAreNotLeftovers() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "d191-leftovers")
        let fm = FileManager.default
        let files = [
            "Library/Preferences/com.microsoft.office.plist", "Library/Preferences/com.microsoft.shared.plist",
            "Library/Preferences/com.setapp.defaults.plist", "Library/Logs/com.codingquota.agent.out.log",
            "Library/Preferences/info.marcel-dierkes.KeepingYouAwake.plist", "Library/Preferences/io.github.alice.Tool.plist",
        ]
        let folders = [
            "Library/Containers/com.tencent.inputmethod.wetype.FinderSync", "Library/Caches/com.hackemist.SDImageCache",
            "Library/Caches/com.onevcat.Kingfisher.ImageCache.default", "Library/Caches/org.swift.swiftpm",
            "Library/Application Support/com.firebase.FIRInstallations", "Library/Caches/com.raycast.shared",
        ]
        for relative in files {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        for relative in folders {
            try fm.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        let scanner = LeftoverScanner(
            homeDirectory: home,
            installedBundleIdentifiers: ["com.microsoft.Powerpoint", "com.setapp.DesktopClient", "com.raycast.macos",
                                         "io.github.bob.Other"],
            isRegistered: { $0 == "com.tencent.inputmethod.wetype" },
            hasLaunchJob: { $0 == "com.codingquota.agent" },
            measuresSizes: false)
        let groups = scanner.scan()
        XCTAssertEqual(Set(groups.map(\.bundleIdentifier)),
                       ["info.marcel-dierkes.KeepingYouAwake", "io.github.alice.Tool"],
                       "only stores whose owner and developer are both gone")
    }

    func testVendorDomainsAndOwnerCandidates() {
        XCTAssertEqual(LeftoverScanner.vendorDomain(of: "com.microsoft.office"), "com.microsoft")
        XCTAssertEqual(LeftoverScanner.vendorDomain(of: "group.com.emby.mobile"), "com.emby")
        XCTAssertEqual(LeftoverScanner.vendorDomain(of: "io.github.alice.Tool"), "io.github.alice")
        XCTAssertEqual(LeftoverScanner.vendorDomain(of: "com.local.CoCanBar.widget"), "com.local.cocanbar")
        XCTAssertNil(LeftoverScanner.vendorDomain(of: "io.github"))
        XCTAssertEqual(LeftoverScanner.ownerCandidates(for: "com.tencent.inputmethod.wetype.FinderSync"),
                       ["com.tencent.inputmethod.wetype.FinderSync", "com.tencent.inputmethod.wetype", "com.tencent.inputmethod"])
        XCTAssertEqual(LeftoverScanner.ownerCandidates(for: "group.com.emby.mobile"),
                       ["group.com.emby.mobile", "group.com.emby", "com.emby.mobile"])
    }
}
