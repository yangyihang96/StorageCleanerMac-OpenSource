import Foundation
import XCTest
@testable import StorageCleanerMac

/// D183: isolated metadata fixtures only; never reads the user's Mail store.
final class MailLibraryAttachmentRuleTests: XCTestCase {
    private let rule = CleanupCoverageCatalog.mailLibraryAttachmentFoldersRule
    private let inbox = "V10/32B7E404-A79C-4E5A-BCEB-B8C9B9D7978D/INBOX.mbox/604B/Data/1/2/Attachments"

    func testRuleIsReviewedSelectableAndInTheBaseline() throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let loaded = try XCTUnwrap(bundled.rules.first { $0.id == rule.id })
        XCTAssertEqual(loaded.root.kind, .homeRelative)
        XCTAssertEqual(loaded.root.path, "Library/Mail")
        XCTAssertEqual(loaded.effectiveCandidateScope, .namedDescendantDirectories)
        XCTAssertEqual(loaded.maximumDepth, 16)
        XCTAssertEqual(loaded.maximumCandidates, 400)
        XCTAssertEqual(loaded.minimumBytes, 1_000_000)
        XCTAssertEqual(loaded.minimumAgeDays, 0)
        XCTAssertEqual(loaded.include.entryKinds, [.directory])
        XCTAssertEqual(loaded.include.nameMatcher.mode, .exact)
        XCTAssertEqual(loaded.include.nameMatcher.values, ["Attachments"])
        XCTAssertEqual(loaded.cloudPolicy, .skipPlaceholder)
        XCTAssertEqual(loaded.risk, .reviewOnly)
        XCTAssertEqual(loaded.recommendation, .optional)
        XCTAssertEqual(loaded.defaultSelection, .unselected)
        XCTAssertEqual(loaded.executionEligibility, .eligibleAfterReview)
        XCTAssertEqual(loaded.measurementRequirement, .complete)
        XCTAssertTrue(loaded.allowsManualSelection)
        XCTAssertEqual(loaded.action, .moveToTrashAfterReview)
        XCTAssertFalse(loaded.action.permanentlyDeletes)
        XCTAssertEqual(loaded.requiredClosedBundleIDs, ["com.apple.mail"])
        XCTAssertEqual(loaded.ownerDisplayName, "Apple Mail")
        XCTAssertNil(bundled.rules.first { $0.id == "mail.library-attachments" })
        let baseline = try CleanupRuleTestFixtures.baseline()
        let hash = try CleanupRuleFingerprint.contentHash(for: loaded)
        let entry = try XCTUnwrap(baseline.entries.first { $0.ruleID == rule.id }, "D183 baseline contentHash: \(hash)")
        XCTAssertEqual(entry.revision, 1)
        XCTAssertEqual(entry.contentHash, hash)
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(bundled, baseline: baseline))
    }

    func testNamedDescendantsRejectUnsafeCombinationsAndAggregateStaysRejected() throws {
        let unsafeFields: [[String: Any]] = [
            ["include": include(kinds: ["directory", "regularFile"])],
            ["include": include(kinds: ["regularFile"])],
            ["include": include(mode: "prefix")],
            ["include": include(mode: "any", names: [])],
            ["include": include(names: [])],
            ["include": include(names: [""])],
            ["risk": "safe"], ["risk": "protected"], ["risk": "informational"],
            ["defaultSelection": "selected"], ["defaultSelection": "forbidden"],
            ["action": "moveToTrash"], ["action": "revealOnly"], ["action": "emptyTrash"],
            ["action": "moveToTrashAfterProtectedReview"],
            ["requiredClosedBundleIDs": []],
            ["root": ["kind": "applicationsDirectory", "path": "/Applications"]],
            ["root": ["kind": "mountedVolumeTrashes", "path": "/Volumes"]],
            ["executionEligibility": "eligible"], ["allowsManualSelection": false],
            ["measurementRequirement": "bestEffort"],
            ["candidateScope": "descendantAggregate"],
        ]
        for fields in unsafeFields {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: fields)
            XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([changed])), "\(fields)")
        }
        for limit in [0, -1, 1_001] {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: ["maximumCandidates": limit])
            XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([changed]))) {
                XCTAssertEqual($0 as? CleanupRuleValidationError, .invalidLimit(ruleID: self.rule.id))
            }
        }
        for limit in [1, 400, 1_000] {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: ["maximumCandidates": limit])
            XCTAssertNoThrow(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([changed])))
        }
        XCTAssertNoThrow(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([rule])))
    }

    func testOnlyD183CanEnterTheProtectedMailLibrary() throws {
        for fields: [String: Any] in [
            ["id": "mail.other"], ["candidateScope": "immediateChildren"],
            ["include": include(names: ["Messages"])],
            ["include": include(names: ["Attachments", "Messages"])],
            ["requiredClosedBundleIDs": ["com.example.mail"]],
            ["root": ["kind": "homeRelative", "path": "Library/Mail/V10"]],
            ["root": ["kind": "homeRelative", "path": "Library/Safari"]],
        ] {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: fields)
            XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([changed])), "\(fields)")
        }
        XCTAssertEqual(ProtectedLocations.kind(ofHomeRelative: "Library/Mail"), .systemData)
        XCTAssertTrue(ProtectedLocations.protects(path: "/H/Library/Mail/V10/Attachments", homePath: "/H"))
    }

    func testScopeAndCandidateOverrideParticipateInFingerprint() throws {
        let data = try CleanupRuleFingerprint.normalizedData(for: rule)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["candidateScope"] as? String, "namedDescendantDirectories")
        XCTAssertEqual(object["maximumCandidates"] as? Int, 400)
        let changed = try CleanupRuleTestFixtures.replacing(rule, fields: ["maximumCandidates": 401])
        XCTAssertNotEqual(try CleanupRuleFingerprint.contentHash(for: rule), try CleanupRuleFingerprint.contentHash(for: changed))
        let oldRule = CleanupCoverageCatalog.mailDownloadedAttachmentsRule
        let oldObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: CleanupRuleFingerprint.normalizedData(for: oldRule)) as? [String: Any])
        XCTAssertNil(oldObject["maximumCandidates"], "D183 must preserve old rule hashes when no override exists")
    }

    func testDiscoversExactDirectoriesThroughPackagesAndMeasuresEachWholeFolder() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let first = try seed(home, relative: inbox)
        try CleanupRuleTestFixtures.write(first.appendingPathComponent("8/2/file.pdf"), bytes: 1_200_000)
        // A nested match contributes bytes to its parent but never becomes a row.
        try CleanupRuleTestFixtures.write(first.appendingPathComponent("nested/Attachments/file.pdf"), bytes: 1_200_000)
        let archive = try seed(home, relative: "V10/ACCOUNT/Archive.mbox/2025.mbox/U/Data/1/Attachments")
        try seed(home, relative: "V10/ACCOUNT/INBOX.mbox/U/Data/1/Attachments-old")
        let messages = home.appendingPathComponent("Library/Mail/V10/ACCOUNT/INBOX.mbox/U/Data/1/Messages/1.emlx")
        try CleanupRuleTestFixtures.write(messages, bytes: 1_200_000)
        try CleanupRuleTestFixtures.write(home.appendingPathComponent("Library/Mail/V10/regular-file/Attachments"), bytes: 1_200_000)
        let outside = home.appendingPathComponent("outside/Attachments")
        try CleanupRuleTestFixtures.write(outside.appendingPathComponent("file.pdf"), bytes: 1_200_000)
        let linked = home.appendingPathComponent("Library/Mail/V10/linked-account")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside.deletingLastPathComponent())
        let directLink = home.appendingPathComponent("Library/Mail/V10/Attachments")
        try FileManager.default.createSymbolicLink(at: directLink, withDestinationURL: outside)

        let probe = MailDirectoryProbe()
        let session = try await scan(home, fileSystem: MailDirectoryFileSystem(root: home, probe: probe))
        XCTAssertEqual(Set(session.candidates.map(\.sourceURL.path)), [first.path, archive.path], "\(session.issues)")
        let measured = try XCTUnwrap(session.candidates.first { $0.sourceURL.path == first.path })
        XCTAssertEqual(measured.snapshot.logicalSizeBytes, 3_600_000)
        XCTAssertTrue(session.candidates.allSatisfy { $0.measurementCompleteness == .complete })
        XCTAssertTrue(session.candidates.allSatisfy { $0.risk == .reviewOnly && $0.isManuallySelectable })
        XCTAssertTrue(session.candidates.allSatisfy { $0.selectionEligibility == .selectableWithReview })
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.isEmpty)
        XCTAssertTrue(session.issues.contains { $0.path == linked.path && $0.kind == .symbolicLinkSkipped })
        XCTAssertTrue(session.issues.contains { $0.path == directLink.path && $0.kind == .symbolicLinkSkipped })
        XCTAssertFalse(probe.listings.contains { $0.hasPrefix(first.path) }, "Discovery stops at the matching folder")
        XCTAssertFalse(probe.snapshots.contains(messages.path), "Message files do not need full metadata during discovery")
    }

    func testMaximumDepthIncludesTheBoundaryButNeverDeeperCandidates() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let boundary = (1...15).map { "d\($0)" }.joined(separator: "/") + "/Attachments"
        let tooDeep = "too-deep/" + boundary
        let allowed = try seed(home, relative: boundary)
        try seed(home, relative: tooDeep)
        let session = try await scan(home)
        XCTAssertEqual(session.candidates.map(\.sourceURL.path), [allowed.path], "\(session.issues)")
        XCTAssertTrue(session.candidates.allSatisfy { $0.measurementCompleteness == .complete })
    }

    func testKeepsLargest400FoldersAndOtherRulesStillKeep40() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        var largest = Set<String>()
        for index in 0..<405 {
            let url = home.appendingPathComponent("Library/Mail/V10/\(index)/Attachments")
            try CleanupRuleTestFixtures.write(url.appendingPathComponent("file.pdf"), bytes: index < 5 ? 4_096 : 8_192)
            if index >= 5 { largest.insert(url.path) }
        }
        for index in 0..<45 {
            try CleanupRuleTestFixtures.write(home.appendingPathComponent("Library/Caches/tool\(index)/cache.bin"), bytes: 8_192)
        }
        let mail = try CleanupRuleTestFixtures.replacing(rule, fields: ["minimumBytes": 1])
        let originalCache = try XCTUnwrap(try CleanupRuleSetLoader.loadBundled().rules.first { $0.id == "system.user-caches" })
        // Keep the real rule's nil cap, lowering only this fixture's 50 MiB
        // byte threshold so the cap test does not need gigabytes of payload.
        let cache = try CleanupRuleTestFixtures.replacing(originalCache, fields: ["minimumBytes": 1])
        let session = try await scan(home, rules: [mail, cache])
        XCTAssertEqual(Set(session.candidates.filter { $0.ruleID == rule.id }.map(\.sourceURL.path)), largest)
        XCTAssertEqual(session.candidates.filter { $0.ruleID == cache.id }.count, 40)
        XCTAssertEqual(session.metrics.truncatedCandidateCount, 10)
    }

    func testWalkTimeoutIsReportedFromInsideTheDirectoryListing() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        try seed(home, relative: inbox)
        let fileSystem = MailDirectoryFileSystem(root: home, listingDelay: 0.1)
        let session = try await scan(home, fileSystem: fileSystem, maximumDuration: 0.05)
        XCTAssertEqual(session.outcome, .partial)
        XCTAssertTrue(session.issues.contains { $0.kind == .timedOut })
        XCTAssertTrue(session.candidates.isEmpty)
    }

    func testDeniedBranchIsReportedWhileOtherMailboxesRemainReadable() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let allowed = try seed(home, relative: inbox)
        try seed(home, relative: "denied/Attachments")
        let denied = home.appendingPathComponent("Library/Mail/denied")
        let session = try await scan(home, fileSystem: MailDirectoryFileSystem(root: home, denied: denied))
        XCTAssertEqual(session.candidates.map(\.sourceURL.path), [allowed.path])
        XCTAssertEqual(session.outcome, .partial)
        XCTAssertTrue(session.issues.contains { $0.path == denied.path && $0.kind == .permissionDenied })
    }

    func testDeniedLibraryRootUsesTheExistingPermissionReport() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        try seed(home, relative: inbox)
        let root = home.appendingPathComponent(rule.root.path)
        let session = try await scan(home, fileSystem: MailDirectoryFileSystem(root: home, denied: root))
        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertEqual(session.outcome, .partial)
        XCTAssertEqual(session.permissions.first { $0.ruleID == rule.id }?.status, .permissionDenied)
        XCTAssertEqual(session.coverageLimits.deniedLocationCount, 1)
    }

    @discardableResult
    private func seed(_ home: URL, relative: String) throws -> URL {
        let url = home.appendingPathComponent("Library/Mail/" + relative)
        try CleanupRuleTestFixtures.write(url.appendingPathComponent("7/1/file.pdf"), bytes: 1_200_000)
        return url
    }

    private func include(kinds: [String] = ["directory"], mode: String = "exact", names: [String] = ["Attachments"]) -> [String: Any] {
        ["entryKinds": kinds, "extensions": [], "nameMatcher": ["mode": mode, "values": names]]
    }

    private func scan(_ home: URL, rules: [CleanupRule]? = nil,
                      fileSystem: (any ReadOnlyFileSystem)? = nil, maximumDuration: TimeInterval = 300) async throws -> ScanSession {
        let scanner = try ReadOnlyCleanupScanner(fileSystem: fileSystem ?? MailDirectoryFileSystem(root: home),
            ruleSet: CleanupRuleTestFixtures.set(rules ?? [rule]))
        return try await scanner.scan(request: CleanupScanRequest(userHomeURL: home, maximumDuration: maximumDuration)) { _ in }
    }
}

private final class MailDirectoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var listed = [String]()
    private var read = [String]()
    var listings: [String] { lock.withLock { listed } }
    var snapshots: [String] { lock.withLock { read } }
    func listing(_ path: String) { lock.withLock { listed.append(path) } }
    func snapshot(_ path: String) { lock.withLock { read.append(path) } }
}

private struct MailDirectoryFileSystem: ReadOnlyFileSystem {
    let root: URL
    var probe: MailDirectoryProbe? = nil
    var listingDelay: TimeInterval = 0
    var denied: URL? = nil

    func snapshot(at url: URL) throws -> FileSnapshot {
        probe?.snapshot(url.path)
        return try RuleTestReadOnlyFileSystem(root: root).snapshot(at: url)
    }
    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        try RuleTestReadOnlyFileSystem(root: root).aggregateSnapshot(at: url)
    }
    func children(of directory: URL) throws -> [URL] {
        try FoundationReadOnlyFileSystem().children(of: directory)
    }
    func directoryEntries(of directory: URL, checking: () throws -> Void) throws -> [URL] {
        probe?.listing(directory.path)
        if directory.path == denied?.path { throw CleanupFileSystemError.permissionDenied }
        if listingDelay > 0 { Thread.sleep(forTimeInterval: listingDelay) }
        return try FoundationReadOnlyFileSystem().directoryEntries(of: directory, checking: checking)
    }
}
