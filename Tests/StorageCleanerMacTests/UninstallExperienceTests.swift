import XCTest
@testable import StorageCleanerMac

final class UninstallExperienceTests: XCTestCase {
    private func app(_ bundleID: String, related: [InstalledAppRelatedItem] = []) -> InstalledAppItem {
        .init(id: "/Applications/Fixture.app", name: "Fixture", bundleIdentifier: bundleID,
            path: "/Applications/Fixture.app", version: "1.0", build: "1", category: "", appDescription: "",
            sizeBytes: 0, source: "fixture", modifiedAt: nil, relatedPaths: related.map(\.path), relatedItems: related, status: .installed)
    }
    func testSelectionDiscoversFilesCreatedAfterInventoryAndRemovesVanishedEntries() throws {
        let id = "org.storagecleaner.fixture." + UUID().uuidString
        let home = try TestFileSystem.makeOperationHome(for: self)
        let path = home.appendingPathComponent("Library/Caches/" + id)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { TestFileSystem.remove(path) }
        try Data("fresh data".utf8).write(to: path.appendingPathComponent("fresh"))
        let initial = app(id)
        let found = UninstallOwnershipVerifier.discover(initial, homeDirectory: home)
        let row = try XCTUnwrap(found.first { $0.path == path.path })
        XCTAssertNotNil(row.scanIdentity)
        XCTAssertEqual(row.sizeBytes, 10)
        XCTAssertTrue(row.sizeIsKnown)
        XCTAssertNil(row.ownershipEvidence, "Discovery must not grant ownership")
        try FileManager.default.removeItem(at: path)
        XCTAssertFalse(UninstallOwnershipVerifier.discover(app(id, related: found), homeDirectory: home).contains { $0.path == path.path })
    }
    func testUnknownOrSymlinkCandidateIsNeverMadeSelectableForDisplay() throws {
        let id = "org.storagecleaner.fixture." + UUID().uuidString
        let home = try TestFileSystem.makeOperationHome(for: self)
        let root = home.appendingPathComponent("Library/Caches/" + id)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: URL(fileURLWithPath: "/tmp"))
        defer { TestFileSystem.remove(root) }
        let value = app(id, related: [.init(path: root.path, sizeBytes: 0)])
        let discovered = UninstallOwnershipVerifier.discover(value, homeDirectory: home)
        XCTAssertEqual(discovered.first?.ownershipBlockReason, .unsafePath)
        XCTAssertTrue(UninstallPresentation.selectablePaths(app(id, related: discovered)).isEmpty)
    }
    func testVendorRulesBindExactSignerAndDoNotAuthorizeSharedGroups() {
        XCTAssertTrue(UninstallVendorRules.rules(bundleID: "com.microsoft.teams2", version: "26072", teamID: "wrong").isEmpty)
        XCTAssertTrue(UninstallVendorRules.rules(bundleID: "com.microsoft.teams2.other", version: "26072", teamID: "UBF8T346G9").isEmpty)
        let rules = UninstallVendorRules.rules(bundleID: "com.microsoft.teams2", version: "26072", teamID: "UBF8T346G9")
        XCTAssertEqual(rules.map(\.relativePath), ["Library/Containers/com.microsoft.teams2"])
        XCTAssertFalse(rules.contains { $0.relativePath.contains("Group Containers") })
        XCTAssertEqual(UninstallVendorRules.discoveryOnly(bundleID: "com.microsoft.teams2").count, 1)
    }
    func testLegacyVSCodeProofRevisionRemainsCompatible() {
        let rules = UninstallVendorRules.rules(bundleID: "com.microsoft.VSCode", version: "1.100", teamID: "UBF8T346G9")
        XCTAssertEqual(rules.first?.revision, "vscode-stable-1-data-v1")
        XCTAssertTrue(UninstallVendorRules.rules(bundleID: "com.microsoft.VSCode", version: "2.0", teamID: "UBF8T346G9").isEmpty)
    }
}

extension UninstallExperienceTests {
    func testAppOnlyUninstallCanDiscoverAndCleanResidualsFromSavedReceipt() async throws {
        guard let manifest = ProcessInfo.processInfo.environment["SCM_SIGNED_UNINSTALL_FIXTURE"] else {
            throw XCTSkip("Requires the disposable signed fixture; never a real application")
        }
        let fixture = try copyOwnedUninstallFixture(for: self, manifest: manifest)
        let original = fixture.app
        let container = fixture.container
        let bid = fixture.bundleID
        XCTAssertTrue(bid.hasPrefix("org.storagecleaner.fixture."))
        let root = fixture.home.appendingPathComponent("residual-trash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appTarget = root.appendingPathComponent("Fixture.app")
        let dataTarget = root.appendingPathComponent("Data")
        defer {
            if FileManager.default.fileExists(atPath: appTarget.path) { try? FileManager.default.moveItem(at: appTarget, to: original) }
            if FileManager.default.fileExists(atPath: dataTarget.path) { try? FileManager.default.moveItem(at: dataTarget, to: container) }
            TestFileSystem.remove(root)
        }
        let identity = try FoundationReadOnlyFileSystem().snapshot(at: original).identity
        let app = InstalledAppItem(id: original.path, name: "Fixture", bundleIdentifier: bid, path: original.path,
            version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: 0, source: "fixture",
            modifiedAt: nil, scanIdentity: identity, relatedPaths: [], relatedItems: [], status: .installed)
        let coordinator = HeavyWorkCoordinator()
        let first = try await coordinator.withLease(owner: .cleanup) { lease in
            await AppUninstallService.execute(try UninstallPlan(app: app, selectedPaths: [], homeDirectory: fixture.home), coordinator: coordinator, lease: lease,
                recycle: { source in try FileManager.default.moveItem(at: source, to: appTarget); return appTarget }, persist: { _, _ in })
        }
        let report = try XCTUnwrap(first.report)
        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertTrue(AppUninstallService.canInspectResiduals(report))
        XCTAssertThrowsError(try AppUninstallService.residualReview(report, inventory: [app], complete: true, homeDirectory: fixture.home))
        XCTAssertThrowsError(try AppUninstallService.residualReview(report, inventory: [], complete: false, homeDirectory: fixture.home))
        let (residual, receipt) = try AppUninstallService.residualReview(report, inventory: [], complete: true, homeDirectory: fixture.home)
        XCTAssertTrue(UninstallPresentation.selectablePaths(residual).contains(container.path))
        let second = try await coordinator.withLease(owner: .cleanup) { lease in
            await AppUninstallService.execute(try UninstallPlan(app: residual, selectedPaths: [container.path], homeDirectory: fixture.home),
                coordinator: coordinator, lease: lease, completedApplication: receipt,
                recycle: { source in
                    XCTAssertEqual(source.path, container.path, "Must never retry moving the already removed app")
                    try FileManager.default.moveItem(at: source, to: dataTarget); return dataTarget
                }, persist: { _, _ in })
        }
        XCTAssertEqual(second.report?.summary.movedItemCount, 1)
        XCTAssertEqual(second.report?.items.count, 1)
        XCTAssertEqual(second.report?.restorableReceipts.first?.originalPath, container.path)
    }
}
