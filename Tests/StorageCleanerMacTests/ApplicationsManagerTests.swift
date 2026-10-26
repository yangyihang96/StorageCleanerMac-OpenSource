import Foundation
import XCTest
@testable import StorageCleanerMac

/// CleanMyMac's uninstaller rules as rebuilt here: selection, requests,
/// removal into an isolated Trash with receipts, leftovers and installers.
final class ApplicationsManagerTests: XCTestCase {
    // MARK: Fixtures

    private func writeApplication(at url: URL, identifier: String, name: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleExecutable": name,
                                   "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/\(name)"))
    }

    private func resource(_ path: String, _ group: ApplicationResourceGroup, removable: Bool = true,
                          evidence: ApplicationResourceEvidence = .bundleIdentifier) -> ApplicationResource {
        ApplicationResource(path: path, group: group, evidence: evidence, domain: .user, kind: .file,
                            sizeBytes: 100, identity: nil, isRemovable: removable, note: nil)
    }

    private func entry(id: String, name: String, protected: Bool = false) -> ApplicationEntry {
        let path = protected ? "/System/Applications/\(name).app" : "/Applications/\(name).app"
        let item = InstalledAppItem(id: path, name: name, bundleIdentifier: id, path: path, version: "1", build: "1",
                                    category: "", appDescription: "", sizeBytes: 1_000, source: "", modifiedAt: nil,
                                    relatedPaths: [], relatedItems: [], status: .installed)
        var resources = [
            resource(path, .binaries, removable: !protected, evidence: .bundle),
            resource("/Users/me/Library/Caches/\(id)", .caches),
            resource("/Users/me/Library/Preferences/\(id).plist", .preferences),
        ]
        resources.append(resource("/Library/Receipts/\(id).bom", .installers, removable: false))
        return ApplicationEntry(item: item, profile: nil,
            classification: ApplicationClassification(store: .other, vendor: .other, isUnused: false,
                                                      isThirtyTwoBitOnly: false, suspiciousReason: nil),
            resources: resources, isThisApplication: false)
    }

    // MARK: Selection

    @MainActor
    func testAppCheckboxSelectsEverythingRemovableAndBinaryOutMeansReset() {
        let model = ApplicationsManagerModel()
        let photon = entry(id: "com.example.photon", name: "Photon")
        model.replaceEntries([photon])
        model.toggle(photon)
        XCTAssertEqual(model.selectionState(of: photon), .all)
        XCTAssertEqual(model.selection[photon.id]?.count, 3, "binary, cache and preferences; the receipt is not removable")
        XCTAssertEqual(model.selectionSummary.applications, 1)
        XCTAssertEqual(model.primaryActionTitle, L10n.text("卸载所选", "Uninstall Selected"))
        let requests = model.buildRequests()
        XCTAssertEqual(requests.first?.purpose, .uninstall)
        XCTAssertEqual(requests.first?.resources.count, 2)

        // Leaving the binary out keeps the app: CleanMyMac's reset.
        let binary = photon.resources!.first { $0.group == .binaries }!
        model.toggle(binary, in: photon)
        XCTAssertEqual(model.selectionState(of: photon), .partial)
        XCTAssertEqual(model.selectionSummary.applications, 0)
        XCTAssertEqual(model.selectionSummary.items, 2)
        XCTAssertEqual(model.buildRequests().first?.purpose, .reset)
        XCTAssertEqual(model.primaryActionTitle, L10n.text("移除所选", "Remove Selected"))

        model.toggle(photon)
        XCTAssertEqual(model.selectionState(of: photon), .all)
        model.toggle(photon)
        XCTAssertEqual(model.selectionState(of: photon), .none)
        XCTAssertTrue(model.buildRequests().isEmpty)
    }

    @MainActor
    func testProtectedSystemAppSelectsOnlyItsRelatedFiles() {
        let model = ApplicationsManagerModel()
        let chess = entry(id: "com.apple.Chess", name: "Chess", protected: true)
        model.replaceEntries([chess])
        model.toggle(chess)
        XCTAssertEqual(model.selectionState(of: chess), .all)
        XCTAssertFalse(model.selection[chess.id]!.contains(chess.bundleResourceID))
        XCTAssertEqual(model.buildRequests().first?.purpose, .reset)
    }

    /// D151 review: an item the finder lists but does not offer (another
    /// vendor's shared group) cannot be checked by the app, its group or
    /// itself, and never reaches a removal request.
    @MainActor
    func testListedButNotOfferedItemsNeverEnterTheSelectionOrARequest() {
        let model = ApplicationsManagerModel()
        let base = entry(id: "com.example.photon", name: "Photon")
        let shared = ApplicationResource(
            path: "/Users/me/Library/Group Containers/group.com.othervendor.shared", group: .container,
            evidence: .applicationGroup, domain: .user, kind: .file, sizeBytes: 100, identity: nil,
            isRemovable: false, note: ApplicationResourceFinder.sharedGroupNote)
        let photon = ApplicationEntry(item: base.item, profile: nil, classification: base.classification,
                                      resources: (base.resources ?? []) + [shared], isThisApplication: false)
        model.replaceEntries([photon])
        model.toggle(photon)
        XCTAssertEqual(model.selectionState(of: photon), .all, "everything removable is checked")
        XCTAssertFalse(model.isSelected(shared, in: photon))
        model.toggle(shared, in: photon)
        XCTAssertFalse(model.isSelected(shared, in: photon), "the item itself cannot be checked")
        model.toggle(group: .container, in: photon)
        XCTAssertFalse(model.isSelected(shared, in: photon), "nor through its group")
        let requests = model.buildRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.flatMap(\.resources).contains { $0.path == shared.path })
    }

    @MainActor
    func testGroupCheckboxAndCategoryCounts() {
        let model = ApplicationsManagerModel()
        var unused = entry(id: "com.example.old", name: "Old")
        unused.classification.isUnused = true
        let fresh = entry(id: "com.example.fresh", name: "Fresh")
        model.replaceEntries([unused, fresh])
        XCTAssertEqual(model.count(in: .all), 2)
        XCTAssertEqual(model.count(in: .unused), 1)
        model.toggle(group: .caches, in: fresh)
        XCTAssertEqual(model.selection[fresh.id]?.count, 1)
        XCTAssertEqual(model.count(in: .selected), 1)
        model.category = .unused
        XCTAssertEqual(model.visibleEntries.map(\.item.name), ["Old"])
    }

    func testUnusedMeansSixMonthsWithoutUse() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sevenMonths = calendar.date(byAdding: .month, value: -7, to: now)!
        let fiveMonths = calendar.date(byAdding: .month, value: -5, to: now)!
        XCTAssertTrue(ApplicationClassification.isUnused(lastUsed: sevenMonths, installed: nil, now: now, calendar: calendar))
        XCTAssertFalse(ApplicationClassification.isUnused(lastUsed: fiveMonths, installed: sevenMonths, now: now, calendar: calendar))
        XCTAssertTrue(ApplicationClassification.isUnused(lastUsed: nil, installed: sevenMonths, now: now, calendar: calendar))
        XCTAssertFalse(ApplicationClassification.isUnused(lastUsed: nil, installed: nil, now: now, calendar: calendar))
    }

    func testVendorsFollowTeamIDThenIdentifier() {
        XCTAssertEqual(ApplicationVendor.of(bundleIdentifier: "com.example.x", teamIdentifier: "UBF8T346G9"), .microsoft)
        XCTAssertEqual(ApplicationVendor.of(bundleIdentifier: "com.google.Chrome", teamIdentifier: nil), .google)
        XCTAssertEqual(ApplicationVendor.of(bundleIdentifier: "com.apple.Safari", teamIdentifier: nil), .apple)
        XCTAssertEqual(ApplicationVendor.of(bundleIdentifier: "org.mozilla.firefox", teamIdentifier: "43AQ936H96"), .other)
    }

    // MARK: Removal

    /// 10-24 (13th build): a removal asked for while another task holds the
    /// exclusive lease did not start, yet its done page read "Some files were
    /// not removed" over "Files are in the Trash", the log read
    /// "…HeavyWorkCoordinator.Error错误0" and the selection was gone. Now the
    /// page says it did not start and why, nothing moves, and Back keeps the
    /// selection for another try.
    @MainActor
    func testARemovalThatCouldNotStartSaysWhyAndKeepsTheSelection() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let model = ApplicationsManagerModel.of(store)
        model.removal.trashResource = { _ in
            XCTFail("nothing moves while another task holds the lease")
            throw CancellationError()
        }
        model.removal.moves.recycle = { _ in
            XCTFail("nothing moves while another task holds the lease")
            throw CancellationError()
        }
        let photon = entry(id: "com.example.photon", name: "Photon")
        model.replaceEntries([photon])
        model.toggle(photon)
        let selected = try XCTUnwrap(model.selection[photon.id])
        let held = try await store.heavyWorkCoordinator.acquire(owner: .appUpdates)

        model.requestRemoval()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.phase != .finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.phase, .finished)
        let reason = HeavyWorkActivityStore.conflictMessage(activeOwner: .appUpdates)
        XCTAssertEqual(model.startFailure, reason)
        XCTAssertTrue(model.outcomes.isEmpty, "nothing ran, so nothing is logged")
        XCTAssertFalse(model.completionSucceeded)
        XCTAssertEqual(model.completionTitle, L10n.text("没能开始", "Could Not Start"))
        XCTAssertTrue(model.completionDescription.hasPrefix(reason), model.completionDescription)
        XCTAssertEqual(model.completionFootnote, L10n.text("没有移动任何文件", "Nothing was moved"))
        for text in [model.completionTitle, model.completionDescription, model.completionFootnote] {
            for misleading in ["没能移走", "废纸篓", "not removed", "Trash", "HeavyWorkCoordinator"] {
                XCTAssertFalse(text.contains(misleading), "\(misleading) in \(text)")
            }
        }
        XCTAssertEqual(model.selection[photon.id], selected, "the selection stays for another try")

        await store.heavyWorkCoordinator.release(held)
        model.returnToBrowsing()
        XCTAssertEqual(model.phase, .browsing)
        XCTAssertNil(model.startFailure)
        XCTAssertEqual(model.selection[photon.id], selected)
    }

    func testRemovalMovesBundleAndResourcesIntoTheTrashWithReceipts() async throws {
        let fm = FileManager.default
        let root = TestFileSystem.uniqueOperationRoot("lifecycle-removal")
        TestFileSystem.registerCleanup(of: root, for: self)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let trash = root.appendingPathComponent("fixture-trash", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let apps = root.appendingPathComponent("apps", isDirectory: true)
        try writeApplication(at: apps.appendingPathComponent("Photon.app"), identifier: "com.example.photon", name: "Photon")
        let cache = home.appendingPathComponent("Library/Caches/com.example.photon", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: cache.appendingPathComponent("blob"))
        let prefs = home.appendingPathComponent("Library/Preferences/com.example.photon.plist")
        try fm.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("p".utf8).write(to: prefs)

        let scan = await AppUninstallService.scanInstalledAppsFromSharedInventory(
            directories: [ApplicationScanDirectory(url: apps, maximumDepth: 1)], timeLimit: 5, maximumConcurrency: 1)
        let app = try XCTUnwrap(scan.apps.first)
        let profile = try XCTUnwrap(ApplicationProfileReader.profile(at: URL(fileURLWithPath: app.path)))
        let finder = ApplicationResourceFinder(homeDirectory: home, systemRoot: root.appendingPathComponent("system"),
                                               dockTileURLs: { [] }, darwinUserCacheDirectory: nil, darwinUserTempDirectory: nil)
        let resources = finder.resources(for: profile, includeBundle: false)
        XCTAssertEqual(Set(resources.map(\.group)), [.caches, .preferences])

        // D218＋旧值：未声明目录类型的 URL。回执读取会核对父目录 URL，夹具应与生产目录一样带目录标记。
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts", isDirectory: true))
        @Sendable func intoTrash(_ source: URL) throws -> URL {
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        var service = ApplicationRemovalService()
        service.homeDirectory = home
        service.persist = { try journal.checkpoint($0, expectedIdentities: $1) }
        service.trashResource = { try intoTrash($0) }
        service.moves = UninstallMoveEnvironment(recycle: { try intoTrash($0) }, authorization: UninstallAuthorizationEnvironment(
            helperVerdict: { _, _, _ in .rejectsLocation }, isWritable: { _ in true }, protection: { _ in .none },
            move: { _, _, _, _ in
                XCTFail("The fixture must never ask for authorization")
                throw POSIXError(.EPERM)
            }))
        service.launchctl = { _ in
            XCTFail("No launch item in this fixture")
            return (1, "")
        }
        service.dock = DockTileEditing { _ in
            XCTFail("No Dock tile in this fixture")
            return nil
        }
        let request = ApplicationRemovalRequest(title: "Photon", bundleIdentifier: "com.example.photon", purpose: .uninstall,
                                                application: app, resources: resources)
        let coordinator = HeavyWorkCoordinator()
        let runner = service
        let outcome = try await coordinator.withLease(owner: .cleanup) { lease in
            await runner.run(request, coordinator: coordinator, lease: lease)
        }
        XCTAssertTrue(outcome.applicationRemoved)
        XCTAssertEqual(outcome.removedCount, 3)
        XCTAssertEqual(outcome.failedCount, 0)
        XCTAssertFalse(fm.fileExists(atPath: app.path))
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        XCTAssertFalse(fm.fileExists(atPath: prefs.path))
        XCTAssertEqual(try journal.load().first?.restorableReceipts.count, 3)
        XCTAssertEqual(try journal.load().first?.items.first?.ruleID, ApplicationRemovalService.ruleID)
    }

    func testChangedResourceIsKeptNotMoved() async throws {
        let fm = FileManager.default
        let root = TestFileSystem.uniqueOperationRoot("lifecycle-changed")
        TestFileSystem.registerCleanup(of: root, for: self)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches/com.example.changed", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let scanned = try XCTUnwrap(AppUninstallService.uninstallFileIdentity(at: cache.path))
        // Replaced after the scan: same path, different object.
        try fm.removeItem(at: cache)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let changed = ApplicationResource(path: cache.path, group: .caches, evidence: .bundleIdentifier, domain: .user, kind: .file,
                                          sizeBytes: 0, identity: scanned, isRemovable: true, note: nil)
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        var service = ApplicationRemovalService()
        service.homeDirectory = home
        service.persist = { try journal.checkpoint($0, expectedIdentities: $1) }
        service.trashResource = { _ in
            XCTFail("A replaced item must not move")
            throw POSIXError(.EPERM)
        }
        let coordinator = HeavyWorkCoordinator()
        let runner = service
        let outcome = try await coordinator.withLease(owner: .cleanup) { lease in
            await runner.run(ApplicationRemovalRequest(title: "Changed", bundleIdentifier: "com.example.changed",
                                                        purpose: .leftovers, application: nil, resources: [changed]),
                              coordinator: coordinator, lease: lease)
        }
        XCTAssertEqual(outcome.removedCount, 0)
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
    }

    /// D151 review: a user agent is booted out only when launchd says the
    /// loaded job came from the plist being moved; Apple's labels are never
    /// touched; a Dock tile already gone is not counted as removed.
    func testLaunchItemIsStoppedOnlyWhenLaunchdNamesThisPlistAndAbsentDockTilesDoNotCount() async throws {
        let fm = FileManager.default
        let root = TestFileSystem.uniqueOperationRoot("lifecycle-launchd")
        TestFileSystem.registerCleanup(of: root, for: self)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let trash = root.appendingPathComponent("fixture-trash", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)

        func agent(_ label: String) throws -> ApplicationResource {
            let plist = agents.appendingPathComponent(label + ".plist")
            try Data("<plist/>".utf8).write(to: plist)
            return ApplicationResource(path: plist.path, group: .loginItems, evidence: .launchdReference, domain: .user,
                                       kind: .launchdJob(label: label), sizeBytes: 8,
                                       identity: AppUninstallService.uninstallFileIdentity(at: plist.path),
                                       isRemovable: true, note: nil)
        }
        let own = try agent("com.example.photon.helper")
        let borrowed = try agent("com.example.photon.updater")
        let apple = try agent("com.apple.photon.lookalike")
        let calls = LaunchctlCalls()
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        var service = ApplicationRemovalService()
        service.homeDirectory = home
        service.persist = { try journal.checkpoint($0, expectedIdentities: $1) }
        service.trashResource = { source in
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        let ownPath = own.path
        service.launchctl = { arguments in
            calls.append(arguments)
            let target = arguments.last ?? ""
            if arguments.first == "bootout" { return (0, "") }
            if target.hasSuffix("/com.example.photon.helper") {
                // Loaded from this plist until booted out.
                return calls.contains(["bootout", target]) ? (113, "") : (0, "\tpath = \(ownPath)\n\tstate = running\n")
            }
            // The updater's label is held by another job, from another plist.
            return (0, "\tpath = /Users/someone/Library/LaunchAgents/other.plist\n")
        }
        service.dock = DockTileEditing { _ in [] }
        let dockTile = ApplicationResource(path: "/Applications/Photon.app", group: .dockIcon, evidence: .dockReference,
                                           domain: .user, kind: .dockTile(url: "file:///Applications/Photon.app/"),
                                           sizeBytes: 0, identity: nil, isRemovable: true, note: nil)
        let request = ApplicationRemovalRequest(title: "Photon", bundleIdentifier: "com.example.photon", purpose: .reset,
                                                application: nil, resources: [own, borrowed, apple, dockTile])
        let coordinator = HeavyWorkCoordinator()
        let runner = service
        let outcome = try await coordinator.withLease(owner: .cleanup) { lease in
            await runner.run(request, coordinator: coordinator, lease: lease)
        }
        XCTAssertFalse(fm.fileExists(atPath: own.path), "its own agent was stopped and moved")
        XCTAssertTrue(fm.fileExists(atPath: borrowed.path), "a label held by another plist's job is left alone")
        XCTAssertTrue(fm.fileExists(atPath: apple.path), "Apple's labels are never touched")
        XCTAssertEqual(calls.bootouts, ["gui/\(getuid())/com.example.photon.helper"])
        XCTAssertFalse(calls.labels.contains { $0.hasSuffix("com.apple.photon.lookalike") })
        XCTAssertEqual(outcome.removedCount, 1, "the absent Dock tile is not counted")
        XCTAssertEqual(outcome.keptCount, 2)
        XCTAssertEqual(outcome.log.filter { $0.status == .kept(ApplicationRemovalService.unconfirmedLaunchItemNote) }.count, 2)
        XCTAssertEqual(ApplicationRemovalService.loadedPlistPath(in: "\tpath = (submitted by smd.352)\n"), nil)
    }

    // MARK: Leftovers and installers

    func testLeftoversListOnlyIdentifiersNothingOwns() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "leftovers")
        let fm = FileManager.default
        for relative in ["Library/Preferences/com.removed.Tool.plist", "Library/Preferences/com.apple.finder.plist",
                         "Library/Preferences/com.present.App.helper.plist", "Library/Preferences/Notes.plist",
                         "Library/Preferences/com.registered.Thing.plist"] {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try fm.createDirectory(at: home.appendingPathComponent("Library/Caches/com.removed.Tool"), withIntermediateDirectories: true)
        let scanner = LeftoverScanner(homeDirectory: home, installedBundleIdentifiers: ["com.present.App"],
                                      isRegistered: { $0 == "com.registered.Thing" }, measuresSizes: false)
        let groups = scanner.scan()
        XCTAssertEqual(groups.map(\.bundleIdentifier), ["com.removed.Tool"])
        XCTAssertEqual(Set(groups.first?.resources.map(\.group) ?? []), [.preferences, .caches])
        XCTAssertEqual(groups.first?.displayName, "Tool")
        XCTAssertTrue(LeftoverScanner.looksLikeBundleIdentifier("com.vendor.App"))
        XCTAssertFalse(LeftoverScanner.looksLikeBundleIdentifier("vendor.App"))
        XCTAssertFalse(LeftoverScanner.looksLikeBundleIdentifier("2024.backup.zip"))
    }

    func testInstallersArePreselectedWhenTheirAppIsInstalled() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "installers")
        let fm = FileManager.default
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let matched = downloads.appendingPathComponent("Photon Studio 3.1.dmg")
        let other = downloads.appendingPathComponent("Something.pkg")
        let notInstaller = downloads.appendingPathComponent("Notes.txt")
        for url in [matched, other, notInstaller] { try Data("x".utf8).write(to: url) }
        let scanner = UnusedInstallerScanner(homeDirectory: home, installedApplicationNames: ["Photon Studio"],
                                             search: { _ in [matched.path, other.path, notInstaller.path] })
        let files = scanner.scan()
        XCTAssertEqual(Set(files.map(\.resource.displayName)), ["Photon Studio 3.1.dmg", "Something.pkg"])
        XCTAssertEqual(files.first { $0.resource.displayName == "Photon Studio 3.1.dmg" }?.preselected, true)
        XCTAssertEqual(files.first { $0.resource.displayName == "Something.pkg" }?.preselected, false)
    }

    // MARK: Updater additions

    func testSparkleAppcastKeepsReleaseDateAndPlainReleaseNotes() throws {
        let appcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><item>
        <title>2.0</title>
        <pubDate>Mon, 12 Oct 2026 09:30:00 +0000</pubDate>
        <description><![CDATA[<h2>What's new</h2><ul><li>Faster &amp; smaller</li><li>Bug fixes</li></ul>]]></description>
        <enclosure url="https://example.com/App-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0" length="1234" type="application/octet-stream"/>
        </item></channel></rss>
        """
        let release = try XCTUnwrap(SparkleAppcastParser.select(Data(appcast.utf8),
            installed: ApplicationVersion(marketing: "1.0", build: "100"), systemVersion: "26.0"))
        XCTAssertEqual(release.releaseDate, Date(timeIntervalSince1970: 1_791_797_400))
        XCTAssertEqual(release.releaseNotes, "What's new\n\n• Faster & smaller\n• Bug fixes")
        XCTAssertNil(ReleaseNotesText.plain(fromHTML: "<p> </p>"))
    }

    func testSystemUpdatesAreReadFromSoftwareUpdatePreferences() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let plist = root.appendingPathComponent("com.apple.SoftwareUpdate.plist")
        let values: [String: Any] = ["RecommendedUpdates": [
            ["Display Name": "macOS Tahoe 26.1", "Display Version": "26.1", "Identifier": "MSU_UPDATE_25B_patch"],
            ["Display Name": "", "Display Version": "1"],
        ]]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: plist)
        let updates = SystemSoftwareUpdateStatus.recommendedUpdates(plistURL: plist)
        XCTAssertEqual(updates, [SystemSoftwareUpdate(identifier: "MSU_UPDATE_25B_patch", name: "macOS Tahoe 26.1", version: "26.1")])
        XCTAssertEqual(SystemSoftwareUpdateStatus.recommendedUpdates(plistURL: root.appendingPathComponent("missing.plist")), [])
    }
}

/// launchctl calls a removal makes, recorded from its @Sendable stub.
private final class LaunchctlCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func append(_ arguments: [String]) { lock.withLock { calls.append(arguments) } }
    func contains(_ arguments: [String]) -> Bool { lock.withLock { calls.contains(arguments) } }
    var bootouts: [String] { lock.withLock { calls.filter { $0.first == "bootout" }.compactMap(\.last) } }
    var labels: [String] { lock.withLock { calls.compactMap(\.last) } }
}
