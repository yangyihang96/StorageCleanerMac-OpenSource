#if DEBUG
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldFilesPresentationTests: XCTestCase {
    func testCompletedIndexCountsFilesAndLimitsLargestToEightWithoutDirectoriesOrDuplicates() {
        let fixture = FeatureLightfieldFileResultFixture.analysis
        XCTAssertEqual(FileLightfieldPresentation.fileCount(fixture.index), 27)
        XCTAssertEqual(fixture.inspectedItemCount, 38, "Directory visits are not the donut file count")
        let largest = FileLightfieldPresentation.largest(fixture.index)
        XCTAssertEqual(largest.count, 8)
        XCTAssertTrue(largest.allSatisfy { !$0.isDirectory && !$0.canDescend && $0.sizeBytes > 0 })
        XCTAssertEqual(largest.map(\.sizeBytes), largest.map(\.sizeBytes).sorted(by: >))
        let index = StorageMapAnalysisIndex(rootPath: fixture.index.rootPath, rootVolumeIdentifier: fixture.index.rootVolumeIdentifier,
            directories: fixture.index.directories, childrenByDirectory: fixture.index.childrenByDirectory,
            blockedDirectoryPaths: fixture.index.blockedDirectoryPaths, duplicateFilePaths: [largest[0].path])
        XCTAssertFalse(FileLightfieldPresentation.largest(index).contains { $0.path == largest[0].path })
        let parent = "/Fixture/Ties"
        let child = { (name: String) in StorageMapIndexedEntry(name: name, kind: "mov", sizeBytes: 100,
            isDirectory: false, canDescend: false, isEstimated: false) }
        let ties = StorageMapAnalysisIndex(rootPath: parent, rootVolumeIdentifier: nil, directories: [:],
            childrenByDirectory: [parent: [child("z.mov"), child("a.mov")]], blockedDirectoryPaths: [], duplicateFilePaths: [])
        XCTAssertEqual(FileLightfieldPresentation.largest(ties).map(\.title), ["a.mov", "z.mov"])
    }

    func testSevenTypesConserveMeasuredRootBytesAndMediaAggregatesExistingKinds() {
        let fixture = FeatureLightfieldFileResultFixture.analysis
        let types = FileLightfieldPresentation.types(fixture)
        XCTAssertEqual(types.reduce(0) { $0 + $1.value }, Double(fixture.rootSnapshot.measuredBytes))
        XCTAssertEqual(LightfieldFileCategory.allCases.count, 7)
        // D70 r4: every approved type's byte total comes from the same tree.
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0.value) }), [
            "application": 14_600_000_000, "system": 7_400_000_000, "developer": 19_600_000_000,
            "media": 87_100_000_000, "archive": 49_000_000_000, "document": 7_100_000_000, "other": 600_000_000,
        ])
        XCTAssertEqual(LightfieldFileCategory.category(.video), .media)
        XCTAssertEqual(LightfieldFileCategory.category(.image), .media)
        XCTAssertEqual(LightfieldFileCategory.category(.audio), .media)
        XCTAssertEqual(LightfieldFileCategory.category(.data), .other)
        XCTAssertEqual(types.first { $0.id == "media" }?.value, 87_100_000_000)
        XCTAssertEqual(FileLightfieldPresentation.sum([.max, 1, -1]), .max)
    }

    func testOldLargeQuickSelectionRequiresKnownPastDateAndOneGigabyteBoundary() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_791_547_200)
        let year = try XCTUnwrap(calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: now)))
        let entries = [entry("eligible", bytes: 1_000_000_000, date: year),
            entry("small", bytes: 999_999_999, date: year), entry("recent", date: year.addingTimeInterval(86_400)),
            entry("unknown", date: nil), entry("future", date: now.addingTimeInterval(86_400))]
        XCTAssertEqual(LightfieldMigrationPresentation.oldLargeIDs(entries, now: now, calendar: calendar), ["eligible"])
        let groups = LightfieldMigrationPresentation.groups(entries, by: .modified, root: nil, now: now, calendar: calendar)
        XCTAssertEqual(groups.first { $0.id == "3-unknown" }?.entries.map(\.id), ["unknown"])
        XCTAssertEqual(groups.first { $0.id == "3-future" }?.entries.map(\.id), ["future"])
        XCTAssertEqual(Set(groups.flatMap(\.entries).map(\.id)), Set(entries.map(\.id)))
        XCTAssertEqual(groups.reduce(Int64(0)) { $0 + $1.bytes }, FileLightfieldPresentation.sum(entries.map { $0.item.sizeBytes }))
    }

    func testGroupingIsStableAndLocationDoesNotMatchSiblingPrefix() {
        let entries = [entry("b", path: "/Fixture/Source/Projects/B.mov"), entry("a", path: "/Fixture/Source/Projects/A.mov"),
            entry("sibling", path: "/Fixture/SourceTwo/Other.mov"), entry("root", path: "/Fixture/Source/Root.pdf")]
        let now = Date(timeIntervalSince1970: 1_791_547_200)
        for mode in LightfieldMigrationGrouping.allCases {
            let forward = LightfieldMigrationPresentation.groups(entries, by: mode, root: "/Fixture/Source", now: now)
            let reverse = LightfieldMigrationPresentation.groups(Array(entries.reversed()), by: mode, root: "/Fixture/Source", now: now)
            XCTAssertEqual(forward.map(\.id), reverse.map(\.id))
            XCTAssertEqual(forward.map { $0.entries.map(\.id) }, reverse.map { $0.entries.map(\.id) })
        }
        let locations = LightfieldMigrationPresentation.groups(entries, by: .location, root: "/Fixture/Source", now: now)
        XCTAssertEqual(locations.first { $0.id == "/Fixture/Source/Projects" }?.entries.map(\.id), ["a", "b"])
        XCTAssertNotNil(locations.first { $0.id == "/Fixture/SourceTwo" })
    }

    func testGroupTriStateOnlyCountsItsEligibleScopeAndActionColumnFitsSevenWindows() {
        XCTAssertEqual(LightfieldSelectionCheck.state(ids: [], selected: ["outside"]), .unchecked)
        XCTAssertEqual(LightfieldSelectionCheck.state(ids: ["a", "b"], selected: ["outside"]), .unchecked)
        XCTAssertEqual(LightfieldSelectionCheck.state(ids: ["a", "b"], selected: ["a", "outside"]), .mixed)
        XCTAssertEqual(LightfieldSelectionCheck.state(ids: ["a", "b"], selected: ["a", "b", "outside"]), .checked)
        for width in [CGFloat(562), 742, 878, 878, 878, 419, 878] {
            let layout = LightfieldMigrationColumns.widths(width)
            XCTAssertEqual(layout.columns.count, 6)
            XCTAssertGreaterThanOrEqual(layout.columns[2], 100)
            XCTAssertGreaterThanOrEqual(layout.columns[5], 52)
            XCTAssertEqual(layout.columns.reduce(0, +) + layout.gap * 5, width, accuracy: 0.5)
        }
    }

    func testProductionRoutingRetainsExistingSafetyCallbacksAndInertFixturesHaveNoProviders() throws {
        let analysis = try source("Views/FilesLightfield/FileAnalysisLightfieldView.swift")
        for call in ["workspace.canReviewTrash", "workspace.requestTrashReview", "workspace.trashSelectionState", "workspace.toggleTrashSelection",
            "FileAnalysisTrashReviewSheet(", "workspace.retryStorageMapBrowse", "outcome.receiptIncomplete", "workspace.clearTrashSelection"] {
            XCTAssertTrue(analysis.contains(call), call)
        }
        let migration = try source("Views/LargeFilesView.swift")
        XCTAssertTrue(migration.contains("pendingMigration = $0"))
        XCTAssertTrue(migration.contains("pendingOriginalRemoval ="))
        XCTAssertTrue(migration.contains("ExternalDriveMigrationService.migrate(item, to: selectedVolume)"))
        let duplicates = try source("Views/FilesLightfield/DuplicateFilesLightfieldView.swift")
        XCTAssertTrue(duplicates.contains("!isSimilarPhotos && !selected.isEmpty && !isBusy"))
        XCTAssertTrue(duplicates.contains("store.requestVerifiedDuplicateCleanup(disposition: .trash, workspace: workspace)"))
        XCTAssertTrue(duplicates.contains("Manual review mark only; does not select deletion"))
        let duplicatePresentation = try source("Views/FilesLightfield/DuplicateLightfieldPresentation.swift")
        XCTAssertTrue(duplicatePresentation.contains("guard let date, date.timeIntervalSinceReferenceDate.isFinite, date <= now else"))
        XCTAssertTrue(duplicates.contains(".disabled(isBusy || !presentation.canKeepNewest)"))
        let fixture = try source("Debug/FeatureLightfieldFileResultFixture.swift")
        for token in ["DiskScanner(", "ScanStore(", "FileManager.default", "NSWorkspace", "copyAndVerify(", "moveToTrash("] {
            XCTAssertFalse(fixture.contains(token), "Inert result fixture: " + token)
        }
        for path in ["Views/FilesLightfield/FileAnalysisLightfieldView.swift", "Views/FilesLightfield/FileMigrationLightfieldView.swift",
            "Views/FilesLightfield/DuplicateFilesLightfieldView.swift", "Views/DesignSystem/FeatureLightfieldFileComponents.swift"] {
            let value = try source(path)
            for token in [".glassPanel(", "Material", "SurfaceBackground(", "ContentPanel(", "Image(systemName:"] {
                XCTAssertFalse(value.contains(token), path + " " + token)
            }
        }
    }

    private func entry(_ id: String, bytes: Int64 = 2_000_000_000, date: Date? = nil, path: String? = nil) -> LightfieldMigrationEntry {
        .init(item: .init(id: id, title: id + ".mov", sourceURL: URL(fileURLWithPath: path ?? "/Fixture/" + id + ".mov"),
            sizeBytes: bytes, kind: .file, bundleIdentifier: ""), modifiedAt: date)
    }
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }
}
#endif
