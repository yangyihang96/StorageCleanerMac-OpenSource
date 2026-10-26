import Foundation
import XCTest
@testable import StorageCleanerMac

final class RecentItemsScannerTests: XCTestCase {
    func testOnlyTheFourGlobalNamesAndThreeExtensionsAreRecognized() throws {
        let fixture = try RecentItemsTestFixture(self)
        for name in ["RecentDocuments", "RecentApplications", "RecentServers", "RecentHosts"] {
            for suffix in ["sfl2", "sfl3", "sfl4"] {
                try fixture.write("com.apple.LSSharedFileList.\(name).\(suffix)")
            }
        }
        let snapshot = fixture.scanner.scan()
        XCTAssertEqual(snapshot.lists.count, 12)
        XCTAssertEqual(snapshot.knownEntryCount, 24)
        XCTAssertEqual(snapshot.unknownListCount, 0)
        XCTAssertEqual(snapshot.unreadableLocations, 0)
        XCTAssertEqual(snapshot.lists.filter { $0.category == .servers }.count, 6)
    }

    func testSidebarFavoritesUnlistedNamesAndOtherExtensionsAreNeverListed() throws {
        let fixture = try RecentItemsTestFixture(self)
        for name in ["FavoriteItems", "FavoriteVolumes", "TopSidebarSection", "ProjectsItems", "iCloudItems",
                     "RecentDocumentsExtra", "RecentDocument", "Other"] {
            for suffix in ["sfl2", "sfl3", "sfl4"] {
                let url = try fixture.write("com.apple.LSSharedFileList.\(name).\(suffix)")
                XCTAssertNil(fixture.scanner.classification(of: url))
            }
        }
        for name in ["RecentDocuments.sfl4", "com.apple.LSSharedFileList.RecentDocuments.sfl",
                     "com.apple.LSSharedFileList.RecentDocuments.sfl5", "com.apple.LSSharedFileList.RecentDocuments.sfl4.backup"] {
            try fixture.write(name)
        }
        XCTAssertTrue(fixture.scanner.scan().lists.isEmpty)
    }

    func testApplicationListsMustBeDirectBundleIdentifierFiles() throws {
        let fixture = try RecentItemsTestFixture(self)
        for suffix in ["sfl2", "sfl3", "sfl4"] { try fixture.write("com.example.Editor.\(suffix)", app: true) }
        for name in ["FavoriteItems", "FavoriteVolumes", "TopSidebarSection", "ProjectsItems", "iCloudItems", "Other",
                     "com..example", "com.example_App", "com.apple.LSSharedFileList.FavoriteItems"] {
            try fixture.write(name + ".sfl4", app: true)
        }
        let nested = fixture.scanner.rootURL.appendingPathComponent(RecentItemsScanner.applicationDirectory + "/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try RecentItemsTestFixture.archive(count: 2).write(to: nested.appendingPathComponent("com.example.Nested.sfl4"))
        let snapshot = fixture.scanner.scan()
        XCTAssertEqual(snapshot.lists.count, 3)
        XCTAssertTrue(snapshot.lists.allSatisfy { $0.category == .applicationDocuments && $0.bundleIdentifier == "com.example.Editor" })
    }

    func testDirectoriesAndSymbolicLinksAreRejectedEvenWithAllowlistedNames() throws {
        let fixture = try RecentItemsTestFixture(self)
        let real = try fixture.write()
        let linked = fixture.scanner.rootURL.appendingPathComponent("com.apple.LSSharedFileList.RecentApplications.sfl4")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let directory = fixture.scanner.rootURL.appendingPathComponent("com.apple.LSSharedFileList.RecentServers.sfl4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appLink = fixture.scanner.rootURL.appendingPathComponent(RecentItemsScanner.applicationDirectory + "/com.example.Link.sfl4")
        try FileManager.default.createSymbolicLink(at: appLink, withDestinationURL: real)
        XCTAssertThrowsError(try fixture.scanner.readList(at: linked))
        XCTAssertThrowsError(try fixture.scanner.readList(at: directory))
        XCTAssertEqual(fixture.scanner.scan().lists.map(\.url), [real])
    }

    func testLinkedListRootAndLinkedApplicationFolderAreNotTraversed() throws {
        let fixture = try RecentItemsTestFixture(self)
        try fixture.write()
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.scanner.rootURL)
        let linked = RecentItemsScanner(rootURL: alias).scan()
        XCTAssertTrue(linked.lists.isEmpty)
        XCTAssertGreaterThan(linked.unreadableLocations, 0)
        let apps = fixture.scanner.rootURL.appendingPathComponent(RecentItemsScanner.applicationDirectory)
        let original = fixture.root.appendingPathComponent("old-app-lists")
        try FileManager.default.moveItem(at: apps, to: original)
        try RecentItemsTestFixture.archive(count: 3).write(to: original.appendingPathComponent("com.example.Editor.sfl4"))
        try FileManager.default.createSymbolicLink(at: apps, withDestinationURL: original)
        XCTAssertEqual(fixture.scanner.scan().lists.count, 1)
        XCTAssertEqual(fixture.scanner.scan().unreadableLocations, 1)
    }

    func testRealKeyedArchiveCountsInstancesAndDoesNotUnarchiveOpaqueBookmarks() throws {
        XCTAssertEqual(RecentItemsScanner.entryCount(in: try RecentItemsTestFixture.archive(count: 3)), 3)
        XCTAssertEqual(RecentItemsScanner.entryCount(in: try RecentItemsTestFixture.archive(count: 0)), 0)
    }

    func testMalformedAndUnrecognizedArchivesHaveUnknownCounts() throws {
        XCTAssertNil(RecentItemsScanner.entryCount(in: Data("not a plist".utf8)))
        let arbitrary = try PropertyListSerialization.data(fromPropertyList: ["items": [1, 2]], format: .binary, options: 0)
        XCTAssertNil(RecentItemsScanner.entryCount(in: arbitrary))
        let noInstances: [String: Any] = ["$archiver": "NSKeyedArchiver", "$version": 100000,
            "$top": ["root": ["CF$UID": 0]], "$objects": ["$null"]]
        XCTAssertNil(RecentItemsScanner.entryCount(in: try PropertyListSerialization.data(fromPropertyList: noInstances, format: .binary, options: 0)))
        for (reference, name) in [(99, "SFLListItem"), (2, "FuturePrivateListEntry")] {
            let archive: [String: Any] = ["$archiver": "NSKeyedArchiver", "$version": 100000,
                "$top": ["root": ["CF$UID": 1]],
                "$objects": ["$null", ["$class": ["CF$UID": reference]], ["$classname": name, "$classes": [name, "NSObject"]]]]
            let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
            XCTAssertNil(RecentItemsScanner.entryCount(in: data))
        }
    }

    /// D192②: macOS 27 writes every list as a dictionary whose "items" array
    /// holds plain dictionaries (10-23 test beta read 10 + 10 + 10 + 2 as 0).
    func testDictionaryRootListsCountTheirItemsArray() throws {
        func list(_ items: [Any], key: String = "items") throws -> Data {
            let root: NSDictionary = [key: items as NSArray,
                                      "properties": ["com.apple.LSSharedFileList.MaxAmount": 10] as NSDictionary]
            return try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
        }
        let entries = (0..<3).map { index -> NSDictionary in
            ["visibility": 0, "uuid": "entry-\(index)", "Bookmark": Data("opaque-bookmark-fixture".utf8)]
        }
        XCTAssertEqual(RecentItemsScanner.entryCount(in: try list(entries)), 3)
        XCTAssertEqual(RecentItemsScanner.entryCount(in: try list([])), 0)
        XCTAssertEqual(RecentItemsScanner.entryCount(in: try list([RecentItemsFixtureSFLListItem(),
                                                                   RecentItemsFixtureSFLListItem()])), 2)
        XCTAssertNil(RecentItemsScanner.entryCount(in: try list(entries, key: "favorites")))
        XCTAssertNil(RecentItemsScanner.entryCount(in: try list(["not a list entry" as NSString])))

        let fixture = try RecentItemsTestFixture(self)
        try list(entries).write(to: fixture.scanner.rootURL
            .appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments.sfl4"))
        let snapshot = fixture.scanner.scan()
        XCTAssertEqual(snapshot.knownEntryCount, 3)
        XCTAssertEqual(snapshot.unknownListCount, 0)
    }

    func testMixedKnownEmptyAndUnreadableFilesDoNotGuessATotal() throws {
        let fixture = try RecentItemsTestFixture(self)
        try fixture.write(count: 4)
        try fixture.write("com.apple.LSSharedFileList.RecentApplications.sfl3", count: 0)
        let unknown = try fixture.write("com.example.Gone.sfl2", app: true)
        try Data("unreadable-format".utf8).write(to: unknown)
        let snapshot = fixture.scanner.scan()
        XCTAssertEqual(snapshot.lists.count, 3)
        XCTAssertEqual(snapshot.knownEntryCount, 4)
        XCTAssertEqual(snapshot.unknownListCount, 1)
        XCTAssertNil(snapshot.lists.first { $0.url == unknown }?.entryCount)
    }
}
