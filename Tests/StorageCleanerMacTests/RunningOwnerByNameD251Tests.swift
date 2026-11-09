import Foundation
import XCTest
@testable import StorageCleanerMac

/// D251 (G batch, install22 13:57): `~/Library/Logs/Claude` was “未识别所属应用”
/// and preselected while Claude was running — only reverse-domain folder
/// names could name an app. A folder named exactly like one running app now
/// belongs to it, so D47 holds the row back. Fixtures live in temporary folders.
final class RunningOwnerByNameD251Tests: XCTestCase {
    func testAFolderNamedLikeExactlyOneRunningAppBelongsToIt() {
        let byName = CleanupOwnerInferencePolicy.runningApplicationsByName([
            (bundleIdentifier: "com.anthropic.claudefordesktop", names: ["Claude", "Claude"]),
            (bundleIdentifier: "com.example.notes", names: ["Notes"]),
            (bundleIdentifier: "com.example.notes-pro", names: ["Notes"]),
            (bundleIdentifier: "com.example.x", names: ["X"]),
        ])
        XCTAssertEqual(byName["claude"], ["com.anthropic.claudefordesktop"])
        XCTAssertEqual(CleanupOwnerInferencePolicy.runningOwner(forName: "Claude", runningApplicationsByName: byName),
                       "com.anthropic.claudefordesktop")
        XCTAssertEqual(CleanupOwnerInferencePolicy.runningOwner(forName: "CLAUDE", runningApplicationsByName: byName),
                       "com.anthropic.claudefordesktop", "case does not matter")
        XCTAssertNil(CleanupOwnerInferencePolicy.runningOwner(forName: "Notes", runningApplicationsByName: byName),
                     "two running apps share the name: unresolved")
        XCTAssertNil(CleanupOwnerInferencePolicy.runningOwner(forName: "X", runningApplicationsByName: byName),
                     "one letter never names an app")
        XCTAssertNil(CleanupOwnerInferencePolicy.runningOwner(forName: "Claude Code", runningApplicationsByName: byName),
                     "only an exact name")
        XCTAssertNil(CleanupOwnerInferencePolicy.runningOwner(
            forName: "com.anthropic.claudefordesktop", runningApplicationsByName: ["com.anthropic.claudefordesktop": ["a.b.c"]]),
            "reverse-domain names keep the bundle identifier rule")
    }

    func testALogFolderOfARunningAppIsNotPreselected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerRunningOwnerD251-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let logs = home.appendingPathComponent("Library/Logs")
        let old = Date().addingTimeInterval(-10 * 86_400)
        for name in ["Claude", "SomeTool"] {
            let row = logs.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: row, withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: 4_096).write(to: row.appendingPathComponent("main.log"))
            for url in [row.appendingPathComponent("main.log"), row] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
        }
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(schemaVersion: bundled.schemaVersion, rulesVersion: bundled.rulesVersion,
                                   rules: bundled.rules.filter { $0.id == "system.user-logs" }.map(Self.withoutSizeThreshold))
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: NoSymlinkFileSystem(), ruleSet: rules,
            applicationsURL: root.appendingPathComponent("Applications"),
            applicationEnvironment: NamedRunningApplications(running: ["com.anthropic.claudefordesktop": ["Claude"]]))

        let session = try await scanner.scan(request: CleanupScanRequest(userHomeURL: home)) { _ in }

        let claude = try XCTUnwrap(session.candidates.first { $0.sourceURL.lastPathComponent == "Claude" })
        let tool = try XCTUnwrap(session.candidates.first { $0.sourceURL.lastPathComponent == "SomeTool" })
        XCTAssertEqual(claude.ownerResolution, .inferredFromName)
        XCTAssertEqual(claude.ownerBundleIdentifiers, ["com.anthropic.claudefordesktop"])
        XCTAssertTrue(claude.isOwnerRunning)
        XCTAssertEqual(tool.ownerResolution, .unresolved, "no running app carries the name")
        let selected = CleanupSelection.defaults(in: session).selectedCandidateIDs
        XCTAssertFalse(selected.contains(claude.id), "D47: a running owner holds the row back")
        XCTAssertTrue(selected.contains(tool.id), "an unidentified log is still preselected (D47)")
    }

    private static func withoutSizeThreshold(_ rule: CleanupRule) -> CleanupRule {
        CleanupRule(
            id: rule.id, selectionPolicyVersion: rule.selectionPolicyVersion, categoryID: rule.categoryID,
            categoryTitleKey: rule.categoryTitleKey, titleKey: rule.titleKey, root: rule.root,
            candidateScope: rule.candidateScope, maximumDepth: rule.maximumDepth, minimumAgeDays: rule.minimumAgeDays,
            minimumBytes: 0, include: rule.include, exclude: rule.exclude, cloudPolicy: rule.cloudPolicy,
            risk: rule.risk, recommendation: rule.recommendation, defaultSelection: rule.defaultSelection,
            executionEligibility: rule.executionEligibility, measurementRequirement: rule.measurementRequirement,
            allowsManualSelection: rule.allowsManualSelection, action: rule.action,
            requiredClosedBundleIDs: rule.requiredClosedBundleIDs, reasonKey: rule.reasonKey,
            ownerInference: rule.ownerInference)
    }
}

private struct NamedRunningApplications: CleanupApplicationEnvironment {
    /// Bundle identifier → names.
    let running: [String: [String]]

    func snapshot(checkingInstalled _: Set<String>) async -> CleanupApplicationSnapshot {
        CleanupApplicationSnapshot(
            runningBundleIdentifiers: Set(running.keys),
            runningApplicationsByName: CleanupOwnerInferencePolicy.runningApplicationsByName(
                running.map { (bundleIdentifier: $0.key, names: $0.value) }))
    }
}

/// The temporary folder sits under `/var` → `/private/var`; the fixture reads
/// it as the scanner would read a home folder.
private struct NoSymlinkFileSystem: ReadOnlyFileSystem {
    func snapshot(at url: URL) throws -> FileSnapshot {
        let snapshot = try FoundationReadOnlyFileSystem().snapshot(at: url)
        return FileSnapshot(
            identity: snapshot.identity, standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier, logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes, modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume, isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder, hasSymbolicLinkComponent: false)
    }

    func children(of directory: URL) throws -> [URL] {
        try FoundationReadOnlyFileSystem().children(of: directory)
    }
}
