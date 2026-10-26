import Foundation
import XCTest
@testable import StorageCleanerMac

/// D173: the menu bar reads free space on every capacity read but asks for
/// the purgeable space (the important-usage figure, a CacheDelete query) only
/// every five minutes, as iStat does, and completes the readings in between
/// with the purgeable space it last measured.
final class MenuBarPurgeableCadenceTests: XCTestCase {
    func testTheImportantUsageKeyIsLeftOutOnlyWhenAsked() {
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        XCTAssertTrue(StorageCapacityService.resourceKeys(path: "/").contains(key))
        XCTAssertTrue(StorageCapacityService.resourceKeys(path: "/Users/example", isInternalVolume: true).contains(key))
        XCTAssertFalse(StorageCapacityService.resourceKeys(path: "/", includeImportantUsage: false).contains(key))
        XCTAssertFalse(StorageCapacityService.resourceKeys(path: "/Users/example", isInternalVolume: true,
                                                           includeImportantUsage: false).contains(key))
        XCTAssertTrue(StorageCapacityService.resourceKeys(path: "/", includeImportantUsage: false)
            .isSuperset(of: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]))
    }

    func testAPurgeableEstimateCompletesAFreeSpaceOnlyReading() {
        let plain = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 300)
        XCTAssertEqual(plain.addingPurgeableEstimate(200).availableForImportantUsageBytes, 500)
        XCTAssertEqual(plain.addingPurgeableEstimate(200).userAvailableBytes, 500)
        XCTAssertEqual(plain.addingPurgeableEstimate(nil), plain)
        XCTAssertEqual(plain.addingPurgeableEstimate(0), plain)
        XCTAssertEqual(plain.addingPurgeableEstimate(900).availableForImportantUsageBytes, 1_000, "never above the volume")
        let measured = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 300, availableForImportantUsageBytes: 450)
        XCTAssertEqual(measured.addingPurgeableEstimate(200), measured, "a reading's own figure wins")
        let huge = StorageCapacitySnapshot(totalBytes: .max, availableBytes: .max - 1)
        XCTAssertEqual(huge.addingPurgeableEstimate(10).availableForImportantUsageBytes, .max, "no overflow")
    }

    @MainActor
    func testThePurgeableSpaceIsAskedForOnceThenEveryFiveMinutes() async throws {
        let reads = StartupWorkCounter(), free = PurgeableTestFreeSpace(300)
        let context = MenuBarSamplingContext()
        context.beginStartup(now: reads.now)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
            customFanControlActive: false, paused: false, now: reads.now, selectedInterval: 2)
        let state = MenuBarAuxiliaryMonitorState(collectionClock: { reads.now },
            batteryAvailabilityProvider: { .present }, diskCounterProvider: { nil },
            storageVolumeProvider: { .empty },
            storageCapacityProvider: { includeImportantUsage in
                reads.read("capacity")
                if includeImportantUsage { reads.read("purgeable") }
                let available = free.value
                return StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: available,
                                               availableForImportantUsageBytes: includeImportantUsage ? available + 200 : nil)
            },
            batterySnapshotProvider: { (nil, nil) },
            publicNetworkConsentProvider: { false },
            networkProcessProvider: { nil },
            processorTelemetryProvider: { nil },
            powerTelemetryProvider: { .unsupported(at: reads.now) },
            powerTelemetryPause: {}, powerHistoryURL: nil, chargeLimitReader: { nil })
        state.attachSamplingContext(context)
        state.setPresentationVisible(false)
        defer { state.setPaused(true) }

        // The first capacity read (startup slot at 1 s) asks for the purgeable space.
        reads.advance(1)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("capacity") == 1 && !state.isLocalDataRefreshActive }
        XCTAssertEqual(reads.count("purgeable"), 1)
        XCTAssertEqual(state.storageSnapshot?.availableForImportantUsageBytes, 500)

        // The next tick reads free space only and adds the purgeable space measured before.
        free.value = 250
        reads.advance(2)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("capacity") == 2 && !state.isLocalDataRefreshActive }
        XCTAssertEqual(reads.count("purgeable"), 1, "no CacheDelete query on an ordinary tick")
        XCTAssertEqual(state.storageSnapshot?.availableBytes, 250)
        XCTAssertEqual(state.storageSnapshot?.availableForImportantUsageBytes, 450)

        // Still not at 298 s after the first purgeable read.
        reads.advance(296)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("capacity") == 3 && !state.isLocalDataRefreshActive }
        XCTAssertEqual(reads.count("purgeable"), 1)

        // Five minutes after it, the purgeable space is asked for again.
        free.value = 240
        reads.advance(2)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("capacity") == 4 && !state.isLocalDataRefreshActive }
        XCTAssertEqual(reads.count("purgeable"), 2)
        XCTAssertEqual(state.storageSnapshot?.availableForImportantUsageBytes, 440)
        XCTAssertEqual(MenuBarAuxiliaryMonitorState.purgeableSamplingInterval, 300)
    }
}

private final class PurgeableTestFreeSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    init(_ bytes: Int64) { self.bytes = bytes }
    var value: Int64 {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}
