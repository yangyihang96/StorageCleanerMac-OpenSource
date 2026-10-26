import Foundation
import XCTest
@testable import StorageCleanerMac

/// D19: every item listed on the Smart Scan, Safe Cleanup and Developer pages
/// can be selected and removed. Items that cannot be acted on are not listed.
final class CleanupJunkActionableTests: XCTestCase {
    func testEveryBundledRuleCategoryProducesOnlyActionableResults() async throws {
        let fixture = try makeFixtureHome()
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.map(lowered)
        )
        for rule in rules.rules {
            try makeMatchingFixture(for: rule, home: fixture.home, applications: fixture.applications)
        }

        // Variants that used to make an item view-only.
        let outside = fixture.root.appendingPathComponent("outside-target.bin")
        try write(bytes: 8_192, to: outside)
        let symlinkHost = fixture.home.appendingPathComponent("Library/Caches/fixture-system.user-caches")
        try FileManager.default.createSymbolicLink(
            at: symlinkHost.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )
        let deep = (1...34).reduce(fixture.home.appendingPathComponent(".npm/_npx")) {
            $0.appendingPathComponent("level-\($1)")
        }
        try write(bytes: 4_096, to: deep.appendingPathComponent("payload.bin"))
        let unreadable = fixture.home.appendingPathComponent("Library/Logs/fixture-system.user-logs/private")
        try write(bytes: 4_096, to: unreadable.appendingPathComponent("secret.log"))
        let blockedRoot = fixture.home.appendingPathComponent("Library/Caches/fixture-blocked")
        try write(bytes: 4_096, to: blockedRoot.appendingPathComponent("payload.bin"))
        // Variant 5: a folder the user excluded inside a row.
        let excludedRow = fixture.home.appendingPathComponent("Library/Caches/fixture-excluded")
        try write(bytes: 4_096, to: excludedRow.appendingPathComponent("payload.bin"))
        let excludedInside = excludedRow.appendingPathComponent("keep")
        try write(bytes: 4_096, to: excludedInside.appendingPathComponent("keep.bin"))

        let fileSystem = ActionableFixtureFileSystem(
            deniedChildrenPaths: [unreadable.path, blockedRoot.path]
        )
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: fileSystem,
            ruleSet: rules,
            applicationsURL: fixture.applications
        )
        let session = try await scanner.scan(
            request: CleanupScanRequest(
                userHomeURL: fixture.home,
                excludedURLs: [excludedInside]
            )
        ) { _ in }

        XCTAssertFalse(session.candidates.isEmpty)
        let unselectable = session.candidates.filter { !$0.isSelectable }
        XCTAssertEqual(
            session.candidates.filter(\.isSelectable).count,
            session.candidates.count,
            "Listed but not actionable: \(unselectable.map { "\($0.ruleID):\($0.sourceURL.lastPathComponent):\($0.selectionEligibility.rawValue)" })"
        )
        // D181: the volume Trash rule needs a mounted drive, so it is scanned
        // on a fixture drive seen as /Volumes/Fake; its rows must be
        // actionable too (was the home fixture alone).
        let drive = try VolumeTrashFakeDrive(test: self, uid: getuid())
        try drive.write(bytes: 8_192, to: "fixture-volume-trash.bin")
        let (volumeSession, _) = try await drive.scan()
        XCTAssertFalse(volumeSession.candidates.isEmpty)
        XCTAssertTrue(volumeSession.candidates.allSatisfy(\.isSelectable))
        let listedRuleIDs = Set(session.candidates.map(\.ruleID))
            .union(volumeSession.candidates.map(\.ruleID))
        XCTAssertEqual(
            Set(rules.rules.map(\.id)).subtracting(listedRuleIDs),
            [],
            "Every bundled rule must produce an actionable fixture result"
        )

        let lowerBoundNames = Set(session.candidates
            .filter { $0.measurementCompleteness.isLowerBound }
            .map { $0.sourceURL.lastPathComponent })
        XCTAssertTrue(lowerBoundNames.isSuperset(of: [
            "fixture-system.user-caches",
            "_npx",
            "fixture-system.user-logs",
        ]), "lower-bound items: \(lowerBoundNames)")

        XCTAssertFalse(session.candidates.contains {
            $0.sourceURL.lastPathComponent == "fixture-blocked"
        })
        XCTAssertTrue(session.issues.contains {
            $0.kind == .candidateNotActionable
                && $0.path == blockedRoot.standardizedFileURL.path
        }, "The unreadable root is counted as safely skipped")
        XCTAssertGreaterThanOrEqual(session.metrics.notActionableCandidateCount, 1)
        XCTAssertEqual(session.outcome, .partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        // Variant 5: cleanup always skips a row holding an excluded path, so
        // the row is not listed; it is counted with its reason.
        XCTAssertFalse(session.candidates.contains {
            $0.sourceURL.lastPathComponent == "fixture-excluded"
        })
        XCTAssertTrue(session.issues.contains {
            $0.kind == .candidateContainsExcludedPath
                && $0.path == PathSafety.lexicalPath(excludedRow.path)
        })
        XCTAssertEqual(session.metrics.excludedPathCandidateCount, 1)
        XCTAssertGreaterThanOrEqual(session.metrics.notActionableCandidateCount, 2)

        // P2-9: every listed item is planned, passes the cleanup check with the
        // same exclusions, and is moved or deleted in the fixture. Duplicate
        // app copies are left out here only because their plan accepts the
        // real /Applications folder alone.
        let targets = session.candidates.filter {
            $0.ruleID != "applications.duplicate-installed-apps"
        }
        var selection = CleanupSelection()
        selection.setCandidates(targets.map(\.id), selected: true, in: session)
        XCTAssertEqual(selection.selectedCandidateIDs, Set(targets.map(\.id)))
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(Set(plan.items.map(\.candidateID)), Set(targets.map(\.id)))
        let executor = SafeCleanupExecutor(
            metadataReader: fileSystem,
            mover: TrashFolderMover(trashURL: fixture.home.appendingPathComponent(".Trash")),
            runningApplicationChecker: FixedRunningChecker(running: []),
            coordinator: HeavyWorkCoordinator()
        )
        let preflight = await executor.preflight(
            plan: plan,
            context: executionContext(
                session: session,
                rules: rules,
                home: fixture.home,
                excluded: [excludedInside]
            )
        )
        let notReady = zip(plan.items, preflight.items).filter { $0.1.status != .ready }.map {
            "\($0.0.ruleID):\($0.0.sourceURL.lastPathComponent):\($0.1.status)"
        }
        XCTAssertEqual(notReady, [], "Listed but refused by the cleanup check")
        let report = await executor.execute(
            plan: plan,
            context: executionContext(
                session: session,
                rules: rules,
                home: fixture.home,
                approved: Set(plan.items.map(\.id)),
                excluded: [excludedInside]
            )
        ) { _ in }
        let notRemoved = report.items.filter {
            switch $0.outcome {
            case .moved, .deleted: false
            case .skipped, .failed, .notProcessed: true
            }
        }.map { "\($0.ruleID):\(URL(fileURLWithPath: $0.sourcePath).lastPathComponent):\($0.outcome)" }
        XCTAssertEqual(notRemoved, [], "Listed but not removed")
        XCTAssertEqual(
            report.summary.movedItemCount + (report.summary.deletedItemCount ?? 0),
            plan.items.count
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "Link targets stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: excludedInside.path), "Excluded paths stay")
    }

    /// P1-1: an item that holds a path the user excluded would always be
    /// skipped by cleanup, so the scan does not list it and counts it with its
    /// reason. A Trash entry that holds one is not frozen for deletion.
    func testItemsHoldingUserExclusionsAreCountedNotListed() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        let caches = home.appendingPathComponent("Library/Caches")
        let idleRow = caches.appendingPathComponent("com.example.idle")
        try write(bytes: 8_192, to: idleRow.appendingPathComponent("data.bin"))
        let cacheKeep = idleRow.appendingPathComponent("keep")
        try write(bytes: 4_096, to: cacheKeep.appendingPathComponent("keep.bin"))
        try write(bytes: 8_192, to: caches.appendingPathComponent("com.example.plain/data.bin"))
        let npx = home.appendingPathComponent(".npm/_npx")
        try write(bytes: 8_192, to: npx.appendingPathComponent("abc/index.js"))
        let npxKeep = npx.appendingPathComponent("keep")
        try write(bytes: 4_096, to: npxKeep.appendingPathComponent("state.bin"))
        let trash = home.appendingPathComponent(".Trash")
        try write(bytes: 8_192, to: trash.appendingPathComponent("normal.bin"))
        let trashFolder = trash.appendingPathComponent("Folder")
        try write(bytes: 4_096, to: trashFolder.appendingPathComponent("other.bin"))
        let trashKeep = trashFolder.appendingPathComponent("keep")
        try write(bytes: 4_096, to: trashKeep.appendingPathComponent("keep.bin"))
        let excluded = [cacheKeep, npxKeep, trashKeep]
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let wanted: Set<String> = ["system.user-caches", "developer.npx-cache", "trash.user-trash"]
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.filter { wanted.contains($0.id) }.map(lowered)
        )

        let session = try await scan(
            home: home,
            applications: fixture.applications,
            rules: rules,
            environment: FixedApplicationEnvironment(snapshot: CleanupApplicationSnapshot(
                installedBundleIdentifiers: ["com.example.idle", "com.example.plain"]
            )),
            excluded: excluded
        )

        let names = Set(session.candidates.map(\.sourceURL.lastPathComponent))
        XCTAssertFalse(names.contains("com.example.idle"), "\(names)")
        XCTAssertFalse(names.contains("_npx"), "\(names)")
        XCTAssertTrue(names.contains("com.example.plain"), "\(names)")
        let trashCandidate = try XCTUnwrap(session.candidates.first { $0.action == .emptyTrash })
        XCTAssertEqual(
            trashCandidate.permanentDeletionEntries?.map {
                URL(fileURLWithPath: $0.standardizedPath).lastPathComponent
            },
            ["normal.bin"]
        )
        XCTAssertEqual(
            Set(session.issues.filter { $0.kind == .candidateContainsExcludedPath }.compactMap(\.path)),
            Set([idleRow, npx, trashFolder].map { PathSafety.lexicalPath($0.path) })
        )
        XCTAssertEqual(session.metrics.excludedPathCandidateCount, 3)
        XCTAssertEqual(session.metrics.notActionableCandidateCount, 3)
        XCTAssertEqual(session.outcome, .partial)
        let unverifiedReason = DeveloperCleanupAgePolicy.reason(
            for: try XCTUnwrap(DeveloperCleanupAgePolicy.decision(
                for: try XCTUnwrap(rules.rules.first { $0.id == "developer.npx-cache" }),
                latestModificationTimeNanoseconds: 1,
                measurementCompleteness: .lowerBound(reason: .permissionDenied),
                referenceDate: Date(),
                thresholdDays: 30
            )),
            latestModificationTimeNanoseconds: 1,
            referenceDate: Date(),
            thresholdDays: 30
        )
        XCTAssertFalse(
            unverifiedReason.contains("排除") || unverifiedReason.contains("exclude"),
            "Excluded folders no longer reach the unverified band: \(unverifiedReason)"
        )

        // What is listed passes the cleanup check with the same exclusions.
        var selection = CleanupSelection()
        selection.setCandidates(session.candidates.map(\.id), selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        let preflight = await SafeCleanupExecutor(
            metadataReader: ActionableFixtureFileSystem(),
            runningApplicationChecker: FixedRunningChecker(running: []),
            coordinator: HeavyWorkCoordinator()
        ).preflight(
            plan: plan,
            context: executionContext(session: session, rules: rules, home: home, excluded: excluded)
        )
        XCTAssertEqual(preflight.items.map(\.status), Array(repeating: .ready, count: plan.items.count))
    }

    /// P2-7: IDE local history (JetBrains keeps it in
    /// ~/Library/Caches/JetBrains/<product>/LocalHistory) is the user's own
    /// edit history, so a row holding it is counted, not listed. WorkBuddy
    /// audit records are not logs to clean.
    func testLocalHistoryAndAuditRecordsAreNotListed() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        let caches = home.appendingPathComponent("Library/Caches")
        let jetBrains = caches.appendingPathComponent("JetBrains")
        let product = jetBrains.appendingPathComponent("IntelliJIdea2026.2")
        try write(bytes: 8_192, to: product.appendingPathComponent("caches/content.dat"))
        let localHistory = product.appendingPathComponent("LocalHistory")
        try write(bytes: 4_096, to: localHistory.appendingPathComponent("changes.storageData"))
        let tool = caches.appendingPathComponent("com.example.tool")
        try write(bytes: 8_192, to: tool.appendingPathComponent("index/data.bin"))
        try write(bytes: 4_096, to: tool.appendingPathComponent("local-history/edits.bin"))
        try write(bytes: 8_192, to: caches.appendingPathComponent("com.example.plain/data.bin"))
        let workBuddy = home.appendingPathComponent(".workbuddy")
        try write(bytes: 4_096, to: workBuddy.appendingPathComponent("logs/app.log"))
        let auditLog = workBuddy.appendingPathComponent("audit-log")
        try write(bytes: 4_096, to: auditLog.appendingPathComponent("2026-10-01.jsonl"))
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let wanted: Set<String> = ["system.user-caches", "developer.workbuddy-logs"]
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.filter { wanted.contains($0.id) }.map(lowered)
        )

        let session = try await scan(home: home, applications: fixture.applications, rules: rules)

        let listed = Set(session.candidates.map { "\($0.ruleID):\($0.sourceURL.lastPathComponent)" })
        XCTAssertEqual(listed, [
            "system.user-caches:com.example.plain",
            "developer.workbuddy-logs:logs",
        ])
        XCTAssertEqual(
            Set(session.issues.filter { $0.kind == .candidateContainsProtectedData }.compactMap(\.path)),
            Set([jetBrains, tool].map { PathSafety.lexicalPath($0.path) })
        )
        XCTAssertEqual(session.metrics.protectedDataCandidateCount, 2)
        XCTAssertEqual(session.metrics.notActionableCandidateCount, 2)
        XCTAssertEqual(session.outcome, .partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localHistory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: auditLog.path))
    }

    /// P2-8: a row whose folder cannot be listed has no known size, so the
    /// size threshold cannot drop it; it is counted as not listed, the same
    /// way as below the threshold.
    func testUnlistableRowsAreCountedEvenBelowTheSizeThreshold() async throws {
        let fixture = try makeFixtureHome()
        let blocked = fixture.home.appendingPathComponent("Library/Caches/com.example.blocked")
        try write(bytes: 4_096, to: blocked.appendingPathComponent("payload.bin"))
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.filter { $0.id == "system.user-caches" }
        )
        XCTAssertGreaterThan(try XCTUnwrap(rules.rules.first).minimumBytes, 4_096)

        let session = try await scan(
            home: fixture.home,
            applications: fixture.applications,
            rules: rules,
            fileSystem: ActionableFixtureFileSystem(deniedChildrenPaths: [blocked.path])
        )

        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertEqual(session.metrics.notActionableCandidateCount, 1)
        XCTAssertTrue(session.issues.contains {
            $0.kind == .candidateNotActionable && $0.path == PathSafety.lexicalPath(blocked.path)
        })
        XCTAssertEqual(session.outcome, .partial)
    }

    /// D19/D24/D25: personal data, agent sessions and app bundles stay out.
    /// D183 supersedes D24 only for explicitly reviewed attachment folders.
    func testRemovedPersonalDataAndApplicationBundlesAreNotListed() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        for path in [
            "Pictures/Photos Library.photoslibrary/database/photo.db",
            "Library/Containers/com.tencent.xinWeChat/Data/chat.db",
            "Library/Application Support/Google/Chrome/Default/History",
            ".codex/sessions/2026/session.jsonl",
            ".codex/.tmp/runtime.lock",
            ".claude/projects/project/session.jsonl",
            "Library/Application Support/Citro Labs/ego lite/model.bin",
            "Library/Application Support/CrossOver/Bottles/game/drive_c/file.bin",
            "Library/Mail/V10/account/Inbox.mbox/Data/1/Attachments/invoice.pdf",
        ] {
            try write(bytes: 2 * 1_024 * 1_024, to: home.appendingPathComponent(path))
        }
        try makeApplicationBundle(
            at: fixture.applications.appendingPathComponent("Final Cut Pro.app"),
            bundleIdentifier: "com.apple.FinalCutApp",
            payloadBytes: 2 * 1_024 * 1_024
        )
        try makeApplicationBundle(
            at: fixture.applications.appendingPathComponent("Large.app"),
            bundleIdentifier: "com.example.large",
            payloadBytes: 2 * 1_024 * 1_024
        )
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.map(lowered)
        )

        let session = try await scan(home: home, applications: fixture.applications, rules: rules)

        // D183＋旧值：session.candidates.isEmpty。其他个人数据仍不能列出。
        XCTAssertEqual(session.candidates.map { PathSafety.normalizedPath($0.sourceURL.path) }, [PathSafety.normalizedPath(
            home.appendingPathComponent("Library/Mail/V10/account/Inbox.mbox/Data/1/Attachments").path)])
        XCTAssertTrue(session.candidates.allSatisfy { $0.ruleID == "mail.library-attachment-folders" && !$0.isPreselectedByDefault })
    }

    /// D47 (replaces D22's owner rule): every green cache and log row is
    /// preselected unless its app is running; an unidentified owner or recent
    /// writes no longer hold a row back. Show the running state; recheck it
    /// before cleanup.
    func testPreselectionSkipsOnlyRowsWhoseAppIsRunning() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        let caches = home.appendingPathComponent("Library/Caches")
        let logs = home.appendingPathComponent("Library/Logs")
        for name in ["com.example.running", "com.example.idle", "com.example.idle.Helper", "SomeTool"] {
            try write(bytes: 4_096, to: caches.appendingPathComponent("\(name)/cache.bin"))
        }
        // Catalog rules keep their 1 MiB threshold.
        let catalogBytes = 1_024 * 1_024 + 64 * 1_024
        try write(bytes: catalogBytes, to: caches.appendingPathComponent("Google/Chrome/cache.bin"))
        try write(bytes: 4_096, to: logs.appendingPathComponent("com.example.idle/app.log"))
        try write(bytes: 4_096, to: logs.appendingPathComponent("DiagnosticReports/crash.ips"))
        try write(bytes: catalogBytes, to: logs.appendingPathComponent("com.apple.diagnosticextensionsd/report.log"))
        // D47: a log written in the last 7 days is preselected as well.
        // DiagnosticReports stays freshly written.
        let quiet = Date().addingTimeInterval(-10 * 86_400)
        try setModificationDate(quiet, under: logs.appendingPathComponent("com.example.idle"))
        try setModificationDate(quiet, under: logs.appendingPathComponent("com.apple.diagnosticextensionsd"))
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let wanted: Set<String> = [
            "system.user-caches", "system.user-logs",
            "browser-cache.google-chrome", "system-log.diagnostics",
        ]
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.filter { wanted.contains($0.id) }.map(lowered)
        )
        let environment = FixedApplicationEnvironment(snapshot: CleanupApplicationSnapshot(
            runningBundleIdentifiers: ["com.example.running", "com.google.Chrome"],
            installedBundleIdentifiers: ["com.example.running", "com.example.idle"]
        ))

        let session = try await scan(
            home: home,
            applications: fixture.applications,
            rules: rules,
            environment: environment
        )
        func candidate(_ ruleID: String, _ name: String) throws -> ScanCandidate {
            try XCTUnwrap(session.candidates.first {
                $0.ruleID == ruleID && $0.sourceURL.lastPathComponent == name
            }, "\(ruleID) \(name)")
        }
        let running = try candidate("system.user-caches", "com.example.running")
        let idle = try candidate("system.user-caches", "com.example.idle")
        let helper = try candidate("system.user-caches", "com.example.idle.Helper")
        let unknown = try candidate("system.user-caches", "SomeTool")
        let chrome = try candidate("browser-cache.google-chrome", "Chrome")
        let idleLog = try candidate("system.user-logs", "com.example.idle")
        let unknownLog = try candidate("system.user-logs", "DiagnosticReports")
        let diagnostics = try candidate("system-log.diagnostics", "com.apple.diagnosticextensionsd")

        XCTAssertEqual(running.ownerResolution, .inferredFromName)
        XCTAssertTrue(running.isOwnerRunning)
        XCTAssertEqual(helper.ownerBundleIdentifiers, ["com.example.idle"])
        XCTAssertEqual(unknown.ownerResolution, .unresolved)
        XCTAssertEqual(CleanupRecommendationDisplayPolicy.level(for: unknown), .recommended)
        XCTAssertEqual(chrome.ownerResolution, .declared)
        XCTAssertTrue(chrome.isOwnerRunning)
        XCTAssertEqual(diagnostics.ownerResolution, .noApplication)
        XCTAssertTrue(session.candidates.allSatisfy(\.isSelectable))

        // D47: the unidentified cache and the recently written log are
        // preselected; only the rows whose app is running are not.
        let expected: Set<ScanCandidateID> = [
            idle.id, helper.id, unknown.id, idleLog.id, unknownLog.id, diagnostics.id,
        ]
        XCTAssertEqual(CleanupSelection.defaults(in: session).selectedCandidateIDs, expected)
        XCTAssertEqual(CleanupSelection.recommended(in: session).selectedCandidateIDs, expected)
        XCTAssertFalse(expected.contains(running.id))
        XCTAssertFalse(expected.contains(chrome.id))
        // DiagnosticReports has no owning app; it was written within the
        // last 7 days and the row says so.
        XCTAssertEqual(unknownLog.ownerResolution, .noApplication)
        XCTAssertEqual(unknownLog.logWriteState, .recent)
        XCTAssertEqual(
            CleanupCandidateRowHint.ownerStatus(for: unknownLog)?.text,
            L10n.text("最近 7 天内仍有写入", "Written within the last 7 days")
        )
        XCTAssertEqual(
            CleanupCandidateRowHint.ownerStatus(for: unknown)?.text,
            L10n.text("未识别所属应用，清理前无法确认它是否在运行",
                      "Its app could not be identified, so whether it is running cannot be checked")
        )

        // Once the apps quit, refreshing the running state restores preselection.
        let refreshed = session.updatingRunningOwners(from: CleanupApplicationSnapshot())
        XCTAssertEqual(
            CleanupSelection.defaults(in: refreshed).selectedCandidateIDs,
            expected.union([running.id, chrome.id])
        )

        // The running owner found from the row name is checked again before
        // anything moves.
        var selection = CleanupSelection()
        selection.setCandidate(running.id, selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(plan.items.first?.inferredOwnerBundleIDs, ["com.example.running"])
        let context = executionContext(session: session, rules: rules, home: home)
        let runningReport = await SafeCleanupExecutor(
            metadataReader: ActionableFixtureFileSystem(),
            runningApplicationChecker: FixedRunningChecker(running: ["com.example.running"]),
            coordinator: HeavyWorkCoordinator()
        ).preflight(plan: plan, context: context)
        XCTAssertEqual(runningReport.items.map(\.status), [.skipped(.relatedAppStillRunning)])
        let closedReport = await SafeCleanupExecutor(
            metadataReader: ActionableFixtureFileSystem(),
            runningApplicationChecker: FixedRunningChecker(running: []),
            coordinator: HeavyWorkCoordinator()
        ).preflight(plan: plan, context: context)
        XCTAssertEqual(closedReport.items.map(\.status), [.ready])
    }

    /// D47 supplement (review P1-1b): a row whose app cannot be identified
    /// has no app to check right before cleanup, so it is checked for writes
    /// instead, the way developer files are: anything written after the scan
    /// skips it, and the result names the reason. A row whose app is known
    /// keeps the running-app check.
    func testUnidentifiedOwnerRowsWrittenAfterTheScanAreSkipped() async throws {
        let fixture = try makeFixtureHome()
        let caches = fixture.home.appendingPathComponent("Library/Caches")
        let logs = fixture.home.appendingPathComponent("Library/Logs")
        try write(bytes: 4_096, to: caches.appendingPathComponent("SomeTool/cache.bin"))
        try write(bytes: 4_096, to: caches.appendingPathComponent("com.example.idle/cache.bin"))
        try write(bytes: 4_096, to: logs.appendingPathComponent("SomeTool/app.log"))
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.filter { ["system.user-caches", "system.user-logs"].contains($0.id) }.map(lowered)
        )
        let environment = FixedApplicationEnvironment(snapshot: CleanupApplicationSnapshot(
            runningBundleIdentifiers: [],
            installedBundleIdentifiers: ["com.example.idle"]
        ))
        let session = try await scan(
            home: fixture.home,
            applications: fixture.applications,
            rules: rules,
            environment: environment
        )
        func candidate(_ ruleID: String, _ name: String) throws -> ScanCandidate {
            try XCTUnwrap(session.candidates.first {
                $0.ruleID == ruleID && $0.sourceURL.lastPathComponent == name
            }, "\(ruleID) \(name)")
        }
        let unknownCache = try candidate("system.user-caches", "SomeTool")
        let unknownLog = try candidate("system.user-logs", "SomeTool")
        let knownCache = try candidate("system.user-caches", "com.example.idle")
        XCTAssertEqual(unknownCache.ownerResolution, .unresolved)
        XCTAssertEqual(unknownLog.ownerResolution, .unresolved)
        XCTAssertEqual(knownCache.ownerResolution, .inferredFromName)
        let selection = CleanupSelection.defaults(in: session)
        for row in [unknownCache, unknownLog, knownCache] {
            XCTAssertTrue(selection.selectedCandidateIDs.contains(row.id), row.sourceURL.path)
        }
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        let context = executionContext(session: session, rules: rules, home: fixture.home)
        let executor = SafeCleanupExecutor(
            metadataReader: ActionableFixtureFileSystem(),
            runningApplicationChecker: FixedRunningChecker(running: []),
            coordinator: HeavyWorkCoordinator()
        )
        func status(_ report: CleanPreflightReport, _ row: ScanCandidate) throws -> CleanPreflightItemStatus {
            let item = try XCTUnwrap(plan.items.first { $0.candidateID == row.id })
            return try XCTUnwrap(report.items.first { $0.planItemID == item.id }).status
        }

        let quiet = await executor.preflight(plan: plan, context: context)
        for row in [unknownCache, unknownLog, knownCache] {
            XCTAssertEqual(try status(quiet, row), .ready, row.sourceURL.path)
        }

        try write(bytes: 128, to: caches.appendingPathComponent("SomeTool/new.bin"))
        try write(bytes: 128, to: logs.appendingPathComponent("SomeTool/new.log"))
        try write(bytes: 128, to: caches.appendingPathComponent("com.example.idle/new.bin"))
        let written = await executor.preflight(plan: plan, context: context)
        XCTAssertEqual(try status(written, unknownCache), .skipped(.candidateBecameActive))
        XCTAssertEqual(try status(written, unknownLog), .skipped(.candidateBecameActive))
        XCTAssertEqual(try status(written, knownCache), .ready, "Its app is checked instead")
        // The confirmation and completion pages name the reason.
        XCTAssertEqual(
            CleanSkipReasonPresentation.title(.candidateBecameActive),
            L10n.text("扫描后仍有新写入或变化，可能正在使用；已跳过，如需清理请重新扫描",
                      "Written or changed after the scan and may be in use; skipped. Scan again to clean it")
        )
    }

    /// D47 supplement (review P1-1a): caches of developer tools that live in
    /// `~/Library/Caches` are graded by developer activity (D22) like other
    /// developer caches, so a freshly written one is red and not preselected;
    /// only one unchanged for over a year is green. They are no longer green
    /// user-cache rows with an unidentified owner.
    func testDeveloperToolCachesInLibraryCachesAreGradedByActivity() async throws {
        let fixture = try makeFixtureHome()
        let caches = fixture.home.appendingPathComponent("Library/Caches")
        // Catalog rules keep their 1 MiB threshold.
        let catalogBytes = 1_024 * 1_024 + 64 * 1_024
        let fresh = ["go-build", "ms-playwright", "ms-playwright-go", "pnpm", "claude-cli-nodejs"]
        for name in fresh {
            try write(bytes: catalogBytes, to: caches.appendingPathComponent("\(name)/payload.bin"))
        }
        try write(bytes: catalogBytes, to: caches.appendingPathComponent("Yarn/payload.bin"))
        try setModificationDate(Date().addingTimeInterval(-400 * 86_400), under: caches.appendingPathComponent("Yarn"))
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.map(lowered)
        )

        let session = try await scan(home: fixture.home, applications: fixture.applications, rules: rules)

        func row(_ name: String) throws -> ScanCandidate {
            try XCTUnwrap(session.candidates.first { $0.sourceURL.lastPathComponent == name }, name)
        }
        for name in fresh {
            let candidate = try row(name)
            XCTAssertEqual(candidate.categoryID, "developer", name)
            XCTAssertNotEqual(candidate.ruleID, "system.user-caches", name)
            XCTAssertNotEqual(candidate.ownerResolution, .unresolved, name)
            XCTAssertEqual(candidate.risk, .protected, "Written just now, so red: \(name)")
            XCTAssertFalse(candidate.isPreselectedByDefault, name)
        }
        let yarn = try row("Yarn")
        XCTAssertEqual(yarn.categoryID, "developer")
        XCTAssertEqual(yarn.risk, .safe, "Unchanged for over a year, so green")
        XCTAssertTrue(yarn.isPreselectedByDefault)
        // Each folder is listed once, by its developer rule only.
        XCTAssertEqual(session.candidates.filter { (fresh + ["Yarn"]).contains($0.sourceURL.lastPathComponent) }.count,
                       fresh.count + 1)
    }

    /// Re-review P1-A: Deno keeps `Deno.openKv()` databases and localStorage
    /// in `deno/location_data`, and Poetry keeps project virtual environments
    /// in `pypoetry/virtualenvs`. A cache row holding either is the user's
    /// data, so it is counted, not listed, even when unchanged for over a year.
    func testDeveloperToolCachesHoldingUserDataAreNotListed() async throws {
        let fixture = try makeFixtureHome()
        let caches = fixture.home.appendingPathComponent("Library/Caches")
        let catalogBytes = 1_024 * 1_024 + 64 * 1_024
        let deno = caches.appendingPathComponent("deno")
        try write(bytes: catalogBytes, to: deno.appendingPathComponent("deps/https/example.com/mod.js"))
        let kv = deno.appendingPathComponent("location_data/0a1b2c/kv.sqlite3")
        try write(bytes: 4_096, to: kv)
        let poetry = caches.appendingPathComponent("pypoetry")
        try write(bytes: catalogBytes, to: poetry.appendingPathComponent("cache/repositories/pypi/index.bin"))
        let venv = poetry.appendingPathComponent("virtualenvs/project-AbC123-py3.13/pyvenv.cfg")
        try write(bytes: 4_096, to: venv)
        let pnpm = caches.appendingPathComponent("pnpm")
        try write(bytes: catalogBytes, to: pnpm.appendingPathComponent("metadata/registry.bin"))
        let old = Date().addingTimeInterval(-400 * 86_400)
        for folder in [deno, poetry, pnpm] {
            try setModificationDate(old, under: folder)
        }
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.map(lowered)
        )

        let session = try await scan(home: fixture.home, applications: fixture.applications, rules: rules)

        let listedNames = Set(session.candidates.map(\.sourceURL.lastPathComponent))
        XCTAssertFalse(listedNames.contains("deno"))
        XCTAssertFalse(listedNames.contains("pypoetry"))
        let pnpmRow = try XCTUnwrap(session.candidates.first { $0.sourceURL.lastPathComponent == "pnpm" })
        XCTAssertEqual(pnpmRow.risk, .safe, "A developer cache without user data is still green when idle")
        XCTAssertTrue(pnpmRow.isPreselectedByDefault)
        let protectedPaths = Set(session.issues.filter { $0.kind == .candidateContainsProtectedData }.compactMap(\.path))
        XCTAssertTrue(protectedPaths.contains(PathSafety.lexicalPath(deno.path)))
        XCTAssertTrue(protectedPaths.contains(PathSafety.lexicalPath(poetry.path)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kv.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: venv.path))
    }

    /// D19: developer caches with skipped links keep their activity grade;
    /// partly unreadable ones are red but selectable. The cleanup recheck
    /// reads the folder exactly as the scan did.
    func testLowerBoundDeveloperCachesStaySelectableAndPreflightMatchesTheScan() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        let npx = home.appendingPathComponent(".npm/_npx")
        let payload = npx.appendingPathComponent("abc/node_modules/tool/index.js")
        try write(bytes: 4_096, to: payload)
        let outside = fixture.root.appendingPathComponent("outside-target.js")
        try write(bytes: 4_096, to: outside)
        try FileManager.default.createDirectory(
            at: npx.appendingPathComponent("abc/node_modules/.bin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: npx.appendingPathComponent("abc/node_modules/.bin/tool"),
            withDestinationURL: outside
        )
        let old = Date().addingTimeInterval(-400 * 86_400)
        try setModificationDate(old, under: npx)
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.filter { $0.id == "developer.npx-cache" }.map(lowered)
        )

        let linked = try await scan(home: home, applications: fixture.applications, rules: rules)
        let green = try XCTUnwrap(linked.candidates.first)
        XCTAssertEqual(green.measurementCompleteness, .lowerBound(reason: .symbolicLinkSkipped))
        XCTAssertEqual(green.risk, .safe)
        XCTAssertTrue(CleanupSelection.defaults(in: linked).selectedCandidateIDs.contains(green.id))
        let greenPlan = try CleanPlanBuilder.makePlan(
            session: linked,
            selection: CleanupSelection(selectedCandidateIDs: [green.id]),
            activeRules: rules,
            disposition: .trash
        )
        let greenReady = await SafeCleanupExecutor(
            metadataReader: ActionableFixtureFileSystem(),
            coordinator: HeavyWorkCoordinator()
        ).preflight(plan: greenPlan, context: executionContext(session: linked, rules: rules, home: home))
        XCTAssertEqual(greenReady.items.map(\.status), [.ready])

        let privateFolder = npx.appendingPathComponent("private")
        try write(bytes: 4_096, to: privateFolder.appendingPathComponent("state.bin"))
        try setModificationDate(old, under: npx)
        let denying = ActionableFixtureFileSystem(deniedChildrenPaths: [privateFolder.path])
        let partial = try await scan(
            home: home,
            applications: fixture.applications,
            rules: rules,
            fileSystem: denying
        )
        let red = try XCTUnwrap(partial.candidates.first)
        XCTAssertEqual(red.measurementCompleteness, .lowerBound(reason: .permissionDenied))
        XCTAssertEqual(red.risk, .protected)
        XCTAssertEqual(red.selectionEligibility, .selectableWithProtectedReview)
        XCTAssertTrue(red.recommendation.evidenceCodes.contains("developer-age-band:activityUnverified"))
        XCTAssertFalse(CleanupSelection.defaults(in: partial).selectedCandidateIDs.contains(red.id))
        var selection = CleanupSelection()
        selection.setCandidate(red.id, selected: true, in: partial)
        let redPlan = try CleanPlanBuilder.makePlan(
            session: partial,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        let executor = SafeCleanupExecutor(metadataReader: denying, coordinator: HeavyWorkCoordinator())
        let redContext = executionContext(session: partial, rules: rules, home: home)
        let redReady = await executor.preflight(plan: redPlan, context: redContext)
        XCTAssertEqual(redReady.items.map(\.status), [.ready])

        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: payload.path)
        let changed = await executor.preflight(plan: redPlan, context: redContext)
        XCTAssertEqual(changed.items.map(\.status), [.skipped(.candidateBecameActive)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    /// D23: emptying the Trash is one item that deletes only the top-level
    /// entries frozen at scan time, each re-verified by identity. Links that
    /// point outside the Trash, and anything added later, are left alone.
    func testEmptyTrashDeletesOnlyFrozenEntriesInsideTheTrash() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        let trash = home.appendingPathComponent(".Trash")
        let outsideFile = fixture.root.appendingPathComponent("outside-keep.bin")
        try write(bytes: 4_096, to: outsideFile)
        try write(bytes: 8_192, to: trash.appendingPathComponent("replaced.bin"))
        try write(bytes: 8_192, to: trash.appendingPathComponent("Folder/inner.bin"))
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("Folder/inner-link"),
            withDestinationURL: outsideFile
        )
        try FileManager.default.createSymbolicLink(
            atPath: trash.appendingPathComponent("inside-link").path,
            withDestinationPath: "replaced.bin"
        )
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("outside-link"),
            withDestinationURL: outsideFile
        )
        try write(bytes: 4_096, to: home.appendingPathComponent("Library/Caches/com.example.cache/cache.bin"))
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules
                .filter { ["trash.user-trash", "system.user-caches"].contains($0.id) }
                .map(lowered)
        )
        let progressRecorder = ProgressRecorder()
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: ActionableFixtureFileSystem(),
            ruleSet: rules,
            applicationsURL: fixture.applications
        )
        let session = try await scanner.scan(
            request: CleanupScanRequest(userHomeURL: home)
        ) { await progressRecorder.append($0) }

        let trashCandidate = try XCTUnwrap(session.candidates.first { $0.action == .emptyTrash })
        let cache = try XCTUnwrap(session.candidates.first { $0.ruleID == "system.user-caches" })
        XCTAssertEqual(trashCandidate.selectionEligibility, .selectableWithPermanentDeletionReview)
        XCTAssertEqual(trashCandidate.measurementCompleteness, .lowerBound(reason: .symbolicLinkSkipped))
        XCTAssertEqual(
            Set(trashCandidate.permanentDeletionEntries?.map {
                URL(fileURLWithPath: $0.standardizedPath).lastPathComponent
            } ?? []),
            ["replaced.bin", "Folder", "inside-link"]
        )
        XCTAssertFalse(CleanupSelection.defaults(in: session).selectedCandidateIDs.contains(trashCandidate.id))
        XCTAssertFalse(CleanupSelection.recommended(in: session).selectedCandidateIDs.contains(trashCandidate.id))
        let finalProgress = await progressRecorder.last()
        XCTAssertEqual(finalProgress?.discoveredItemCount, 1, "Trash is counted on its own")
        XCTAssertEqual(finalProgress?.discoveredBytes, cache.estimatedSizeBytes)

        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: session,
            selection: CleanupSelection(selectedCandidateIDs: [trashCandidate.id]),
            activeRules: rules,
            disposition: .trash
        ), "Emptying the Trash requires an explicit choice") {
            XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
        }
        var selection = CleanupSelection()
        selection.setCandidates([trashCandidate.id, cache.id], selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(plan.permanentDeletionItems.count, 3)
        XCTAssertEqual(plan.trashMoveItems.map(\.sourceURL.lastPathComponent), ["com.example.cache"])
        XCTAssertEqual(plan.protectedItems.count, 3, "Deletion needs the two red confirmations")
        XCTAssertTrue(plan.permanentDeletionItems.allSatisfy {
            $0.allowedRootURL.standardizedFileURL == trash.standardizedFileURL
                && $0.explicitUserSelection
        })

        // After the scan: one entry is replaced, a new item arrives.
        try FileManager.default.removeItem(at: trash.appendingPathComponent("replaced.bin"))
        try write(bytes: 1_024, to: trash.appendingPathComponent("replaced.bin"))
        try write(bytes: 1_024, to: trash.appendingPathComponent("added-after-scan.bin"))

        let mover = TrashFolderMover(trashURL: trash)
        let executor = SafeCleanupExecutor(
            metadataReader: ActionableFixtureFileSystem(),
            mover: mover,
            runningApplicationChecker: FixedRunningChecker(running: []),
            coordinator: HeavyWorkCoordinator()
        )
        let context = executionContext(
            session: session,
            rules: rules,
            home: home,
            approved: Set(plan.items.map(\.id))
        )
        let report = await executor.execute(plan: plan, context: context) { _ in }

        let outcomes = Dictionary(uniqueKeysWithValues: report.items.map {
            (URL(fileURLWithPath: $0.sourcePath).lastPathComponent, $0.outcome)
        })
        XCTAssertEqual(outcomes["replaced.bin"], .skipped(.identityChanged))
        if case .deleted = outcomes["Folder"] {} else { XCTFail("Folder: \(String(describing: outcomes["Folder"]))") }
        if case .deleted = outcomes["inside-link"] {} else { XCTFail("link: \(String(describing: outcomes["inside-link"]))") }
        if case .moved = outcomes["com.example.cache"] {} else { XCTFail("cache: \(String(describing: outcomes["com.example.cache"]))") }
        XCTAssertEqual(report.summary.deletedItemCount, 2)
        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertGreaterThan(report.summary.permanentlyFreedBytes, 0)
        XCTAssertEqual(report.restorableReceipts.map(\.originalPath), [cache.snapshot.standardizedPath])
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: trash.appendingPathComponent("Folder").path))
        XCTAssertTrue(fileManager.fileExists(atPath: trash.appendingPathComponent("replaced.bin").path))
        XCTAssertTrue(fileManager.fileExists(atPath: trash.appendingPathComponent("added-after-scan.bin").path))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFile.path), "Link targets are never followed")
        XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(
            atPath: trash.appendingPathComponent("outside-link").path
        ), "A link pointing outside the Trash is left alone")
        let movedName = await mover.movedNames()
        XCTAssertEqual(movedName, ["com.example.cache"])
        XCTAssertTrue(fileManager.fileExists(
            atPath: trash.appendingPathComponent("com.example.cache").path
        ), "This cleanup's own Trash items are not deleted")

        // After the cleanup the moved cache and the deleted entries leave the
        // results; the Trash item keeps only the entry that was skipped.
        let refreshed = session.removingCleanedItems(report: report, plan: plan)
        XCTAssertEqual(refreshed.id, session.id)
        XCTAssertEqual(refreshed.candidates.map(\.ruleID), ["trash.user-trash"])
        let remainingTrash = try XCTUnwrap(refreshed.candidates.first)
        XCTAssertEqual(
            remainingTrash.permanentDeletionEntries?.map {
                URL(fileURLWithPath: $0.standardizedPath).lastPathComponent
            },
            ["replaced.bin"]
        )
        XCTAssertEqual(refreshed.metrics.candidateCount, 1)
        XCTAssertLessThan(remainingTrash.estimatedSizeBytes, trashCandidate.estimatedSizeBytes)
    }

    /// D23: if the Trash folder is swapped for a link after the scan, or a
    /// deletion fails part-way, nothing outside the Trash is touched and the
    /// failed entry is never treated as moved or restorable.
    func testEmptyTrashStopsWhenTheTrashIsReplacedAndRecordsFailedDeletions() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        let trash = home.appendingPathComponent(".Trash")
        try write(bytes: 8_192, to: trash.appendingPathComponent("old.bin"))
        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "trash.fixture",
            rules: [CleanupCoverageCatalog.userTrashRule]
        )
        let session = try await scan(home: home, applications: fixture.applications, rules: rules)
        let trashCandidate = try XCTUnwrap(session.candidates.first)
        var selection = CleanupSelection()
        selection.setCandidate(trashCandidate.id, selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(plan.permanentDeletionItems.count, 1)

        // A failing deletion: recorded as unconfirmed, never as moved.
        let failing = SafeCleanupExecutor(
            metadataReader: ActionableFixtureFileSystem(),
            deleter: ThrowingDeleter(),
            coordinator: HeavyWorkCoordinator()
        )
        let failedReport = await failing.execute(
            plan: plan,
            context: executionContext(
                session: session,
                rules: rules,
                home: home,
                approved: Set(plan.items.map(\.id))
            )
        ) { _ in }
        guard case let .failed(failure) = failedReport.items.first?.outcome else {
            return XCTFail("\(String(describing: failedReport.items.first?.outcome))")
        }
        XCTAssertEqual(failure.code, .deletionOutcomeUnknown)
        XCTAssertEqual(failedReport.summary.movedItemCount, 0)
        XCTAssertEqual(failedReport.summary.deletedItemCount, 0)
        XCTAssertTrue(failedReport.restorableReceipts.isEmpty)
        XCTAssertEqual(OperationResultPresentation(report: failedReport).state, .needsVerification)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("old.bin").path))

        // The Trash folder is replaced by a link to another folder.
        let elsewhere = fixture.root.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: trash, to: fixture.root.appendingPathComponent("Moved Trash"))
        try write(bytes: 8_192, to: elsewhere.appendingPathComponent("old.bin"))
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: elsewhere)
        let preflight = await SafeCleanupExecutor(
            metadataReader: ActionableFixtureFileSystem(),
            coordinator: HeavyWorkCoordinator()
        ).preflight(plan: plan, context: executionContext(session: session, rules: rules, home: home))
        XCTAssertEqual(preflight.items.map(\.status), [.skipped(.pathOutsideAllowedRoot)])
        XCTAssertFalse(preflight.isConfirmable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("old.bin").path))
    }

    /// P2-5: a cloud file in the Trash that is not downloaded is skipped and
    /// counted when the entries are frozen. It never makes the plan fail.
    func testCloudPlaceholdersInTheTrashAreSkippedNotFatal() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        let trash = home.appendingPathComponent(".Trash")
        try write(bytes: 8_192, to: trash.appendingPathComponent("normal.bin"))
        let cloud = trash.appendingPathComponent("cloud.bin")
        try write(bytes: 8_192, to: cloud)
        try write(bytes: 8_192, to: home.appendingPathComponent("Library/Caches/com.example.cache/cache.bin"))
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules
                .filter { ["trash.user-trash", "system.user-caches"].contains($0.id) }
                .map(lowered)
        )
        let fileSystem = ActionableFixtureFileSystem(placeholderPaths: [cloud.path])

        let session = try await scan(
            home: home,
            applications: fixture.applications,
            rules: rules,
            fileSystem: fileSystem
        )

        let trashCandidate = try XCTUnwrap(session.candidates.first { $0.action == .emptyTrash })
        let cache = try XCTUnwrap(session.candidates.first { $0.ruleID == "system.user-caches" })
        XCTAssertEqual(
            trashCandidate.permanentDeletionEntries?.map {
                URL(fileURLWithPath: $0.standardizedPath).lastPathComponent
            },
            ["normal.bin"]
        )
        XCTAssertEqual(session.metrics.cloudSkippedCount, 1)
        XCTAssertTrue(session.issues.contains {
            $0.kind == .cloudPlaceholderSkipped && $0.path == PathSafety.lexicalPath(cloud.path)
        })
        var selection = CleanupSelection()
        selection.setCandidates([trashCandidate.id, cache.id], selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(plan.permanentDeletionItems.map(\.sourceURL.lastPathComponent), ["normal.bin"])

        // A placeholder among frozen entries (for example from a session made
        // before this check) is left out of the plan instead of failing it.
        let placeholder = try fileSystem.snapshot(at: cloud)
        XCTAssertTrue(placeholder.isCloudPlaceholder)
        let withPlaceholder = session.mappingCandidates { candidate in
            guard candidate.action == .emptyTrash else { return candidate }
            var updated = candidate
            updated.permanentDeletionEntries = (candidate.permanentDeletionEntries ?? []) + [placeholder]
            return updated
        }
        let tolerant = try CleanPlanBuilder.makePlan(
            session: withPlaceholder,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(tolerant.permanentDeletionItems.map(\.sourceURL.lastPathComponent), ["normal.bin"])
        XCTAssertEqual(tolerant.trashMoveItems.map(\.sourceURL.lastPathComponent), ["com.example.cache"])
    }

    /// D23: without permission to read the Trash, the scan says so instead of
    /// reporting it as empty.
    func testUnreadableTrashIsReportedNotEmpty() async throws {
        let fixture = try makeFixtureHome()
        let trash = fixture.home.appendingPathComponent(".Trash")
        try write(bytes: 4_096, to: trash.appendingPathComponent("item.bin"))
        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "trash.fixture",
            rules: [CleanupCoverageCatalog.userTrashRule]
        )
        let session = try await scan(
            home: fixture.home,
            applications: fixture.applications,
            rules: rules,
            fileSystem: ActionableFixtureFileSystem(deniedChildrenPaths: [trash.path])
        )

        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertEqual(
            session.permissions.first { $0.ruleID == "trash.user-trash" }?.status,
            .permissionDenied
        )
        XCTAssertEqual(session.outcome, .partial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("item.bin").path))
    }

    func testValidatorKeepsEmptyTrashAndContainerRulesNarrow() throws {
        let trash = CleanupCoverageCatalog.userTrashRule
        let elsewhere = CleanupRule(
            id: trash.id,
            selectionPolicyVersion: trash.selectionPolicyVersion,
            categoryID: trash.categoryID,
            categoryTitleKey: trash.categoryTitleKey,
            titleKey: trash.titleKey,
            root: CleanupRuleRoot(kind: .homeRelative, path: "Downloads"),
            candidateScope: .root,
            maximumDepth: trash.maximumDepth,
            minimumAgeDays: 0,
            minimumBytes: 1,
            include: trash.include,
            exclude: trash.exclude,
            cloudPolicy: trash.cloudPolicy,
            risk: .protected,
            recommendation: .notRecommended,
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .emptyTrash,
            requiredClosedBundleIDs: [],
            reasonKey: trash.reasonKey
        )
        XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleSet(
            schemaVersion: 2, rulesVersion: "x", rules: [elsewhere]
        )))

        let bundled = try CleanupRuleSetLoader.loadBundled()
        let userCaches = try XCTUnwrap(bundled.rules.first { $0.id == "system.user-caches" })
        let withoutHomebrewExclusion = CleanupRule(
            id: userCaches.id,
            selectionPolicyVersion: userCaches.selectionPolicyVersion,
            categoryID: userCaches.categoryID,
            categoryTitleKey: userCaches.categoryTitleKey,
            titleKey: userCaches.titleKey,
            root: userCaches.root,
            maximumDepth: userCaches.maximumDepth,
            minimumAgeDays: 0,
            minimumBytes: userCaches.minimumBytes,
            include: userCaches.include,
            exclude: CleanupRuleExclusion(
                relativePrefixes: userCaches.exclude.relativePrefixes.filter { $0 != "Homebrew" },
                extensions: [],
                namePrefixes: userCaches.exclude.namePrefixes
            ),
            cloudPolicy: userCaches.cloudPolicy,
            risk: userCaches.risk,
            recommendation: userCaches.recommendation,
            defaultSelection: userCaches.defaultSelection,
            executionEligibility: userCaches.executionEligibility,
            measurementRequirement: userCaches.measurementRequirement,
            allowsManualSelection: userCaches.allowsManualSelection,
            action: userCaches.action,
            requiredClosedBundleIDs: [],
            reasonKey: userCaches.reasonKey,
            ownerInference: userCaches.ownerInference
        )
        XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules.map { $0.id == userCaches.id ? withoutHomebrewExclusion : $0 }
        )), "The Homebrew cache would be listed twice")
    }

    func testOwnerInferenceUsesReverseDomainNamesOnly() {
        XCTAssertEqual(
            CleanupOwnerInferencePolicy.bundleIdentifierCandidates(forName: "com.vendor.app.Helper"),
            ["com.vendor.app.Helper", "com.vendor.app"]
        )
        XCTAssertEqual(CleanupOwnerInferencePolicy.bundleIdentifierCandidates(forName: "install.log"), [])
        XCTAssertEqual(CleanupOwnerInferencePolicy.bundleIdentifierCandidates(forName: "Google"), [])
        XCTAssertEqual(CleanupOwnerInferencePolicy.bundleIdentifierCandidates(forName: "fsck_apfs.v2.log"), [])
        XCTAssertEqual(
            CleanupOwnerInferencePolicy.owner(
                forName: "com.vendor.app.ShipIt",
                installedBundleIdentifiers: ["com.vendor.app"]
            ),
            "com.vendor.app"
        )
    }

    func testDuplicateRetentionPrefersRunningThenNewestCopy() {
        func copy(_ path: String, modified: Int64, running: Bool) -> ScanCandidate {
            var candidate = ScanCandidate(
                id: ScanCandidateID(),
                sessionID: ScanSessionID(),
                ruleID: "applications.duplicate-installed-apps",
                ruleSelectionPolicyVersion: 1,
                categoryID: "applications",
                categoryTitle: "Apps",
                subcategoryTitle: "Duplicates",
                sourceURL: URL(fileURLWithPath: path),
                allowedRootURL: URL(fileURLWithPath: "/Applications"),
                snapshot: FileSnapshot(
                    identity: FileIdentity(deviceID: 1, inode: UInt64(modified), entryKind: .directory, creationTimeNanoseconds: 1),
                    standardizedPath: path,
                    volumeIdentifier: "v",
                    logicalSizeBytes: 1,
                    allocatedSizeBytes: 1,
                    modificationTimeNanoseconds: modified,
                    isWritableVolume: true,
                    isCloudItem: false,
                    isCloudPlaceholder: false,
                    hasSymbolicLinkComponent: false
                ),
                risk: .protected,
                recommendation: CleanupRecommendation(level: .notRecommended, reasonCode: "r", evidenceCodes: ["duplicate-bundle-group:g"]),
                defaultSelection: .unselected,
                executionEligibility: .eligibleAfterProtectedReview,
                measurementCompleteness: .complete,
                isManuallySelectable: true,
                action: .moveToTrashAfterProtectedReview,
                requiredClosedBundleIDs: [],
                reason: "r"
            )
            candidate.ownerResolution = .applicationBundle
            candidate.ownerBundleIdentifiers = ["com.example.app"]
            candidate.runningOwnerBundleIdentifiers = running ? ["com.example.app"] : []
            return candidate
        }
        let old = copy("/Applications/App old.app", modified: 10, running: false)
        let new = copy("/Applications/App.app", modified: 20, running: false)
        let runningOld = copy("/Applications/App 2.app", modified: 5, running: true)
        XCTAssertEqual(DuplicateApplicationRetentionPolicy.keeper(among: [old, new])?.id, new.id)
        XCTAssertEqual(DuplicateApplicationRetentionPolicy.keeper(among: [old, new, runningOld])?.id, runningOld.id)
    }

    // MARK: - Fixtures

    private func scan(
        home: URL,
        applications: URL,
        rules: CleanupRuleSet,
        environment: any CleanupApplicationEnvironment = NoCleanupApplicationEnvironment(),
        fileSystem: any ReadOnlyFileSystem = ActionableFixtureFileSystem(),
        excluded: [URL] = []
    ) async throws -> ScanSession {
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: fileSystem,
            ruleSet: rules,
            applicationsURL: applications,
            applicationEnvironment: environment
        )
        return try await scanner.scan(request: CleanupScanRequest(
            userHomeURL: home,
            excludedURLs: excluded
        )) { _ in }
    }

    private func executionContext(
        session: ScanSession,
        rules: CleanupRuleSet,
        home: URL,
        approved: Set<UUID>? = nil,
        excluded: [URL] = []
    ) -> CleanupExecutionContext {
        CleanupExecutionContext(
            featureConfiguration: .productDefault,
            activeSessionID: session.id,
            activeRules: rules,
            userHomeURL: home,
            excludedURLs: excluded,
            approvedPlanItemIDs: approved
        )
    }

    private func setModificationDate(_ date: Date, under root: URL) throws {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: [])
        var urls = [root]
        while let url = enumerator?.nextObject() as? URL { urls.append(url) }
        for url in urls.reversed() {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else { continue }
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private struct FixtureHome {
        let root: URL
        let home: URL
        let applications: URL
    }

    private func makeFixtureHome() throws -> FixtureHome {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerJunkActionable-\(UUID().uuidString)")
        let home = root.appendingPathComponent("Home")
        let applications = root.appendingPathComponent("Applications")
        for directory in [
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Logs"),
            applications,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return FixtureHome(root: root, home: home, applications: applications)
    }

    /// Coverage-catalog rules are validated against their catalog thresholds,
    /// so only bundled-JSON and developer-catalog thresholds are lowered. A
    /// zero threshold also keeps a root whose size cannot be measured, so it
    /// reaches the D19 actionability filter instead of the size filter.
    private func lowered(_ rule: CleanupRule) -> CleanupRule {
        let coverageIDs = Set(CleanupCoverageCatalog.cleanupRules.map(\.id))
        guard !coverageIDs.contains(rule.id) else { return rule }
        return CleanupRule(
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

    private func payloadBytes(for rule: CleanupRule) -> Int {
        Int(max(rule.minimumBytes, 4_096)) + 64 * 1_024
    }

    private func makeMatchingFixture(for rule: CleanupRule, home: URL, applications: URL) throws {
        let bytes = payloadBytes(for: rule)
        if rule.root.kind == .applicationsDirectory {
            let bundleIdentifier = rule.effectiveIncludedBundleIdentifiers.sorted().first
                ?? "com.example.duplicate-\(rule.id)"
            let copies = rule.effectiveRequiresDuplicateBundleIdentifier ? 2 : 1
            for index in 0..<copies {
                try makeApplicationBundle(
                    at: applications.appendingPathComponent("Fixture \(rule.id) \(index).app"),
                    bundleIdentifier: bundleIdentifier,
                    payloadBytes: bytes
                )
            }
            return
        }
        let root = home.appendingPathComponent(rule.root.path, isDirectory: true)
        switch rule.effectiveCandidateScope {
        case .root:
            try write(bytes: bytes, to: root.appendingPathComponent("fixture-\(rule.id).bin"))
        case .descendantAggregate:
            let name = rule.include.nameMatcher.values.first ?? "Attachments"
            try write(bytes: bytes, to: root.appendingPathComponent("V10/fixture/\(name)/payload.bin"))
        case .namedDescendantDirectories:
            let name = rule.include.nameMatcher.values[0]
            try write(bytes: bytes, to: root.appendingPathComponent("V10/fixture/INBOX.mbox/U/Data/1/\(name)/payload.bin"))
        case .immediateChildren:
            let matcher = rule.include.nameMatcher
            let name: String
            switch matcher.mode {
            case .exact: name = matcher.values[0]
            case .prefix: name = matcher.values[0] + ".fixture"
            case .any: name = "fixture-\(rule.id)"
            }
            if let fileExtension = rule.include.extensions.sorted().first,
               rule.include.entryKinds.contains(.regularFile) {
                try write(bytes: bytes, to: root.appendingPathComponent("\(name).\(fileExtension)"))
            } else {
                try write(bytes: bytes, to: root.appendingPathComponent(name).appendingPathComponent("payload.bin"))
            }
        }
    }

    private func makeApplicationBundle(at url: URL, bundleIdentifier: String, payloadBytes: Int) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
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
        try write(bytes: payloadBytes, to: contents.appendingPathComponent("Resources/payload.bin"))
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }
}

/// Temporary fixtures live under `/var`, which is a symbolic link on macOS.
/// Ancestor links are therefore ignored; links inside the fixture are still
/// reported through the entry kind. Selected directories refuse listing to
/// model folders the app cannot read.
private struct ActionableFixtureFileSystem: ReadOnlyFileSystem {
    var deniedChildrenPaths: Set<String> = []
    /// Entries reported as cloud files that are not downloaded.
    var placeholderPaths: Set<String> = []

    func snapshot(at url: URL) throws -> FileSnapshot {
        let snapshot = try FoundationReadOnlyFileSystem().snapshot(at: url)
        let isPlaceholder = placeholderPaths.contains {
            PathSafety.lexicalPath($0) == PathSafety.lexicalPath(url.path)
        }
        return FileSnapshot(
            identity: snapshot.identity,
            standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier,
            logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume,
            isCloudItem: isPlaceholder || snapshot.isCloudItem,
            isCloudPlaceholder: isPlaceholder || snapshot.isCloudPlaceholder,
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

private struct FixedApplicationEnvironment: CleanupApplicationEnvironment {
    let snapshot: CleanupApplicationSnapshot

    func snapshot(checkingInstalled bundleIdentifiers: Set<String>) async -> CleanupApplicationSnapshot {
        var result = snapshot
        result.installedBundleIdentifiers = snapshot.installedBundleIdentifiers
            .intersection(bundleIdentifiers)
        return result
    }
}

private struct FixedRunningChecker: CleanupRunningApplicationChecking {
    let running: Set<String>

    func isRunning(bundleIdentifier: String) async -> Bool {
        running.contains(bundleIdentifier)
    }
}

/// Moves into the fixture's own `.Trash`, never the real one.
private actor TrashFolderMover: CleanupMoving {
    let trashURL: URL
    private var names = [String]()

    init(trashURL: URL) {
        self.trashURL = trashURL
    }

    func moveToTrash(_ url: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        var destination = trashURL.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Like the Finder, a name already in the Trash gets a new one.
            destination = trashURL.appendingPathComponent(UUID().uuidString + " " + url.lastPathComponent)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        names.append(url.lastPathComponent)
        return destination
    }

    func moveToQuarantine(_ url: URL, planID _: CleanPlanID, itemID _: UUID) async throws -> URL {
        throw CleanupMoveError.invalidResult
    }

    func movedNames() -> [String] { names }
}

private actor ProgressRecorder {
    private var snapshots = [CleanupScanProgress]()

    func append(_ progress: CleanupScanProgress) {
        snapshots.append(progress)
    }

    func last() -> CleanupScanProgress? { snapshots.last }
}

private struct ThrowingDeleter: CleanupPermanentDeleting {
    func removeTrashEntry(_: CleanupTrashEntryDeletion) async throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

extension CleanupJunkActionableTests {
    /// D101 G4-2: under a rule's root, a location no flow may touch is
    /// counted, not listed — here the integration identity's data among the
    /// user caches, and Screen Time's and File Provider's stores under a
    /// rule rooted at Application Support. The rules' other rows are listed.
    func testLocationsNoFlowMayTouchAreCountedNotListed() async throws {
        let fixture = try makeFixtureHome()
        let home = fixture.home
        let caches = home.appendingPathComponent("Library/Caches")
        let support = home.appendingPathComponent("Library/Application Support")
        for folder in [caches.appendingPathComponent("StorageCleanerIntegration-run"),
                       caches.appendingPathComponent("com.example.plain")]
            + ["Knowledge", "FileProvider", "com.example.vendor"].map(support.appendingPathComponent) {
            try write(bytes: 8_192, to: folder.appendingPathComponent("data.bin"))
        }
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let userCaches = lowered(try XCTUnwrap(bundled.rules.first { $0.id == "system.user-caches" }))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(userCaches)) as? [String: Any])
        object["id"] = "fixture.application-support"
        object["root"] = ["kind": "homeRelative", "path": "Library/Application Support"]
        // Application Support is not a safe root, so a rule there can only
        // be a reviewed one, as the bundled iStat Menus rule is.
        object["risk"] = "reviewOnly"
        object["recommendation"] = "optional"
        object["defaultSelection"] = "unselected"
        object["executionEligibility"] = "eligibleAfterReview"
        object["measurementRequirement"] = "complete"
        object["allowsManualSelection"] = true
        object["action"] = "moveToTrashAfterReview"
        let applicationSupport = try JSONDecoder().decode(
            CleanupRule.self, from: JSONSerialization.data(withJSONObject: object))
        let rules = CleanupRuleSet(schemaVersion: bundled.schemaVersion, rulesVersion: bundled.rulesVersion,
                                   rules: [userCaches, applicationSupport])

        let session = try await scan(home: home, applications: fixture.applications, rules: rules)

        XCTAssertEqual(Set(session.candidates.map { "\($0.ruleID):\($0.sourceURL.lastPathComponent)" }), [
            "system.user-caches:com.example.plain",
            "fixture.application-support:com.example.vendor",
        ])
        XCTAssertEqual(
            Set(session.issues.filter { $0.kind == .candidateContainsProtectedData }.compactMap(\.path)),
            Set([caches.appendingPathComponent("StorageCleanerIntegration-run"),
                 support.appendingPathComponent("Knowledge"),
                 support.appendingPathComponent("FileProvider")].map { PathSafety.lexicalPath($0.path) })
        )
        XCTAssertEqual(session.metrics.protectedDataCandidateCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("Knowledge").path))
    }
}
