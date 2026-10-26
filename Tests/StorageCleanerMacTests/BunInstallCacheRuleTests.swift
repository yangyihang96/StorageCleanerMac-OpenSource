import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D101 G10: Bun's install cache. Only `~/.bun/install/cache` is listed, never
/// `~/.bun/bin` or the global installs. On macOS Bun clones the cache into
/// projects, so a cache whose files are cloned frees little and is not
/// preselected; its row says how much it frees.
final class BunInstallCacheRuleTests: XCTestCase {
    private static let mib = 1_024 * 1_024

    func testTheBundledRuleCoversOnlyTheInstallCache() throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        XCTAssertNoThrow(try CleanupRuleValidator.validate(bundled))
        let bun = try XCTUnwrap(bundled.rules.first { $0.id == "developer.bun-install-cache" })
        XCTAssertEqual(bun.root.kind, .homeRelative)
        XCTAssertEqual(bun.root.path, ".bun/install/cache")
        XCTAssertEqual(bun.effectiveCandidateScope, .root)
        XCTAssertEqual(bun.minimumBytes, 50 * Int64(Self.mib))
        XCTAssertEqual(bun.risk, .safe)
        XCTAssertEqual(bun.recommendation, .optional)
        XCTAssertEqual(bun.defaultSelection, .unselected)
        XCTAssertEqual(bun.action, .moveToTrash)
        XCTAssertTrue(bun.requiredClosedBundleIDs.isEmpty)
        // Graded by developer activity like the other developer caches (D22).
        XCTAssertTrue(DeveloperCleanupAgePolicy.applies(to: bun))

        let maintenance = try XCTUnwrap(bun.maintenance)
        XCTAssertEqual(maintenance.source, .json)
        XCTAssertEqual(maintenance.checkedAt, "2026-10-15")
        XCTAssertEqual(maintenance.evidenceURLs, ["https://bun.sh/docs/install/cache", "https://bun.sh/docs/cli/pm"])
        XCTAssertNotNil(CleanupImpactText.englishByChinese[maintenance.impact])
        // The rule enters the reviewed baseline at revision 1, so any later
        // change to it must raise the revision.
        let baseline = try CleanupRuleTestFixtures.baseline()
        let entry = try XCTUnwrap(baseline.entries.first { $0.ruleID == bun.id })
        XCTAssertEqual(entry.revision, 1)
        XCTAssertEqual(maintenance.revision, 1)
        XCTAssertEqual(entry.contentHash, try CleanupRuleFingerprint.contentHash(for: bun))
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(bundled, baseline: baseline))

        // Its safe root is the cache alone: the rule may not start any higher
        // (`~/.bun` holds the Bun binary) nor beside it.
        XCTAssertNoThrow(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([bun])))
        for root in [".bun", ".bun/install", ".bun/install/global", ".bun/bin"] {
            let moved = try CleanupRuleTestFixtures.replacing(bun, fields: ["root": ["kind": "homeRelative", "path": root]])
            XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([moved])), root)
        }
    }

    /// With every bundled rule, only the cache folder under `~/.bun` is
    /// listed; the binary and the global installs are not, however large.
    func testNothingElseUnderBunIsListed() async throws {
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let bun = home.appendingPathComponent(".bun")
        try CleanupRuleTestFixtures.write(bun.appendingPathComponent("install/cache/left-pad@1.3.0@@@1/index.js"),
                                          bytes: 2 * Self.mib)
        try CleanupRuleTestFixtures.write(bun.appendingPathComponent("bin/bun"), bytes: 2 * Self.mib)
        try CleanupRuleTestFixtures.write(bun.appendingPathComponent("install/global/node_modules/tool/index.js"),
                                          bytes: 2 * Self.mib)
        try CleanupRuleTestFixtures.write(bun.appendingPathComponent("install/global/package.json"),
                                          bytes: 2 * Self.mib)
        try CleanupRuleTestFixtures.ageTree(home)

        let bundled = try CleanupRuleSetLoader.loadBundled()
        let session = try await CleanupRuleTestFixtures.scan(
            CleanupRuleTestFixtures.set(try bundled.rules.map(lowered)), home: home)
        let underBun = session.candidates.filter { lexicalPath($0).hasPrefix(bun.path + "/") }
        XCTAssertEqual(underBun.map(lexicalPath), [bun.appendingPathComponent("install/cache").path],
                       "Scan issues: \(session.issues)")
        let cache = try XCTUnwrap(underBun.first)
        XCTAssertEqual(cache.ruleID, "developer.bun-install-cache")
        XCTAssertEqual(cache.risk, .safe)
        let selected = CleanupSelection.defaults(in: session).selectedCandidateIDs
        XCTAssertTrue(session.candidates.filter { selected.contains($0.id) }
            .allSatisfy { !lexicalPath($0).hasPrefix(bun.path + "/") || $0.id == cache.id })
    }

    /// A cache whose package is cloned into a project frees almost nothing:
    /// it stays green and selectable, is not preselected, and its row says
    /// how much it frees. The same cache without the clone is preselected.
    func testAClonedCacheIsListedButNotPreselected() async throws {
        let rule = try lowered(try XCTUnwrap(
            try CleanupRuleSetLoader.loadBundled().rules.first { $0.id == "developer.bun-install-cache" }))
        let size = 4 * Self.mib

        let control = try makeRoot().appendingPathComponent("Home")
        try writeRandom(size, to: control.appendingPathComponent(".bun/install/cache/react@19.0.0@@@1/index.js"))
        try CleanupRuleTestFixtures.ageTree(control.appendingPathComponent(".bun"))
        let controlSession = try await scan(rule, home: control)
        let alone = try XCTUnwrap(controlSession.candidates.first)
        XCTAssertEqual(alone.risk, .safe)
        XCTAssertEqual(alone.reclaimableSizeBytes, alone.estimatedSizeBytes)
        XCTAssertFalse(alone.freesTooLittleToPreselect)
        XCTAssertTrue(alone.isPreselectedByDefault)
        XCTAssertEqual(alone.preselectionReason, .preselected)

        let home = try makeRoot().appendingPathComponent("Home")
        let package = home.appendingPathComponent(".bun/install/cache/react@19.0.0@@@1/index.js")
        try writeRandom(size, to: package)
        try makeClone(of: package, at: home.appendingPathComponent("Projects/app/node_modules/react/index.js"))
        try CleanupRuleTestFixtures.ageTree(home.appendingPathComponent(".bun"))
        let session = try await scan(rule, home: home)
        let cloned = try XCTUnwrap(session.candidates.first)
        XCTAssertEqual(session.candidates.count, 1)
        XCTAssertEqual(cloned.sourceURL.path, home.appendingPathComponent(".bun/install/cache").path)
        XCTAssertEqual(cloned.risk, .safe)
        XCTAssertTrue(cloned.isSelectable)
        XCTAssertEqual(cloned.reclaimableEstimate?.reason, .sharedWithClones)
        XCTAssertLessThan(cloned.reclaimableSizeBytes, Int64(Self.mib))
        XCTAssertTrue(cloned.freesTooLittleToPreselect)
        XCTAssertFalse(cloned.isPreselectedByDefault)
        XCTAssertEqual(cloned.preselectionReason, .freesLittle)
        XCTAssertNotNil(CleanupCandidateRowHint.reclaimable(for: cloned))
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.isEmpty)
    }

    /// D116: when both copies of a clone lie inside the cache, cleaning the
    /// cache removes both and frees the shared data, so the row is
    /// preselected. The conservative amount and the row note are unchanged.
    func testACacheWhoseClonesAllLieInsideItIsPreselected() async throws {
        let rule = try lowered(try XCTUnwrap(
            try CleanupRuleSetLoader.loadBundled().rules.first { $0.id == "developer.bun-install-cache" }))
        let size = 4 * Self.mib
        let home = try makeRoot().appendingPathComponent("Home")
        let cache = home.appendingPathComponent(".bun/install/cache")
        let package = cache.appendingPathComponent("react@19.0.0@@@1/index.js")
        try writeRandom(size, to: package)
        try makeClone(of: package, at: cache.appendingPathComponent("react@19.0.0@@@2/index.js"))
        try CleanupRuleTestFixtures.ageTree(home.appendingPathComponent(".bun"))

        let session = try await scan(rule, home: home)
        let row = try XCTUnwrap(session.candidates.first)
        XCTAssertEqual(session.candidates.count, 1)
        XCTAssertEqual(row.sourceURL.path, cache.path)
        let estimate = try XCTUnwrap(row.reclaimableEstimate)
        XCTAssertEqual(estimate.reason, .sharedWithClones)
        XCTAssertGreaterThanOrEqual(estimate.wholeCloneGroupBytes, Int64(size))
        XCTAssertLessThan(row.reclaimableSizeBytes, Int64(Self.mib))
        XCTAssertNotNil(CleanupCandidateRowHint.reclaimable(for: row))
        XCTAssertFalse(row.freesTooLittleToPreselect)
        XCTAssertTrue(row.isPreselectedByDefault)
        XCTAssertEqual(row.preselectionReason, .preselected)
        XCTAssertEqual(CleanupSelection.defaults(in: session).selectedCandidateIDs, [row.id])
    }

    // MARK: Helpers

    /// Lower the size floor so small fixtures are listed; catalog coverage
    /// rules validate their sizes exactly and stay as they are.
    private func lowered(_ rule: CleanupRule) throws -> CleanupRule {
        guard !CleanupCoverageCatalog.cleanupRules.contains(where: { $0.id == rule.id }) else { return rule }
        return try CleanupRuleTestFixtures.replacing(rule, fields: ["minimumBytes": 1])
    }

    /// Rule roots keep the home's spelling (/var/...), but items found by
    /// listing a folder are spelled /private/var/...; compare lexically.
    private func lexicalPath(_ candidate: ScanCandidate) -> String {
        PathSafety.lexicalPath(candidate.sourceURL.path)
    }

    private func makeRoot() throws -> URL {
        let root = TestFileSystem.uniqueRoot("BunInstallCache")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeRandom(_ count: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        try data.write(to: url)
    }

    private func makeClone(of source: URL, at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw XCTSkip("clonefile is not supported here (errno \(errno))")
        }
    }

    private func scan(_ rule: CleanupRule, home: URL) async throws -> ScanSession {
        let scanner = try ReadOnlyCleanupScanner(fileSystem: BunFixtureFileSystem(),
                                                 ruleSet: CleanupRuleTestFixtures.set([rule]))
        return try await scanner.scan(request: CleanupScanRequest(userHomeURL: home)) { _ in }
    }
}

/// The real file system, sharing included, under a temporary folder whose
/// path goes through /var -> /private/var.
private struct BunFixtureFileSystem: ReadOnlyFileSystem {
    func snapshot(at url: URL) throws -> FileSnapshot {
        try unlinked(FoundationReadOnlyFileSystem().snapshot(at: url))
    }

    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        try unlinked(FoundationReadOnlyFileSystem().aggregateSnapshot(at: url))
    }

    func children(of directory: URL) throws -> [URL] {
        try FoundationReadOnlyFileSystem().children(of: directory)
    }

    func storageSharing(at url: URL) -> FileStorageSharing.Reading {
        FoundationReadOnlyFileSystem().storageSharing(at: url)
    }

    private func unlinked(_ snapshot: FileSnapshot) -> FileSnapshot {
        FileSnapshot(
            identity: snapshot.identity, standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier, logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume, isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder, hasSymbolicLinkComponent: false
        )
    }
}
