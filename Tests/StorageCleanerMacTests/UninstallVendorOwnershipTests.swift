import Foundation
import XCTest
@testable import StorageCleanerMac

/// D87: vendor paths are discovered at selection time, but only a current,
/// exactly matching rule proof can make them selectable. Uses a disposable
/// operation home; no real application data is read.
final class UninstallVendorOwnershipTests: XCTestCase {
    private func app(_ bundleID: String, version: String = "1.0", at path: String,
                     identity: FileIdentity?, related: [InstalledAppRelatedItem] = []) -> InstalledAppItem {
        InstalledAppItem(id: path, name: "Fixture", bundleIdentifier: bundleID, path: path,
            version: version, build: "1", category: "", appDescription: "", sizeBytes: 0,
            source: "fixture", modifiedAt: nil, scanIdentity: identity,
            relatedPaths: related.map(\.path), relatedItems: related, status: .installed)
    }

    private func makeDirectory(_ home: URL, _ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url.appendingPathComponent("item"))
        return url
    }

    func testVendorAndDiscoveryPathsAreFoundButUnsignedAppGetsNoEvidence() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "vendor-rules")
        let profile = try makeDirectory(home, "Library/Application Support/Google/Chrome")
        let applicationURL = try makeDirectory(home, "Applications/Google Chrome.app")
        let identity = try FoundationReadOnlyFileSystem().snapshot(at: applicationURL).identity
        let chrome = app("com.google.Chrome", at: applicationURL.path, identity: identity)
        let prepared = UninstallOwnershipVerifier.prepare(chrome, inventory: [chrome], complete: true, homeDirectory: home)
        let row = try XCTUnwrap(prepared.relatedItems.first { $0.path == profile.path })
        XCTAssertNotNil(row.scanIdentity)
        XCTAssertNil(row.ownershipEvidence, "an unsigned fixture can never satisfy the signer binding")
        XCTAssertEqual(row.ownershipBlockReason, .signatureUnverified)
        XCTAssertTrue(UninstallPresentation.selectablePaths(prepared).isEmpty)

        let docker = app("com.docker.docker", at: applicationURL.path, identity: identity)
        let group = try makeDirectory(home, "Library/Group Containers/group.com.docker")
        let dockerPrepared = UninstallOwnershipVerifier.prepare(docker, inventory: [docker], complete: true, homeDirectory: home)
        let groupRow = try XCTUnwrap(dockerPrepared.relatedItems.first { $0.path == group.path })
        XCTAssertNil(groupRow.ownershipEvidence)
        XCTAssertTrue(UninstallPresentation.selectablePaths(dockerPrepared).isEmpty)
    }

    func testMultipleInstallationsAndIncompleteInventoryStayBlocked() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "vendor-rules")
        _ = try makeDirectory(home, "Library/Application Support/Spotify")
        let first = try makeDirectory(home, "Applications/Spotify.app")
        let second = try makeDirectory(home, "Downloads/Spotify.app")
        let firstIdentity = try FoundationReadOnlyFileSystem().snapshot(at: first).identity
        let secondIdentity = try FoundationReadOnlyFileSystem().snapshot(at: second).identity
        let a = app("com.spotify.client", at: first.path, identity: firstIdentity)
        let b = app("com.spotify.client", at: second.path, identity: secondIdentity)
        let duplicated = UninstallOwnershipVerifier.prepare(a, inventory: [a, b], complete: true, homeDirectory: home)
        XCTAssertFalse(duplicated.relatedItems.isEmpty)
        XCTAssertTrue(duplicated.relatedItems.allSatisfy { $0.ownershipEvidence == nil })
        XCTAssertTrue(duplicated.relatedItems.contains { $0.ownershipBlockReason == .otherInstallations })
        let incomplete = UninstallOwnershipVerifier.prepare(a, inventory: [a], complete: false, homeDirectory: home)
        XCTAssertTrue(incomplete.relatedItems.allSatisfy { $0.ownershipEvidence == nil && $0.ownershipBlockReason == .inventoryIncomplete })
    }

    func testVendorProofIsCurrentOnlyForExactTeamPathRevisionAndVersion() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "vendor-rules")
        let data = try makeDirectory(home, "Library/Application Support/JetBrains/IntelliJIdea2026.2")
        let other = try makeDirectory(home, "Library/Application Support/JetBrains/IntelliJIdea2026.1")
        let discovery = try makeDirectory(home, "Library/Application Support/JetBrains/Toolbox")
        let applicationURL = try makeDirectory(home, "Applications/IntelliJ IDEA.app")
        let appIdentity = try FoundationReadOnlyFileSystem().snapshot(at: applicationURL).identity
        let rule = try XCTUnwrap(UninstallVendorRules.rules(bundleID: "com.jetbrains.intellij", version: "2026.2.1",
                                                            teamID: UninstallVendorRules.jetBrainsTeamID).first)

        func evaluate(path: URL, bundleID: String = "com.jetbrains.intellij", team: String = UninstallVendorRules.jetBrainsTeamID,
                      revision: String? = nil, version: String = "2026.2.1") throws -> Bool {
            let identity = try FoundationReadOnlyFileSystem().snapshot(at: path).identity
            let proof = UninstallOwnershipEvidence(basis: .vendorRule, bundleID: bundleID, teamID: team,
                applicationIdentity: appIdentity, path: path.path, identity: identity,
                source: rule.source, sourceHash: revision ?? rule.revision, checkedAt: Date(),
                applicationVersion: version, applicationBuild: "1")
            let item = InstalledAppRelatedItem(path: path.path, sizeBytes: 0, scanIdentity: identity, ownershipEvidence: proof)
            let value = app(bundleID, version: version, at: applicationURL.path, identity: appIdentity, related: [item])
            return UninstallOwnershipVerifier.isCurrent(item, app: value, homeDirectory: home)
        }
        XCTAssertTrue(try evaluate(path: data))
        XCTAssertFalse(try evaluate(path: data, team: "ABCDE12345"))
        XCTAssertFalse(try evaluate(path: data, revision: "jetbrains-intellijidea-versioned-old"))
        XCTAssertFalse(try evaluate(path: data, version: "2026.1.3"), "an upgraded IDE does not own the old folder")
        XCTAssertFalse(try evaluate(path: other))
        XCTAssertFalse(try evaluate(path: discovery), "discovery-only folders never verify")
        XCTAssertFalse(try evaluate(path: data, bundleID: "com.jetbrains.intellij.ce"))
    }

    /// 修复轮 1: shared group containers (WeChat, Telegram, Docker) are shown
    /// by path only; nothing inside them is walked to measure a size.
    func testSharedGroupContainersAreListedWithoutMeasuring() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "vendor-rules")
        let applicationURL = try makeDirectory(home, "Applications/Docker.app")
        let identity = try FoundationReadOnlyFileSystem().snapshot(at: applicationURL).identity
        let group = try makeDirectory(home, "Library/Group Containers/group.com.docker")
        let container = try makeDirectory(home, "Library/Containers/com.docker.docker")
        let docker = app("com.docker.docker", at: applicationURL.path, identity: identity)
        let prepared = UninstallOwnershipVerifier.prepare(docker, inventory: [docker], complete: true, homeDirectory: home)
        let groupRow = try XCTUnwrap(prepared.relatedItems.first { $0.path == group.path })
        XCTAssertFalse(groupRow.sizeIsKnown)
        XCTAssertEqual(groupRow.sizeBytes, 0)
        XCTAssertNotNil(groupRow.scanIdentity, "existence is still checked with lstat")
        XCTAssertNil(groupRow.ownershipEvidence)
        let containerRow = try XCTUnwrap(prepared.relatedItems.first { $0.path == container.path })
        XCTAssertTrue(containerRow.sizeIsKnown)
        XCTAssertGreaterThan(containerRow.sizeBytes, 0)
    }

    /// 修复轮 1: a proved Chrome profile or Docker container stays
    /// selectable one by one, but "Select All Verified" never includes it.
    func testHighValueDataIsNeverPartOfSelectAllVerified() throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "vendor-rules")
        let applicationURL = try makeDirectory(home, "Applications/Fixture.app")
        let appIdentity = try FoundationReadOnlyFileSystem().snapshot(at: applicationURL).identity
        func proved(_ relative: String, bundleID: String) throws -> InstalledAppRelatedItem {
            let url = try makeDirectory(home, relative)
            let identity = try FoundationReadOnlyFileSystem().snapshot(at: url).identity
            let proof = UninstallOwnershipEvidence(basis: .vendorRule, bundleID: bundleID, teamID: "ABCDE12345",
                applicationIdentity: appIdentity, path: url.path, identity: identity, source: "fixture",
                sourceHash: "fixture", checkedAt: Date(), applicationVersion: "1.0", applicationBuild: "1")
            return InstalledAppRelatedItem(path: url.path, sizeBytes: 1, scanIdentity: identity, ownershipEvidence: proof)
        }
        let profile = try proved("Library/Application Support/Google/Chrome", bundleID: "com.google.Chrome")
        let cache = try proved("Library/Caches/com.google.Chrome", bundleID: "com.google.Chrome")
        let chrome = app("com.google.Chrome", at: applicationURL.path, identity: appIdentity, related: [profile, cache])
        XCTAssertEqual(UninstallPresentation.selectablePaths(chrome), [profile.path, cache.path])
        XCTAssertEqual(UninstallPresentation.bulkSelectablePaths(chrome), [cache.path])

        let volumes = try proved("Library/Containers/com.docker.docker", bundleID: "com.docker.docker")
        let docker = app("com.docker.docker", at: applicationURL.path, identity: appIdentity, related: [volumes])
        XCTAssertEqual(UninstallPresentation.selectablePaths(docker), [volumes.path])
        XCTAssertTrue(UninstallPresentation.bulkSelectablePaths(docker).isEmpty)

        let sheet = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/UninstallPreviewSheet.swift")
        XCTAssertTrue(sheet.contains("UninstallPresentation.bulkSelectablePaths(app)"))
        XCTAssertTrue(sheet.contains("let paths = Set(bulk.map(\\.path))"))
        XCTAssertTrue(sheet.contains("UninstallVendorRules.highValueData(path: item.path)"))
    }
}
