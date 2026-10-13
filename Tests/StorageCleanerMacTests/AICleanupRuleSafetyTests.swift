import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class AICleanupRuleSafetyTests: XCTestCase {
    private let newIDs: Set<String> = [
        "developer.claude-desktop-web-cache", "developer.codex-desktop-web-cache",
        "developer.vscode-web-cache", "developer.vscode-logs",
        "developer.lmstudio-web-cache", "developer.rod-browser-downloads",
    ]

    func testNewRulesAreEvidenceBackedExactRegenerableSubdirectories() throws {
        let rules = try CleanupRuleSetLoader.loadBundled().rules.filter { newIDs.contains($0.id) }
        XCTAssertEqual(Set(rules.map(\.id)), newIDs)
        for rule in rules {
            XCTAssertEqual(rule.effectiveCandidateScope, .immediateChildren)
            XCTAssertEqual(rule.include.nameMatcher.mode, .exact)
            XCTAssertEqual(rule.risk, .safe)
            XCTAssertEqual(rule.action, .moveToTrash)
            XCTAssertFalse(try XCTUnwrap(rule.maintenance).evidenceURLs.isEmpty)
            XCTAssertTrue(rule.include.nameMatcher.values.allSatisfy {
                ["Cache", "Code Cache", "GPUCache", "logs", "browser"].contains($0)
            })
        }
    }

    func testNewToolCachesKeepExistingDeveloperActivityBandsAndLogPreselection() async throws {
        let rules = try CleanupRuleSetLoader.loadBundled().rules.filter { newIDs.contains($0.id) }
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        for rule in rules { try CleanupRuleTestFixtures.seed(rule, home: home) }
        let ruleSet = CleanupRuleTestFixtures.set(rules)
        let recent = try await CleanupRuleTestFixtures.scan(ruleSet, home: home)
        for row in recent.candidates {
            if row.developerArtifactKind == .logs {
                XCTAssertEqual(row.risk, .safe)
                XCTAssertTrue(row.isPreselectedByDefault)
            } else {
                XCTAssertEqual(row.risk, .protected)
                XCTAssertFalse(row.isPreselectedByDefault)
            }
        }
        XCTAssertEqual(Set(recent.candidates.map(\.ruleID)), newIDs, "Scan issues: \(recent.issues)")
        try CleanupRuleTestFixtures.ageTree(home, days: 60)
        let midAge = try await CleanupRuleTestFixtures.scan(ruleSet, home: home)
        XCTAssertTrue(midAge.candidates.filter { $0.developerArtifactKind != .logs }
            .allSatisfy { $0.risk == .reviewOnly && !$0.isPreselectedByDefault })
        try CleanupRuleTestFixtures.ageTree(home)
        let old = try await CleanupRuleTestFixtures.scan(ruleSet, home: home)
        XCTAssertTrue(old.candidates.allSatisfy { $0.risk == .safe && $0.isPreselectedByDefault })
        let running = try await CleanupRuleTestFixtures.scan(ruleSet, home: home,
            applications: .init(runningBundleIdentifiers: ["com.anthropic.claudefordesktop", "com.microsoft.VSCode", "com.openai.codex"]))
        XCTAssertTrue(running.candidates.filter { !$0.requiredClosedBundleIDs.isEmpty }
            .allSatisfy { !$0.isPreselectedByDefault })
    }

    func testAdjacentSessionsConfigurationCredentialsAndModelsAreNeverListed() async throws {
        let full = try CleanupRuleSetLoader.loadBundled()
        let rules = full.rules.filter { newIDs.contains($0.id) }
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        for rule in rules {
            try CleanupRuleTestFixtures.seed(rule, home: home)
            let root = home.appendingPathComponent(rule.root.path)
            for name in ["sessions", "checkpoints", "projects", "models", "Local Storage", "IndexedDB", "User"] {
                try CleanupRuleTestFixtures.write(root.appendingPathComponent(name).appendingPathComponent("personal.bin"), bytes: 4_096)
            }
            for name in ["auth.json", "settings.json", "config.toml", "model.gguf"] {
                try CleanupRuleTestFixtures.write(root.appendingPathComponent(name), bytes: 4_096)
            }
        }
        let session = try await CleanupRuleTestFixtures.scan(
            CleanupRuleTestFixtures.set(rules), home: home)
        XCTAssertEqual(Set(session.candidates.map(\.ruleID)), newIDs)
        XCTAssertTrue(session.candidates.allSatisfy { row in
            ["Cache", "Code Cache", "GPUCache", "logs", "browser"].contains(row.sourceURL.lastPathComponent)
        })
        XCTAssertFalse(session.candidates.contains { $0.sourceURL.path.contains("/models/") })
    }

    func testMixedCachesContainingPersistentAgentDataAreProtectedWithoutReadingContents() async throws {
        let rule = try XCTUnwrap(try CleanupRuleSetLoader.loadBundled().rules.first {
            $0.id == "developer.claude-desktop-web-cache"
        })
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let cache = home.appendingPathComponent(rule.root.path).appendingPathComponent("Cache")
        let protectedNames = ["sessions", "archived_sessions", "checkpoints", "file-history", "projects",
            "models", "Local Storage", "IndexedDB", "mcp-chrome-fixture", "auth.json", "credentials.json",
            "history.jsonl", "state.sqlite", "config.toml", "model.gguf", "model.safetensors", "model.onnx"]
        for name in protectedNames {
            try CleanupRuleTestFixtures.write(cache.appendingPathComponent(name), bytes: 4_096)
            let session = try await CleanupRuleTestFixtures.scan(CleanupRuleTestFixtures.set([rule]), home: home)
            XCTAssertTrue(session.candidates.isEmpty, name)
            XCTAssertGreaterThan(session.metrics.protectedDataCandidateCount, 0, name)
            try FileManager.default.removeItem(at: cache.appendingPathComponent(name))
        }
        // All data above belongs to this temporary fixture; no real state read.
    }

    func testPersistentPlaywrightMCPProfilesNeverBecomeAWholeFolderCandidate() async throws {
        let full = try CleanupRuleSetLoader.loadBundled()
        let rules = full.rules.filter {
            ["developer.playwright-mcp-cache", "developer.playwright-browsers"].contains($0.id)
        }
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let profile = home.appendingPathComponent("Library/Caches/ms-playwright-mcp/mcp-chrome-fixture/Local Storage/state.bin")
        let mixedProfile = home.appendingPathComponent("Library/Caches/ms-playwright/mcp-chromium-fixture/Cookies")
        try CleanupRuleTestFixtures.write(profile, bytes: 4_096)
        try CleanupRuleTestFixtures.write(mixedProfile, bytes: 4_096)
        try CleanupRuleTestFixtures.write(home.appendingPathComponent("Library/Caches/ms-playwright/chromium-123/browser.bin"), bytes: 4_096)
        try CleanupRuleTestFixtures.ageTree(home)
        let session = try await CleanupRuleTestFixtures.scan(CleanupRuleTestFixtures.set(rules), home: home)
        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertEqual(session.metrics.protectedDataCandidateCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedProfile.path))
    }

    func testSymbolicLinksToPersonalDataAreSkippedAndOverlapIsCountedOnce() async throws {
        let full = try CleanupRuleSetLoader.loadBundled()
        let rule = try XCTUnwrap(full.rules.first { $0.id == "developer.claude-desktop-web-cache" })
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let root = home.appendingPathComponent(rule.root.path)
        try CleanupRuleTestFixtures.write(root.appendingPathComponent("Cache/generated.bin"))
        try CleanupRuleTestFixtures.write(root.appendingPathComponent("sessions/keep.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Code Cache"),
            withDestinationURL: root.appendingPathComponent("sessions"))
        // An existing Claude Code rule and the new Codex desktop rule see
        // the same inode. Only one rule may add its bytes to the result.
        let shared = home.appendingPathComponent("Library/Caches/claude-cli-nodejs/shared.bin")
        let overlapping = home.appendingPathComponent("Library/Application Support/Codex/Cache/shared.bin")
        try CleanupRuleTestFixtures.write(shared)
        try FileManager.default.createDirectory(at: overlapping.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: shared, to: overlapping)
        let session = try await CleanupRuleTestFixtures.scan(full, home: home)
        let cachePath = PathSafety.lexicalPath(root.appendingPathComponent("Cache").path)
        XCTAssertEqual(session.candidates.filter { $0.snapshot.standardizedPath == cachePath }.count, 1)
        let overlappingRows = session.candidates.filter {
            ["developer.claude-code-cli-cache", "developer.codex-desktop-web-cache"].contains($0.ruleID)
        }
        XCTAssertEqual(overlappingRows.reduce(Int64(0)) { $0 + $1.snapshot.logicalSizeBytes }, 131_072)
        XCTAssertGreaterThan(session.metrics.deduplicatedIdentityCount, 0)
        XCTAssertFalse(session.candidates.contains { $0.sourceURL.lastPathComponent == "Code Cache" })
        XCTAssertTrue(session.issues.contains { $0.kind == .symbolicLinkSkipped })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/keep.bin").path))
        XCTAssertEqual(Set(session.candidates.map(\.snapshot.identity)).count, session.candidates.count)
    }

    func testWritesAfterScanAreRejectedForNewAICaches() async throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "ai-cache-write")
        let rule = try XCTUnwrap(try CleanupRuleSetLoader.loadBundled().rules.first { $0.id == "developer.claude-desktop-web-cache" })
        let rules = CleanupRuleTestFixtures.set([rule])
        let payload = home.appendingPathComponent(rule.root.path).appendingPathComponent("Cache/generated.bin")
        try CleanupRuleTestFixtures.write(payload)
        try CleanupRuleTestFixtures.ageTree(home)
        let session = try await CleanupRuleTestFixtures.scan(rules, home: home)
        let plan = try CleanPlanBuilder.makePlan(session: session, selection: CleanupSelection.defaults(in: session),
            activeRules: rules, disposition: .trash)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: payload.path)
        let executor = SafeCleanupExecutor(runningApplicationChecker: RuleTestNoRunningApplicationChecker(), coordinator: HeavyWorkCoordinator())
        let preflight = await executor.preflight(plan: plan, context: CleanupExecutionContext(
            featureConfiguration: .productDefault, activeSessionID: session.id, activeRules: rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: nil))
        XCTAssertEqual(preflight.items.first?.status, .skipped(.candidateBecameActive))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    // MARK: Repair 1 (P1-1, P2-1)

    func testAgentStateMarkersApplyOnlyToD83AIAndPlaywrightRules() throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let expected = newIDs.union(["developer.playwright-mcp-cache", "developer.playwright-browsers"])
        XCTAssertEqual(CleanupProtectedContentPolicy.persistentAgentStateRuleIDs, expected)
        XCTAssertTrue(expected.isSubset(of: Set(bundled.rules.map(\.id))))
        for id in ["developer.npx-cache", "developer.uv-cache", "system.user-caches", "developer.pip-cache",
                   "developer.yarn-cache", "developer.pnpm-cache"] {
            XCTAssertFalse(CleanupProtectedContentPolicy.protectsPersistentAgentState(ruleID: id), id)
        }
        // The integration-baseline folder policy is unchanged.
        for name in ["config", "models", "mcp-server", "settings.json", "history", "projects", "backups"] {
            XCTAssertFalse(CleanupProtectedContentPolicy.isProtectedDataFolder(named: name), name)
        }
    }

    func testPackageCachesWithConfigModelAndMCPNamedFoldersStayListedWithBaselineSelection() async throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = bundled.rules.filter { ["developer.npx-cache", "developer.uv-cache"].contains($0.id) }
        XCTAssertEqual(rules.count, 2)
        let ruleSet = CleanupRuleTestFixtures.set(rules)
        let control = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        for root in [control, home] {
            for rule in rules { try CleanupRuleTestFixtures.seed(rule, home: root) }
        }
        // Ordinary package contents named like agent state (seen under the
        // real ~/.npm/_npx and ~/.cache/uv); only names, synthetic bytes.
        let npx = home.appendingPathComponent(".npm/_npx/0a1b2c/node_modules")
        for path in ["x/config/index.js", "@sentry/core/build/integrations/mcp-server/index.js",
                     "orchestrion/config/default.json", "pkg/settings.json", "pkg/history/index.js",
                     "pkg/projects/index.js", "pkg/backups/readme.md", "pkg/config.json"] {
            try CleanupRuleTestFixtures.write(npx.appendingPathComponent(path), bytes: 4_096)
        }
        let uv = home.appendingPathComponent(".cache/uv/archive-v0/fixture/lib/site-packages")
        for path in ["pkg/models/__init__.py", "pkg/model/weights.pt", "pkg/export.onnx", "pkg/config/defaults.py",
                     "pkg/mcp-tools/__init__.py", "pkg/settings.json"] {
            try CleanupRuleTestFixtures.write(uv.appendingPathComponent(path), bytes: 4_096)
        }
        try CleanupRuleTestFixtures.ageTree(control)
        try CleanupRuleTestFixtures.ageTree(home)
        let expected = try await CleanupRuleTestFixtures.scan(ruleSet, home: control)
        let session = try await CleanupRuleTestFixtures.scan(ruleSet, home: home)
        XCTAssertEqual(Set(expected.candidates.map(\.ruleID)), ["developer.npx-cache", "developer.uv-cache"],
                       "Control issues: \(expected.issues)")
        XCTAssertEqual(Set(session.candidates.map(\.ruleID)), ["developer.npx-cache", "developer.uv-cache"],
                       "Scan issues: \(session.issues)")
        XCTAssertEqual(session.metrics.protectedDataCandidateCount, 0)
        for id in ["developer.npx-cache", "developer.uv-cache"] {
            let before = try XCTUnwrap(expected.candidates.first { $0.ruleID == id })
            let after = try XCTUnwrap(session.candidates.first { $0.ruleID == id })
            XCTAssertEqual(after.risk, before.risk, id)
            XCTAssertEqual(after.selectionEligibility, before.selectionEligibility, id)
            XCTAssertEqual(after.isPreselectedByDefault, before.isPreselectedByDefault, id)
        }
        XCTAssertTrue(try XCTUnwrap(session.candidates.first { $0.ruleID == "developer.npx-cache" }).isPreselectedByDefault)
        XCTAssertEqual(CleanupSelection.defaults(in: session).selectedCandidateIDs.count,
                       CleanupSelection.defaults(in: expected).selectedCandidateIDs.count)

        // The same names deep inside a D83 AI cache still hide the row.
        let claude = try XCTUnwrap(bundled.rules.first { $0.id == "developer.claude-desktop-web-cache" })
        let cache = home.appendingPathComponent(claude.root.path).appendingPathComponent("Cache")
        try CleanupRuleTestFixtures.write(cache.appendingPathComponent("generated.bin"))
        for name in ["sessions", "checkpoints"] {
            let marker = cache.appendingPathComponent("nested/deeper/\(name)/state.bin")
            try CleanupRuleTestFixtures.write(marker, bytes: 4_096)
            try CleanupRuleTestFixtures.ageTree(home)
            let hidden = try await CleanupRuleTestFixtures.scan(CleanupRuleTestFixtures.set([claude]), home: home)
            XCTAssertTrue(hidden.candidates.isEmpty, name)
            XCTAssertEqual(hidden.metrics.protectedDataCandidateCount, 1, name)
            try FileManager.default.removeItem(at: marker.deletingLastPathComponent())
        }
    }

    func testAgentStateAppearingAfterScanBlocksAILogRowBeforeExecution() async throws {
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "ai-log-recheck")
        let rule = try XCTUnwrap(try CleanupRuleSetLoader.loadBundled().rules.first { $0.id == "developer.vscode-logs" })
        let rules = CleanupRuleTestFixtures.set([rule])
        let logs = home.appendingPathComponent(rule.root.path).appendingPathComponent("logs")
        try CleanupRuleTestFixtures.write(logs.appendingPathComponent("20261012/main.log"))
        try CleanupRuleTestFixtures.ageTree(home)
        let session = try await CleanupRuleTestFixtures.scan(rules, home: home)
        let candidate = try XCTUnwrap(session.candidates.first, "Scan issues: \(session.issues)")
        // D47 logs have no activity probe and a declared owner, so only the
        // name recheck can notice state that appeared after the scan.
        XCTAssertEqual(candidate.developerArtifactKind, .logs)
        XCTAssertEqual(candidate.ownerResolution, .declared)
        let plan = try CleanPlanBuilder.makePlan(session: session, selection: CleanupSelection.defaults(in: session),
            activeRules: rules, disposition: .trash)
        XCTAssertEqual(plan.items.count, 1)
        let executor = SafeCleanupExecutor(runningApplicationChecker: RuleTestNoRunningApplicationChecker(),
            coordinator: HeavyWorkCoordinator())
        let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: session.id,
            activeRules: rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: nil)
        let clean = await executor.preflight(plan: plan, context: context)
        XCTAssertEqual(clean.items.first?.status, .ready)
        let markers = [("20261012/sessions/chat.json", "20261012/sessions"),
                       ("20261012/window1/mcp-server-fixture/state.bin", "20261012/window1"),
                       ("settings.json", "settings.json")]
        for (path, created) in markers {
            try CleanupRuleTestFixtures.write(logs.appendingPathComponent(path), bytes: 512)
            let preflight = await executor.preflight(plan: plan, context: context)
            XCTAssertEqual(preflight.items.first?.status, .skipped(.candidateBecameActive), path)
            try FileManager.default.removeItem(at: logs.appendingPathComponent(created))
            let restored = await executor.preflight(plan: plan, context: context)
            XCTAssertEqual(restored.items.first?.status, .ready, path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.appendingPathComponent("20261012/main.log").path))
    }
}
