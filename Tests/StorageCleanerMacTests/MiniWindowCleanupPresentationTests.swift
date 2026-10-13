import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MiniWindowCleanupPresentationTests: XCTestCase {
    func testHealthNotRequestedIsRenderedAsOneTextLineInHistory() async throws {
        let entry = ScanHistoryService.entry(from: fixture().withSmartScan(scopes: [.cleanupCandidates], health: nil))
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = MiniWindowLogicLanguageScope(language)
            defer { languageScope.restore() }
            let mounted = CleanupAccessibilityReadbackHost(view: ScanHistoryHealthStatusLine(entry: entry),
                width: 312, testCase: self)
            defer { mounted.close() }
            let snapshot = try await mounted.settledSnapshot(requiringValueLabels: [], context: "history health status")
            XCTAssertTrue(snapshot.visibleText.contains(L10n.text("未做健康检查", "Health check not performed")), snapshot.description)
        }
        let settings = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("lastScanAt: scanHistorySummary.latestScanAt"), "The settings reminder uses the tested date")
        XCTAssertTrue(settings.contains("ScanHistoryHealthStatusLine(entry: entry)"))
        let line = try XCTUnwrap(settings.components(separatedBy: "struct ScanHistoryHealthStatusLine: View {").last)
            .components(separatedBy: "private extension NSRect")[0]
        XCTAssertTrue(line.contains("Text(L10n.text("))
        XCTAssertTrue(line.contains("文件扫描 · "))
        XCTAssertTrue(line.contains("status.title"))
        XCTAssertTrue(line.contains(".lineLimit(1)"))
        XCTAssertFalse(line.contains("Image("))
        XCTAssertFalse(line.contains("Label("))
    }

    func testInMemorySmartScanUsesResultsTotalsAndD47RowsInBothLanguages() throws {
        let session = fixture()
        let details = MiniWindowCleanupDetails(session: session)
        let totals = CleanupScanTierTotals(categories: session.categories)
        let defaultIDs = CleanupSelection.defaults(in: session).selectedCandidateIDs
        XCTAssertEqual(details.safeBytes, totals.safeBytes)
        XCTAssertEqual(details.safeCount, totals.safe.count)
        XCTAssertEqual(details.safeCount, 6, "The risk card still counts the running owner's green row")
        XCTAssertEqual(details.defaultCount, defaultIDs.count)
        XCTAssertEqual(details.defaultCount, 5, "D47 includes unknown owners, recent logs and optional green rows")
        XCTAssertEqual(details.items.map(\.id), totals.safe.filter { defaultIDs.contains($0.id) }.sorted { $0.estimatedSizeBytes > $1.estimatedSizeBytes }.prefix(4).map(\.id))
        XCTAssertEqual(details.items.map { $0.sourceURL.lastPathComponent }, ["cache-6", "cache-5", "cache-4", "cache-2"])
        XCTAssertFalse(details.items.contains { $0.isOwnerRunning || $0.risk != .safe || $0.action.permanentlyDeletes })

        // A stale, unrelated history must not override the session now in the
        // main window. Missing history must not hide a scoped scan's session.
        let histories: [LastScanStatusSummary?] = [nil, status(for: fixture(candidates: []))]
        for history in histories {
            let presentation = MiniWindowCleanupPresentation.resolve(session: session, details: details, history: history)
            XCTAssertEqual(presentation.source, .session)
            for language in [AppLanguage.zhHans, .english] {
                let scope = MiniWindowLogicLanguageScope(language)
                defer { scope.restore() }
                XCTAssertEqual(presentation.title, L10n.text("可安全清理", "Safe Cleanup"))
                XCTAssertEqual(presentation.bytesText, ByteFormat.string(totals.safeBytes))
                XCTAssertEqual(presentation.countText, L10n.text("6 项", "6 items"))
                XCTAssertEqual(presentation.actionableCountText, "5", "Count all default rows, not the four-row preview")
                XCTAssertEqual(presentation.actionableDetail, L10n.text("默认可清理", "Default Cleanup Items"))
                XCTAssertEqual(presentation.notice, L10n.text("默认可清理 5 项。在主窗口确认。", "5 default cleanup items. Confirm in the main window."))
                XCTAssertFalse(presentation.notice.contains(L10n.text("重新扫描", "Rescan")))
                let lowerBound = try XCTUnwrap(details.items.first { $0.measurementCompleteness.isLowerBound })
                XCTAssertEqual(CleanupMeasurementPresentation.value(lowerBound),
                               L10n.text("至少 \(ByteFormat.string(lowerBound.estimatedSizeBytes))", "At least \(ByteFormat.string(lowerBound.estimatedSizeBytes))"))
            }
        }
    }

    func testHistoryOnlyStatesShowTheScanDateAndAskForRescanOnlyWhenThereAreItems() {
        for hasItems in [true, false] {
            let session = fixture(candidates: hasItems ? nil : [])
            let history = status(for: session)
            let presentation = MiniWindowCleanupPresentation.resolve(session: nil, details: nil, history: history)
            XCTAssertEqual(presentation.source, .history)
            XCTAssertNil(presentation.details)
            XCTAssertEqual(presentation.actionableCountText, "…", "A summary does not establish loaded action rows")
            for language in [AppLanguage.zhHans, .english] {
                let scope = MiniWindowLogicLanguageScope(language)
                defer { scope.restore() }
                let time = session.completedAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))
                XCTAssertEqual(presentation.title, L10n.text("上次扫描 · \(time)", "Last Scan · \(time)"))
                XCTAssertEqual(presentation.bytesText, ByteFormat.string(history.entry.greenBytes))
                XCTAssertEqual(presentation.countText, L10n.text("\(history.entry.greenCount) 项", "\(history.entry.greenCount) items"))
                XCTAssertEqual(presentation.actionableDetail, hasItems ? L10n.text("需重新扫描", "Rescan Required") : L10n.text("历史摘要", "Scan Summary"))
                XCTAssertEqual(presentation.notice, hasItems
                    ? L10n.text("仅保留扫描摘要。清理前请重新扫描。", "Only the scan summary is saved. Rescan before cleanup.")
                    : L10n.text("仅保留扫描摘要。上次没有绿色清理项。", "Only the scan summary is saved. The last scan found no green items."))
            }
        }
    }

    func testNoScanSaysFirstScanWithoutPretendingToHaveHistoryOrZeroItems() {
        let presentation = MiniWindowCleanupPresentation.resolve(session: nil, details: nil, history: nil)
        XCTAssertEqual(presentation.source, .empty)
        XCTAssertNil(presentation.details)
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(presentation.title, L10n.text("尚未扫描", "Not Scanned Yet"))
            XCTAssertEqual(presentation.bytesText, "…")
            XCTAssertEqual(presentation.countText, L10n.text("等待扫描", "Waiting for Scan"))
            XCTAssertEqual(presentation.actionableCountText, "…")
            XCTAssertEqual(presentation.actionableDetail, L10n.text("等待首次扫描", "Waiting for First Scan"))
            XCTAssertEqual(presentation.notice, L10n.text("先在主窗口扫描，再查看清理项。", "Scan in the main window to see cleanup items."))
        }
    }

    func testEmptyAndRunningOwnerOnlySessionsAreLoadedWithoutARescanWarning() {
        for candidates in [[], [candidate(3, running: true)]] {
            let session = fixture(candidates: candidates)
            let details = MiniWindowCleanupDetails(session: session)
            let presentation = MiniWindowCleanupPresentation.resolve(session: session, details: details, history: nil)
            XCTAssertEqual(presentation.source, .session)
            XCTAssertTrue(details.items.isEmpty)
            XCTAssertEqual(presentation.actionableCountText, "0")
            for language in [AppLanguage.zhHans, .english] {
                let scope = MiniWindowLogicLanguageScope(language)
                defer { scope.restore() }
                XCTAssertEqual(presentation.title, L10n.text("可安全清理", "Safe Cleanup"))
                XCTAssertEqual(presentation.actionableDetail, L10n.text("无默认项目", "No Default Items"))
                XCTAssertEqual(presentation.notice, candidates.isEmpty
                    ? L10n.text("本次扫描没有绿色清理项。", "This scan found no green cleanup items.")
                    : L10n.text("本次扫描没有默认可清理项。在主窗口查看。", "No default cleanup items. Review in the main window."))
            }
        }
    }

    func testPreparationAndCancelledSessionsNeverExposeOldOrExecutableRows() {
        let session = fixture()
        let preparation = MiniWindowCleanupPresentation.resolve(session: session, details: nil, history: status(for: session))
        let unrelated = fixture(id: ScanSessionID(rawValue: UUID()))
        XCTAssertEqual(MiniWindowCleanupPresentation.resolve(session: session, details: MiniWindowCleanupDetails(session: unrelated), history: nil).source, .preparing)
        let cancelled = fixture(outcome: .cancelled)
        let cancelledDetails = MiniWindowCleanupDetails(session: cancelled)
        XCTAssertTrue(cancelledDetails.items.isEmpty)
        XCTAssertEqual(cancelledDetails.defaultCount, 0)
        let presentation = MiniWindowCleanupPresentation.resolve(session: cancelled, details: cancelledDetails, history: status(for: session))
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(preparation.title, L10n.text("可安全清理", "Safe Cleanup"))
            XCTAssertEqual(preparation.countText, L10n.text("正在整理", "Preparing Details"))
            XCTAssertEqual(preparation.notice, L10n.text("正在整理扫描明细…", "Preparing scan details…"))
            XCTAssertEqual(presentation.title, L10n.text("扫描已取消", "Scan Cancelled"))
            XCTAssertEqual(presentation.notice, L10n.text("扫描已取消。重新扫描后再确认清理。", "Scan cancelled. Rescan before confirming cleanup."))
        }
    }

    func testReopeningUsesSharedCacheAndSameIDChangesInvalidateIt() async throws {
        let cache = MenuBarDerivedCache()
        let model = MiniWindowCleanupDetailsModel(cache: cache)
        let session = fixture()
        defer { model.stop() }
        model.start(session)
        let first = try await waitForDetails(model)
        XCTAssertEqual(first.defaultCount, 5)
        var stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 1)
        model.stop()
        XCTAssertEqual(model.details?.items.map(\.id), first.items.map(\.id), "D39 retains the bounded delivery while hidden")
        model.start(session)
        _ = try await waitForDetails(model)
        XCTAssertEqual(model.details?.items.map(\.id), first.items.map(\.id))
        stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 1, "Reopening reuses the prepared projection")

        let ownersChanged = session.mappingCandidates { candidate in
            var changed = candidate
            changed.runningOwnerBundleIdentifiers = []
            return changed
        }
        XCTAssertNotEqual(MiniWindowCleanupDetails.cacheKey(for: session), MiniWindowCleanupDetails.cacheKey(for: ownersChanged))
        model.request(ownersChanged)
        let ownerDetails = try await waitForDetails(model)
        XCTAssertEqual(ownerDetails.defaultCount, 6)

        let removed = ownersChanged.mappingCandidates { $0.sourceURL.lastPathComponent == "cache-1" ? nil : $0 }
        XCTAssertNotEqual(MiniWindowCleanupDetails.cacheKey(for: ownersChanged), MiniWindowCleanupDetails.cacheKey(for: removed))
        model.request(removed)
        let updated = try await waitForDetails(model)
        XCTAssertEqual(updated.safeCount, 5)
        XCTAssertFalse(updated.items.contains { $0.sourceURL.lastPathComponent == "cache-1" })
        stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 3)
        XCTAssertEqual(stats.entries, 1, "Existing cache keeps only the latest revision of this family")
    }

    func testHiddenPageAndReplacementWithNilCannotDeliverAQueuedProjection() async {
        let cache = MenuBarDerivedCache()
        let model = MiniWindowCleanupDetailsModel(cache: cache)
        var stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 0, "Creating the panel's model does no candidate work")
        model.start(fixture())
        model.stop()
        XCTAssertFalse(model.isVisible)
        model.request(fixture())
        XCTAssertFalse(model.isPreparing, "Hidden publications cannot create a worker")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.details)
        stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 0)
        model.start(fixture())
        model.request(nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.details)
        stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 0)
    }

    func testLegacyScanStillUsesStorageItemsAndOriginalTitlesAndNotices() throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try ScanStore.makeForTests(for: self, historyLoader: EmptyHistoryLoader(), scanHistoryDefaults: defaults,
                              cleanupFeatureConfiguration: .legacy, cleanupPreferences: defaults,
                              cleanReportLoader: { [] }, interruptedOperationReconciler: { [] })
        let history = status(for: fixture()).entry
        store.scanHistorySummary = ScanHistorySummary(entries: [history])
        let view = MenuBarAdvancedStatusView(
            store: store, computerHealthStore: ComputerHealthStore(probe: UnusedHealthProbe(),
                batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController()),
            panelSettingsState: MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults),
            panelCoordinator: GeekPanelCoordinator(initialSection: .cleanup), initialSection: .cleanup,
            fanControl: TestOperationFactory(for: self).fanControl(defaults: defaults)
        )
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            store.result = nil
            XCTAssertEqual(view.cleanupSummaryTitle, L10n.text("上次扫描摘要", "Last Scan Summary"))
            XCTAssertTrue(view.actionableCleanupItems.isEmpty)
            // D64 keeps safety copy to one line: a cached summary cannot
            // authorize cleanup; a new scan is required first.
            XCTAssertEqual(view.staleCleanupSummaryNotice,
                           L10n.text("需重新扫描后才能清理", "Rescan before cleanup"))
            XCTAssertEqual(view.cleanupActionableDetail, L10n.text("需重新扫描", "Rescan Required"))
            XCTAssertEqual(view.cleanupPageBytesText, ByteFormat.string(history.greenBytes))
            XCTAssertEqual(view.cleanupPageCountText, L10n.text("6 项", "6 items"))
            let items = (1...6).map { legacyItem($0) }
            store.result = ScanResult(generatedAt: Date(), scanSeconds: 1, system: system(), groups: [], items: items, deniedPaths: [])
            XCTAssertEqual(view.cleanupPageBytesText, ByteFormat.string(history.greenBytes),
                           "Legacy page rows do not replace the global Smart Scan number")
            let expected = Array(store.items(for: .green).filter(\.canMoveToTrash).prefix(4))
            XCTAssertEqual(view.actionableCleanupItems, expected)
            XCTAssertEqual(view.cleanupSummaryTitle, L10n.text("可安全清理", "Safe Cleanup"))
            XCTAssertEqual(view.cleanupActionableCountText, "4", "Legacy preview count remains unchanged")
            XCTAssertEqual(view.cleanupActionableDetail, L10n.text("已加载明细", "Details Loaded"))
            store.result = nil
            store.scanHistorySummary = ScanHistorySummary(entries: [])
            XCTAssertEqual(view.cleanupSummaryTitle, L10n.text("尚未扫描", "Not Scanned Yet"))
            XCTAssertEqual(view.staleCleanupSummaryNotice, L10n.text("当前没有已加载的可操作清理项。", "No actionable cleanup items are currently loaded."))
            store.scanHistorySummary = ScanHistorySummary(entries: [history])
        }
    }

    func testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons() throws {
        let page = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekCleanupView.swift")
        let components = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift")
        let panel = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let root = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(page.contains("source: MiniWindowCleanupSource(store: store)"))
        XCTAssertTrue(page.contains(".onAppear { model.start(source) }"))
        XCTAssertFalse(page.contains(".onReceive("), "The model owns one visible subscription set")
        XCTAssertTrue(page.contains(".onDisappear { model.stop() }"))
        XCTAssertTrue(page.contains("ForEach(presentation.details?.items ?? [])"))
        XCTAssertTrue(page.contains("let renderedNotice = presentation.notice"))
        XCTAssertTrue(page.contains("Text(renderedNotice)"))
        XCTAssertTrue(page.contains("let renderedName = candidate.sourceURL.lastPathComponent"))
        XCTAssertTrue(page.contains("Text(renderedName)"))
        XCTAssertTrue(page.contains("let renderedSize = CleanupMeasurementPresentation.value(candidate)"))
        XCTAssertTrue(page.contains("Text(renderedSize)"))
        XCTAssertFalse(components.contains("cleanupPresentation"), "Dormant simple pages retain legacy adapters")
        XCTAssertFalse(components.contains("store.cleanupFeatureConfiguration.mode != .legacy { return"))
        let rowStart = try XCTUnwrap(page.range(of: "struct AdvancedSmartCleanupItemRow: View")).lowerBound
        let smartRow = String(page[rowStart...])
        XCTAssertTrue(smartRow.contains(".fixedSize()"), "The size column must retain its intrinsic width")
        XCTAssertTrue(page.contains("model.isVisible ? model.presentation"))
        XCTAssertTrue(page.contains("model.presentation(beforeStarting: source.current())"))
        XCTAssertFalse(page.contains("eraseToAnyPublisher()"))
        XCTAssertTrue(page.contains("value: presentation.bytesText"))
        XCTAssertTrue(page.contains("value: presentation.countText"))
        XCTAssertTrue(page.contains("value: presentation.actionableCountText, detail: presentation.actionableDetail"))
        XCTAssertTrue(panel.contains("value: cleanupActionableCountText, detail: cleanupActionableDetail"))
        XCTAssertTrue(root.contains("@State var cleanupDetailsModel = MiniWindowCleanupDetailsModel()"))
        XCTAssertFalse(root.contains("@StateObject var cleanupDetailsModel"), "Detail publications belong to the cleanup host")
        XCTAssertTrue(page.contains("@ObservedObject var model: MiniWindowCleanupDetailsModel"))
        XCTAssertFalse(root.contains("cleanupDetailsModel.request("), "Never prepare during root/overview construction")
        for filter in ["green", "largeFiles", "memory"] { XCTAssertTrue(page.contains("openApp(filter: .\(filter))")) }
        XCTAssertEqual(page.components(separatedBy: "AppButton(").count - 1, 3)
        for forbidden in ["requestV2Cleanup(", "confirmV2Cleanup(", "moveToTrash(", "startScan(", "setCleanupCandidate("] {
            XCTAssertFalse(page.contains(forbidden), forbidden)
        }
        let action = try MiniWindowLogicFixtures.section(root, from: "func openApp(filter: ReviewFilter) {", to: "private struct MenuBarObservedObjectBoundary")
        XCTAssertTrue(action.contains("store.showFilter(filter)"))
        XCTAssertTrue(action.contains("dismissPanel()"))
        XCTAssertTrue(action.contains("requestMainWindow()"))
    }

    func testSameKeyRefreshAndReopenRetainTheDeliveryWithoutRebuilding() async throws {
        let cache = MenuBarDerivedCache()
        let grace = CleanupTestGate()
        let model = MiniWindowCleanupDetailsModel(cache: cache, waitForUpdateGrace: { await grace.wait() })
        let session = fixture()
        defer { model.stop() }
        model.start(session)
        let first = try await waitForDetails(model)
        var updatingPublications = 0
        let updatingSubscription = model.$isUpdating.sink { if $0 { updatingPublications += 1 } }
        defer { updatingSubscription.cancel() }
        let deliveredKey = try XCTUnwrap(model.deliveredKey)
        let layoutRevision = model.layoutRevision
        var publications = 0
        var blankPublications = 0
        let subscription = model.$details.dropFirst().sink {
            publications += 1
            if $0 == nil { blankPublications += 1 }
        }
        defer { subscription.cancel() }
        model.request(session)
        XCTAssertEqual(model.details?.items.map(\.id), first.items.map(\.id))
        XCTAssertFalse(model.isUpdating, "Fast validation stays inside the notice grace")
        let updating = MiniWindowCleanupPresentation.resolve(session: session, details: model.details,
                                                             history: nil, isUpdating: model.isUpdating)
        XCTAssertEqual(updating.source, .session)
        XCTAssertEqual(updating.actionableDetail, L10n.text("默认可清理", "Default Cleanup Items"))
        _ = try await waitForDetails(model)
        XCTAssertEqual(model.deliveredKey, deliveredKey)
        XCTAssertEqual(model.layoutRevision, layoutRevision, "Same-key preparation cannot request a new height")
        XCTAssertFalse(model.isUpdating)
        model.stop()
        XCTAssertNotNil(model.details, "Hide only cancels work")
        model.start(session)
        XCTAssertNotNil(model.details, "The reopening frame has the previous result synchronously")
        XCTAssertFalse(model.isUpdating)
        _ = try await waitForDetails(model)
        XCTAssertEqual(model.layoutRevision, layoutRevision, "Same-key reopening cannot request a new height")
        XCTAssertEqual(blankPublications, 0)
        XCTAssertEqual(publications, 0, "Same key must not republish or rebuild the details")
        await grace.release()
        await drainLayout()
        XCTAssertEqual(updatingPublications, 0, "A finished fast check cancels its delayed notice")
        let stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 1)
    }

    func testPreAppearPageUsesCurrentInputsWithoutSubscriptionsOrCandidateWork() async throws {
        let cache = MenuBarDerivedCache()
        let model = MiniWindowCleanupDetailsModel(cache: cache)
        let inputs = CleanupTestInputs(session: fixture())
        let page = GeekSmartCleanupPage(model: model, source: inputs.source,
            diskTile: smartContent(.resolve(session: nil, details: nil, history: nil)).tiles[1],
            diskAvailableText: "560 GB", showsExtendedDetails: true, actions: EmptyView())
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            inputs.session.send(fixture())
            inputs.scanning.send(false)
            inputs.history.send(.init(entries: []))
            XCTAssertEqual(page.presentation.source, .preparing)
            XCTAssertEqual(page.presentation.title, L10n.text("可安全清理", "Safe Cleanup"))
            XCTAssertEqual(page.presentation.notice, L10n.text("正在整理扫描明细…", "Preparing scan details…"))
            inputs.session.send(nil)
            inputs.scanning.send(true)
            XCTAssertEqual(page.presentation.actionableDetail, L10n.text("扫描中…", "Scanning…"))
            XCTAssertEqual(page.presentation.notice, L10n.text("扫描中…等待本次结果。", "Scanning… Wait for the new results."))
            inputs.scanning.send(false)
            let history = status(for: fixture()).entry
            inputs.history.send(.init(entries: [history]))
            XCTAssertEqual(page.presentation.source, .history)
            XCTAssertTrue(page.presentation.title.hasPrefix(L10n.text("上次扫描 · ", "Last Scan · ")))
            XCTAssertEqual(page.presentation.notice,
                L10n.text("仅保留扫描摘要。清理前请重新扫描。", "Only the scan summary is saved. Rescan before cleanup."))
            inputs.history.send(.init(entries: []))
            XCTAssertEqual(page.presentation.source, .empty)
            XCTAssertEqual(page.presentation.title, L10n.text("尚未扫描", "Not Scanned Yet"))
        }
        XCTAssertEqual(inputs.subscriptions, [0, 0, 0])
        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(model.layoutRevision, 0)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 0)
    }

    func testSharedBodiesUseReleaseIdentityProbeModifiers() throws {
        let page = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekCleanupView.swift")
        let shared = try MiniWindowLogicFixtures.section(page,
            from: "struct GeekSmartCleanupContent", to: "#if DEBUG\nprivate extension View")
        XCTAssertFalse(shared.contains("#if"), "View bodies must have one implementation in Debug and Release")
        let release = try MiniWindowLogicFixtures.section(page,
            from: "#else\n// Private, always-inlined identity modifiers", to: "#endif")
        XCTAssertEqual(release.components(separatedBy: "-> Self { self }").count - 1, 8)
        for symbol in ["GeekCleanupRenderedField", "GeekCleanupProbeID", "GeometryReader", "Preference", "cleanupRenderedProbe("] {
            // Comments are excluded (the section starts mid-line, after its marker); the Release
            // implementation consists only of identity functions.
            let implementation = release.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
            XCTAssertFalse(implementation.contains(symbol), symbol)
        }
    }

    func testOnlyDeliveredResultKeysOrSessionRemovalAdvanceLayoutRevision() async throws {
        let work = CleanupTestGate(passing: 1)
        let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache(), fingerprint: { session in
            await work.wait()
            return MiniWindowCleanupDetails.cacheKey(for: session)
        })
        defer { model.stop() }
        let session = fixture(candidates: [candidate(1)])
        model.start(session)
        _ = try await waitForDetails(model)
        let firstRevision = model.layoutRevision
        let later = ScanSession(id: session.id, rulesVersion: session.rulesVersion,
            startedAt: session.startedAt, completedAt: session.completedAt.addingTimeInterval(1),
            outcome: session.outcome, categories: session.categories, issues: session.issues,
            permissions: session.permissions, metrics: session.metrics, system: session.system,
            smartScanScopes: session.smartScanScopes)
        XCTAssertTrue(later.coversCleanupCandidates)
        model.request(later)
        try await waitUntil("Changed completion time reaches preparation") { await work.arrivalCount == 2 }
        XCTAssertEqual(model.layoutRevision, firstRevision, "A pending projection cannot report a new height")
        await work.release()
        _ = try await waitForDetails(model)
        XCTAssertEqual(model.layoutRevision, firstRevision + 1)
        model.request(later)
        _ = try await waitForDetails(model)
        XCTAssertEqual(model.layoutRevision, firstRevision + 1)
        model.request(fixture(id: ScanSessionID(rawValue: UUID()), candidates: [candidate(1)]))
        _ = try await waitForDetails(model)
        XCTAssertEqual(model.layoutRevision, firstRevision + 2)
        model.request(nil)
        XCTAssertEqual(model.layoutRevision, firstRevision + 3)
        model.request(nil)
        XCTAssertEqual(model.layoutRevision, firstRevision + 3, "Repeated nil is the same state")
    }

    func testSameSessionContentChangesKeepOldRowsUntilTheLatestDelivery() async throws {
        let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
        let session = fixture()
        defer { model.stop() }
        model.start(session)
        let first = try await waitForDetails(model)
        let changed = session.mappingCandidates { $0.sourceURL.lastPathComponent == "cache-6" ? nil : $0 }
        model.request(changed)
        XCTAssertEqual(model.details?.items.map(\.id), first.items.map(\.id))
        XCTAssertFalse(model.isUpdating, "Old rows remain normal until the grace expires")
        XCTAssertEqual(MiniWindowCleanupPresentation.resolve(session: changed, details: model.details,
                                                             history: nil, isUpdating: true).source, .session)
        let latest = try await waitForDetails(model)
        XCTAssertFalse(latest.items.contains { $0.sourceURL.lastPathComponent == "cache-6" })
        XCTAssertFalse(model.isUpdating)
    }

    func testRetainedDeliverySurvivesSharedCacheEvictionWithoutIncreasingItsBudget() async throws {
        let cache = MenuBarDerivedCache(pageLimit: 1)
        let model = MiniWindowCleanupDetailsModel(cache: cache)
        let session = fixture()
        defer { model.stop() }
        model.start(session)
        let delivered = try await waitForDetails(model)
        let other = MenuBarDerivedKey(page: "cpu", kind: "chart", revision: "1", configuration: "fixture")
        let _: Int = await cache.value(for: other, cost: 8) { 42 }
        let before = await cache.statistics()
        XCTAssertEqual(before.pages, 1)
        XCTAssertEqual(before.entries, 1)
        XCTAssertEqual(before.builds, 2)
        model.stop()
        model.start(session)
        XCTAssertEqual(model.details?.items.map(\.id), delivered.items.map(\.id))
        _ = try await waitForDetails(model)
        let after = await cache.statistics()
        XCTAssertEqual(after.builds, before.builds, "A retained delivery does not refill or churn the shared LRU")
        XCTAssertEqual(after.pages, 1)
    }

    func testSessionIdentityDateOrOutcomeChangesUsePreparationInsteadOfOldRows() {
        let session = fixture()
        let details = MiniWindowCleanupDetails(session: session)
        let newDate = ScanSession(id: session.id, rulesVersion: session.rulesVersion,
            startedAt: session.startedAt, completedAt: session.completedAt.addingTimeInterval(1),
            outcome: session.outcome, categories: session.categories, issues: session.issues,
            permissions: session.permissions, metrics: session.metrics, system: session.system,
            smartScanScopes: session.smartScanScopes)
        XCTAssertTrue(newDate.coversCleanupCandidates)
        for changed in [fixture(id: ScanSessionID(rawValue: UUID())), newDate, fixture(outcome: .cancelled)] {
            let presentation = MiniWindowCleanupPresentation.resolve(session: changed, details: details,
                                                                     history: nil, isUpdating: true)
            XCTAssertEqual(presentation.source, .preparing)
            XCTAssertNil(presentation.details)
            XCTAssertFalse(presentation.isUpdating)
            XCTAssertEqual(presentation.bytesText, "…")
            XCTAssertEqual(presentation.actionableCountText, "…")
        }
    }

    func testDedicatedSessionArrivalsKeepSmartHistoryOrUnscannedWithoutPreparing() async throws {
        let smart = fixture(candidates: [candidate(1)])
        let entry = ScanHistoryService.entry(from: smart)
        for hasSmartHistory in [false, true] {
            let history = ScanHistorySummary(entries: hasSmartHistory ? [entry] : [])
            let inputs = CleanupTestInputs(session: hasSmartHistory ? smart : nil)
            inputs.history.send(history)
            let cache = MenuBarDerivedCache()
            let model = MiniWindowCleanupDetailsModel(cache: cache)
            defer { model.stop() }
            model.start(inputs.source)
            if hasSmartHistory {
                _ = try await waitForDetails(model)
                XCTAssertEqual(model.presentation.source, .session)
            } else {
                XCTAssertEqual(model.presentation.source, .empty)
            }
            let initialRevision = model.layoutRevision
            let expectedSource: MiniWindowCleanupPresentation.Source = hasSmartHistory ? .history : .empty

            for route in [ReviewFilter.green, .devCaches] {
                let dedicated = ScanSession(id: ScanSessionID(), rulesVersion: "dedicated-mini-fixture",
                    startedAt: smart.completedAt.addingTimeInterval(1),
                    completedAt: smart.completedAt.addingTimeInterval(2), outcome: .complete,
                    categories: [], issues: [], permissions: [],
                    metrics: ScanMetrics(visitedEntryCount: 0, candidateCount: 0,
                        deduplicatedIdentityCount: 0, estimatedCandidateBytes: 0, duration: 1),
                    includedCategoryIDs: route == .devCaches ? ["developer"] : nil,
                    includedRuleIDs: route == .green ? ["fixture.cache"] : nil)
                XCTAssertNil(dedicated.smartScanScopes)
                XCTAssertFalse(dedicated.coversCleanupCandidates)
                let opening = model.presentation(beforeStarting: MiniWindowCleanupSnapshot(
                    session: dedicated, isScanning: false, history: history))
                XCTAssertEqual(opening.source, expectedSource)
                XCTAssertEqual(opening.safeBytes, hasSmartHistory ? entry.greenBytes : nil)

                inputs.session.send(dedicated)
                XCTAssertFalse(model.isPreparing, "A specialty scan never prepares global cleanup rows")
                XCTAssertNil(model.session)
                XCTAssertNil(model.details, "Old executable rows must not remain after a different scan")
                XCTAssertEqual(model.presentation.source, expectedSource)
                XCTAssertEqual(model.presentation.safeBytes, hasSmartHistory ? entry.greenBytes : nil)
                XCTAssertEqual(model.presentation.safeCount, hasSmartHistory ? entry.greenCount : nil)
                if hasSmartHistory {
                    XCTAssertEqual(model.presentation.date, smart.completedAt)
                } else {
                    XCTAssertEqual(model.presentation.title, L10n.text("尚未扫描", "Not Scanned Yet"))
                }
                XCTAssertEqual(model.history?.entry.id, hasSmartHistory ? entry.id : nil)
                XCTAssertEqual(model.layoutRevision, initialRevision + (hasSmartHistory ? 1 : 0))
                XCTAssertTrue(model.isInitialLayoutReady)
            }
            let stats = await cache.statistics()
            XCTAssertEqual(stats.builds, hasSmartHistory ? 1 : 0,
                "Specialty sessions do not build global cleanup details")
        }
    }

    func testSizeTiesUseTheMainWindowPathComparator() {
        let first = candidate(1)
        let second = candidate(2, sizeBytes: first.estimatedSizeBytes)
        let details = MiniWindowCleanupDetails(session: fixture(candidates: [second, first]))
        XCTAssertEqual(details.items.map(\.id), [first.id, second.id])
    }

    func testEnglishCountsAndNoticesHaveSingularAndPluralForms() {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        for count in [0, 1, 2] {
            let session = fixture(candidates: (0..<count).map { candidate($0 + 1) })
            let details = MiniWindowCleanupDetails(session: session)
            let presentation = MiniWindowCleanupPresentation.resolve(session: session, details: details, history: nil)
            XCTAssertEqual(presentation.countText, count == 1 ? "1 item" : "\(count) items")
            if count > 0 {
                XCTAssertEqual(presentation.notice, count == 1
                    ? "1 default cleanup item. Confirm in the main window."
                    : "2 default cleanup items. Confirm in the main window.")
            }
            let history = MiniWindowCleanupPresentation.resolve(session: nil, details: nil, history: status(for: session))
            XCTAssertEqual(history.countText, count == 1 ? "1 item" : "\(count) items")
        }
    }

    func testActiveScanDoesNotAskForAnotherScanInHistoryOrEmptyState() {
        for history in [nil, status(for: fixture())] {
            let presentation = MiniWindowCleanupPresentation.resolve(session: nil, details: nil,
                                                                     history: history, isScanning: true)
            for language in [AppLanguage.zhHans, .english] {
                let scope = MiniWindowLogicLanguageScope(language)
                defer { scope.restore() }
                XCTAssertEqual(presentation.actionableDetail, L10n.text("扫描中…", "Scanning…"))
                XCTAssertEqual(presentation.notice, L10n.text("扫描中…等待本次结果。", "Scanning… Wait for the new results."))
            }
        }
    }

    func testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages() throws {
        let session = fixture()
        let details = MiniWindowCleanupDetails(session: session)
        let single = fixture(candidates: [candidate(1)])
        let presentations = [
            MiniWindowCleanupPresentation.resolve(session: single, details: MiniWindowCleanupDetails(session: single), history: nil),
            MiniWindowCleanupPresentation.resolve(session: session, details: details, history: nil),
            MiniWindowCleanupPresentation.resolve(session: nil, details: nil, history: status(for: session)),
            MiniWindowCleanupPresentation.resolve(session: nil, details: nil, history: nil),
            MiniWindowCleanupPresentation.resolve(session: session, details: nil, history: nil),
            MiniWindowCleanupPresentation.resolve(session: nil, details: nil, history: status(for: fixture(candidates: []))),
            MiniWindowCleanupPresentation.resolve(session: session, details: details, history: nil, isUpdating: true),
            MiniWindowCleanupPresentation.resolve(session: nil, details: nil, history: status(for: session), isScanning: true)
        ]
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for presentation in presentations {
                let content = smartContent(presentation)
                // Text cards are read from the native accessibility tree.
                // Metric cells hide their children and expose their input as
                // value/help, so also require a concrete read-only tile input
                // that cannot take GeekMetricCell's unavailable branch.
                let actionableTile = content.tiles[2]
                let actionableMetric = try hostedSnapshot(GeekMetricCell(model: actionableTile, action: nil),
                                                          requiringValueLabels: [actionableTile.title])
                XCTAssertEqual(actionableTile.value, presentation.actionableCountText, actionableMetric.description)
                XCTAssertEqual(actionableTile.detail, presentation.actionableDetail, actionableMetric.description)
                assertAvailableTile(actionableTile, snapshot: actionableMetric)
                assertMetric(actionableMetric, label: actionableTile.title, value: actionableTile.value,
                             detail: presentation.actionableDetail)
                assertNoUnavailable(actionableMetric)

                let safeTile = content.tiles[0]
                let safeMetric = try hostedSnapshot(GeekMetricCell(model: safeTile, action: nil),
                                                    requiringValueLabels: [safeTile.title])
                XCTAssertEqual(safeTile.value, presentation.bytesText, safeMetric.description)
                XCTAssertEqual(safeTile.detail, presentation.countText, safeMetric.description)
                assertAvailableTile(safeTile, snapshot: safeMetric)
                assertMetric(safeMetric, label: safeTile.title, value: safeTile.value, detail: presentation.countText)
                assertNoUnavailable(safeMetric)

                let status = try hostedSnapshot(content.statusCard, width: 720)
                // Compare the first native text element, so the similarly
                // named telemetry label cannot mask the wrong card heading.
                XCTAssertEqual(status.primaryTexts.first, presentation.title, status.description)
                assertAccessible(status, contains: presentation.countText)
                if presentation.safeBytes != nil { assertAccessible(status, contains: presentation.bytesText) }
                // Scope pairs to the actual metric grid; the status card has
                // a same-named heading/telemetry row and its own help text.
                let grid = try hostedSnapshot(GeekMetricSummaryGrid(tiles: content.tiles),
                                              requiringValueLabels: [actionableTile.title, safeTile.title])
                assertMetric(grid, label: actionableTile.title, value: actionableTile.value, detail: presentation.actionableDetail)
                assertMetric(grid, label: safeTile.title, value: safeTile.value, detail: presentation.countText)
                let page = try hostedSnapshot(content)
                assertAccessible(page, contains: presentation.notice)
                assertAccessible(page, contains: presentation.countText)
                assertNoUnavailable(page)
                let fullPage = page.visibleText

                if presentation.source == .session {
                    for candidate in presentation.details?.items ?? [] {
                        assertAccessible(page, contains: candidate.sourceURL.lastPathComponent)
                        let row = try hostedSnapshot(AdvancedSmartCleanupItemRow(candidate: candidate))
                        assertAccessible(row, contains: CleanupMeasurementPresentation.value(candidate))
                    }
                    if presentation.details?.defaultCount == 5 {
                        XCTAssertFalse(fullPage.contains("cache-1"), page.description)
                        XCTAssertFalse(fullPage.contains("cache-3"), page.description)
                    }
                }
                let compact = try hostedSnapshot(smartContent(presentation, extended: false))
                assertAccessible(compact, contains: presentation.notice)
            }
        }
    }

    func testHostedRowsUseTheirNaturalHeightIncludingCancelledAndOneToFourItems() {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        let width: CGFloat = 312
        var heights: [CGFloat] = []
        for count in 0...4 {
            let session = fixture(candidates: (0..<count).map { candidate($0 + 1) })
            let presentation = MiniWindowCleanupPresentation.resolve(session: session,
                details: MiniWindowCleanupDetails(session: session), history: nil)
            let card = NSHostingView(rootView: smartContent(presentation).actionableCard.frame(width: width))
            heights.append(card.fittingSize.height)
            if count > 1 {
                let row = NSHostingView(rootView: AdvancedSmartCleanupItemRow(candidate: candidate(count)).frame(width: width - 12))
                // The real row's measured height, not just a fixed outer frame,
                // must fit before the notice, including the shared row gap.
                XCTAssertEqual(heights[count] - heights[count - 1],
                               row.fittingSize.height + GeekCleanupRowLayout.spacing, accuracy: 1)
                XCTAssertGreaterThanOrEqual(row.fittingSize.height, GeekCleanupRowLayout.minimumHeight)
            }
        }
        XCTAssertGreaterThan(heights[1], heights[0])
        XCTAssertLessThan(heights[1], heights[4] - 2 * GeekCleanupRowLayout.minimumHeight)
        let cancelled = fixture(outcome: .cancelled)
        let cancelledCard = NSHostingView(rootView: smartContent(.resolve(session: cancelled,
            details: MiniWindowCleanupDetails(session: cancelled), history: nil)).actionableCard.frame(width: width))
        XCTAssertEqual(cancelledCard.fittingSize.height, heights[0], accuracy: 1,
                       "A cancelled session has no row reservation")
        let session = fixture()
        let details = MiniWindowCleanupDetails(session: session)
        let prepared = NSHostingView(rootView: smartContent(.resolve(session: session, details: details, history: nil)).frame(width: width))
        let updating = NSHostingView(rootView: smartContent(.resolve(session: session, details: details, history: nil, isUpdating: true)).frame(width: width))
        XCTAssertEqual(updating.fittingSize.height, prepared.fittingSize.height, accuracy: 1)
    }

    func testLayoutSettlesOnlyReadyCurrentOpeningAndRejectsRepeatedOrInvalidMeasurements() {
        let opening = UUID()
        let size = CGSize(width: 312, height: 400)
        func measurement(_ size: CGSize, ready: Bool = true, id: UUID? = nil) -> GeekCleanupNaturalMeasurement {
            .init(visibilityID: id ?? opening, isReady: ready, size: size)
        }
        XCTAssertNil(GeekCleanupLayoutSettlement.accepting(measurement(size, ready: false), for: opening, previous: nil))
        XCTAssertNil(GeekCleanupLayoutSettlement.accepting(measurement(size, id: UUID()), for: opening, previous: nil))
        for invalid in [CGSize.zero, CGSize(width: 312, height: CGFloat.infinity), CGSize(width: -1, height: 20)] {
            XCTAssertNil(GeekCleanupLayoutSettlement.accepting(measurement(invalid), for: opening, previous: nil))
        }
        let settled = GeekCleanupLayoutSettlement.accepting(measurement(size), for: opening, previous: nil)
        XCTAssertEqual(settled?.size, size)
        XCTAssertEqual(GeekCleanupLayoutSettlement.accepting(measurement(CGSize(width: 312, height: 550)),
                       for: opening, previous: settled), settled)
        let changed = GeekCleanupNaturalMeasurement(visibilityID: opening, isReady: true,
            size: CGSize(width: 312, height: 550), revision: 1)
        let grown = GeekCleanupLayoutSettlement.accepting(changed, for: opening, revision: 1, previous: settled)
        XCTAssertEqual(grown?.size, changed.size, "A real result change may settle once in the same opening")
        let shorter = GeekCleanupNaturalMeasurement(visibilityID: opening, isReady: true,
            size: CGSize(width: 312, height: 300), revision: 2)
        let shrunk = GeekCleanupLayoutSettlement.accepting(shorter, for: opening, revision: 2, previous: grown)
        XCTAssertEqual(shrunk?.size, shorter.size)
        XCTAssertEqual(GeekCleanupLayoutSettlement.accepting(changed, for: opening, revision: 1, previous: shrunk), shrunk,
                       "A queued older result cannot roll back the latest settlement")
        let reopened = UUID()
        let newSize = CGSize(width: 312, height: 350)
        XCTAssertEqual(GeekCleanupLayoutSettlement.accepting(measurement(newSize, id: reopened),
                       for: reopened, previous: settled)?.size, newSize)
        let unrestricted = GeekDetailContentMeasurement(section: .cleanup, density: .geek, size: size)
        XCTAssertFalse(unrestricted.canReportSize(smartCleanup: true, cleanupIsVisible: true, cleanupVisibilityID: opening))
        XCTAssertTrue(unrestricted.canReportSize(smartCleanup: false, cleanupIsVisible: false, cleanupVisibilityID: opening),
                      "Other pages and legacy cleanup keep their original measurement")
        let oldRevision = GeekDetailContentMeasurement(section: .cleanup, density: .geek, size: size,
            cleanupReadiness: .init(visibilityID: opening, isReady: true, revision: 1))
        XCTAssertFalse(oldRevision.canReportSize(smartCleanup: true, cleanupIsVisible: true,
            cleanupVisibilityID: opening, cleanupRevision: 2))
        for ready in [false, true] {
            let current = GeekDetailContentMeasurement(section: .cleanup, density: .geek, size: size,
                cleanupReadiness: .init(visibilityID: opening, isReady: ready))
            XCTAssertEqual(current.canReportSize(smartCleanup: true, cleanupIsVisible: true, cleanupVisibilityID: opening), ready)
            XCTAssertFalse(current.canReportSize(smartCleanup: true, cleanupIsVisible: false, cleanupVisibilityID: opening))
            XCTAssertFalse(current.canReportSize(smartCleanup: true, cleanupIsVisible: true, cleanupVisibilityID: reopened))
        }
    }

    #if DEBUG
    func testHostedStableViewportReportsOnceAfterDeliveryAndScrollsLaterLargerResults() async throws {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        let firstSession = fixture(candidates: [candidate(1)])
        let firstContent = smartContentWithActions(.resolve(session: firstSession,
            details: MiniWindowCleanupDetails(session: firstSession), history: nil))
        let firstNaturalSize = NSHostingView(rootView: firstContent.frame(width: 312)).fittingSize
        let gate = CleanupTestGate()
        let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache(), fingerprint: { session in
            await gate.wait()
            return MiniWindowCleanupDetails.cacheKey(for: session)
        })
        let inputs = CleanupTestInputs(session: firstSession)
        let counter = CleanupParentRenderCounter()
        let layout = CleanupPageLayoutRecorder()
        let mounted = CleanupRenderedReadbackHost(view: CleanupRetainingTestHost(
            model: model, source: inputs.source, counter: counter, layout: layout,
            availableHeight: firstNaturalSize.height), width: 312, testCase: self)
        defer { mounted.close(); model.stop() }
        try await mounted.waitForLayout(context: "viewport initial mount")
        try await waitUntil("Initial preparation is blocked and the page is mounted",
                            diagnostics: { mounted.diagnostics + "; preparing=\(model.isPreparing)" }) { model.isPreparing }
        await drainLayout(mounted.native)
        XCTAssertTrue(layout.settledSizes.isEmpty, "Pending zero-row content cannot report the panel height")
        await gate.release()
        _ = try await waitForDetails(model, mounted: mounted.native)
        try await waitForSettlements(layout, count: 1, mounted: mounted)
        let firstSize = try XCTUnwrap(layout.settledSizes.first)
        let snapshot = try await mounted.snapshot(requiredFrames: footerProbeIDs, context: "viewport first delivery")
        XCTAssertEqual(snapshot.viewportSize.height, firstSize.height, accuracy: 1)
        XCTAssertEqual(firstSize.height, firstNaturalSize.height, accuracy: 1)
        assertFooterVisible(snapshot)
        let firstRevision = model.layoutRevision

        inputs.session.send(fixture(id: ScanSessionID(rawValue: UUID()), candidates: (1...4).map { candidate($0) }))
        _ = try await waitForDetails(model, mounted: mounted.native)
        try await waitForSettlements(layout, count: 2, mounted: mounted)
        let largerSize = try XCTUnwrap(layout.settledSizes.last)
        XCTAssertGreaterThan(largerSize.height, firstSize.height + 2 * GeekCleanupRowLayout.minimumHeight)
        XCTAssertEqual(model.layoutRevision, firstRevision + 1)
        XCTAssertEqual(layout.settledSizes, [firstSize, largerSize], "A changed result settles exactly once")
        let laterSnapshot = try await mounted.snapshot(requiredFrames: footerProbeIDs.union([GeekCleanupProbeID.hint]),
            context: "viewport larger delivery, screen-constrained")
        XCTAssertEqual(laterSnapshot.viewportSize.height, firstSize.height, accuracy: 1,
                       "The simulated screen limit, not the old result, caps the visible height")
        assertFooterVisible(laterSnapshot)
        XCTAssertEqual(laterSnapshot.fields[GeekCleanupProbeID.hint]?.label, L10n.text("向下滚动查看更多", "Scroll down to see more"))
        let scroll = try XCTUnwrap(mounted.scrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height + 2 * GeekCleanupRowLayout.minimumHeight)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, document.frame.height - 1,
                                    "The last item stays reachable; footer needs no scrolling")
        await drainLayout(mounted.native)
        let lastItem = try XCTUnwrap(model.details?.items.last)
        let lastID = GeekCleanupProbeID.item(lastItem.id)
        let endSnapshot = try await mounted.snapshot(requiredFrames: footerProbeIDs.union([GeekCleanupProbeID.listViewport, lastID]),
            context: "viewport last row after native scroll")
        let lastFrame = try XCTUnwrap(endSnapshot.frames[lastID], endSnapshot.description)
        let listFrame = try XCTUnwrap(endSnapshot.frames[GeekCleanupProbeID.listViewport], endSnapshot.description)
        XCTAssertEqual(listFrame.width, scroll.contentSize.width, accuracy: 1, endSnapshot.description)
        XCTAssertEqual(listFrame.height, scroll.contentSize.height, accuracy: 1, endSnapshot.description)
        assertFrame(lastFrame, inside: listFrame, message: endSnapshot.description)
        assertFooterVisible(endSnapshot)
        XCTAssertEqual(layout.settledSizes, [firstSize, largerSize], "Scrolling cannot request another settlement")
    }

    func testHostedVisibleResultChangesGrowAndShrinkOnceWithFooterAlwaysVisible() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let inputs = CleanupTestInputs(session: fixture(candidates: [candidate(1)]))
            let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
            let counter = CleanupParentRenderCounter()
            let layout = CleanupPageLayoutRecorder()
            let mounted = CleanupRenderedReadbackHost(view: CleanupRetainingTestHost(
                model: model, source: inputs.source, counter: counter, layout: layout), width: 312, testCase: self)
            defer { mounted.close(); model.stop() }
            _ = try await waitForDetails(model, mounted: mounted.native)
            try await waitForSettlements(layout, count: 1, mounted: mounted)
            let first = try await mounted.snapshot(requiredFrames: footerProbeIDs, context: "unconstrained first delivery")
            assertFooterVisible(first)
            let initialRevision = model.layoutRevision
            let before = counter.count
            let larger = fixture(id: ScanSessionID(rawValue: UUID()), candidates: (1...4).map { candidate($0) })
            inputs.session.send(larger)
            _ = try await waitForDetails(model, mounted: mounted.native)
            try await waitForSettlements(layout, count: 2, mounted: mounted)
            let grown = try await mounted.snapshot(requiredFrames: footerProbeIDs, context: "unconstrained larger delivery")
            XCTAssertGreaterThan(grown.viewportSize.height, first.viewportSize.height + 2 * GeekCleanupRowLayout.minimumHeight)
            XCTAssertEqual(layout.settlements.count, 2)
            XCTAssertEqual(model.layoutRevision, initialRevision + 1)
            assertFooterVisible(grown)
            assertNotice(grown, equals: L10n.text("默认可清理 4 项。在主窗口确认。", "4 default cleanup items. Confirm in the main window."))

            let smaller = larger.mappingCandidates { $0.sourceURL.lastPathComponent == "cache-1" ? $0 : nil }
            inputs.session.send(smaller)
            _ = try await waitForDetails(model, mounted: mounted.native)
            try await waitForSettlements(layout, count: 3, mounted: mounted)
            let shrunk = try await mounted.snapshot(requiredFrames: footerProbeIDs, context: "same identity with fewer results")
            XCTAssertEqual(shrunk.viewportSize.height, first.viewportSize.height, accuracy: 1)
            XCTAssertEqual(layout.settlements.count, 3)
            XCTAssertEqual(model.layoutRevision, initialRevision + 2)
            assertFooterVisible(shrunk)
            inputs.scanning.send(true)
            inputs.session.send(nil)
            try await waitForSettlements(layout, count: 4, mounted: mounted)
            let scanning = try await mounted.snapshot(requiredFrames: footerProbeIDs, context: "scan start removes old rows")
            XCTAssertLessThan(scanning.viewportSize.height, shrunk.viewportSize.height)
            XCTAssertEqual(layout.settlements.count, 4)
            assertFooterVisible(scanning)
            assertNotice(scanning, equals: L10n.text("扫描中…等待本次结果。", "Scanning… Wait for the new results."))
            XCTAssertEqual(counter.count, before, "Result changes must not require an artificial parent redraw")
        }
    }

    func testHostedSameKeyReopenDoesNotResettleAndUsesCurrentPreAppearInputs() async throws {
        let inputs = CleanupTestInputs(session: fixture(candidates: [candidate(1)]))
        let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
        let layout = CleanupPageLayoutRecorder()
        let visibility = CleanupFixtureVisibility()
        let mounted = CleanupRenderedReadbackHost(view: CleanupReopeningTestHost(
            visibility: visibility, model: model, inputs: inputs, layout: layout), width: 312, testCase: self)
        defer { mounted.close(); model.stop() }
        _ = try await waitForDetails(model, mounted: mounted.native)
        try await waitForSettlements(layout, count: 1, mounted: mounted)
        let firstRevision = model.layoutRevision
        let firstOpening = model.visibilityID
        let firstSize = try XCTUnwrap(layout.settledSizes.first)
        visibility.isShown = false
        try await waitUntil("The page really disappears before reopening", diagnostics: { mounted.diagnostics }) {
            mounted.layout()
            return !model.isVisible
        }
        XCTAssertEqual(model.presentation(beforeStarting: inputs.source.current()).source, .session,
                       "Before onAppear the retained rows resolve against current inputs, not cleared model inputs")
        visibility.isShown = true
        _ = try await waitForDetails(model, mounted: mounted.native)
        try await waitForSettlements(layout, count: 2, mounted: mounted)
        XCTAssertNotEqual(model.visibilityID, firstOpening)
        XCTAssertEqual(model.layoutRevision, firstRevision, "Reopening the same key never advances the layout revision")
        XCTAssertEqual(layout.settlements.map(\.size), [firstSize, firstSize], "Only the initial report for each opening")
        inputs.session.send(inputs.session.value)
        _ = try await waitForDetails(model, mounted: mounted.native)
        await drainLayout(mounted.native)
        XCTAssertEqual(layout.settlements.count, 2, "Same-key refresh cannot settle again")
        let snapshot = try await mounted.snapshot(requiredFrames: footerProbeIDs, context: "same-key reopened page")
        assertFooterVisible(snapshot)
        assertNoUnavailable(snapshot)
        XCTAssertEqual(inputs.subscriptions, [2, 2, 2])
    }

    func testHostedAttachedAndCompactShellKeepFooterOutsideTheirScrollers() async throws {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        let padding = GeekPanelLayout.contentPadding
        let width = GeekPanelPresentationMetrics.detailWidth - 2 * padding
        let firstSession = fixture(candidates: [candidate(1)])
        let natural = NSHostingView(rootView: smartContentWithActions(.resolve(session: firstSession,
            details: MiniWindowCleanupDetails(session: firstSession), history: nil)).frame(width: width)).fittingSize
        let panelHeight = (natural.height + 2 * padding).rounded(.up)
        for compact in [false, true] {
            let inputs = CleanupTestInputs(session: firstSession)
            let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
            let layout = CleanupPageLayoutRecorder()
            let counter = CleanupParentRenderCounter()
            let panelSize = CGSize(width: GeekPanelPresentationMetrics.detailWidth, height: panelHeight)
            let compactLayout = MenuBarCascadeLayout(direction: .left, alignment: .bottom,
                parentFrame: CGRect(origin: .zero, size: panelSize), childFrames: [],
                secondaryPresentationMode: .adjacent, tertiaryPresentationMode: .unavailable, isCompact: true)
            let shell = GeekAttachedPanelShell(section: .cleanup, density: .geek,
                overviewSize: panelSize, direction: .left, presentationMode: .adjacent,
                tertiaryPresentationMode: .unavailable, cascadeLayout: compact ? compactLayout : nil,
                detailPreferredSize: panelSize, showsTertiary: false,
                tertiaryPreferredSize: GeekPanelPresentationMetrics.tertiarySize, tertiarySourceOffset: nil,
                onHoverChange: { _, _ in }, detailOwnsScrolling: true) {
                    CleanupRetainingTestHost(model: model, source: inputs.source,
                        counter: counter, layout: layout, contentWidth: width).padding(padding)
                } overview: { Color.clear } tertiary: { EmptyView() }
            let mounted = CleanupRenderedReadbackHost(view: shell,
                width: compact ? panelSize.width : 2 * panelSize.width + MiniWindowStyleTokens.cascadeGap,
                testCase: self)
            defer { mounted.close(); model.stop() }
            _ = try await waitForDetails(model, mounted: mounted.native)
            try await waitForSettlements(layout, count: 1, mounted: mounted)
            let before = counter.count
            inputs.session.send(fixture(id: ScanSessionID(rawValue: UUID()), candidates: (1...4).map { candidate($0) }))
            _ = try await waitForDetails(model, mounted: mounted.native)
            try await waitForSettlements(layout, count: 2, mounted: mounted)
            let snapshot = try await mounted.snapshot(requiredFrames: footerProbeIDs,
                context: "real attached shell: compact=\(compact)")
            assertFooterVisible(snapshot)
            XCTAssertLessThanOrEqual(snapshot.viewportSize.height, panelHeight - 2 * padding + 1,
                "The real shell must pass its clipped height, not the natural result height; \(snapshot.description)")
            let overflow = try await mounted.snapshot(requiredFrames: footerProbeIDs.union([GeekCleanupProbeID.hint]),
                context: "real shell overflow hint: compact=\(compact)")
            XCTAssertEqual(overflow.fields[GeekCleanupProbeID.hint]?.label, "Scroll down to see more")
            let nativeContent = try XCTUnwrap(mounted.window.contentView)
            XCTAssertEqual(countScrollViews(in: nativeContent), 1,
                "Only the item list scrolls; no outer shell scroller may contain the footer")
            XCTAssertEqual(counter.count, before)
        }
    }
    #endif

    func testHostedSmartPageOwnsUpdatesWithoutInvalidatingItsRetainingParent() async throws {
        let session = fixture()
        let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
        let inputs = CleanupTestInputs(session: session)
        let counter = CleanupParentRenderCounter()
        let layout = CleanupPageLayoutRecorder()
        let mounted = CleanupAccessibilityReadbackHost(view: CleanupRetainingTestHost(
            model: model, source: inputs.source, counter: counter, layout: layout), width: 312, testCase: self)
        defer { mounted.close(); model.stop() }
        _ = try await waitForDetails(model)
        XCTAssertTrue(model.isVisible)
        await drainLayout(mounted)
        let before = counter.count
        inputs.session.send(session.mappingCandidates { $0.sourceURL.lastPathComponent == "cache-6" ? nil : $0 })
        _ = try await waitForDetails(model)
        await drainLayout(mounted)
        XCTAssertFalse(model.details?.items.contains { $0.sourceURL.lastPathComponent == "cache-6" } ?? true)
        XCTAssertEqual(counter.count, before, "Only the cleanup host observes detail publications")
    }

    #if DEBUG
    func testHostedParentDoesNotRedrawWhenScanningFinishesNewIdentityOrHistoryChanges() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let inputs = CleanupTestInputs(session: nil, isScanning: true)
            let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
            let counter = CleanupParentRenderCounter()
            let layout = CleanupPageLayoutRecorder()
            let mounted = CleanupRenderedReadbackHost(view: CleanupRetainingTestHost(
                model: model, source: inputs.source, counter: counter, layout: layout), width: 312, testCase: self)
            defer { mounted.close(); model.stop() }
            try await mounted.waitForLayout(context: "identity initial mount: \(language.rawValue)")
            try await waitUntil("The mounted page subscribes to the initial scan", diagnostics: {
                mounted.diagnostics + "; visible=\(model.isVisible), scanning=\(model.isScanning)"
            }) { model.isVisible && model.isScanning }
            await drainLayout(mounted.native)
            let before = counter.count
            assertNotice(try await mounted.snapshot(context: "identity initial scanning: \(language.rawValue)"), equals:
                L10n.text("扫描中…等待本次结果。", "Scanning… Wait for the new results."))

            let first = fixture(candidates: [candidate(1)])
            inputs.session.send(first)
            inputs.scanning.send(false)
            _ = try await waitForDetails(model, mounted: mounted.native)
            await drainLayout(mounted.native)
            var snapshot = try await mounted.snapshot(context: "identity first completion: \(language.rawValue)")
            assertRendered(snapshot, contains: first.candidates[0].sourceURL.lastPathComponent)
            assertNotice(snapshot, equals: L10n.text("默认可清理 1 项。在主窗口确认。", "1 default cleanup item. Confirm in the main window."))
            XCTAssertFalse(snapshot.visibleText.contains(L10n.text("扫描中…", "Scanning…")), snapshot.description)
            XCTAssertEqual(model.presentation.source, .session)
            assertMetric(snapshot, label: L10n.text("当前可操作", "Actionable Now"), value: "1",
                         detail: L10n.text("默认可清理", "Default Cleanup Items"))

            inputs.session.send(nil)
            inputs.scanning.send(true)
            let summary = ScanHistorySummary(entries: [status(for: first).entry])
            inputs.history.send(summary)
            await drainLayout(mounted.native)
            snapshot = try await mounted.snapshot(context: "identity new scanning with history: \(language.rawValue)")
            XCTAssertEqual(snapshot.fields[GeekCleanupProbeID.heading]?.label, model.presentation.title, snapshot.description)
            assertNotice(snapshot, equals: L10n.text("扫描中…等待本次结果。", "Scanning… Wait for the new results."))
            XCTAssertEqual(model.presentation.source, .history)
            XCTAssertEqual(model.history?.entry.greenBytes, summary.entries.first?.greenBytes)

            let next = fixture(id: ScanSessionID(rawValue: UUID()), candidates: [candidate(2), candidate(6)])
            inputs.session.send(next)
            inputs.scanning.send(false)
            _ = try await waitForDetails(model, mounted: mounted.native)
            await drainLayout(mounted.native)
            snapshot = try await mounted.snapshot(context: "identity new identity completion: \(language.rawValue)")
            XCTAssertEqual(model.session?.id, next.id)
            XCTAssertEqual(model.details?.sessionID, next.id)
            assertRendered(snapshot, contains: "cache-6")
            assertNotice(snapshot, equals: L10n.text("默认可清理 2 项。在主窗口确认。", "2 default cleanup items. Confirm in the main window."))
            XCTAssertFalse(snapshot.visibleText.contains(L10n.text("正在整理扫描明细…", "Preparing scan details…")), snapshot.description)
            assertNoUnavailable(snapshot)
            assertMetric(snapshot, label: L10n.text("当前可操作", "Actionable Now"), value: "2",
                         detail: L10n.text("默认可清理", "Default Cleanup Items"))

            inputs.session.send(nil)
            inputs.history.send(ScanHistorySummary(entries: [status(for: fixture(candidates: [])).entry]))
            await drainLayout(mounted.native)
            snapshot = try await mounted.snapshot(context: "identity zero-green history: \(language.rawValue)")
            assertNotice(snapshot, equals: L10n.text("仅保留扫描摘要。上次没有绿色清理项。", "Only the scan summary is saved. The last scan found no green items."))
            inputs.history.send(ScanHistorySummary(entries: []))
            await drainLayout(mounted.native)
            snapshot = try await mounted.snapshot(context: "identity no scan history: \(language.rawValue)")
            XCTAssertEqual(snapshot.fields[GeekCleanupProbeID.heading]?.label,
                           L10n.text("尚未扫描", "Not Scanned Yet"), snapshot.description)
            assertNotice(snapshot, equals: L10n.text("先在主窗口扫描，再查看清理项。", "Scan in the main window to see cleanup items."))
            XCTAssertEqual(counter.count, before, "No state update may depend on a parent redraw")
        }
    }
    #endif

    func testSourceSubscribesOncePerVisibleLifetimeAndDoesNoHiddenWork() async throws {
        let cache = MenuBarDerivedCache()
        let inputs = CleanupTestInputs(session: fixture())
        let model = MiniWindowCleanupDetailsModel(cache: cache)
        model.start(inputs.source)
        _ = try await waitForDetails(model)
        let opening = model.visibilityID
        let publications = CleanupParentRenderCounter()
        let subscription = model.$session.dropFirst().sink { _ in publications.count += 1 }
        defer { subscription.cancel(); model.stop() }
        for _ in 0..<5 { model.start(inputs.source) }
        await drainLayout()
        XCTAssertEqual(model.visibilityID, opening)
        XCTAssertEqual(inputs.subscriptions, [1, 1, 1])
        XCTAssertEqual(publications.count, 0, "Parent evaluations must not request or publish a session again")
        model.stop()
        XCTAssertEqual(inputs.cancellations, [1, 1, 1])
        let before = await cache.statistics()
        inputs.session.send(fixture(id: ScanSessionID(rawValue: UUID())))
        inputs.scanning.send(true)
        inputs.history.send(ScanHistorySummary(entries: [status(for: fixture()).entry]))
        await drainLayout()
        let after = await cache.statistics()
        XCTAssertEqual(after.builds, before.builds)
        XCTAssertFalse(model.isPreparing)
        XCTAssertFalse(model.isScanning, "Cancelled subscriptions do not deliver hidden changes")
        model.start(inputs.source)
        _ = try await waitForDetails(model)
        XCTAssertNotEqual(model.visibilityID, opening)
        XCTAssertEqual(model.session?.id, inputs.session.value?.id)
        XCTAssertTrue(model.isScanning)
        XCTAssertNotNil(model.history)
        XCTAssertEqual(inputs.subscriptions, [2, 2, 2])
        model.stop()
        XCTAssertEqual(inputs.cancellations, [2, 2, 2])
    }

    func testHostedParentRedrawDoesNotResubscribeOrRestartPreparation() async throws {
        let inputs = CleanupTestInputs(session: fixture())
        let cache = MenuBarDerivedCache()
        let model = MiniWindowCleanupDetailsModel(cache: cache)
        let refresh = CleanupParentRefresh()
        let counter = CleanupParentRenderCounter()
        let layout = CleanupPageLayoutRecorder()
        let mounted = CleanupAccessibilityReadbackHost(view: CleanupRefreshingTestHost(
            refresh: refresh, model: model, inputs: inputs, counter: counter, layout: layout), width: 312, testCase: self)
        defer { mounted.close(); model.stop() }
        _ = try await waitForDetails(model)
        try await waitUntil("Missing initial cleanup.page.settled report", diagnostics: { mounted.diagnostics }) {
            mounted.layout()
            return layout.settlements.count == 1
        }
        await drainLayout(mounted)
        let before = counter.count
        let opening = model.visibilityID
        let layoutRevision = model.layoutRevision
        let initialSettlements = layout.settlements
        var sessionPublications = 0
        let subscription = model.$session.dropFirst().sink { _ in sessionPublications += 1 }
        defer { subscription.cancel() }
        for revision in 1...3 {
            refresh.revision = revision
            await drainLayout(mounted)
        }
        XCTAssertGreaterThan(counter.count, before, "The fixture must actually reevaluate the retaining parent")
        XCTAssertEqual(inputs.subscriptions, [1, 1, 1])
        XCTAssertEqual(inputs.cancellations, [0, 0, 0])
        XCTAssertEqual(model.visibilityID, opening)
        XCTAssertEqual(model.layoutRevision, layoutRevision)
        XCTAssertEqual(layout.settlements, initialSettlements, "Root redraws cannot request another height")
        XCTAssertEqual(sessionPublications, 0, "Even a cheap same-key request would be a redundant restart")
        XCTAssertFalse(model.isPreparing)
        XCTAssertFalse(model.isUpdating)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 1)
    }

    func testUpdatingNoticeWaitsForGraceRetainsRowsAndCancelsOnHide() async throws {
        let work = CleanupTestGate(passing: 1)
        let grace = CleanupTestGate()
        let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache(), fingerprint: { session in
            await work.wait()
            return MiniWindowCleanupDetails.cacheKey(for: session)
        }, waitForUpdateGrace: { await grace.wait() })
        defer { model.stop() }
        let session = fixture()
        model.start(session)
        let first = try await waitForDetails(model)
        let changed = session.mappingCandidates { $0.sourceURL.lastPathComponent == "cache-6" ? nil : $0 }
        model.request(changed)
        XCTAssertFalse(model.isUpdating)
        XCTAssertEqual(model.details?.items.map(\.id), first.items.map(\.id))
        try await waitUntil("Both worker and notice grace are suspended") {
            let workArrivals = await work.arrivalCount
            let graceArrivals = await grace.arrivalCount
            return workArrivals == 2 && graceArrivals == 1
        }
        await grace.release()
        try await waitUntil("A slow refresh publishes its delayed notice") { model.isUpdating }
        XCTAssertEqual(model.presentation.source, .session)
        XCTAssertEqual(model.presentation.actionableDetail, L10n.text("更新中…", "Updating…"))
        XCTAssertEqual(model.details?.items.map(\.id), first.items.map(\.id))
        let cancelledTasks = model.stop()
        XCTAssertFalse(model.isUpdating)
        await work.release()
        for task in cancelledTasks { await task.value }
        XCTAssertEqual(model.details?.items.map(\.id), first.items.map(\.id), "Cancelled workers cannot overwrite the retained delivery")
        model.start(changed)
        _ = try await waitForDetails(model)
        XCTAssertFalse(model.isUpdating)
        XCTAssertFalse(model.details?.items.contains { $0.sourceURL.lastPathComponent == "cache-6" } ?? true)
    }

    func testHidingBeforeGraceDoesNotPublishLateUpdatingNotice() async throws {
        let work = CleanupTestGate(passing: 1)
        let grace = CleanupTestGate()
        let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache(), fingerprint: { session in
            await work.wait()
            return MiniWindowCleanupDetails.cacheKey(for: session)
        }, waitForUpdateGrace: { await grace.wait() })
        let session = fixture()
        model.start(session)
        _ = try await waitForDetails(model)
        model.request(session)
        try await waitUntil("The delayed task has started") { await grace.arrivalCount == 1 }
        var notices = 0
        let subscription = model.$isUpdating.sink { if $0 { notices += 1 } }
        defer { subscription.cancel(); model.stop() }
        let cancelledTasks = model.stop()
        await grace.release()
        await work.release()
        for task in cancelledTasks { await task.value }
        XCTAssertEqual(notices, 0)
        XCTAssertFalse(model.isUpdating)
    }

    func testReadbackHostIsRetainedAcrossAwaitAndCloseOnlyHidesUntilTeardown() async throws {
        var local: CleanupAccessibilityReadbackHost? = CleanupAccessibilityReadbackHost(
            view: Text("Cleanup fixture lifetime"), width: 312, testCase: self)
        // Immutable weak readers preserve the lifetime probe: these locals
        // must not retain the objects whose teardown lease is under test.
        let retainedHost = { [weak host = local] in host }
        let retainedWindow = { [weak window = local?.window] in window }
        let retainedController = { [weak controller = local?.window.contentViewController] in controller }
        local = nil
        // The XCTest teardown lease must retain the fixture even when no test
        // local owns it. A real main-queue turn makes this an async lifetime.
        await CleanupAccessibilityReadbackHost.nextMainQueueTurn()
        let mounted = try XCTUnwrap(retainedHost(), "XCTest must own the readback host until teardown")
        XCTAssertNotNil(retainedWindow())
        XCTAssertNotNil(retainedController())
        XCTAssertTrue(mounted.isAttached, mounted.diagnostics)
        try await mounted.waitForLayout(context: "lifetime before hide")
        mounted.close()
        await CleanupAccessibilityReadbackHost.nextMainQueueTurn()
        XCTAssertTrue(mounted.isAttached, "close must only hide before teardown; \(mounted.diagnostics)")
        XCTAssertTrue(mounted.window.contentViewController === retainedController())
        XCTAssertTrue(mounted.window === retainedWindow())
        XCTAssertFalse(mounted.window.isVisible)
        let snapshot = try await mounted.settledSnapshot(requiringValueLabels: [], context: "lifetime after hide")
        assertAccessible(snapshot, contains: "Cleanup fixture lifetime")
        XCTAssertTrue(mounted.window.isVisible, "AX readback must realize the retained fixture; \(mounted.diagnostics)")
    }

    #if DEBUG
    func testHostedRenderedProbePublishesLabelsValuesAndTextInBothLanguages() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let session = fixture(candidates: [candidate(1)])
            let model = MiniWindowCleanupDetailsModel(cache: MenuBarDerivedCache())
            let inputs = CleanupTestInputs(session: session)
            let mounted = CleanupRenderedReadbackHost(view: CleanupRetainingTestHost(
                model: model, source: inputs.source, counter: CleanupParentRenderCounter(),
                layout: CleanupPageLayoutRecorder()), width: 312, testCase: self)
            defer { mounted.close(); model.stop() }
            _ = try await waitForDetails(model, mounted: mounted.native)
            await drainLayout(mounted.native)
            let first = try await mounted.snapshot(context: "rendered scroll content: \(language.rawValue)")
            XCTAssertNotNil(mounted.scrollView, "Exercise the real cleanup scroll viewport")
            XCTAssertTrue(mounted.window.isVisible, mounted.diagnostics)
            assertMetric(first, label: L10n.text("当前可操作", "Actionable Now"), value: "1",
                         detail: L10n.text("默认可清理", "Default Cleanup Items"))
            assertNotice(first, equals: L10n.text("默认可清理 1 项。在主窗口确认。", "1 default cleanup item. Confirm in the main window."))
            mounted.close()
            XCTAssertFalse(mounted.window.isVisible)
            XCTAssertTrue(mounted.native.isAttached, mounted.diagnostics)
            mounted.show()
            await drainLayout(mounted.native)
            _ = try await waitForDetails(model, mounted: mounted.native)
            let reopened = try await mounted.snapshot(context: "reshown rendered scroll content: \(language.rawValue)")
            XCTAssertTrue(mounted.window.isVisible, mounted.diagnostics)
            assertMetric(reopened, label: L10n.text("当前可操作", "Actionable Now"), value: "1",
                         detail: L10n.text("默认可清理", "Default Cleanup Items"))
            assertNotice(reopened, equals: L10n.text("默认可清理 1 项。在主窗口确认。", "1 default cleanup item. Confirm in the main window."))
        }
    }
    #endif

    func testHostedLongFileNameKeepsTheCompleteLowerBoundSize() throws {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        let item = candidate(4, measurement: .lowerBound(reason: .unreadableDescendant),
                             pathOverride: "/MiniCleanupFixture/" + String(repeating: "long-name-", count: 20))
        let text = try renderedText(AdvancedSmartCleanupItemRow(candidate: item), width: 280)
        assertRendered(text, contains: CleanupMeasurementPresentation.value(item))
    }

    private func smartContent(_ presentation: MiniWindowCleanupPresentation, extended: Bool = true) -> GeekSmartCleanupContent<EmptyView> {
        GeekSmartCleanupContent(presentation: presentation,
            diskTile: AdvancedMetricTileModel(id: "disk-free", title: "Disk", value: "560 GB", detail: "Available",
                                             tint: AppDesignTokens.Palette.information, progress: nil),
            diskAvailableText: "560 GB", showsExtendedDetails: extended, actions: EmptyView())
    }

    private func smartContentWithActions(_ presentation: MiniWindowCleanupPresentation) -> GeekSmartCleanupContent<GeekCleanupActions> {
        GeekSmartCleanupContent(presentation: presentation,
            diskTile: AdvancedMetricTileModel(id: "disk-free", title: "Disk", value: "560 GB", detail: "Available",
                tint: AppDesignTokens.Palette.information, progress: nil),
            diskAvailableText: "560 GB", showsExtendedDetails: true, actions: cleanupFixtureActions)
    }

    private func hostedSnapshot<V: View>(_ view: V, width: CGFloat = 312,
                                        requiringValueLabels: Set<String> = []) throws -> CleanupAccessibilitySnapshot {
        let fixture = CleanupAccessibilityReadbackHost(view: view, width: width, testCase: self)
        defer { fixture.close() }
        return try fixture.snapshot(requiringValueLabels: requiringValueLabels)
    }

    // Preserve the long-name test's call site, but retain the native tree so
    // its assertion can also print role/label/value diagnostics on failure.
    private func renderedText<V: View>(_ view: V, width: CGFloat = 312) throws -> CleanupAccessibilitySnapshot {
        try hostedSnapshot(view, width: width)
    }

    private func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertRendered(_ snapshot: CleanupAccessibilitySnapshot, contains expected: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        assertAccessible(snapshot, contains: expected, file: file, line: line)
    }

    private func assertAccessible(_ snapshot: CleanupAccessibilitySnapshot, contains expected: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(normalize(snapshot.visibleText).contains(normalize(expected)),
                      "Expected hosted text: \(expected); \(snapshot.description)", file: file, line: line)
    }

    private func assertMetric(_ snapshot: CleanupAccessibilitySnapshot, label: String, value: String, detail: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let matches = snapshot.metricNodes(label: label)
        XCTAssertEqual(matches.count, 1, "Expected one element labelled \(label); \(snapshot.description)", file: file, line: line)
        guard let node = matches.first else { return }
        // Read title, value and hint from this one native element. A value in
        // another tile, telemetry row or notice cannot satisfy the assertion.
        XCTAssertEqual(node.label, label, snapshot.description, file: file, line: line)
        XCTAssertEqual(node.value, value, "Expected value for \(label): \(value); \(snapshot.description)", file: file, line: line)
        XCTAssertTrue(node.help?.contains(detail) == true,
                      "Expected explanation for \(label): \(detail); \(snapshot.description)", file: file, line: line)
    }

    private func assertAvailableTile(_ tile: AdvancedMetricTileModel, snapshot: CleanupAccessibilitySnapshot,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let value = tile.value.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(value.isEmpty || value == "—" || value.contains("--"),
                       "An unknown marker would hide the visible explanation: \(tile.id)=\(tile.value); \(snapshot.description)", file: file, line: line)
        XCTAssertNotEqual(tile.detail, L10n.text("不可用", "Unavailable"), snapshot.description, file: file, line: line)
    }

    private func assertNoUnavailable(_ snapshot: CleanupAccessibilitySnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(snapshot.allText.contains(L10n.text("不可用", "Unavailable")), snapshot.description, file: file, line: line)
        XCTAssertFalse(snapshot.nodes.contains { $0.value == "--" || $0.value == "—" }, snapshot.description, file: file, line: line)
    }

    #if DEBUG
    private var footerProbeIDs: Set<String> {
        [GeekCleanupProbeID.viewport, GeekCleanupProbeID.footer, GeekCleanupProbeID.notice,
         GeekCleanupProbeID.action(0), GeekCleanupProbeID.action(1), GeekCleanupProbeID.action(2)]
    }

    private func assertFrame(_ frame: CGRect, inside viewport: CGRect, message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(frame.height, 0, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1, message, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1, message, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1, message, file: file, line: line)
    }

    private func assertFooterVisible(_ snapshot: CleanupRenderedSnapshot,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard let viewport = snapshot.frames[GeekCleanupProbeID.viewport] else {
            XCTFail("Missing actual page viewport; \(snapshot.description)", file: file, line: line)
            return
        }
        for id in footerProbeIDs.subtracting([GeekCleanupProbeID.viewport]) {
            guard let frame = snapshot.frames[id] else { XCTFail("Missing footer frame \(id); \(snapshot.description)", file: file, line: line); continue }
            assertFrame(frame, inside: viewport, message: snapshot.description, file: file, line: line)
        }
    }

    private func waitForSettlements(_ layout: CleanupPageLayoutRecorder, count: Int,
                                    mounted: CleanupRenderedReadbackHost) async throws {
        try await waitUntil("Missing cleanup.page.settled reports; wanted \(count)", diagnostics: {
            mounted.diagnostics + "; settlements=\(layout.settlements)"
        }) {
            mounted.layout()
            return layout.settlements.count >= count
        }
        await drainLayout(mounted.native)
        XCTAssertEqual(layout.settlements.count, count, mounted.diagnostics)
    }

    private func countScrollViews(in view: NSView) -> Int {
        (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + countScrollViews(in: $1) }
    }

    private func assertNotice(_ snapshot: CleanupRenderedSnapshot, equals expected: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let field = snapshot.fields[GeekCleanupProbeID.notice]
        XCTAssertEqual(field?.kind, .notice, snapshot.description, file: file, line: line)
        XCTAssertEqual(field?.label, expected,
                       "Expected actual notice Text: \(expected); \(snapshot.description)", file: file, line: line)
    }

    private func assertRendered(_ snapshot: CleanupRenderedSnapshot, contains expected: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(normalize(snapshot.visibleText).contains(normalize(expected)),
                      "Expected rendered body text: \(expected); \(snapshot.description)", file: file, line: line)
    }

    private func assertMetric(_ snapshot: CleanupRenderedSnapshot, label: String, value: String, detail: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let matches = snapshot.fields.values.filter { $0.kind == .metric && $0.label == label }
        XCTAssertEqual(matches.count, 1, "Expected one rendered metric labelled \(label); \(snapshot.description)", file: file, line: line)
        guard let field = matches.first else { return }
        XCTAssertEqual(field.label, label, snapshot.description, file: file, line: line)
        XCTAssertEqual(field.value, value, "Expected value for \(label): \(value); \(snapshot.description)", file: file, line: line)
        XCTAssertTrue(field.detail?.contains(detail) == true,
                      "Expected explanation for \(label): \(detail); \(snapshot.description)", file: file, line: line)
    }

    private func assertNoUnavailable(_ snapshot: CleanupRenderedSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(snapshot.visibleText.contains(L10n.text("不可用", "Unavailable")), snapshot.description, file: file, line: line)
        XCTAssertFalse(snapshot.fields.values.contains { $0.value == "--" || $0.value == "—" }, snapshot.description, file: file, line: line)
    }
    #endif

    private func waitUntil(_ message: String, diagnostics: () -> String = { "" },
                           _ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await predicate() { return }
            await Task.yield()
        }
        let diagnostic = message + "; " + diagnostics()
        FileHandle.standardError.write(Data("Cleanup wait failure: \(diagnostic)\n".utf8))
        XCTFail(diagnostic)
        throw NSError(domain: "MiniWindowCleanupPresentationTests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: diagnostic])
    }

    private func drainLayout(_ mounted: CleanupAccessibilityReadbackHost? = nil) async {
        // Let queued SwiftUI invalidations and native layout probes run. No
        // fixed sleep, and all substantive readiness uses a bounded predicate.
        for _ in 0..<10 {
            mounted?.layout()
            await Task.yield()
        }
    }

    private func waitForDetails(_ model: MiniWindowCleanupDetailsModel,
                                mounted: CleanupAccessibilityReadbackHost? = nil) async throws -> MiniWindowCleanupDetails {
        let deadline = Date().addingTimeInterval(5)
        while (model.details == nil || model.isPreparing) && Date() < deadline {
            mounted?.layout()
            await Task.yield()
        }
        let diagnostics = "visible=\(model.isVisible), preparing=\(model.isPreparing), source=\(model.presentation.source); "
            + (mounted?.diagnostics ?? "pure model")
        XCTAssertFalse(model.isPreparing, "The latest request must finish, not just retain an older delivery; \(diagnostics)")
        if model.isPreparing {
            FileHandle.standardError.write(Data("Cleanup detail wait failure: \(diagnostics)\n".utf8))
            throw NSError(domain: "MiniWindowCleanupPresentationTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Latest detail request did not finish; \(diagnostics)"])
        }
        return try XCTUnwrap(model.details, "The visible page must receive its projection; \(diagnostics)")
    }

    private struct EmptyHistoryLoader: ScanStoreHistoryLoading {
        func load() async -> ScanStoreHistorySnapshot {
            ScanStoreHistorySnapshot(scanHistory: ScanHistorySummary(entries: []), cleanupHistory: CleanupHistorySummary(entries: []))
        }
    }

    private struct UnusedHealthProbe: ComputerHealthProbing {
        func probe() async throws -> ComputerHealthSnapshot { throw CancellationError() }
    }

    private let sessionID = ScanSessionID(rawValue: UUID(uuidString: "51000325-3849-4DA5-970C-E75F819C9414")!)
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    private func fixture(id: ScanSessionID? = nil, outcome: ScanOutcome = .complete,
                         candidates: [ScanCandidate]? = nil) -> ScanSession {
        let candidates = candidates ?? [candidate(1, unknownOwner: true), candidate(2, recentLog: true),
            candidate(3, running: true), candidate(4, measurement: .lowerBound(reason: .unreadableDescendant)),
            candidate(5, defaultSelection: .unselected), candidate(6), candidate(7, risk: .reviewOnly),
            candidate(8, risk: .protected), candidate(9, risk: .protected, action: .emptyTrash),
            candidate(10, measurement: .failed(reason: .permissionDenied))]
        return ScanSession(id: id ?? sessionID, rulesVersion: "mini-cleanup-fixture", startedAt: date.addingTimeInterval(-1),
                           completedAt: date, outcome: outcome,
                           categories: [CleanupScanCategory(id: "fixture", title: "Fixture", subcategories: [
                            CleanupScanSubcategory(id: "fixture", title: "Caches", risk: .safe,
                                                  recommendation: .recommended, reason: "fixture", candidates: candidates)])],
                           issues: [], permissions: [],
                           metrics: ScanMetrics(visitedEntryCount: 10, visitedDirectoryCount: 1, candidateCount: candidates.count,
                                                deduplicatedIdentityCount: 0, estimatedCandidateBytes: 0,
                                                completeMeasurementCandidateCount: candidates.count, duration: 1),
                           system: system(), smartScanScopes: [.cleanupCandidates])
    }

    private func candidate(_ index: Int, risk: CleanupRisk = .safe, action: CleanupRuleAction? = nil,
                           running: Bool = false, unknownOwner: Bool = false, recentLog: Bool = false,
                           measurement: MeasurementCompleteness = .complete,
                           defaultSelection: CleanupDefaultSelection = .selected,
                           pathOverride: String? = nil, sizeBytes: Int64? = nil) -> ScanCandidate {
        let path = pathOverride ?? "/MiniCleanupFixture/cache-\(index)"
        let bytes = sizeBytes ?? Int64(index * 1_024)
        let action = action ?? (risk == .safe ? .moveToTrash : risk == .reviewOnly ? .moveToTrashAfterReview : .moveToTrashAfterProtectedReview)
        let eligibility: CleanupExecutionEligibility = switch action {
        case .moveToTrash: .eligible
        case .moveToTrashAfterReview: .eligibleAfterReview
        case .moveToTrashAfterProtectedReview, .emptyTrash: .eligibleAfterProtectedReview
        case .revealOnly: .advisoryOnly
        }
        var candidate = ScanCandidate(
            id: ScanCandidateID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!),
            sessionID: sessionID, ruleID: "mini-fixture-\(index)", ruleSelectionPolicyVersion: 1,
            categoryID: "application-cache", categoryTitle: "Fixture", subcategoryTitle: "Caches",
            sourceURL: URL(fileURLWithPath: path), allowedRootURL: URL(fileURLWithPath: "/MiniCleanupFixture"),
            snapshot: FileSnapshot(identity: FileIdentity(deviceID: 42, inode: UInt64(index), entryKind: .regularFile,
                                                          creationTimeNanoseconds: 1),
                                   standardizedPath: path, volumeIdentifier: "fixture", logicalSizeBytes: bytes,
                                   allocatedSizeBytes: bytes, modificationTimeNanoseconds: 1,
                                   isWritableVolume: true, isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false),
            risk: risk, recommendation: CleanupRecommendation(level: .recommended, reasonCode: "fixture",
                evidenceCodes: recentLog ? [CleanupLogPreselectionPolicy.evidencePrefix + CleanupLogWriteState.recent.rawValue] : []),
            defaultSelection: defaultSelection, executionEligibility: eligibility, measurementCompleteness: measurement,
            isManuallySelectable: true, action: action, requiredClosedBundleIDs: [], reason: "fixture")
        candidate.ownerResolution = unknownOwner ? .unresolved : .noApplication
        candidate.runningOwnerBundleIdentifiers = running ? ["com.example.fixture"] : []
        return candidate
    }

    private func status(for session: ScanSession) -> LastScanStatusSummary {
        ScanHistorySummary(entries: [ScanHistoryService.entry(from: session)]).latestStatus(referenceDate: session.completedAt)!
    }

    private func legacyItem(_ index: Int) -> StorageItem {
        let path = "/MiniCleanupFixture/legacy-\(index)"
        return StorageItem(id: "legacy-\(index)", title: "Legacy \(index)", path: path, groupTitle: "Caches",
                           sizeBytes: Int64(index * 1_024), tier: .green, kind: "cache", reason: "", recommendation: "",
                           risk: "", requiresClose: "", trashPaths: [path], openPath: path, status: .available)
    }

    private func system() -> SystemSnapshot {
        SystemSnapshot(osName: "macOS", build: "fixture", arch: "arm64", user: "fixture", home: "/MiniCleanupFixture",
                       filesystem: "APFS", purgeable: "", diskName: "Fixture", diskTotalBytes: 1_000_000,
                       diskUsedBytes: 600_000, diskFreeBytes: 400_000)
    }
}

@MainActor
private final class CleanupParentRenderCounter {
    var count = 0
}

private struct CleanupAccessibilitySnapshot {
    struct Node: Equatable {
        let depth: Int
        let typeName: String
        let role: String?
        let label: String?
        let title: String?
        let value: String?
        let help: String?
        let modernValue: String?
        let legacyValue: String?
        let modernValueDescription: String?
        let legacyValueDescription: String?
        var isContent: Bool { role != NSAccessibility.Role.window.rawValue && role != NSAccessibility.Role.image.rawValue }
        var texts: [String] { [label, title, value].compactMap { $0 }.filter { !$0.isEmpty } }
        var primaryText: String? { label ?? title ?? value }
        var diagnostic: String {
            "\(String(repeating: "  ", count: depth))(role: \(String(reflecting: role)), label: \(String(reflecting: label)), value: \(String(reflecting: value))) type=\(typeName), title=\(String(reflecting: title)), help=\(String(reflecting: help)), modernValue=\(String(reflecting: modernValue)), AXValue=\(String(reflecting: legacyValue)), modernValueDescription=\(String(reflecting: modernValueDescription)), AXValueDescription=\(String(reflecting: legacyValueDescription))"
        }
    }
    let nodes: [Node]
    let layoutSize: CGSize
    var contentNodes: [Node] { nodes.filter(\.isContent) }
    func metricNodes(label: String) -> [Node] {
        // Called on an isolated metric/grid, with no same-named status rows.
        // Do not select by the expected value or expected explanation.
        contentNodes.filter { $0.label == label }
    }
    var primaryTexts: [String] {
        contentNodes.compactMap(\.primaryText).filter { !$0.isEmpty }
    }
    var helpTexts: [String] { contentNodes.compactMap(\.help) }
    // Help is intentionally excluded: a tooltip/hint does not prove a Text
    // was included in the page's visible content (the original P2-2 bug).
    var visibleText: String { contentNodes.flatMap(\.texts).joined(separator: "\n") }
    var allText: String { ([visibleText] + helpTexts).joined(separator: "\n") }
    var description: String { "layout=\(layoutSize); accessibility tree:\n" + nodes.map(\.diagnostic).joined(separator: "\n") }
}

@MainActor
private final class CleanupReadbackLayoutRecorder {
    var size = CGSize.zero
    var isMounted = false
}

/// A test-only native probe measures the content actually mounted by SwiftUI.
/// It does not add labels, values or copied presentation strings to the tree.
@MainActor
private struct CleanupReadbackLayoutProbe: NSViewRepresentable {
    let recorder: CleanupReadbackLayoutRecorder
    func makeNSView(context: Context) -> CleanupReadbackProbeView {
        CleanupReadbackProbeView(recorder: recorder)
    }
    func updateNSView(_ view: CleanupReadbackProbeView, context: Context) { view.report() }
}

@MainActor
private final class CleanupReadbackProbeView: NSView {
    let recorder: CleanupReadbackLayoutRecorder
    init(recorder: CleanupReadbackLayoutRecorder) {
        self.recorder = recorder
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }
    override func layout() { super.layout(); report() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); report() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
    func report() {
        recorder.size = bounds.size
        recorder.isMounted = window != nil
    }
}

/// In-process public NSAccessibility getters, including the same-element
/// AXValue compatibility path used by ConceptLandingNativeLayoutRegressionTests.
@MainActor
private final class CleanupAccessibilityReadbackHost {
    private static let contentProbeID = "cleanup.readback.content"
    private let host: NSView
    let window: NSWindow
    private let recorder: CleanupReadbackLayoutRecorder
    // AX reads use one real native window and its hosting controller in both
    // configurations, not V0's offscreen geometry-only fixture.
    private let controller: NSHostingController<AnyView>
    private var isDismantled = false

    init<V: View>(view: V, width: CGFloat, testCase: XCTestCase) {
        _ = NSApplication.shared
        let recorder = CleanupReadbackLayoutRecorder()
        self.recorder = recorder
        let content = view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(CleanupReadbackLayoutProbe(recorder: recorder).accessibilityHidden(true))
            .environment(\.colorScheme, .dark)
            .environment(\.accessibilityEnabled, true)
        let size = CGSize(width: width, height: 720)
        controller = NSHostingController(rootView: AnyView(content))
        controller.sizingOptions = []
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        host = controller.view
        window.setContentSize(size)
        // This explicit strong capture owns the fixture, window and controller
        // throughout every await and until XCTest teardown, including throws.
        testCase.addTeardownBlock { @MainActor [self] in await dismantle() }
        // Realize only the inert test fixture. Do this before parent-render
        // counters are sampled; no key-window or application activation.
        window.orderFront(nil)
        layout()
    }

    var isAttached: Bool {
        !isDismantled && window.contentViewController != nil && host.window === window
    }

    var missingNativeProbeIDs: [String] {
        var missing: [String] = []
        if !isAttached { missing.append("cleanup.readback.attachment") }
        if !recorder.isMounted || recorder.size.width <= 0 || recorder.size.height <= 0 {
            missing.append(Self.contentProbeID)
        }
        return missing
    }

    var diagnostics: String {
        "attached=\(isAttached), visible=\(window.isVisible), dismantled=\(isDismantled), host=\(type(of: host)), nativeSize=\(recorder.size), mounted=\(recorder.isMounted), missing probes: \(missingNativeProbeIDs)"
    }

    func layout() {
        guard !isDismantled else { return }
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }

    func waitForLayout(context: String) async throws {
        guard isAttached else {
            throw failure("Detached host before layout: \(context); \(diagnostics)", code: 4)
        }
        // Measure the same visible content that AX will read. The existing
        // native probe has a bounded 100-pass wait in Debug and Release.
        var previous: CGSize?
        var stable = 0
        var settled = false
        for _ in 0..<100 {
            layout()
            await Task.yield()
            if missingNativeProbeIDs.isEmpty {
                stable = previous == recorder.size ? stable + 1 : 0
                if stable >= 2 { settled = true; break }
            } else { stable = 0 }
            previous = recorder.size
        }
        guard settled else {
            throw failure("Native layout did not settle: \(context); \(diagnostics)", code: 5)
        }
        guard missingNativeProbeIDs.isEmpty else {
            throw failure("Native attachment/content probes missing: \(context); \(diagnostics)", code: 6)
        }
    }

    func settledSnapshot(requiringValueLabels labels: Set<String>, context: String) async throws -> CleanupAccessibilitySnapshot {
        try showForReadback(context: context)
        try await waitForLayout(context: context)
        return try snapshot(requiringValueLabels: labels, context: context)
    }

    static func nextMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    var scrollView: NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.compactMap(find).first
        }
        return find(host)
    }

    private func showForReadback(context: String) throws {
        guard isAttached else { throw failure("Detached host before AX readback: \(context); \(diagnostics)", code: 7) }
        window.orderFront(nil)
        layout()
        guard window.isVisible else {
            throw failure("Missing probe cleanup.readback.visible-window: \(context); \(diagnostics); \(CleanupAccessibilitySnapshot(nodes: readNodes(), layoutSize: recorder.size).description)", code: 8)
        }
    }

    func snapshot(requiringValueLabels labels: Set<String>, context: String = "static AX readback") throws -> CleanupAccessibilitySnapshot {
        try showForReadback(context: context)
        var previous: [CleanupAccessibilitySnapshot.Node]?
        var previousSize: CGSize?
        var stablePasses = 0
        for _ in 0..<100 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let nodes = readNodes()
            let hasText = nodes.contains { $0.isContent && !$0.texts.isEmpty }
            // Wait for native values to exist, not to equal the expected
            // values. Wrong values must settle and then fail assertMetric.
            let hasValues = labels.allSatisfy { label in
                nodes.contains { $0.isContent && $0.label == label && $0.help != nil && $0.value != nil }
            }
            if hasText && hasValues && recorder.isMounted && recorder.size.width > 0 && recorder.size.height > 0 {
                stablePasses = previous == nodes && previousSize == recorder.size ? stablePasses + 1 : 0
                if stablePasses >= 2 { return CleanupAccessibilitySnapshot(nodes: nodes, layoutSize: recorder.size) }
            } else {
                stablePasses = 0
            }
            previous = nodes
            previousSize = recorder.size
            // Pump native layout/AX callbacks only; never wait for the
            // expected value or explanation, which could mask a regression.
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let snapshot = CleanupAccessibilitySnapshot(nodes: readNodes(), layoutSize: recorder.size)
        let missingValues = labels.filter { label in
            !snapshot.metricNodes(label: label).contains { $0.help != nil && $0.value != nil }
        }.sorted().map { "cleanup.readback.metric:" + $0 }
        let missingText = snapshot.contentNodes.contains { !$0.texts.isEmpty } ? [] : ["cleanup.readback.text"]
        let missing = missingNativeProbeIDs + missingValues + missingText
        throw failure("Native text/layout/values did not settle: \(context); missing probes: \(missing); required labels: \(labels.sorted()); \(diagnostics); \(snapshot.description)", code: 1)
    }

    /// Test defer blocks only hide. XCTest's strong teardown lease performs
    /// the actual detach after the final assertion or original wait failure.
    func close() { window.orderOut(nil) }

    private func dismantle() async {
        guard !isDismantled else { return }
        close()
        await Self.nextMainQueueTurn()
        isDismantled = true
        window.contentViewController = nil
        window.close()
    }

    private func failure(_ message: String, code: Int) -> NSError {
        // Log before throwing, matching V0's explicit probe failures. Preserve
        // diagnostics even if a native framework reports a secondary error.
        FileHandle.standardError.write(Data("Cleanup native fixture failure: \(message)\n".utf8))
        XCTFail(message)
        return NSError(domain: "MiniWindowCleanupPresentationTests", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func readNodes() -> [CleanupAccessibilitySnapshot.Node] {
        var result: [CleanupAccessibilitySnapshot.Node] = []
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject, depth: Int) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let role = text(object, "accessibilityRole")
            let modernValue = nativeText(accessibilityValue(object))
            let legacyValue = nativeText(legacyAttributeValue(object, .value))
            let modernValueDescription = text(object, "accessibilityValueDescription")
            let legacyValueDescription = nativeText(legacyAttributeValue(object, .valueDescription))
            // Keep every node for failure diagnostics, even empty containers,
            // windows and images; only the visible-text view excludes them.
            result.append(CleanupAccessibilitySnapshot.Node(depth: depth, typeName: String(describing: type(of: object)), role: role,
                label: text(object, "accessibilityLabel"), title: text(object, "accessibilityTitle"),
                value: modernValue ?? legacyValue ?? modernValueDescription ?? legacyValueDescription,
                help: text(object, "accessibilityHelp"), modernValue: modernValue, legacyValue: legacyValue,
                modernValueDescription: modernValueDescription, legacyValueDescription: legacyValueDescription))
            var children = [NSObject]()
            for selector in ["accessibilityChildrenInNavigationOrder", "accessibilityChildren", "accessibilityContents"] {
                children += (objectValue(object, selector) as? [Any] ?? []).compactMap { $0 as? NSObject }
            }
            // Match ConceptLandingNativeLayoutRegressionTests: a SwiftUI
            // scroll area may expose its primary content only through its
            // actual document view. All text still comes from native getters.
            if let scroll = object as? NSScrollView, let document = scroll.documentView {
                children.append(document)
            }
            children.forEach { collect($0, depth: depth + 1) }
        }
        collect(host, depth: 0)
        collect(window, depth: 0)
        return result
    }

    private func text(_ object: NSObject, _ name: String) -> String? {
        nativeText(objectValue(object, name))
    }

    private func nativeText(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let string = value as? NSAttributedString { return string.string.isEmpty ? nil : string.string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func accessibilityValue(_ object: NSObject) -> Any? {
        if let accessible = object as? any NSAccessibilityProtocol,
           let value = accessible.accessibilityValue() { return value }
        // SwiftUI's bridge need not statically adopt NSAccessibilityProtocol.
        return objectValue(object, "accessibilityValue")
    }

    private func legacyAttributeValue(_ object: NSObject, _ attribute: NSAccessibility.Attribute) -> AnyObject? {
        // Public deprecated getter on the SAME element, not a copied model
        // value or a lookup in other nodes. Preserve nil for missing values.
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector, with: attribute.rawValue as NSString)?.takeUnretainedValue()
    }

    private func objectValue(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
}

#if DEBUG
private struct CleanupRenderedSnapshot: Equatable {
    let fields: [String: GeekCleanupRenderedField]
    let frames: [String: CGRect]
    var viewportSize: CGSize { frames[GeekCleanupProbeID.viewport]?.size ?? .zero }
    var visibleText: String {
        fields.keys.sorted().compactMap { fields[$0] }
            .flatMap { field in [field.label] + [field.value, field.detail].compactMap { $0 } }.joined(separator: "\n")
    }
    var description: String { "rendered fields=\(fields); layout probes=\(frames)" }
}

@MainActor
private final class CleanupRenderedProbeRecorder {
    var fields: [String: GeekCleanupRenderedField] = [:]
    var frames: [String: CGRect] = [:]
}

/// Read only Preferences emitted by the actual page, never model.presentation.
/// The native host supplies strong ownership, window lifecycle and geometry;
/// this fixture does not call its AX snapshot method.
@MainActor
private final class CleanupRenderedReadbackHost {
    let native: CleanupAccessibilityReadbackHost
    private let recorder: CleanupRenderedProbeRecorder

    init<V: View>(view: V, width: CGFloat, testCase: XCTestCase) {
        let recorder = CleanupRenderedProbeRecorder()
        self.recorder = recorder
        let observed = view
            .onPreferenceChange(GeekCleanupRenderedPreferenceKey.self) { fields in
                Task { @MainActor in recorder.fields = fields }
            }
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in recorder.frames = frames }
            }
        native = CleanupAccessibilityReadbackHost(view: observed, width: width, testCase: testCase)
        testCase.addTeardownBlock { @MainActor [self] in
            native.close()
            await CleanupAccessibilityReadbackHost.nextMainQueueTurn()
        }
    }

    var window: NSWindow { native.window }
    var scrollView: NSScrollView? { native.scrollView }
    var diagnostics: String { native.diagnostics + "; " + current.description }
    private var current: CleanupRenderedSnapshot { .init(fields: recorder.fields, frames: recorder.frames) }
    func layout() { native.layout() }
    func close() { native.close() }
    func show() { window.orderFront(nil); native.layout() }
    func waitForLayout(context: String) async throws { try await native.waitForLayout(context: context) }

    func snapshot(requiredFrames: Set<String> = [GeekCleanupProbeID.viewport],
                  context: String) async throws -> CleanupRenderedSnapshot {
        show()
        try await native.waitForLayout(context: context)
        let requiredFields: Set<String> = [GeekCleanupProbeID.heading, GeekCleanupProbeID.notice,
            GeekCleanupProbeID.metric("safe-bytes"), GeekCleanupProbeID.metric("disk-free"), GeekCleanupProbeID.metric("actionable")]
        let deadline = Date().addingTimeInterval(5)
        var previous: CleanupRenderedSnapshot?
        var stable = 0
        while Date() < deadline {
            native.layout()
            await Task.yield()
            let snapshot = current
            let hasFields = requiredFields.isSubset(of: Set(snapshot.fields.keys))
            let hasFrames = requiredFrames.isSubset(of: Set(snapshot.frames.keys))
            if hasFields && hasFrames && snapshot.viewportSize.width > 0 && snapshot.viewportSize.height > 0 {
                stable = previous == snapshot ? stable + 1 : 0
                if stable >= 2 { return snapshot }
            } else { stable = 0 }
            previous = snapshot
        }
        let missingFields = requiredFields.subtracting(recorder.fields.keys).sorted()
        let missingFrames = requiredFrames.subtracting(recorder.frames.keys).sorted()
        let message = "Rendered body probes did not settle: \(context); missing fields=\(missingFields), missing frames=\(missingFrames); \(diagnostics)"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        XCTFail(message)
        throw NSError(domain: "MiniWindowCleanupPresentationTests.RenderedProbe", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif

@MainActor
private final class CleanupTestInputs {
    let session: CurrentValueSubject<ScanSession?, Never>
    let scanning: CurrentValueSubject<Bool, Never>
    let history: CurrentValueSubject<ScanHistorySummary, Never>
    private(set) var subscriptions = [0, 0, 0]
    private(set) var cancellations = [0, 0, 0]

    init(session: ScanSession?, isScanning: Bool = false) {
        self.session = CurrentValueSubject(session)
        scanning = CurrentValueSubject(isScanning)
        history = CurrentValueSubject(ScanHistorySummary(entries: []))
    }

    var source: MiniWindowCleanupSource {
        MiniWindowCleanupSource(
            session: session.handleEvents(receiveSubscription: { [weak self] _ in self?.subscriptions[0] += 1 },
                                          receiveCancel: { [weak self] in self?.cancellations[0] += 1 }),
            scanning: scanning.handleEvents(receiveSubscription: { [weak self] _ in self?.subscriptions[1] += 1 },
                                            receiveCancel: { [weak self] in self?.cancellations[1] += 1 }),
            history: history.handleEvents(receiveSubscription: { [weak self] _ in self?.subscriptions[2] += 1 },
                                          receiveCancel: { [weak self] in self?.cancellations[2] += 1 }),
            current: { [weak self] in
                guard let self else { return .empty }
                return .init(session: self.session.value, isScanning: self.scanning.value, history: self.history.value)
            })
    }
}

private actor CleanupTestGate {
    let passing: Int
    private(set) var arrivalCount = 0
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    init(passing: Int = 0) { self.passing = passing }
    func wait() async {
        arrivalCount += 1
        if isOpen || arrivalCount <= passing { return }
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { continuation.resume() }
                else { waiters[token] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }
    private func cancel(_ token: UUID) { waiters.removeValue(forKey: token)?.resume() }
    func release() {
        isOpen = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class CleanupPageLayoutRecorder {
    var settledSizes: [CGSize] = []
    var settlements: [GeekCleanupNaturalMeasurement] = []
    func record(_ measurement: GeekCleanupNaturalMeasurement?, model: MiniWindowCleanupDetailsModel) {
        guard let measurement else { return }
        let report = GeekDetailContentMeasurement(section: .cleanup, density: .geek, size: measurement.size,
            cleanupReadiness: .init(visibilityID: measurement.visibilityID, isReady: measurement.isReady,
                                   revision: measurement.revision))
        guard report.canReportSize(smartCleanup: true, cleanupIsVisible: model.isVisible,
            cleanupVisibilityID: model.visibilityID, cleanupRevision: model.layoutRevision) else { return }
        // Collapse only identical Preferences. A second, different height for
        // the same revision remains observable and fails the count assertions.
        if settlements.last != measurement { settlements.append(measurement) }
        if settledSizes.last != measurement.size { settledSizes.append(measurement.size) }
    }
}

private struct CleanupTestPageSizeKey: PreferenceKey {
    static let defaultValue: GeekCleanupNaturalMeasurement? = nil
    static func reduce(value: inout GeekCleanupNaturalMeasurement?, nextValue: () -> GeekCleanupNaturalMeasurement?) {
        if let next = nextValue() { value = next }
    }
}

@MainActor
private struct CleanupRetainingTestHost: View {
    @State var model: MiniWindowCleanupDetailsModel
    let source: MiniWindowCleanupSource
    let counter: CleanupParentRenderCounter
    let layout: CleanupPageLayoutRecorder
    var availableHeight: CGFloat? = nil
    var contentWidth: CGFloat = 312

    var body: some View {
        counter.count += 1
        return GeekSmartCleanupPage(model: model, source: source,
            diskTile: AdvancedMetricTileModel(id: "disk-free", title: "Disk", value: "560 GB", detail: "Available",
                                             tint: AppDesignTokens.Palette.information, progress: nil),
            diskAvailableText: "560 GB", showsExtendedDetails: true, actions: cleanupFixtureActions)
            .modifier(CleanupHeightOverride(height: availableHeight))
            .frame(width: contentWidth)
            .backgroundPreferenceValue(GeekCleanupLayoutReadinessKey.self) { readiness in
                GeometryReader { proxy in
                    Color.clear.preference(key: CleanupTestPageSizeKey.self,
                        value: readiness.visibilityID.map {
                            GeekCleanupNaturalMeasurement(visibilityID: $0, isReady: readiness.isReady,
                                size: readiness.preferredSize(in: proxy.size), revision: readiness.revision ?? 0)
                        })
                }
            }
            .onPreferenceChange(CleanupTestPageSizeKey.self) { measurement in
                Task { @MainActor in layout.record(measurement, model: model) }
            }
    }
}

private struct CleanupHeightOverride: ViewModifier {
    let height: CGFloat?
    @Environment(\.geekCleanupAvailableHeight) private var inheritedHeight
    func body(content: Content) -> some View {
        content.environment(\.geekCleanupAvailableHeight, height ?? inheritedHeight)
    }
}

@MainActor
private final class CleanupParentRefresh: ObservableObject {
    @Published var revision = 0
}

@MainActor
private struct CleanupRefreshingTestHost: View {
    @ObservedObject var refresh: CleanupParentRefresh
    let model: MiniWindowCleanupDetailsModel
    let inputs: CleanupTestInputs
    let counter: CleanupParentRenderCounter
    let layout: CleanupPageLayoutRecorder
    var body: some View {
        let _ = refresh.revision
        return CleanupRetainingTestHost(model: model, source: inputs.source, counter: counter, layout: layout)
    }
}

@MainActor
private var cleanupFixtureActions: GeekCleanupActions {
    GeekCleanupActions(showsExtendedDetails: true,
        reviewSafe: { XCTFail("Hosted fixture must not navigate") },
        reviewLargeFiles: { XCTFail("Hosted fixture must not navigate") },
        openMemory: { XCTFail("Hosted fixture must not navigate") })
}

@MainActor
private final class CleanupFixtureVisibility: ObservableObject {
    @Published var isShown = true
}

@MainActor
private struct CleanupReopeningTestHost: View {
    @ObservedObject var visibility: CleanupFixtureVisibility
    let model: MiniWindowCleanupDetailsModel
    let inputs: CleanupTestInputs
    let layout: CleanupPageLayoutRecorder
    var body: some View {
        if visibility.isShown {
            CleanupRetainingTestHost(model: model, source: inputs.source,
                counter: CleanupParentRenderCounter(), layout: layout)
        } else { Color.clear.frame(width: 312, height: 1) }
    }
}
