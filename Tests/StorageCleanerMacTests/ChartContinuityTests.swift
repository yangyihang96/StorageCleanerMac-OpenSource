import XCTest
import SwiftUI
@testable import StorageCleanerMac

final class ChartContinuityTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 100_000)

    private func buckets(_ offsets: [Double], duration: Double,
                         valid: (Int) -> Bool = { _ in true },
                         starts: [Date?] = []) -> [GeekChartBucketSnapshot] {
        let dates = offsets.map { origin.addingTimeInterval($0) }
        return GeekChartWindow.displayBuckets(for: dates,
            in: CGRect(x: 0, y: 0, width: 360, height: 100),
            range: (origin, origin.addingTimeInterval(duration), origin),
            referenceDate: origin.addingTimeInterval(duration), displayScale: 2,
            isValid: valid, intervalStart: { starts.indices.contains($0) ? starts[$0] : nil })
    }

    func testNormalSlowCadencesRemainContinuousWithoutInventingObservedPolls() {
        for interval in [1.0, 2, 15, 30, 60] {
            let frames = buckets((0...10).map { Double($0) * interval }, duration: interval * 10)
            XCTAssertEqual(frames.count, 120)
            XCTAssertTrue(frames.allSatisfy { !$0.indices.isEmpty }, "cadence \(interval)")
            XCTAssertTrue(frames.contains(where: \.isEstimated))
            XCTAssertEqual(frames.filter { !$0.isEstimated }.count, 11)
        }
    }

    func testTwoMissedPollsAreEstimatedButLongOutageRemainsUnrecorded() {
        let short = buckets([0, 1, 2, 5, 6, 7, 8], duration: 8)
        XCTAssertTrue(short.allSatisfy { !$0.indices.isEmpty })
        let long = buckets([0, 1, 2, 100, 101, 102, 103], duration: 103)
        XCTAssertTrue(long.contains { $0.indices.isEmpty && $0.start > origin.addingTimeInterval(10) })
    }

    func testExplicitUnavailableChannelBreaksEvenAShortGap() {
        let frames = buckets([0, 1, 2, 3, 4, 5, 6], duration: 6, valid: { $0 != 3 })
        XCTAssertTrue(frames.contains { $0.indices.isEmpty && $0.start > origin.addingTimeInterval(2)
            && $0.end < origin.addingTimeInterval(4) })
    }

    func testRangeChangesPreserveHistoryAndNeverExtrapolateBeforeOrAfterSamples() {
        let offsets = [10.0, 11, 12, 13, 14, 15]
        let first = buckets(offsets, duration: 30)
        _ = buckets(offsets, duration: 600)
        let restored = buckets(offsets, duration: 30)
        XCTAssertEqual(first.map(\.indices), restored.map(\.indices))
        XCTAssertEqual(first.map(\.isEstimated), restored.map(\.isEstimated))
        XCTAssertTrue(first.filter { $0.end < origin.addingTimeInterval(10) }.allSatisfy { $0.indices.isEmpty })
        XCTAssertTrue(first.filter { $0.start > origin.addingTimeInterval(15) }.allSatisfy { $0.indices.isEmpty })
    }

    func testAnIsolatedPairCannotEstablishAnArtificialSlowCadence() {
        XCTAssertTrue(buckets([0, 60], duration: 60).contains { $0.indices.isEmpty })
    }

    func testCounterIntervalIsObservedCoverageAndLegacyHistoryRemainsReadable() throws {
        let offsets = [0.0, 60, 120, 180]
        let starts: [Date?] = [nil, origin, origin.addingTimeInterval(60), origin.addingTimeInterval(120)]
        let frames = buckets(offsets, duration: 180, starts: starts)
        XCTAssertTrue(frames.allSatisfy { !$0.indices.isEmpty && !$0.isEstimated })
        let json = Data("{\"date\":1,\"readBytesPerSecond\":0,\"writeBytesPerSecond\":0,\"readOperationsPerSecond\":0,\"writeOperationsPerSecond\":0}".utf8)
        let legacy = try JSONDecoder().decode(NativeDiskIOPoint.self, from: json)
        XCTAssertNil(legacy.intervalStart)
        XCTAssertEqual(legacy.readBytesPerSecond, 0)
    }

    func testCounterResetDoesNotProduceCoverage() {
        func counters(_ date: Date, bytes: UInt64) -> NativeDiskIOCounters {
            NativeDiskIOCounters(date: date, readBytes: bytes, writtenBytes: bytes,
                readOperations: bytes, writeOperations: bytes, driverCount: 1)
        }
        XCTAssertNil(NativeDiskIOMonitorService.throughput(
            current: counters(origin.addingTimeInterval(2), bytes: 1),
            previous: counters(origin, bytes: 100)))
    }

    func testKnownSleepOverridesShortGapEstimatesAndCounterCoverage() {
        let history = MenuBarSamplingGaps()
        history.begin(.sleep, at: origin.addingTimeInterval(2.2))
        history.end(.sleep, at: origin.addingTimeInterval(2.8))
        let dates = (0...6).map { origin.addingTimeInterval(Double($0)) }
        let frames = GeekChartWindow.displayBuckets(for: dates,
            in: CGRect(x: 0, y: 0, width: 360, height: 100),
            range: (origin, dates.last!, origin), referenceDate: dates.last!, displayScale: 2,
            intervalStart: { $0 > 0 ? dates[$0 - 1] : nil },
            unrecordedIntervals: history.intervals(at: dates.last!))
        XCTAssertTrue(frames.filter { $0.start > dates[2] && $0.end < dates[3] }
            .allSatisfy { $0.indices.isEmpty })
        XCTAssertFalse(frames.filter { $0.start > dates[3] && $0.end < dates[4] }
            .contains { $0.indices.isEmpty })
    }

    func testPauseBoundariesPersistAndAnOpenPausePreventsBridging() throws {
        let name = "StorageCleanerMac.ChartGaps.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = MenuBarSamplingGaps(defaults: defaults)
        history.begin(.paused, at: origin)
        XCTAssertTrue(MenuBarSamplingGaps.crosses(history.intervals(at: origin.addingTimeInterval(10)),
            from: origin, to: origin.addingTimeInterval(5)))
        history.end(.paused, at: origin.addingTimeInterval(10))
        let restored = MenuBarSamplingGaps(defaults: defaults)
        XCTAssertEqual(restored.intervals(at: origin.addingTimeInterval(12)),
            [DateInterval(start: origin, duration: 10)])
        XCTAssertFalse(MenuBarSamplingGaps.crosses(restored.intervals(),
            from: origin.addingTimeInterval(10), to: origin.addingTimeInterval(11)))
    }
}
