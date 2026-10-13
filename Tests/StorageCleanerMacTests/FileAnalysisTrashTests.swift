import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D46: File Analysis moves checked items to the Trash after a review, with
/// a receipt Operation History can restore. These tests cover which items
/// can be checked (the rules table), the review, the check right before the
/// move, and the receipt and restore.
///
/// Fixtures only: a hidden folder under the home folder holds the analyzed
/// tree, a fixture "Trash" and an isolated receipt journal; it is removed
/// afterwards. Nothing goes to the real Trash or the live journal.
final class FileAnalysisTrashTests: XCTestCase {
    // MARK: - Which items can be checked

    func testTheStartupDiskRulesTable() {
        let home = "/Users/fixture"
        let policy = FileAnalysisTrashPolicy(
            rootPath: "/", targetKind: .internalVolume, homePath: home,
            appDataPath: home + "/Library/Application Support/StorageCleanerMac",
            excludedPaths: [home + "/Projects/Keep"],
            cloudSyncedFolders: [home + "/Documents"]
        )
        func block(_ path: String, kind: String = "file", directory: Bool = false,
                   estimated: Bool = false) -> FileAnalysisTrashBlock? {
            policy.block(path: path, name: (path as NSString).lastPathComponent, kind: kind,
                         isDirectory: directory, isEstimated: estimated)
        }
        XCTAssertEqual(block("/", kind: "folder", directory: true), .analysisRoot)
        for path in ["/Users", home, "/Users/other"] {
            XCTAssertEqual(block(path, kind: "folder", directory: true), .homeFolder, path)
        }
        XCTAssertEqual(block("/Users/Shared/movie.mov"), .outsideHome)
        XCTAssertEqual(block("/Users/other/Downloads/a.zip"), .outsideHome)
        for path in ["/System", "/Library/Caches/com.example", "/usr/local/bin/tool", "/private/var/tmp/x.log",
                     "/opt/homebrew", "/cores/core.123", "/Volumes", "/bin/ls", "/Applications"] {
            XCTAssertEqual(block(path, kind: "folder", directory: true), .systemLocation, path)
        }
        XCTAssertEqual(block("/Applications/Tool.app", kind: "package", directory: true), .applicationBundle)
        XCTAssertEqual(block("/Applications/Utilities", kind: "folder", directory: true), .applicationsFolder)
        XCTAssertEqual(block("/Applications/readme.pdf"), .applicationsFolder)
        for name in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library", "Applications", "Public"] {
            XCTAssertEqual(block(home + "/" + name, kind: "folder", directory: true), .standardFolder, name)
        }
        XCTAssertEqual(block(home + "/Library/Application Support", kind: "folder", directory: true), .appData)
        XCTAssertEqual(block(home + "/Library/Application Support/StorageCleanerMac/CleanupReports", kind: "folder",
                             directory: true), .appData)
        XCTAssertEqual(block(home + "/.Trash", kind: "folder", directory: true), .trash)
        XCTAssertEqual(block(home + "/.Trash/old.zip"), .trash)
        XCTAssertEqual(block(home + "/Library/Mobile Documents", kind: "folder", directory: true), .cloudStorage)
        XCTAssertEqual(block(home + "/Library/Mobile Documents/com~apple~CloudDocs/a.pdf"), .cloudStorage)
        XCTAssertEqual(block(home + "/Library/CloudStorage/Dropbox/b.mov"), .cloudStorage)
        XCTAssertEqual(block(home + "/Documents/Report.pages", kind: "package", directory: true), .cloudStorage,
                       "Documents is kept in iCloud here")
        XCTAssertNil(block(home + "/Desktop/shot.png"), "Desktop is not kept in iCloud here")
        XCTAssertEqual(block(home + "/Downloads/Installer.app", kind: "package", directory: true), .applicationBundle)
        XCTAssertEqual(block(home + "/Downloads/shortcut", kind: "alias"), .symbolicLink)
        XCTAssertEqual(block(home + "/Projects/Keep", kind: "folder", directory: true), .excluded)
        XCTAssertEqual(block(home + "/Projects/Keep/a.swift"), .excluded)
        XCTAssertEqual(block(home + "/Projects", kind: "folder", directory: true), .excluded, "Holds an exclusion")
        XCTAssertEqual(block(home + "/Downloads/odd", kind: "unavailable"), .unreadable)
        XCTAssertEqual(block(home + "/Downloads/Partial", kind: "folder", directory: true, estimated: true),
                       .incompleteMeasurement)
        XCTAssertEqual(block(home + "/Downloads/unsized.zip", estimated: true), .incompleteMeasurement)
        XCTAssertEqual(policy.block(path: home + "/Downloads/placeholder.zip", name: "placeholder.zip", kind: "zip",
                                    isDirectory: false, isEstimated: true, isCloudOnly: true), .cloudOnly)
        // What can be checked.
        XCTAssertNil(block(home + "/Downloads/clip.mov"))
        XCTAssertNil(block(home + "/Library/Caches/com.example", kind: "folder", directory: true))
        XCTAssertNil(block(home + "/.npm", kind: "folder", directory: true))
        XCTAssertNil(block(home + "/Pictures/Old.photoslibrary", kind: "package", directory: true),
                     "Packages other than apps are user data")
        XCTAssertNil(block(home + "/Developer/Build/Products/Debug/Demo", kind: "folder", directory: true))

        // The home folder as the analyzed location.
        let homeScope = FileAnalysisTrashPolicy(rootPath: home, targetKind: .homeDirectory, homePath: home,
                                                appDataPath: home + "/Library/Application Support/StorageCleanerMac",
                                                excludedPaths: [])
        XCTAssertEqual(homeScope.block(path: home, name: "fixture", kind: "folder", isDirectory: true,
                                       isEstimated: false), .analysisRoot)
        XCTAssertNil(homeScope.block(path: home + "/Projects", name: "Projects", kind: "folder", isDirectory: true,
                                     isEstimated: false))
    }

    func testTheExternalVolumeRulesTable() {
        var policy = FileAnalysisTrashPolicy(rootPath: "/Volumes/Ext", targetKind: .externalVolume,
                                             homePath: "/Users/fixture", appDataPath: "/Users/fixture/AppData",
                                             excludedPaths: [])
        func block(_ relative: String, kind: String = "file", directory: Bool = false) -> FileAnalysisTrashBlock? {
            let path = relative.isEmpty ? "/Volumes/Ext" : "/Volumes/Ext/" + relative
            return policy.block(path: path, name: (path as NSString).lastPathComponent, kind: kind,
                                isDirectory: directory, isEstimated: false)
        }
        XCTAssertEqual(block("", kind: "folder", directory: true), .analysisRoot)
        XCTAssertEqual(block(".Trashes", kind: "folder", directory: true), .trash)
        XCTAssertEqual(block(".Trashes/501/old.mov"), .trash)
        XCTAssertEqual(block(".Spotlight-V100", kind: "folder", directory: true), .systemLocation)
        XCTAssertEqual(block(".fseventsd", kind: "folder", directory: true), .systemLocation)
        XCTAssertEqual(block("Backups.backupdb", kind: "folder", directory: true), .systemLocation)
        XCTAssertEqual(block("Apps/Tool.app", kind: "package", directory: true), .applicationBundle)
        XCTAssertNil(block("Movies/a.mov"))
        XCTAssertNil(block("Library", kind: "folder", directory: true), "An external drive's folders are the user's")
        policy.isReadOnlyVolume = true
        XCTAssertEqual(block("Movies/a.mov"), .readOnlyVolume)
    }

    func testEveryReasonReadsAsChineseWithoutInternalNames() {
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        let rawNames = FileAnalysisTrashBlock.allCases.map(\.rawValue)
        for block in FileAnalysisTrashBlock.allCases {
            for text in [block.shortTitle, block.explanation] {
                XCTAssertFalse(text.isEmpty, block.rawValue)
                XCTAssertTrue(text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, text)
                XCTAssertFalse(rawNames.contains { text.contains($0) }, text)
            }
        }
        XCTAssertTrue(FileAnalysisTrashBlock.cloudStorage.explanation.contains("请在访达或云盘应用中处理"))
        XCTAssertTrue(FileAnalysisTrashBlock.cloudStorage.explanation.contains("从所有设备删除"))
        XCTAssertEqual(CleanSkipReasonPresentation.title(.changedSinceAnalysis), "分析后已修改或替换，请重新分析")
    }

    // MARK: - Review and the check right before the move

    func testTheReviewMarksReadyItemsAndSaysWhyTheOthersCannotMove() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        try Data("edited after the analysis".utf8).write(to: fixture.url("Docs/notes.txt"))
        try FileManager.default.removeItem(at: fixture.url("gone.bin"))
        try fixture.lock("locked.bin")
        defer { fixture.unlock("locked.bin") }
        let cloudy = fixture.url("cloud.bin").path

        let environment = fixture.environment(metadata: CloudStandIn(cloudPaths: [cloudy]))
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let names = ["big.zip", "Docs", "Tool.app", "link", "Docs/notes.txt", "gone.bin", "locked.bin", "cloud.bin"]
        let review = FileAnalysisTrashService.review(
            try names.map { try fixture.selection($0, in: analysis.index) },
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )

        func status(_ name: String) -> FileAnalysisTrashReviewItem.Status? {
            review.items.first { $0.selection.path == fixture.url(name).path }?.status
        }
        guard case .ready = status("big.zip"), case .ready = status("Docs") else {
            return XCTFail("A file and a folder as analyzed are ready: \(review.items.map(\.status))")
        }
        XCTAssertEqual(status("Tool.app"), .blocked(.applicationBundle))
        XCTAssertEqual(status("link"), .blocked(.symbolicLink))
        XCTAssertEqual(status("Docs/notes.txt"), .blocked(.changedSinceAnalysis))
        XCTAssertEqual(status("gone.bin"), .blocked(.missing))
        XCTAssertEqual(status("locked.bin"), .blocked(.locked))
        XCTAssertEqual(status("cloud.bin"), .blocked(.cloudStorage))
        XCTAssertEqual(review.readyItems.count, 2)
        XCTAssertEqual(review.readyBytes,
                       try fixture.allocatedBytes("big.zip") + XCTUnwrap(analysis.index.directories[fixture.url("Docs").path]).sizeBytes)
    }

    func testMovingWritesARestorableReceiptAndOperationHistoryPutsTheItemsBack() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let environment = fixture.environment()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        // Finder saving .DS_Store in the folder after the analysis does not
        // count as a change.
        try Data("finder".utf8).write(to: fixture.url("Docs/.DS_Store"), options: .atomic)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("big.zip", in: analysis.index), try fixture.selection("Docs", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertEqual(Set(outcome.movedPaths), [fixture.url("big.zip").path, fixture.url("Docs").path])
        XCTAssertEqual(outcome.movedBytes, review.readyBytes)
        XCTAssertEqual(outcome.skipped, [])
        XCTAssertEqual(outcome.notRestorableHereCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("big.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("Docs/Nested/deep.bin").path))

        let reports = try fixture.journal.load()
        XCTAssertEqual(reports.count, 1, "One durable receipt")
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.rulesVersion, FileAnalysisTrashService.ruleID)
        XCTAssertEqual(report.disposition, .trash)
        XCTAssertEqual(report.restorableReceipts.count, 2)
        XCTAssertEqual(report.summary.movedToRecoverableLocationBytes, review.readyBytes)

        // Operation History's restore path puts both back.
        let coordinator = HeavyWorkCoordinator()
        let service = CleanupRecoveryService()
        let journal = fixture.journal
        let trash = fixture.trash
        let restored = try await coordinator.withLease(owner: .restore) { lease in
            await service.restore(report: report, coordinator: coordinator, lease: lease,
                                  journal: journal, trashURL: trash)
        }
        XCTAssertEqual(restored.recovery.restoredCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Docs/Nested/deep.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("big.zip").path))
    }

    func testAnItemThatChangedAfterTheReviewIsSkippedExplainedAndKept() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let environment = fixture.environment()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            try ["big.zip", "Docs", "Media"].map { try fixture.selection($0, in: analysis.index) },
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )
        XCTAssertEqual(review.readyItems.count, 3)
        // After the review: the archive is replaced, a file appears deep in
        // a checked folder; Media stays as analyzed.
        let bytes = try Data(contentsOf: fixture.url("big.zip"))
        try FileManager.default.removeItem(at: fixture.url("big.zip"))
        try bytes.write(to: fixture.url("big.zip"))
        try Data("new".utf8).write(to: fixture.url("Docs/Nested/new.txt"))

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertEqual(outcome.movedPaths, [fixture.url("Media").path])
        XCTAssertEqual(Set(outcome.skipped.map(\.path)), [fixture.url("big.zip").path, fixture.url("Docs").path])
        XCTAssertTrue(outcome.skipped.allSatisfy { $0.reason == FileAnalysisTrashBlock.changedSinceAnalysis.explanation })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("big.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Docs/Nested/deep.bin").path))
        let report = try XCTUnwrap(try fixture.journal.load().first)
        let skipped = report.items.filter {
            if case .skipped = $0.outcome { return true }
            return false
        }
        XCTAssertEqual(skipped.count, 2, "The receipt records both as kept in place")
        XCTAssertTrue(skipped.allSatisfy {
            $0.outcome == .skipped(.changedSinceAnalysis) || $0.outcome == .skipped(.identityChanged)
        })
        XCTAssertEqual(report.summary.skippedItemCount, 2)
        XCTAssertEqual(report.summary.movedItemCount, 1)
    }

    func testWithoutADurableIntentNothingMoves() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        // A journal folder that cannot be created: its parent is a file.
        try Data().write(to: fixture.base.appendingPathComponent("not-a-folder"))
        let environment = fixture.environment(
            journal: CleanupReportJournal(directory: fixture.base.appendingPathComponent("not-a-folder/Receipts"))
        )
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertTrue(outcome.receiptUnavailable)
        XCTAssertEqual(outcome.movedPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("big.zip").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
    }

    func testARefusedMoveKeepsTheItemAndSaysSo() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let environment = fixture.environment(moveToTrash: { _ in throw CocoaError(.fileWriteNoPermission) })
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertEqual(outcome.movedPaths, [])
        XCTAssertEqual(outcome.skipped.map(\.path), [fixture.url("big.zip").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("big.zip").path))
        let report = try XCTUnwrap(try fixture.journal.load().first, "The refused attempt is recorded")
        XCTAssertTrue(report.restorableReceipts.isEmpty)
    }

    /// Items on an external volume go to that volume's Trash; the receipt
    /// is written as usual, but Operation History restores only from the
    /// user's Trash, so the page says to put them back in Finder.
    func testAMoveIntoAnotherTrashIsRecordedButNotOfferedForRestoreHere() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let environment = fixture.environment(userTrashPath: fixture.base.appendingPathComponent("User Trash").path)
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: "Ext"
        )
        XCTAssertEqual(review.externalVolumeNames, ["Ext"])

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertEqual(outcome.movedPaths.count, 1)
        XCTAssertEqual(outcome.notRestorableHereCount, 1)
        XCTAssertEqual(outcome.externalVolumeNames, ["Ext"])
        XCTAssertEqual(try fixture.journal.load().first?.summary.movedItemCount, 1, "The receipt is written as usual")
    }

    // MARK: - Links swapped in after the review (review P2-1, the reviewer's E1–E3)

    /// E1: the item itself became a link: skipped as a link, nothing followed.
    func testAnItemReplacedByALinkAfterTheReviewIsNotMovedNorFollowed() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let environment = fixture.environment()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review([try fixture.selection("big.zip", in: analysis.index)],
                                                     index: analysis.index, policy: policy,
                                                     environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.readyItems.count, 1)
        try FileManager.default.removeItem(at: fixture.url("big.zip"))
        try FileManager.default.createSymbolicLink(at: fixture.url("big.zip"), withDestinationURL: fixture.url("Docs/report.pdf"))

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertEqual(outcome.movedPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Docs/report.pdf").path), "Target untouched")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("big.zip").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
        XCTAssertEqual(try fixture.journal.load().first?.items.first?.outcome, .skipped(.symbolicLinkDetected))
    }

    /// E2: a parent became a link to where it went; through it the item is
    /// the very same file with the same stamp. Nothing moves.
    func testAParentReplacedByALinkAfterTheReviewIsNotMoved() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let environment = fixture.environment()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review([try fixture.selection("Media/photo.jpg", in: analysis.index)],
                                                     index: analysis.index, policy: policy,
                                                     environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.readyItems.count, 1)
        try FileManager.default.moveItem(at: fixture.url("Media"), to: fixture.url("Media-real"))
        try FileManager.default.createSymbolicLink(at: fixture.url("Media"), withDestinationURL: fixture.url("Media-real"))

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertEqual(outcome.movedPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Media-real/photo.jpg").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
    }

    /// The same before the review: only the review's own path check
    /// (`FileAnalysisTrashService.check`) can tell, since identity, stamp and
    /// size are those of the analyzed file.
    func testAParentReplacedByALinkBeforeTheReviewIsCaughtByTheReview() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        try FileManager.default.moveItem(at: fixture.url("Media"), to: fixture.url("Media-real"))
        try FileManager.default.createSymbolicLink(at: fixture.url("Media"), withDestinationURL: fixture.url("Media-real"))
        let environment = fixture.environment()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review([try fixture.selection("Media/photo.jpg", in: analysis.index)],
                                                     index: analysis.index, policy: policy,
                                                     environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.items.first?.status, .blocked(.changedSinceAnalysis))
    }

    /// The receipt layer's own path check (`RecordedTrashOperation`): a
    /// parent swapped for a link right after the service's last check, just
    /// before the move. Each of the two checks has its own test.
    func testAParentReplacedByALinkAfterTheLastCheckIsRefusedByTheReceiptLayer() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let swap = LinkSwapAfterNextSnapshot(original: fixture.url("Media"), movedTo: fixture.url("Media-real"))
        let environment = fixture.environment(metadata: swap)
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review([try fixture.selection("Media/photo.jpg", in: analysis.index)],
                                                     index: analysis.index, policy: policy,
                                                     environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.readyItems.count, 1)
        let checks = CheckCounter()

        let outcome = await FileAnalysisTrashService.execute(
            review.items, index: analysis.index, policy: policy, environment: environment,
            // The second check of the item: the swap follows its snapshot.
            beforeEachMove: { if checks.increment() == 2 { swap.arm() } }
        )

        XCTAssertTrue(swap.didSwap)
        XCTAssertEqual(outcome.movedPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Media-real/photo.jpg").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
    }

    /// E3: a checked folder became a link to its moved self; another was
    /// renamed away. Neither moves.
    func testAFolderReplacedByALinkOrRenamedAfterTheReviewIsNotMoved() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let environment = fixture.environment()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            try ["Docs", "Media"].map { try fixture.selection($0, in: analysis.index) },
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )
        XCTAssertEqual(review.readyItems.count, 2)
        try FileManager.default.moveItem(at: fixture.url("Docs"), to: fixture.url("Docs-real"))
        try FileManager.default.createSymbolicLink(at: fixture.url("Docs"), withDestinationURL: fixture.url("Docs-real"))
        try FileManager.default.moveItem(at: fixture.url("Media"), to: fixture.url("Media-renamed"))

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertEqual(outcome.movedPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Docs-real/Nested/deep.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Media-renamed/photo.jpg").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
        XCTAssertEqual(try fixture.journal.load().first?.items.map(\.outcome),
                       [.skipped(.symbolicLinkDetected), .skipped(.itemMissing)])
    }

    // MARK: - A receipt that cannot be written midway (review P2-2)

    func testAReceiptThatCannotBeWrittenMidwayStopsTheMoveAndThePageSaysSo() async throws {
        let fixture = try TrashFixture()
        let receipts = fixture.base.appendingPathComponent("Receipts", isDirectory: true)
        @Sendable func setReceiptFiles(_ mode: mode_t) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: receipts.path)) ?? [] {
                _ = chmod(receipts.appendingPathComponent(name).path, mode)
            }
        }
        defer {
            setReceiptFiles(0o600)
            fixture.remove()
        }
        let analysis = try fixture.analyze()
        let move = fixture.moveToFixtureTrash
        // After the first move the receipt files turn read-only, so the next
        // checkpoint cannot be written (the reviewer's E13).
        let environment = fixture.environment(moveToTrash: { url in
            let target = try move(url)
            setReceiptFiles(0o400)
            return target
        })
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            try ["big.zip", "cloud.bin"].map { try fixture.selection($0, in: analysis.index) },
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)
        setReceiptFiles(0o600)

        XCTAssertEqual(outcome.movedPaths, [fixture.url("big.zip").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("cloud.bin").path), "Second item kept")
        XCTAssertTrue(outcome.receiptIncomplete, "The page must not just say \"moved\"")
        XCTAssertFalse(outcome.receiptUnavailable)
        XCTAssertEqual(outcome.skipped.map(\.reason), ["操作记录写入失败，已停下，未处理"])
        XCTAssertTrue(FileAnalysisTrashPresentation.receiptIncompleteNote.hasPrefix("回执未写完，请在“操作记录”中核对"))
        let views = try source("Sources/StorageCleanerMac/Views/FileAnalysisTrashViews.swift")
        let bar = try XCTUnwrap(views.components(separatedBy: "private func outcomeRows(").last?
            .components(separatedBy: "private func outcomeTitle(").first)
        XCTAssertTrue(bar.contains("if outcome.receiptIncomplete {"))
        XCTAssertTrue(bar.contains("FileAnalysisTrashPresentation.receiptIncompleteNote"))
    }

    // MARK: - Operation History and the page

    func testOperationHistoryNamesTheMoveAndSaysWhereAnotherVolumesItemsAre() throws {
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        typealias P = OperationRecordPresentation
        XCTAssertEqual(P.title(rulesVersion: FileAnalysisTrashService.ruleID, subject: "big.zip", itemCount: 3),
                       "文件分析 · big.zip 等 3 项")
        XCTAssertEqual(P.title(rulesVersion: FileAnalysisTrashService.ruleID, subject: "Docs"), "文件分析 · Docs")
        XCTAssertEqual(P.title(rulesVersion: FileAnalysisTrashService.ruleID, subject: nil), "文件分析 · 移到废纸篓")
        XCTAssertTrue(P.offersRestore(rulesVersion: FileAnalysisTrashService.ruleID))

        let fixture = try TrashFixture()
        defer { fixture.remove() }
        func report(_ names: [String]) -> CleanReport {
            let items = names.map { name in
                CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: FileAnalysisTrashService.ruleID,
                                sourcePath: fixture.url(name).path, estimatedBytes: 1, outcome: .notProcessed)
            }
            return CleanReport(
                id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
                rulesVersion: FileAnalysisTrashService.ruleID, disposition: .trash, scanWasPartial: false,
                startedAt: Date(), completedAt: Date(), outcome: .completed, items: items,
                summary: CleanReportSummary(requestedItemCount: items.count, movedItemCount: 0, skippedItemCount: 0,
                    failedItemCount: 0, notProcessedItemCount: items.count, unverifiedMoveCount: 0, plannedBytes: 0,
                    movedToRecoverableLocationBytes: 0, reclaimableAfterEmptyingTrashBytes: 0,
                    permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil)
            )
        }
        let three = CleanupReportIndex(report: report(["big.zip", "Docs", "Media"]), orderingDate: Date())
        XCTAssertEqual(three.subject, "big.zip", "Stored without words, so a cached index follows the language")
        XCTAssertEqual(P.title(rulesVersion: three.rulesVersion, subject: three.subject,
                               itemCount: three.summary.requestedItemCount), "文件分析 · big.zip 等 3 项")
        XCTAssertEqual(CleanupReportIndex(report: report(["Docs"]), orderingDate: Date()).subject, "Docs")

        let trashHome = FileManager.default.homeDirectoryForCurrentUser
        let identity = FileIdentity(deviceID: 1, inode: 2, entryKind: .regularFile, creationTimeNanoseconds: 3)
        func receipt(_ target: String) -> CleanupMoveReceipt {
            CleanupMoveReceipt(originalPath: "/Volumes/Ext/a.mov", resultingItemURL: URL(fileURLWithPath: target),
                               disposition: .trash, movedIdentity: identity, verification: .identityVerified, movedAt: Date())
        }
        let userTrash = trashHome.appendingPathComponent(".Trash").path
        XCTAssertTrue(P.isInUserTrash(receipt(userTrash + "/a.mov"), userTrashPath: userTrash))
        XCTAssertFalse(P.isInUserTrash(receipt("/Volumes/Ext/.Trashes/501/a.mov"), userTrashPath: userTrash))
        XCTAssertEqual(P.otherTrashLabel, "在该卷的废纸篓中 · 请在访达中放回")

        let history = try source("Sources/StorageCleanerMac/Views/ReversibleOperationsView.swift")
        XCTAssertTrue(history.contains("itemCount: summary.summary.requestedItemCount"))
        XCTAssertTrue(history.contains("OperationRecordPresentation.isInUserTrash($0, userTrashPath: userTrashPath)"))
        XCTAssertTrue(history.contains("return OperationRecordPresentation.otherTrashLabel"))
    }

    /// D45/D46 page contract: list rows, column rows and blocks carry the
    /// checkbox (drawn like the cleanup results' group checkboxes, a lock
    /// when the item cannot move); the bar shows the count and size with the review
    /// button; the review lists name, path, size, folder contents and status
    /// and moves only from its own button.
    func testThePageOffersCheckboxesTheBarAndTheReview() throws {
        let map = try source("Sources/StorageCleanerMac/Views/StorageTreemapView.swift")
        XCTAssertEqual(map.components(separatedBy: "workspace.trashSelectionState(for: entry)").count - 1, 2,
                       "List rows and blocks ask for their state")
        XCTAssertTrue(map.contains("trashState: workspace.trashSelectionState(for:)"), "Column rows too")
        let row = try XCTUnwrap(map.components(separatedBy: "private struct StorageMapEntryRow: View {").last?
            .components(separatedBy: "private var entryButton").first)
        XCTAssertTrue(row.contains("FileAnalysisTrashCheckbox(state: trashState, title: entry.title,"), "Rows")
        let tile = try XCTUnwrap(map.components(separatedBy: "private struct StorageTreemapTile: View {").last?
            .components(separatedBy: "private struct StorageMapEntryRow: View {").first)
        XCTAssertTrue(tile.contains("FileAnalysisTrashCheckbox(state: trashState, title: entry.title,"), "Blocks")
        XCTAssertTrue(map.contains("FileAnalysisTrashBar(workspace: workspace)"))
        XCTAssertTrue(map.contains("FileAnalysisTrashReviewSheet(workspace: workspace, review: review)"))
        XCTAssertTrue(map.contains("FileAnalysisTrashPresentation.rowNote(state: trashState)"))

        let views = try source("Sources/StorageCleanerMac/Views/FileAnalysisTrashViews.swift")
        XCTAssertTrue(views.contains(".buttonStyle(ResponsivePlainButtonStyle())"))
        for symbol in ["\"square\"", "\"checkmark.square.fill\"", "\"checkmark.square\"", "\"lock.fill\""] {
            XCTAssertTrue(views.contains(symbol), symbol)
        }
        XCTAssertTrue(views.contains("FileAnalysisTrashPresentation.reviewAction"))
        XCTAssertTrue(views.contains("workspace.requestTrashReview()"))
        XCTAssertTrue(views.contains("Text(item.selection.path)"))
        XCTAssertTrue(views.contains("ByteFormat.storageString(item.selection.bytes)"))
        XCTAssertTrue(views.contains("FileAnalysisTrashPresentation.itemDetail(item.selection)"))
        XCTAssertEqual(views.components(separatedBy: "workspace.confirmTrash()").count - 1, 1,
                       "Only the review's own button moves anything")

        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(FileAnalysisTrashPresentation.selectionSummary(count: 3, bytes: 1_500_000),
                       "已选 3 项 · \(ByteFormat.storageString(1_500_000))", "The page's own size format")
        XCTAssertEqual(FileAnalysisTrashPresentation.reviewAction, "审阅并移到废纸篓")
        XCTAssertEqual(FileAnalysisTrashPresentation.itemDetail(FileAnalysisTrashSelection(
            path: "/x/Docs", title: "Docs", isDirectory: true, kind: "folder", bytes: 1, itemCount: 12
        )), "文件夹 · 含 12 项")
        XCTAssertEqual(FileAnalysisTrashPresentation.rowNote(state: .blocked(.standardFolder)), "系统标准文件夹")
        XCTAssertEqual(FileAnalysisTrashPresentation.rowNote(state: .includedInSelection("Docs")), "随“Docs”移走")
        XCTAssertNil(FileAnalysisTrashPresentation.rowNote(state: .available))
        XCTAssertTrue(FileAnalysisTrashPresentation.checkboxHelp(state: .blocked(.cloudStorage))
            .contains("请在访达或云盘应用中处理"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

// MARK: - Fixtures

/// A hidden isolated folder inside the home folder: `Analyzed` is the tree the
/// analysis reads, `Trash` stands in for the Trash and `Receipts` is an
/// isolated receipt journal.
struct TrashFixture {
    let base: URL
    let root: URL
    let trash: URL
    let journal: CleanupReportJournal

    var target: StorageMapScanTarget {
        StorageMapScanTarget(path: root.path, title: "Trash Fixture", kind: .homeDirectory)
    }

    init() throws {
        let fileManager = FileManager.default
        // 与 r2-fa-followups 的 def2321 一致：文件操作夹具不能放到系统临时目录。
        base = TestFileSystem.uniqueOperationRoot("file-analysis-trash-test")
        root = base.appendingPathComponent("Analyzed", isDirectory: true)
        trash = base.appendingPathComponent("Trash", isDirectory: true)
        journal = CleanupReportJournal(directory: base.appendingPathComponent("Receipts", isDirectory: true))
        do {
            for folder in ["Analyzed/Docs/Nested", "Analyzed/Media", "Analyzed/Tool.app/Contents/MacOS", "Trash"] {
                try fileManager.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for (path, bytes) in [
                ("Docs/report.pdf", 8_192), ("Docs/notes.txt", 100), ("Docs/Nested/deep.bin", 16_384),
                ("Media/photo.jpg", 65_536), ("Tool.app/Contents/MacOS/Tool", 1_024), ("big.zip", 32_768),
                ("gone.bin", 4_096), ("locked.bin", 4_096), ("cloud.bin", 4_096),
            ] {
                try Data(repeating: 0x5A, count: bytes).write(to: root.appendingPathComponent(path))
            }
            // 第 4 轮：Tool 的可执行文件存在，包类型不再决定应用判定。
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.example.tool", "CFBundlePackageType": "APPL"],
                format: .xml, options: 0
            ).write(to: root.appendingPathComponent("Tool.app/Contents/Info.plist"))
            try fileManager.createSymbolicLink(at: root.appendingPathComponent("link"),
                                               withDestinationURL: root.appendingPathComponent("Docs"))
        } catch {
            TestFileSystem.remove(base)
            throw error
        }
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func analyze() throws -> StorageMapAnalysisResult {
        try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target)
    }

    func allocatedBytes(_ relative: String) throws -> Int64 {
        let values = try url(relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    /// The selection the page makes for `relative`, from the index.
    func selection(_ relative: String, in index: StorageMapAnalysisIndex) throws -> FileAnalysisTrashSelection {
        let path = url(relative).path
        let entry = try XCTUnwrap(index.indexedEntry(at: path), relative)
        let aggregate = index.directories[path]
        return FileAnalysisTrashSelection(
            path: path, title: entry.name, isDirectory: entry.isDirectory, kind: entry.kind,
            bytes: entry.isDirectory ? aggregate?.sizeBytes ?? 0 : entry.sizeBytes ?? 0,
            itemCount: entry.isDirectory ? aggregate?.descendantItemCount : nil
        )
    }

    /// Moves into the fixture Trash, the way the Trash keeps its top level.
    var moveToFixtureTrash: @Sendable (URL) throws -> URL {
        { [trash] source in
            var destination = trash.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
    }

    /// The fixture's own folder stands in for the home folder (it holds
    /// `Analyzed`, as the real home folder holds this fixture), so the rules
    /// never read the real Library (r2-fa-followups P1-1). A test that needs
    /// Desktop, Documents or a Library passes a home inside the fixture.
    func environment(
        journal: CleanupReportJournal? = nil,
        moveToTrash: (@Sendable (URL) throws -> URL)? = nil,
        metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem(),
        excludedPaths: [String] = [],
        userTrashPath: String? = nil,
        homePath: String? = nil,
        isCloudFolder: @escaping @Sendable (URL) -> Bool = { _ in false },
        isReadOnlyVolume: @escaping @Sendable (URL) -> Bool = { _ in false },
        runningApplicationPaths: @escaping @MainActor @Sendable () -> [String] = { [] },
        mountPointPaths: @escaping @Sendable () -> [String] = { [] }
    ) -> FileAnalysisTrashEnvironment {
        var environment = FileAnalysisTrashEnvironment(
            journal: journal ?? self.journal,
            moveToTrash: moveToTrash ?? moveToFixtureTrash,
            metadata: metadata,
            homePath: homePath ?? base.path,
            appDataPath: base.appendingPathComponent("AppData").path,
            excludedPaths: { excludedPaths },
            isCloudFolder: isCloudFolder,
            isReadOnlyVolume: isReadOnlyVolume,
            userTrashPath: userTrashPath ?? trash.path
        )
        environment.runningApplicationPaths = runningApplicationPaths
        environment.mountPointPaths = mountPointPaths
        let fixtureHome = base.path
        environment.protectedLinkTargets = { home, appData in
            precondition(home == fixtureHome || home.hasPrefix(fixtureHome + "/"),
                         "A TrashFixture never reads a real home folder's Library")
            return FileAnalysisProtectedLinkResolver.locations(homePath: home, appDataPath: appData)
        }
        return environment
    }

    func lock(_ relative: String) throws {
        guard chflags(url(relative).path, UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError(.EPERM) }
    }

    func unlock(_ relative: String) {
        _ = chflags(url(relative).path, 0)
    }

    func remove() {
        _ = chflags(url("locked.bin").path, 0)
        TestFileSystem.remove(base)
    }
}

/// The real metadata, except that the given paths read as iCloud items.
struct CloudStandIn: ReadOnlyFileSystem {
    let cloudPaths: Set<String>
    private let real = FoundationReadOnlyFileSystem()

    func snapshot(at url: URL) throws -> FileSnapshot {
        let snapshot = try real.snapshot(at: url)
        guard cloudPaths.contains(url.path) else { return snapshot }
        return FileSnapshot(
            identity: snapshot.identity, standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier, logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume, isCloudItem: true, isCloudPlaceholder: false,
            hasSymbolicLinkComponent: snapshot.hasSymbolicLinkComponent
        )
    }

    func children(of directory: URL) throws -> [URL] { try real.children(of: directory) }
}

/// Switches the interface language through the volatile argument domain,
/// so nothing is written to a preferences file.
final class TrashLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        // L10n caches the language until defaults announce a change.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}

/// The real metadata; once armed, the next snapshot is taken and then a
/// folder is swapped for a link to where it moved.
final class LinkSwapAfterNextSnapshot: ReadOnlyFileSystem, @unchecked Sendable {
    private let real = FoundationReadOnlyFileSystem()
    private let lock = NSLock()
    private var armed = false
    private var swapped = false
    let original: URL
    let movedTo: URL

    init(original: URL, movedTo: URL) {
        self.original = original
        self.movedTo = movedTo
    }

    var didSwap: Bool { lock.withLock { swapped } }

    func arm() { lock.withLock { armed = true } }

    func snapshot(at url: URL) throws -> FileSnapshot {
        let snapshot = try real.snapshot(at: url)
        let swapNow: Bool = lock.withLock {
            defer { armed = false }
            return armed
        }
        if swapNow {
            try FileManager.default.moveItem(at: original, to: movedTo)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: movedTo)
            lock.withLock { swapped = true }
        }
        return snapshot
    }

    func aggregateSnapshot(at url: URL) throws -> FileSnapshot { try real.aggregateSnapshot(at: url) }
    func children(of directory: URL) throws -> [URL] { try real.children(of: directory) }
    func symbolicLinkDestination(of url: URL) throws -> String { try real.symbolicLinkDestination(of: url) }
}

/// Counts calls from any thread.
final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
