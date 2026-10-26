import Foundation
import XCTest
@testable import StorageCleanerMac

/// D100 G5: after access is granted elsewhere, coming back to the app reads
/// again only the roots the current scan could not read, offers each root
/// once, and scans only when the user asks.
@MainActor
final class ScanAccessReturnTests: XCTestCase {
    private let downloads = "/Fixture/Downloads"
    private let trash = "/Fixture/.Trash"

    func testNothingChangedOffersNothingAndKeepsCheckingLater() {
        var tracker = ScanAccessReturnTracker()
        let checked = tracker.pathsToCheck(in: permissions())
        XCTAssertEqual(checked, [downloads, trash])
        XCTAssertEqual(tracker.recordReadable([], among: checked), [])
        XCTAssertEqual(tracker.pathsToCheck(in: permissions()), [downloads, trash])
    }

    func testOnlyRootsThatBecameReadableAreOfferedAndOnlyOnce() {
        var tracker = ScanAccessReturnTracker()
        let checked = tracker.pathsToCheck(in: permissions())
        XCTAssertEqual(tracker.recordReadable([trash], among: checked), [trash])
        XCTAssertEqual(tracker.pathsToCheck(in: permissions()), [downloads])
        // Turning access off and on again does not offer the Trash a second time.
        XCTAssertEqual(tracker.recordReadable([trash, downloads], among: [trash, downloads]), [downloads])
        XCTAssertEqual(tracker.recordReadable([trash, downloads], among: [trash, downloads]), [])
        XCTAssertEqual(tracker.pathsToCheck(in: permissions()), [])
    }

    func testOnlyDeniedRootsAreReadAgainEachOnce() {
        let tracker = ScanAccessReturnTracker()
        let reports = permissions() + [
            CleanupPermissionReport(ruleID: "downloads.large-items", path: downloads, status: .permissionDenied),
            CleanupPermissionReport(ruleID: "caches", path: "/Fixture/Caches", status: .readable),
            CleanupPermissionReport(ruleID: "gone", path: "/Fixture/Gone", status: .missing),
            CleanupPermissionReport(ruleID: "broken", path: "/Fixture/Broken", status: .unreadable),
        ]
        XCTAssertEqual(tracker.pathsToCheck(in: reports), [downloads, trash])
    }

    func testNoticeNamesTheRulesOnceAndFallsBackToThePath() {
        let session = makeSession(permissions: permissions() + [
            CleanupPermissionReport(ruleID: "downloads.large-items", path: downloads, status: .permissionDenied),
        ])
        let notice = ScanAccessReturnNotice(
            session: session,
            readablePaths: [downloads, trash],
            ruleTitles: ["downloads.installers": "下载", "downloads.large-items": "下载"]
        )
        XCTAssertEqual(notice.sessionID, session.id)
        XCTAssertEqual(notice.titles, ["下载", trash])
    }

    func testReturningOffersARescanAndNothingScansUntilTheUserAsks() async throws {
        let session = makeSession(permissions: permissions())
        let scans = ScanCounter()
        let probed = ProbeLog()
        let store = try ScanStore.makeForTests(
            for: self,
            readableDirectories: { paths in
                probed.record(paths)
                return [paths[0]]
            },
            scanHistoryDefaults: ScanHistoryTestDefaults.defaults(named: ScanHistoryTestDefaults.makeSuite(for: self)),
            cleanupFeatureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
            cleanupScanOperation: { _, _ in
                scans.increment()
                return session
            }
        )
        store.startScan()
        try await waitUntil { !store.isScanning && store.cleanupScanSession?.id == session.id }
        XCTAssertEqual(scans.value, 1)

        store.checkAccessAfterReturn()
        try await waitUntil { store.accessReturnNotice != nil }
        XCTAssertEqual(probed.calls, [[downloads, trash]])
        XCTAssertEqual(store.accessReturnNotice?.paths, [downloads])
        XCTAssertEqual(scans.value, 1, "coming back never scans by itself")

        // Dismissed, the same root is not offered again; the other is read again.
        store.dismissAccessReturnNotice()
        store.checkAccessAfterReturn()
        try await waitUntil { probed.calls.count == 2 }
        try await settle()
        XCTAssertEqual(probed.calls.last, [trash])
        XCTAssertNotNil(store.accessReturnNotice, "the Trash became readable on the second read")
        XCTAssertEqual(store.accessReturnNotice?.paths, [trash])

        store.rescanAfterAccessReturn()
        XCTAssertNil(store.accessReturnNotice)
        try await waitUntil { scans.value == 2 && !store.isScanning }
    }

    func testIndependentReviewRescanKeepsTheCompletedSessionsScope() async throws {
        let session = makeSession(permissions: permissions())
        let requests = ReviewRequestScopeLog()
        let store = try ScanStore.makeForTests(
            for: self,
            readableDirectories: { Set($0) },
            cleanupFeatureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
            cleanupScanOperation: { request, _ in
                requests.record(request.includedRuleIDs)
                return session
            }
        )
        XCTAssertTrue(store.selectedSmartScanScopes.contains(.cleanupCandidates))
        XCTAssertTrue(store.selectedSmartScanScopes.contains(.filesToReview))
        store.startScan()
        try await waitUntil { !store.isScanning && store.cleanupScanSession?.id == session.id }
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertNil(requests.values[0])
        store.toggleSmartScanScope(.cleanupCandidates)
        store.checkAccessAfterReturn()
        try await waitUntil { store.accessReturnNotice != nil }
        store.rescanAfterAccessReturn()
        try await waitUntil { requests.values.count == 2 && !store.isScanning }
        print("REVIEW_RESCAN_SCOPE originalAllRules=\(requests.values[0] == nil) rerunAllRules=\(requests.values[1] == nil)")
        XCTAssertEqual(requests.values[1], requests.values[0],
                       "A rescan promised for the completed session must not silently use changed scope preferences")
    }

    /// Review A-R3: a narrowed Smart Scan reruns with its own scopes after the
    /// scopes changed, and the changed scopes stay as the user set them.
    func testRescanKeepsANarrowedSmartScanAndLeavesThePreferences() async throws {
        let requests = RequestLog()
        let store = try ScanStore.makeForTests(
            for: self,
            readableDirectories: { Set($0) },
            cleanupFeatureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
            cleanupScanOperation: { request, _ in
                requests.record(request)
                return Self.session(echoing: request, permissions: Self.deniedPermissions)
            }
        )
        store.toggleSmartScanScope(.filesToReview)
        let narrowed = store.selectedSmartScanScopes
        XCTAssertFalse(narrowed.contains(.filesToReview))
        store.startScan()
        try await waitUntil { !store.isScanning && store.cleanupScanSession != nil }
        let original = try XCTUnwrap(requests.values.first)
        XCTAssertNotNil(original.includedRuleIDs, "fixture: a narrowed Smart Scan names its rules")

        store.toggleSmartScanScope(.cleanupCandidates)
        store.toggleSmartScanScope(.filesToReview)
        let changed = store.selectedSmartScanScopes
        store.checkAccessAfterReturn()
        try await waitUntil { store.accessReturnNotice != nil }
        store.rescanAfterAccessReturn()
        try await waitUntil { requests.values.count == 2 && !store.isScanning }

        XCTAssertEqual(requests.values[1].includedRuleIDs, original.includedRuleIDs)
        XCTAssertEqual(requests.values[1].includedCategoryIDs, original.includedCategoryIDs)
        XCTAssertEqual(store.cleanupScanSession?.smartScanScopes, narrowed)
        XCTAssertEqual(store.selectedSmartScanScopes, changed, "the rescan leaves the scan preferences as they are")
        XCTAssertEqual(store.selectedFilter, .overview)
    }

    /// Review A-R3: a Safe Cleanup scan reruns with its own rules after the
    /// Safe Cleanup scopes changed, and the changed scopes stay.
    func testRescanKeepsASafeCleanupSessionsRulesAndLeavesThePreferences() async throws {
        let requests = RequestLog()
        let store = try ScanStore.makeForTests(
            for: self,
            readableDirectories: { Set($0) },
            cleanupFeatureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
            cleanupScanOperation: { request, _ in
                requests.record(request)
                return Self.session(echoing: request, permissions: Self.deniedPermissions)
            }
        )
        store.selectedFilter = .green
        store.startScan()
        try await waitUntil { !store.isScanning && store.cleanupScanSession != nil }
        let original = try XCTUnwrap(requests.values.first)
        let originalRules = try XCTUnwrap(original.includedRuleIDs)
        XCTAssertFalse(originalRules.isEmpty)

        // D192＋旧值：A-R3 原先关闭 caches，现在关闭包含缓存的 systemJunk。
        store.toggleSafeCleanupScope(.systemJunk)
        let changed = store.selectedSafeCleanupScopes
        XCTAssertFalse(changed.contains(.systemJunk))
        store.checkAccessAfterReturn()
        try await waitUntil { store.accessReturnNotice != nil }
        store.rescanAfterAccessReturn()
        try await waitUntil { requests.values.count == 2 && !store.isScanning }

        XCTAssertEqual(requests.values[1].includedRuleIDs, originalRules)
        XCTAssertEqual(requests.values[1].includedCategoryIDs, original.includedCategoryIDs)
        XCTAssertEqual(store.selectedFilter, .green, "the rescan runs from the scan's own page")
        XCTAssertEqual(store.selectedSafeCleanupScopes, changed, "the rescan leaves the scan preferences as they are")
    }

    func testTheAppChecksOnReturnAndOnlyTheBannerButtonRescans() throws {
        let sources = try SwiftSourceScanning.sources()
        let app = try XCTUnwrap(sources["Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"])
        let activation = try XCTUnwrap(app.range(of: "for: NSApplication.didBecomeActiveNotification"))
        let handler = app[activation.upperBound...].prefix(900)
        XCTAssertTrue(handler.contains("store.checkAccessAfterReturn()"))
        let views = try XCTUnwrap(sources["Sources/StorageCleanerMac/Views/CleanupScanViews.swift"])
        XCTAssertEqual(views.components(separatedBy: "store.rescanAfterAccessReturn()").count - 1, 1)
        XCTAssertEqual(views.components(separatedBy: "CleanupAccessReturnBanner(store: store, notice: notice)").count - 1, 2)
    }

    // MARK: D104 G5: only the newly readable locations

    /// With the rules the session was scanned with, the locations that became
    /// readable are scanned as part of the same session: only their rules
    /// run, what they find joins the results, the rest is not read again and
    /// no second history entry is written. Review A-R3 still holds: changed
    /// scan preferences neither narrow the scan nor are changed by it.
    func testScanningNewLocationsRunsOnlyTheirRulesAndAddsToTheSameResults() async throws {
        let fixture = try NewLocationScanFixture()
        let history = ScanHistoryTestDefaults.defaults(named: ScanHistoryTestDefaults.makeSuite(for: self))
        let store = try makeStore(fixture, history: history)
        store.startScan()
        try await waitUntil { !store.isScanning && store.cleanupScanSession != nil }
        let original = try XCTUnwrap(store.cleanupScanSession)
        let cache = NewLocationScanFixture.cacheID
        XCTAssertEqual(store.cleanupSelection.selectedCandidateIDs, [cache], "fixture: the green row is preselected")
        store.setCleanupCandidate(cache, selected: false)
        let entries = ScanHistoryService.load(defaults: history).count
        XCTAssertEqual(entries, 1, "fixture: the scan was recorded")

        store.toggleSmartScanScope(.filesToReview)
        let changedScopes = store.selectedSmartScanScopes
        store.selectedFilter = .green
        store.checkAccessAfterReturn()
        try await waitUntil { store.accessReturnNotice != nil }
        XCTAssertEqual(
            Set(store.accessReturnNotice?.paths ?? []),
            [NewLocationScanFixture.logsPath, NewLocationScanFixture.historyPath]
        )
        store.rescanAfterAccessReturn()
        XCTAssertNil(store.accessReturnNotice)
        try await waitUntil { fixture.requests.count == 2 && !store.isScanning }

        let request = fixture.requests[1]
        // D227＋旧值：was ["system.user-logs", "downloads.installers"]. D227 retired the Downloads rules, and a
        // rule that no longer ships sends the rescan down the review A-R3 path; the review-only rule that
        // still ships takes the second location's place, so this still checks that only those rules run.
        XCTAssertEqual(request.includedRuleIDs, ["system.user-logs", "user-data.istat-menus-setapp-history"])
        XCTAssertNil(request.includedCategoryIDs)
        XCTAssertEqual(request.sessionID, original.id)
        XCTAssertEqual(request.developerInactivityThresholdDays, original.developerInactivityThresholdDays)
        let merged = try XCTUnwrap(store.cleanupScanSession)
        print("G5_NEW_LOCATIONS rules=\(request.includedRuleIDs?.sorted() ?? []) sameSession=\(merged.id == original.id) rows=\(merged.candidates.count) outcome=\(merged.outcome) history=\(ScanHistoryService.load(defaults: history).count)")
        XCTAssertEqual(merged.id, original.id)
        XCTAssertEqual(
            merged.candidates.map(\.id),
            [cache, NewLocationScanFixture.logID, NewLocationScanFixture.historyID]
        )
        XCTAssertEqual(merged.outcome, .complete)
        XCTAssertTrue(merged.permissions.allSatisfy { $0.status == .readable })
        XCTAssertEqual(merged.smartScanScopes, original.smartScanScopes)
        XCTAssertEqual(
            store.cleanupSelection.selectedCandidateIDs,
            [NewLocationScanFixture.logID],
            "the cleared row stays cleared; the added green row is preselected, the yellow one is not"
        )
        XCTAssertEqual(ScanHistoryService.load(defaults: history).count, entries, "no second history entry")
        XCTAssertEqual(store.scanPresentationState, .results)
        XCTAssertEqual(store.selectedFilter, .overview, "the scan runs from the session's own page")
        XCTAssertEqual(store.selectedSmartScanScopes, changedScopes, "the scan preferences stay as they are")
        XCTAssertEqual(fixture.requests.count, 2)
    }

    /// Stopping the scan of the new locations, whether the scan throws or
    /// reports itself cancelled, leaves the results as they were and offers
    /// the locations again.
    func testStoppingTheScanOfNewLocationsKeepsTheResultsAndOffersThemAgain() async throws {
        for outcome in [NewLocationScanFixture.Rescan.waitsForCancel, .reportsCancelled] {
            let fixture = try NewLocationScanFixture(rescan: outcome)
            let (store, original, notice) = try await scannedStoreWithNotice(fixture)
            let selection = store.cleanupSelection.selectedCandidateIDs

            store.rescanAfterAccessReturn()
            if outcome == .waitsForCancel {
                try await waitUntil { fixture.requests.count == 2 && store.canCancelMainScan }
                store.cancelMainScan()
            }
            try await waitUntil { fixture.requests.count == 2 && !store.isScanning }

            assertUnchanged(store, original: original, selection: selection)
            XCTAssertEqual(store.accessReturnNotice?.paths, notice.paths, "\(outcome)")
            XCTAssertEqual(store.accessReturnNotice?.sessionID, original.id, "\(outcome)")
            XCTAssertNil(store.errorMessage, "\(outcome)")
        }
    }

    /// A scan of the new locations that fails, or reports none of them,
    /// leaves the results as they were and offers the locations again.
    func testAFailedScanOfNewLocationsKeepsTheResultsAndOffersThemAgain() async throws {
        for outcome in [NewLocationScanFixture.Rescan.fails, .reportsNothing] {
            let fixture = try NewLocationScanFixture(rescan: outcome)
            let (store, original, notice) = try await scannedStoreWithNotice(fixture)
            let selection = store.cleanupSelection.selectedCandidateIDs

            store.rescanAfterAccessReturn()
            try await waitUntil { fixture.requests.count == 2 && !store.isScanning }

            assertUnchanged(store, original: original, selection: selection)
            XCTAssertEqual(store.accessReturnNotice?.paths, notice.paths, "\(outcome)")
            XCTAssertNotNil(store.errorMessage, "\(outcome)")
        }
    }

    /// Review A-R3 fallback: when the rules changed since the scan (another
    /// version or fingerprint), the session's own coverage is scanned again
    /// as a new scan instead.
    func testRulesThatChangedSinceTheScanRescanTheWholeSession() async throws {
        let older = CleanupRuleSetProvenance(fingerprint: "older", rules: [])
        for fixture in [
            try NewLocationScanFixture(rulesVersion: "g5.older"),
            try NewLocationScanFixture(provenance: older),
        ] {
            let (store, original, _) = try await scannedStoreWithNotice(fixture)
            store.rescanAfterAccessReturn()
            try await waitUntil { fixture.requests.count == 2 && !store.isScanning }

            let first = fixture.requests[0]
            let rescan = fixture.requests[1]
            XCTAssertNil(rescan.sessionID)
            XCTAssertEqual(rescan.includedRuleIDs, first.includedRuleIDs)
            XCTAssertEqual(rescan.includedCategoryIDs, first.includedCategoryIDs)
            XCTAssertNotEqual(store.cleanupScanSession?.id, original.id)
        }
    }

    private func makeStore(_ fixture: NewLocationScanFixture, history: UserDefaults? = nil) throws -> ScanStore {
        try ScanStore.makeForTests(
            for: self,
            readableDirectories: { Set($0) },
            scanHistoryDefaults: history,
            cleanupFeatureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
            cleanupScanOperation: { request, _ in try await fixture.scan(request) }
        )
    }

    private func scannedStoreWithNotice(
        _ fixture: NewLocationScanFixture
    ) async throws -> (ScanStore, ScanSession, ScanAccessReturnNotice) {
        let store = try makeStore(fixture)
        store.startScan()
        try await waitUntil { !store.isScanning && store.cleanupScanSession != nil }
        let original = try XCTUnwrap(store.cleanupScanSession)
        store.checkAccessAfterReturn()
        try await waitUntil { store.accessReturnNotice != nil }
        return (store, original, try XCTUnwrap(store.accessReturnNotice))
    }

    private func assertUnchanged(
        _ store: ScanStore,
        original: ScanSession,
        selection: Set<ScanCandidateID>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(store.cleanupScanSession?.id, original.id, file: file, line: line)
        XCTAssertEqual(store.cleanupScanSession?.candidates.map(\.id), original.candidates.map(\.id), file: file, line: line)
        XCTAssertEqual(store.cleanupScanSession?.outcome, original.outcome, file: file, line: line)
        XCTAssertEqual(
            store.cleanupScanSession?.permissions.map(\.status),
            original.permissions.map(\.status),
            file: file, line: line
        )
        XCTAssertEqual(store.cleanupSelection.selectedCandidateIDs, selection, file: file, line: line)
        XCTAssertEqual(store.scanPresentationState, .results, file: file, line: line)
    }

    // MARK: Helpers

    private func permissions() -> [CleanupPermissionReport] {
        [
            CleanupPermissionReport(ruleID: "downloads.installers", path: downloads, status: .permissionDenied),
            CleanupPermissionReport(ruleID: "trash", path: trash, status: .permissionDenied),
        ]
    }

    // "fixture.1" is not the bundled rules version, so the rescans in the
    // tests above that use these sessions take the review A-R3 path (D104).
    nonisolated private static let deniedPermissions = [
        CleanupPermissionReport(ruleID: "downloads.installers", path: "/Users/fixture/Downloads", status: .permissionDenied),
    ]

    /// Records the request's scope in the session, as the scanner does.
    nonisolated private static func session(echoing request: CleanupScanRequest,
                                            permissions: [CleanupPermissionReport]) -> ScanSession {
        ScanSession(
            id: ScanSessionID(), rulesVersion: "fixture.1", startedAt: Date(), completedAt: Date(),
            outcome: .partial, categories: [], issues: [], permissions: permissions,
            metrics: ScanMetrics(visitedEntryCount: 0, candidateCount: 0, deduplicatedIdentityCount: 0,
                                 estimatedCandidateBytes: 0, permissionFailureCount: permissions.count, duration: 0),
            includedCategoryIDs: request.includedCategoryIDs,
            includedRuleIDs: request.includedRuleIDs
        )
    }

    private func makeSession(permissions: [CleanupPermissionReport]) -> ScanSession {
        ScanSession(
            id: ScanSessionID(), rulesVersion: "fixture.1", startedAt: Date(), completedAt: Date(),
            outcome: .partial, categories: [], issues: [], permissions: permissions,
            metrics: ScanMetrics(visitedEntryCount: 0, candidateCount: 0, deduplicatedIdentityCount: 0,
                                 estimatedCandidateBytes: 0, permissionFailureCount: permissions.count, duration: 0)
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }
}

private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [[String]]()
    var calls: [[String]] { lock.withLock { recorded } }
    func record(_ paths: [String]) { lock.withLock { recorded.append(paths) } }
}

private final class ReviewRequestScopeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var scopes: [Set<String>?] = []
    var values: [Set<String>?] { lock.withLock { scopes } }
    func record(_ value: Set<String>?) { lock.withLock { scopes.append(value) } }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CleanupScanRequest] = []
    var values: [CleanupScanRequest] { lock.withLock { requests } }
    func record(_ request: CleanupScanRequest) { lock.withLock { requests.append(request) } }
}

/// D104 G5: a scan operation that answers like the scanner with the bundled
/// rules. The first scan reads the caches but not the logs or the iStat Menus
/// history folder; a scan of those two finds one row in each. (D227＋旧值:
/// the second location was Downloads with `downloads.installers`, retired by
/// D227; a rule the session names must still ship for this path.)
private final class NewLocationScanFixture: @unchecked Sendable {
    enum Rescan { case finds, waitsForCancel, reportsCancelled, fails, reportsNothing }

    static let cachesPath = "/G5Fixture/Library/Caches"
    static let logsPath = "/G5Fixture/Library/Logs"
    static let historyPath = "/G5Fixture/Library/Application Support/iStat Menus 7 (Setapp)"
    static let cacheID = RescanFixtureRows.id("system.user-caches", cachesPath + "/com.example.app")
    static let logID = RescanFixtureRows.id("system.user-logs", logsPath + "/com.example.app")
    static let historyID = RescanFixtureRows.id("user-data.istat-menus-setapp-history", historyPath + "/history")

    private let rescan: Rescan
    private let rulesVersion: String
    private let provenance: CleanupRuleSetProvenance
    private let lock = NSLock()
    private var recorded = [CleanupScanRequest]()

    init(rescan: Rescan = .finds, rulesVersion: String? = nil, provenance: CleanupRuleSetProvenance? = nil) throws {
        let rules = try CleanupRuleSetLoader.loadBundled()
        self.rescan = rescan
        self.rulesVersion = rulesVersion ?? rules.rulesVersion
        self.provenance = provenance ?? rules.effectiveProvenance
    }

    var requests: [CleanupScanRequest] { lock.withLock { recorded } }

    func scan(_ request: CleanupScanRequest) async throws -> ScanSession {
        lock.withLock { recorded.append(request) }
        guard let sessionID = request.sessionID else { return firstScan(request) }
        switch rescan {
        case .finds:
            return newLocations(sessionID, request: request)
        case .waitsForCancel:
            try await Task.sleep(for: .seconds(60))
            return newLocations(sessionID, request: request)
        case .reportsCancelled:
            return RescanFixtureRows.session(
                id: sessionID, outcome: .cancelled, groups: [], permissions: [],
                rulesVersion: rulesVersion, provenance: provenance
            )
        case .fails:
            throw CocoaError(.fileReadUnknown)
        case .reportsNothing:
            return session(sessionID, request: request, groups: [], permissions: [],
                           issues: [ScanIssue(ruleID: nil, path: nil, kind: .timedOut)])
        }
    }

    private func firstScan(_ request: CleanupScanRequest) -> ScanSession {
        let id = ScanSessionID()
        let cache = RescanFixtureRows.candidate(
            "system.user-caches", Self.cachesPath + "/com.example.app", sessionID: id, inode: 1, bytes: 4_096
        )
        return session(
            id,
            request: request,
            groups: [
                ("system", [("system.user-caches", [cache]), ("system.user-logs", [])]),
                ("user-data", [("user-data.istat-menus-setapp-history", [])]),
            ],
            permissions: [
                CleanupPermissionReport(ruleID: "system.user-caches", path: Self.cachesPath, status: .readable),
                CleanupPermissionReport(ruleID: "system.user-logs", path: Self.logsPath, status: .permissionDenied),
                CleanupPermissionReport(ruleID: "user-data.istat-menus-setapp-history", path: Self.historyPath,
                                        status: .permissionDenied),
            ],
            issues: [
                ScanIssue(ruleID: "system.user-logs", path: Self.logsPath, kind: .permissionDenied),
                ScanIssue(ruleID: "user-data.istat-menus-setapp-history", path: Self.historyPath, kind: .permissionDenied),
            ]
        )
    }

    private func newLocations(_ id: ScanSessionID, request: CleanupScanRequest) -> ScanSession {
        let log = RescanFixtureRows.candidate(
            "system.user-logs", Self.logsPath + "/com.example.app", sessionID: id, inode: 2, bytes: 8_192
        )
        let history = RescanFixtureRows.candidate(
            "user-data.istat-menus-setapp-history", Self.historyPath + "/history", sessionID: id, inode: 3, bytes: 16_384,
            risk: .reviewOnly
        )
        return session(
            id,
            request: request,
            groups: [
                ("system", [("system.user-logs", [log])]),
                ("user-data", [("user-data.istat-menus-setapp-history", [history])]),
            ],
            permissions: [
                CleanupPermissionReport(ruleID: "system.user-logs", path: Self.logsPath, status: .readable),
                CleanupPermissionReport(ruleID: "user-data.istat-menus-setapp-history", path: Self.historyPath, status: .readable),
            ]
        )
    }

    private func session(
        _ id: ScanSessionID,
        request: CleanupScanRequest,
        groups: [(String, [(String, [ScanCandidate])])],
        permissions: [CleanupPermissionReport],
        issues: [ScanIssue] = []
    ) -> ScanSession {
        RescanFixtureRows.session(
            id: id,
            outcome: issues.isEmpty ? .complete : .partial,
            groups: groups,
            permissions: permissions,
            issues: issues,
            rulesVersion: rulesVersion,
            provenance: provenance,
            developerInactivityThresholdDays: request.developerInactivityThresholdDays,
            includedCategoryIDs: request.includedCategoryIDs,
            includedRuleIDs: request.includedRuleIDs
        )
    }
}
