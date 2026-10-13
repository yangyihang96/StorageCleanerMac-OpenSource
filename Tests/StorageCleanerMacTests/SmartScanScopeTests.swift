#if DEBUG
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SmartScanScopeTests: XCTestCase {
    func testEveryCombinationSeparatesCleanupSummaryAndReminderWithoutJunkHistory() async throws {
        try await assertSummaryCombinations(retainingJunkHistory: false)
    }

    func testEveryCombinationKeepsPreviousJunkNumbersWhileRemindersUseTheNewestScan() async throws {
        try await assertSummaryCombinations(retainingJunkHistory: true)
    }

    private func assertSummaryCombinations(retainingJunkHistory: Bool) async throws {
        for mask in 0..<8 {
            let defaults = TestPreferenceDomain.make(for: self)
            let oldDate = Date().addingTimeInterval(-14 * 24 * 60 * 60)
            let oldJunk = summaryEntry(date: oldDate, scopes: [.cleanupCandidates], greenBytes: 73_728, greenCount: 3)
            let previousReview = summaryEntry(date: oldDate.addingTimeInterval(60),
                scopes: [.filesToReview], greenBytes: 0, greenCount: 0)
            if retainingJunkHistory {
                ScanHistoryService.record(oldJunk, defaults: defaults)
                ScanHistoryService.record(previousReview, defaults: defaults)
            }
            let home = try TestFileSystem.makeOperationHome(for: self, purpose: "scope-summary")
            let scanner = ScopeRecordingScanner(rules: Self.rules, home: home)
            let health = ScopeRecordingHealthProbe()
            let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
                scanHistoryDefaults: defaults,
                cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
                smartScanHealthOperation: { await health.probe() },
                cleanupRuleSetLoader: { Self.rules }, cleanupUserHomeURL: home)
            store.refreshScanHistory()
            let scopes = selection(mask)
            for scope in SmartScanScope.allCases where !scopes.contains(scope) {
                store.toggleSmartScanScope(scope)
            }
            store.selectedFilter = .overview
            store.startScan()
            let session: ScanSession?
            if mask == 0 {
                XCTAssertFalse(store.isScanning)
                XCTAssertNil(store.cleanupScanSession)
                session = nil
            } else {
                session = try await finished(store)
            }

            // A later checkbox edit must not rewrite the completed coverage.
            store.toggleSmartScanScope(.cleanupCandidates)
            let hasJunk = scopes.contains(.cleanupCandidates)
            let expectedBytes: Int64? = hasJunk ? 8192 : (retainingJunkHistory ? oldJunk.greenBytes : nil)
            let expectedCount: Int? = hasJunk ? 2 : (retainingJunkHistory ? oldJunk.greenCount : nil)
            XCTAssertEqual(store.scanHistorySummary.latestCleanupEntry?.greenBytes, expectedBytes, "mask=\(mask)")
            XCTAssertEqual(store.scanHistorySummary.latestCleanupEntry?.greenCount, expectedCount, "mask=\(mask)")
            let panel = summaryPanel(store: store, defaults: defaults)
            let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
            defer { model.stop() }
            let source = MiniWindowCleanupSource(store: store)
            let opening = model.presentation(beforeStarting: source.current())
            XCTAssertEqual(opening.source, hasJunk ? .preparing : (retainingJunkHistory ? .history : .empty))
            model.start(source)
            let deadline = Date().addingTimeInterval(5)
            while model.isPreparing || !model.isInitialLayoutReady {
                guard Date() < deadline else { throw ScopeProbeError.didNotFinish }
                try await Task.sleep(for: .milliseconds(5))
            }
            let presentation = model.presentation
            XCTAssertEqual(presentation.source, hasJunk ? .session : (retainingJunkHistory ? .history : .empty), "mask=\(mask)")
            XCTAssertEqual(presentation.safeBytes, expectedBytes, "mask=\(mask)")
            XCTAssertEqual(presentation.safeCount, expectedCount, "mask=\(mask)")
            XCTAssertEqual(presentation.date, hasJunk ? session?.completedAt : (retainingJunkHistory ? oldDate : nil))
            if !hasJunk {
                XCTAssertNil(presentation.details, "Unscanned junk cannot supply executable rows")
            }
            if !hasJunk {
                let cache = await model.cache.statistics()
                XCTAssertEqual(cache.builds, 0, "Health/review-only sessions do no cleanup projection work")
            }
            for language in [AppLanguage.zhHans, .english] {
                let languageScope = CalibrationLanguageScope(language)
                defer { languageScope.restore() }
                XCTAssertEqual(panel.safeCleanupBytesText, expectedBytes.map(ByteFormat.string)
                    ?? L10n.text("尚未扫描", "Not Scanned Yet"), "mask=\(mask)")
                XCTAssertEqual(panel.safeCleanupCountText, expectedCount.map { L10n.text("\($0) 项", "\($0) items") }
                    ?? L10n.text("等待扫描", "Waiting for Scan"), "mask=\(mask)")
                if expectedBytes == nil {
                    XCTAssertEqual(panel.cleanupSummaryTitle, L10n.text("尚未扫描", "Not Scanned Yet"))
                    XCTAssertEqual(presentation.title, L10n.text("尚未扫描", "Not Scanned Yet"))
                    XCTAssertEqual(presentation.countText, L10n.text("等待扫描", "Waiting for Scan"))
                }
            }

            let expectedReminderDate = session?.completedAt ?? (retainingJunkHistory ? previousReview.date : nil)
            XCTAssertEqual(store.scanHistorySummary.latestScanAt, expectedReminderDate, "mask=\(mask)")
            let reminder = MaintenanceReminderService.summary(cadence: .weekly,
                lastScanAt: store.scanHistorySummary.latestScanAt,
                referenceDate: session?.completedAt ?? Date())
            XCTAssertEqual(reminder.lastScanAt, expectedReminderDate)
            XCTAssertEqual(reminder.status, mask == 0
                ? (retainingJunkHistory ? .due : .waitingForFirstScan) : .scheduled, "mask=\(mask)")
            let reloaded = ScanHistoryService.summary(defaults: defaults)
            XCTAssertEqual(reloaded.latestScanAt, expectedReminderDate, "Reminder time survives a restart, including health-only")
            XCTAssertEqual(reloaded.latestCleanupEntry?.greenBytes, expectedBytes)
            XCTAssertEqual(reloaded.entries.count, (retainingJunkHistory ? 2 : 0) + (mask & 3 == 0 ? 0 : 1))
            XCTAssertEqual(store.canClearScanHistory, expectedReminderDate != nil)
            let scannerCalls = await scanner.calls.count
            let healthCalls = await health.diskCalls
            XCTAssertEqual(scannerCalls, mask & 3 == 0 ? 0 : 1)
            XCTAssertEqual(healthCalls, mask & 4 == 0 ? 0 : 1)
            for task in model.stop() { await task.value }
        }
    }

    func testReviewOnlyHistoryCannotMasqueradeAsCleanupInThePurePresentation() {
        let entry = summaryEntry(date: Date(), scopes: [.filesToReview], greenBytes: 0, greenCount: 0)
        let history = ScanHistorySummary(entries: [entry]).latestStatus()
        let presentation = MiniWindowCleanupPresentation.resolve(session: nil, details: nil, history: history)
        XCTAssertEqual(presentation.source, .empty)
        XCTAssertNil(presentation.safeBytes)
        XCTAssertNil(presentation.safeCount)
    }

    func testLegacyUnscopedSessionCannotSupplyGlobalSummary() {
        let fixture = DebugSmartScanSessionFixture.session
        let session = ScanSession(id: fixture.id, rulesVersion: fixture.rulesVersion,
            startedAt: fixture.startedAt, completedAt: fixture.completedAt, outcome: fixture.outcome,
            categories: fixture.categories, issues: fixture.issues, permissions: fixture.permissions,
            metrics: fixture.metrics, system: fixture.system)
        XCTAssertNil(session.smartScanScopes)
        XCTAssertFalse(session.coversCleanupCandidates)
        let presentation = MiniWindowCleanupPresentation.resolve(session: session,
            details: MiniWindowCleanupDetails(session: session), history: nil)
        XCTAssertEqual(presentation.source, .empty)
        XCTAssertNil(presentation.safeBytes)
    }

    func testLegacyResultCannotReplaceSmartScanGlobalSummary() throws {
        for hasHistory in [false, true] {
            let defaults = TestPreferenceDomain.make(for: self)
            let old = summaryEntry(date: Date().addingTimeInterval(-60), scopes: [.cleanupCandidates],
                greenBytes: 73_728, greenCount: 3)
            if hasHistory { ScanHistoryService.record(old, defaults: defaults) }
            let store = try ScanStore.makeForTests(for: self,
                historyLoader: ScopeSeededHistory(summary: ScanHistoryService.summary(defaults: defaults)),
                scanHistoryDefaults: defaults)
            store.refreshScanHistory()
            let system = SystemSnapshot(osName: "fixture", build: "fixture", arch: "fixture", user: "fixture",
                home: "/Fixture", filesystem: "APFS", purgeable: "", diskName: "fixture",
                diskTotalBytes: 1_000, diskUsedBytes: 400, diskFreeBytes: 600)
            store.result = ScanResult(generatedAt: Date(), scanSeconds: 1, system: system,
                groups: [], items: [], deniedPaths: [])
            XCTAssertEqual(store.latestSafeCleanupEntry?.greenBytes, hasHistory ? old.greenBytes : nil)
            XCTAssertEqual(store.latestSafeCleanupEntry?.date, hasHistory ? old.date : nil)
        }
    }

    func testVisibleMiniWindowKeepsJunkHistoryAfterReviewAndHealthOnlyScans() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "visible-scope-summary")
        let scanner = ScopeRecordingScanner(rules: Self.rules, home: home)
        let health = ScopeRecordingHealthProbe()
        let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
            scanHistoryDefaults: defaults,
            cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
            smartScanHealthOperation: { await health.probe() },
            cleanupRuleSetLoader: { Self.rules }, cleanupUserHomeURL: home)
        store.selectedFilter = .overview
        store.startScan()
        let first = try await finished(store)
        let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
        defer { model.stop() }
        let source = MiniWindowCleanupSource(store: store)
        model.start(source)
        let deadline = Date().addingTimeInterval(5)
        while model.isPreparing {
            guard Date() < deadline else { throw ScopeProbeError.didNotFinish }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.presentation.source, .session)
        XCTAssertEqual(model.presentation.safeBytes, 8192)
        for scopes: Set<SmartScanScope> in [[.filesToReview], [.health]] {
            for scope in SmartScanScope.allCases where store.selectedSmartScanScopes.contains(scope) != scopes.contains(scope) {
                store.toggleSmartScanScope(scope)
            }
            store.startScan()
            let latest = try await finished(store)
            XCTAssertEqual(model.presentation.source, .history)
            XCTAssertEqual(model.presentation.safeBytes, 8192)
            XCTAssertEqual(model.presentation.safeCount, 2)
            XCTAssertEqual(model.presentation.date, first.completedAt)
            XCTAssertNil(model.session)
            XCTAssertNil(model.details)
            XCTAssertFalse(model.isPreparing)
            XCTAssertTrue(model.isInitialLayoutReady)
            XCTAssertEqual(store.scanHistorySummary.latestScanAt, latest.completedAt)
            XCTAssertEqual(summaryPanel(store: store, defaults: defaults).safeCleanupBytesText, ByteFormat.string(8192))
        }
        for task in model.stop() { await task.value }
        let opening = model.presentation(beforeStarting: source.current())
        XCTAssertEqual(opening.source, .history)
        XCTAssertEqual(opening.safeBytes, 8192)
        XCTAssertEqual(opening.date, first.completedAt)
        let stats = await model.cache.statistics()
        XCTAssertEqual(stats.builds, 1, "Only the actual junk scan generated a projection")
    }

    func testARealZeroJunkScanReplacesPreviousNonzeroHistory() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let old = summaryEntry(date: Date().addingTimeInterval(-60), scopes: [.cleanupCandidates],
            greenBytes: 73_728, greenCount: 3)
        ScanHistoryService.record(old, defaults: defaults)
        let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
            scanHistoryDefaults: defaults, cleanupScanOperation: { request, _ in Self.emptySummarySession(request) },
            cleanupRuleSetLoader: { Self.rules })
        for scope in SmartScanScope.allCases where scope != .cleanupCandidates { store.toggleSmartScanScope(scope) }
        store.selectedFilter = .overview
        store.startScan()
        let session = try await finished(store)
        XCTAssertEqual(store.scanHistorySummary.latestCleanupEntry?.greenBytes, 0)
        XCTAssertEqual(store.scanHistorySummary.latestCleanupEntry?.greenCount, 0)
        XCTAssertEqual(store.scanHistorySummary.latestCleanupEntry?.date, session.completedAt)
        let panel = summaryPanel(store: store, defaults: defaults)
        XCTAssertEqual(panel.safeCleanupBytesText, ByteFormat.string(0))
        XCTAssertEqual(panel.safeCleanupCountText, L10n.text("0 项", "0 items"))
        let presentation = MiniWindowCleanupPresentation.resolve(session: session,
            details: MiniWindowCleanupDetails(session: session), history: store.scanHistorySummary.latestCleanupStatus())
        XCTAssertEqual(presentation.source, .session)
        XCTAssertEqual(presentation.safeBytes, 0)
        XCTAssertEqual(presentation.safeCount, 0)
        XCTAssertEqual(presentation.title, L10n.text("可安全清理", "Safe Cleanup"))
        store.clearScanHistory()
        XCTAssertNil(store.scanHistorySummary.latestCleanupEntry)
        XCTAssertEqual(panel.safeCleanupBytesText, ByteFormat.string(0), "The loaded covered result survives history clearing")
        XCTAssertEqual(panel.safeCleanupCountText, L10n.text("0 项", "0 items"))
    }

    func testDeveloperFilesScanDoesNotReplaceAppWideSafeCleanupSummary() async throws {
        try await assertDedicatedScanDoesNotReplaceSummary(route: .devCaches)
    }

    func testNarrowedSafeCleanupScanDoesNotReplaceAppWideSummary() async throws {
        try await assertDedicatedScanDoesNotReplaceSummary(route: .green, narrowed: true)
    }

    func testAllDefaultSafeCleanupScopesStillDoNotUpdateGlobalSummary() async throws {
        XCTAssertEqual(SafeCleanupScanScope.defaultSelection, Set(SafeCleanupScanScope.allCases))
        try await assertDedicatedScanDoesNotReplaceSummary(route: .green)
    }

    private func assertDedicatedScanDoesNotReplaceSummary(route: ReviewFilter, narrowed: Bool = false) async throws {
        for hasHistory in [false, true] {
            let defaults = TestPreferenceDomain.make(for: self)
            let old = summaryEntry(date: Date().addingTimeInterval(-60), scopes: [.cleanupCandidates],
                greenBytes: 73_728, greenCount: 3)
            if hasHistory { ScanHistoryService.record(old, defaults: defaults) }
            let seeded = ScanHistorySummary(entries: hasHistory ? [old] : [],
                lastCompletedScanAt: hasHistory ? old.date : nil)
            let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeSeededHistory(summary: seeded),
                scanHistoryDefaults: defaults, cleanupScanOperation: { request, _ in Self.emptySummarySession(request) },
                cleanupRuleSetLoader: { Self.rules })
            store.refreshScanHistory()
            store.selectedFilter = route
            if route == .green {
                XCTAssertEqual(store.selectedSafeCleanupScopes, SafeCleanupScanScope.defaultSelection)
                if narrowed {
                    for scope in SafeCleanupScanScope.allCases where scope != .downloadResidue {
                        store.toggleSafeCleanupScope(scope)
                    }
                    XCTAssertEqual(store.selectedSafeCleanupScopes, [.downloadResidue])
                }
            }
            store.startScan()
            let session = try await finished(store)
            XCTAssertNil(session.smartScanScopes)
            XCTAssertFalse(session.coversCleanupCandidates)
            XCTAssertFalse(session.mappingCandidates { $0 }.coversCleanupCandidates)
            XCTAssertEqual(store.cleanupSession(for: route)?.id, session.id,
                "The dedicated result remains available on its own page")
            let otherRoute: ReviewFilter = route == .green ? .devCaches : .green
            XCTAssertNil(store.cleanupSession(for: otherRoute),
                "A dedicated scan cannot populate the other specialty page")
            if route == .devCaches {
                XCTAssertEqual(session.includedCategoryIDs, ["developer"])
            } else {
                XCTAssertNotNil(session.includedRuleIDs)
                if narrowed {
                    for scope in SafeCleanupScanScope.allCases where scope != .downloadResidue {
                        store.toggleSafeCleanupScope(scope)
                    }
                } else {
                    store.toggleSafeCleanupScope(.caches)
                }
                XCTAssertFalse(session.coversCleanupCandidates, "A later checkbox edit cannot make a dedicated run global")
            }

            let expectedBytes: Int64? = hasHistory ? old.greenBytes : nil
            let expectedCount: Int? = hasHistory ? old.greenCount : nil
            XCTAssertEqual(store.scanHistorySummary.latestCleanupEntry?.greenBytes, expectedBytes)
            XCTAssertEqual(store.latestSafeCleanupEntry?.greenBytes, expectedBytes)
            XCTAssertEqual(store.latestSafeCleanupEntry?.date, hasHistory ? old.date : nil)
            let panel = summaryPanel(store: store, defaults: defaults)
            XCTAssertEqual(panel.safeCleanupBytesText,
                expectedBytes.map(ByteFormat.string) ?? L10n.text("尚未扫描", "Not Scanned Yet"))
            XCTAssertEqual(panel.safeCleanupCountText,
                expectedCount.map { L10n.text("\($0) 项", "\($0) items") }
                    ?? L10n.text("等待扫描", "Waiting for Scan"))

            let expectedSource: MiniWindowCleanupPresentation.Source = hasHistory ? .history : .empty
            let history = store.scanHistorySummary.latestCleanupStatus()
            let pure = MiniWindowCleanupPresentation.resolve(session: session,
                details: MiniWindowCleanupDetails(session: session), history: history)
            XCTAssertEqual(pure.source, expectedSource)
            XCTAssertEqual(pure.safeBytes, expectedBytes)
            XCTAssertEqual(pure.safeCount, expectedCount)
            XCTAssertNil(pure.details)
            let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
            defer { model.stop() }
            let source = MiniWindowCleanupSource(store: store)
            let opening = model.presentation(beforeStarting: source.current())
            XCTAssertEqual(opening.source, expectedSource)
            model.start(source)
            XCTAssertNil(model.session, "Dedicated scans must not enter the global mini subscription")
            let deadline = Date().addingTimeInterval(5)
            while model.session == nil && !model.isInitialLayoutReady {
                guard Date() < deadline else { throw ScopeProbeError.didNotFinish }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(model.presentation.source, expectedSource)
            XCTAssertEqual(model.presentation.safeBytes, expectedBytes)
            XCTAssertNil(model.session)
            XCTAssertNil(model.details)
            let cache = await model.cache.statistics()
            XCTAssertEqual(cache.builds, 0, "Dedicated results must not build global cleanup rows")
            for task in model.stop() { await task.value }
        }
    }

    nonisolated private static func emptySummarySession(_ request: CleanupScanRequest) -> ScanSession {
        ScanSession(id: ScanSessionID(), rulesVersion: "scope-empty", startedAt: Date(), completedAt: Date(),
            outcome: .complete, categories: [], issues: [], permissions: [],
            metrics: ScanMetrics(visitedEntryCount: 0, candidateCount: 0, deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: 0, duration: 0),
            includedCategoryIDs: request.includedCategoryIDs, includedRuleIDs: request.includedRuleIDs)
    }

    func testMenuUsesNewestCoveredHistoryOrCurrentResultAndLoadedTotalsWinDateTies() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
            scanHistoryDefaults: defaults, cleanupScanOperation: { request, _ in Self.emptySummarySession(request) },
            cleanupRuleSetLoader: { Self.rules })
        for scope in SmartScanScope.allCases where scope != .cleanupCandidates { store.toggleSmartScanScope(scope) }
        store.selectedFilter = .overview
        store.startScan()
        let session = try await finished(store)
        let panel = summaryPanel(store: store, defaults: defaults)
        let tied = summaryEntry(date: session.completedAt, scopes: [.cleanupCandidates],
            greenBytes: 73_728, greenCount: 3)
        let newerJunk = summaryEntry(date: session.completedAt.addingTimeInterval(60),
            scopes: [.cleanupCandidates], greenBytes: 147_456, greenCount: 4)
        let newerReview = summaryEntry(date: session.completedAt.addingTimeInterval(120),
            scopes: [.filesToReview], greenBytes: 0, greenCount: 0)
        let newerLegacy = summaryEntry(date: session.completedAt.addingTimeInterval(180),
            scopes: nil, greenBytes: 294_912, greenCount: 8)
        store.scanHistorySummary = ScanHistorySummary(entries: [newerReview, tied])
        XCTAssertEqual(panel.safeCleanupBytesText, ByteFormat.string(0), "Loaded totals supersede the original history at the same date")
        store.scanHistorySummary = ScanHistorySummary(entries: [newerReview, newerJunk, tied])
        XCTAssertEqual(panel.safeCleanupBytesText, ByteFormat.string(newerJunk.greenBytes))
        XCTAssertEqual(panel.safeCleanupCountText, L10n.text("4 项", "4 items"))
        store.scanHistorySummary = ScanHistorySummary(entries: [newerLegacy, newerReview, newerJunk, tied])
        XCTAssertEqual(panel.safeCleanupBytesText, ByteFormat.string(newerJunk.greenBytes),
            "A newer legacy record cannot supply a global Smart Scan total")
        store.scanHistorySummary = ScanHistorySummary(entries: [newerLegacy, newerReview])
        XCTAssertEqual(panel.safeCleanupBytesText, ByteFormat.string(0),
            "Newer legacy or review-only history cannot hide the loaded Smart Scan total")
        XCTAssertEqual(panel.safeCleanupCountText, L10n.text("0 项", "0 items"))
    }

    func testHealthAndReviewSessionsCannotMasqueradeAsCleanupInThePurePresentation() {
        for scopes: Set<SmartScanScope> in [[.health], [.filesToReview], [.filesToReview, .health]] {
            let session = DebugSmartScanSessionFixture.session.withSmartScan(scopes: scopes, health: nil)
            let presentation = MiniWindowCleanupPresentation.resolve(session: session,
                details: MiniWindowCleanupDetails(session: session), history: nil)
            XCTAssertEqual(presentation.source, .empty, "Even nonzero injected junk rows cannot override coverage")
            XCTAssertNil(presentation.details)
            XCTAssertNil(presentation.safeBytes)
            XCTAssertNil(presentation.safeCount)
        }
    }

    private func summaryPanel(store: ScanStore, defaults: UserDefaults) -> MenuBarAdvancedStatusView {
        let operations = TestOperationFactory(for: self)
        return MenuBarAdvancedStatusView(store: store,
            computerHealthStore: ComputerHealthStore(probe: ScopeUnusedHealthProbe(),
                batteryPowerModeController: operations.batteryPowerModeController()),
            panelSettingsState: MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults),
            panelCoordinator: GeekPanelCoordinator(initialSection: .cleanup), initialSection: .cleanup,
            fanControl: operations.fanControl(defaults: defaults))
    }

    private func summaryEntry(date: Date, scopes: Set<SmartScanScope>?, greenBytes: Int64, greenCount: Int) -> ScanHistoryEntry {
        ScanHistoryEntry(date: date, scanSeconds: 1, score: 95, diskUsedBytes: 10, diskFreeBytes: 90,
            greenBytes: greenBytes, yellowBytes: 12_288, redBytes: 0, itemCount: greenCount + 3,
            greenCount: greenCount, yellowCount: 3, redCount: 0, deniedCount: 0,
            smartScanScopes: scopes, smartScanHealthStatus: scopes == nil ? nil : .notRequested)
    }

    func testEveryCheckboxCombinationExecutesOnlyItsSelectedPhasesAndResults() async throws {
        for mask in 1..<8 {
            let scopes = selection(mask)
            let home = try TestFileSystem.makeOperationHome(for: self, purpose: "smart-scan-scopes")
            let rules = Self.rules
            let scanner = ScopeRecordingScanner(rules: rules, home: home)
            let health = ScopeRecordingHealthProbe()
            let store = try ScanStore.makeForTests(for: self,
                historyLoader: ScopeEmptyHistory(),
                cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
                smartScanHealthOperation: { await health.probe() },
                cleanupRuleSetLoader: { rules }, cleanupUserHomeURL: home)
            for scope in SmartScanScope.allCases where !scopes.contains(scope) { store.toggleSmartScanScope(scope) }
            store.selectedFilter = .overview
            store.startScan()
            let session = try await finished(store)
            let expectedCategories: Set<String> = (mask & 1 == 0 ? Set<String>() : Set(["system", "developer"]))
                .union(mask & 2 == 0 ? Set<String>() : Set(["downloads", "mail", "applications"]))
            let calls = await scanner.calls
            XCTAssertEqual(calls.count, mask & 3 == 0 ? 0 : 1, "mask=\(mask)")
            XCTAssertEqual(Set(session.categories.map(\.id)), expectedCategories, "mask=\(mask)")
            XCTAssertEqual(Set(session.candidates.map(\.categoryID)), expectedCategories)
            XCTAssertEqual(session.metrics.candidateCount, expectedCategories.count)
            XCTAssertEqual(session.metrics.estimatedCandidateBytes, Int64(expectedCategories.count) * 4096)
            let executed = await scanner.executedRuleIDs
            let diskCalls = await health.diskCalls
            let batteryCalls = await health.batteryCalls
            XCTAssertEqual(Set(executed), Set(expectedCategories.map { "fixture.\($0)" }))
            XCTAssertEqual(diskCalls, mask & 4 == 0 ? 0 : 1)
            XCTAssertEqual(batteryCalls, mask & 4 == 0 ? 0 : 1)
            XCTAssertEqual(session.smartScanScopes, scopes)
            XCTAssertEqual(session.smartScanHealthSnapshot, mask & 4 == 0 ? nil : ScopeRecordingHealthProbe.snapshot)
            XCTAssertEqual(store.smartScanHealthSnapshot, session.smartScanHealthSnapshot)
            XCTAssertEqual(ScanStore.scanRoute(of: session), .overview)
            XCTAssertEqual(store.cleanupSelection.selectedCandidateIDs,
                CleanupSelection.defaults(in: session).selectedCandidateIDs,
                "Scan coverage never replaces the existing cleanup preselection policy")
            XCTAssertFalse(store.cleanupSelection.selectedCandidates(in: session).contains { $0.risk != .safe })
            if mask & 3 == 0 {
                XCTAssertNil(store.scanHistorySummary.latest, "Health-only scans do not update file-scan history")
                XCTAssertEqual(session.includedCategoryIDs, Set<String>(), "No file categories were scanned")
                XCTAssertEqual(session.includedRuleIDs, Set<String>())
            } else {
                let entry = try XCTUnwrap(store.scanHistorySummary.latest, "Every completed selected file scope is recorded")
                XCTAssertEqual(entry.smartScanScopes, scopes)
                XCTAssertEqual(entry.smartScanHealthStatus, mask & 4 == 0 ? .notRequested : .completed)
                XCTAssertEqual(entry.scanWasLimited, false)
            }
            let rebuilt = session.mappingCandidates { $0 }
            XCTAssertEqual(rebuilt.smartScanScopes, scopes)
            XCTAssertEqual(rebuilt.smartScanHealthSnapshot, session.smartScanHealthSnapshot)
            XCTAssertEqual(rebuilt.smartScanHealthStatus, session.smartScanHealthStatus)
        }
    }

    func testEmptySelectionPersistsDisablesTheRealStartButtonAndRunsNothing() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let scanner = ScopeRecordingScanner(rules: Self.rules,
            home: try TestFileSystem.makeOperationHome(for: self, purpose: "empty-smart-scope"))
        let health = ScopeRecordingHealthProbe()
        let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
            cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
            smartScanHealthOperation: { await health.probe() }, cleanupPreferences: defaults)
        XCTAssertEqual(store.selectedSmartScanScopes, SmartScanScope.defaultSelection)
        for scope in SmartScanScope.allCases { store.toggleSmartScanScope(scope) }
        XCTAssertTrue(store.selectedSmartScanScopes.isEmpty)
        XCTAssertEqual(defaults.array(forKey: SmartScanScope.defaultsKey) as? [String], [])
        let reloaded = try ScanStore.makeForTests(for: self, cleanupPreferences: defaults)
        XCTAssertTrue(reloaded.selectedSmartScanScopes.isEmpty, "Empty is an intentional preference")
        store.selectedFilter = .overview
        store.startScanRespectingAccessGuide()
        store.startScan()
        XCTAssertFalse(store.isScanning)
        XCTAssertFalse(store.isCheckingScanReadiness)
        XCTAssertNil(store.cleanupScanSession)
        let scanCalls = await scanner.calls.count
        let diskCalls = await health.diskCalls
        let batteryCalls = await health.batteryCalls
        XCTAssertEqual(scanCalls, 0)
        XCTAssertEqual(diskCalls, 0)
        XCTAssertEqual(batteryCalls, 0)
        let size = CGSize(width: 1084, height: 712)
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            let root = AdaptivePageViewport {
                SmartCareLandingView(store: store, latestStatus: nil)
                    .environment(\.moduleTheme, ReviewFilter.overview.moduleTheme)
            }
            let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
            defer { host.close() }
            let frames = try await host.frames(required: [LayoutProbeID.landingActionButton], size: size)
            let actionFrame = try XCTUnwrap(frames[LayoutProbeID.landingActionButton])
            let title = L10n.text("开始扫描", "Start Scan")
            // The outer ScrollView's DocumentView omits SwiftUI descendants
            // from its children in this inert host (N20). Discover the actual
            // native button through public AX hit testing, never a fake AX node.
            try await host.waitForAccessibility(labels: [title], expectedEnabled: [title: false], pressLabels: [title],
                hitTestFrames: [actionFrame])
            let button = try XCTUnwrap(host.element(label: title, requiresPress: true))
            XCTAssertTrue(button.responds(to: NSSelectorFromString("isAccessibilityEnabled")))
            XCTAssertFalse(button.value(forKey: "accessibilityEnabled") as? Bool ?? true,
                "The real native button remains labelled and disabled with no scope selected")
            let nativeFrame = try host.accessibilityFrame(label: title)
            XCTAssertGreaterThan(nativeFrame.width, 0)
            XCTAssertGreaterThan(nativeFrame.height, 0)
            XCTAssertTrue(nativeFrame.contains(CGPoint(x: actionFrame.midX, y: actionFrame.midY)),
                "Hit testing must return the pinned action's real native button")
            XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(nativeFrame))

            // Check both states on the same production view. Changing coverage
            // only enables the control; it does not start a scan.
            store.toggleSmartScanScope(.cleanupCandidates)
            host.resize(to: size) // discard retained native hit objects from the previous state
            let enabledFrames = try await host.frames(required: [LayoutProbeID.landingActionButton], size: size)
            let enabledFrame = try XCTUnwrap(enabledFrames[LayoutProbeID.landingActionButton])
            try await host.waitForAccessibility(labels: [title], expectedEnabled: [title: true], pressLabels: [title],
                hitTestFrames: [enabledFrame])
            let enabledButton = try XCTUnwrap(host.element(label: title, requiresPress: true))
            XCTAssertTrue(enabledButton.value(forKey: "accessibilityEnabled") as? Bool ?? false)
            store.toggleSmartScanScope(.cleanupCandidates)
            XCTAssertTrue(store.selectedSmartScanScopes.isEmpty)
        }
        let finalScanCalls = await scanner.calls.count
        let finalDiskCalls = await health.diskCalls
        let finalBatteryCalls = await health.batteryCalls
        XCTAssertEqual(finalScanCalls, 0, "Changing selection alone never scans")
        XCTAssertEqual(finalDiskCalls, 0)
        XCTAssertEqual(finalBatteryCalls, 0)
        store.toggleSmartScanScope(.cleanupCandidates)
        XCTAssertEqual(store.selectedSmartScanScopes, [.cleanupCandidates])
        let again = try ScanStore.makeForTests(for: self, cleanupPreferences: defaults)
        XCTAssertEqual(again.selectedSmartScanScopes, [.cleanupCandidates])
    }

    func testRulePartitionIsCoverageRatherThanRiskAndKeepsAllExistingRules() throws {
        let all = try CleanupRuleSetLoader.loadBundled()
        let cleanup = all.rules.filter(SmartScanScope.cleanupCandidates.includes)
        let review = all.rules.filter(SmartScanScope.filesToReview.includes)
        XCTAssertFalse(cleanup.isEmpty)
        XCTAssertFalse(review.isEmpty)
        XCTAssertTrue(Set(cleanup.map(\.id)).isDisjoint(with: Set(review.map(\.id))))
        XCTAssertEqual(Set((cleanup + review).map(\.id)), Set(all.rules.map(\.id)))
        XCTAssertTrue(review.contains { $0.id == "mail.downloaded-attachments" })
        XCTAssertTrue(review.contains { $0.categoryID == "applications" })
        XCTAssertTrue(cleanup.contains { $0.categoryID == "developer" })
        XCTAssertTrue(cleanup.contains { $0.id == "trash.user-trash" })
        XCTAssertTrue(all.rules.allSatisfy { !SmartScanScope.health.includes($0) })
    }

    func testFailedHealthKeepsCompletedFileResultsAndCancelledFilesNeverStartHealth() async throws {
        for cancelled in [false, true] {
            let health = ScopeRecordingHealthProbe()
            let fixture = ScopeRecordingScanner(rules: Self.rules,
                home: try TestFileSystem.makeOperationHome(for: self, purpose: "smart-health-outcome"))
            let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
                cleanupScanOperation: { request, progress in
                    let session = try await fixture.scan(request, progress: progress)
                    return cancelled ? session.withSmartScan(scopes: .init(SmartScanScope.allCases),
                        health: nil, outcome: .cancelled) : session
                }, smartScanHealthOperation: {
                    _ = await health.probe()
                    throw ScopeProbeError.unavailable
                }, cleanupRuleSetLoader: { Self.rules })
            store.selectedFilter = .overview
            store.startScan()
            let session = try await finished(store)
            XCTAssertEqual(session.outcome, cancelled ? .cancelled : .complete)
            XCTAssertEqual(session.metrics.candidateCount, 5)
            XCTAssertNil(session.smartScanHealthSnapshot)
            let diskCalls = await health.diskCalls
            let batteryCalls = await health.batteryCalls
            XCTAssertEqual(diskCalls, cancelled ? 0 : 1)
            XCTAssertEqual(batteryCalls, cancelled ? 0 : 1)
            XCTAssertFalse(session.issues.contains { $0.ruleID == "smart.health" }, "Health failure is not a file-scan issue")
            XCTAssertEqual(session.smartScanHealthStatus, cancelled ? .cancelled : .failed)
            XCTAssertEqual(store.scanHistorySummary.latestScanAt, cancelled ? nil : session.completedAt)
            if cancelled { XCTAssertNil(store.latestSafeCleanupEntry) }
        }
    }

    func testPublishedHealthPhaseKeepsOnlySelectedFileGroupsAndFreezesCoverage() async throws {
        for mask in [4, 5, 6, 7] {
            let scopes = selection(mask)
            let home = try TestFileSystem.makeOperationHome(for: self, purpose: "smart-health-phase")
            let scanner = ScopeRecordingScanner(rules: Self.rules, home: home)
            let gate = ScopeHealthGate()
            let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
                cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
                smartScanHealthOperation: { try await gate.probe() },
                cleanupRuleSetLoader: { Self.rules }, cleanupUserHomeURL: home)
            for scope in SmartScanScope.allCases where !scopes.contains(scope) { store.toggleSmartScanScope(scope) }
            store.selectedFilter = .overview
            store.startScan()
            let deadline = Date().addingTimeInterval(5)
            while store.mainScanProgress?.currentGroupTitle != SmartScanScope.health.title {
                guard Date() < deadline else { throw ScopeProbeError.didNotFinish }
                try await Task.sleep(for: .milliseconds(5))
            }
            let progress = try XCTUnwrap(store.mainScanProgress)
            let expectedFiles = (mask & 1 == 0 ? Set<String>() : Set(["system", "developer"]))
                .union(mask & 2 == 0 ? Set<String>() : Set(["downloads", "mail", "applications"]))
            XCTAssertEqual(progress.totalGroupCount, expectedFiles.count + 1)
            XCTAssertEqual(progress.completedGroupCount, expectedFiles.count)
            XCTAssertEqual(progress.discoveredItemCount, expectedFiles.count)
            XCTAssertEqual(progress.discoveredBytes, Int64(expectedFiles.count) * 4096)
            XCTAssertEqual(Set(progress.groups.map(\.id)), Set(expectedFiles.map { "fixture.\($0)" }).union(["smart.health"]))
            XCTAssertEqual(progress.groups.first { $0.id == "smart.health" }?.state, .scanning)
            XCTAssertTrue(store.canCancelMainScan)
            store.toggleSmartScanScope(.health)
            XCTAssertEqual(store.selectedSmartScanScopes, scopes, "A running task keeps its captured scope")
            await gate.release()
            let result = try await finished(store)
            XCTAssertEqual(result.smartScanScopes, scopes)
            XCTAssertNotNil(result.smartScanHealthSnapshot)
        }
    }

    func testCancellingTheHealthPhaseKeepsCompletedFilesAndTheirExistingSelectionPolicy() async throws {
        let scanner = ScopeRecordingScanner(rules: Self.rules,
            home: try TestFileSystem.makeOperationHome(for: self, purpose: "smart-health-cancellation"))
        let gate = ScopeHealthGate()
        let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
            cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
            smartScanHealthOperation: { try await gate.probe() }, cleanupRuleSetLoader: { Self.rules })
        store.selectedFilter = .overview
        store.startScan()
        let deadline = Date().addingTimeInterval(5)
        while store.mainScanProgress?.currentGroupTitle != SmartScanScope.health.title {
            guard Date() < deadline else { throw ScopeProbeError.didNotFinish }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.canCancelMainScan)
        store.cancelMainScan()
        let session = try await finished(store)
        XCTAssertEqual(session.outcome, .cancelled)
        XCTAssertEqual(session.metrics.candidateCount, 5)
        XCTAssertEqual(session.smartScanScopes, SmartScanScope.defaultSelection)
        XCTAssertNil(session.smartScanHealthSnapshot)
        XCTAssertNil(store.smartScanHealthSnapshot)
        XCTAssertEqual(store.cleanupSelection.selectedCandidateIDs,
            CleanupSelection.defaults(in: session).selectedCandidateIDs)
        XCTAssertNil(store.scanHistorySummary.latest)
        XCTAssertNil(store.scanHistorySummary.latestScanAt, "Cancellation must not reset the reminder")
        XCTAssertFalse(store.canCancelMainScan)
    }

    func testLandingScopeButtonsUseRealStoreToggleAndFixtureDefaultsStayInert() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let landing = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MainWorkspaceViews.swift"), encoding: .utf8)
        XCTAssertTrue(landing.contains("ForEach(SmartScanScope.allCases)"))
        XCTAssertTrue(landing.contains("store.toggleSmartScanScope(scope)"))
        XCTAssertTrue(landing.contains("Button(action: onToggle)"))
        XCTAssertTrue(landing.contains("store.selectedSmartScanScopes.isEmpty"))
        let store = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Stores/ScanStore.swift"), encoding: .utf8)
        XCTAssertTrue(store.contains("if FeaturePresentationDemo.isEnabled { selectedSmartScanScopes = SmartScanScope.defaultSelection }"))
        XCTAssertFalse(store.contains("SmartScanScope.save(SmartScanScope.defaultSelection"),
            "Inert captures must not overwrite saved user selection")
    }

    func testLegacyDiagnosticHealthFailureKeepsItsOriginalFileResult() async throws {
        let date = Date(timeIntervalSince1970: 400)
        let system = SystemSnapshot(osName: "fixture", build: "fixture", arch: "fixture", user: "fixture",
            home: "/Fixture", filesystem: "APFS", purgeable: "", diskName: "fixture", diskTotalBytes: 1000,
            diskUsedBytes: 400, diskFreeBytes: 600)
        let result = ScanResult(generatedAt: date, scanSeconds: 1, system: system,
            groups: [], items: [], deniedPaths: [])
        let health = ScopeRecordingHealthProbe()
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "legacy-smart-scope")
        let scanner = ScopeRecordingScanner(rules: Self.rules, home: home)
        let store = try ScanStore.makeForTests(for: self,
            scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(scan: { _, _ in result }),
            historyLoader: ScopeEmptyHistory(), cleanupFeatureConfiguration: .init(mode: .legacy),
            cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
            smartScanHealthOperation: {
                _ = await health.probe()
                throw ScopeProbeError.unavailable
            }, cleanupRuleSetLoader: { Self.rules }, cleanupUserHomeURL: home)
        store.selectedFilter = .overview
        store.toggleSmartScanScope(.cleanupCandidates)
        store.toggleSmartScanScope(.health)
        store.startScan()
        let scoped = try await finished(store)
        XCTAssertEqual(Set(scoped.categories.map(\.id)), ["downloads", "mail", "applications"])
        let reviewedID = try XCTUnwrap(scoped.candidates.first?.id)
        store.setCleanupCandidate(reviewedID, selected: true)
        XCTAssertEqual(store.cleanupSelection.selectedCandidateIDs, [reviewedID])
        store.toggleSmartScanScope(.cleanupCandidates)
        store.toggleSmartScanScope(.health)
        store.startScan()
        let deadline = Date().addingTimeInterval(5)
        while store.isScanning {
            guard Date() < deadline else { throw ScopeProbeError.didNotFinish }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(store.result)
        XCTAssertNil(store.cleanupScanSession, "The preceding narrowed session cannot shadow the new legacy result")
        XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.isEmpty)
        XCTAssertNil(store.cleanupDryRunSummary)
        XCTAssertNil(store.pendingCleanPlan)
        XCTAssertNil(store.pendingCleanPreflight)
        XCTAssertEqual(store.cleanupWorkflowState, .idle)
        XCTAssertEqual(store.result?.generatedAt, date)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.smartScanHealthSnapshot)
        XCTAssertEqual(store.actionMessage, L10n.text("健康信息不可用；已保留完成的只读文件结果。",
            "Health information unavailable; completed read-only file results were kept."))
        let calls = await health.diskCalls
        XCTAssertEqual(calls, 1)
    }

    func testCleanupPageRoutesUseCompletedCoverageRatherThanEmptyResultsOrNewCheckboxes() async throws {
        let size = CGSize(width: 1084, height: 712)
        for mask in 1..<8 {
            let scopes = selection(mask)
            let scanner = ScopeRecordingScanner(rules: Self.rules,
                home: try TestFileSystem.makeOperationHome(for: self, purpose: "scope-route"))
            let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
                cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
                smartScanHealthOperation: { ScopeRecordingHealthProbe.snapshot },
                cleanupRuleSetLoader: { Self.rules })
            for scope in SmartScanScope.allCases where !scopes.contains(scope) { store.toggleSmartScanScope(scope) }
            store.selectedFilter = .overview
            store.startScan()
            let session = try await finished(store)
            // Changing the next scan's checkboxes cannot alter the completed run's coverage.
            for scope in SmartScanScope.allCases { store.toggleSmartScanScope(scope) }
            for route in [ReviewFilter.green, .devCaches] {
                store.selectedFilter = route
                let showsResults = scopes.contains(.cleanupCandidates)
                XCTAssertEqual(store.cleanupSession(for: route)?.id, showsResults ? session.id : nil)
                let root = AdaptivePageViewport {
                    CleanupWorkspaceView(store: store, filter: route)
                        .environment(\.moduleTheme, route.moduleTheme)
                }.transaction { $0.disablesAnimations = true }
                let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
                defer { host.close() }
                let present = showsResults ? "cleanup.route.results" : "cleanup.route.landing"
                let absent = showsResults ? "cleanup.route.landing" : "cleanup.route.results"
                let frames = try await host.frames(required: [present, "fixture.viewport"], size: size)
                let frame = try XCTUnwrap(frames[present])
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertNil(frames[absent], "mask=\(mask), route=\(route): unscanned files cannot render a clean result")
            }
        }
    }

    func testFileWorkspaceRefreshPreservesTheSmartScanSessionSelectionWorkflowAndHistory() async throws {
        for route in [ReviewFilter.largeFiles, .migration, .duplicates] {
            let home = try TestFileSystem.makeOperationHome(for: self, purpose: "scoped-refresh")
            let scanner = ScopeRecordingScanner(rules: Self.rules, home: home)
            let calls = ScopeWorkspaceCalls()
            let store = try ScanStore.makeForTests(for: self,
                scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(scan: { _, _ in
                    await calls.record("legacy")
                    throw ScopeProbeError.unavailable
                }),
                largeFilesScanOperation: { _ in await calls.record("migration"); return [] },
                largeFilesStorageMapTargets: [StorageMapScanTarget(path: home.path, title: "Fixture", kind: .homeDirectory)],
                largeFilesStorageAnalysisOperation: { target, _ in
                    await calls.record("analysis")
                    return Self.emptyStorageAnalysis(target)
                },
                duplicateFilesScanOperation: { _, _, _, _, _ in
                    await calls.record("duplicates")
                    return DuplicateFileScanReport(exactGroups: [], candidates: [],
                        coverage: DuplicateFileScanCoverage(roots: [], reachedTimeLimit: false,
                            reachedFileLimit: false, reachedDirectoryLimit: false, reachedResultLimit: false),
                        progress: .initial, outcome: .complete)
                },
                loadScanReadinessSummary: {
                    XCTFail("A feature-owned refresh must not run the main scan's access guide")
                    return ScanReadinessSummary(items: [])
                }, historyLoader: ScopeEmptyHistory(),
                cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
                smartScanHealthOperation: { ScopeRecordingHealthProbe.snapshot },
                cleanupRuleSetLoader: { Self.rules }, cleanupUserHomeURL: home)
            store.selectedFilter = .overview
            store.startScan()
            let session = try await finished(store)
            let selected = try XCTUnwrap(store.cleanupSelection.selectedCandidateIDs.first)
            store.setCleanupCandidate(selected, selected: false)
            let selection = store.cleanupSelection.selectedCandidateIDs
            store.prepareCleanupDryRun()
            let dryRun = try XCTUnwrap(store.cleanupDryRunSummary)
            let history = store.scanHistorySummary
            let presentationID = store.scanPresentationSessionID
            store.selectedFilter = route
            store.startScanRespectingAccessGuide() // the Cmd-R entry point
            let deadline = Date().addingTimeInterval(5)
            while store.isPreparingScan || store.largeFilesWorkspace.trashPolicy?.awaitsProtectedLinkTargets == true {
                guard Date() < deadline else { throw ScopeProbeError.didNotFinish }
                try await Task.sleep(for: .milliseconds(5))
            }
            let actualCalls = await calls.values
            let expectedCall = route == .largeFiles ? "analysis" : route == .migration ? "migration" : "duplicates"
            XCTAssertEqual(actualCalls, [expectedCall], "Refresh only the active file page")
            let smartCalls = await scanner.calls.count
            XCTAssertEqual(smartCalls, 1)
            XCTAssertEqual(store.cleanupScanSession?.id, session.id)
            XCTAssertEqual(store.cleanupSelection.selectedCandidateIDs, selection)
            XCTAssertEqual(store.cleanupDryRunSummary?.sessionID, session.id)
            XCTAssertEqual(store.cleanupDryRunSummary?.createdAt, dryRun.createdAt)
            XCTAssertEqual(store.cleanupDryRunSummary?.paths, dryRun.paths)
            XCTAssertEqual(store.cleanupWorkflowState, .results(sessionID: session.id))
            XCTAssertEqual(store.scanPresentationSessionID, presentationID)
            XCTAssertEqual(store.scanPresentationState, .results)
            XCTAssertEqual(store.scanHistorySummary, history)
            XCTAssertEqual(store.smartScanHealthSnapshot, session.smartScanHealthSnapshot)
            XCTAssertNil(store.pendingCleanPlan)
            XCTAssertNil(store.pendingCleanPreflight)
            XCTAssertNil(store.result, "A file-workspace refresh never publishes a legacy full-disk result")
            XCTAssertEqual(store.selectedFilter, route)
        }
        let commands = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift")
        XCTAssertTrue(commands.contains("store.startScanRespectingAccessGuide()"))
        XCTAssertTrue(commands.contains(".keyboardShortcut(\"r\", modifiers: [.command])"))
    }

    func testEveryFileScopeWithoutHealthPersistsCoverageAndRefreshesHistoryStatus() async throws {
        for mask in [1, 2, 3] {
            let scopes = selection(mask)
            let defaults = TestPreferenceDomain.make(for: self)
            let scanner = ScopeRecordingScanner(rules: Self.rules,
                home: try TestFileSystem.makeOperationHome(for: self, purpose: "file-only-history"))
            let health = ScopeRecordingHealthProbe()
            let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
                scanHistoryDefaults: defaults,
                cleanupScanOperation: { request, progress in try await scanner.scan(request, progress: progress) },
                smartScanHealthOperation: { await health.probe() }, cleanupRuleSetLoader: { Self.rules })
            for scope in SmartScanScope.allCases where !scopes.contains(scope) { store.toggleSmartScanScope(scope) }
            store.selectedFilter = .overview
            store.startScan()
            let session = try await finished(store)
            let entry = try XCTUnwrap(store.scanHistorySummary.latest)
            let persisted = try XCTUnwrap(ScanHistoryService.load(defaults: defaults).first)
            XCTAssertEqual(persisted, entry)
            XCTAssertEqual(entry.smartScanScopes, scopes)
            XCTAssertEqual(entry.smartScanHealthStatus, .notRequested)
            XCTAssertEqual(entry.date, session.completedAt)
            XCTAssertEqual(entry.itemCount, session.metrics.candidateCount)
            XCTAssertEqual(entry.scanWasLimited, false)
            XCTAssertEqual(store.scanHistorySummary.latestStatus()?.attentionLevel, .current)
            XCTAssertEqual(entry.greenBytes, CleanupScanTierTotals(categories: session.categories).safeBytes)
            let healthCalls = await health.diskCalls
            XCTAssertEqual(healthCalls, 0)
            for language in [AppLanguage.zhHans, .english] {
                let languageScope = CalibrationLanguageScope(language)
                defer { languageScope.restore() }
                XCTAssertEqual(entry.smartScanHealthStatus?.title,
                    language == .zhHans ? "未做健康检查" : "Health check not performed")
            }
        }
    }

    func testHealthReadFailureDoesNotDowngradeFileOutcomeHistoryScoreOrPermissionEvidence() async throws {
        for (fileOutcome, denied) in [(ScanOutcome.complete, false), (.partial, false), (.partial, true)] {
            let defaults = TestPreferenceDomain.make(for: self)
            let scanner = ScopeRecordingScanner(rules: Self.rules,
                home: try TestFileSystem.makeOperationHome(for: self, purpose: "health-history-failure"))
            let store = try ScanStore.makeForTests(for: self, historyLoader: ScopeEmptyHistory(),
                scanHistoryDefaults: defaults,
                cleanupScanOperation: { request, progress in
                    let files = try await scanner.scan(request, progress: progress)
                    return ScanSession(id: files.id, rulesVersion: files.rulesVersion,
                        startedAt: files.startedAt, completedAt: files.completedAt, outcome: fileOutcome,
                        categories: files.categories,
                        issues: denied ? [ScanIssue(ruleID: "fixture.denied", path: nil, kind: .permissionDenied)] : [],
                        permissions: denied
                            ? [CleanupPermissionReport(ruleID: "fixture.denied", path: "/Fixture/Denied", status: .permissionDenied)] : [],
                        metrics: files.metrics, system: files.system,
                        includedCategoryIDs: files.includedCategoryIDs, includedRuleIDs: files.includedRuleIDs)
                }, smartScanHealthOperation: { throw ScopeProbeError.unavailable },
                cleanupRuleSetLoader: { Self.rules })
            store.selectedFilter = .overview
            store.startScan()
            let session = try await finished(store)
            XCTAssertEqual(session.outcome, fileOutcome, "Health failure never changes the file outcome")
            XCTAssertEqual(session.smartScanHealthStatus, .failed)
            XCTAssertEqual(session.issues.map(\.ruleID), denied ? ["fixture.denied"] : [],
                "Keep real file issues; a health failure must not add a skipped file rule")
            XCTAssertEqual(session.permissions.filter { $0.status == .permissionDenied }.count, denied ? 1 : 0)
            XCTAssertEqual(session.metrics.candidateCount, 5)
            let entry = try XCTUnwrap(store.scanHistorySummary.latest)
            XCTAssertEqual(entry.smartScanHealthStatus, .failed)
            XCTAssertEqual(entry.scanWasLimited, fileOutcome == .partial)
            XCTAssertEqual(entry.deniedCount, denied ? 1 : 0)
            let healthy = session.withSmartScan(scopes: SmartScanScope.defaultSelection,
                health: ScopeRecordingHealthProbe.snapshot)
            XCTAssertEqual(entry.score, ScanHistoryService.entry(from: healthy, scanMode: entry.scanMode).score)
            XCTAssertEqual(ScanHistoryService.load(defaults: defaults).first, entry)
            XCTAssertEqual(store.scanHistorySummary.latestStatus()?.attentionLevel,
                denied ? .permissionLimited : fileOutcome == .partial ? .rescanRecommended : .current)
            XCTAssertEqual(session.mappingCandidates { $0 }.smartScanHealthStatus, .failed)
            for language in [AppLanguage.zhHans, .english] {
                let languageScope = CalibrationLanguageScope(language)
                defer { languageScope.restore() }
                XCTAssertEqual(session.smartScanHealthStatus?.title,
                    language == .zhHans ? "健康信息读取失败" : "Health information could not be read")
            }
        }
        let healthView = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/SmartScanHealthResultsView.swift")
        XCTAssertTrue(healthView.contains("Text(status?.title ?? unavailable)"), "The existing health section renders the actual cause")
    }

    func testHistoryCoverageSurvivesScoreRebalanceAndOlderRecordsStayUnknown() throws {
        let scopes: Set<SmartScanScope> = [.filesToReview]
        let entry = ScanHistoryEntry(date: Date(), scanSeconds: 1, score: 0,
            diskUsedBytes: 10, diskFreeBytes: 90, greenBytes: 0, yellowBytes: 0, redBytes: 0,
            itemCount: 0, greenCount: 0, yellowCount: 0, redCount: 0, deniedCount: 0,
            scanMode: .standard, permissionPenalty: 0, scoreModelVersion: ScanHistoryService.currentScoreModelVersion,
            actionableGreenBytes: 0, actionableGreenCount: 0, scanWasLimited: false,
            smartScanScopes: scopes, smartScanHealthStatus: .notRequested)
        let defaults = TestPreferenceDomain.make(for: self)
        ScanHistoryService.record(entry, defaults: defaults)
        let rebalanced = try XCTUnwrap(ScanHistoryService.load(defaults: defaults).first)
        XCTAssertNotEqual(rebalanced.score, entry.score, "Exercise the rebuilding path")
        XCTAssertEqual(rebalanced.smartScanScopes, scopes)
        XCTAssertEqual(rebalanced.smartScanHealthStatus, .notRequested)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "smartScanScopes")
        json.removeValue(forKey: "smartScanHealthStatus")
        let old = try JSONDecoder().decode(ScanHistoryEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.smartScanScopes)
        XCTAssertNil(old.smartScanHealthStatus, "An old history entry cannot claim a health check")
        XCTAssertEqual(old.itemCount, entry.itemCount)
        XCTAssertEqual(old.date, entry.date)
    }

    nonisolated private static func emptyStorageAnalysis(_ target: StorageMapScanTarget) -> StorageMapAnalysisResult {
        StorageMapAnalysisResult(target: target, volumeTotalBytes: 100, volumeAvailableBytes: 100,
            inspectedItemCount: 0, omittedItemCount: 0, scanSeconds: 0.1,
            index: StorageMapAnalysisIndex(rootPath: target.path, rootVolumeIdentifier: nil,
                directories: [target.path: StorageMapDirectoryAggregate()], childrenByDirectory: [target.path: []],
                blockedDirectoryPaths: [], duplicateFilePaths: []),
            rootSnapshot: StorageMapDirectorySnapshot(path: target.path, title: target.title,
                entries: [], measuredBytes: 0, inspectedItemCount: 0, omittedEntryCount: 0, isComplete: true))
    }

    private func selection(_ mask: Int) -> Set<SmartScanScope> {
        Set(SmartScanScope.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
    }
    private func finished(_ store: ScanStore) async throws -> ScanSession {
        let deadline = Date().addingTimeInterval(5)
        while store.isScanning || store.cleanupScanSession == nil {
            guard Date() < deadline else { throw ScopeProbeError.didNotFinish }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try XCTUnwrap(store.cleanupScanSession)
    }
    nonisolated fileprivate static var rules: CleanupRuleSet {
        CleanupRuleSet(schemaVersion: 2, rulesVersion: "scope-fixture-v1",
            rules: ["system", "developer", "downloads", "mail", "applications"].map { category in
                let cleanup = category == "system" || category == "developer"
                return CleanupRule(id: "fixture.\(category)", selectionPolicyVersion: 1,
                    categoryID: category, categoryTitleKey: "cleanup.category.\(category)",
                    titleKey: "cleanup.rule.userCaches.title",
                    root: CleanupRuleRoot(kind: .homeRelative, path: "Fixture/\(category)"),
                    maximumDepth: 1, minimumAgeDays: 0, minimumBytes: 1,
                    include: CleanupRuleMatch(entryKinds: [.regularFile], extensions: [],
                        nameMatcher: CleanupNameMatcher(mode: .any, values: [])),
                    exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
                    cloudPolicy: .skipPlaceholder, risk: cleanup ? .safe : .reviewOnly,
                    recommendation: cleanup ? .recommended : .optional,
                    defaultSelection: cleanup ? .selected : .unselected,
                    executionEligibility: cleanup ? .eligible : .eligibleAfterReview,
                    measurementRequirement: .complete, allowsManualSelection: true,
                    action: cleanup ? .moveToTrash : .moveToTrashAfterReview,
                    requiredClosedBundleIDs: [], reasonKey: "cleanup.rule.userCaches.reason")
            })
    }
}

private actor ScopeWorkspaceCalls {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private enum ScopeProbeError: Error { case unavailable, didNotFinish }
private struct ScopeUnusedHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot { throw CancellationError() }
}
private struct ScopeEmptyHistory: ScanStoreHistoryLoading {
    func load() async -> ScanStoreHistorySnapshot {
        ScanStoreHistorySnapshot(scanHistory: ScanHistorySummary(entries: []), cleanupHistory: CleanupHistorySummary(entries: []))
    }
}
private struct ScopeSeededHistory: ScanStoreHistoryLoading {
    let summary: ScanHistorySummary
    func load() async -> ScanStoreHistorySnapshot {
        ScanStoreHistorySnapshot(scanHistory: summary, cleanupHistory: CleanupHistorySummary(entries: []))
    }
}
private actor ScopeRecordingScanner {
    let rules: CleanupRuleSet
    let home: URL
    var calls: [CleanupScanRequest] = []
    var executedRuleIDs: [String] = []
    init(rules: CleanupRuleSet, home: URL) { self.rules = rules; self.home = home }
    func scan(_ request: CleanupScanRequest, progress: CleanupScanProgressHandler) async throws -> ScanSession {
        calls.append(request)
        let active = CleanupScanOperations.scopedRuleSet(rules,
            includedCategoryIDs: request.includedCategoryIDs, includedRuleIDs: request.includedRuleIDs)
        let id = ScanSessionID()
        var categories: [CleanupScanCategory] = []
        for (index, rule) in active.rules.enumerated() {
            executedRuleIDs.append(rule.id)
            let url = home.appendingPathComponent("Fixture/\(rule.categoryID)/sample.dat")
            let candidate = ScanCandidate(id: ScanCandidateID(stableKey: rule.id), sessionID: id,
                ruleID: rule.id, ruleSelectionPolicyVersion: rule.selectionPolicyVersion,
                categoryID: rule.categoryID, categoryTitle: rule.categoryID, subcategoryTitle: rule.id,
                sourceURL: url, allowedRootURL: home,
                snapshot: FileSnapshot(identity: FileIdentity(deviceID: 92, inode: UInt64(index + 1),
                    entryKind: .regularFile, creationTimeNanoseconds: 1), standardizedPath: url.path,
                    volumeIdentifier: "scope-fixture", logicalSizeBytes: 4096, allocatedSizeBytes: 4096,
                    modificationTimeNanoseconds: 1, isWritableVolume: true, isCloudItem: false,
                    isCloudPlaceholder: false, hasSymbolicLinkComponent: false),
                risk: rule.risk, recommendation: CleanupRecommendation(level: rule.recommendation,
                    reasonCode: "fixture", evidenceCodes: []), defaultSelection: rule.defaultSelection,
                executionEligibility: rule.executionEligibility, measurementCompleteness: .complete,
                isManuallySelectable: true, action: rule.action, requiredClosedBundleIDs: [], reason: "fixture")
            categories.append(CleanupScanCategory(id: rule.categoryID, title: rule.categoryID,
                subcategories: [CleanupScanSubcategory(id: rule.id, title: rule.id, risk: rule.risk,
                    recommendation: rule.recommendation, reason: "fixture", candidates: [candidate])]))
            await progress(CleanupScanProgress(phase: .enumerating, currentRuleID: rule.id,
                currentRuleTitle: rule.id, completedRuleCount: index + 1, totalRuleCount: active.rules.count,
                discoveredItemCount: index + 1, discoveredBytes: Int64(index + 1) * 4096, groups: []))
        }
        return ScanSession(id: id, rulesVersion: rules.rulesVersion, startedAt: Date(), completedAt: Date(),
            outcome: .complete, categories: categories, issues: [], permissions: [],
            metrics: ScanMetrics(visitedEntryCount: active.rules.count, candidateCount: active.rules.count,
                deduplicatedIdentityCount: 0, estimatedCandidateBytes: Int64(active.rules.count) * 4096, duration: 0.1),
            includedCategoryIDs: request.includedCategoryIDs, includedRuleIDs: request.includedRuleIDs)
    }
}
private actor ScopeHealthGate {
    private var released = false
    func probe() async throws -> ComputerHealthSnapshot {
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        return ScopeRecordingHealthProbe.snapshot
    }
    func release() { released = true }
}
private actor ScopeRecordingHealthProbe {
    var diskCalls = 0
    var batteryCalls = 0
    func probe() -> ComputerHealthSnapshot { diskCalls += 1; batteryCalls += 1; return Self.snapshot }
    nonisolated static var snapshot: ComputerHealthSnapshot {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        return ComputerHealthSnapshot(generatedAt: date,
            disk: DiskHealthSnapshot(availability: .available, status: .healthy, smartStatus: .verified,
                isTRIMEnabled: true, fileSystem: "APFS", availableBytes: 400, summaryText: nil, checkedAt: date),
            capacity: CapacityTrendSnapshot(availability: .available, status: .healthy, totalBytes: 1000,
                availableBytes: 400, availableForImportantUsageBytes: 500, sevenDayDeltaBytes: 0, recordedAt: date),
            backup: TimeMachineSnapshot(availability: .available, status: .healthy, destinationState: .configured,
                isRunning: false, latestLocalSnapshot: date, latestCompleteBackup: date,
                completeBackupAvailability: .available, summaryText: nil, checkedAt: date),
            stability: StabilitySummary(availability: .available, status: .healthy, crashCount: 0, hangCount: 0,
                unexpectedRestartCount: 0, filesExamined: 0, windowStart: date, generatedAt: date),
            battery: BatteryHealthSnapshot(availability: .available, status: .healthy, currentChargePercent: 75,
                isCharging: false, maximumCapacityPercent: 96, cycleCount: 88, condition: .normal,
                batteryPowerMode: .automatic, adapterPowerMode: .automatic, guidance: BatteryGuidance(kind: .none), sampledAt: date))
    }
}
#endif
