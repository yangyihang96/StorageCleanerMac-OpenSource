import Foundation
import XCTest
@testable import StorageCleanerMac

final class ScanScopeHistoryTests: XCTestCase {
    func testEveryScopePairComparesOnlyEqualCoverage() throws {
        for latestMask in 1..<8 {
            for previousMask in 1..<8 {
                let latest = entry(at: 200, scopes: scopes(latestMask), score: 93, green: 300, review: 0)
                let previous = entry(at: 100, scopes: scopes(previousMask), score: 41, green: 100, review: 800)
                let summary = ScanHistorySummary(entries: [latest, previous])
                if latestMask == previousMask {
                    let trend = try XCTUnwrap(summary.trend)
                    XCTAssertEqual(trend.scoreDelta, 52)
                    XCTAssertEqual(trend.greenDeltaBytes, 200)
                    XCTAssertEqual(trend.reviewDeltaBytes, -800)
                    XCTAssertEqual(trend.usedDeltaBytes, 100)
                    XCTAssertEqual(summary.usedDeltaBytes, 100)
                } else {
                    XCTAssertNil(summary.trend, "Unscanned review items and scores must not become a zero-based comparison: \(latestMask)/\(previousMask)")
                    XCTAssertNil(summary.usedDeltaBytes)
                    XCTAssertNil(summary.comparablePrevious)
                }
                XCTAssertEqual(summary.previous, previous, "The chronological previous record remains available")
            }
        }
    }

    func testTrendFindsNearestMatchingCoverageAcrossInterveningScans() throws {
        let latest = entry(at: 400, scopes: [.cleanupCandidates], score: 92, green: 300, review: 0)
        let full = entry(at: 300, scopes: SmartScanScope.defaultSelection, score: 40, green: 900, review: 800)
        let same = entry(at: 200, scopes: [.cleanupCandidates], score: 90, green: 350, review: 0)
        let older = entry(at: 100, scopes: [.cleanupCandidates], score: 50, green: 800, review: 0)
        let summary = ScanHistorySummary(entries: [latest, full, same, older])
        let trend = try XCTUnwrap(summary.trend)
        XCTAssertEqual(trend.latest, latest)
        XCTAssertEqual(trend.previous, same)
        XCTAssertEqual(trend.scoreDelta, 2)
        XCTAssertEqual(trend.greenDeltaBytes, -50)
        XCTAssertEqual(trend.reviewDeltaBytes, 0, "Review was unrequested in both compared runs")
        XCTAssertEqual(summary.usedDeltaBytes, 200)
    }

    func testLegacyRecordsKeepTrendCoverageButDoNotFeedGlobalCleanupSummary() throws {
        let legacy = entry(at: 100, scopes: nil, score: 80, green: 128, review: 256)
        let full = entry(at: 200, scopes: SmartScanScope.defaultSelection, score: 90, green: 64, review: 256)
        XCTAssertEqual(ScanHistorySummary(entries: [full, legacy]).trend?.previous, legacy)
        XCTAssertEqual(legacy.completedScopes, SmartScanScope.defaultSelection)
        XCTAssertFalse(legacy.coversCleanupCandidates)
        XCTAssertNil(ScanHistorySummary(entries: [legacy]).latestCleanupEntry)
        let partial = entry(at: 200, scopes: [.cleanupCandidates], score: 95, green: 64, review: 0)
        XCTAssertNil(ScanHistorySummary(entries: [partial, legacy]).trend)
        let noHealth = entry(at: 200, scopes: [.cleanupCandidates, .filesToReview], score: 95, green: 64, review: 256)
        XCTAssertNil(ScanHistorySummary(entries: [noHealth, legacy]).trend, "Health coverage is also retained")
    }

    func testJunkHistoryStatusRetainsItsOwnFreshnessAndRealZeroMeansScanned() throws {
        let junk = entry(at: 100, scopes: [.cleanupCandidates], score: 95, green: 0, review: 0)
        let review = entry(at: 200, scopes: [.filesToReview], score: 50, green: 999, review: 512)
        let summary = ScanHistorySummary(entries: [review, junk])
        let reference = Date(timeIntervalSince1970: 200)
        let status = try XCTUnwrap(summary.latestCleanupStatus(referenceDate: reference))
        XCTAssertEqual(status.entry, junk, "Coverage takes priority even over nonzero injected junk counts")
        XCTAssertEqual(status.freshness, ScanFreshnessService.summary(generatedAt: junk.date, referenceDate: reference))
        XCTAssertEqual(status.entry.greenBytes, 0)
        XCTAssertEqual(summary.latestStatus(referenceDate: reference)?.entry, review)
        XCTAssertNil(ScanHistorySummary(entries: [review]).latestCleanupStatus())
    }

    func testReminderTimePersistsWithoutFabricatingFileHistoryAndClearsWithHistory() {
        let suiteName = makeHistorySuite()
        let defaults = ScanHistoryTestDefaults.defaults(named: suiteName)
        XCTAssertEqual(ScanHistoryService.summary(defaults: defaults), ScanHistorySummary(entries: []))
        XCTAssertNil(defaults.object(forKey: ScanHistoryService.defaultsKey))
        XCTAssertNil(defaults.object(forKey: ScanHistoryService.lastCompletedScanKey))
        let healthDate = Date(timeIntervalSince1970: 300)
        ScanHistoryService.recordCompletedScan(at: healthDate, defaults: defaults)
        let summary = ScanHistoryService.summary(defaults: defaults)
        XCTAssertTrue(summary.entries.isEmpty)
        XCTAssertNil(summary.latestCleanupEntry)
        XCTAssertNil(summary.latestStatus())
        XCTAssertEqual(summary.latestScanAt, healthDate)
        ScanHistoryService.record(entry(at: 100, scopes: [.filesToReview], score: 80, green: 0, review: 256), defaults: defaults)
        XCTAssertEqual(ScanHistoryService.summary(defaults: defaults).latestScanAt, healthDate,
            "Loading or inserting older history must not rewind the reminder")
        let reopened = ScanHistoryTestDefaults.defaults(named: suiteName)
        XCTAssertEqual(ScanHistoryService.load(defaults: reopened).count, 1)
        XCTAssertEqual(ScanHistoryService.summary(defaults: reopened).latestScanAt, healthDate)
        ScanHistoryService.clear(defaults: reopened)
        XCTAssertEqual(ScanHistoryService.summary(defaults: defaults), ScanHistorySummary(entries: []))
        XCTAssertNil(defaults.object(forKey: ScanHistoryService.lastCompletedScanKey))
        let cleared = ScanHistoryTestDefaults.defaults(named: suiteName)
        XCTAssertTrue(ScanHistoryService.load(defaults: cleared).isEmpty)
        XCTAssertNil(cleared.object(forKey: ScanHistoryService.defaultsKey))
        XCTAssertNil(cleared.object(forKey: ScanHistoryService.lastCompletedScanKey))
        XCTAssertNil(ScanHistoryService.summary(defaults: cleared).latestScanAt)
    }

    func testHealthOnlyReminderClearsWithoutFileHistoryWhenReopened() {
        let suiteName = makeHistorySuite()
        let defaults = ScanHistoryTestDefaults.defaults(named: suiteName)
        XCTAssertEqual(ScanHistoryService.summary(defaults: defaults), ScanHistorySummary(entries: []))
        let healthDate = Date(timeIntervalSince1970: 600)
        ScanHistoryService.recordCompletedScan(at: healthDate, defaults: defaults)
        let reopened = ScanHistoryTestDefaults.defaults(named: suiteName)
        XCTAssertNil(reopened.object(forKey: ScanHistoryService.defaultsKey))
        XCTAssertEqual(ScanHistoryService.summary(defaults: reopened).latestScanAt, healthDate)
        ScanHistoryService.clear(defaults: reopened)
        let cleared = ScanHistoryTestDefaults.defaults(named: suiteName)
        XCTAssertEqual(ScanHistoryService.summary(defaults: cleared), ScanHistorySummary(entries: []))
        XCTAssertNil(cleared.object(forKey: ScanHistoryService.lastCompletedScanKey))
        XCTAssertNil(ScanHistoryService.summary(defaults: cleared).latestScanAt)
    }

    func testHistoryPreferenceDomainsStayIndependentInBothClearOrders() {
        for order in [[0, 1], [1, 0]] {
            let suiteNames = [makeHistorySuite(), makeHistorySuite()]
            XCTAssertNotEqual(suiteNames[0], suiteNames[1])
            for index in suiteNames.indices {
                let defaults = ScanHistoryTestDefaults.defaults(named: suiteNames[index])
                XCTAssertEqual(ScanHistoryService.summary(defaults: defaults), ScanHistorySummary(entries: []))
                ScanHistoryService.record(entry(at: Double(100 + index), scopes: [.cleanupCandidates],
                    score: 90, green: Int64(64 + index), review: 0), defaults: defaults)
                ScanHistoryService.recordCompletedScan(at: Date(timeIntervalSince1970: Double(300 + index)),
                    defaults: defaults)
                defaults.set("keep-\(index)", forKey: "scope-history.unrelated")
            }
            let summaries = suiteNames.map { name in
                ScanHistoryService.summary(defaults: ScanHistoryTestDefaults.defaults(named: name))
            }
            var clearedIndices = Set<Int>()
            for index in order {
                ScanHistoryService.clear(defaults: ScanHistoryTestDefaults.defaults(named: suiteNames[index]))
                clearedIndices.insert(index)
                for other in suiteNames.indices {
                    let defaults = ScanHistoryTestDefaults.defaults(named: suiteNames[other])
                    let expected = clearedIndices.contains(other) ? ScanHistorySummary(entries: []) : summaries[other]
                    XCTAssertEqual(ScanHistoryService.summary(defaults: defaults), expected,
                        "Clearing one domain must not change another domain, in either order: \(order)")
                    XCTAssertEqual(defaults.string(forKey: "scope-history.unrelated"), "keep-\(other)")
                    if clearedIndices.contains(other) {
                        XCTAssertNil(defaults.object(forKey: ScanHistoryService.defaultsKey))
                        XCTAssertNil(defaults.object(forKey: ScanHistoryService.lastCompletedScanKey))
                    }
                }
            }
        }
    }

    func testOldPreferencesDeriveReminderTimeFromFileHistory() throws {
        let defaults = ScanHistoryTestDefaults.defaults(named: makeHistorySuite())
        XCTAssertEqual(ScanHistoryService.summary(defaults: defaults), ScanHistorySummary(entries: []))
        let legacy = entry(at: 100, scopes: nil, score: 90, green: 64, review: 128)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: ScanHistoryService.defaultsKey)
        let summary = ScanHistoryService.summary(defaults: defaults)
        XCTAssertNil(summary.lastCompletedScanAt)
        XCTAssertEqual(summary.latestScanAt, legacy.date)
        XCTAssertNil(summary.latestCleanupEntry)
    }

    func testFutureReminderTimeIsReplacedByTheCompletedScanAndStaysCorrectAfterReopen() throws {
        let suiteName = makeHistorySuite()
        let defaults = ScanHistoryTestDefaults.defaults(named: suiteName)
        let current = Date(timeIntervalSince1970: 1_000)
        let future = Date(timeIntervalSince1970: 2_000)
        let older = Date(timeIntervalSince1970: 900)
        XCTAssertEqual(ScanHistoryService.summary(defaults: defaults), ScanHistorySummary(entries: []))
        defaults.set(future, forKey: ScanHistoryService.lastCompletedScanKey)
        let futureHistory = entry(at: 2_000, scopes: [.cleanupCandidates],
            score: 90, green: 64, review: 0)
        defaults.set(try JSONEncoder().encode([futureHistory]), forKey: ScanHistoryService.defaultsKey)

        ScanHistoryService.recordCompletedScan(at: current, defaults: defaults, referenceDate: current)
        let reopened = ScanHistoryTestDefaults.defaults(named: suiteName)
        XCTAssertEqual(reopened.object(forKey: ScanHistoryService.lastCompletedScanKey) as? Date, current)
        XCTAssertEqual(ScanHistoryService.summary(defaults: reopened).latestScanAt, current,
            "A future-dated file row must not resurrect the corrected reminder time")
        ScanHistoryService.recordCompletedScan(at: older, defaults: reopened,
            referenceDate: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(ScanHistoryService.summary(defaults: defaults).latestScanAt, current,
            "A valid previous reminder remains monotonic")
    }

    private func makeHistorySuite() -> String {
        // This factory uses TestPreferenceDomain and owns both history keys in
        // one unique temporary suite. It also checks the standard history key.
        let name = ScanHistoryTestDefaults.makeSuite(for: self)
        let reminderBefore = UserDefaults.standard.object(forKey: ScanHistoryService.lastCompletedScanKey) as? Date
        addTeardownBlock {
            XCTAssertEqual(UserDefaults.standard.object(forKey: ScanHistoryService.lastCompletedScanKey) as? Date,
                reminderBefore, "The test wrote its reminder time to UserDefaults.standard")
        }
        return name
    }

    private func scopes(_ mask: Int) -> Set<SmartScanScope> {
        Set(SmartScanScope.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
    }

    private func entry(at seconds: TimeInterval, scopes: Set<SmartScanScope>?, score: Int,
                       green: Int64, review: Int64) -> ScanHistoryEntry {
        ScanHistoryEntry(date: Date(timeIntervalSince1970: seconds), scanSeconds: 1, score: score,
            diskUsedBytes: Int64(seconds), diskFreeBytes: 1000 - Int64(seconds),
            greenBytes: green, yellowBytes: review, redBytes: 0, itemCount: 2,
            greenCount: green == 0 ? 0 : 1, yellowCount: review == 0 ? 0 : 1, redCount: 0, deniedCount: 0,
            smartScanScopes: scopes, smartScanHealthStatus: scopes == nil ? nil : .notRequested)
    }
}
