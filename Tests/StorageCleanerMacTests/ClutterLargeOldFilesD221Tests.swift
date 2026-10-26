import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D221: Large & Old Files in the clutter manager — which files of the
/// large-file list it shows, the kind, size and last-opened filters, nothing
/// checked at first, the D46 review before anything moves (never called
/// “free up”, D90/D93), and the D207 Ignore List with Put Back. D221 补: its
/// tile on the clutter results page.
@MainActor
final class ClutterLargeOldFilesD221Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func item(_ name: String, bytes: Int64, folder: Bool = false, modifiedDaysAgo: Double? = 400,
                      root: String = "/Users/fixture/Documents") -> StorageItem {
        let path = root + "/" + name
        return StorageItem(id: "large-" + path, title: name, path: path, sourceID: "large_files", groupTitle: "",
                           sizeBytes: bytes, tier: .yellow, kind: folder ? "folder" : "file", reason: "", recommendation: "",
                           risk: "", requiresClose: "", trashPaths: [path], openPath: path, isDirectory: folder,
                           modifiedAt: modifiedDaysAgo.map { now.addingTimeInterval(-$0 * day) }, status: .available)
    }

    private func row(_ item: StorageItem, openedDaysAgo: Double?) -> LargeOldFileRow {
        LargeOldFilesPresenter.rows(from: [item], lastOpened: openedDaysAgo.map { [item.path: now.addingTimeInterval(-$0 * day)] } ?? [:],
                                    ignoring: .empty, moved: [])[0]
    }

    // MARK: What is listed

    func testListsFilesOnlyWithKindSizeAndWhichDateItShows() {
        let items = [
            item("Report.pdf", bytes: 99_999_999), item("Holiday.jpg", bytes: 100_000_000),
            item("Film.mov", bytes: 999_999_999), item("Backup.zip", bytes: 1_000_000_000),
            item("Installer.dmg", bytes: 300_000_000), item("Projects", bytes: 5_000_000_000, folder: true),
            item("Never Opened.key", bytes: 200_000_000, modifiedDaysAgo: 40)
        ]
        let opened = items[0].path
        let rows = LargeOldFilesPresenter.rows(from: items, lastOpened: [opened: now.addingTimeInterval(-3 * day)],
                                               ignoring: .empty, moved: [])
        // D226＋旧值: the list was Report, Holiday, Film, Backup, Installer.dmg
        // (type .other, size .medium), Never Opened, so the last row was
        // rows[5]. Installers are now listed only under Applications →
        // Installers.
        XCTAssertEqual(rows.map(\.item.title), ["Report.pdf", "Holiday.jpg", "Film.mov", "Backup.zip", "Never Opened.key"],
                       "Folders stay with the large-file list; installers are under Applications → Installers")
        XCTAssertEqual(rows.map(\.type), [.documents, .pictures, .videos, .archives, .documents])
        XCTAssertEqual(rows.map(\.size), [.small, .medium, .medium, .large, .medium])
        XCTAssertTrue(rows[0].dateIsLastOpened)
        XCTAssertEqual(rows[0].date, now.addingTimeInterval(-3 * day))
        XCTAssertFalse(rows[4].dateIsLastOpened, "No Spotlight date: the modification date stands in")
        XCTAssertEqual(rows[4].date, now.addingTimeInterval(-40 * day))
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertTrue(LargeOldFilesPresentation.dateText(rows[0]).hasPrefix("上次打开"))
        XCTAssertTrue(LargeOldFilesPresentation.dateText(rows[4]).hasPrefix("无打开记录 · 修改于"), "The row says which date it shows")
        XCTAssertEqual(LargeOldFileSize.allCases.map(\.range), ["100 MB 以下", "100 MB–1 GB", "1 GB 及以上"])
    }

    func testIgnoreListKeepsItsFilesOutOfLargeAndOldOnly() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let list = IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
        let items = [item("a.pdf", bytes: 200_000_000), item("b.pdf", bytes: 200_000_000), item("c.pdf", bytes: 200_000_000)]
        XCTAssertTrue(list.add(items[0].path, category: .largeAndOld))
        XCTAssertTrue(list.add(items[1].path, category: .duplicates))
        let rows = LargeOldFilesPresenter.rows(from: items, lastOpened: [:], ignoring: list.snapshot(), moved: [])
        XCTAssertEqual(rows.map(\.item.title), ["b.pdf", "c.pdf"], "Another category's entry does not hide a file here")
        XCTAssertTrue(list.add(items[2].path, category: .other))
        XCTAssertEqual(LargeOldFilesPresenter.rows(from: items, lastOpened: [:], ignoring: list.snapshot(), moved: []).map(\.item.title),
                       ["b.pdf"], "Other covers every category, as everywhere")
    }

    // MARK: Filters and order

    func testFiltersAddUpWithinAGroupAndNarrowAcrossGroups() {
        let rows = [
            row(item("old.pdf", bytes: 2_000_000_000), openedDaysAgo: 400),
            row(item("recent.pdf", bytes: 50_000_000), openedDaysAgo: 2),
            row(item("clip.mov", bytes: 500_000_000), openedDaysAgo: 45),
            row(item("undated.zip", bytes: 150_000_000, modifiedDaysAgo: nil), openedDaysAgo: nil)
        ]
        func titles(_ filters: LargeOldFileFilters) -> [String] {
            rows.filter { filters.includes($0, now: now) }.map(\.item.title)
        }
        XCTAssertEqual(titles(LargeOldFileFilters()), ["old.pdf", "recent.pdf", "clip.mov", "undated.zip"], "Nothing checked shows all")
        XCTAssertEqual(titles(LargeOldFileFilters(types: [.documents, .videos])), ["old.pdf", "recent.pdf", "clip.mov"])
        XCTAssertEqual(titles(LargeOldFileFilters(types: [.documents], sizes: [.large])), ["old.pdf"])
        XCTAssertEqual(titles(LargeOldFileFilters(ages: [.withinWeek])), ["recent.pdf"])
        XCTAssertEqual(titles(LargeOldFileFilters(ages: [.overMonth])), ["old.pdf", "clip.mov"], "Older bands take in the oldest files")
        XCTAssertEqual(titles(LargeOldFileFilters(ages: [.overYear])), ["old.pdf"])
        XCTAssertEqual(titles(LargeOldFileFilters(ages: [.withinWeek, .overYear])), ["old.pdf", "recent.pdf"])
        XCTAssertFalse(titles(LargeOldFileFilters(ages: LargeOldFileAge.allCases.reduce(into: []) { $0.insert($1) }))
                        .contains("undated.zip"), "A file with no date matches no age")
        XCTAssertTrue(LargeOldFileAge.overHalfYear.includes(now.addingTimeInterval(-182 * day), now: now))
        XCTAssertFalse(LargeOldFileAge.overHalfYear.includes(now.addingTimeInterval(-181 * day), now: now))
    }

    func testSortsBySizeNameOrOldestOpenedFirst() {
        let rows = [
            row(item("b.pdf", bytes: 300_000_000), openedDaysAgo: 10),
            row(item("a.pdf", bytes: 900_000_000), openedDaysAgo: 500),
            row(item("c.pdf", bytes: 600_000_000, modifiedDaysAgo: nil), openedDaysAgo: nil)
        ]
        func order(_ sort: LargeOldFileSort, query: String = "") -> [String] {
            LargeOldFilesPresenter.visible(rows, filters: LargeOldFileFilters(), query: query, sort: sort, now: now).map(\.item.title)
        }
        XCTAssertEqual(order(.size), ["a.pdf", "c.pdf", "b.pdf"])
        XCTAssertEqual(order(.name), ["a.pdf", "b.pdf", "c.pdf"])
        XCTAssertEqual(order(.lastOpened), ["a.pdf", "b.pdf", "c.pdf"], "Oldest first; no date last")
        XCTAssertEqual(order(.size, query: "B.PDF"), ["b.pdf"])
    }

    // MARK: The store

    private final class FakeTrash: LargeOldFilesTrashing, @unchecked Sendable {
        var prepared: [[String]] = []
        var executed = 0
        var executeError: Error?
        var skipped: Set<String> = []

        func prepare(_ rows: [LargeOldFileRow]) async throws -> LargeOldFilesTrashPlan {
            prepared.append(rows.map(\.path))
            let identity = FileIdentity(deviceID: 1, inode: 1, entryKind: .regularFile, creationTimeNanoseconds: nil)
            let items = rows.map { row in
                FileAnalysisTrashReviewItem(selection: FileAnalysisTrashSelection(path: row.path, title: row.item.title, isDirectory: false,
                                                                                  kind: "file", bytes: row.bytes, itemCount: nil),
                                            status: .ready(identity), externalVolumeName: nil)
            }
            return LargeOldFilesTrashPlan(
                review: FileAnalysisTrashReview(items: items),
                index: StorageMapAnalysisIndex(rootPath: "/", rootVolumeIdentifier: nil, directories: [:], childrenByDirectory: [:],
                                               blockedDirectoryPaths: [], duplicateFilePaths: []),
                policy: FileAnalysisTrashPolicy(rootPath: "/", targetKind: .internalVolume, homePath: "/Users/fixture",
                                                appDataPath: "/Users/fixture/AppData", excludedPaths: [], runningApplicationPaths: [],
                                                mountPointPaths: [], protectedLinkTargets: []))
        }

        func execute(_ plan: LargeOldFilesTrashPlan) async throws -> FileAnalysisTrashOutcome {
            executed += 1
            if let executeError { throw executeError }
            let moved = plan.review.readyItems.map(\.id).filter { !skipped.contains($0) }
            return FileAnalysisTrashOutcome(report: nil, movedPaths: moved,
                                            movedBytes: plan.review.readyItems.filter { moved.contains($0.id) }.reduce(0) { $0 + $1.selection.bytes },
                                            skipped: plan.review.items.filter { skipped.contains($0.id) }
                                                .map { .init(path: $0.id, title: $0.selection.title, reason: "changed") },
                                            notRestorableHereCount: 0, externalVolumeNames: [], receiptUnavailable: false, cancelled: false)
        }
    }

    private func makeStore(_ items: [StorageItem], trash: FakeTrash = FakeTrash(),
                           list: IgnoreListStore? = nil) async throws -> (LargeOldFilesStore, LargeFilesStore) {
        let coordinator = HeavyWorkCoordinator()
        let largeFiles = LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
                                         defaults: TestPreferenceDomain.make(for: self), storageMapTargets: [])
        let opened = Dictionary(uniqueKeysWithValues: items.prefix(1).map { ($0.path, now.addingTimeInterval(-2 * day)) })
        let store = LargeOldFilesStore(largeFiles: largeFiles, trash: trash, ignoreList: { list },
                                       readLastOpened: { paths in opened.filter { paths.contains($0.key) } }, now: { [now] in now })
        largeFiles.replaceItemsForTesting(items, scannedAt: now)
        try await waitUntil { !store.isReadingDates && !store.lastOpened.isEmpty || items.isEmpty }
        return (store, largeFiles)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }

    func testNothingIsCheckedAndTheReviewComesBeforeAnyMove() async throws {
        let trash = FakeTrash()
        let items = [item("a.pdf", bytes: 400_000_000), item("b.mov", bytes: 1_500_000_000), item("c.zip", bytes: 120_000_000)]
        let (store, largeFiles) = try await makeStore(items, trash: trash)
        XCTAssertTrue(store.hasList)
        XCTAssertEqual(store.rows.count, 3)
        XCTAssertEqual(store.selectedIDs, [], "Nothing is checked by default")
        XCTAssertEqual(store.rows.first { $0.path == items[0].path }?.dateIsLastOpened, true, "Spotlight's date is read for the list")
        XCTAssertEqual(store.count(.videos), 1)
        XCTAssertEqual(store.count(.large), 1)
        XCTAssertEqual(store.count(.overYear), 2)

        store.requestTrashReview()
        XCTAssertTrue(trash.prepared.isEmpty, "Nothing checked, nothing to review")
        store.setSelected(true, row: store.rows[0])
        store.setSelected(true, row: store.rows[1])
        XCTAssertEqual(store.selectedBytes, 1_900_000_000)
        store.requestTrashReview()
        try await waitUntil { store.trashPlan != nil }
        XCTAssertEqual(trash.prepared.last.map(Set.init), Set([items[0].path, items[1].path]))
        XCTAssertEqual(trash.executed, 0, "The review moves nothing")
        XCTAssertFalse(store.canEdit)
        store.setSelected(true, row: store.rows[2])
        XCTAssertFalse(store.selectedIDs.contains(store.rows[2].id), "No checking while the review is open")

        trash.skipped = [items[1].path]
        store.confirmTrash()
        try await waitUntil { !store.isMoving && store.trashPlan == nil }
        XCTAssertEqual(trash.executed, 1)
        XCTAssertEqual(largeFiles.items.map(\.path), [items[1].path, items[2].path], "What moved leaves the large-file list too")
        XCTAssertEqual(store.rows.map(\.path), [items[1].path, items[2].path])
        XCTAssertEqual(store.selectedIDs, [items[1].id], "The skipped file stays checked")
        let notice = try XCTUnwrap(store.notice)
        XCTAssertTrue(notice.contains(L10n.text("移到废纸篓", "to the Trash")))
        XCTAssertFalse(notice.contains("释放"), "D90/D93: a move is never called freeing up")
    }

    func testABusyCleanupKeepsTheReviewOpenAndSaysWhy() async throws {
        let trash = FakeTrash()
        trash.executeError = HeavyWorkCoordinator.Error.busy(activeOwner: .cleanup)
        let (store, largeFiles) = try await makeStore([item("a.pdf", bytes: 400_000_000)], trash: trash)
        store.setSelected(true, row: store.rows[0])
        store.requestTrashReview()
        try await waitUntil { store.trashPlan != nil }
        store.confirmTrash()
        try await waitUntil { !store.isMoving }
        XCTAssertNotNil(store.trashPlan, "The review stays open")
        XCTAssertEqual(store.notice, HeavyWorkActivityStore.conflictMessage(activeOwner: .cleanup))
        XCTAssertEqual(largeFiles.items.count, 1, "Nothing left the list")
        store.cancelReview()
        XCTAssertNil(store.trashPlan)
        XCTAssertTrue(store.canEdit)
    }

    func testIgnoringHidesAtOnceAndPutBackReturnsTheFileChecked() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let list = IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
        let feedback = IgnoreListFeedback { list }
        let items = [item("a.pdf", bytes: 400_000_000), item("b.pdf", bytes: 300_000_000)]
        let (store, _) = try await makeStore(items, list: list)
        let first = try XCTUnwrap(store.rows.first { $0.path == items[0].path })
        store.setSelected(true, row: first)
        store.ignore([first], feedback: feedback)
        XCTAssertEqual(store.rows.map(\.path), [items[1].path])
        XCTAssertEqual(store.selectedIDs, [])
        XCTAssertEqual(list.snapshot().entries.map(\.category), [.largeAndOld])
        XCTAssertEqual(feedback.note?.canPutBack, true)

        feedback.putBack()
        XCTAssertEqual(Set(store.rows.map(\.path)), Set(items.map(\.path)))
        XCTAssertEqual(store.selectedIDs, [first.id], "Put Back returns it checked as it was")
        XCTAssertTrue(list.snapshot().entries.isEmpty)
    }

    func testANewLargeFileListStartsWithNothingChecked() async throws {
        let items = [item("a.pdf", bytes: 400_000_000)]
        let (store, largeFiles) = try await makeStore(items)
        store.setSelected(true, row: store.rows[0])
        store.toggle(.documents)
        XCTAssertEqual(store.selectedIDs.count, 1)
        largeFiles.replaceItemsForTesting(items + [item("b.pdf", bytes: 500_000_000)], scannedAt: now.addingTimeInterval(60))
        XCTAssertEqual(store.selectedIDs, [])
        XCTAssertEqual(store.filters.types, [.documents], "The filters are the person's choice and stay")
        XCTAssertEqual(store.rows.count, 2)
    }

    // MARK: The results page's tile (D221 补)

    func testResultsTileCountsWhatTheCategoryListsAndOnlyOpensIt() throws {
        let store = try ScanStore.makeForTests(for: self)
        var reviewed: [DuplicateResultFilter] = []
        func results() -> CareStudioClutterResults {
            CareStudioClutterResults(store: store, confirmedGroups: 0, confirmedFiles: 0, logicalBytes: 0, physicalBytes: nil,
                                     candidateGroups: 0, onReview: { reviewed.append($0) }, onStartOver: {})
        }
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        let before = try XCTUnwrap(results().tiles.first { $0.id == "largeOld" })
        XCTAssertNil(before.value, "No large-file list yet: no size on the tile")
        XCTAssertEqual(before.valueCaption, "体积较大、很久没打开的文件")

        let items = [item("a.pdf", bytes: 400_000_000), item("b.mov", bytes: 1_500_000_000),
                     item("Projects", bytes: 9_000_000_000, folder: true)]
        store.largeFilesWorkspace.replaceItemsForTesting(items, scannedAt: now)
        let largeOld = ToolboxStores.of(store).largeOldFiles
        let tile = try XCTUnwrap(results().tiles.first { $0.id == "largeOld" })
        XCTAssertEqual(largeOld.rows.count, 2)
        XCTAssertEqual(largeOld.totalBytes, 1_900_000_000, "The folder stays with the large-file list, as in the manager")
        XCTAssertEqual(tile.value, ByteFormat.storageString(1_900_000_000))
        XCTAssertEqual(tile.valueCaption?.hasPrefix("2 个大型文件"), true)
        XCTAssertNil(tile.onClean, "Nothing is selected by default, so the tile has no one-click action")
        XCTAssertNil(tile.cleanTitle)
        XCTAssertNil(tile.tick)
        XCTAssertEqual(tile.reviewTitle, "查看")

        tile.onReview()
        XCTAssertEqual(reviewed, [.all])
        XCTAssertTrue(largeOld.isManagerRequested)
        let manager = CareStudioClutterManager(store: store, workspace: store.duplicateFilesWorkspace, allItems: [], groups: [],
                                               filter: .all, details: AnyView(EmptyView()), onFilter: { _ in }, onBack: {},
                                               showsLargeOld: false, onLargeOld: {})
        XCTAssertTrue(manager.showsLargeOldCategory, "The manager opens on Large & Old Files")
        let classic = CareStudioClutterManager(store: store, workspace: store.duplicateFilesWorkspace, allItems: [], groups: [],
                                               filter: .all, details: AnyView(EmptyView()), onFilter: { _ in }, onBack: {})
        XCTAssertFalse(classic.showsLargeOldCategory, "Without the category's callback it is not offered")
        XCTAssertTrue(largeOld.takeManagerRequest())
        XCTAssertFalse(largeOld.takeManagerRequest(), "The request is taken once")
        XCTAssertFalse(manager.showsLargeOldCategory)
        XCTAssertTrue(largeOld.selectedIDs.isEmpty)

        tile.onReview()
        try XCTUnwrap(results().tiles.first { $0.id == "similarPhotos" }).onReview()
        XCTAssertEqual(reviewed, [.all, .all, .similarImage])
        XCTAssertFalse(largeOld.isManagerRequested, "Another way into the manager drops a request left behind")
    }

    // MARK: The review itself (D46)

    /// D186's fixture reader: temporary folders sit behind the system's /var
    /// link, which D46 would refuse; each component is checked with the
    /// production no-follow opener first.
    private struct FixtureMetadata: ReadOnlyFileSystem {
        func snapshot(at url: URL) throws -> FileSnapshot {
            let original = try FoundationReadOnlyFileSystem().snapshot(at: url)
            let checked = try GuardedFileContentReader().open(url)
            return withExtendedLifetime(checked) {
                FileSnapshot(identity: original.identity, standardizedPath: original.standardizedPath,
                    volumeIdentifier: original.volumeIdentifier, logicalSizeBytes: original.logicalSizeBytes,
                    allocatedSizeBytes: original.allocatedSizeBytes, modificationTimeNanoseconds: original.modificationTimeNanoseconds,
                    isWritableVolume: original.isWritableVolume, isCloudItem: original.isCloudItem,
                    isCloudPlaceholder: original.isCloudPlaceholder, hasSymbolicLinkComponent: false)
            }
        }
        func children(of directory: URL) throws -> [URL] {
            try FoundationReadOnlyFileSystem().children(of: directory)
        }
    }

    func testTheReviewHoldsBackFilesChangedOrGoneSinceTheScan() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        var environment = FileAnalysisTrashEnvironment(
            journal: CleanupReportJournal(directory: home.appendingPathComponent("Receipts")),
            moveToTrash: { _ in throw FileContentReadError.protectionUnavailable },
            metadata: FixtureMetadata(), homePath: home.path,
            appDataPath: home.appendingPathComponent("AppData").path, excludedPaths: { [] },
            isCloudFolder: { _ in false }, isReadOnlyVolume: { _ in false }, userTrashPath: home.appendingPathComponent("Trash").path)
        environment.protectedLinkTargets = { _, _ in [] }
        let service = LargeOldFilesTrashService(environment: environment, coordinator: HeavyWorkCoordinator())
        func listed(_ name: String) throws -> LargeOldFileRow {
            let url = home.appendingPathComponent("Documents/\(name)")
            try TestFileSystem.createDirectory(at: url.deletingLastPathComponent())
            try Data("Synthetic D221 fixture \(name)".utf8).write(to: url)
            let modified = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let listed = StorageItem(id: url.path, title: name, path: url.path, groupTitle: "", sizeBytes: 4096, tier: .yellow,
                                     kind: "file", reason: "", recommendation: "", risk: "", requiresClose: "",
                                     trashPaths: [url.path], openPath: url.path, modifiedAt: modified, status: .available)
            return LargeOldFilesPresenter.rows(from: [listed], lastOpened: [:], ignoring: .empty, moved: [])[0]
        }
        let ready = try listed("ready.pdf")
        let changed = try listed("changed.pdf")
        let gone = try listed("gone.pdf")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: changed.path)
        try FileManager.default.removeItem(atPath: gone.path)

        let plan = try await service.prepare([ready, changed, gone])
        XCTAssertEqual(plan.review.readyItems.map(\.id), [ready.path])
        XCTAssertEqual(plan.review.items.first { $0.id == changed.path }?.status, .blocked(.changedSinceAnalysis))
        XCTAssertEqual(plan.review.items.first { $0.id == gone.path }?.status, .blocked(.missing))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "The review moves nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Receipts").path))
    }
}
