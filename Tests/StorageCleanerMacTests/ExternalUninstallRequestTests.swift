import Foundation
import XCTest
import UninstallHandoffShared
@testable import StorageCleanerMac

/// D88: Finder handoffs (open-documents with the installed Beta) resolve into
/// the inventory and then enter the one existing review (`requestUninstall`),
/// one application at a time.
@MainActor
final class ExternalUninstallRequestTests: XCTestCase {
    private func app(_ path: String, bundleID: String = "org.example.fixture") -> InstalledAppItem {
        InstalledAppItem(id: path, name: "Fixture", bundleIdentifier: bundleID, path: path,
            version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: 0,
            source: "fixture", modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)
    }

    private func opened(_ paths: [String]) -> [URL] { paths.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// A center whose file-system step is replaced; literal matches never reach it.
    private func makeCenter(fileSystem: ExternalUninstallMatch = .rejected(.notInInventory)) -> ExternalUninstallRequestCenter {
        let center = ExternalUninstallRequestCenter()
        center.showMainWindow = {}
        center.activateAttachedWindow = {}
        center.resolveOnFileSystem = { _, _ in fileSystem }
        return center
    }

    private func settle(_ center: ExternalUninstallRequestCenter) async {
        while let task = center.resolutionTask { await task.value }
    }

    // MARK: Resolver (temporary data fixture; nothing is moved)

    func testResolverFollowsSymlinkAndAliasIntoTheSameInventoryIdentity() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let real = root.appendingPathComponent("Applications/Real.app", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let alias = root.appendingPathComponent("Alias.app")
        let bookmark = try real.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let inventory = [app(real.path)]

        XCTAssertEqual(ExternalUninstallResolver.resolve(real.path, inventory: inventory), .application(inventory[0]))
        XCTAssertEqual(ExternalUninstallResolver.resolve(link.path, inventory: inventory), .application(inventory[0]))
        XCTAssertEqual(ExternalUninstallResolver.resolve(alias.path, inventory: inventory), .application(inventory[0]))
        XCTAssertEqual(ExternalUninstallResolver.resolve(real.path, inventory: []), .rejected(.notInInventory))
    }

    func testResolverRejectsMissingBrokenNonApplicationAndSystemPaths() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let target = root.appendingPathComponent("Gone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let broken = root.appendingPathComponent("Broken.app")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: target)
        try FileManager.default.removeItem(at: target)
        let notApp = root.appendingPathComponent("Folder.app")
        try FileManager.default.createSymbolicLink(at: notApp, withDestinationURL: root)
        let plainFile = root.appendingPathComponent("Document.app")
        try Data("not a bundle".utf8).write(to: plainFile)

        XCTAssertEqual(ExternalUninstallResolver.resolve(target.path, inventory: []), .rejected(.missing))
        XCTAssertEqual(ExternalUninstallResolver.resolve(broken.path, inventory: []), .rejected(.missing))
        XCTAssertEqual(ExternalUninstallResolver.resolve(notApp.path, inventory: []), .rejected(.notApplicationBundle))
        XCTAssertEqual(ExternalUninstallResolver.resolve(plainFile.path, inventory: [app(plainFile.path)]),
                       .rejected(.notApplicationBundle), "only an .app directory is an application")
        XCTAssertEqual(ExternalUninstallResolver.resolve("relative/X.app", inventory: []), .rejected(.handoff(.unnormalizedPath)))
        // Read-only lstat of an OS path; the system copy is never in the inventory.
        let system = "/System/Applications/Calculator.app"
        if FileManager.default.fileExists(atPath: system) {
            XCTAssertEqual(ExternalUninstallResolver.resolve(system, inventory: [app(system, bundleID: "com.apple.calculator")]),
                           .rejected(.systemApplication))
        }
    }

    func testLiteralMatchDecidesTheCommonCaseWithoutTheFileSystem() {
        // None of these paths exist; a literal decision must not need them.
        let listed = app("/Applications/Listed Fixture \(UUID().uuidString).app")
        XCTAssertEqual(ExternalUninstallResolver.literalMatch(listed.path + "/", inventory: [listed]), .application(listed))
        XCTAssertNil(ExternalUninstallResolver.literalMatch("/Applications/Other Fixture.app", inventory: [listed]))
        XCTAssertEqual(ExternalUninstallResolver.literalMatch("/System/Applications/X.app", inventory: [app("/System/Applications/X.app")]),
                       .rejected(.systemApplication))
        XCTAssertEqual(ExternalUninstallResolver.literalMatch("/tmp/notes.txt", inventory: []), .rejected(.notApplicationBundle))
        XCTAssertEqual(ExternalUninstallResolver.literalMatch("Applications/X.app", inventory: []), .rejected(.handoff(.unnormalizedPath)))
    }

    // MARK: Queue

    func testQueueRefreshesOnceThenFeedsOneReviewAtATime() async throws {
        let host = FakeUninstallHost()
        let center = makeCenter()
        var windowRequests = 0
        center.showMainWindow = { windowRequests += 1 }
        let first = app("/Applications/First.app"), running = app("/Applications/Running.app", bundleID: "org.example.running")
        center.attach(host)
        XCTAssertTrue(center.receive(openedURLs: opened([first.path, running.path, "/Applications/Unknown.app"])))
        XCTAssertEqual(windowRequests, 1)
        XCTAssertEqual(host.shownFilters, [.uninstall])
        XCTAssertEqual(host.refreshes, 1, "a Finder selection is matched against a fresh inventory")
        XCTAssertTrue(host.requested.isEmpty)

        // The refresh finishes: the first app enters the review, nothing else.
        host.isLoadingInstalledApps = false
        host.installedApps = [first, running]
        center.advance(host)
        XCTAssertEqual(host.requested.map(\.path), [first.path])
        XCTAssertEqual(host.refreshes, 1)
        // While its review is open the queue waits.
        center.advance(host)
        XCTAssertEqual(host.requested.count, 1)
        // Closing the review starts the next one; a running app is not
        // special-cased here: the review/execution chain decides.
        host.pendingUninstallApp = nil
        center.advance(host)
        XCTAssertEqual(host.requested.map(\.path), [first.path, running.path])
        XCTAssertNil(center.rejectionSummary)
        host.pendingUninstallApp = nil
        center.advance(host)
        await settle(center)
        XCTAssertEqual(host.requested.count, 2)
        let summary = try XCTUnwrap(center.rejectionSummary)
        XCTAssertTrue(summary.message.contains("Unknown.app"))
        XCTAssertTrue(center.queue.isEmpty)
        XCTAssertFalse(center.isBatchActive)
        XCTAssertTrue(host.selectedRelatedPaths.isEmpty, "the handoff never selects related files")
    }

    func testRequestsArrivingDuringABatchShareOneRefreshAndOnePageSwitch() async {
        let host = FakeUninstallHost()
        let center = makeCenter()
        var windowRequests = 0
        center.showMainWindow = { windowRequests += 1 }
        let a = app("/Applications/A.app"), b = app("/Applications/B.app"), c = app("/Applications/C.app")
        center.attach(host)
        center.receive(openedURLs: opened([a.path]))
        center.receive(openedURLs: opened([b.path, a.path]))
        XCTAssertEqual(host.refreshes, 1)
        XCTAssertEqual(center.queue, [a.path, b.path])
        host.installedApps = [a, b, c]
        host.isLoadingInstalledApps = false
        center.advance(host)
        XCTAssertEqual(host.requested.map(\.path), [a.path])
        // Arrives while a review is open: joins the batch, no second refresh.
        center.receive(openedURLs: opened([c.path]))
        XCTAssertEqual(host.refreshes, 1)
        host.pendingUninstallApp = nil
        center.advance(host)
        host.pendingUninstallApp = nil
        center.advance(host)
        host.pendingUninstallApp = nil
        center.advance(host)
        await settle(center)
        XCTAssertEqual(host.requested.map(\.path), [a.path, b.path, c.path])
        XCTAssertEqual(host.shownFilters, [.uninstall], "one page switch per batch")
        XCTAssertEqual(windowRequests, 1, "one window request per batch")
        XCTAssertNil(center.rejectionSummary)
        // A later, separate batch refreshes and presents again.
        center.receive(openedURLs: opened([a.path]))
        XCTAssertEqual(host.refreshes, 2)
        XCTAssertEqual(windowRequests, 2)
    }

    func testQueueAndRejectionListAreBounded() async throws {
        let host = FakeUninstallHost()
        host.hasScannedInstalledApps = true
        host.manageable = false
        let center = makeCenter()
        center.attach(host)
        // Held back while busy so everything below lands in one batch.
        host.isUninstallingApp = true
        let paths = (0..<40).map { "/Applications/Bounded\($0).app" }
        center.receive(FinderUninstallHandoff.Request(paths: paths, rejected: []))
        center.receive(FinderUninstallHandoff.Request(paths: [], rejected: (0..<100).map {
            .init(path: "/tmp/file\($0).txt", reason: .notApplicationBundle)
        }))
        XCTAssertEqual(center.queue.count, ExternalUninstallRequestCenter.maximumQueuedApplications)
        XCTAssertEqual(center.rejections.count, ExternalUninstallRequestCenter.maximumRejections)
        XCTAssertEqual(center.droppedRejectionCount, 8 + 100 - ExternalUninstallRequestCenter.maximumRejections)

        host.installedApps = paths.map { app($0) }
        host.isUninstallingApp = false
        center.advance(host)
        host.isLoadingInstalledApps = false
        center.advance(host)
        await settle(center)
        XCTAssertTrue(host.requested.isEmpty)
        let summary = try XCTUnwrap(center.rejectionSummary)
        // 8 over the queue limit + 100 handoff rejections + 32 unmanageable, 8 listed.
        XCTAssertTrue(summary.message.contains("132"), summary.message)
        XCTAssertEqual(summary.message.components(separatedBy: "\n").count, 1 + 8 + 1)
        XCTAssertEqual(center.rejections.count, 0)
        XCTAssertEqual(center.droppedRejectionCount, 0)
    }

    func testColdLaunchRequestWaitsForTheMainWindowThenOpens() {
        let host = FakeUninstallHost()
        let center = makeCenter()
        var windowRequests = 0, activations = 0
        center.showMainWindow = { windowRequests += 1 }
        center.activateAttachedWindow = { activations += 1 }
        // application(_:open:) before any window: nothing to show yet.
        XCTAssertTrue(center.receive(openedURLs: opened(["/Applications/Early.app"])))
        XCTAssertEqual(windowRequests, 0)
        XCTAssertEqual(center.queue, ["/Applications/Early.app"])
        XCTAssertEqual(host.refreshes, 0)
        // The main window attaches: the app is brought forward once and the
        // queue runs; no further window is requested (a second main window
        // appeared on a real cold launch).
        center.attach(host)
        XCTAssertEqual(windowRequests, 0)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(host.shownFilters, [.uninstall])
        XCTAssertEqual(host.refreshes, 1)
        host.installedApps = [app("/Applications/Early.app")]
        host.isLoadingInstalledApps = false
        center.advance(host)
        XCTAssertEqual(host.requested.map(\.path), ["/Applications/Early.app"])
        // A second attach (window re-created) does not present again.
        center.attach(host)
        XCTAssertEqual(windowRequests, 0)
        XCTAssertEqual(activations, 1)
    }

    func testRelatedFilesCleanupMakesTheQueueWaitInsteadOfRejecting() async {
        let host = FakeUninstallHost()
        host.hasScannedInstalledApps = true
        let first = app("/Applications/First.app"), second = app("/Applications/Second.app")
        host.installedApps = [first, second]
        let center = makeCenter()
        center.attach(host)
        center.receive(openedURLs: opened([first.path, second.path]))
        host.isLoadingInstalledApps = false
        center.advance(host)
        XCTAssertEqual(host.requested.map(\.path), [first.path])
        // The first uninstall finished and its related-files step follows:
        // ScanStore refuses new reviews meanwhile, so the queue must wait.
        host.pendingUninstallApp = nil
        host.pendingRelatedCleanupApp = first
        center.advance(host)
        XCTAssertEqual(host.requested.map(\.path), [first.path])
        host.pendingRelatedCleanupApp = nil
        host.isCleaningRelatedAppFiles = true
        center.advance(host)
        XCTAssertEqual(host.requested.map(\.path), [first.path], "still waiting while related files are cleaned")
        host.isCleaningRelatedAppFiles = false
        center.advance(host)
        XCTAssertEqual(host.requested.map(\.path), [first.path, second.path])
        host.pendingUninstallApp = nil
        center.advance(host)
        await settle(center)
        XCTAssertNil(center.rejectionSummary, "waiting is not a rejection")
        XCTAssertEqual(host.refreshes, 1)
    }

    func testFileSystemResolutionIsAsynchronous() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let real = root.appendingPathComponent("Applications/Linked.app", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let host = FakeUninstallHost()
        host.hasScannedInstalledApps = true
        let target = app(real.path)
        let center = ExternalUninstallRequestCenter()
        center.showMainWindow = {}
        center.activateAttachedWindow = {}
        center.attach(host)
        center.receive(openedURLs: [link])
        host.installedApps = [target]
        host.isLoadingInstalledApps = false
        center.advance(host)
        // No literal match: the default resolver runs as a task, not inline.
        XCTAssertNotNil(center.resolutionTask)
        XCTAssertTrue(host.requested.isEmpty)
        await settle(center)
        XCTAssertEqual(host.requested.map(\.path), [real.path])
    }

    func testUnmanageableAndInvalidEntriesAreReportedWithoutReview() async throws {
        let host = FakeUninstallHost()
        host.hasScannedInstalledApps = true
        let blocked = app("/Applications/Blocked.app")
        host.installedApps = [blocked]
        host.manageable = false
        let center = makeCenter(fileSystem: .rejected(.missing))
        center.attach(host)
        XCTAssertTrue(center.receive(openedURLs: opened([blocked.path]) + [URL(fileURLWithPath: "/tmp/notes.txt"),
                                                                            URL(string: "https://example.com/A.app")!]))
        XCTAssertEqual(host.refreshes, 1)
        host.isLoadingInstalledApps = false
        center.advance(host)
        await settle(center)
        XCTAssertTrue(host.requested.isEmpty)
        let message = try XCTUnwrap(center.rejectionSummary?.message)
        XCTAssertTrue(message.contains("Blocked.app"))
        XCTAssertTrue(message.contains("notes.txt"))
        XCTAssertFalse(message.contains("example.com"), "non-file URLs are ignored, not listed")
        XCTAssertFalse(center.receive(openedURLs: [URL(string: "https://example.com/?path=/Applications/A.app")!]))
    }

    func testRejectionSummaryHasItsOwnTitleAndSanitizedNames() {
        XCTAssertFalse(ExternalUninstallRejectionSummary.title.contains("操作失败"))
        XCTAssertFalse(ExternalUninstallRejectionSummary.title.contains("Operation Failed"))
        let hostile = "/Applications/Evil\n\u{202E}ppa.txt\u{0007}.app"
        let name = ExternalUninstallRejectionSummary.displayName(hostile)
        XCTAssertFalse(name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, name)
        XCTAssertEqual(name, "Evilppa.txt.app")
        let long = "/Applications/" + String(repeating: "长", count: 200) + ".app"
        let truncated = ExternalUninstallRejectionSummary.displayName(long)
        XCTAssertEqual(truncated.count, ExternalUninstallRejectionSummary.maximumNameLength)
        XCTAssertTrue(truncated.hasSuffix("…"))
        let summary = ExternalUninstallRejectionSummary(entries: [(hostile, .notInInventory)], droppedCount: 0)
        let lines = summary.message.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "a newline in a file name cannot add lines")
        XCTAssertEqual(lines[1], "• " + name + L10n.text("：", ": ") + ExternalUninstallRejection.notInInventory.title)
    }

    func testQueueWaitsForBusyUninstallFlowBeforeRefreshing() throws {
        let host = FakeUninstallHost()
        host.hasScannedInstalledApps = true
        host.isLoadingInstalledApps = false
        host.isUninstallingApp = true
        let center = makeCenter()
        center.attach(host)
        center.receive(FinderUninstallHandoff.Request(paths: ["/Applications/A.app"], rejected: []))
        XCTAssertEqual(host.refreshes, 0, "a running uninstall is never interrupted by a refresh")
        host.isUninstallingApp = false
        center.advance(host)
        XCTAssertEqual(host.refreshes, 1)
    }
}

@MainActor
private final class FakeUninstallHost: ExternalUninstallHost {
    var installedApps: [InstalledAppItem] = []
    var hasScannedInstalledApps = false
    var isLoadingInstalledApps = false
    var isUninstallingApp = false
    var isPreparingUninstall = false
    var isRestoringRecordedOperation = false
    var pendingUninstallApp: InstalledAppItem?
    var pendingRelatedCleanupApp: InstalledAppItem?
    var isCleaningRelatedAppFiles = false
    // Mirrors ScanStore: no refresh while an uninstall or related cleanup runs.
    var canRefreshInstalledApps: Bool {
        !isLoadingInstalledApps && !isUninstallingApp && !isCleaningRelatedAppFiles && pendingRelatedCleanupApp == nil
    }
    var manageable = true
    var refreshes = 0
    var requested: [InstalledAppItem] = []
    var shownFilters: [ReviewFilter] = []
    var selectedRelatedPaths = Set<String>()

    func canRequestUninstall(_ app: InstalledAppItem) -> Bool {
        manageable && !isCleaningRelatedAppFiles && pendingRelatedCleanupApp == nil
    }
    func requestUninstall(_ app: InstalledAppItem) {
        requested.append(app)
        pendingUninstallApp = app
    }
    func refreshInstalledApps(priority: TaskPriority) {
        refreshes += 1
        hasScannedInstalledApps = true
        isLoadingInstalledApps = true
    }
    func showFilter(_ filter: ReviewFilter) { shownFilters.append(filter) }
}
