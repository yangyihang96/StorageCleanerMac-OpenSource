import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class CleanupRuleScannerTests: XCTestCase {
    func testDeveloperOnlyScopeKeepsTheExistingScannerAndDeveloperRules() throws {
        let allRules = try CleanupRuleSetLoader.loadBundled()
        let request = CleanupScanRequest(includedCategoryIDs: ["developer"])
        let scopedRules = CleanupScanOperations.scopedRuleSet(
            allRules,
            includedCategoryIDs: request.includedCategoryIDs
        )

        XCTAssertEqual(request.includedCategoryIDs, ["developer"])
        XCTAssertFalse(scopedRules.rules.isEmpty)
        XCTAssertTrue(scopedRules.rules.allSatisfy { $0.categoryID == "developer" })
        XCTAssertLessThan(scopedRules.rules.count, allRules.rules.count)
    }

    func testSafeCleanupScopesSelectRealDisjointRuleSets() throws {
        let allRules = try CleanupRuleSetLoader.loadBundled()
        let ruleIDsByScope = Dictionary(uniqueKeysWithValues:
            SafeCleanupScanScope.allCases.map { scope in
                (scope, Set(allRules.rules.filter(scope.includes).map(\.id)))
            }
        )

        for scope in SafeCleanupScanScope.allCases {
            XCTAssertFalse(ruleIDsByScope[scope, default: []].isEmpty, "\(scope) must map to real cleanup rules")
        }
        for (index, scope) in SafeCleanupScanScope.allCases.enumerated() {
            for otherScope in SafeCleanupScanScope.allCases.dropFirst(index + 1) {
                XCTAssertTrue(
                    ruleIDsByScope[scope, default: []]
                        .intersection(ruleIDsByScope[otherScope, default: []])
                        .isEmpty,
                    "\(scope) and \(otherScope) must not scan the same rule twice"
                )
            }
        }

        let selectedRuleIDs = ruleIDsByScope[.caches, default: []]
            .union(ruleIDsByScope[.downloadResidue, default: []])
        let request = CleanupScanRequest(includedRuleIDs: selectedRuleIDs)
        let scopedRules = CleanupScanOperations.scopedRuleSet(
            allRules,
            includedCategoryIDs: request.includedCategoryIDs,
            includedRuleIDs: request.includedRuleIDs
        )

        XCTAssertEqual(Set(scopedRules.rules.map(\.id)), selectedRuleIDs)
        XCTAssertEqual(request.includedRuleIDs, selectedRuleIDs)
        XCTAssertEqual(CleanupScanRequest(includedRuleIDs: []).includedRuleIDs, [])
    }

    func testStandardScanBudgetDoesNotUseTheOldNinetySecondCutoff() {
        XCTAssertEqual(CleanupScanRequest().maximumDuration, 300)
        XCTAssertEqual(CleanupScanRequest(maximumDuration: .nan).maximumDuration, 300)
        XCTAssertEqual(CleanupScanRequest().developerInactivityThresholdDays, 30)
        XCTAssertEqual(CleanupScanRequest(developerInactivityThresholdDays: 5).developerInactivityThresholdDays, 30)
        XCTAssertEqual(CleanupScanRequest(developerInactivityThresholdDays: 500).developerInactivityThresholdDays, 364)
    }

    func testDeveloperAgePolicyUsesStrictGreenYellowAndRedBoundaries() throws {
        let rule = makeRule(
            id: "developer.fixture",
            root: ".npm",
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.npxCache.title"
        )
        let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)
        func decision(days: Double) throws -> DeveloperCleanupAgeDecision {
            try XCTUnwrap(DeveloperCleanupAgePolicy.decision(
                for: rule,
                latestModificationTimeNanoseconds: Int64(
                    (referenceDate.timeIntervalSince1970 - days * 86_400)
                        * 1_000_000_000
                ),
                measurementCompleteness: .complete,
                referenceDate: referenceDate,
                thresholdDays: 30
            ))
        }

        XCTAssertEqual(try decision(days: 366).band, .inactiveYear)
        XCTAssertEqual(try decision(days: 366).defaultSelection, .selected)
        XCTAssertEqual(try decision(days: 365).band, .inactiveReview)
        XCTAssertEqual(try decision(days: 31).band, .inactiveReview)
        XCTAssertEqual(try decision(days: 30).band, .recent)
        XCTAssertEqual(try decision(days: 1).executionEligibility, .eligibleAfterProtectedReview)
    }

    @MainActor
    func testDeveloperThresholdPersistsInExistingScanStore() throws {
        let suiteName = TestPreferenceDomain.makeSuite()
        let preferences = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }

        let first = try ScanStore.makeForTests(for: self, cleanupPreferences: preferences)
        first.setDeveloperInactivityThresholdDays(75)
        XCTAssertEqual(first.developerInactivityThresholdDays, 75)
        XCTAssertEqual(
            try ScanStore.makeForTests(for: self, cleanupPreferences: preferences).developerInactivityThresholdDays,
            75
        )
    }

    func testDeveloperScanUsesLatestNestedChangeAndPreflightRejectsLaterActivity() async throws {
        let home = try makeFixtureHome()
        let candidateRoot = home.appendingPathComponent(".npm/_npx")
        let payload = candidateRoot.appendingPathComponent("payload.bin")
        try write(bytes: 4_096, to: payload)
        let rules = makeRuleSet(rules: [makeRule(
            id: "developer.npx-cache",
            root: ".npm",
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.npxCache.title",
            nameMatcher: CleanupNameMatcher(mode: .exact, values: ["_npx"]),
            maximumDepth: 8
        )])
        let oldDate = Date().addingTimeInterval(-366 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: payload.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: candidateRoot.path)

        let greenSession = try await scan(home: home, ruleSet: rules)
        let green = try XCTUnwrap(greenSession.candidates.first)
        XCTAssertEqual(green.risk, .safe)
        XCTAssertEqual(green.defaultSelection, .selected)
        XCTAssertTrue(CleanupSelection.defaults(in: greenSession).selectedCandidateIDs.contains(green.id))

        let recentDate = Date().addingTimeInterval(-10 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: payload.path)
        let redSession = try await scan(home: home, ruleSet: rules)
        let red = try XCTUnwrap(redSession.candidates.first)
        XCTAssertEqual(red.risk, .protected)
        XCTAssertEqual(red.selectionEligibility, .selectableWithProtectedReview)
        XCTAssertTrue(CleanupSelection.defaults(in: redSession).selectedCandidateIDs.isEmpty)

        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: redSession,
            selection: CleanupSelection(selectedCandidateIDs: [red.id]),
            activeRules: rules,
            disposition: .trash
        )) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
        }

        var selection = CleanupSelection()
        selection.setCandidate(red.id, selected: true, in: redSession)
        let plan = try CleanPlanBuilder.makePlan(
            session: redSession,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        let context = CleanupExecutionContext(
            featureConfiguration: .productDefault,
            activeSessionID: redSession.id,
            activeRules: rules,
            userHomeURL: home,
            excludedURLs: [],
            approvedPlanItemIDs: nil
        )
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureReadOnlyFileSystem(),
            coordinator: HeavyWorkCoordinator()
        )
        let ready = await executor.preflight(plan: plan, context: context)
        XCTAssertEqual(ready.items.map(\.status), [.ready])

        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: payload.path)
        let changed = await executor.preflight(plan: plan, context: context)
        XCTAssertEqual(changed.items.map(\.status), [.skipped(.candidateBecameActive)])
    }

    /// D19/D47: developer tool logs are green and preselected while the tool's
    /// app is closed; sessions, checkpoints and agent data are not listed.
    func testDeveloperToolArtifactsExposeOwnerAndTypeWhileProtectedStateStaysExcluded() async throws {
        let home = try makeFixtureHome()
        try write(
            bytes: 128 * 1_024,
            to: home.appendingPathComponent("Library/Application Support/Cursor/CachedData/cache.bin")
        )
        try write(
            bytes: 128 * 1_024,
            to: home.appendingPathComponent(".cache/opencode/cache.bin")
        )
        let codexLog = home.appendingPathComponent(".codex/logs/latest.log")
        try write(bytes: 128 * 1_024, to: codexLog)
        let quiet = Date().addingTimeInterval(-10 * 86_400)
        for url in [codexLog, codexLog.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.modificationDate: quiet], ofItemAtPath: url.path)
        }
        for protectedPath in [
            ".codex/sessions/protected.jsonl",
            ".codex/.tmp/runtime.lock",
            ".gemini/history/session.json",
            ".workbuddy/sessions/session.json",
            ".claude/projects/project.jsonl",
            "Library/Application Support/Cursor/User/workspaceStorage/protected.bin",
        ] {
            try write(bytes: 128 * 1_024, to: home.appendingPathComponent(protectedPath))
        }

        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "developer-artifacts.fixture",
            rules: DeveloperToolArtifactCatalog.cleanupRules
        )
        let session = try await scan(home: home, ruleSet: rules)
        let byRuleID = Dictionary(uniqueKeysWithValues: session.candidates.map { ($0.ruleID, $0) })

        let cursor = try XCTUnwrap(byRuleID["developer.cursor-cache"])
        XCTAssertEqual(cursor.developerTool, .cursor)
        XCTAssertEqual(cursor.developerArtifactKind, .cache)
        XCTAssertTrue(cursor.subcategoryTitle.contains("Cursor"))

        let openCode = try XCTUnwrap(byRuleID["developer.opencode-cache"])
        XCTAssertEqual(openCode.developerTool, .openCode)
        XCTAssertEqual(openCode.developerArtifactKind, .cache)

        let codexLogs = try XCTUnwrap(byRuleID["developer.codex-logs"])
        XCTAssertEqual(codexLogs.developerTool, .codex)
        XCTAssertEqual(codexLogs.developerArtifactKind, .logs)
        XCTAssertEqual(codexLogs.action, .moveToTrash)
        XCTAssertEqual(codexLogs.risk, .safe, "Logs are not graded by activity")
        XCTAssertEqual(codexLogs.selectionEligibility, .selectable)
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.contains(codexLogs.id))

        XCTAssertTrue(session.candidates.allSatisfy(\.isSelectable))
        XCTAssertFalse(session.candidates.contains {
            $0.snapshot.standardizedPath.contains("/sessions")
                || $0.snapshot.standardizedPath.hasSuffix("/.tmp")
                || $0.snapshot.standardizedPath.contains("/history")
                || $0.snapshot.standardizedPath.contains("/projects")
                || $0.snapshot.standardizedPath.contains("/User/workspaceStorage")
        })
        XCTAssertFalse(DeveloperToolArtifactCatalog.definitions.contains { $0.kind == .agentData })
    }

    func testBundledRuleSetLoadsAndValidates() throws {
        let ruleSet = try CleanupRuleSetLoader.loadBundled()

        XCTAssertEqual(ruleSet.schemaVersion, 2)
        XCTAssertFalse(ruleSet.rules.isEmpty)
        XCTAssertNoThrow(try CleanupRuleValidator.validate(ruleSet))
    }

    func testSchemaOneRulesAreRejectedAfterV2Upgrade() {
        let legacy = CleanupRuleSet(
            schemaVersion: 1,
            rulesVersion: "legacy-v1",
            rules: [makeRule()]
        )

        XCTAssertThrowsError(try CleanupRuleValidator.validate(legacy)) {
            XCTAssertEqual(
                $0 as? CleanupRuleValidationError,
                .unsupportedSchema(1)
            )
        }
    }

    func testExactNameMatcherIsCaseSensitiveAndUnicodeCanonicalEquivalent() async throws {
        let home = try makeFixtureHome()
        let npm = home.appendingPathComponent(".npm")
        for name in ["_npx", "_npx-backup", "_NPX", "_cacache", "_cacache-old"] {
            try write(bytes: 4_096, to: npm.appendingPathComponent("\(name)/payload.bin"))
        }
        let decomposedCafe = "cafe\u{301}"
        try write(bytes: 4_096, to: npm.appendingPathComponent("\(decomposedCafe)/payload.bin"))
        let rules = makeRuleSet(rules: [
            makeRule(
                id: "developer.npx-cache",
                root: ".npm",
                nameMatcher: CleanupNameMatcher(mode: .exact, values: ["_npx"])
            ),
            makeRule(
                id: "developer.npm-content-cache",
                root: ".npm",
                nameMatcher: CleanupNameMatcher(mode: .exact, values: ["_cacache"]),
                recommendation: .optional,
                defaultSelection: .unselected
            ),
            makeRule(
                id: "developer.unicode-cache",
                root: ".npm",
                nameMatcher: CleanupNameMatcher(mode: .exact, values: ["café"])
            ),
        ])

        let session = try await scan(home: home, ruleSet: rules)
        let names = Set(session.candidates.map {
            $0.sourceURL.lastPathComponent.precomposedStringWithCanonicalMapping
        })

        XCTAssertEqual(names, ["_npx", "_cacache", "café"])
        XCTAssertFalse(names.contains("_npx-backup"))
        XCTAssertFalse(names.contains("_cacache-old"))
        XCTAssertFalse(names.contains("_NPX"))
        let defaults = CleanupSelection.defaults(in: session)
        let npmContent = try XCTUnwrap(session.candidates.first {
            $0.ruleID == "developer.npm-content-cache"
        })
        // D47: a green row is preselected even when its rule is only
        // "optional" (this fixture rule is not graded by developer activity).
        XCTAssertEqual(npmContent.risk, .safe)
        XCTAssertEqual(npmContent.defaultSelection, .unselected)
        XCTAssertTrue(defaults.selectedCandidateIDs.contains(npmContent.id))
    }

    /// D19, D22–D25: every bundled rule lists items that can be selected and
    /// removed. Personal data, agent sessions and app bundles have no rule.
    func testBundledRulesEncodeStorageAnalyzerDecisionTiersWithNativeSafetyGuards() throws {
        let rules = try CleanupRuleSetLoader.loadBundled().rules
        let ruleByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        let artifactDefinitions = DeveloperToolArtifactCatalog.definitions
        let artifactRuleIDs = artifactDefinitions.map(\.id)
        let coverageRuleIDs = CleanupCoverageCatalog.cleanupRules.map(\.id)

        let decisionRuleIDs = [
            "developer.npx-cache",
            "developer.npm-content-cache",
            "developer.homebrew-cache",
            "developer.uv-cache",
            "developer.xcode-derived-data",
            "system.user-caches",
            "system.user-logs",
            "downloads.installers",
            "downloads.large-items",
            "applications.duplicate-installed-apps",
        ]
        XCTAssertEqual(
            Set(ruleByID.keys),
            Set(artifactRuleIDs + coverageRuleIDs + decisionRuleIDs)
        )
        for removedRuleID in [
            "personal.pictures-library",
            "user-data.wechat",
            "user-data.chrome",
            "user-data.codex-sessions",
            "user-data.ego-lite",
            "user-data.crossover",
            "applications.installed-apps",
            "applications.large-creative-apps",
            "mail.library-attachments",
            "developer.codex-agent-data",
            "developer.codex-runtime-temporary-files",
            "developer.claude-code-agent-data",
            "developer.gemini-cli-data",
        ] {
            XCTAssertNil(ruleByID[removedRuleID], "D19/D24/D25 removed \(removedRuleID)")
        }

        // D19: nothing is listed read-only any more.
        XCTAssertTrue(rules.allSatisfy { $0.action.isExecutable && $0.allowsManualSelection })
        XCTAssertFalse(rules.contains { $0.action == .revealOnly })
        XCTAssertEqual(
            rules.filter { $0.risk == .safe }.count,
            7
                + artifactDefinitions.count
                + CleanupCoverageCatalog.regenerableCacheDefinitions.count
                + CleanupCoverageCatalog.logDefinitions.count
        )
        XCTAssertEqual(
            Set(rules.filter { $0.risk == .reviewOnly }.map(\.id)),
            [
                "downloads.installers",
                "downloads.large-items",
                "system-cache.cloudkit",
                "mail.downloaded-attachments",
            ]
        )
        XCTAssertEqual(
            Set(rules.filter { $0.risk == .protected }.map(\.id)),
            ["applications.duplicate-installed-apps", "trash.user-trash"]
        )

        let automaticRules = rules.filter { $0.action == .moveToTrash }
        XCTAssertFalse(automaticRules.isEmpty)
        XCTAssertTrue(automaticRules.allSatisfy {
            $0.risk == .safe && $0.allowsManualSelection
        })
        let reviewedRules = rules.filter { $0.action == .moveToTrashAfterReview }
        XCTAssertTrue(reviewedRules.allSatisfy {
            $0.risk == .reviewOnly
                && $0.allowsManualSelection
                && $0.defaultSelection == .unselected
        })
        XCTAssertEqual(
            rules.filter { $0.action == .moveToTrashAfterProtectedReview }.map(\.id),
            ["applications.duplicate-installed-apps"]
        )
        XCTAssertEqual(
            rules.filter { $0.action == .emptyTrash }.map(\.id),
            ["trash.user-trash"]
        )

        let duplicateApplications = try XCTUnwrap(
            ruleByID["applications.duplicate-installed-apps"]
        )
        XCTAssertEqual(duplicateApplications.risk, .protected)
        XCTAssertEqual(duplicateApplications.recommendation, .notRecommended)
        XCTAssertEqual(duplicateApplications.defaultSelection, .unselected)
        XCTAssertEqual(duplicateApplications.action, .moveToTrashAfterProtectedReview)
        XCTAssertTrue(duplicateApplications.allowsManualSelection)
        XCTAssertEqual(duplicateApplications.maximumDepth, 32)
        XCTAssertEqual(duplicateApplications.include.extensions, ["app"])
        XCTAssertTrue(duplicateApplications.effectiveRequiresDuplicateBundleIdentifier)
        XCTAssertTrue(duplicateApplications.effectiveIncludedBundleIdentifiers.isEmpty)

        let npx = try XCTUnwrap(ruleByID["developer.npx-cache"])
        XCTAssertEqual(npx.root.path, ".npm")
        XCTAssertEqual(npx.include.nameMatcher.mode, .exact)
        XCTAssertEqual(npx.include.nameMatcher.values, ["_npx"])
        XCTAssertEqual(npx.minimumBytes, 50 * 1_024 * 1_024)
        XCTAssertEqual(npx.minimumAgeDays, 0)
        XCTAssertEqual(npx.recommendation, .recommended)
        XCTAssertEqual(npx.defaultSelection, .selected)
        XCTAssertEqual(npx.developerTool, .npm)
        XCTAssertEqual(npx.developerArtifactKind, .temporaryExecutionCache)

        let npmContent = try XCTUnwrap(ruleByID["developer.npm-content-cache"])
        XCTAssertEqual(npmContent.include.nameMatcher.mode, .exact)
        XCTAssertEqual(npmContent.include.nameMatcher.values, ["_cacache"])
        XCTAssertEqual(npmContent.minimumBytes, 200 * 1_024 * 1_024)
        XCTAssertEqual(npmContent.minimumAgeDays, 0)
        XCTAssertEqual(npmContent.recommendation, .optional)
        XCTAssertEqual(npmContent.defaultSelection, .unselected)
        XCTAssertEqual(npmContent.developerTool, .npm)
        XCTAssertEqual(npmContent.developerArtifactKind, .contentCache)

        for ruleID in [
            "developer.homebrew-cache",
            "developer.uv-cache",
            "developer.xcode-derived-data",
        ] {
            let rule = try XCTUnwrap(ruleByID[ruleID])
            XCTAssertEqual(rule.risk, .safe)
            XCTAssertEqual(rule.recommendation, .optional)
            XCTAssertEqual(rule.defaultSelection, .unselected)
            XCTAssertEqual(rule.executionEligibility, .eligible)
            XCTAssertEqual(rule.action, .moveToTrash)
        }
        XCTAssertEqual(ruleByID["developer.homebrew-cache"]?.root.path, "Library/Caches")
        XCTAssertEqual(
            ruleByID["developer.homebrew-cache"]?.include.nameMatcher.values,
            ["Homebrew"]
        )
        XCTAssertEqual(ruleByID["developer.uv-cache"]?.root.path, ".cache")
        XCTAssertEqual(
            ruleByID["developer.uv-cache"]?.include.nameMatcher.values,
            ["uv"]
        )
        XCTAssertEqual(
            ruleByID["developer.xcode-derived-data"]?.effectiveCandidateScope,
            .root
        )
        XCTAssertEqual(
            ruleByID["developer.xcode-derived-data"]?.requiredClosedBundleIDs,
            ["com.apple.dt.Xcode"]
        )

        // D19/D47: one row per app or log source, green, preselected unless
        // the owning app is running.
        for ruleID in ["system.user-caches", "system.user-logs"] {
            let rule = try XCTUnwrap(ruleByID[ruleID])
            XCTAssertEqual(rule.risk, .safe)
            XCTAssertEqual(rule.recommendation, .recommended)
            XCTAssertEqual(rule.defaultSelection, .selected)
            XCTAssertEqual(rule.executionEligibility, .eligible)
            XCTAssertEqual(rule.action, .moveToTrash)
            XCTAssertTrue(rule.allowsManualSelection)
            XCTAssertTrue(rule.isContainerRule)
            XCTAssertEqual(rule.ownerInference, .candidateName)
        }
        let userCaches = try XCTUnwrap(ruleByID["system.user-caches"])
        for excluded in [
            "Homebrew", "Google", "BraveSoftware", "Citro Labs", "CloudKit", "Claude",
            "com.apple.bird", "com.apple.nsurlsessiond", "com.apple.containermanagerd",
            "com.local.StorageCleanerMac", "com.local.StorageCleanerMac.beta",
            "com.apple.FileProviderDaemon.AppStoreService", "com.apple.XProtectFramework.plugins",
        ] {
            XCTAssertTrue(userCaches.exclude.excludes(childName: excluded), excluded)
        }
        XCTAssertFalse(userCaches.exclude.excludes(childName: "com.example.app"))
        // D47 supplement (review P1-1a): developer tool caches have their own
        // activity-graded rules, so the user-cache rows leave them out.
        for developerCache in [
            "go-build", "gopls", "golangci-lint", "ms-playwright", "ms-playwright-go", "pnpm", "Yarn",
            "node-gyp", "typescript", "deno", "electron", "electron-builder", "Cypress", "pypoetry",
            "CocoaPods", "org.carthage.CarthageKit", "Mozilla.sccache", "flutter_engine", "claude-cli-nodejs",
        ] {
            XCTAssertTrue(userCaches.exclude.excludes(childName: developerCache), developerCache)
            let owner = try XCTUnwrap(rules.first {
                $0.root.path == "Library/Caches"
                    && $0.include.nameMatcher.mode == .exact
                    && $0.include.nameMatcher.values.contains(developerCache)
            }, developerCache)
            XCTAssertEqual(owner.categoryID, "developer", developerCache)
            XCTAssertTrue(DeveloperCleanupAgePolicy.applies(to: owner), developerCache)
        }
        let userLogs = try XCTUnwrap(ruleByID["system.user-logs"])
        for excluded in ["com.apple.diagnosticextensionsd", "com.openai.codex", "GitHub Copilot", "OpenClaw"] {
            XCTAssertTrue(userLogs.exclude.excludes(childName: excluded), excluded)
        }

        XCTAssertEqual(
            Set(artifactDefinitions.map(\.tool)),
            [
                .codex, .claudeCode, .cursor, .githubCopilot, .openCode, .openClaw,
                .workBuddy, .windsurf, .continueDev,
                // D83 adds only generated caches/logs for these tool owners.
                .claudeDesktop, .visualStudioCode, .lmStudio, .rodBrowser,
            ]
        )
        XCTAssertFalse(artifactDefinitions.contains { $0.kind == .agentData })
        for definition in artifactDefinitions {
            let rule = try XCTUnwrap(ruleByID[definition.id])
            XCTAssertEqual(rule.developerTool, definition.tool)
            XCTAssertEqual(rule.developerArtifactKind, definition.kind)
            XCTAssertEqual(rule.root.path, definition.rootPath)
            XCTAssertEqual(Set(rule.include.nameMatcher.values), Set(definition.candidateNames))
            XCTAssertEqual(rule.risk, .safe)
            XCTAssertEqual(rule.action, .moveToTrash)
            XCTAssertTrue(rule.allowsManualSelection)
            if definition.kind == .logs {
                XCTAssertEqual(definition.policy, .disposableLogs)
                XCTAssertEqual(rule.recommendation, .recommended)
                XCTAssertEqual(rule.defaultSelection, .selected)
                XCTAssertFalse(DeveloperCleanupAgePolicy.applies(to: rule))
            } else {
                XCTAssertEqual(definition.policy, .regenerable)
                XCTAssertEqual(rule.defaultSelection, .unselected)
                XCTAssertTrue(DeveloperCleanupAgePolicy.applies(to: rule))
            }
        }

        for definition in CleanupCoverageCatalog.regenerableCacheDefinitions
            + CleanupCoverageCatalog.logDefinitions {
            let rule = try XCTUnwrap(ruleByID[definition.id])
            XCTAssertEqual(rule.ownerDisplayName, definition.ownerDisplayName)
            XCTAssertEqual(rule.root.path, definition.rootPath)
            XCTAssertEqual(
                Set(rule.include.nameMatcher.values),
                Set(definition.candidateNames)
            )
            XCTAssertEqual(rule.risk, .safe)
            XCTAssertEqual(rule.executionEligibility, .eligible)
            XCTAssertEqual(rule.measurementRequirement, .complete)
            XCTAssertEqual(rule.action, .moveToTrash)
            XCTAssertTrue(rule.allowsManualSelection)
            let preselects = rule.categoryID != "developer"
            XCTAssertEqual(rule.recommendation, preselects ? .recommended : .optional, definition.id)
            XCTAssertEqual(rule.defaultSelection, preselects ? .selected : .unselected, definition.id)
        }

        for ruleID in ["system-cache.cloudkit", "mail.downloaded-attachments"] {
            let rule = try XCTUnwrap(ruleByID[ruleID])
            XCTAssertEqual(rule.risk, .reviewOnly)
            XCTAssertEqual(rule.recommendation, .optional)
            XCTAssertEqual(rule.defaultSelection, .unselected)
            XCTAssertEqual(rule.executionEligibility, .eligibleAfterReview)
            XCTAssertEqual(rule.action, .moveToTrashAfterReview)
            XCTAssertTrue(rule.allowsManualSelection)
        }
        XCTAssertEqual(
            ruleByID["mail.downloaded-attachments"]?.requiredClosedBundleIDs,
            ["com.apple.mail"]
        )

        let trash = try XCTUnwrap(ruleByID["trash.user-trash"])
        XCTAssertEqual(trash.root.path, ".Trash")
        XCTAssertEqual(trash.effectiveCandidateScope, .root)
        XCTAssertEqual(trash.action, .emptyTrash)
        XCTAssertEqual(trash.recommendation, .notRecommended)
        XCTAssertEqual(trash.defaultSelection, .unselected)

        let downloads = try XCTUnwrap(ruleByID["downloads.large-items"])
        XCTAssertEqual(downloads.root.path, "Downloads")
        XCTAssertEqual(downloads.action, .moveToTrashAfterReview)
        XCTAssertEqual(downloads.recommendation, .notRecommended)

        let installers = try XCTUnwrap(ruleByID["downloads.installers"])
        XCTAssertEqual(installers.include.extensions, ["dmg", "pkg", "xip"])
        XCTAssertEqual(installers.recommendation, .optional)
        XCTAssertEqual(installers.defaultSelection, .unselected)
        XCTAssertEqual(installers.action, .moveToTrashAfterReview)

        XCTAssertTrue(rules.allSatisfy {
            [
                .moveToTrash,
                .moveToTrashAfterReview,
                .moveToTrashAfterProtectedReview,
                .emptyTrash,
            ].contains($0.action)
        })
    }

    /// D19: the per-app cache rows never repeat a path a more specific rule
    /// lists, and never list a parent that contains one (here `Google`).
    func testKnownBrowserCacheWinsOverGenericCacheWithoutDoubleCounting() async throws {
        let home = try makeFixtureHome()
        let chromeCache = home.appendingPathComponent(
            "Library/Caches/Google/Chrome",
            isDirectory: true
        )
        try write(
            bytes: 2 * 1_024 * 1_024,
            to: chromeCache.appendingPathComponent("Default/cache.bin")
        )
        try write(
            bytes: 2 * 1_024 * 1_024,
            to: home.appendingPathComponent("Library/Caches/Google/Updater/cache.bin")
        )
        try write(
            bytes: 2 * 1_024 * 1_024,
            to: home.appendingPathComponent("Library/Caches/com.example.other/cache.bin")
        )
        let chromeRule = try XCTUnwrap(
            CleanupCoverageCatalog.regenerableCacheDefinitions
                .first { $0.id == "browser-cache.google-chrome" }?
                .cleanupRule
        )
        let genericRule = makeRule(
            id: "system.user-caches",
            root: "Library/Caches",
            excludedRelativePrefixes: ["Google"],
            minimumBytes: 1_024 * 1_024
        )

        let session = try await scan(
            home: home,
            ruleSet: makeRuleSet(rules: [chromeRule, genericRule])
        )
        let candidate = try XCTUnwrap(session.candidates.first { $0.ruleID == chromeRule.id })

        XCTAssertEqual(
            session.candidates.map(\.sourceURL.lastPathComponent).sorted(),
            ["Chrome", "com.example.other"]
        )
        XCTAssertEqual(candidate.subcategoryTitle, CleanupRuleCopy.title(for: chromeRule))
        XCTAssertEqual(candidate.requiredClosedBundleIDs, ["com.google.Chrome"])
        XCTAssertEqual(candidate.ownerResolution, .declared)
        XCTAssertEqual(candidate.defaultSelection, .selected)
        XCTAssertEqual(candidate.selectionEligibility, .selectable)
        XCTAssertEqual(
            CleanupRecommendationDisplayPolicy.level(for: candidate),
            .recommended
        )
        XCTAssertGreaterThanOrEqual(candidate.estimatedSizeBytes, 2 * 1_024 * 1_024)

        XCTAssertThrowsError(try CleanupRuleValidator.validate(makeRuleSet(rules: [
            chromeRule,
            makeRule(id: "system.user-caches", root: "Library/Caches"),
        ])), "A container that does not exclude Google would list Chrome's cache twice")
    }

    /// D19: a lower-bound measurement stays selectable and keeps its tier.
    func testIncompleteOptionalCacheDisplaysViewOnlyWithoutChangingRuleSafety() async throws {
        let home = try makeFixtureHome()
        let chromeCache = home.appendingPathComponent(
            "Library/Caches/Google/Chrome",
            isDirectory: true
        )
        try write(
            bytes: 2 * 1_024 * 1_024,
            to: chromeCache.appendingPathComponent("Default/cache.bin")
        )
        let outside = home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: chromeCache.appendingPathComponent("linked-cache"),
            withDestinationURL: outside
        )
        let chromeRule = try XCTUnwrap(
            CleanupCoverageCatalog.regenerableCacheDefinitions
                .first { $0.id == "browser-cache.google-chrome" }?
                .cleanupRule
        )

        let session = try await scan(
            home: home,
            ruleSet: makeRuleSet(rules: [chromeRule])
        )
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(candidate.recommendation.level, .recommended)
        XCTAssertEqual(candidate.measurementCompleteness, .lowerBound(reason: .symbolicLinkSkipped))
        XCTAssertEqual(candidate.selectionEligibility, .selectable)
        XCTAssertEqual(
            CleanupRecommendationDisplayPolicy.level(for: candidate),
            .recommended
        )
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.contains(candidate.id))
    }

    /// D24: copies saved when attachments were opened are yellow and
    /// selectable; attachments inside the mail library are not listed.
    func testMailDownloadsAreReviewedAndMailLibraryAttachmentsAreNotListed() async throws {
        let home = try makeFixtureHome()
        try write(
            bytes: 8_192,
            to: home.appendingPathComponent(
                "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A1/invoice.pdf"
            )
        )
        try write(
            bytes: 8_192,
            to: home.appendingPathComponent(
                "Library/Mail/V10/account/Inbox.mbox/Data/1/Attachments/invoice.pdf"
            )
        )
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupScanOperations.scopedRuleSet(bundled, includedCategoryIDs: ["mail"])
        XCTAssertEqual(rules.rules.map(\.id), ["mail.downloaded-attachments"])

        let session = try await scan(home: home, ruleSet: rules)
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(session.candidates.count, 1)
        XCTAssertEqual(candidate.sourceURL.lastPathComponent, "Mail Downloads")
        XCTAssertEqual(candidate.risk, .reviewOnly)
        XCTAssertEqual(candidate.selectionEligibility, .selectableWithReview)
        XCTAssertEqual(candidate.requiredClosedBundleIDs, ["com.apple.mail"])
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.isEmpty)
        XCTAssertFalse(session.candidates.contains {
            $0.snapshot.standardizedPath.contains("/Library/Mail/")
        })
    }

    func testDescendantAggregateScopeCannotAuthorizeCleanup() throws {
        let forged = makeRule(
            id: "mail.forged-delete",
            root: "Library/Mail",
            candidateScope: .descendantAggregate,
            nameMatcher: CleanupNameMatcher(
                mode: .exact,
                values: ["Attachments"]
            )
        )

        XCTAssertThrowsError(try CleanupRuleValidator.validate(
            makeRuleSet(rules: [forged])
        )) { error in
            XCTAssertEqual(
                error as? CleanupRuleValidationError,
                .unsafeActionRiskCombination(ruleID: forged.id)
            )
        }
    }

    func testRootCandidateScopeEmitsOneStableSelectableRootAndBuildsPlan() async throws {
        let home = try makeFixtureHome()
        let cacheRoot = home.appendingPathComponent(".cache")
        try write(bytes: 8_192, to: cacheRoot.appendingPathComponent("tool/deep/cache.bin"))
        let rule = makeRule(
            id: "developer.dot-cache",
            root: ".cache",
            candidateScope: .root
        )
        let rules = makeRuleSet(rules: [rule])

        let first = try await scan(home: home, ruleSet: rules)
        let second = try await scan(home: home, ruleSet: rules)
        XCTAssertEqual(first.candidates.count, 1)
        XCTAssertEqual(second.candidates.count, 1)
        let candidate = try XCTUnwrap(first.candidates.first)

        XCTAssertEqual(PathSafety.lexicalPath(candidate.sourceURL.path), PathSafety.lexicalPath(cacheRoot.path))
        XCTAssertEqual(PathSafety.lexicalPath(candidate.allowedRootURL.path), PathSafety.lexicalPath(home.path))
        XCTAssertEqual(candidate.id, second.candidates.first?.id)
        XCTAssertEqual(candidate.selectionEligibility, .selectable)
        XCTAssertEqual(candidate.defaultSelection, .selected)

        var selection = CleanupSelection()
        selection.setCandidate(candidate.id, selected: true, in: first)
        let plan = try CleanPlanBuilder.makePlan(
            session: first,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(plan.items.map { PathSafety.lexicalPath($0.sourceURL.path) }, [PathSafety.lexicalPath(cacheRoot.path)])
    }

    func testDeepStorageAnalyzerCandidateCountsDataBeyondEightLevels() async throws {
        let home = try makeFixtureHome()
        let candidateRoot = home.appendingPathComponent("Library/Application Support/DeepApp")
        let nested = (1...12).reduce(candidateRoot) { partial, depth in
            partial.appendingPathComponent("level-\(depth)")
        }
        try write(bytes: 8_192, to: nested.appendingPathComponent("payload.bin"))
        // D19: read-only listings are gone, so the depth check uses a
        // reviewed (selectable) rule.
        let rule = makeRule(
            id: "user-data.application-support",
            root: "Library/Application Support",
            categoryID: "user-data",
            categoryTitleKey: "cleanup.category.userData",
            titleKey: "cleanup.rule.applicationSupport.title",
            maximumDepth: 32,
            risk: .reviewOnly,
            recommendation: .notRecommended,
            allowsManualSelection: true,
            action: .moveToTrashAfterReview,
            reasonKey: "cleanup.reason.manualAppData"
        )

        let session = try await scan(home: home, ruleSet: makeRuleSet(rules: [rule]))
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(PathSafety.lexicalPath(candidate.sourceURL.path), PathSafety.lexicalPath(candidateRoot.path))
        XCTAssertGreaterThanOrEqual(candidate.estimatedSizeBytes, 8_192)
        XCTAssertEqual(candidate.risk, .reviewOnly)
        XCTAssertEqual(candidate.measurementCompleteness, .complete)
        XCTAssertEqual(candidate.selectionEligibility, .selectableWithReview)
    }

    /// D25: only extra copies of the same app are listed; other apps are not.
    /// Copies are measured fully and kept in whole groups.
    func testDuplicateApplicationBundlesBecomeProtectedDecisionItems() async throws {
        let home = try makeFixtureHome()
        let applications = home.appendingPathComponent("Applications")
        try makeApplicationBundle(
            at: applications.appendingPathComponent("Example.app"),
            bundleIdentifier: "com.example.product"
        )
        try makeApplicationBundle(
            at: applications.appendingPathComponent("Example Beta.app"),
            bundleIdentifier: "com.example.product"
        )
        try makeApplicationBundle(
            at: applications.appendingPathComponent("Different.app"),
            bundleIdentifier: "com.example.different"
        )
        try write(
            bytes: 4_096,
            to: applications.appendingPathComponent("Setapp/Contents/payload.bin")
        )
        let protectedRule = duplicateApplicationsRule()

        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FixtureReadOnlyFileSystem(),
            ruleSet: makeRuleSet(rules: [protectedRule]),
            applicationsURL: applications
        )
        let session = try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home)
        ) { _ in }

        XCTAssertEqual(Set(session.candidates.map { $0.sourceURL.lastPathComponent }), [
            "Example.app", "Example Beta.app",
        ])
        XCTAssertTrue(session.candidates.allSatisfy {
            $0.risk == .protected
                && $0.action == .moveToTrashAfterProtectedReview
                && $0.isSelectable
                && $0.selectionEligibility == .selectableWithProtectedReview
                && $0.measurementCompleteness == .complete
                && $0.estimatedSizeBytes >= 4_096
                && $0.ownerResolution == .applicationBundle
                && $0.ownerBundleIdentifiers == ["com.example.product"]
                && $0.recommendation.evidenceCodes.contains("duplicate-bundle-identifier")
                && $0.duplicateApplicationGroupCode != nil
        })
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.isEmpty)

        var selection = CleanupSelection()
        let selected = try XCTUnwrap(session.candidates.first)
        selection.setCandidate(selected.id, selected: true, in: session)
        XCTAssertTrue(selection.isExplicitlySelected(selected.id))
    }

    /// D25: app bundles are removed from the Uninstall page, so the validator
    /// rejects rules that would list whole apps in the junk scan.
    func testApprovedCreativeApplicationsUseBundleIdentifierAllowlist() throws {
        let allowlisted = CleanupRule(
            id: "applications.large-creative-apps",
            selectionPolicyVersion: 1,
            categoryID: "applications",
            categoryTitleKey: "cleanup.category.applications",
            titleKey: "cleanup.rule.largeCreativeApps.title",
            root: CleanupRuleRoot(kind: .applicationsDirectory, path: "/Applications"),
            maximumDepth: 0,
            minimumAgeDays: 0,
            minimumBytes: 1,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: ["app"],
                nameMatcher: CleanupNameMatcher(mode: .any, values: [])
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .metadataOnly,
            risk: .protected,
            recommendation: .notRecommended,
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrashAfterProtectedReview,
            requiredClosedBundleIDs: [],
            reasonKey: "cleanup.rule.largeCreativeApps.reason",
            includedBundleIdentifiers: ["com.example.allowed"]
        )
        let informational = CleanupRule(
            id: "applications.installed-apps",
            selectionPolicyVersion: 3,
            categoryID: "applications",
            categoryTitleKey: "cleanup.category.applications",
            titleKey: "cleanup.rule.installedApps.title",
            root: CleanupRuleRoot(kind: .applicationsDirectory, path: "/Applications"),
            maximumDepth: 32,
            minimumAgeDays: 0,
            minimumBytes: 1,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: [],
                nameMatcher: CleanupNameMatcher(mode: .any, values: [])
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .metadataOnly,
            risk: .informational,
            recommendation: .advisoryOnly,
            defaultSelection: .forbidden,
            executionEligibility: .advisoryOnly,
            measurementRequirement: .bestEffort,
            allowsManualSelection: false,
            action: .revealOnly,
            requiredClosedBundleIDs: [],
            reasonKey: "cleanup.rule.installedApps.reason"
        )
        for rule in [allowlisted, informational] {
            XCTAssertThrowsError(try CleanupRuleValidator.validate(makeRuleSet(rules: [rule]))) {
                XCTAssertEqual(
                    $0 as? CleanupRuleValidationError,
                    .unsafeActionRiskCombination(ruleID: rule.id)
                )
            }
        }
        XCTAssertNoThrow(try CleanupRuleValidator.validate(makeRuleSet(rules: [duplicateApplicationsRule()])))
    }

    func testOptInCapturesCurrentHomeStorageAnalyzerParity() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "STORAGE_ANALYZER_PARITY_OUTPUT"
        ], !outputPath.isEmpty else {
            throw XCTSkip("Set STORAGE_ANALYZER_PARITY_OUTPUT for a read-only live comparison.")
        }
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard outputURL.path.hasPrefix("/tmp/storage-cleaner-storage-parity-"),
              outputURL.pathExtension == "json" else {
            XCTFail("Parity output must be a JSON file under /tmp/storage-cleaner-storage-parity-*")
            return
        }

        let ruleSet = try CleanupRuleSetLoader.loadBundled()
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FoundationReadOnlyFileSystem(),
            ruleSet: ruleSet
        )
        let session = try await scanner.scan(
            request: CleanupScanRequest()
        ) { _ in }
        let payload: [String: Any] = [
            "rulesVersion": session.rulesVersion,
            "outcome": session.outcome.rawValue,
            "durationSeconds": session.metrics.duration,
            "visitedDirectoryCount": session.metrics.visitedDirectoryCount,
            "visitedEntryCount": session.metrics.visitedEntryCount,
            "candidateCount": session.metrics.candidateCount,
            "completeMeasurementCandidateCount": session.metrics.completeMeasurementCandidateCount,
            "lowerBoundMeasurementCandidateCount": session.metrics.lowerBoundMeasurementCandidateCount,
            "failedMeasurementCandidateCount": session.metrics.failedMeasurementCandidateCount,
            "permissionFailureCount": session.metrics.permissionFailureCount,
            "cloudSkippedCount": session.metrics.cloudSkippedCount,
            "timedOutRuleCount": session.metrics.timedOutRuleCount,
            "truncatedCandidateCount": session.metrics.truncatedCandidateCount,
            "estimatedCandidateBytes": session.metrics.estimatedCandidateBytes,
            "groups": session.categories.flatMap(\.subcategories).map { subcategory in
                [
                    "id": subcategory.id,
                    "risk": subcategory.risk.rawValue,
                    "itemCount": subcategory.candidates.count,
                    "bytes": subcategory.discoveredBytes,
                ] as [String: Any]
            },
            "candidates": session.candidates.map { candidate in
                [
                    "ruleID": candidate.ruleID,
                    "name": candidate.sourceURL.lastPathComponent,
                    "path": candidate.sourceURL.path,
                    "sizeBytes": candidate.estimatedSizeBytes,
                    "logicalSizeBytes": candidate.snapshot.logicalSizeBytes,
                    "allocatedSizeBytes": candidate.snapshot.allocatedSizeBytes ?? 0,
                    "risk": candidate.risk.rawValue,
                    "action": candidate.action.rawValue,
                    "selectionEligibility": candidate.selectionEligibility.rawValue,
                    "defaultSelection": candidate.defaultSelection.rawValue,
                    "developerTool": candidate.developerTool?.rawValue ?? "",
                    "developerArtifactKind": candidate.developerArtifactKind?.rawValue ?? "",
                ] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: outputURL, options: .atomic)

        XCTAssertFalse(session.candidates.isEmpty)
    }

    func testOptInCapturesCurrentHomeDeveloperArtifactScan() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "DEVELOPER_ARTIFACT_SCAN_OUTPUT"
        ], !outputPath.isEmpty else {
            throw XCTSkip("Set DEVELOPER_ARTIFACT_SCAN_OUTPUT for a read-only live scan.")
        }
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard outputURL.path.hasPrefix("/tmp/storage-cleaner-developer-artifacts-"),
              outputURL.pathExtension == "json" else {
            XCTFail("Developer artifact output must be JSON under /tmp.")
            return
        }

        let request = CleanupScanRequest(
            maximumDuration: 30,
            includedCategoryIDs: ["developer"]
        )
        let session = try await CleanupScanOperations.live(request) { _ in }
        let payload: [String: Any] = [
            "outcome": session.outcome.rawValue,
            "durationSeconds": session.metrics.duration,
            "candidateCount": session.metrics.candidateCount,
            "timedOutRuleCount": session.metrics.timedOutRuleCount,
            "candidates": session.candidates.map { candidate in
                [
                    "path": candidate.snapshot.standardizedPath,
                    "tool": candidate.developerTool?.displayName ?? "",
                    "artifactKind": candidate.developerArtifactKind?.rawValue ?? "",
                    "risk": candidate.risk.rawValue,
                    "action": candidate.action.rawValue,
                    "isSelectable": candidate.isSelectable,
                    "estimatedBytes": candidate.estimatedSizeBytes,
                    "creationTimeNanoseconds": candidate.snapshot.identity.creationTimeNanoseconds ?? 0,
                    "latestActivityNanoseconds": candidate.latestContentModificationTimeNanoseconds ?? 0,
                ] as [String: Any]
            },
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputURL, options: .atomic)

        XCTAssertEqual(session.includedCategoryIDs, ["developer"])
        XCTAssertLessThanOrEqual(session.metrics.duration, 31)
    }

    func testRuleValidatorRejectsTraversalAndUnsafeAutomaticRoot() {
        XCTAssertThrowsError(try CleanupRuleValidator.validate(makeRuleSet(rules: [
            makeRule(id: "bad.path", root: "Library/Caches/../Logs")
        ]))) { error in
            XCTAssertEqual(
                error as? CleanupRuleValidationError,
                .invalidRelativePath(ruleID: "bad.path")
            )
        }

        XCTAssertThrowsError(try CleanupRuleValidator.validate(makeRuleSet(rules: [
            makeRule(id: "bad.root", root: "Downloads")
        ]))) { error in
            XCTAssertEqual(
                error as? CleanupRuleValidationError,
                .forbiddenRoot(ruleID: "bad.root")
            )
        }

        XCTAssertThrowsError(try CleanupRuleValidator.validate(makeRuleSet(rules: [
            makeRule(
                id: "bad.root-exclusion",
                root: ".cargo",
                candidateScope: .root,
                excludedRelativePrefixes: ["bin"]
            )
        ]))) { error in
            XCTAssertEqual(
                error as? CleanupRuleValidationError,
                .unsafeActionRiskCombination(ruleID: "bad.root-exclusion")
            )
        }

        for matcher in [
            CleanupNameMatcher(mode: .exact, values: ["_npx*"]),
            CleanupNameMatcher(mode: .exact, values: ["café", "cafe\u{301}"]),
        ] {
            XCTAssertThrowsError(try CleanupRuleValidator.validate(makeRuleSet(rules: [
                makeRule(id: "bad.matcher", nameMatcher: matcher)
            ]))) { error in
                XCTAssertEqual(
                    error as? CleanupRuleValidationError,
                    .invalidNameMatcher(ruleID: "bad.matcher")
                )
            }
        }

        XCTAssertThrowsError(try CleanupRuleValidator.validate(makeRuleSet(rules: [
            makeRule(
                id: "bad.optional-default",
                recommendation: .optional,
                defaultSelection: .selected
            )
        ]))) { error in
            XCTAssertEqual(
                error as? CleanupRuleValidationError,
                .unsafeActionRiskCombination(ruleID: "bad.optional-default")
            )
        }
    }

    func testPathBoundaryUsesComponentsNotStringPrefixes() {
        XCTAssertTrue(PathSafety.isContained(
            "/tmp/home/Library/Caches/App",
            in: "/tmp/home/Library/Caches",
            resolvingSymlinks: false
        ))
        XCTAssertFalse(PathSafety.isContained(
            "/tmp/home/Library/Caches-Escape/App",
            in: "/tmp/home/Library/Caches",
            resolvingSymlinks: false
        ))
    }

    func testReadOnlyFixtureProducesCategoriesRiskReasonsAndSeparateSpaceTotals() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 4_096, to: home.appendingPathComponent("Library/Caches/App/cache.bin"))
        try write(bytes: 2_048, to: home.appendingPathComponent("Library/Logs/app.log"))
        let ruleSet = makeRuleSet(rules: [
            makeRule(id: "system.cache"),
            makeRule(
                id: "system.logs",
                root: "Library/Logs",
                categoryID: "system",
                categoryTitleKey: "cleanup.category.system",
                titleKey: "cleanup.rule.userLogs.title",
                risk: .reviewOnly,
                recommendation: .advisoryOnly,
                allowsManualSelection: false,
                action: .revealOnly,
                reasonKey: "cleanup.rule.userLogs.reason"
            )
        ])
        let session = try await scan(home: home, ruleSet: ruleSet)

        // D19: the reveal-only log is found but not listed; it is counted
        // under "some scopes were safely skipped".
        XCTAssertEqual(
            session.outcome,
            .partial,
            "issues=\(session.issues.map { "\($0.kind.rawValue):\($0.path ?? "")" }) permissions=\(session.permissions.map { "\($0.status.rawValue):\($0.path)" })"
        )
        XCTAssertEqual(session.metrics.notActionableCandidateCount, 1)
        XCTAssertTrue(session.issues.contains { $0.kind == .candidateNotActionable })
        XCTAssertEqual(session.categories.count, 1)
        XCTAssertEqual(session.categories.first?.subcategories.count, 2)
        XCTAssertEqual(session.candidates.count, 1)
        XCTAssertEqual(Set(session.candidates.map(\.risk)), [.safe])
        XCTAssertTrue(session.candidates.allSatisfy { !$0.reason.isEmpty })

        XCTAssertEqual(
            CleanupSelection.defaults(in: session).selectedCandidates(in: session).map(\.risk),
            [.safe]
        )
        var selection = CleanupSelection.recommended(in: session)
        XCTAssertEqual(selection.selectedCandidates(in: session).count, 1)
        XCTAssertEqual(
            selection.selectedBytes(in: session),
            session.candidates.first(where: { $0.risk == .safe })?.estimatedSizeBytes
        )
        selection.setCandidates(
            session.categories.first?.selectableCandidateIDs ?? [],
            selected: false,
            in: session
        )
        XCTAssertEqual(selection.selectedBytes(in: session), 0)

        let unknownID = ScanCandidateID()
        selection.setCandidates(
            session.candidates.map(\.id) + [unknownID],
            selected: true,
            in: session
        )
        XCTAssertEqual(selection.selectedCandidates(in: session).map(\.risk), [.safe])
        XCTAssertFalse(selection.selectedCandidateIDs.contains(unknownID))
        XCTAssertTrue(selection.selectedCandidates(in: session).allSatisfy {
            selection.isExplicitlySelected($0.id)
        })
        XCTAssertGreaterThan(session.metrics.estimatedCandidateBytes, 0)
    }

    func testPermissionDenialIsExplicitAndNotReportedAsEmptySuccess() async throws {
        let home = try makeFixtureHome()
        let root = home.appendingPathComponent("Library/Caches")
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: PermissionDeniedReadOnlyFileSystem(deniedPath: root.path),
            ruleSet: makeRuleSet()
        )

        let session = try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home)
        ) { _ in }

        XCTAssertEqual(session.outcome, .partial)
        XCTAssertEqual(session.permissions.first?.status, .permissionDenied)
        XCTAssertTrue(session.issues.contains { $0.kind == .permissionDenied })
        XCTAssertEqual(session.metrics.candidateCount, 0)
    }

    func testMissingOptionalScopeIsReportedWithoutTurningTheScanPartial() async throws {
        let home = try makeFixtureHome()
        let session = try await scan(
            home: home,
            ruleSet: makeRuleSet(rules: [makeRule(id: "developer.dot-cache", root: ".cache")])
        )

        XCTAssertEqual(session.outcome, .complete)
        XCTAssertEqual(session.permissions.first?.status, .missing)
        XCTAssertTrue(session.issues.isEmpty)
        XCTAssertTrue(session.candidates.isEmpty)
    }

    func testScanCapsEachRuleAtFortyLargestCandidatesAndBuildsTopFive() async throws {
        let home = try makeFixtureHome()
        for index in 1...45 {
            try write(
                bytes: index * 4_096,
                to: home.appendingPathComponent(
                    "Library/Caches/\(String(format: "%02d", index)).bin"
                )
            )
        }

        let session = try await scan(home: home, ruleSet: makeRuleSet())

        XCTAssertEqual(session.candidates.count, 40)
        XCTAssertEqual(session.metrics.truncatedCandidateCount, 5)
        XCTAssertEqual(session.metrics.completeMeasurementCandidateCount, 40)
        XCTAssertGreaterThan(session.metrics.visitedDirectoryCount, 0)
        XCTAssertEqual(
            session.topStorageCandidates.map(\.sourceURL.lastPathComponent),
            ["45.bin", "44.bin", "43.bin", "42.bin", "41.bin"]
        )
        XCTAssertFalse(session.candidates.contains { $0.sourceURL.lastPathComponent == "01.bin" })
        XCTAssertNotNil(session.system)
    }

    func testZeroDurationReturnsAnExplicitReadOnlyTimeout() async throws {
        let home = try makeFixtureHome()
        let file = home.appendingPathComponent("Library/Caches/keep.bin")
        try write(bytes: 1_024, to: file)
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FixtureReadOnlyFileSystem(),
            ruleSet: makeRuleSet()
        )

        let session = try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home, maximumDuration: 0)
        ) { _ in }

        XCTAssertEqual(session.outcome, .partial)
        XCTAssertTrue(session.issues.contains { $0.kind == .timedOut })
        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testSymbolicLinksAreSkippedWithoutFollowingTarget() async throws {
        let home = try makeFixtureHome()
        let outside = home.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).bin")
        addTeardownBlock { TestFileSystem.remove(outside) }
        try write(bytes: 8_192, to: outside)
        let link = home.appendingPathComponent("Library/Caches/outside-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        let session = try await scan(home: home, ruleSet: makeRuleSet())

        XCTAssertEqual(session.metrics.candidateCount, 0)
        XCTAssertTrue(
            session.issues.contains { $0.kind == .symbolicLinkSkipped },
            "issues=\(session.issues.map(\.kind.rawValue))"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    /// D19: a lower-bound item is selectable and enters the plan; the plan
    /// moves only the item's own root and never the link target.
    func testLowerBoundMeasurementIsVisibleButCannotEnterPlan() async throws {
        let home = try makeFixtureHome()
        let candidateRoot = home.appendingPathComponent("Library/Caches/candidate")
        try write(bytes: 4_096, to: candidateRoot.appendingPathComponent("payload.bin"))
        let outside = home.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).bin")
        addTeardownBlock { TestFileSystem.remove(outside) }
        try write(bytes: 8_192, to: outside)
        try FileManager.default.createSymbolicLink(
            at: candidateRoot.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )
        let rules = makeRuleSet(rules: [makeRule(
            nameMatcher: CleanupNameMatcher(mode: .exact, values: ["candidate"])
        )])

        let session = try await scan(home: home, ruleSet: rules)
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(
            candidate.measurementCompleteness,
            .lowerBound(reason: .symbolicLinkSkipped)
        )
        XCTAssertTrue(candidate.isSelectable)
        XCTAssertEqual(session.metrics.lowerBoundMeasurementCandidateCount, 1)
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.contains(candidate.id))
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: CleanupSelection(selectedCandidateIDs: [candidate.id]),
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(plan.items.map { PathSafety.lexicalPath($0.sourceURL.path) }, [PathSafety.lexicalPath(candidateRoot.path)])
        XCTAssertEqual(plan.items.first?.measurementCompleteness, .lowerBound(reason: .symbolicLinkSkipped))
    }

    /// D19: an item whose own folder cannot be listed cannot be acted on, so
    /// it is not listed; it is counted as safely skipped instead.
    func testFailedMeasurementIsVisibleButUnavailable() async throws {
        let home = try makeFixtureHome()
        let candidateRoot = home.appendingPathComponent("Library/Caches/blocked")
        try FileManager.default.createDirectory(
            at: candidateRoot,
            withIntermediateDirectories: true
        )
        let rules = makeRuleSet(rules: [makeRule(
            nameMatcher: CleanupNameMatcher(mode: .exact, values: ["blocked"]),
            minimumBytes: 0
        )])
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: ChildrenPermissionDeniedReadOnlyFileSystem(
                deniedPath: candidateRoot.path
            ),
            ruleSet: rules
        )

        let session = try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home)
        ) { _ in }

        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertEqual(session.metrics.notActionableCandidateCount, 1)
        XCTAssertEqual(session.metrics.failedMeasurementCandidateCount, 0)
        XCTAssertEqual(session.metrics.permissionFailureCount, 1)
        XCTAssertTrue(session.issues.contains {
            $0.kind == .candidateNotActionable
                && $0.path == candidateRoot.standardizedFileURL.path
        })
        XCTAssertEqual(session.outcome, .partial)
    }

    func testHardLinksAreCountedOnceByDeviceAndInode() async throws {
        let home = try makeFixtureHome()
        let first = home.appendingPathComponent("Library/Caches/first.bin")
        let second = home.appendingPathComponent("Library/Caches/second.bin")
        try write(bytes: 4_096, to: first)
        try FileManager.default.linkItem(at: first, to: second)

        let session = try await scan(home: home, ruleSet: makeRuleSet())

        XCTAssertEqual(session.metrics.candidateCount, 1)
        XCTAssertEqual(session.metrics.deduplicatedIdentityCount, 1)
        XCTAssertTrue(session.issues.contains { $0.kind == .hardLinkDeduplicated })
        XCTAssertEqual(session.metrics.estimatedCandidateBytes, 4_096)
    }

    func testCancellationStopsFixtureScanAndReturnsOnlyCompletedReadOnlyResults() async throws {
        let home = try makeFixtureHome()
        for index in 0..<200 {
            try write(
                bytes: 128,
                to: home.appendingPathComponent("Library/Caches/\(index).bin")
            )
        }
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: SlowReadOnlyFileSystem(delay: 0.002),
            ruleSet: makeRuleSet()
        )
        let task = Task {
            try await scanner.scan(
                request: CleanupScanRequest(userHomeURL: home)
            ) { _ in }
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let session = try await task.value

        XCTAssertEqual(session.outcome, .cancelled)
        XCTAssertLessThan(session.metrics.candidateCount, 200)
        XCTAssertEqual(
            FileManager.default.contents(atPath: home.appendingPathComponent(
                "Library/Caches/199.bin"
            ).path)?.count,
            128
        )
    }

    func testThreeStateSelectionIgnoresUnselectableCandidates() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Caches/a.bin"))
        try write(bytes: 2_048, to: home.appendingPathComponent("Library/Caches/b.bin"))
        let session = try await scan(home: home, ruleSet: makeRuleSet())
        let ids = session.categories[0].selectableCandidateIDs
        var selection = CleanupSelection.recommended(in: session)

        XCTAssertEqual(selection.state(for: ids), .checked)
        selection.setCandidate(ids[0], selected: false, in: session)
        XCTAssertEqual(selection.state(for: ids), .mixed)
        selection.setCandidate(ids[1], selected: false, in: session)
        XCTAssertEqual(selection.state(for: ids), .unchecked)
    }

    func testStorageAnalyzerGoldenSnapshotUsesStableIdentityAndSelectsOnlyGreenByDefault() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 8_192, to: home.appendingPathComponent("Library/Caches/b.bin"))
        try write(bytes: 4_096, to: home.appendingPathComponent("Library/Caches/a.bin"))
        let reviewLog = home.appendingPathComponent("Library/Logs/review.log")
        try write(bytes: 6_144, to: reviewLog)
        // The yellow log fixture is recommended by its rule, so "Select
        // Recommended" takes it (marked as explicitly reviewed). Since D47 its
        // last write no longer matters; it is kept quiet as before.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10 * 86_400)],
            ofItemAtPath: reviewLog.path
        )
        let rules = makeRuleSet(rules: [
            makeRule(id: "system.cache"),
            makeRule(
                id: "system.logs",
                root: "Library/Logs",
                risk: .reviewOnly,
                recommendation: .recommended,
                allowsManualSelection: true,
                action: .moveToTrashAfterReview,
                reasonKey: "cleanup.rule.userLogs.reason"
            ),
        ])

        let first = try await scan(home: home, ruleSet: rules)
        let second = try await scan(home: home, ruleSet: rules)
        let firstByPath = Dictionary(uniqueKeysWithValues: first.candidates.map {
            ($0.snapshot.standardizedPath, $0)
        })
        let secondByPath = Dictionary(uniqueKeysWithValues: second.candidates.map {
            ($0.snapshot.standardizedPath, $0)
        })

        XCTAssertEqual(firstByPath.keys, secondByPath.keys)
        for path in firstByPath.keys {
            XCTAssertEqual(firstByPath[path]?.id, secondByPath[path]?.id)
        }
        XCTAssertEqual(
            first.topStorageCandidates.map(\.sourceURL.lastPathComponent),
            ["b.bin", "review.log", "a.bin"]
        )
        XCTAssertEqual(
            first.candidates.first { $0.risk == .safe }?.selectionEligibility,
            .selectable
        )
        XCTAssertEqual(
            first.candidates.first { $0.risk == .reviewOnly }?.selectionEligibility,
            .selectableWithReview
        )
        let defaultCandidates = CleanupSelection.defaults(in: first).selectedCandidates(in: first)
        XCTAssertFalse(defaultCandidates.isEmpty)
        XCTAssertTrue(defaultCandidates.allSatisfy { $0.risk == .safe })
        XCTAssertTrue(first.candidates.filter { $0.risk == .safe }.allSatisfy { $0.defaultSelection == .selected })
        XCTAssertTrue(first.candidates.filter { $0.risk != .safe }.allSatisfy { $0.defaultSelection != .selected })
        let recommended = CleanupSelection.recommended(in: first)
        XCTAssertEqual(recommended.selectedCandidates(in: first).count, 3)
        let recommendedReview = try XCTUnwrap(
            first.candidates.first { $0.risk == .reviewOnly }
        )
        XCTAssertTrue(recommended.isExplicitlySelected(recommendedReview.id))
        XCTAssertTrue(first.candidates.allSatisfy { !$0.recommendation.reasonCode.isEmpty })
        XCTAssertTrue(first.candidates.allSatisfy {
            $0.recommendation.evidenceCodes.contains("storage-analyzer-macos-policy")
        })
    }

    func testRecommendedSelectionPreservesExplicitYellowSelection() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Caches/safe.bin"))
        try write(bytes: 1_024, to: home.appendingPathComponent("Downloads/review.bin"))
        let session = try await scan(home: home, ruleSet: makeRuleSet(rules: [
            makeRule(id: "system.cache"),
            makeRule(
                id: "downloads.review",
                root: "Downloads",
                risk: .reviewOnly,
                recommendation: .notRecommended,
                allowsManualSelection: true,
                action: .moveToTrashAfterReview
            ),
        ]))
        let review = try XCTUnwrap(session.candidates.first { $0.risk == .reviewOnly })
        var current = CleanupSelection.defaults(in: session)
        current.setCandidate(review.id, selected: true, in: session)

        let recommended = CleanupSelection.recommended(
            in: session,
            preservingExplicitReviewFrom: current
        )

        XCTAssertTrue(recommended.selectedCandidateIDs.contains(review.id))
        XCTAssertTrue(recommended.isExplicitlySelected(review.id))
        XCTAssertTrue(recommended.selectedCandidates(in: session).contains { $0.risk == .safe })
    }

    func testStableCandidateIDChangesWhenFileIdentityChanges() {
        let original = ScanCandidateID(stableKey: "rule\u{0}/path\u{0}1:2:file")
        let same = ScanCandidateID(stableKey: "rule\u{0}/path\u{0}1:2:file")
        let replaced = ScanCandidateID(stableKey: "rule\u{0}/path\u{0}1:99:file")

        XCTAssertEqual(original, same)
        XCTAssertNotEqual(original, replaced)
    }

    /// D19: a reveal-only rule produces no listed item. A forged selection of
    /// a non-selectable candidate is still rejected by the selection model.
    func testLegacyReviewOnlyCandidateCannotEnterSelectionEvenWithForgedID() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Logs/review.log"))
        let scanned = try await scan(home: home, ruleSet: makeRuleSet(rules: [
            makeRule(
                id: "system.logs",
                root: "Library/Logs",
                risk: .reviewOnly,
                recommendation: .advisoryOnly,
                allowsManualSelection: false,
                action: .revealOnly,
                reasonKey: "cleanup.rule.userLogs.reason"
            ),
        ]))
        XCTAssertTrue(scanned.candidates.isEmpty)
        XCTAssertEqual(scanned.metrics.notActionableCandidateCount, 1)

        let sessionID = ScanSessionID()
        let snapshot = try FixtureReadOnlyFileSystem().snapshot(
            at: home.appendingPathComponent("Library/Logs/review.log")
        )
        let forged = ScanCandidate(
            id: ScanCandidateID(),
            sessionID: sessionID,
            ruleID: "system.logs",
            ruleSelectionPolicyVersion: 1,
            categoryID: "system",
            categoryTitle: "System",
            subcategoryTitle: "Logs",
            sourceURL: home.appendingPathComponent("Library/Logs/review.log"),
            allowedRootURL: home.appendingPathComponent("Library/Logs"),
            snapshot: snapshot,
            risk: .reviewOnly,
            recommendation: CleanupRecommendation(
                level: .advisoryOnly,
                reasonCode: "cleanup.rule.userLogs.reason",
                evidenceCodes: []
            ),
            defaultSelection: .forbidden,
            executionEligibility: .advisoryOnly,
            measurementCompleteness: .complete,
            isManuallySelectable: false,
            action: .revealOnly,
            requiredClosedBundleIDs: [],
            reason: "Fixture"
        )
        let session = ScanSession(
            id: sessionID,
            rulesVersion: "fixture.1",
            startedAt: Date(),
            completedAt: Date(),
            outcome: .complete,
            categories: [CleanupScanCategory(
                id: "system",
                title: "System",
                subcategories: [CleanupScanSubcategory(
                    id: "system.logs",
                    title: "Logs",
                    risk: .reviewOnly,
                    recommendation: .advisoryOnly,
                    reason: "Fixture",
                    candidates: [forged]
                )]
            )],
            issues: [],
            permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: 1,
                candidateCount: 1,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: 1_024,
                duration: 0
            )
        )
        var selection = CleanupSelection(selectedCandidateIDs: [forged.id])

        XCTAssertTrue(selection.selectedCandidates(in: session).isEmpty)
        selection.setCandidate(forged.id, selected: true, in: session)
        XCTAssertTrue(selection.selectedCandidateIDs.isEmpty)
    }

    func testReviewedYellowRequiresExplicitSelectionBeforePlanBuild() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Logs/review.log"))
        let rules = makeRuleSet(rules: [
            makeRule(
                id: "system.logs",
                root: "Library/Logs",
                risk: .reviewOnly,
                recommendation: .notRecommended,
                allowsManualSelection: true,
                action: .moveToTrashAfterReview,
                reasonKey: "cleanup.rule.userLogs.reason"
            ),
        ])
        let session = try await scan(home: home, ruleSet: rules)
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(candidate.selectionEligibility, .selectableWithReview)
        XCTAssertTrue(CleanupSelection.recommended(in: session).selectedCandidateIDs.isEmpty)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: session,
            selection: CleanupSelection(selectedCandidateIDs: [candidate.id]),
            activeRules: rules,
            disposition: .trash
        )) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
        }

        var selection = CleanupSelection()
        selection.setCandidate(candidate.id, selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )

        XCTAssertTrue(selection.isExplicitlySelected(candidate.id))
        XCTAssertEqual(plan.reviewItems.count, 1)
        XCTAssertEqual(plan.reviewItems.first?.action, .moveToTrashAfterReview)
        XCTAssertTrue(plan.reviewItems.first?.explicitUserSelection == true)

        let preflight = await SafeCleanupExecutor(
            metadataReader: FixtureReadOnlyFileSystem(),
            coordinator: HeavyWorkCoordinator()
        ).preflight(
            plan: plan,
            context: CleanupExecutionContext(
                featureConfiguration: .productDefault,
                activeSessionID: session.id,
                activeRules: rules,
                userHomeURL: home,
                excludedURLs: [],
                approvedPlanItemIDs: nil
            )
        )
        XCTAssertEqual(
            preflight.readyCount,
            1,
            "statuses=\(preflight.items.map(\.status))"
        )
        XCTAssertTrue(
            preflight.isConfirmable,
            "statuses=\(preflight.items.map(\.status))"
        )
    }

    func testTopLevelSelectAllSelectsOnlyGreenCandidates() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Caches/safe.bin"))
        try write(bytes: 2_048, to: home.appendingPathComponent("Downloads/review.bin"))
        let session = try await scan(home: home, ruleSet: makeRuleSet(rules: [
            makeRule(id: "system.cache"),
            makeRule(
                id: "downloads.review",
                root: "Downloads",
                risk: .reviewOnly,
                recommendation: .notRecommended,
                allowsManualSelection: true,
                action: .moveToTrashAfterReview,
                reasonKey: "cleanup.rule.userLogs.reason"
            ),
        ]))
        let store = try await makeScanOnlyStore(session: session)

        await MainActor.run { store.startScan() }
        while await MainActor.run(body: { store.isScanning }) {
            await Task.yield()
        }

        let selected = await MainActor.run {
            store.clearCleanupCandidates()
            store.selectAllCleanupCandidates()
            return store.cleanupSelection.selectedCandidates(in: session)
        }

        let selectedIDs = Set(selected.map(\.id))
        XCTAssertFalse(selected.isEmpty)
        XCTAssertTrue(selected.allSatisfy { $0.risk == .safe })
        XCTAssertTrue(session.candidates.contains {
            $0.risk == .reviewOnly && !selectedIDs.contains($0.id)
        })
    }

    func testProgressPrebuildsEveryRuleAndOnlyUpdatesRowState() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Caches/a.bin"))
        let rules = makeRuleSet(rules: [
            makeRule(id: "system.cache"),
            makeRule(
                id: "system.logs",
                root: "Library/Logs",
                risk: .reviewOnly,
                recommendation: .notRecommended,
                allowsManualSelection: true,
                action: .moveToTrashAfterReview,
                reasonKey: "cleanup.rule.userLogs.reason"
            ),
        ])
        let recorder = CleanupProgressRecorder()
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FixtureReadOnlyFileSystem(),
            ruleSet: rules
        )

        _ = try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home)
        ) { snapshot in
            await recorder.append(snapshot)
        }

        let snapshots = await recorder.all()
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertTrue(snapshots.allSatisfy { $0.groups.map(\.id) == rules.rules.map(\.id) })
        XCTAssertTrue(snapshots.first?.groups.allSatisfy { $0.state == .pending } == true)
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.groups.contains { $0.id == "system.cache" && $0.state == .scanning }
        })
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.currentPath?.hasSuffix("/Library/Caches/a.bin") == true
                && snapshot.currentRuleCompletedItemCount == 0
                && snapshot.currentRuleTotalItemCount == 1
        })
        XCTAssertEqual(snapshots.last?.groups.map(\.state), [.found, .clean])
    }

    func testDryRunDoesNotMutateFixture() async throws {
        let home = try makeFixtureHome()
        let file = home.appendingPathComponent("Library/Caches/keep.bin")
        try write(bytes: 3_072, to: file)
        let before = try Data(contentsOf: file)
        let session = try await scan(home: home, ruleSet: makeRuleSet())
        let selection = CleanupSelection.recommended(in: session)

        let summary = CleanupDryRunSummary.make(
            session: session,
            selection: selection
        )

        XCTAssertEqual(summary.selectedCount, 1)
        XCTAssertEqual(summary.selectedBytes, session.candidates[0].estimatedSizeBytes)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// A scan-only store that completes the given fixture session. Its scan
    /// history is private to the test (r2-live-fixes-2 review P2-1).
    private func makeScanOnlyStore(session: ScanSession) async throws -> ScanStore {
        let historySuite = ScanHistoryTestDefaults.makeSuite(for: self)
        return try await MainActor.run {
            try ScanStore.makeForTests(for: self,
                scanHistoryDefaults: ScanHistoryTestDefaults.defaults(named: historySuite),
                cleanupFeatureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
                cleanupScanOperation: { _, _ in session }
            )
        }
    }

    func testScanOnlyFeatureFlagDisablesAllLegacyTrashEntryPoints() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Caches/a.bin"))
        let session = try await scan(home: home, ruleSet: makeRuleSet())
        let store = try await makeScanOnlyStore(session: session)

        await MainActor.run { store.startScan() }
        while await MainActor.run(body: { store.isScanning }) {
            await Task.yield()
        }

        await MainActor.run {
            XCTAssertEqual(store.cleanupScanSession?.id, session.id)
            XCTAssertFalse(store.canRequestEmptyTrash)
            XCTAssertFalse(store.canRequestGreenTrash)
            store.selectAllCleanupCandidates()
            store.prepareCleanupDryRun()
            XCTAssertEqual(store.cleanupDryRunSummary?.selectedCount, 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Library/Caches/a.bin").path
        ))
    }

    private func scan(
        home: URL,
        ruleSet: CleanupRuleSet
    ) async throws -> ScanSession {
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FixtureReadOnlyFileSystem(),
            ruleSet: ruleSet
        )
        return try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home)
        ) { _ in }
    }

    private func makeFixtureHome() throws -> URL {
        let root = TestFileSystem.uniqueRoot("CleanupFixture")
        TestFileSystem.registerCleanup(of: root, for: self)
        let home = root.appendingPathComponent("Home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Logs"),
            withIntermediateDirectories: true
        )
        return home
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func makeApplicationBundle(
        at url: URL,
        bundleIdentifier: String
    ) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleName": url.deletingPathExtension().lastPathComponent,
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try write(bytes: 4_096, to: contents.appendingPathComponent("Resources/payload.bin"))
    }

    private func duplicateApplicationsRule() -> CleanupRule {
        CleanupRule(
            id: "applications.duplicate-installed-apps",
            selectionPolicyVersion: 1,
            categoryID: "applications",
            categoryTitleKey: "cleanup.category.applications",
            titleKey: "cleanup.rule.duplicateInstalledApps.title",
            root: CleanupRuleRoot(kind: .applicationsDirectory, path: "/Applications"),
            maximumDepth: 32,
            minimumAgeDays: 0,
            minimumBytes: 1,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: ["app"],
                nameMatcher: CleanupNameMatcher(mode: .any, values: [])
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .metadataOnly,
            risk: .protected,
            recommendation: .notRecommended,
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrashAfterProtectedReview,
            requiredClosedBundleIDs: [],
            reasonKey: "cleanup.rule.duplicateInstalledApps.reason",
            requiresDuplicateBundleIdentifier: true
        )
    }

    private func makeRuleSet(
        rules: [CleanupRule]? = nil
    ) -> CleanupRuleSet {
        CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "fixture.1",
            rules: rules ?? [makeRule()]
        )
    }

    private func makeRule(
        id: String = "system.cache",
        root: String = "Library/Caches",
        categoryID: String = "system",
        categoryTitleKey: String = "cleanup.category.system",
        titleKey: String = "cleanup.rule.userCaches.title",
        candidateScope: CleanupRuleCandidateScope? = nil,
        excludedRelativePrefixes: [String] = [],
        nameMatcher: CleanupNameMatcher = CleanupNameMatcher(mode: .any, values: []),
        maximumDepth: Int = 4,
        minimumAgeDays: Int = 0,
        minimumBytes: Int64 = 1,
        risk: CleanupRisk = .safe,
        recommendation: CleanupRecommendationLevel = .recommended,
        defaultSelection: CleanupDefaultSelection? = nil,
        executionEligibility: CleanupExecutionEligibility? = nil,
        measurementRequirement: CleanupMeasurementRequirement? = nil,
        allowsManualSelection: Bool = true,
        action: CleanupRuleAction = .moveToTrash,
        reasonKey: String = "cleanup.rule.userCaches.reason"
    ) -> CleanupRule {
        let actionExecution: CleanupExecutionEligibility = switch action {
        case .moveToTrash: .eligible
        case .moveToTrashAfterReview: .eligibleAfterReview
        case .moveToTrashAfterProtectedReview, .emptyTrash: .eligibleAfterProtectedReview
        case .revealOnly: .advisoryOnly
        }
        let resolvedExecution = executionEligibility ?? actionExecution
        let resolvedDefault = defaultSelection ?? (
            action == .revealOnly
                ? .forbidden
                : (risk == .safe && recommendation == .recommended ? .selected : .unselected)
        )
        return CleanupRule(
            id: id,
            selectionPolicyVersion: 1,
            categoryID: categoryID,
            categoryTitleKey: categoryTitleKey,
            titleKey: titleKey,
            root: CleanupRuleRoot(kind: .homeRelative, path: root),
            candidateScope: candidateScope,
            maximumDepth: maximumDepth,
            minimumAgeDays: minimumAgeDays,
            minimumBytes: minimumBytes,
            include: CleanupRuleMatch(
                entryKinds: [.regularFile, .directory],
                extensions: [],
                nameMatcher: nameMatcher
            ),
            exclude: CleanupRuleExclusion(
                relativePrefixes: excludedRelativePrefixes,
                extensions: []
            ),
            cloudPolicy: .skipPlaceholder,
            risk: risk,
            recommendation: recommendation,
            defaultSelection: resolvedDefault,
            executionEligibility: resolvedExecution,
            measurementRequirement: measurementRequirement
                ?? (action.movesToTrash ? .complete : .bestEffort),
            allowsManualSelection: allowsManualSelection,
            action: action,
            requiredClosedBundleIDs: [],
            reasonKey: reasonKey
        )
    }

    /// P2-4: a folder the app may not read (for example the Trash without Full
    /// Disk Access) can fail with a Cocoa or a POSIX error. Either way it is a
    /// permission problem, so the scan shows the Full Disk Access guidance
    /// instead of treating it as unreadable. Codes are read in their own domain.
    func testPermissionErrorsAreRecognizedInEveryDomain() {
        let permissionErrors: [Error] = [
            CocoaError(.fileReadNoPermission),
            CocoaError(.fileWriteNoPermission),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            POSIXError(.EPERM),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            ]),
        ]
        for error in permissionErrors {
            XCTAssertEqual(
                FoundationReadOnlyFileSystem.cleanupError(for: error),
                .permissionDenied,
                "\(error)"
            )
        }
        let missingErrors: [Error] = [
            CocoaError(.fileNoSuchFile),
            CocoaError(.fileReadNoSuchFile),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
        ]
        for error in missingErrors {
            XCTAssertEqual(FoundationReadOnlyFileSystem.cleanupError(for: error), .vanished, "\(error)")
        }
        // POSIX code 4 is EINTR, not Cocoa's "no such file" (also 4).
        XCTAssertEqual(
            FoundationReadOnlyFileSystem.cleanupError(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR))),
            .unreadable
        )
        XCTAssertEqual(
            FoundationReadOnlyFileSystem.cleanupError(for: CocoaError(.fileReadCorruptFile)),
            .unreadable
        )
    }
}

private actor CleanupProgressRecorder {
    private var snapshots = [CleanupScanProgress]()

    func append(_ progress: CleanupScanProgress) {
        snapshots.append(progress)
    }

    func all() -> [CleanupScanProgress] { snapshots }
}

private struct PermissionDeniedReadOnlyFileSystem: ReadOnlyFileSystem {
    let deniedPath: String

    func snapshot(at url: URL) throws -> FileSnapshot {
        if PathSafety.lexicalPath(url.path) == PathSafety.lexicalPath(deniedPath) {
            throw CleanupFileSystemError.permissionDenied
        }
        return try FixtureReadOnlyFileSystem().snapshot(at: url)
    }

    func children(of directory: URL) throws -> [URL] {
        try FixtureReadOnlyFileSystem().children(of: directory)
    }
}

private struct ChildrenPermissionDeniedReadOnlyFileSystem: ReadOnlyFileSystem {
    let deniedPath: String
    private let base = FixtureReadOnlyFileSystem()

    func snapshot(at url: URL) throws -> FileSnapshot {
        try base.snapshot(at: url)
    }

    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        try base.aggregateSnapshot(at: url)
    }

    func children(of directory: URL) throws -> [URL] {
        guard PathSafety.lexicalPath(directory.path) != PathSafety.lexicalPath(deniedPath) else {
            throw CleanupFileSystemError.permissionDenied
        }
        return try base.children(of: directory)
    }
}

private struct SlowReadOnlyFileSystem: ReadOnlyFileSystem {
    let delay: TimeInterval

    func snapshot(at url: URL) throws -> FileSnapshot {
        Thread.sleep(forTimeInterval: delay)
        return try FixtureReadOnlyFileSystem().snapshot(at: url)
    }

    func children(of directory: URL) throws -> [URL] {
        try FixtureReadOnlyFileSystem().children(of: directory)
    }
}

private struct FixtureReadOnlyFileSystem: ReadOnlyFileSystem {
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
        try FoundationReadOnlyFileSystem().children(of: directory)
    }
}
