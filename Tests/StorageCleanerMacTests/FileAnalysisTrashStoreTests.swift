import Foundation
import XCTest
@testable import StorageCleanerMac

/// D46 on the File Analysis page's store: checking items, the review, the
/// move, the map after the move (no new analysis), and the map after
/// Operation History puts items back. Fixtures only (`TrashFixture`): the
/// analyzed tree, the "Trash" and the receipt journal sit in a hidden
/// folder under the home folder; preferences go to a suite file inside it.
@MainActor
final class FileAnalysisTrashStoreTests: XCTestCase {
    func testCheckingFollowsTheRulesAndAFolderTakesInWhatIsInsideIt() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        try await install(try fixture.analyze(), in: store)
        let root = try XCTUnwrap(store.currentStorageMapSnapshot)
        func entry(_ name: String) throws -> StorageTreemapEntry {
            try XCTUnwrap(root.entries.first { $0.title == name }, name)
        }

        XCTAssertEqual(store.trashSelectionState(for: try entry("Tool.app")), .blocked(.applicationBundle))
        store.toggleTrashSelection(try entry("Tool.app"))
        XCTAssertEqual(store.trashSelections, [], "An app cannot be checked")
        XCTAssertEqual(store.trashNotice?.contains(FileAnalysisTrashBlock.applicationBundle.explanation), true)
        XCTAssertEqual(store.trashSelectionState(for: try entry("link")), .blocked(.symbolicLink))

        store.toggleTrashSelection(try entry("big.zip"))
        XCTAssertEqual(store.trashSelectionState(for: try entry("big.zip")), .selected)
        XCTAssertNil(store.trashNotice)

        // A file inside Docs, then Docs itself: the folder takes it in.
        let docs = try entry("Docs")
        let index = try XCTUnwrap(store.storageAnalysis?.index)
        let notes = try XCTUnwrap(try DiskScanner(excludedPaths: []).storageMapSnapshot(at: docs.path, using: index)
            .entries.first { $0.title == "notes.txt" })
        store.toggleTrashSelection(notes)
        store.toggleTrashSelection(docs)
        XCTAssertEqual(store.trashSelections.map(\.title), ["big.zip", "Docs"])
        XCTAssertEqual(store.trashSelectionState(for: notes), .includedInSelection("Docs"))
        store.toggleTrashSelection(notes)
        XCTAssertEqual(store.trashSelections.map(\.title), ["big.zip", "Docs"], "Inside a checked folder: no change")
        XCTAssertEqual(store.selectedTrashBytes, (try entry("big.zip")).sizeBytes + docs.sizeBytes)
        XCTAssertEqual(store.trashSelections.last?.itemCount, index.directories[docs.path]?.descendantItemCount)
        XCTAssertTrue(store.canReviewTrash)

        store.toggleTrashSelection(docs)
        XCTAssertEqual(store.trashSelections.map(\.title), ["big.zip"], "Clicking a checked item unchecks it")
        store.clearTrashSelection()
        XCTAssertEqual(store.trashSelections, [])
        XCTAssertFalse(store.canReviewTrash)
    }

    func testReviewThenMoveDropsTheItemsFromTheMapWithoutAnotherAnalysis() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        let original = try fixture.analyze()
        try await install(original, in: store)
        let root = try XCTUnwrap(store.currentStorageMapSnapshot)
        let docs = try XCTUnwrap(root.entries.first { $0.title == "Docs" })
        // Open Docs, so the page shows a level that changes.
        store.openStorageMapDirectory(docs)
        try await waitUntil("Docs is open") { store.storageMapNavigation.count == 2 }
        let notes = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "notes.txt" })
        let nested = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "Nested" })
        let bigZip = try XCTUnwrap(root.entries.first { $0.title == "big.zip" })
        store.toggleTrashSelection(notes)
        store.toggleTrashSelection(nested)
        store.toggleTrashSelection(bigZip)
        let selectedBytes = store.selectedTrashBytes

        store.requestTrashReview()
        try await waitUntil("the review is ready") { store.trashPhase == .reviewing }
        let review = try XCTUnwrap(store.trashReview)
        XCTAssertEqual(review.readyItems.count, 3)
        XCTAssertEqual(review.readyBytes, selectedBytes)

        store.confirmTrash()
        try await waitUntil("the move ends") { store.trashPhase == .idle && store.trashOutcome != nil }

        let outcome = try XCTUnwrap(store.trashOutcome)
        XCTAssertEqual(outcome.movedPaths.count, 3)
        XCTAssertEqual(outcome.movedBytes, selectedBytes)
        XCTAssertEqual(store.trashSelections, [], "The checked items are gone")
        XCTAssertNil(store.trashReview)
        for entry in [notes, nested, bigZip] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path), entry.title)
        }
        // The map: no new analysis, the moved items gone, sizes down.
        let analysis = try XCTUnwrap(store.storageAnalysis)
        XCTAssertNil(analysis.index.indexedEntry(at: notes.path))
        XCTAssertNil(analysis.index.directories[nested.path])
        XCTAssertEqual(analysis.rootSnapshot.measuredBytes, original.rootSnapshot.measuredBytes - selectedBytes)
        XCTAssertEqual(store.storageMapNavigation.count, 2, "Still inside Docs")
        XCTAssertEqual(store.currentStorageMapSnapshot?.entries.map(\.title).sorted(), ["report.pdf"])
        XCTAssertEqual(store.currentStorageMapSnapshot?.measuredBytes,
                       try XCTUnwrap(original.index.directories[docs.path]).sizeBytes - notes.sizeBytes - nested.sizeBytes)
        XCTAssertNil(store.storageMapNavigation.first?.entries.first { $0.title == "big.zip" })
        XCTAssertEqual(store.storageMapNavigation.first?.entries.first { $0.title == "Docs" }?.sizeBytes,
                       docs.sizeBytes - notes.sizeBytes - nested.sizeBytes)

        let report = try XCTUnwrap(try fixture.journal.load().first, "Receipts went to the fixture journal")
        XCTAssertEqual(report.rulesVersion, FileAnalysisTrashService.ruleID)
        XCTAssertEqual(report.restorableReceipts.count, 3)
    }

    func testARestoreFromOperationHistoryPutsTheItemsBackInTheMap() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        let original = try fixture.analyze()
        try await install(original, in: store)
        let root = try XCTUnwrap(store.currentStorageMapSnapshot)
        for name in ["Docs", "big.zip"] {
            store.toggleTrashSelection(try XCTUnwrap(root.entries.first { $0.title == name }))
        }
        store.requestTrashReview()
        try await waitUntil("the review is ready") { store.trashPhase == .reviewing }
        store.confirmTrash()
        try await waitUntil("the move ends") { store.trashPhase == .idle && store.trashOutcome != nil }
        XCTAssertNotEqual(store.storageAnalysis?.index, original.index)

        // Operation History's restore, then ScanStore tells the store.
        let report = try XCTUnwrap(try fixture.journal.load().first)
        let coordinator = HeavyWorkCoordinator()
        let service = CleanupRecoveryService()
        let journal = fixture.journal
        let trash = fixture.trash
        let restored = try await coordinator.withLease(owner: .restore) { lease in
            await service.restore(report: report, coordinator: coordinator, lease: lease,
                                  journal: journal, trashURL: trash)
        }
        XCTAssertEqual(restored.recovery.restoredCount, 2)
        store.operationHistoryDidRestore(restored.report.restorableReceiptsRestored)

        XCTAssertEqual(store.storageAnalysis?.index, original.index, "Back where they were, with their sizes")
        XCTAssertEqual(store.storageAnalysis?.rootSnapshot, original.rootSnapshot)
        XCTAssertEqual(store.currentStorageMapSnapshot, original.rootSnapshot)
        XCTAssertEqual(store.trashPutBackCount, 2)

        // A receipt for something else changes nothing.
        store.operationHistoryDidRestore(restored.report.restorableReceiptsRestored)
        XCTAssertEqual(store.storageAnalysis?.index, original.index)
    }

    func testAnItemPutBackAsSomethingElseIsNotCountedAgain() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        try await install(try fixture.analyze(), in: store)
        let bigZip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })
        store.toggleTrashSelection(bigZip)
        store.requestTrashReview()
        try await waitUntil("the review is ready") { store.trashPhase == .reviewing }
        store.confirmTrash()
        try await waitUntil("the move ends") { store.trashPhase == .idle && store.trashOutcome != nil }
        let moved = try XCTUnwrap(try fixture.journal.load().first?.restorableReceipts)

        // Another file now has the name; the receipt's item did not come back.
        try Data("someone else's archive".utf8).write(to: fixture.url("big.zip"))
        store.operationHistoryDidRestore(moved)

        XCTAssertNil(store.storageAnalysis?.index.indexedEntry(at: bigZip.path))
        XCTAssertEqual(store.trashPutBackCount, 0)
    }

    func testANewAnalysisStartsWithoutTheOldCheckedItems() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        try await install(try fixture.analyze(), in: store)
        let bigZip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })
        store.toggleTrashSelection(bigZip)
        XCTAssertEqual(store.trashSelections.count, 1)

        store.replaceStorageAnalysisForTesting(try fixture.analyze())

        XCTAssertEqual(store.trashSelections, [])
        XCTAssertNil(store.trashOutcome)
        XCTAssertEqual(store.trashPolicy?.rootPath, fixture.root.path)
    }

    // MARK: - Review fixes

    /// Review P2-12: until iCloud's Desktop and Documents are known, items
    /// there read "checking" and cannot be checked; then they follow the rules.
    func testItemsWaitWhileICloudIsBeingCheckedAndFollowTheAnswer() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        for folder in ["Desktop", "Documents"] {
            try FileManager.default.createDirectory(at: fixture.url(folder), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 4_096).write(to: fixture.url("Desktop/shot.png"))
        try Data(repeating: 2, count: 4_096).write(to: fixture.url("Documents/report.pdf"))
        let gate = RefinementGate()
        defer { gate.open() }
        let documents = fixture.url("Documents").path
        // The analyzed folder stands in for the home folder.
        let environment = fixture.environment(homePath: fixture.root.path, isCloudFolder: { url in
            gate.wait()
            return url.path == documents
        })
        let store = try makeStore(fixture, environment: environment)
        store.replaceStorageAnalysisForTesting(try fixture.analyze())
        // P1-1: the links are found first (off the main thread); iCloud waits.
        try await waitUntil("the links are known") { store.trashPolicy?.awaitsProtectedLinkTargets == false }
        let index = try XCTUnwrap(store.storageAnalysis?.index)
        let scanner = DiskScanner(excludedPaths: [])
        let shot = try XCTUnwrap(try scanner.storageMapSnapshot(at: fixture.url("Desktop").path, using: index)
            .entries.first { $0.title == "shot.png" })
        let report = try XCTUnwrap(try scanner.storageMapSnapshot(at: documents, using: index)
            .entries.first { $0.title == "report.pdf" })
        let bigZip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })

        XCTAssertEqual(store.trashSelectionState(for: shot), .checking(.iCloud))
        XCTAssertEqual(store.trashSelectionState(for: report), .checking(.iCloud))
        XCTAssertEqual(store.trashSelectionState(for: bigZip), .available, "Elsewhere nothing waits")
        store.toggleTrashSelection(report)
        XCTAssertEqual(store.trashSelections, [], "Cannot be checked while checking")
        XCTAssertEqual(store.trashNotice?.contains("iCloud"), true)
        store.toggleTrashSelection(bigZip)
        XCTAssertTrue(store.canReviewTrash, "不依赖 iCloud 判定的勾选可立即审阅")
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(store.trashRefinementNotice, "正在确认 iCloud 状态…")
        store.requestTrashReview()
        try await waitUntil("其他项目可以审阅") { store.trashPhase == .reviewing }
        XCTAssertEqual(store.trashReview?.readyItems.map(\.selection.title), ["big.zip"])
        store.cancelTrashReview()

        gate.open()
        try await waitUntil("iCloud is known") { store.trashPolicy?.isRefined == true }
        XCTAssertEqual(store.trashSelectionState(for: report), .blocked(.cloudStorage))
        XCTAssertEqual(store.trashSelectionState(for: shot), .available)
        XCTAssertTrue(store.canReviewTrash)
        XCTAssertNil(store.trashRefinementNotice)
    }

    /// r2-fa-followups P1-1: the D54 locations reached through links are
    /// found off the main thread. The page draws at once; every item no
    /// other rule blocks waits ("checking") until they are known.
    func testProtectedLinksAreFoundOffTheMainThreadWhileItemsWait() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let gate = RefinementGate()
        defer { gate.open() }
        let calls = ResolverCalls()
        var environment = fixture.environment()
        let resolve = environment.protectedLinkTargets
        environment.protectedLinkTargets = { home, appData in
            calls.record(onMainThread: pthread_main_np() != 0)
            gate.wait()
            return resolve(home, appData)
        }
        let store = try makeStore(fixture, environment: environment)
        let analysis = try fixture.analyze()
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }

        let start = ContinuousClock.now
        store.replaceStorageAnalysisForTesting(analysis)
        // The resolver is held for up to 10 s; on the main thread this would wait.
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        let root = try XCTUnwrap(store.currentStorageMapSnapshot)
        let bigZip = try XCTUnwrap(root.entries.first { $0.title == "big.zip" })
        let tool = try XCTUnwrap(root.entries.first { $0.title == "Tool.app" })
        XCTAssertEqual(store.trashSelectionState(for: bigZip), .checking(.protectedLocations))
        XCTAssertEqual(store.trashSelectionState(for: tool), .blocked(.applicationBundle), "Other rules show at once")
        XCTAssertEqual(store.trashRefinementNotice, "正在核对受保护的位置…")
        store.toggleTrashSelection(bigZip)
        XCTAssertEqual(store.trashSelections, [], "Cannot be checked while the links are looked for")
        XCTAssertEqual(store.trashNotice, "正在核对受保护的位置，请稍候再勾选“big.zip”。")
        XCTAssertFalse(store.canReviewTrash)
        XCTAssertTrue(FileAnalysisTrashPresentation.checkboxHelp(state: .checking(.protectedLocations)).contains("链接"))

        gate.open()
        try await waitUntil("the links are known") { store.trashPolicy?.isRefined == true }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.onMainThread, 0, "Never on the main thread")
        XCTAssertEqual(store.trashSelectionState(for: bigZip), .available)
        XCTAssertNil(store.trashRefinementNotice)
        store.toggleTrashSelection(bigZip)
        XCTAssertEqual(store.trashSelections.map(\.title), ["big.zip"])
    }

    /// r2-fa-followups P2-1: a folder named like an app (the scanner calls it
    /// a package) reads as an app until its Info.plist is read off the main
    /// thread; then it can be checked. A real app stays blocked.
    func testAFolderNamedLikeAnAppBecomesCheckableOnceItsInfoPlistIsRead() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let storage = fixture.url("HTTPStorages/com.example.app")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4_096).write(to: storage.appendingPathComponent("httpstorage.sqlite"))
        let gate = RefinementGate()
        defer { gate.open() }
        var environment = fixture.environment()
        let resolve = environment.protectedLinkTargets
        environment.protectedLinkTargets = { home, appData in
            gate.wait()
            return resolve(home, appData)
        }
        let store = try makeStore(fixture, environment: environment)
        store.replaceStorageAnalysisForTesting(try fixture.analyze())
        let index = try XCTUnwrap(store.storageAnalysis?.index)
        let folder = try XCTUnwrap(try DiskScanner(excludedPaths: []).storageMapSnapshot(
            at: fixture.url("HTTPStorages").path, using: index).entries.first { $0.title == "com.example.app" })
        let tool = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "Tool.app" })
        XCTAssertEqual(folder.kind, "package")
        XCTAssertEqual(store.trashSelectionState(for: folder), .blocked(.applicationBundle), "Until it is read")

        gate.open()
        try await waitUntil("the rules are known") { store.trashPolicy?.isRefined == true }
        XCTAssertEqual(store.trashSelectionState(for: folder), .available)
        XCTAssertEqual(store.trashSelectionState(for: tool), .blocked(.applicationBundle))
        store.toggleTrashSelection(folder)
        XCTAssertEqual(store.trashSelections.map(\.title), ["com.example.app"])

        // Main-session ruling: the row's category and the review follow the
        // same rule, so it no longer reads as an app.
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(folder.contentCategory, .data)
        XCTAssertEqual(tool.contentCategory, .application)
        let selection = try XCTUnwrap(store.trashSelections.first)
        XCTAssertEqual(FileAnalysisTrashPresentation.itemDetail(selection), "文件夹 · 含 1 项")
        XCTAssertTrue(selection.presentsAsFolder)
    }

    /// r2-fa-followups P1-1: a TrashFixture's rules read the fixture's own
    /// folder as the home folder, never the real Library.
    func testTrashFixturesUseTheirOwnHomeFolder() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let environment = fixture.environment()
        XCTAssertEqual(environment.homePath, fixture.base.path)
        XCTAssertNotEqual(environment.homePath, PathSafety.lexicalHomePath)
        let policy = FileAnalysisTrashService.policy(for: try fixture.analyze(), environment: environment)
        XCTAssertEqual(policy.homePath, fixture.base.path)
        XCTAssertEqual(policy.protectedLinkTargets, [])
        XCTAssertTrue(policy.isRefined)
    }

    /// D54 ③ and review P2-12: an app that starts inside a checked folder
    /// unchecks it the next time the page looks, and says why.
    func testACheckedFolderWhereAnAppStartsIsUncheckedWithTheReason() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("Build/Demo.app/Contents"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_048).write(to: fixture.url("Build/Demo.app/Contents/Demo"))
        let running = RunningAppsStandIn()
        let store = try makeStore(fixture, environment: fixture.environment(runningApplicationPaths: { running.paths }))
        try await install(try fixture.analyze(), in: store)
        let root = try XCTUnwrap(store.currentStorageMapSnapshot)
        let build = try XCTUnwrap(root.entries.first { $0.title == "Build" })
        let bigZip = try XCTUnwrap(root.entries.first { $0.title == "big.zip" })
        store.toggleTrashSelection(build)
        XCTAssertEqual(store.trashSelections.map(\.title), ["Build"])

        running.paths = [fixture.url("Build/Demo.app").path]
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        store.toggleTrashSelection(bigZip)

        XCTAssertEqual(store.trashSelections.map(\.title), ["big.zip"])
        XCTAssertEqual(store.trashSelectionState(for: build), .blocked(.containsRunningApplication))
        XCTAssertEqual(store.trashNotice, "已取消勾选“Build”：含正在运行的应用。")
    }

    /// Review P2-8: after "Stop", what was not reached stays checked.
    func testStopKeepsWhatWasNotReachedChecked() async throws {
        let fixture = try TrashFixture()
        let gate = FolderCheckGate()
        defer {
            gate.release()
            fixture.remove()
        }
        var environment = fixture.environment()
        environment.verificationOptions = DiskScanner.StorageMapAnalysisOptions(
            concurrency: 1, ubiquityLookup: .everyItem, cloudState: .custom { gate.cloudState(of: $0) }
        )
        let store = try makeStore(fixture, environment: environment)
        try await install(try fixture.analyze(), in: store)
        let root = try XCTUnwrap(store.currentStorageMapSnapshot)
        for name in ["Docs", "big.zip"] {
            store.toggleTrashSelection(try XCTUnwrap(root.entries.first { $0.title == name }))
        }
        store.requestTrashReview()
        try await waitUntil("the review is ready") { store.trashPhase == .reviewing }
        store.confirmTrash()
        try await waitUntil("the folder check is under way") { gate.isBlocked }
        // Review P2-11: the folder being compared shows at once.
        try await waitUntil("the folder's title shows") { store.trashProgress?.verifyingTitle == "Docs" }
        store.stopTrashMove()
        gate.release()
        try await waitUntil("the move ends") { store.trashPhase == .idle && store.trashOutcome != nil }

        XCTAssertEqual(store.trashOutcome?.cancelled, true)
        XCTAssertEqual(store.trashOutcome?.movedPaths, [])
        XCTAssertEqual(store.trashSelections.map(\.title), ["Docs", "big.zip"], "Still checked")
        XCTAssertTrue(store.canReviewTrash)
    }

    /// Review P2-10: a move that cannot start says why in people's words;
    /// cancelling the review clears it.
    func testAMoveThatCannotStartSaysWhyAndCancellingClearsIt() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let coordinator = HeavyWorkCoordinator()
        let store = try makeStore(fixture, coordinator: coordinator)
        try await install(try fixture.analyze(), in: store)
        let bigZip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })
        store.toggleTrashSelection(bigZip)
        store.requestTrashReview()
        try await waitUntil("the review is ready") { store.trashPhase == .reviewing }
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        let held = try await coordinator.acquire(owner: .duplicateScan)

        store.confirmTrash()
        try await waitUntil("the move gives up") { store.trashPhase == .reviewing && store.trashNotice != nil }
        await coordinator.release(held)

        XCTAssertEqual(store.trashNotice, HeavyWorkActivityStore.conflictMessage(activeOwner: .duplicateScan))
        XCTAssertNil(store.trashNoticeDetail)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bigZip.path))
        store.cancelTrashReview()
        XCTAssertNil(store.trashNotice, "Nothing stale stays in the bar")
        XCTAssertNil(store.trashNoticeDetail)

        // Any other failure: the people's words; the system's own only
        // under "Details".
        let storeSource = try source("Sources/StorageCleanerMac/Features/LargeFiles/Stores/LargeFilesStore.swift")
        let confirm = try XCTUnwrap(storeSource.components(separatedBy: "func confirmTrash()").last?
            .components(separatedBy: "func stopTrashMove()").first)
        XCTAssertFalse(confirm.contains("localizedDescription"))
        XCTAssertTrue(confirm.contains("self.reportTrashMoveFailure(error)"))
        let report = try XCTUnwrap(confirm.components(separatedBy: "private func reportTrashMoveFailure(").last)
        XCTAssertTrue(report.contains("trashNotice = FileAnalysisTrashPresentation.moveDidNotStart"))
        XCTAssertTrue(report.contains("trashNoticeDetail = FileAnalysisTrashPresentation.moveFailureDetail(error)"))
        XCTAssertFalse(report.contains("String(describing: error)"))
        let views = try source("Sources/StorageCleanerMac/Views/FileAnalysisTrashViews.swift")
        XCTAssertTrue(views.contains("if let detail = workspace.trashNoticeDetail {"))
        XCTAssertTrue(views.contains("DisclosureGroup(L10n.text(\"详情\", \"Details\"))"))
        XCTAssertTrue(FileAnalysisTrashPresentation.moveDidNotStart.hasPrefix("没能开始移到废纸篓"))
    }

    /// Review P2-9: after a move nothing keeps pointing at what moved.
    func testAMovedHighlightIsDropped() throws {
        let moved = ["/x/Docs", "/x/big.zip"]
        XCTAssertTrue(StorageTreemapPresentation.isGone("/x/Docs", after: moved))
        XCTAssertTrue(StorageTreemapPresentation.isGone("/x/Docs/Nested/deep.bin", after: moved))
        XCTAssertTrue(StorageTreemapPresentation.isGone("/x/big.zip", after: moved))
        XCTAssertFalse(StorageTreemapPresentation.isGone("/x/Docs2", after: moved))
        XCTAssertFalse(StorageTreemapPresentation.isGone(nil, after: moved))
        XCTAssertFalse(StorageTreemapPresentation.isGone("/x/Media", after: moved))

        let map = try source("Sources/StorageCleanerMac/Views/StorageTreemapView.swift")
        let handler = try XCTUnwrap(map.components(separatedBy: ".onChange(of: workspace.trashOutcome?.movedPaths ?? [])").last?
            .components(separatedBy: ".animation(").first)
        for line in ["selectedEntryID = nil", "selectedMapEntry = nil", "hoveredMapEntry = nil", "quickLookURL = nil"] {
            XCTAssertTrue(handler.contains(line), line)
        }
    }

    /// Review P2-11: the "moves with" note takes its own line instead of
    /// being cut to "随…", and the progress shows a new folder at once.
    func testTheRowNoteWrapsAndANewFolderShowsAtOnce() throws {
        let map = try source("Sources/StorageCleanerMac/Views/StorageTreemapView.swift")
        let row = try XCTUnwrap(map.components(separatedBy: "private struct StorageMapEntryRow: View {").last)
        XCTAssertTrue(row.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(row.contains(".truncationMode(.middle)"))
        XCTAssertTrue(row.contains(".help(FileAnalysisTrashPresentation.checkboxHelp(state: trashState))"))
        XCTAssertTrue(row.contains(".frame(minHeight: 48, alignment: .leading)"))
        XCTAssertFalse(row.contains(".frame(height: 48, alignment: .leading)"))
        XCTAssertTrue(row.contains(".lineLimit(FileAnalysisTrashPresentation.rowNoteLineLimit(state: trashState))"))
        XCTAssertEqual(FileAnalysisTrashPresentation.rowNoteLineLimit(state: .includedInSelection("Old Projects")), 2)

        let delivered = DeliveredProgress()
        let relay = FileAnalysisTrashProgressRelay { delivered.append($0) }
        relay.deliver(FileAnalysisTrashProgress(processed: 0, total: 2))
        relay.deliver(FileAnalysisTrashProgress(processed: 0, total: 2, verifyingTitle: "Docs"))
        relay.deliver(FileAnalysisTrashProgress(processed: 0, total: 2, verifyingTitle: "Docs", verifiedItemCount: 5))
        XCTAssertEqual(delivered.items.map(\.verifyingTitle), [nil, "Docs"], "A new title at once; counts at most 10/s")

        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        for check in [FileAnalysisTrashPendingCheck.iCloud, .volume, .protectedLocations] {
            XCTAssertEqual(FileAnalysisTrashPresentation.rowNote(state: .checking(check)), "检查中")
        }
        let views = try source("Sources/StorageCleanerMac/Views/FileAnalysisTrashViews.swift")
        XCTAssertTrue(views.contains("case .checking: \"clock\""))
    }

    /// 生产构造仍默认 live；D48 / N26 允许 ScanStore 将测试注入的环境向下传递。
    func testTheAppMovesWithTheLiveJournalAndTheRealTrash() throws {
        let scanStore = try source("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let creation = try XCTUnwrap(ExternalMigrationReceiptTests.argumentLists(of: "LargeFilesStore(", in: scanStore).first)
        XCTAssertTrue(creation.contains("trashEnvironment: fileAnalysisTrashEnvironment"), creation)
        XCTAssertTrue(scanStore.contains("fileAnalysisTrashEnvironment: FileAnalysisTrashEnvironment = .live"))
        let store = try source("Sources/StorageCleanerMac/Features/LargeFiles/Stores/LargeFilesStore.swift")
        XCTAssertTrue(store.contains("trashEnvironment: FileAnalysisTrashEnvironment = .live"))
        let service = try source("Sources/StorageCleanerMac/Features/LargeFiles/Services/FileAnalysisTrashService.swift")
        XCTAssertTrue(service.contains("journal: .live,"))
        XCTAssertTrue(service.contains("try FileManager.default.trashItem(at: source, resultingItemURL: &target)"))
        let live = FileAnalysisTrashEnvironment.live
        XCTAssertEqual(live.journal.directory.standardizedFileURL, CleanupReportJournal.live.directory.standardizedFileURL)
        XCTAssertEqual(live.userTrashPath, PathSafety.lexicalPath(CleanupService.userTrashURL().path))
    }

    // MARK: - Helpers

    private func makeStore(
        _ fixture: TrashFixture,
        environment: FileAnalysisTrashEnvironment? = nil,
        coordinator: HeavyWorkCoordinator = HeavyWorkCoordinator()
    ) throws -> LargeFilesStore {
        LargeFilesStore(
            coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self),
            storageMapTargets: [],
            trashEnvironment: environment ?? fixture.environment()
        )
    }

    /// The store with `analysis`, once iCloud and the volume are known
    /// (review P2-12: until then the review waits).
    private func install(_ analysis: StorageMapAnalysisResult, in store: LargeFilesStore) async throws {
        store.replaceStorageAnalysisForTesting(analysis)
        try await waitUntil("the rules are known") { store.trashPolicy?.isRefined == true }
    }

    private struct Timeout: Error {}

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting until \(what)")
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private extension CleanReport {
    /// The moved receipts this restore put back, as ScanStore passes them.
    var restorableReceiptsRestored: [CleanupMoveReceipt] {
        let restored = Set((recoveryAttempts ?? []).flatMap(\.items).filter { $0.outcome == .restored }.map(\.originalPath))
        return items.compactMap {
            guard case .moved(let receipt) = $0.outcome, restored.contains(receipt.originalPath) else { return nil }
            return receipt
        }
    }
}

/// Holds the iCloud question of a policy refinement until opened.
final class RefinementGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var finished = false
    var waitFinished: Bool {
        condition.lock(); defer { condition.unlock() }
        return finished
    }

    func wait() {
        condition.lock()
        let deadline = Date().addingTimeInterval(10)
        while !isOpen && condition.wait(until: deadline) {}
        finished = true
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Counts the link resolver's calls and those made on the main thread
/// (r2-fa-followups P1-1).
final class ResolverCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var mainThreadCalls = 0
    var count: Int { lock.withLock { calls } }
    var onMainThread: Int { lock.withLock { mainThreadCalls } }
    func record(onMainThread: Bool) {
        lock.withLock {
            calls += 1
            if onMainThread { mainThreadCalls += 1 }
        }
    }
}

/// Holds the first cloud lookup of a folder comparison until released (the
/// reviewer's `ReviewVerifyGate`).
final class FolderCheckGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false

    var isBlocked: Bool {
        condition.lock(); defer { condition.unlock() }
        return blocked
    }

    func cloudState(of url: URL) -> DiskScanner.StorageMapCloudState {
        condition.lock()
        if !blocked {
            blocked = true
            let deadline = Date().addingTimeInterval(10)
            while !released && condition.wait(until: deadline) {}
        }
        condition.unlock()
        return DiskScanner.StorageMapCloudState(isUbiquitous: false, isCurrent: true)
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Progress the relay handed on.
final class DeliveredProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: [FileAnalysisTrashProgress] = []
    var items: [FileAnalysisTrashProgress] { lock.withLock { delivered } }
    func append(_ progress: FileAnalysisTrashProgress) { lock.withLock { delivered.append(progress) } }
}
