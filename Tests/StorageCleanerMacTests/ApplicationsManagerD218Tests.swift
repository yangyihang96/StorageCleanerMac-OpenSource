import Foundation
import XCTest
@testable import StorageCleanerMac

final class ApplicationsManagerD218Tests: XCTestCase {
    private static let home = "/Users/d218-fixture"

    private static func item(_ path: String, identifier: String = "com.example.copy", bytes: Int64 = 100) -> InstalledAppItem {
        InstalledAppItem(id: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            bundleIdentifier: identifier, path: path, version: "1.0", build: "1", category: "", appDescription: "",
            sizeBytes: bytes, source: "fixture", modifiedAt: Date(timeIntervalSince1970: 1_000),
            relatedPaths: [home + "/Library/Preferences/\(identifier).plist"], relatedItems: [], status: .installed)
    }

    private func scanner(_ items: [InstalledAppItem], symlinks: Set<String> = []) -> OtherApplicationsScanner {
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        return OtherApplicationsScanner(homeDirectory: URL(fileURLWithPath: Self.home),
            query: { SpotlightApplicationScanResult(applicationURLs: items.map { URL(fileURLWithPath: $0.path) }, completion: .completed) },
            containsSymbolicLink: { symlinks.contains($0) }, readApplication: { byPath[$0.path] })
    }

    func testEveryExcludedLocationIsFilteredFromInjectedSpotlightResults() async throws {
        let h = Self.home
        let excluded = [
            "/Applications/A.app", "/Applications/Setapp/B.app", "/Applications/Tools/C.app", h + "/Applications/D.app",
            h + "/Library/Developer/DerivedData/Build.app", "/Library/Input Methods/E.app", "/System/Applications/F.app",
            "/Volumes/External/G.app", "/usr/local/H.app", "/bin/I.app", "/sbin/J.app", "/private/data/K.app",
            "/opt/homebrew/Caskroom/L.app", "/cores/M.app", "/net/N.app", "/tmp/O.app", "/var/P.app", "/dev/Q.app", "/etc/R.app",
            "/Developer/Tools/S.app", h + "/Documents/Outer.app/Contents/Helpers/Inner.app",
            h + "/VMs/Windows.pvm/Apps/T.app", h + "/VMs/Windows.vmwarevm/Apps/U.app",
            h + "/VMs/Windows.utm/Apps/V.app", h + "/VMs/Windows.vbox/Apps/W.app",
            h + "/Backups.backupdb/Mac/date/X.app", h + "/Archive.backup/Apps/Y.app",
            h + "/Disk.sparsebundle/Apps/Z.app", h + "/.ssh/Credential.app", h + "/.config/gh/Credential.app",
            h + "/.Trash/Trashed.app", h + "/.cxoffice/Bottles/Proxy.app",
            h + "/Desktop/Chrome Apps.localized/Web.app", h + "/Desktop/linked/Link.app",
            h + "/Downloads/NotAnApp.app.disabled",
        ]
        let allowed = [h + "/Downloads/Download.app", h + "/Desktop/Desktop.app", h + "/Documents/Document.app",
                       h + "/Developer/project/.build/Build.app", "/Users/Shared/Shared.app", h + "/ApplicationsArchive/Keep.app"]
        let items = (excluded + allowed).map { Self.item($0, identifier: "") }
        let report = try await scanner(items, symlinks: [h + "/Desktop/linked/Link.app"]).scan()
        XCTAssertEqual(Set(report.groups.flatMap(\.copies).map(\.path)), Set(allowed))
        XCTAssertEqual(report.groups.count, allowed.count)
        XCTAssertNil(report.unavailableReason)
        for path in excluded where !path.contains("/linked/") {
            XCTAssertFalse(OtherApplicationsScanner.permits(path: path, homePath: h), path)
        }
    }

    func testProxyAndBrowserWebApplicationIdentifiersAreExcluded() async throws {
        let excluded = ["com.parallels.winapp.test", "com.parallels.ApplicationGroupBridge.test", "com.vmware.proxyApp.test",
                        "com.codeweavers.CrossOverHelper.test", "com.codeweavers.CrossOver.winapp.test",
                        "com.google.Chrome.app.test", "com.google.Chrome.canary.app.test", "org.chromium.Chromium.app.test",
                        "com.microsoft.edgemac.app.test", "com.brave.Browser.app.test", "com.vivaldi.Vivaldi.app.test",
                        "com.operasoftware.Opera.app.test", "com.apple.Safari.WebApp.test"]
        let proxies = excluded.enumerated().map { Self.item(Self.home + "/Desktop/Proxy\($0.offset).app", identifier: $0.element) }
        let realBrowsers = [Self.item(Self.home + "/Desktop/Chrome.app", identifier: "com.google.Chrome"),
                            Self.item(Self.home + "/Desktop/CrossOver.app", identifier: "com.codeweavers.CrossOver")]
        let report = try await scanner(proxies + realBrowsers).scan()
        XCTAssertEqual(Set(report.groups.flatMap(\.copies).map(\.path)), Set(realBrowsers.map(\.path)))
    }

    func testSameIdentifierGroupsCopiesButMissingIdentifiersStaySeparate() async throws {
        let copies = [Self.item(Self.home + "/Developer/one/Copy.app", bytes: 10),
                      Self.item(Self.home + "/Developer/two/Copy.app", bytes: 20),
                      Self.item(Self.home + "/Desktop/NoID.app", identifier: ""),
                      Self.item(Self.home + "/Documents/NoID.app", identifier: "")]
        let report = try await scanner(copies).scan()
        XCTAssertEqual(report.groups.count, 3)
        let group = try XCTUnwrap(report.groups.first { $0.copies.count == 2 })
        XCTAssertEqual(group.sizeBytes, 30)
        XCTAssertEqual(Set(group.copies.map(\.path)), Set(copies.prefix(2).map(\.path)))
        XCTAssertTrue(group.copies.allSatisfy { $0.modifiedAt == Date(timeIntervalSince1970: 1_000) })
        XCTAssertEqual(group.copies.map(\.sizeBytes).sorted(), [10, 20])
    }

    @MainActor
    func testManagerStartsUnselectedAndDoesNotAddCopiesToInstalledCountsOrOverview() async throws {
        let copies = [Self.item(Self.home + "/Developer/one/Copy.app"), Self.item(Self.home + "/Developer/two/Copy.app")]
        let model = ApplicationsManagerModel(otherApplicationsScanner: scanner(copies))
        let installed = Self.item("/Applications/Installed.app")
        model.load(inventory: [installed], readsDisk: false)
        XCTAssertTrue(model.otherApplications.groups.isEmpty, "inert loads do not query Spotlight")
        model.refreshOtherApplications()
        await model.waitForOtherApplications()
        XCTAssertEqual(model.count(in: .otherLocations), 1)
        XCTAssertEqual(model.count(in: .all), 1)
        XCTAssertEqual(model.entries.map(\.item.path), [installed.path])
        XCTAssertTrue(model.unusedEntries.allSatisfy { $0.item.path == installed.path })
        XCTAssertTrue(model.thirtyTwoBitEntries.isEmpty)
        XCTAssertTrue(model.otherApplicationSelection.isEmpty)
        XCTAssertFalse(model.hasSelection)
        XCTAssertTrue(model.buildRequests().isEmpty)
        model.category = .otherLocations
        model.searchText = "/two/"
        XCTAssertEqual(model.visibleOtherApplications.count, 1)
        let group = try XCTUnwrap(model.visibleOtherApplications.first)
        model.toggleOtherApplications(group)
        XCTAssertEqual(model.otherApplicationSelection, Set(copies.map(\.path)))
        model.toggleOtherApplication(copies[0].path)
        XCTAssertEqual(model.otherApplicationSelection, [copies[1].path])
        XCTAssertEqual(model.selectionSummary.applications, 1)
        XCTAssertEqual(model.count(in: .all), 1)
        XCTAssertEqual(model.count(in: .selected), 1)
        model.toggleOtherApplications(group)
        model.toggleOtherApplications(group)
        XCTAssertTrue(model.otherApplicationSelection.isEmpty)
    }

    @MainActor
    func testRemovalRequestsContainOnlyCheckedBundlesDespitePreselectedRelatedFiles() async throws {
        let copies = [Self.item(Self.home + "/Desktop/Copy.app"), Self.item(Self.home + "/Documents/Copy.app")]
        let model = ApplicationsManagerModel(otherApplicationsScanner: scanner(copies))
        model.load(inventory: [Self.item("/Applications/Installed.app")], readsDisk: false)
        model.refreshOtherApplications()
        await model.waitForOtherApplications()
        let resource = ApplicationResource(path: Self.home + "/Library/Preferences/com.example.copy.plist",
            group: .preferences, evidence: .bundleIdentifier, domain: .user, kind: .file, sizeBytes: 30,
            identity: nil, isRemovable: true, note: nil)
        model.replaceLeftovers([LeftoverGroup(bundleIdentifier: "com.example.copy", displayName: "Copy", resources: [resource])])
        XCTAssertFalse(model.leftoverSelection.isEmpty)
        model.category = .otherLocations
        XCTAssertFalse(model.hasSelection)
        model.toggleOtherApplication(copies[1].path)
        let requests = model.buildRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.application?.path, copies[1].path)
        XCTAssertEqual(request.purpose, .bundleOnly)
        XCTAssertTrue(request.removesBundle)
        XCTAssertTrue(request.resources.isEmpty)
        XCTAssertEqual(model.selectionSummary.items, 0)
        XCTAssertEqual(model.selectionSummary.bytes, copies[1].sizeBytes)
        let poisoned = ApplicationRemovalRequest(title: "Copy", bundleIdentifier: "com.example.copy", purpose: .bundleOnly,
                                                application: copies[1], resources: [resource])
        XCTAssertTrue(poisoned.resources.isEmpty, "bundle-only requests enforce the boundary even if a caller supplies shared resources")
    }

    func testUnavailableTimeoutAndFailureReturnEmptyStateWithReason() async throws {
        for completion in [SpotlightScanCompletion.unavailable, .timedOut] {
            var scanner = scanner([Self.item(Self.home + "/Desktop/Copy.app")])
            scanner.query = { .init(applicationURLs: [URL(fileURLWithPath: Self.home + "/Desktop/Copy.app")], completion: completion) }
            let report = try await scanner.scan()
            XCTAssertTrue(report.groups.isEmpty)
            XCTAssertFalse(try XCTUnwrap(report.unavailableReason).isEmpty)
        }
        var failing = scanner([])
        failing.query = { throw NSError(domain: "D218InjectedFailure", code: 7) }
        let report = try await failing.scan()
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertNotNil(report.unavailableReason)
    }

    @MainActor
    func testFailedQueryIsPublishedAsAnEmptyManagerState() async throws {
        var scanner = scanner([])
        scanner.query = { throw NSError(domain: "D218InjectedFailure", code: 7) }
        let model = ApplicationsManagerModel(otherApplicationsScanner: scanner)
        model.refreshOtherApplications()
        await model.waitForOtherApplications()
        XCTAssertFalse(model.isScanningOtherApplications)
        XCTAssertEqual(model.count(in: .otherLocations), 0)
        XCTAssertNotNil(model.otherApplications.unavailableReason)
    }

    @MainActor
    func testD207PathIgnoresFilterIndividualCopiesAndRefreshSelection() async throws {
        let copies = [Self.item(Self.home + "/Desktop/Copy.app"), Self.item(Self.home + "/Documents/Copy.app")]
        let snapshot = IgnoreListSnapshot(entries: [.init(id: "ignore-one", category: .uninstaller,
            target: .init(path: copies[0].path), displayName: "Copy", addedAt: .distantPast)])
        let scanner = scanner(copies)
        let report = try await scanner.scan(ignoreList: snapshot)
        XCTAssertEqual(report.groups.flatMap(\.copies).map(\.path), [copies[1].path])
        XCTAssertEqual(report.ignoredCount, 1)
        let model = ApplicationsManagerModel(otherApplicationsScanner: scanner)
        model.refreshOtherApplications()
        await model.waitForOtherApplications()
        model.toggleOtherApplication(copies[0].path)
        model.load(inventory: [], readsDisk: false, ignoreList: snapshot)
        XCTAssertTrue(model.otherApplicationSelection.isEmpty)
        XCTAssertEqual(model.otherApplications.groups.flatMap(\.copies).map(\.path), [copies[1].path])
        XCTAssertEqual(model.otherApplications.ignoredCount, 1)
        XCTAssertEqual(model.ignoredTotal, 0, "Other Locations must not change overview counts, including ignored items")
        XCTAssertTrue(model.buildRequests().isEmpty)
    }

    func testSymbolicLinkDetectionUsesOnlyTemporaryFixture() throws {
        let root = try TestFileSystem.makeOperationHome(for: self, purpose: "d218-symlinks")
        let target = root.appendingPathComponent("real/Copy.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let scanner = OtherApplicationsScanner(homeDirectory: root, query: { .init(applicationURLs: [], completion: .completed) })
        XCTAssertTrue(scanner.containsSymbolicLink(link.appendingPathComponent("Copy.app").path))
        XCTAssertFalse(scanner.containsSymbolicLink(target.path))
    }

    func testBundleWithoutIdentifierStillUsesScanIdentityBeforeRemoval() throws {
        let root = try TestFileSystem.makeOperationHome(for: self, purpose: "d218-identity")
        let app = root.appendingPathComponent("NoID.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"],
                                           format: .xml, options: 0).write(to: plist)
        let item = InstalledAppItem(id: app.path, name: "NoID", bundleIdentifier: "", path: app.path, version: "1.0", build: "1",
            category: "", appDescription: "", sizeBytes: 0, source: "fixture", modifiedAt: nil,
            scanIdentity: AppUninstallService.uninstallFileIdentity(at: app.path), relatedPaths: [], relatedItems: [], status: .installed)
        XCTAssertFalse(AppUninstallService.scannedApplicationStillAtPath(item))
        XCTAssertTrue(AppUninstallService.scannedApplicationStillAtPath(item, allowMissingBundleIdentifier: true))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "changed"], format: .xml, options: 0).write(to: plist)
        XCTAssertFalse(AppUninstallService.scannedApplicationStillAtPath(item, allowMissingBundleIdentifier: true))
    }

    func testBundleMetadataReaderOnlyReadsTemporaryBundleAndHasNoRelatedResources() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "d218-metadata")
        let bundle = home.appendingPathComponent("Build.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.build",
            "CFBundleDisplayName": "Build Copy", "CFBundleShortVersionString": "2.1", "CFBundleVersion": "21"],
            format: .xml, options: 0).write(to: plist)
        let scanner = OtherApplicationsScanner(homeDirectory: home, query: { .init(applicationURLs: [], completion: .completed) })
        let item = try XCTUnwrap(scanner.readApplication(bundle))
        XCTAssertEqual(item.name, "Build Copy")
        XCTAssertEqual(item.bundleIdentifier, "com.example.build")
        XCTAssertEqual(item.version, "2.1")
        XCTAssertEqual(item.build, "21")
        XCTAssertEqual(item.path, bundle.path)
        XCTAssertNotNil(item.modifiedAt)
        XCTAssertNotNil(item.scanIdentity)
        XCTAssertGreaterThan(item.sizeBytes, 0)
        XCTAssertTrue(item.relatedPaths.isEmpty)
        XCTAssertTrue(item.relatedItems.isEmpty)
    }

    func testBundleOnlyRemovalKeepsSharedFilesAndWritesARecoverableReceipt() async throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "d218-bundle-removal")
        let bundle = home.appendingPathComponent("copies/Copy.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.copy",
            "CFBundleVersion": "1"], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let shared = home.appendingPathComponent("Library/Preferences/com.example.copy.plist")
        try Data("shared preferences".utf8).write(to: shared)
        let trash = home.appendingPathComponent("fixture-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let scanner = OtherApplicationsScanner(homeDirectory: home, query: { .init(applicationURLs: [], completion: .completed) })
        let app = try XCTUnwrap(scanner.readApplication(bundle))
        let journal = CleanupReportJournal(directory: home.appendingPathComponent("receipts", isDirectory: true))
        var service = ApplicationRemovalService()
        service.homeDirectory = home
        service.persist = { try journal.checkpoint($0, expectedIdentities: $1) }
        service.moves = UninstallMoveEnvironment(recycle: { source in
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }, authorization: UninstallAuthorizationEnvironment(helperVerdict: { _, _, _ in .rejectsLocation },
            isWritable: { _ in true }, protection: { _ in .none }, move: { _, _, _, _ in
                XCTFail("A temporary bundle must never request the helper")
                throw POSIXError(.EPERM)
            }))
        service.trashResource = { _ in
            XCTFail("Bundle-only removal must never move shared resources")
            throw POSIXError(.EPERM)
        }
        let request = ApplicationRemovalRequest(title: "Copy", bundleIdentifier: app.bundleIdentifier,
                                                purpose: .bundleOnly, application: app, resources: [])
        let coordinator = HeavyWorkCoordinator()
        let runner = service
        let outcome = try await coordinator.withLease(owner: .cleanup) { lease in
            await runner.run(request, coordinator: coordinator, lease: lease)
        }
        XCTAssertTrue(outcome.applicationRemoved)
        XCTAssertEqual(outcome.removedCount, 1)
        XCTAssertEqual(outcome.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Copy.app").path))
        XCTAssertEqual(try Data(contentsOf: shared), Data("shared preferences".utf8))
        let report = try XCTUnwrap(outcome.report)
        let stored = try journal.read(journal.directory.appendingPathComponent(report.planID.rawValue.uuidString + ".json"))
        XCTAssertEqual(stored.report.restorableReceipts.count, 1)
        XCTAssertEqual(stored.report.items.map(\.sourcePath), [bundle.path])
        XCTAssertEqual(try journal.load().first?.restorableReceipts.count, 1)
    }
}
