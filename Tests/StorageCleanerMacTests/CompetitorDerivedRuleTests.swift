import Foundation
import XCTest
@testable import StorageCleanerMac

/// D145 (清理软件逆向 2026-10-19): four developer rules taken from what
/// CleanMyMac 5.7.2 lists and we did not (`分报告/cleanmymac.md` §2.2, §7):
/// Xcode device support, the Gradle and Cargo download caches, and Claude
/// Code's queued telemetry. Each is green, optional and graded by developer
/// activity (D22), enters the reviewed baseline at revision 1, and lists only
/// its own folder: the Gradle settings, Cargo credentials and binaries,
/// Claude Code sessions and shell snapshots stay out.
final class CompetitorDerivedRuleTests: XCTestCase {
    private static let mib = 1_024 * 1_024

    private static let expected: [(id: String, root: String, names: [String], closed: [String])] = [
        ("developer.xcode-ios-device-support", "Library/Developer/Xcode/iOS DeviceSupport", [], ["com.apple.dt.Xcode"]),
        ("developer.gradle-cache", ".gradle", ["caches"], []),
        ("developer.cargo-registry-cache", ".cargo/registry", ["cache"], []),
        ("developer.claude-code-telemetry", ".claude", ["telemetry"], [])
    ]

    func testTheRulesAreGreenOptionalAndInTheReviewedBaseline() throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        XCTAssertNoThrow(try CleanupRuleValidator.validate(bundled))
        let baseline = try CleanupRuleTestFixtures.baseline()
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(bundled, baseline: baseline))
        for expected in Self.expected {
            let rule = try XCTUnwrap(bundled.rules.first { $0.id == expected.id }, expected.id)
            XCTAssertEqual(rule.root.kind, .homeRelative, expected.id)
            XCTAssertEqual(rule.root.path, expected.root, expected.id)
            XCTAssertEqual(rule.effectiveCandidateScope, .immediateChildren, expected.id)
            if expected.names.isEmpty {
                XCTAssertEqual(rule.include.nameMatcher.mode, .any, expected.id)
            } else {
                XCTAssertEqual(rule.include.nameMatcher.mode, .exact, expected.id)
                XCTAssertEqual(rule.include.nameMatcher.values, expected.names, expected.id)
            }
            XCTAssertEqual(rule.include.entryKinds, [.directory], expected.id)
            XCTAssertEqual(rule.risk, .safe, expected.id)
            XCTAssertEqual(rule.recommendation, .optional, expected.id)
            XCTAssertEqual(rule.defaultSelection, .unselected, expected.id)
            XCTAssertEqual(rule.action, .moveToTrash, expected.id)
            XCTAssertEqual(rule.requiredClosedBundleIDs, expected.closed, expected.id)
            XCTAssertEqual(rule.categoryID, "developer", expected.id)
            XCTAssertTrue(DeveloperCleanupAgePolicy.applies(to: rule), "\(expected.id) is graded by activity (D22)")

            let maintenance = try XCTUnwrap(rule.maintenance, expected.id)
            XCTAssertEqual(maintenance.revision, 1, expected.id)
            XCTAssertEqual(maintenance.checkedAt, "2026-10-19", expected.id)
            XCTAssertNotNil(CleanupImpactText.englishByChinese[maintenance.impact], expected.id)
            let entry = try XCTUnwrap(baseline.entries.first { $0.ruleID == rule.id }, expected.id)
            XCTAssertEqual(entry.revision, 1, expected.id)
            XCTAssertEqual(entry.contentHash, try CleanupRuleFingerprint.contentHash(for: rule), expected.id)
        }
        // D227＋旧值：was "2026.10.20.1" (D-FP6 added the broken preferences rule).
        XCTAssertEqual(bundled.rulesVersion, "2026.10.26.1", "D227 retired the two Downloads rules")
    }

    /// With every bundled rule, only the new folders are listed under these
    /// roots; settings, credentials, binaries, sources, sessions and shell
    /// snapshots beside them are not, however large.
    func testOnlyTheNamedFoldersAreListed() async throws {
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let write = { (path: String) in
            try CleanupRuleTestFixtures.write(home.appendingPathComponent(path), bytes: 2 * Self.mib)
        }
        try write("Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)/Symbols/usr/lib/dyld")
        try write("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)/Symbols/usr/lib/dyld")
        try write(".gradle/caches/modules-2/files-2.1/lib.jar")
        try write(".gradle/gradle.properties")
        try write(".gradle/wrapper/dists/gradle-8.9-bin/gradle.zip")
        try write(".cargo/registry/cache/index.crates.io-6f17d22bba15001f/serde-1.0.0.crate")
        try write(".cargo/registry/src/index.crates.io-6f17d22bba15001f/serde-1.0.0/lib.rs")
        try write(".cargo/bin/cargo")
        try write(".cargo/credentials.toml")
        try write(".claude/telemetry/1p_failed_events.json")
        try write(".claude/shell-snapshots/snapshot-zsh.sh")
        try write(".claude/projects/app/session.jsonl")
        try write(".claude/settings.json")
        try CleanupRuleTestFixtures.ageTree(home)

        let bundled = try CleanupRuleSetLoader.loadBundled()
        let session = try await CleanupRuleTestFixtures.scan(
            CleanupRuleTestFixtures.set(try bundled.rules.map(lowered)), home: home)
        let roots = [".gradle", ".cargo", ".claude", "Library/Developer/Xcode/iOS DeviceSupport"]
            .map { home.appendingPathComponent($0).path + "/" }
        let listed = Dictionary(uniqueKeysWithValues: session.candidates
            .filter { candidate in roots.contains { lexicalPath(candidate).hasPrefix($0) } }
            .map { (String(lexicalPath($0).dropFirst(home.path.count + 1)), $0.ruleID) })
        XCTAssertEqual(listed, [
            "Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)": "developer.xcode-ios-device-support",
            "Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)": "developer.xcode-ios-device-support",
            ".gradle/caches": "developer.gradle-cache",
            ".cargo/registry/cache": "developer.cargo-registry-cache",
            ".claude/telemetry": "developer.claude-code-telemetry"
        ], "Scan issues: \(session.issues)")
        for candidate in session.candidates where listed.keys.contains(String(lexicalPath(candidate).dropFirst(home.path.count + 1))) {
            XCTAssertEqual(candidate.risk, .safe)
            XCTAssertFalse(candidate.action.permanentlyDeletes, "moves to the Trash")
        }
    }

    private func lowered(_ rule: CleanupRule) throws -> CleanupRule {
        guard !CleanupCoverageCatalog.cleanupRules.contains(where: { $0.id == rule.id }) else { return rule }
        return try CleanupRuleTestFixtures.replacing(rule, fields: ["minimumBytes": 1])
    }

    /// Rule roots keep the home's spelling (/var/...), but items found by
    /// listing a folder are spelled /private/var/...; compare lexically.
    private func lexicalPath(_ candidate: ScanCandidate) -> String {
        PathSafety.lexicalPath(candidate.sourceURL.path)
    }
}
