import Foundation
import XCTest
@testable import StorageCleanerMac

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
        let suiteName = "CleanupRuleScannerTests.developer-threshold.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let first = ScanStore(cleanupPreferences: preferences)
        first.setDeveloperInactivityThresholdDays(75)
        XCTAssertEqual(first.developerInactivityThresholdDays, 75)
        XCTAssertEqual(
            ScanStore(cleanupPreferences: preferences).developerInactivityThresholdDays,
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
        try write(
            bytes: 128 * 1_024,
            to: home.appendingPathComponent(".codex/logs/latest.log")
        )
        try write(
            bytes: 128 * 1_024,
            to: home.appendingPathComponent(".codex/sessions/protected.jsonl")
        )
        try write(
            bytes: 128 * 1_024,
            to: home.appendingPathComponent(".gemini/history/session.json")
        )
        try write(
            bytes: 128 * 1_024,
            to: home.appendingPathComponent(".workbuddy/sessions/session.json")
        )
        try write(
            bytes: 128 * 1_024,
            to: home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage/protected.bin")
        )

        let wantedIDs = [
            "developer.cursor-cache",
            "developer.opencode-cache",
            "developer.codex-logs",
            "developer.gemini-cli-data",
            "developer.workbuddy-agent-data",
        ]
        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "developer-artifacts.fixture",
            rules: wantedIDs.compactMap { wantedID in
                DeveloperToolArtifactCatalog.definitions.first { $0.id == wantedID }?.cleanupRule
            }
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
        XCTAssertEqual(codexLogs.action, .revealOnly)
        XCTAssertFalse(codexLogs.isSelectable)

        let gemini = try XCTUnwrap(byRuleID["developer.gemini-cli-data"])
        XCTAssertEqual(gemini.developerTool, .geminiCLI)
        XCTAssertEqual(gemini.developerArtifactKind, .agentData)
        XCTAssertEqual(gemini.action, .revealOnly)
        XCTAssertFalse(gemini.isSelectable)

        let workBuddy = try XCTUnwrap(byRuleID["developer.workbuddy-agent-data"])
        XCTAssertEqual(workBuddy.developerTool, .workBuddy)
        XCTAssertEqual(workBuddy.developerArtifactKind, .agentData)
        XCTAssertEqual(workBuddy.action, .revealOnly)
        XCTAssertFalse(workBuddy.isSelectable)
        XCTAssertNotNil(workBuddy.snapshot.identity.creationTimeNanoseconds)

        XCTAssertFalse(session.candidates.contains {
            $0.snapshot.standardizedPath.contains("/sessions/")
                || $0.snapshot.standardizedPath.contains("/User/workspaceStorage/")
        })
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
        XCTAssertFalse(defaults.selectedCandidateIDs.contains(npmContent.id))
    }

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
            "personal.pictures-library",
            "user-data.wechat",
            "user-data.chrome",
            "user-data.codex-sessions",
            "user-data.ego-lite",
            "user-data.crossover",
            "applications.duplicate-installed-apps",
            "applications.large-creative-apps",
        ]
        for ruleID in artifactRuleIDs + coverageRuleIDs
            + decisionRuleIDs + ["applications.installed-apps"] {
            XCTAssertNotNil(ruleByID[ruleID], "Missing storage-analyzer scope: \(ruleID)")
        }
        XCTAssertEqual(
            Set(ruleByID.keys),
            Set(
                artifactRuleIDs + coverageRuleIDs
                    + decisionRuleIDs + ["applications.installed-apps"]
            )
        )
        XCTAssertEqual(
            rules.filter { $0.risk == .safe }.count,
            5
                + artifactDefinitions.filter { $0.policy == .regenerable }.count
                + CleanupCoverageCatalog.regenerableCacheDefinitions.count
        )
        XCTAssertEqual(
            rules.filter { $0.risk == .reviewOnly }.count,
            16 + artifactDefinitions.filter { $0.policy != .regenerable }.count
        )
        XCTAssertEqual(rules.filter { $0.risk == .protected }.count, 2)

        let automaticRules = rules.filter { $0.action == .moveToTrash }
        XCTAssertFalse(automaticRules.isEmpty)
        XCTAssertTrue(automaticRules.allSatisfy {
            $0.risk == .safe && $0.allowsManualSelection
        })
        let reviewedRules = rules.filter { $0.action == .moveToTrashAfterReview }
        XCTAssertFalse(reviewedRules.isEmpty)
        XCTAssertTrue(reviewedRules.allSatisfy {
            $0.risk == .reviewOnly && $0.allowsManualSelection
        })
        let protectedReviewedRules = rules.filter {
            $0.action == .moveToTrashAfterProtectedReview
        }
        XCTAssertFalse(protectedReviewedRules.isEmpty)
        XCTAssertTrue(protectedReviewedRules.allSatisfy {
            $0.risk == .protected && $0.allowsManualSelection
        })

        let applications = try XCTUnwrap(ruleByID["applications.installed-apps"])
        XCTAssertEqual(applications.root.kind.rawValue, "applicationsDirectory")
        XCTAssertEqual(applications.root.path, "/Applications")
        XCTAssertEqual(applications.risk, .informational)
        XCTAssertEqual(applications.recommendation, .advisoryOnly)
        XCTAssertEqual(applications.defaultSelection, .forbidden)
        XCTAssertEqual(applications.executionEligibility, .advisoryOnly)
        XCTAssertEqual(applications.action, .revealOnly)
        XCTAssertFalse(applications.allowsManualSelection)
        XCTAssertEqual(applications.maximumDepth, 32)
        XCTAssertTrue(applications.include.extensions.isEmpty)

        let duplicateApplications = try XCTUnwrap(
            ruleByID["applications.duplicate-installed-apps"]
        )
        XCTAssertEqual(duplicateApplications.risk, .protected)
        XCTAssertEqual(duplicateApplications.recommendation, .notRecommended)
        XCTAssertEqual(duplicateApplications.action, .moveToTrashAfterProtectedReview)
        XCTAssertTrue(duplicateApplications.allowsManualSelection)
        XCTAssertEqual(duplicateApplications.maximumDepth, 0)
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

        for ruleID in ["system.user-caches", "system.user-logs"] {
            let rule = try XCTUnwrap(ruleByID[ruleID])
            XCTAssertEqual(rule.risk, .reviewOnly)
            XCTAssertEqual(rule.recommendation, .advisoryOnly)
            XCTAssertEqual(rule.defaultSelection, .forbidden)
            XCTAssertEqual(rule.executionEligibility, .advisoryOnly)
            XCTAssertEqual(rule.action, .revealOnly)
            XCTAssertFalse(rule.allowsManualSelection)
        }

        XCTAssertEqual(
            Set(artifactDefinitions.map(\.tool)),
            [
                .codex, .claudeCode, .cursor, .githubCopilot, .openCode, .openClaw,
                .geminiCLI, .workBuddy, .windsurf, .continueDev, .cline, .rooCode,
            ]
        )
        for definition in artifactDefinitions {
            let rule = try XCTUnwrap(ruleByID[definition.id])
            XCTAssertEqual(rule.developerTool, definition.tool)
            XCTAssertEqual(rule.developerArtifactKind, definition.kind)
            XCTAssertEqual(rule.root.path, definition.rootPath)
            XCTAssertEqual(Set(rule.include.nameMatcher.values), Set(definition.candidateNames))
            if definition.policy == .referenceOnly {
                XCTAssertEqual(rule.maximumDepth, 0)
                XCTAssertEqual(rule.minimumBytes, 0)
                XCTAssertEqual(rule.action, .revealOnly)
                XCTAssertFalse(rule.allowsManualSelection)
            }
        }

        for definition in CleanupCoverageCatalog.regenerableCacheDefinitions {
            let rule = try XCTUnwrap(ruleByID[definition.id])
            XCTAssertEqual(rule.ownerDisplayName, definition.ownerDisplayName)
            XCTAssertEqual(rule.root.path, definition.rootPath)
            XCTAssertEqual(
                Set(rule.include.nameMatcher.values),
                Set(definition.candidateNames)
            )
            XCTAssertEqual(rule.risk, .safe)
            XCTAssertEqual(rule.recommendation, .optional)
            XCTAssertEqual(rule.defaultSelection, .unselected)
            XCTAssertEqual(rule.executionEligibility, .eligible)
            XCTAssertEqual(rule.measurementRequirement, .complete)
            XCTAssertEqual(rule.action, .moveToTrash)
            XCTAssertTrue(rule.allowsManualSelection)
        }

        for definition in CleanupCoverageCatalog.readOnlyDefinitions {
            let rule = try XCTUnwrap(ruleByID[definition.id])
            XCTAssertEqual(rule.ownerDisplayName, definition.ownerDisplayName)
            XCTAssertEqual(rule.root.path, definition.rootPath)
            XCTAssertEqual(rule.risk, .reviewOnly)
            XCTAssertEqual(rule.recommendation, .advisoryOnly)
            XCTAssertEqual(rule.defaultSelection, .forbidden)
            XCTAssertEqual(rule.executionEligibility, .advisoryOnly)
            XCTAssertEqual(rule.action, .revealOnly)
            XCTAssertFalse(rule.allowsManualSelection)
        }

        let mailLibrary = try XCTUnwrap(ruleByID["mail.library-attachments"])
        XCTAssertEqual(mailLibrary.effectiveCandidateScope, .descendantAggregate)
        XCTAssertEqual(mailLibrary.include.nameMatcher.values, ["Attachments"])
        XCTAssertEqual(mailLibrary.action, .revealOnly)
        XCTAssertFalse(mailLibrary.allowsManualSelection)

        let downloads = try XCTUnwrap(ruleByID["downloads.large-items"])
        XCTAssertEqual(downloads.root.path, "Downloads")
        XCTAssertEqual(downloads.action, .moveToTrashAfterReview)
        XCTAssertEqual(downloads.recommendation, .notRecommended)

        let installers = try XCTUnwrap(ruleByID["downloads.installers"])
        XCTAssertEqual(installers.include.extensions, ["dmg", "pkg", "xip"])
        XCTAssertEqual(installers.recommendation, .optional)
        XCTAssertEqual(installers.defaultSelection, .unselected)
        XCTAssertEqual(installers.action, .moveToTrashAfterReview)

        for ruleID in [
            "personal.pictures-library",
            "user-data.wechat",
            "user-data.chrome",
            "user-data.codex-sessions",
            "user-data.ego-lite",
            "user-data.crossover",
        ] {
            let rule = try XCTUnwrap(ruleByID[ruleID])
            XCTAssertEqual(rule.risk, .reviewOnly)
            XCTAssertEqual(rule.recommendation, .advisoryOnly)
            XCTAssertEqual(rule.defaultSelection, .forbidden)
            XCTAssertEqual(rule.executionEligibility, .advisoryOnly)
            XCTAssertEqual(rule.action, .revealOnly)
            XCTAssertFalse(rule.allowsManualSelection)
        }

        let creativeApps = try XCTUnwrap(ruleByID["applications.large-creative-apps"])
        XCTAssertFalse(creativeApps.effectiveRequiresDuplicateBundleIdentifier)
        XCTAssertEqual(creativeApps.effectiveIncludedBundleIdentifiers, [
            "com.apple.FinalCutApp",
            "com.apple.iMovieApp",
            "com.apple.motionappApp",
            "com.apple.mobilelogic",
        ])

        XCTAssertTrue(rules.allSatisfy {
            [
                .moveToTrash,
                .moveToTrashAfterReview,
                .moveToTrashAfterProtectedReview,
                .revealOnly,
            ].contains($0.action)
        })
    }

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
        let chromeRule = try XCTUnwrap(
            CleanupCoverageCatalog.regenerableCacheDefinitions
                .first { $0.id == "browser-cache.google-chrome" }?
                .cleanupRule
        )
        let genericRule = makeRule(
            id: "system.user-caches",
            root: "Library/Caches",
            minimumBytes: 1_024 * 1_024,
            risk: .reviewOnly,
            recommendation: .advisoryOnly,
            defaultSelection: .forbidden,
            executionEligibility: .advisoryOnly,
            measurementRequirement: .bestEffort,
            allowsManualSelection: false,
            action: .revealOnly
        )

        let session = try await scan(
            home: home,
            ruleSet: makeRuleSet(rules: [chromeRule, genericRule])
        )
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(session.candidates.count, 1)
        XCTAssertEqual(candidate.ruleID, chromeRule.id)
        XCTAssertEqual(candidate.subcategoryTitle, CleanupRuleCopy.title(for: chromeRule))
        XCTAssertEqual(candidate.requiredClosedBundleIDs, ["com.google.Chrome"])
        XCTAssertEqual(candidate.defaultSelection, .unselected)
        XCTAssertEqual(candidate.selectionEligibility, .selectable)
        XCTAssertEqual(
            CleanupRecommendationDisplayPolicy.level(for: candidate),
            .optional
        )
        XCTAssertGreaterThanOrEqual(candidate.estimatedSizeBytes, 2 * 1_024 * 1_024)
    }

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

        XCTAssertEqual(candidate.recommendation.level, .optional)
        XCTAssertTrue(candidate.measurementCompleteness.isLowerBound)
        XCTAssertEqual(candidate.selectionEligibility, .unavailable)
        XCTAssertEqual(
            CleanupRecommendationDisplayPolicy.level(for: candidate),
            .advisoryOnly
        )
        XCTAssertEqual(
            CleanupRecommendationDisplayPolicy.level(
                for: [candidate],
                fallback: .optional
            ),
            .advisoryOnly
        )
    }

    func testMailAttachmentDiscoveryAggregatesOnlyMatchedDescendants() async throws {
        let home = try makeFixtureHome()
        let mailRoot = home.appendingPathComponent("Library/Mail", isDirectory: true)
        try write(
            bytes: 8_192,
            to: mailRoot.appendingPathComponent(
                "V10/account/Inbox.mbox/Data/1/Attachments/invoice.pdf"
            )
        )
        try write(
            bytes: 4_096,
            to: mailRoot.appendingPathComponent(
                "V10/account/Sent.mbox/Data/2/Attachments/photo.jpg"
            )
        )
        try write(
            bytes: 32_768,
            to: mailRoot.appendingPathComponent(
                "V10/account/Inbox.mbox/Data/1/Messages/database.emlx"
            )
        )

        let rule = CleanupCoverageCatalog.mailLibraryAttachmentsRule
        let session = try await scan(
            home: home,
            ruleSet: makeRuleSet(rules: [rule])
        )
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(session.candidates.count, 1)
        XCTAssertEqual(candidate.ruleID, rule.id)
        XCTAssertEqual(candidate.sourceURL.standardizedFileURL, mailRoot.standardizedFileURL)
        XCTAssertGreaterThanOrEqual(candidate.estimatedSizeBytes, 12_288)
        XCTAssertLessThan(candidate.estimatedSizeBytes, 32_768)
        XCTAssertEqual(candidate.action, .revealOnly)
        XCTAssertFalse(candidate.isManuallySelectable)
        XCTAssertTrue(candidate.recommendation.evidenceCodes.contains(
            "read-only-descendant-aggregate"
        ))
        XCTAssertTrue(candidate.recommendation.evidenceCodes.contains(
            "matched-descendant-count:2"
        ))
    }

    func testMailAttachmentAggregateBecomesLowerBoundWhenTraversalSkipsSymlink() async throws {
        let home = try makeFixtureHome()
        let mailRoot = home.appendingPathComponent("Library/Mail", isDirectory: true)
        try write(
            bytes: 4_096,
            to: mailRoot.appendingPathComponent(
                "V10/account/Inbox.mbox/Data/Attachments/invoice.pdf"
            )
        )
        let outside = home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let linkedDirectory = mailRoot.appendingPathComponent(
            "V10/account/LinkedData",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: outside
        )

        let session = try await scan(
            home: home,
            ruleSet: makeRuleSet(rules: [
                CleanupCoverageCatalog.mailLibraryAttachmentsRule,
            ])
        )
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertTrue(candidate.measurementCompleteness.isLowerBound)
        XCTAssertEqual(candidate.selectionEligibility, .unavailable)
        XCTAssertEqual(session.outcome, .partial)
        XCTAssertTrue(session.issues.contains {
            $0.kind == .symbolicLinkSkipped
                && $0.path == linkedDirectory.standardizedFileURL.path
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

        XCTAssertEqual(candidate.sourceURL.standardizedFileURL, cacheRoot.standardizedFileURL)
        XCTAssertEqual(candidate.allowedRootURL.standardizedFileURL, home.standardizedFileURL)
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
        XCTAssertEqual(plan.items.map(\.sourceURL.standardizedFileURL), [cacheRoot.standardizedFileURL])
    }

    func testDeepStorageAnalyzerCandidateCountsDataBeyondEightLevels() async throws {
        let home = try makeFixtureHome()
        let candidateRoot = home.appendingPathComponent("Library/Application Support/DeepApp")
        let nested = (1...12).reduce(candidateRoot) { partial, depth in
            partial.appendingPathComponent("level-\(depth)")
        }
        try write(bytes: 8_192, to: nested.appendingPathComponent("payload.bin"))
        let rule = makeRule(
            id: "user-data.application-support",
            root: "Library/Application Support",
            categoryID: "user-data",
            categoryTitleKey: "cleanup.category.userData",
            titleKey: "cleanup.rule.applicationSupport.title",
            maximumDepth: 32,
            risk: .reviewOnly,
            recommendation: .advisoryOnly,
            allowsManualSelection: false,
            action: .revealOnly,
            reasonKey: "cleanup.reason.manualAppData"
        )

        let session = try await scan(home: home, ruleSet: makeRuleSet(rules: [rule]))
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(candidate.sourceURL.standardizedFileURL, candidateRoot.standardizedFileURL)
        XCTAssertGreaterThanOrEqual(candidate.estimatedSizeBytes, 8_192)
        XCTAssertEqual(candidate.risk, .reviewOnly)
        XCTAssertEqual(candidate.selectionEligibility, .reviewRequired)
    }

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
        let informationalRule = CleanupRule(
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
        let protectedRule = CleanupRule(
            id: "applications.duplicate-installed-apps",
            selectionPolicyVersion: 1,
            categoryID: "applications",
            categoryTitleKey: "cleanup.category.applications",
            titleKey: "cleanup.rule.duplicateInstalledApps.title",
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
            reasonKey: "cleanup.rule.duplicateInstalledApps.reason"
        )

        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FixtureReadOnlyFileSystem(),
            ruleSet: makeRuleSet(rules: [informationalRule, protectedRule]),
            applicationsURL: applications
        )
        let session = try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home)
        ) { _ in }
        let protected = session.candidates.filter { $0.risk == .protected }
        let informational = session.candidates.filter { $0.risk == .informational }

        XCTAssertEqual(Set(protected.map { $0.sourceURL.lastPathComponent }), [
            "Example.app", "Example Beta.app",
        ])
        XCTAssertEqual(Set(informational.map { $0.sourceURL.lastPathComponent }), [
            "Different.app", "Setapp",
        ])
        XCTAssertTrue(protected.allSatisfy {
            $0.action == .moveToTrashAfterProtectedReview
                && $0.isSelectable
                && $0.selectionEligibility == .selectableWithProtectedReview
                && $0.recommendation.evidenceCodes.contains("duplicate-bundle-identifier")
                && $0.recommendation.evidenceCodes.contains(where: {
                    $0.hasPrefix("duplicate-bundle-group:")
                })
        })
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.isEmpty)

        var selection = CleanupSelection()
        let selected = try XCTUnwrap(protected.first)
        selection.setCandidate(selected.id, selected: true, in: session)
        XCTAssertTrue(selection.isExplicitlySelected(selected.id))
    }

    func testApprovedCreativeApplicationsUseBundleIdentifierAllowlist() async throws {
        let home = try makeFixtureHome()
        let applications = home.appendingPathComponent("Applications")
        try makeApplicationBundle(
            at: applications.appendingPathComponent("Allowed.app"),
            bundleIdentifier: "com.example.allowed"
        )
        try makeApplicationBundle(
            at: applications.appendingPathComponent("Allowed Name.app"),
            bundleIdentifier: "com.example.other"
        )
        let informationalRule = CleanupRule(
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
        let protectedRule = CleanupRule(
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
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FixtureReadOnlyFileSystem(),
            ruleSet: makeRuleSet(rules: [informationalRule, protectedRule]),
            applicationsURL: applications
        )
        let session = try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home)
        ) { _ in }

        XCTAssertEqual(
            session.candidates(with: .protected).map { $0.sourceURL.lastPathComponent },
            ["Allowed.app"]
        )
        let protected = try XCTUnwrap(session.candidates(with: .protected).first)
        XCTAssertTrue(protected.isSelectable)
        XCTAssertTrue(protected.recommendation.evidenceCodes.contains(
            "application-bundle-identifier:com.example.allowed"
        ))
        XCTAssertEqual(
            Set(session.candidates(with: .informational).map { $0.sourceURL.lastPathComponent }),
            ["Allowed Name.app"]
        )
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

        XCTAssertEqual(
            session.outcome,
            .complete,
            "issues=\(session.issues.map { "\($0.kind.rawValue):\($0.path ?? "")" }) permissions=\(session.permissions.map { "\($0.status.rawValue):\($0.path)" })"
        )
        XCTAssertEqual(session.categories.count, 1)
        XCTAssertEqual(session.categories.first?.subcategories.count, 2)
        XCTAssertEqual(session.candidates.count, 2)
        XCTAssertEqual(Set(session.candidates.map(\.risk)), [.safe, .reviewOnly])
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
        try write(bytes: 8_192, to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
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

    func testLowerBoundMeasurementIsVisibleButCannotEnterPlan() async throws {
        let home = try makeFixtureHome()
        let candidateRoot = home.appendingPathComponent("Library/Caches/candidate")
        try write(bytes: 4_096, to: candidateRoot.appendingPathComponent("payload.bin"))
        let outside = home.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).bin")
        try write(bytes: 8_192, to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
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
        XCTAssertFalse(candidate.isSelectable)
        XCTAssertEqual(session.metrics.lowerBoundMeasurementCandidateCount, 1)
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.isEmpty)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: session,
            selection: CleanupSelection(selectedCandidateIDs: [candidate.id]),
            activeRules: rules,
            disposition: .trash
        )) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
        }
    }

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
        let candidate = try XCTUnwrap(session.candidates.first)

        XCTAssertEqual(
            candidate.measurementCompleteness,
            .failed(reason: .permissionDenied)
        )
        XCTAssertFalse(candidate.isSelectable)
        XCTAssertEqual(session.metrics.failedMeasurementCandidateCount, 1)
        XCTAssertEqual(session.metrics.permissionFailureCount, 1)
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
        try write(bytes: 6_144, to: home.appendingPathComponent("Library/Logs/review.log"))
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

    func testLegacyReviewOnlyCandidateCannotEnterSelectionEvenWithForgedID() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Logs/review.log"))
        let session = try await scan(home: home, ruleSet: makeRuleSet(rules: [
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
        let candidate = try XCTUnwrap(session.candidates.first)
        var selection = CleanupSelection(selectedCandidateIDs: [candidate.id])

        XCTAssertTrue(selection.selectedCandidates(in: session).isEmpty)
        selection.setCandidate(candidate.id, selected: true, in: session)
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
        let store = await MainActor.run {
            ScanStore(
                cleanupFeatureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
                cleanupScanOperation: { _, _ in session }
            )
        }

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

    func testScanOnlyFeatureFlagDisablesAllLegacyTrashEntryPoints() async throws {
        let home = try makeFixtureHome()
        try write(bytes: 1_024, to: home.appendingPathComponent("Library/Caches/a.bin"))
        let session = try await scan(home: home, ruleSet: makeRuleSet())
        let store = await MainActor.run {
            ScanStore(
                cleanupFeatureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
                cleanupScanOperation: { _, _ in session }
            )
        }

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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerCleanupFixture-\(UUID().uuidString)")
        let home = root.appendingPathComponent("Home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Logs"),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
        case .moveToTrashAfterProtectedReview: .eligibleAfterProtectedReview
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
