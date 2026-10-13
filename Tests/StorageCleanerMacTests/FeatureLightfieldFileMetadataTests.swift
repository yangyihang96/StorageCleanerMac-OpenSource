#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldFileMetadataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_547_200)

    func testExistingChildrenScanAndClassifierPreserveModificationDates() throws {
        let root = try makeRoot()
        let expected = try writeFiles(in: root)
        let entries = DiskScanner(excludedPaths: []).scanChildren(at: root.path, minimumBytes: 0,
            limit: 10, deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(entries.count, 3)
        let items = StorageClassifier.classify(groups: [.init(id: "large_files", title: "Files", entries: entries)])
        XCTAssertEqual(items.count, 3)
        let expectedByName = Dictionary(uniqueKeysWithValues: expected.map { (URL(fileURLWithPath: $0.key).lastPathComponent, $0.value) })
        XCTAssertEqual(Set(entries.map(\.name)), Set(expectedByName.keys))
        for entry in entries {
            XCTAssertEqual(try XCTUnwrap(entry.modifiedAt).timeIntervalSince1970,
                try XCTUnwrap(expectedByName[entry.name]).timeIntervalSince1970, accuracy: 0.001)
            let item = try XCTUnwrap(items.first { $0.path == entry.path })
            XCTAssertEqual(item.modifiedAt, entry.modifiedAt)
        }
    }

    func testMigrationProductionAdapterKeepsDatesAndOnlyMissingDatesAreUnknown() throws {
        // Addresses only; this adapter neither reads file contents nor executes
        // migration. The product's original inside-home gate remains active.
        let root = TestFileSystem.uniqueOperationRoot("metadata-adapter")
        TestFileSystem.registerOwnership(of: root, for: self)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let old = try XCTUnwrap(calendar.date(byAdding: .year, value: -2, to: now))
        let middle = try XCTUnwrap(calendar.date(byAdding: .month, value: -8, to: now))
        let recent = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: now))
        let dates: [Date?] = [old, middle, recent, nil, now.addingTimeInterval(86_400)]
        let items = dates.enumerated().map { index, date in
            metadataItem(id: "file-\(index)", path: root.appendingPathComponent("\(index).bin").path, date: date)
        }
        let entries = LightfieldMigrationPresentation.fileEntries(items)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.map(\.modifiedAt), dates)
        XCTAssertEqual(entries.map(\.id), items.map { "file:" + $0.id })
        let groups = LightfieldMigrationPresentation.groups(entries, by: .modified, root: root.path, now: now, calendar: calendar)
        for (key, id) in [("0-old", "file:file-0"), ("1-half", "file:file-1"), ("2-recent", "file:file-2"),
                          ("3-unknown", "file:file-3"), ("3-future", "file:file-4")] {
            XCTAssertEqual(groups.first { $0.id == key }?.entries.map(\.id), [id])
        }
        XCTAssertEqual(LightfieldMigrationPresentation.oldLargeIDs(entries, now: now, calendar: calendar), ["file:file-0"])
        let rejected = metadataItem(id: "outside", path: "/Fixture/outside.bin", date: old)
        XCTAssertTrue(LightfieldMigrationPresentation.fileEntries([rejected]).isEmpty, "No migration path exception")
    }

    func testDuplicateScannerAndProductionItemsKeepSnapshotDatesForExactAndCandidateResults() throws {
        let (report, _, expected) = try duplicateReport()
        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertFalse(report.candidates.isEmpty)
        let items = DuplicateFilesStore.storageItems(from: report)
        XCTAssertTrue(items.contains { $0.duplicateMatchKind == DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue })
        XCTAssertTrue(items.contains { $0.sourceID == "duplicate_candidates" })
        for entry in report.exactGroups.flatMap(\.files) + report.candidates.flatMap(\.files) {
            XCTAssertEqual(try XCTUnwrap(entry.modifiedAt).timeIntervalSince1970,
                try XCTUnwrap(expected[entry.path]).timeIntervalSince1970, accuracy: 0.001)
        }
        for item in items {
            XCTAssertEqual(try XCTUnwrap(item.modifiedAt).timeIntervalSince1970,
                try XCTUnwrap(expected[item.path]).timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testDuplicateResultCacheRecoversDatesFromItsAlreadyValidatedSnapshot() throws {
        let (report, configuration, expected) = try duplicateReport(operationRoot: true)
        let cacheRoot = try makeRoot()
        let cache = DuplicateFileResultStore(fileURL: cacheRoot.appendingPathComponent("results.json"))
        try cache.save(configuration: configuration, items: DuplicateFilesStore.storageItems(from: report),
            coverage: report.coverage, progress: report.progress, outcome: report.outcome, lastScanAt: now, scanSeconds: 0.01)
        let loaded = try XCTUnwrap(cache.load(configuration: configuration))
        XCTAssertFalse(loaded.items.isEmpty)
        for item in loaded.items {
            XCTAssertEqual(try XCTUnwrap(item.modifiedAt).timeIntervalSince1970,
                try XCTUnwrap(expected[item.path]).timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testKeepNewestIsEnabledForScannedDatesAndKeepsTheNewestCopyUnselected() async throws {
        let (report, _, expected) = try duplicateReport()
        let items = DiskScanner.itemsForDuplicateGroups(report.exactGroups)
        let groups = DuplicateFilesPresenter.groups(from: items)
        let newest = try XCTUnwrap(items.max { expected[$0.path]! < expected[$1.path]! })
        let model = MetadataSelectionFixture()
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: DuplicateMetadataNativeFixture(groups: groups, model: model), size: size, dark: true)
        defer { host.close() }
        let auto = L10n.text("自动选择：保留最新", "Auto Select: Keep Newest")
        let frames = try await host.frames(required: ["fixture.viewport", "lightfield.primary", "lightfield.duplicates.auto-select"], size: size)
        XCTAssertEqual(try XCTUnwrap(frames["lightfield.primary"]).height, 52, accuracy: 0.5)
        try await host.waitForAccessibility(labels: [auto], expectedEnabled: [auto: true], pressLabels: [auto],
            hitTestFrames: [try XCTUnwrap(frames["lightfield.duplicates.auto-select"])])
        XCTAssertTrue(try host.press(label: auto))
        let selectedFrames = try await host.frames(required: ["fixture.viewport", "lightfield.duplicates.select." + newest.id], size: size)
        XCTAssertEqual(model.selectedIDs, Set(items.map(\.id)).subtracting([newest.id]))
        XCTAssertEqual(model.changes.first?.id, newest.id)
        XCTAssertEqual(model.changes.first?.selected, false)
        let copy = L10n.text("选择副本：", "Select copy: ") + newest.path
        try await host.waitForAccessibility(labels: [copy], expectedValues: [copy: L10n.text("保留此份", "Keep this copy")],
            hitTestFrames: [try XCTUnwrap(selectedFrames["lightfield.duplicates.select." + newest.id])])
    }

    func testUnknownAndFutureDatesStillPreventAutomaticSelectionAndKeepersRemainStable() {
        let a = metadataItem(id: "a", path: "/Fixture/a.bin", date: now.addingTimeInterval(-10))
        let b = metadataItem(id: "b", path: "/Fixture/b.bin", date: now.addingTimeInterval(-5))
        let group = metadataGroup([a, b])
        let valid = DuplicateLightfieldPresentation.make(groups: [group], selectedIDs: [], preferredKeepers: [group.id: b.id], now: now)
        XCTAssertTrue(valid.canKeepNewest)
        XCTAssertEqual(valid.newestItemsByGroup[group.id]?.id, b.id)
        XCTAssertEqual(valid.keeperIDsByGroup[group.id], b.id)
        let selected = DuplicateLightfieldPresentation.make(groups: [group], selectedIDs: [b.id], preferredKeepers: [group.id: b.id], now: now)
        XCTAssertEqual(selected.keeperIDsByGroup[group.id], a.id)
        for date: Date? in [nil, now.addingTimeInterval(1)] {
            let unknown = metadataItem(id: "unknown", path: "/Fixture/unknown.bin", date: date)
            XCTAssertFalse(DuplicateLightfieldPresentation.make(groups: [metadataGroup([a, unknown])], selectedIDs: [], now: now).canKeepNewest)
        }
        let tied = metadataItem(id: "z", path: "/Fixture/z.bin", date: a.modifiedAt)
        XCTAssertEqual(DuplicateLightfieldPresentation.make(groups: [metadataGroup([tied, a])], selectedIDs: [], now: now)
            .newestItemsByGroup["metadata"]?.id, a.id, "Path is a deterministic tie-breaker")
    }

    private func makeRoot() throws -> URL {
        let root = TestFileSystem.uniqueRoot("file-metadata")
        TestFileSystem.registerCleanup(of: root, for: self)
        try TestFileSystem.createDirectory(at: root)
        return root
    }

    private func writeFiles(in root: URL) throws -> [String: Date] {
        var expected: [String: Date] = [:]
        for index in 0..<3 {
            let url = root.appendingPathComponent("\(index).bin")
            try Data((index == 2 ? "BBBBBBBB" : "AAAAAAAA").utf8).write(to: url)
            let date = now.addingTimeInterval(Double(index - 3) * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            expected[url.path] = date
        }
        return expected
    }

    private func duplicateReport(operationRoot: Bool = false) throws -> (DuplicateFileScanReport, DuplicateFileScanner.Configuration, [String: Date]) {
        let root: URL
        if operationRoot {
            // Persisted available files pass the existing no-symlink gate;
            // /var temp aliases do not. Keep the same hidden-HOME fixture
            // convention as IndependentFeatureWorkspaceStoreTests.
            root = TestFileSystem.uniqueOperationRoot("duplicate-metadata-cache")
            TestFileSystem.registerCleanup(of: root, for: self)
            try TestFileSystem.createDirectory(at: root)
        } else { root = try makeRoot() }
        let expected = try writeFiles(in: root)
        let configuration = DuplicateFileScanner.Configuration(roots: [root.path], excludedPaths: [],
            minimumBytes: 1, maxFilesScanned: 100, maxDirectoriesScanned: 100, maxDepth: 5,
            maxResults: 100, maxScanSeconds: 10, candidateRules: [.sameSize])
        return (DuplicateFileScanner.scanReport(configuration: configuration), configuration, expected)
    }
}

func metadataItem(id: String, path: String, date: Date?) -> StorageItem {
    StorageItem(id: id, title: id + ".bin", path: path, sourceID: "duplicate_files", groupTitle: "Duplicates",
        sizeBytes: 2_000_000_000, tier: .yellow, kind: "BIN", reason: "", recommendation: "", risk: "", requiresClose: "",
        trashPaths: [], openPath: path, modifiedAt: date, duplicateGroupID: "metadata",
        duplicateMatchKind: DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue, status: .available)
}

func metadataGroup(_ items: [StorageItem]) -> DuplicateDisplayGroup {
    DuplicateDisplayGroup(id: "metadata", title: "Duplicates", sizeBytes: items.first?.sizeBytes ?? 0,
        items: items, isContentConfirmed: true, candidateRule: nil, relationship: .independent, physicalReclaimableBytes: nil)
}

@MainActor
final class MetadataSelectionFixture: ObservableObject {
    @Published var selectedIDs: Set<String> = []
    var changes: [(selected: Bool, id: String)] = []
    func setSelected(_ selected: Bool, item: StorageItem) {
        changes.append((selected, item.id))
        if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
    }
}

struct DuplicateMetadataNativeFixture: View {
    let groups: [DuplicateDisplayGroup]
    @ObservedObject var model: MetadataSelectionFixture
    var body: some View {
        GeometryReader { proxy in
            FeatureLightfieldPage(module: .duplicates, phase: .result, title: "Duplicates", status: "Ready", safety: "Keep one",
                actionTitle: "Review", actionEnabled: false, showsArtwork: false, action: {}) {
                FeatureOptionsScrollView(probePrefix: "metadata.duplicates.list", balancesContent: false, usesLightfield: true, fadesResults: true) {
                    DuplicateLightfieldBody(groups: groups, isSimilarPhotos: false, selectedIDs: model.selectedIDs,
                        onSelected: model.setSelected, onReveal: { _ in }, onCopyPath: { _ in })
                }
            }.environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
        }.layoutProbe("fixture.viewport").environment(\.featureDisablesLayoutAnimations, true)
            .environment(\.moduleTheme, ReviewFilter.duplicates.moduleTheme)
            .environment(\.featurePresentationIsFixture, true)
    }
}
#endif
