import Foundation
import XCTest
import Security
@testable import StorageCleanerMac

final class UninstallOwnershipTests: XCTestCase {
    private func app(at path: String, identity: FileIdentity?, related: [InstalledAppRelatedItem] = []) -> InstalledAppItem {
        InstalledAppItem(id: path, name: "Fixture", bundleIdentifier: "org.example.fixture", path: path,
            version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: 0,
            source: "fixture", modifiedAt: nil, scanIdentity: identity,
            relatedPaths: related.map(\.path), relatedItems: related, status: .installed)
    }

    func testProductionVerifierWithExplicitSignedFixture() throws {
        guard let manifest = ProcessInfo.processInfo.environment["SCM_SIGNED_UNINSTALL_FIXTURE"] else {
            throw XCTSkip("Requires the explicitly created disposable signed uninstall fixture")
        }
        let fixture = try copyOwnedUninstallFixture(for: self, manifest: manifest)
        let path = fixture.app.path
        let container = fixture.container.path
        let bundleID = fixture.bundleID
        XCTAssertTrue(bundleID.hasPrefix("org.storagecleaner.fixture."))
        let identity = try FoundationReadOnlyFileSystem().snapshot(at: URL(fileURLWithPath: path)).identity
        let relatedIdentity = try FoundationReadOnlyFileSystem().snapshot(at: URL(fileURLWithPath: container)).identity
        let value = InstalledAppItem(id: path, name: "Fixture", bundleIdentifier: bundleID, path: path,
            version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: 0, source: "fixture",
            modifiedAt: nil, scanIdentity: identity, relatedPaths: [container],
            relatedItems: [.init(path: container, sizeBytes: 0, scanIdentity: relatedIdentity)], status: .installed)
        let prepared = UninstallOwnershipVerifier.prepare(value, inventory: [value], complete: true, homeDirectory: fixture.home)
        let related = try XCTUnwrap(prepared.relatedItems.first)
        XCTAssertNotNil(related.ownershipEvidence)
        XCTAssertEqual(try UninstallPlan(app: prepared, selectedPaths: [container], homeDirectory: fixture.home).relatedItems.count, 1)
        XCTAssertTrue(UninstallOwnershipVerifier.isCurrent(related, app: prepared, homeDirectory: fixture.home))
        let duplicate = UninstallOwnershipVerifier.prepare(prepared, inventory: [value, value], complete: true, homeDirectory: fixture.home)
        XCTAssertNil(duplicate.relatedItems.first?.ownershipEvidence)
        let metadata = URL(fileURLWithPath: container).appendingPathComponent(UninstallOwnershipVerifier.metadataName)
        let original = try Data(contentsOf: metadata)
        // A requirement may match this app while also accepting unrelated code.
        // Merely finding its identifier in the requirement is not ownership proof.
        var broadRequirement: SecRequirement?
        var broadData: CFData?
        XCTAssertEqual(SecRequirementCreateWithString(("identifier \"" + bundleID + "\" or true") as CFString, [], &broadRequirement), errSecSuccess)
        XCTAssertEqual(SecRequirementCopyData(try XCTUnwrap(broadRequirement), [], &broadData), errSecSuccess)
        let broad = try XCTUnwrap(broadData) as Data
        let originalMetadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        let originalInfo = try XCTUnwrap(originalMetadata["MCMMetadataInfo"] as? [String: Any])
        let ownRequirements = try XCTUnwrap(originalInfo["Identity"] as? [Data])
        for requirements in [[broad], ownRequirements + [broad]] {
            let mixed = try PropertyListSerialization.data(fromPropertyList: [
                "MCMMetadataIdentifier": bundleID,
                "MCMMetadataInfo": ["Identity": requirements]
            ], format: .binary, options: 0)
            XCTAssertFalse(UninstallOwnershipVerifier.containerMatches(mixed, appPath: path, bundleID: bundleID))
        }
        defer { try? original.write(to: metadata) }
        try Data("replaced".utf8).write(to: metadata)
        XCTAssertFalse(UninstallOwnershipVerifier.isCurrent(related, app: prepared, homeDirectory: fixture.home))
    }

    func testExactBundleNameAloneCannotEnterProductionPlan() throws {
        let root = TestFileSystem.uniqueOperationRoot("SCM-Ownership")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { TestFileSystem.remove(root) }
        let identity = try FoundationReadOnlyFileSystem().snapshot(at: root).identity
        let related = InstalledAppRelatedItem(path: root.path, sizeBytes: 0, scanIdentity: identity,
            verifiedExclusiveOwnerBundleID: "org.example.fixture")
        let value = app(at: root.appendingPathComponent("Fixture.app").path, identity: identity, related: [related])
        XCTAssertThrowsError(try UninstallPlan(app: value, selectedPaths: [related.path], homeDirectory: root))
        XCTAssertTrue(try UninstallPlan(app: value, selectedPaths: [], homeDirectory: root).relatedItems.isEmpty)
    }

    func testResidualResumeRequiresFreshCompleteInventoryWithoutAnotherInstallation() {
        let value = app(at: "/Applications/Fixture.app", identity: nil)
        XCTAssertFalse(UninstallOwnershipVerifier.canResumeResiduals(bundleID: value.bundleIdentifier, inventory: [], complete: false))
        XCTAssertFalse(UninstallOwnershipVerifier.canResumeResiduals(bundleID: value.bundleIdentifier, inventory: [value], complete: true))
        XCTAssertTrue(UninstallOwnershipVerifier.canResumeResiduals(bundleID: value.bundleIdentifier, inventory: [], complete: true))
    }

    func testContainerNameWithoutSigningRequirementIsNotProof() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": "org.example.fixture"], format: .binary, options: 0)
        XCTAssertFalse(UninstallOwnershipVerifier.containerMatches(data, appPath: "/Applications/Fixture.app", bundleID: "org.example.fixture"))
        XCTAssertFalse(UninstallOwnershipVerifier.containerMatches(Data("bad".utf8), appPath: "/Applications/Fixture.app", bundleID: "org.example.fixture"))
    }

    func testIncompleteInventoryNeverPromotesCandidates() {
        let value = app(at: "/Applications/Fixture.app", identity: nil,
            related: [.init(path: "/unknown", sizeBytes: 0)])
        let prepared = UninstallOwnershipVerifier.prepare(value, inventory: [value], complete: false)
        XCTAssertNil(prepared.relatedItems.first?.ownershipEvidence)
    }

    func testOwnershipEvidenceSurvivesJournalEventsAndCannotBeReplaced() throws {
        let root = TestFileSystem.uniqueOperationRoot("SCM-Ownership")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { TestFileSystem.remove(root) }
        let file = root.appendingPathComponent("data")
        try Data("fixture".utf8).write(to: file)
        let identity = try FoundationReadOnlyFileSystem().snapshot(at: file).identity
        let evidence = UninstallOwnershipEvidence(basis: .containerRequirement, bundleID: "org.example.fixture", teamID: "test",
            applicationIdentity: identity, path: file.path, identity: identity, source: "fixture", sourceHash: "test", checkedAt: Date())
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("journal"))
        let report = RecordedTrashOperation.run(items: [.init(path: file.path, bytes: 7, identity: identity)], ruleID: "fixture",
            validate: { _ in }, move: { source in
                let target = root.appendingPathComponent("moved")
                try FileManager.default.moveItem(at: source, to: target)
                return target
            }, persist: { value, identities in
                var decorated = value; decorated.uninstallOwnership = [file.path: evidence]
                try journal.checkpoint(decorated, expectedIdentities: identities)
            })
        XCTAssertEqual(report.summary.movedItemCount, 1)
        var saved = try XCTUnwrap(journal.load().first)
        XCTAssertEqual(saved.uninstallOwnership?[file.path], evidence)
        saved.uninstallOwnership = [:]
        XCTAssertThrowsError(try journal.checkpoint(saved, expectedIdentities: [file.path: identity]))
    }

    func testUnknownContainerFormatAndMultipleOwnersAreRejected() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": "org.example.fixture",
            "MCMMetadataInfo": ["Owners": ["org.example.fixture", "org.other"], "Identity": [Data([1, 2, 3])]]], format: .binary, options: 0)
        XCTAssertFalse(UninstallOwnershipVerifier.containerMatches(data, appPath: "/Applications/Fixture.app", bundleID: "org.example.fixture"))
    }
}

/// 只读外部签名夹具；复制后再制造 metadata 篡改或移动副本。
/// 不恢复、重写或移动 manifest 指向的原件。
func copyOwnedUninstallFixture(for testCase: XCTestCase, manifest: String) throws
    -> (home: URL, app: URL, container: URL, bundleID: String) {
    let values = try XCTUnwrap(JSONSerialization.jsonObject(with:
        Data(contentsOf: URL(fileURLWithPath: manifest))) as? [String: String])
    let bundleID = try XCTUnwrap(values["bundleID"])
    let prefix = "org.storagecleaner.fixture."
    guard bundleID.hasPrefix(prefix),
          UUID(uuidString: String(bundleID.dropFirst(prefix.count))) != nil else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let sourceApp = URL(fileURLWithPath: try XCTUnwrap(values["app"]))
    let sourceContainer = URL(fileURLWithPath: try XCTUnwrap(values["container"]))
    let metadataSource = values["metadataFixture"].map { URL(fileURLWithPath: $0) }
        ?? sourceContainer.appendingPathComponent(UninstallOwnershipVerifier.metadataName)
    let data = try Data(contentsOf: metadataSource)
    guard data.count <= 1_048_576,
          UninstallOwnershipVerifier.containerMatches(data, appPath: sourceApp.path, bundleID: bundleID) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let home = try TestFileSystem.makeOperationHome(for: testCase)
    let app = home.appendingPathComponent("Applications/Fixture.app")
    let container = home.appendingPathComponent("Library/Containers/" + bundleID)
    try FileManager.default.copyItem(at: sourceApp, to: app)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try data.write(to: container.appendingPathComponent(UninstallOwnershipVerifier.metadataName), options: .atomic)
    return (home, app, container, bundleID)
}
