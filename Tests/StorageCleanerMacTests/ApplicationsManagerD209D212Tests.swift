import XCTest
@testable import StorageCleanerMac

/// D209: an installer is preselected only in Downloads or on the Desktop (10-25:
/// a project's reference DMG in Documents was preselected because its app was
/// installed). D212: copies of one trashed app make one leftover group, and a
/// path goes in one removal request only (10-25: three identical groups, two of
/// whose requests found the files already moved, so the page said some were not).
@MainActor
final class ApplicationsManagerD209D212Tests: XCTestCase {
    private func resource(_ path: String) -> ApplicationResource {
        ApplicationResource(path: path, group: .preferences, evidence: .bundleIdentifier, domain: .user, kind: .file,
                            sizeBytes: 100, identity: nil, isRemovable: true, note: nil)
    }

    func testOnlyInstallersInDownloadsOrOnTheDesktopArePreselected() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "installers-d209")
        let fm = FileManager.default
        var urls: [String: URL] = [:]
        for (key, relative) in [("downloads", "Downloads/Photon Studio 3.1.dmg"),
                                ("nested", "Downloads/Apps/Photon Studio 3.2.dmg"),
                                ("desktop", "Desktop/Photon Studio 3.3.pkg"),
                                ("project", "Documents/New project/Notch/reference/Photon Studio 3.4.dmg"),
                                ("lookalike", "DownloadsArchive/Photon Studio 3.5.dmg")] {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            urls[key] = url
        }
        let paths = urls.values.map(\.path)
        let files = UnusedInstallerScanner(homeDirectory: home, installedApplicationNames: ["Photon Studio"],
                                           search: { _ in paths }).scan()
        func preselected(_ key: String) -> Bool? {
            let path = PathSafety.lexicalPath(urls[key]!.path)
            return files.first { $0.resource.path == path }?.preselected
        }
        XCTAssertEqual(files.count, 5, "every installer is still listed")
        XCTAssertTrue(files.allSatisfy { $0.matchedApplication == "Photon Studio" })
        XCTAssertEqual(preselected("downloads"), true)
        XCTAssertEqual(preselected("nested"), true)
        XCTAssertEqual(preselected("desktop"), true)
        XCTAssertEqual(preselected("project"), false, "listed, not selected")
        XCTAssertEqual(preselected("lookalike"), false, "a folder whose name only starts with Downloads")
    }

    func testCopiesOfOneTrashedAppMakeOneGroupWithEachPathOnce() {
        let shared = ["/u/Library/Preferences/com.example.sync.plist", "/u/Library/HTTPStorages/com.example.sync"]
        let groups = ApplicationsManagerModel.mergingByIdentifier([
            LeftoverGroup(bundleIdentifier: "com.example.sync", displayName: "Sync", resources: shared.map(resource)),
            LeftoverGroup(bundleIdentifier: "com.example.sync", displayName: "Sync", resources: shared.map(resource)),
            LeftoverGroup(bundleIdentifier: "com.example.sync", displayName: "Sync",
                          resources: (shared + ["/u/Library/Caches/com.example.sync"]).map(resource)),
            LeftoverGroup(bundleIdentifier: "com.example.other", displayName: "Other",
                          resources: [resource("/u/Library/Caches/com.example.other")]),
        ])
        XCTAssertEqual(groups.map(\.bundleIdentifier), ["com.example.sync", "com.example.other"])
        XCTAssertEqual(groups[0].resources.map(\.path), shared + ["/u/Library/Caches/com.example.sync"])
    }

    func testAPathGoesInOneRemovalRequestOnly() {
        let model = ApplicationsManagerModel()
        let shared = ["/u/Library/Preferences/com.example.sync.plist", "/u/Library/HTTPStorages/com.example.sync"].map(resource)
        model.replaceLeftovers([
            LeftoverGroup(bundleIdentifier: "com.example.sync", displayName: "Sync", resources: shared),
            LeftoverGroup(bundleIdentifier: "com.example.sync.helper", displayName: "Sync Helper",
                          resources: shared + [resource("/u/Library/Caches/com.example.sync.helper")]),
            LeftoverGroup(bundleIdentifier: "com.example.sync.copy", displayName: "Sync Copy", resources: shared),
        ])
        let requests = model.buildRequests()
        let paths = requests.flatMap(\.resources).map(\.path)
        XCTAssertEqual(paths.count, Set(paths).count, "no path in two requests")
        XCTAssertEqual(requests.map(\.title), ["Sync", "Sync Helper"], "a request left with nothing is dropped")
        XCTAssertEqual(requests.last?.resources.map(\.path), ["/u/Library/Caches/com.example.sync.helper"])
    }
}
