import Foundation
import XCTest
@testable import StorageCleanerMac

/// D47 (replaces D22 and D40 item 10): every green log and cache row is
/// preselected unless its app is running. A log written in the last 7 days, a
/// log that cannot be read completely and a cache whose app cannot be
/// identified are preselected too; the row still says so. DiagnosticReports
/// has no owning app. Fixtures live in temporary folders only.
final class CleanupLogPreselectionTests: XCTestCase {
    func testGreenLogsAndCachesArePreselectedUnlessTheirAppIsRunning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerLogPreselection-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let logs = home.appendingPathComponent("Library/Logs")
        let caches = home.appendingPathComponent("Library/Caches")
        let old = Date().addingTimeInterval(-10 * 86_400)
        let fresh = Date().addingTimeInterval(-2 * 86_400)
        let catalogBytes = 1_024 * 1_024 + 64 * 1_024
        let rows: [(URL, Int, Date)] = [
            (logs.appendingPathComponent("com.example.idle"), 4_096, old),
            (logs.appendingPathComponent("com.example.fresh"), 4_096, fresh),
            (logs.appendingPathComponent("com.example.running"), 4_096, old),
            (logs.appendingPathComponent("DiagnosticReports"), 4_096, old),
            (logs.appendingPathComponent("SomeTool"), 4_096, old),
            (logs.appendingPathComponent("com.apple.diagnosticextensionsd"), catalogBytes, old),
            (home.appendingPathComponent(".codex/logs"), 4_096, fresh),
            (home.appendingPathComponent(".claude/logs"), 4_096, old),
            (caches.appendingPathComponent("SomeTool"), 4_096, old),
            (caches.appendingPathComponent("com.example.idle"), 4_096, old),
        ]
        for (row, bytes, date) in rows {
            try FileManager.default.createDirectory(at: row, withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: bytes).write(to: row.appendingPathComponent("entry.log"))
            for url in [row.appendingPathComponent("entry.log"), row] {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let wanted: Set<String> = [
            "system.user-logs", "system-log.diagnostics", "developer.codex-logs",
            "developer.claude-code-logs", "system.user-caches",
        ]
        let coverageIDs = Set(CleanupCoverageCatalog.cleanupRules.map(\.id))
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.filter { wanted.contains($0.id) }.map {
                coverageIDs.contains($0.id) ? $0 : withoutSizeThreshold($0)
            }
        )
        XCTAssertEqual(Set(rules.rules.map(\.id)), wanted)
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: LogFixtureFileSystem(),
            ruleSet: rules,
            applicationsURL: root.appendingPathComponent("Applications"),
            applicationEnvironment: LogFixtureApplications(
                running: ["com.example.running"],
                installed: ["com.example.idle", "com.example.fresh", "com.example.running"]
            )
        )

        let session = try await scanner.scan(request: CleanupScanRequest(userHomeURL: home)) { _ in }

        func row(_ ruleID: String, _ name: String) throws -> ScanCandidate {
            try XCTUnwrap(session.candidates.first {
                $0.ruleID == ruleID && $0.sourceURL.lastPathComponent == name
            }, "\(ruleID) \(name)")
        }
        let idleLog = try row("system.user-logs", "com.example.idle")
        let freshLog = try row("system.user-logs", "com.example.fresh")
        let runningLog = try row("system.user-logs", "com.example.running")
        let diagnosticReports = try row("system.user-logs", "DiagnosticReports")
        let toolLog = try row("system.user-logs", "SomeTool")
        let diagnostics = try row("system-log.diagnostics", "com.apple.diagnosticextensionsd")
        let codexLogs = try row("developer.codex-logs", "logs")
        let claudeLogs = try row("developer.claude-code-logs", "logs")
        let toolCache = try row("system.user-caches", "SomeTool")
        let idleCache = try row("system.user-caches", "com.example.idle")

        // D47: only the log whose app is running stays unchecked. Recently
        // written logs (fresh, Codex) and the cache whose app cannot be
        // identified (SomeTool) are checked as well.
        let expected: Set<ScanCandidateID> = [
            idleLog.id, freshLog.id, diagnosticReports.id, toolLog.id, diagnostics.id,
            codexLogs.id, claudeLogs.id, toolCache.id, idleCache.id,
        ]
        XCTAssertEqual(CleanupSelection.defaults(in: session).selectedCandidateIDs, expected)
        XCTAssertEqual(CleanupSelection.recommended(in: session).selectedCandidateIDs, expected)
        XCTAssertFalse(expected.contains(runningLog.id))

        // The row still says when a log was written recently (D47 keeps the hint).
        XCTAssertEqual(freshLog.logWriteState, .recent)
        XCTAssertEqual(codexLogs.logWriteState, .recent)
        XCTAssertEqual(idleLog.logWriteState, .quiet)
        XCTAssertEqual(runningLog.logWriteState, .quiet)
        XCTAssertTrue(runningLog.isOwnerRunning)
        XCTAssertNil(idleCache.logWriteState)
        XCTAssertNil(toolCache.logWriteState)
        XCTAssertEqual(diagnosticReports.ownerResolution, .noApplication)
        XCTAssertEqual(toolLog.ownerResolution, .unresolved)
        XCTAssertEqual(toolCache.ownerResolution, .unresolved)
        // A preselected row is not shown as merely "optional".
        XCTAssertEqual(CleanupRecommendationDisplayPolicy.level(for: toolLog), .recommended)
        XCTAssertEqual(CleanupRecommendationDisplayPolicy.level(for: toolCache), .recommended)
    }

    /// D47 (replaces D40 item 10): a log row that cannot be read completely is
    /// green, so it is preselected; the row says recent writes cannot be ruled out.
    func testALogRowThatCannotBeReadCompletelyIsPreselectedAndSaysSo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerLogUnverified-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let row = home.appendingPathComponent("Library/Logs/com.example.idle")
        let hidden = row.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4_096).write(to: row.appendingPathComponent("app.log"))
        try Data(repeating: 0x5A, count: 4_096).write(to: hidden.appendingPathComponent("secret.log"))
        let old = Date().addingTimeInterval(-30 * 86_400)
        for url in [row.appendingPathComponent("app.log"), hidden.appendingPathComponent("secret.log"), hidden, row] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.filter { $0.id == "system.user-logs" }.map(withoutSizeThreshold)
        )
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: LogFixtureFileSystem(deniedChildrenPaths: [hidden.path]),
            ruleSet: rules,
            applicationsURL: root.appendingPathComponent("Applications"),
            applicationEnvironment: LogFixtureApplications(running: [], installed: ["com.example.idle"])
        )

        let session = try await scanner.scan(request: CleanupScanRequest(userHomeURL: home)) { _ in }

        let log = try XCTUnwrap(session.candidates.first)
        XCTAssertEqual(log.measurementCompleteness, .lowerBound(reason: .permissionDenied))
        XCTAssertEqual(log.logWriteState, .unverified)
        XCTAssertTrue(log.isSelectable)
        XCTAssertEqual(log.risk, .safe)
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.contains(log.id))
        XCTAssertTrue(CleanupSelection.recommended(in: session).selectedCandidateIDs.contains(log.id))
        XCTAssertEqual(
            CleanupCandidateRowHint.ownerStatus(for: log)?.text,
            L10n.text("无法确认最近 7 天内是否有写入", "Cannot confirm whether it was written in the last 7 days")
        )
        let views = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/StorageCleanerMac/Views/CleanupScanViews.swift"),
            encoding: .utf8
        )
        // The result row shows the shared hint.
        XCTAssertTrue(views.contains("CleanupCandidateRowHint.ownerStatus(for: candidate)"))
    }

    /// Fixture rows are small, so bundled and developer thresholds drop to 0;
    /// coverage-catalog rules keep theirs (the validator pins them).
    private func withoutSizeThreshold(_ rule: CleanupRule) -> CleanupRule {
        CleanupRule(
            id: rule.id,
            selectionPolicyVersion: rule.selectionPolicyVersion,
            categoryID: rule.categoryID,
            categoryTitleKey: rule.categoryTitleKey,
            titleKey: rule.titleKey,
            root: rule.root,
            candidateScope: rule.candidateScope,
            maximumDepth: rule.maximumDepth,
            minimumAgeDays: rule.minimumAgeDays,
            minimumBytes: 0,
            include: rule.include,
            exclude: rule.exclude,
            cloudPolicy: rule.cloudPolicy,
            risk: rule.risk,
            recommendation: rule.recommendation,
            defaultSelection: rule.defaultSelection,
            executionEligibility: rule.executionEligibility,
            measurementRequirement: rule.measurementRequirement,
            allowsManualSelection: rule.allowsManualSelection,
            action: rule.action,
            requiredClosedBundleIDs: rule.requiredClosedBundleIDs,
            reasonKey: rule.reasonKey,
            ownerDisplayName: rule.ownerDisplayName,
            developerTool: rule.developerTool,
            developerArtifactKind: rule.developerArtifactKind,
            includedBundleIdentifiers: rule.includedBundleIdentifiers,
            requiresDuplicateBundleIdentifier: rule.requiresDuplicateBundleIdentifier,
            ownerInference: rule.ownerInference
        )
    }
}

private struct LogFixtureFileSystem: ReadOnlyFileSystem {
    var deniedChildrenPaths: Set<String> = []

    func snapshot(at url: URL) throws -> FileSnapshot {
        let snapshot = try FoundationReadOnlyFileSystem().snapshot(at: url)
        return FileSnapshot(
            identity: snapshot.identity,
            standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier,
            logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume,
            isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder,
            hasSymbolicLinkComponent: false
        )
    }

    func children(of directory: URL) throws -> [URL] {
        let path = PathSafety.lexicalPath(directory.path)
        if deniedChildrenPaths.contains(where: { PathSafety.lexicalPath($0) == path }) {
            throw CleanupFileSystemError.permissionDenied
        }
        return try FoundationReadOnlyFileSystem().children(of: directory)
    }
}

private struct LogFixtureApplications: CleanupApplicationEnvironment {
    let running: Set<String>
    let installed: Set<String>

    func snapshot(checkingInstalled bundleIdentifiers: Set<String>) async -> CleanupApplicationSnapshot {
        CleanupApplicationSnapshot(
            runningBundleIdentifiers: running,
            installedBundleIdentifiers: installed.intersection(bundleIdentifiers)
        )
    }
}
