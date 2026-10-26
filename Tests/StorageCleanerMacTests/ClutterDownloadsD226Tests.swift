import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D226 (the user chose plan B, 10-26): installers are listed only under
/// Applications → Installers, from one list of types; My Clutter's Downloads
/// lists the rest of the Downloads folder by where it came from, nothing
/// checked at first, with the D46 review before anything moves, the Ignore
/// List under Downloads, and what moves leaving Large & Old Files too.
@MainActor
final class ClutterDownloadsD226Tests: XCTestCase {
    private let home = "/Users/fixture"
    private var root: String { home + "/Downloads" }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    private func file(_ name: String, _ bytes: Int64 = 1_000, kind: String = "file") -> StorageMapIndexedEntry {
        StorageMapIndexedEntry(name: name, kind: kind, sizeBytes: bytes, isDirectory: false, canDescend: false, isEstimated: false)
    }

    private func folder(_ name: String, kind: String = "folder", placeholder: Bool = false) -> StorageMapIndexedEntry {
        StorageMapIndexedEntry(name: name, kind: kind, sizeBytes: nil, isDirectory: true,
                               canDescend: kind == "folder" && !placeholder, isEstimated: placeholder)
    }

    /// The top of the folder, and each listed folder's size, item count and files.
    private func analysis(_ top: [StorageMapIndexedEntry],
                          folders: [String: (bytes: Int64, items: Int, files: [StorageMapIndexedEntry])] = [:]) throws -> StorageMapAnalysisResult {
        var directories = [root: StorageMapDirectoryAggregate(immediateChildCount: top.count)]
        var children = [root: top]
        for (name, contents) in folders {
            let path = root + "/" + name
            directories[path] = StorageMapDirectoryAggregate(sizeBytes: contents.bytes, immediateChildCount: contents.files.count,
                                                             descendantItemCount: contents.items)
            children[path] = contents.files
        }
        let index = StorageMapAnalysisIndex(rootPath: root, rootVolumeIdentifier: nil, directories: directories,
                                            childrenByDirectory: children, blockedDirectoryPaths: [], duplicateFilePaths: [])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: root, using: index)
        return StorageMapAnalysisResult(target: .init(path: root, title: "Downloads", kind: .homeDirectory),
                                        volumeTotalBytes: 1_000_000_000_000, volumeAvailableBytes: 500_000_000_000,
                                        inspectedItemCount: top.count, omittedItemCount: 0, scanSeconds: 1,
                                        index: index, rootSnapshot: snapshot)
    }

    private func path(_ name: String) -> String { root + "/" + name }

    private func row(_ name: String, _ bytes: Int64, source: DownloadSource, modified: Date? = nil) -> DownloadRow {
        DownloadRow(path: path(name), name: name, isDirectory: false, kind: "file", bytes: bytes, itemCount: nil,
                    modifiedAt: modified, source: source)
    }

    private final class FakeTrash: DownloadsTrashing, LargeOldFilesTrashing, @unchecked Sendable {
        var prepared: [[String]] = []
        var executed = 0
        var skipped: Set<String> = []

        private func plan(_ selections: [FileAnalysisTrashSelection]) -> (FileAnalysisTrashReview, StorageMapAnalysisIndex, FileAnalysisTrashPolicy) {
            prepared.append(selections.map(\.path))
            let identity = FileIdentity(deviceID: 1, inode: 1, entryKind: .regularFile, creationTimeNanoseconds: nil)
            let review = FileAnalysisTrashReview(items: selections.map {
                FileAnalysisTrashReviewItem(selection: $0, status: .ready(identity), externalVolumeName: nil)
            })
            return (review,
                    StorageMapAnalysisIndex(rootPath: "/", rootVolumeIdentifier: nil, directories: [:], childrenByDirectory: [:],
                                            blockedDirectoryPaths: [], duplicateFilePaths: []),
                    FileAnalysisTrashPolicy(rootPath: "/", targetKind: .internalVolume, homePath: "/Users/fixture",
                                            appDataPath: "/Users/fixture/AppData", excludedPaths: [], runningApplicationPaths: [],
                                            mountPointPaths: [], protectedLinkTargets: []))
        }

        func prepare(_ rows: [DownloadRow], analysis: StorageMapAnalysisResult) async throws -> DownloadsTrashPlan {
            let (review, index, policy) = plan(rows.map {
                FileAnalysisTrashSelection(path: $0.path, title: $0.name, isDirectory: $0.isDirectory, kind: $0.kind,
                                           bytes: $0.bytes, itemCount: $0.itemCount)
            })
            return DownloadsTrashPlan(review: review, index: index, policy: policy)
        }

        func prepare(_ rows: [LargeOldFileRow]) async throws -> LargeOldFilesTrashPlan {
            let (review, index, policy) = plan(rows.map {
                FileAnalysisTrashSelection(path: $0.path, title: $0.item.title, isDirectory: false, kind: "file",
                                           bytes: $0.bytes, itemCount: nil)
            })
            return LargeOldFilesTrashPlan(review: review, index: index, policy: policy)
        }

        private func outcome(_ review: FileAnalysisTrashReview) -> FileAnalysisTrashOutcome {
            executed += 1
            let moved = review.readyItems.map(\.id).filter { !skipped.contains($0) }
            return FileAnalysisTrashOutcome(report: nil, movedPaths: moved,
                                            movedBytes: review.readyItems.filter { moved.contains($0.id) }.reduce(0) { $0 + $1.selection.bytes },
                                            skipped: review.items.filter { skipped.contains($0.id) }
                                                .map { .init(path: $0.id, title: $0.selection.title, reason: "changed") },
                                            notRestorableHereCount: 0, externalVolumeNames: [], receiptUnavailable: false, cancelled: false)
        }

        func execute(_ plan: DownloadsTrashPlan) async throws -> FileAnalysisTrashOutcome { outcome(plan.review) }
        func execute(_ plan: LargeOldFilesTrashPlan) async throws -> FileAnalysisTrashOutcome { outcome(plan.review) }
    }

    /// Counts the readings, so a test can tell when the folder was read again.
    private final class Readings: @unchecked Sendable {
        var count = 0
        var result: StorageMapAnalysisResult
        init(_ result: StorageMapAnalysisResult) { self.result = result }
    }

    private func makeStore(_ readings: Readings, sources: [String: DownloadSource] = [:], trash: FakeTrash = FakeTrash(),
                           list: IgnoreListStore? = nil) async throws -> DownloadsStore {
        let store = DownloadsStore(downloadsURL: URL(fileURLWithPath: root), homePath: home, trash: trash, ignoreList: { list },
                                   analyze: { _ in readings.count += 1; return readings.result },
                                   readSources: { _, _ in sources }, now: { [now] in now })
        store.refresh(after: nil)
        try await waitUntil { store.hasRead && !store.isReading }
        return store
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }

    private func ignoreList() throws -> IgnoreListStore {
        let home = try TestFileSystem.makeHome(for: self)
        return IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
    }

    // MARK: One list of installer types

    func testOneListOfInstallerTypesServesInstallersDownloadsAndLargeAndOld() {
        XCTAssertEqual(InstallerFileTypes.extensions, ["dmg", "pkg", "mpkg", "iso", "sparseimage", "xip"])
        XCTAssertEqual(UnusedInstallerScanner.extensions, InstallerFileTypes.extensions, "Applications → Installers reads the same list")
        XCTAssertTrue(InstallerFileTypes.isInstaller(path: "/u/Downloads/Setup.DMG"), "Any letter case")
        XCTAssertTrue(InstallerFileTypes.isInstaller(path: "/u/Downloads/Xcode_27.xip"))
        XCTAssertFalse(InstallerFileTypes.isInstaller(path: "/u/Downloads/Archive.zip"))
        XCTAssertFalse(InstallerFileTypes.isInstaller(path: "/u/Downloads/dmg"), "A name, not a type")
        // The Spotlight query finds a XIP by its name; it is neither a disk image nor an installer package.
        let query = UnusedInstallerScanner.spotlightQuery
        XCTAssertTrue(query.contains(#"kMDItemFSName == "*.xip"cd"#))
        XCTAssertTrue(query.contains(#"kMDItemContentTypeTree == "com.apple.disk-image"cd"#))
        XCTAssertTrue(query.contains(#"kMDItemContentTypeTree == "com.apple.installer-package-archive"cd"#))

        func item(_ name: String) -> StorageItem {
            let path = "/Users/fixture/Documents/" + name
            return StorageItem(id: "large-" + path, title: name, path: path, sourceID: "large_files", groupTitle: "",
                               sizeBytes: 500_000_000, tier: .yellow, kind: "file", reason: "", recommendation: "", risk: "",
                               requiresClose: "", trashPaths: [path], openPath: path, isDirectory: false, modifiedAt: now,
                               status: .available)
        }
        let items = ["Setup.dmg", "Tool.PKG", "Suite.mpkg", "Linux.iso", "Disk.sparseimage", "Xcode.xip", "Notes.pdf"].map(item)
        XCTAssertEqual(LargeOldFilesPresenter.rows(from: items, lastOpened: [:], ignoring: .empty, moved: []).map(\.item.title),
                       ["Notes.pdf"], "Large & Old Files lists no installer")
    }

    func testTheInstallerScanFindsAXIPAndKeepsTheD209Preselection() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "installers-d226")
        var urls: [String: URL] = [:]
        for (key, relative) in [("downloads", "Downloads/Xcode_27.xip"), ("documents", "Documents/Reference/Xcode_26.xip")] {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            urls[key] = url
        }
        let paths = urls.values.map(\.path)
        let files = UnusedInstallerScanner(homeDirectory: home, installedApplicationNames: ["Xcode"], search: { _ in paths }).scan()
        func preselected(_ key: String) -> Bool? {
            files.first { $0.resource.path == PathSafety.lexicalPath(urls[key]!.path) }?.preselected
        }
        XCTAssertEqual(files.count, 2, "A XIP is an installer wherever it is")
        XCTAssertEqual(preselected("downloads"), true, "D209: in Downloads, with its app installed")
        XCTAssertEqual(preselected("documents"), false, "D209: listed, not selected")
    }

    // MARK: What Downloads lists

    func testListsTheTopOfDownloadsLessInstallersAppsLinksPlaceholdersAndIgnoredItems() throws {
        let list = try ignoreList()
        XCTAssertTrue(list.add(path("Ignored.zip"), category: .downloads))
        XCTAssertTrue(list.add(path("Film.mov"), category: .largeAndOld))
        let result = try analysis([
            file("Report.pdf", 3_000), folder("Project"), file("Setup.DMG"), file("Tool.pkg"), file("Linux.iso"),
            file("Disk.sparseimage"), file("Xcode.xip"), folder("Suite.mpkg", kind: "package"), folder("Notes.app", kind: "package"),
            file("Shortcut", kind: "alias"), file("Locked", kind: "unavailable"), folder("Cloud Folder", placeholder: true),
            file(".DS_Store"), file("Ignored.zip"), file("Other.zip", 7_000), file("Film.mov", 9_000), file("Moved.txt")
        ], folders: ["Project": (bytes: 50_000, items: 12, files: [file("a.txt")])])
        let rows = DownloadsPresenter.rows(from: result, homePath: home, ignoring: list.snapshot(), removed: [path("Moved.txt")],
                                           sources: [path("Report.pdf"): .application("Safari")])
        XCTAssertEqual(rows.map(\.name), ["Report.pdf", "Project", "Other.zip", "Film.mov"],
                       "Installers, apps, links, unreadable items, cloud placeholders, hidden, ignored and moved items stay out")
        let project = try XCTUnwrap(rows.first { $0.name == "Project" })
        XCTAssertEqual(project.bytes, 50_000, "A folder counts everything in it")
        XCTAssertEqual(project.itemCount, 12)
        XCTAssertTrue(project.isDirectory)
        XCTAssertEqual(rows.first?.source, .application("Safari"))
        XCTAssertEqual(rows.last?.source, .other, "No record: other sources")
    }

    func testGroupsBySourceLargestFirstWithOtherSourcesLast() {
        let old = now.addingTimeInterval(-400 * 24 * 60 * 60)
        let rows = [
            row("b.zip", 50, source: .application("Safari"), modified: now), row("a.pdf", 100, source: .application("Safari"), modified: old),
            row("tool.tar", 500, source: .site("github.com")), row("big.mov", 1_000, source: .other),
            row("c.txt", 100, source: .application("Safari"))
        ]
        let groups = DownloadsPresenter.groups(rows)
        XCTAssertEqual(groups.map(\.source), [.site("github.com"), .application("Safari"), .other],
                       "Largest source first; other sources last however big")
        XCTAssertEqual(groups[1].rows.map(\.name), ["a.pdf", "c.txt", "b.zip"], "Largest first, then by name")
        XCTAssertEqual(groups[1].bytes, 250)
        XCTAssertEqual(DownloadsPresenter.groups(rows, sort: .name)[1].rows.map(\.name), ["a.pdf", "b.zip", "c.txt"])
        XCTAssertEqual(DownloadsPresenter.groups(rows, sort: .modified)[1].rows.map(\.name), ["a.pdf", "b.zip", "c.txt"],
                       "Oldest change first, no date last")
        XCTAssertEqual(DownloadsPresenter.groups(rows, query: "github").map(\.source), [.site("github.com")], "Search takes the source too")
        XCTAssertEqual(DownloadsPresenter.groups(rows, query: "big").flatMap(\.rows).map(\.name), ["big.mov"])
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(DownloadSource.application("Safari").title, "来自 Safari")
        XCTAssertEqual(DownloadSource.other.title, "其他来源")
        // D228＋旧值：was "来自 隔空投送"; no space before a Chinese name.
        XCTAssertEqual(DownloadSource.application(DownloadSource.applicationName(forAgent: "sharingd")).title, "来自隔空投送")
    }

    // MARK: Where an item came from

    func testSourceIsTheQuarantineAppThenTheSiteThenOther() throws {
        let base = try TestFileSystem.makeOperationHome(for: self, purpose: "downloads-source-d226")
        func make(_ relative: String, agent: String?) throws -> String {
            let url = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            if let agent {
                let value = "0083;6900a1b2;\(agent);1F0D3C70-1A2B-4C5D-8E9F-001122334455"
                XCTAssertEqual(setxattr(url.path, "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW), 0)
            }
            return url.path
        }
        let safari = try make("Report.pdf", agent: "Safari")
        let airDrop = try make("Photo.heic", agent: "sharingd")
        let unknown = try make("Plain.txt", agent: nil)
        XCTAssertEqual(DownloadSourceReader.quarantineAgent(atPath: safari), "Safari")
        var budget = 10
        XCTAssertEqual(DownloadSourceReader.source(ofFileAtPath: safari, siteLookups: &budget), .application("Safari"))
        XCTAssertEqual(budget, 10, "A quarantine record needs no Spotlight lookup")
        XCTAssertEqual(DownloadSourceReader.source(ofFileAtPath: airDrop, siteLookups: &budget),
                       .application(DownloadSource.applicationName(forAgent: "sharingd")))
        XCTAssertEqual(DownloadSourceReader.source(ofFileAtPath: unknown, siteLookups: &budget), .other)
        XCTAssertEqual(budget, 9, "One Spotlight lookup for the file without a record")
        var spent = 0
        XCTAssertEqual(DownloadSourceReader.source(ofFileAtPath: unknown, siteLookups: &spent), .other)
        XCTAssertEqual(spent, 0, "No budget left: other sources, without asking Spotlight")

        // A folder: its own record, else what most of its files share; a tie goes to the first met.
        let chrome1 = try make("Unzipped/a.txt", agent: "Google Chrome")
        let chrome2 = try make("Unzipped/b.txt", agent: "Google Chrome")
        let safari2 = try make("Unzipped/c.txt", agent: "Safari")
        let folder = base.appendingPathComponent("Unzipped").path
        budget = 10
        XCTAssertEqual(DownloadSourceReader.source(ofFolderAtPath: folder, files: [safari2, chrome1, chrome2], siteLookups: &budget),
                       .application("Google Chrome"))
        XCTAssertEqual(DownloadSourceReader.source(ofFolderAtPath: folder, files: [safari2, chrome1], siteLookups: &budget),
                       .application("Safari"))
        XCTAssertEqual(DownloadSourceReader.source(ofFolderAtPath: folder, files: [], siteLookups: &budget), .other)
    }

    // MARK: Checking, review and moving

    func testNothingIsCheckedAndTheReviewComesBeforeAnyMove() async throws {
        let trash = FakeTrash()
        let readings = Readings(try analysis([file("Movie.mov", 2_000_000_000), folder("Folder"), file("Notes.txt", 5_000)],
                                             folders: ["Folder": (bytes: 1_000_000_000, items: 1, files: [file("inside.mov", 1_000_000_000)])]))
        let store = try await makeStore(readings, sources: [path("Movie.mov"): .application("Safari")], trash: trash)
        XCTAssertEqual(store.rows.count, 3)
        XCTAssertEqual(store.selectedIDs, [], "Nothing is checked by default")
        XCTAssertEqual(store.totalBytes, 3_000_005_000)
        XCTAssertEqual(store.groups.first?.source, .application("Safari"))

        store.requestTrashReview()
        XCTAssertTrue(trash.prepared.isEmpty, "Nothing checked, nothing to review")
        let safariGroup = try XCTUnwrap(store.groups.first)
        store.toggle(safariGroup)
        XCTAssertEqual(store.selectedIDs, [path("Movie.mov")], "A group's tick checks its items")
        store.toggle(safariGroup)
        XCTAssertEqual(store.selectedIDs, [], "and clears them once all are checked")
        store.setSelected(true, row: try XCTUnwrap(store.rows.first { $0.name == "Movie.mov" }))
        store.setSelected(true, row: try XCTUnwrap(store.rows.first { $0.name == "Folder" }))
        store.requestTrashReview()
        try await waitUntil { store.trashPlan != nil }
        XCTAssertEqual(trash.prepared.last.map(Set.init), [path("Movie.mov"), path("Folder")])
        XCTAssertEqual(trash.executed, 0, "The review moves nothing")
        XCTAssertFalse(store.canEdit)

        var told: Set<String> = []
        store.onMovedToTrash = { told.formUnion($0) }
        trash.skipped = [path("Folder")]
        store.confirmTrash()
        try await waitUntil { !store.isMoving && store.trashPlan == nil }
        XCTAssertEqual(store.rows.map(\.name).sorted(), ["Folder", "Notes.txt"])
        XCTAssertEqual(store.selectedIDs, [path("Folder")], "The skipped folder stays checked")
        XCTAssertEqual(told, [path("Movie.mov")], "Large & Old Files hears what moved")
        let notice = try XCTUnwrap(store.notice)
        XCTAssertTrue(notice.contains(L10n.text("移到废纸篓", "to the Trash")))
        XCTAssertFalse(notice.contains("释放"), "D90/D93: a move is never called freeing up")
        XCTAssertEqual(readings.count, 1)
    }

    func testWhatMovesOnOneSideLeavesTheOtherList() async throws {
        let trash = FakeTrash()
        let readings = Readings(try analysis([file("Movie.mov", 2_000_000_000), folder("Folder"), file("Notes.txt", 500_000_000)],
                                             folders: ["Folder": (bytes: 1_000_000_000, items: 1, files: [file("inside.mov", 1_000_000_000)])]))
        let downloads = try await makeStore(readings, trash: trash)
        let coordinator = HeavyWorkCoordinator()
        let largeFiles = LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
                                         defaults: TestPreferenceDomain.make(for: self), storageMapTargets: [])
        let largeOld = LargeOldFilesStore(largeFiles: largeFiles, trash: trash, ignoreList: { nil },
                                          readLastOpened: { _ in [:] }, now: { [now] in now })
        func item(_ path: String) -> StorageItem {
            StorageItem(id: "large-" + path, title: (path as NSString).lastPathComponent, path: path, sourceID: "large_files",
                        groupTitle: "", sizeBytes: 500_000_000, tier: .yellow, kind: "file", reason: "", recommendation: "", risk: "",
                        requiresClose: "", trashPaths: [path], openPath: path, isDirectory: false, modifiedAt: now, status: .available)
        }
        largeFiles.replaceItemsForTesting([item(path("Movie.mov")), item(path("Folder/inside.mov")), item(path("Notes.txt")),
                                           item(home + "/Documents/Plan.pdf")], scannedAt: now)
        // As `ToolboxStores` wires them.
        largeOld.onMovedToTrash = { [weak downloads] in downloads?.forgetMovedPaths($0) }
        downloads.onMovedToTrash = { [weak largeOld] in largeOld?.forgetMovedPaths($0) }

        // Downloads moves a file and a folder: both leave Large & Old Files, the folder with the file inside it.
        let insideRow = try XCTUnwrap(largeOld.rows.first { $0.path == path("Folder/inside.mov") })
        largeOld.setSelected(true, row: insideRow)
        downloads.setSelected(true, row: try XCTUnwrap(downloads.rows.first { $0.name == "Movie.mov" }))
        downloads.setSelected(true, row: try XCTUnwrap(downloads.rows.first { $0.name == "Folder" }))
        downloads.requestTrashReview()
        try await waitUntil { downloads.trashPlan != nil }
        downloads.confirmTrash()
        try await waitUntil { !downloads.isMoving && downloads.trashPlan == nil }
        XCTAssertEqual(largeOld.rows.map(\.path).sorted(), [home + "/Documents/Plan.pdf", path("Notes.txt")])
        XCTAssertEqual(largeOld.selectedIDs, [], "A checked file that moved from Downloads is no longer counted")
        XCTAssertFalse(largeFiles.items.contains { $0.path.hasPrefix(path("Folder")) })

        // Large & Old Files moves a file at the top of Downloads: it leaves Downloads without another reading.
        largeOld.setSelected(true, row: try XCTUnwrap(largeOld.rows.first { $0.path == path("Notes.txt") }))
        largeOld.requestTrashReview()
        try await waitUntil { largeOld.trashPlan != nil }
        largeOld.confirmTrash()
        try await waitUntil { !largeOld.isMoving && largeOld.trashPlan == nil }
        XCTAssertEqual(downloads.rows.map(\.name), [])
        XCTAssertEqual(readings.count, 1)

        // A file moved from inside a listed folder: the folder is read again for its new size.
        readings.result = try analysis([folder("Kept")], folders: ["Kept": (bytes: 10, items: 1, files: [file("x", 10)])])
        downloads.forgetMovedPaths([path("Kept/big.mov")])
        try await waitUntil { readings.count == 2 && !downloads.isReading }
        XCTAssertEqual(downloads.rows.map(\.name), ["Kept"])
        XCTAssertEqual(downloads.rows.first?.bytes, 10)
    }

    // MARK: D207 Ignore List

    func testIgnoringHidesAtOnceAndPutBackReturnsTheItemChecked() async throws {
        let list = try ignoreList()
        let feedback = IgnoreListFeedback { list }
        let readings = Readings(try analysis([file("a.zip", 400), file("b.zip", 300)]))
        let store = try await makeStore(readings, list: list)
        let first = try XCTUnwrap(store.rows.first { $0.name == "a.zip" })
        store.setSelected(true, row: first)
        store.ignore([first], feedback: feedback)
        XCTAssertEqual(store.rows.map(\.name), ["b.zip"])
        XCTAssertEqual(store.selectedIDs, [])
        XCTAssertEqual(list.snapshot().entries.map(\.category), [.downloads], "By path, under Clutter → Downloads")
        XCTAssertEqual(list.snapshot().entries.map(\.target.path), [path("a.zip")])
        XCTAssertEqual(feedback.note?.canPutBack, true)

        feedback.putBack()
        XCTAssertEqual(Set(store.rows.map(\.name)), ["a.zip", "b.zip"])
        XCTAssertEqual(store.selectedIDs, [first.id], "Put Back returns it checked as it was")
        XCTAssertTrue(list.snapshot().entries.isEmpty)
    }

    // MARK: The results page and the manager

    func testResultsTileCountsWhatTheCategoryListsAndOnlyOpensIt() throws {
        let store = try ScanStore.makeForTests(for: self)
        var reviewed: [DuplicateResultFilter] = []
        func results() -> CareStudioClutterResults {
            CareStudioClutterResults(store: store, confirmedGroups: 0, confirmedFiles: 0, logicalBytes: 0, physicalBytes: nil,
                                     candidateGroups: 0, onReview: { reviewed.append($0) }, onStartOver: {})
        }
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        let toolbox = ToolboxStores.of(store)
        let downloads = toolbox.downloads
        let before = try XCTUnwrap(results().tiles.first { $0.id == "downloads" })
        XCTAssertNil(before.value, "Not read yet: no size on the tile")
        XCTAssertEqual(before.title, "下载")

        downloads.replaceReadingForTesting(.init(analysis: try analysis([file("a.zip", 400_000_000), file("Setup.dmg", 900_000_000),
                                                                          folder("Project")],
                                                                         folders: ["Project": (bytes: 1_500_000_000, items: 3, files: [])]),
                                                 sources: [:], modifiedDates: [:]))
        let tile = try XCTUnwrap(results().tiles.first { $0.id == "downloads" })
        XCTAssertEqual(downloads.rows.count, 2, "The installer is under Applications → Installers")
        XCTAssertEqual(tile.value, ByteFormat.storageString(1_900_000_000), "The size the category lists")
        XCTAssertEqual(tile.valueCaption, "2 个项目，按下载来源分组")
        XCTAssertNil(tile.onClean, "Nothing is selected by default, so the tile has no one-click action")
        XCTAssertNil(tile.cleanTitle)
        XCTAssertNil(tile.tick)
        XCTAssertEqual(tile.reviewTitle, "查看")

        toolbox.largeOldFiles.requestManager()
        tile.onReview()
        XCTAssertEqual(reviewed, [.all])
        XCTAssertTrue(downloads.isManagerRequested)
        XCTAssertFalse(toolbox.largeOldFiles.isManagerRequested, "One category is asked for at a time")
        let manager = CareStudioClutterManager(store: store, workspace: store.duplicateFilesWorkspace, allItems: [], groups: [],
                                               filter: .all, details: AnyView(EmptyView()), onFilter: { _ in }, onBack: {},
                                               showsLargeOld: false, onLargeOld: {}, showsDownloads: false, onDownloads: {})
        XCTAssertTrue(manager.showsDownloadsCategory, "The manager opens on Downloads")
        XCTAssertFalse(manager.showsLargeOldCategory)
        let classic = CareStudioClutterManager(store: store, workspace: store.duplicateFilesWorkspace, allItems: [], groups: [],
                                               filter: .all, details: AnyView(EmptyView()), onFilter: { _ in }, onBack: {})
        XCTAssertFalse(classic.showsDownloadsCategory, "Without the category's callback it is not offered")
        XCTAssertTrue(downloads.takeManagerRequest())
        XCTAssertFalse(downloads.takeManagerRequest(), "The request is taken once")
        XCTAssertTrue(downloads.selectedIDs.isEmpty)

        // The Large & Old Files tile drops a Downloads request left behind.
        downloads.requestManager()
        try XCTUnwrap(results().tiles.first { $0.id == "largeOld" }).onReview()
        XCTAssertFalse(downloads.isManagerRequested)
        XCTAssertTrue(toolbox.largeOldFiles.takeManagerRequest())
    }

    func testTheInstallersLineOpensApplicationsOnInstallers() throws {
        let store = try ScanStore.makeForTests(for: self)
        let model = ApplicationsManagerModel.of(store)
        model.showsOverview = true
        DownloadsPresentation.showInstallers(in: store)
        XCTAssertEqual(model.category, .installers)
        XCTAssertFalse(model.showsOverview)
        // Applications is a tool page: the hub with Uninstall as its tool, as `showFilter(.uninstall)` routes it.
        XCTAssertEqual(store.navigationState.selectedFilter, .utilityHub)
        XCTAssertEqual(store.selectedUtilityFilter, .uninstall)
    }

    func testTheFolderIsTheSystemDownloadsInTheHomeTheStoreReads() throws {
        let system = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        XCTAssertEqual(DownloadsStore.downloadsURL(homePath: PathSafety.lexicalHomePath), system,
                       "In the app: the location the system gives, not a path written here")
        XCTAssertEqual(DownloadsStore.downloadsURL(homePath: "/Users/fixture")?.path, "/Users/fixture/Downloads")
        let store = try ScanStore.makeForTests(for: self)
        let home = store.largeFilesWorkspace.fileAnalysisEnvironment.homePath
        XCTAssertNotEqual(home, PathSafety.lexicalHomePath, "fixture: a test store reads its own home")
        XCTAssertEqual(ToolboxStores.of(store).downloads.downloadsURL?.path, home + "/Downloads",
                       "A page test never reads the real Downloads folder")
    }

    func testAFailedReadingSaysWhyAndChecksNothing() async throws {
        let store = DownloadsStore(downloadsURL: URL(fileURLWithPath: root), homePath: home, trash: FakeTrash(), ignoreList: { nil },
                                   analyze: { _ in throw StorageMapAnalysisError.symbolicLinkPath }, readSources: { _, _ in [:] })
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        store.refresh(after: nil)
        try await waitUntil { !store.isReading && store.readError != nil }
        XCTAssertFalse(store.hasRead)
        XCTAssertEqual(store.readError, "“下载”文件夹是一个链接，这里不读取链接。")
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testANewerClutterScanReadsTheFolderAgainAndANewReadingChecksNothing() async throws {
        let readings = Readings(try analysis([file("a.zip", 400)]))
        let store = try await makeStore(readings)
        store.setSelected(true, row: store.rows[0])
        store.refresh(after: now.addingTimeInterval(-60))
        store.refresh(after: nil)
        XCTAssertEqual(readings.count, 1, "Read after that scan already, or no scan asked")
        store.refresh(after: now.addingTimeInterval(60))
        try await waitUntil { readings.count == 2 && !store.isReading }
        XCTAssertEqual(store.selectedIDs, [], "A new reading starts with nothing checked")
    }
}
