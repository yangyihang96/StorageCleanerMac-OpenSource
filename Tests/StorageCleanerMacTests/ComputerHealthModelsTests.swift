import XCTest
@testable import StorageCleanerMac

final class ComputerHealthModelsTests: XCTestCase {
    func testAvailabilityNormalizesProposedStatusTruthfully() {
        XCTAssertEqual(HealthAvailability.available.normalizedStatus(.healthy), .healthy)
        XCTAssertEqual(HealthAvailability.available.normalizedStatus(.attention), .attention)
        XCTAssertEqual(HealthAvailability.available.normalizedStatus(.actionRequired), .actionRequired)
        XCTAssertEqual(HealthAvailability.available.normalizedStatus(.unavailable), .attention)
        XCTAssertEqual(HealthAvailability.partial.normalizedStatus(.healthy), .attention)
        XCTAssertEqual(HealthAvailability.partial.normalizedStatus(.actionRequired), .actionRequired)
        XCTAssertEqual(HealthAvailability.partial.normalizedStatus(.unavailable), .attention)

        for availability in [
            HealthAvailability.permissionDenied,
            .timedOut,
            .cancelled,
            .unavailable
        ] {
            XCTAssertEqual(availability.normalizedStatus(.healthy), .unavailable)
            XCTAssertEqual(availability.normalizedStatus(.actionRequired), .unavailable)
        }
    }

    func testSnapshotInitializersNormalizeAvailabilityAndProposedStatus() {
        let date = Date(timeIntervalSince1970: 50)
        let disk = DiskHealthSnapshot(
            availability: .available,
            status: .actionRequired,
            smartStatus: .failing,
            isTRIMEnabled: nil,
            fileSystem: nil,
            summaryText: nil,
            checkedAt: date
        )
        let capacity = CapacityTrendSnapshot(
            availability: .partial,
            status: .healthy,
            totalBytes: nil,
            availableBytes: nil,
            availableForImportantUsageBytes: nil,
            sevenDayDeltaBytes: nil,
            recordedAt: date
        )
        let backup = TimeMachineSnapshot(
            availability: .permissionDenied,
            status: .healthy,
            destinationState: .permissionDenied,
            isRunning: nil,
            latestLocalSnapshot: nil,
            latestCompleteBackup: nil,
            completeBackupAvailability: .permissionDenied,
            summaryText: nil,
            checkedAt: date
        )
        let stability = StabilitySummary(
            availability: .timedOut,
            status: .healthy,
            crashCount: nil,
            hangCount: nil,
            unexpectedRestartCount: nil,
            filesExamined: 0,
            windowStart: nil,
            generatedAt: date
        )
        let battery = BatteryHealthSnapshot(
            availability: .cancelled,
            status: .healthy,
            currentChargePercent: nil,
            isCharging: nil,
            maximumCapacityPercent: nil,
            cycleCount: nil,
            condition: nil,
            batteryPowerMode: nil,
            adapterPowerMode: nil,
            guidance: BatteryGuidance(kind: .none),
            sampledAt: date
        )

        XCTAssertEqual(disk.status, .actionRequired)
        XCTAssertEqual(capacity.status, .attention)
        XCTAssertEqual(backup.status, .unavailable)
        XCTAssertEqual(stability.status, .unavailable)
        XCTAssertEqual(battery.status, .unavailable)
    }

    func testDecodedSnapshotsNormalizeUntrustedAvailabilityAndStatusPairs() throws {
        let date = Date(timeIntervalSince1970: 60)
        let snapshot = ComputerHealthSnapshot.fixture(
            generatedAt: date,
            battery: .fixture(sampledAt: date)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let cases: [(HealthAvailability, HealthStatus, HealthStatus)] = [
            (.available, .unavailable, .attention),
            (.partial, .healthy, .attention),
            (.partial, .unavailable, .attention),
            (.permissionDenied, .healthy, .unavailable),
            (.timedOut, .actionRequired, .unavailable),
            (.cancelled, .healthy, .unavailable),
            (.unavailable, .healthy, .unavailable)
        ]

        for (availability, proposedStatus, expectedStatus) in cases {
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            for key in ["disk", "capacity", "backup", "stability", "battery"] {
                root[key] = try snapshotObject(
                    root[key],
                    availability: availability.rawValue,
                    status: proposedStatus.rawValue
                )
            }

            let untrustedData = try JSONSerialization.data(withJSONObject: root)
            let decoded = try JSONDecoder().decode(ComputerHealthSnapshot.self, from: untrustedData)
            let decodedStatuses = [
                decoded.disk.status,
                decoded.capacity.status,
                decoded.backup.status,
                decoded.stability.status,
                try XCTUnwrap(decoded.battery?.status)
            ]

            XCTAssertEqual(
                decodedStatuses,
                Array(repeating: expectedStatus, count: decodedStatuses.count),
                "Failed availability/status matrix for \(availability)/\(proposedStatus)"
            )
        }
    }

    private func snapshotObject(
        _ value: Any?,
        availability: String,
        status: String
    ) throws -> [String: Any] {
        var object = try XCTUnwrap(value as? [String: Any])
        object["availability"] = availability
        object["status"] = status
        return object
    }

    @MainActor
    func testComputerHealthStoreRejectsLateRefreshResult() async {
        let oldSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 100),
            capacityTotalBytes: 1_000,
            capacityAvailableBytes: 400,
            capacityImportantBytes: 500
        )
        let newSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 200),
            capacityTotalBytes: 1_000,
            capacityAvailableBytes: 390,
            capacityImportantBytes: 490
        )
        let probe = SuspendedSequencedHealthProbe(results: [oldSnapshot, newSnapshot])
        let historyRepository = LateRefreshHistoryRepository()
        let capacityRepository = LateRefreshCapacityRepository()
        let store = ComputerHealthStore(
            probe: probe,
            historyRepository: historyRepository,
            capacityHistoryRepository: capacityRepository
        )

        let firstRefresh = Task { @MainActor in
            await store.refresh(force: true)
        }
        let didStartFirst = await probe.waitUntilStarted(1, maximumYields: 10_000)
        guard didStartFirst else {
            await probe.releaseAll()
            firstRefresh.cancel()
            await firstRefresh.value
            XCTFail("First health refresh did not start")
            return
        }

        let secondRefresh = Task { @MainActor in
            await store.refresh(force: true)
        }
        let didStartSecond = await probe.waitUntilStarted(2, maximumYields: 10_000)
        guard didStartSecond else {
            await probe.releaseAll()
            secondRefresh.cancel()
            firstRefresh.cancel()
            await secondRefresh.value
            await firstRefresh.value
            XCTFail("Forced health refresh did not supersede the first refresh")
            return
        }

        await probe.release(call: 1)
        await secondRefresh.value
        await probe.release(call: 0)
        await firstRefresh.value

        XCTAssertEqual(store.snapshot?.generatedAt, newSnapshot.generatedAt)
        let savedHistory = await historyRepository.savedEntries()
        let savedCapacity = await capacityRepository.savedPoints()
        XCTAssertEqual(savedHistory.map(\.recordedAt), [newSnapshot.generatedAt])
        XCTAssertEqual(savedCapacity.map(\.recordedAt), [newSnapshot.capacity.recordedAt])
    }

    @MainActor
    func testConcurrentNonForcedRefreshesShareOnePhysicalProbe() async {
        let snapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 300)
        )
        let probe = SuspendedSequencedHealthProbe(results: [snapshot, snapshot])
        let store = ComputerHealthStore(probe: probe)

        let firstRefresh = Task { @MainActor in
            await store.refresh()
        }
        let didStartFirst = await probe.waitUntilStarted(1, maximumYields: 10_000)
        guard didStartFirst else {
            await probe.releaseAll()
            firstRefresh.cancel()
            await firstRefresh.value
            XCTFail("Health refresh did not start")
            return
        }

        let secondRefresh = Task { @MainActor in
            await store.refresh()
        }
        _ = await probe.waitUntilStarted(2, maximumYields: 200)

        let physicalCallCount = await probe.numberOfStartedCalls()
        XCTAssertEqual(physicalCallCount, 1)
        for call in 0..<physicalCallCount {
            await probe.release(call: call)
        }
        await firstRefresh.value
        await secondRefresh.value

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testNonForcedRefreshWaitsForInFlightForceEvenWhenCachedSnapshotIsFresh() async {
        let oldSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 310)
        )
        let newSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 320)
        )
        let probe = SeedThenSuspendedHealthProbe(seed: oldSnapshot, suspended: newSnapshot)
        let store = ComputerHealthStore(probe: probe, freshnessTTL: 300)

        await store.refresh(force: true)

        let forcedRefresh = Task { @MainActor in
            await store.refresh(force: true)
        }
        let didStartForce = await probe.waitUntilSuspendedCallStarts(maximumYields: 10_000)
        guard didStartForce else {
            await probe.releaseSuspendedCall()
            forcedRefresh.cancel()
            await forcedRefresh.value
            XCTFail("Forced refresh did not start")
            return
        }

        let completion = RefreshCompletionRecorder()
        let nonForcedRefresh = Task { @MainActor in
            await store.refresh()
            await completion.markCompleted()
        }
        for _ in 0..<200 {
            await Task.yield()
        }

        let completedBeforeForce = await completion.isCompleted()
        let callsBeforeRelease = await probe.numberOfCalls()
        XCTAssertFalse(completedBeforeForce)
        XCTAssertEqual(callsBeforeRelease, 2)

        await probe.releaseSuspendedCall()
        await forcedRefresh.value
        await nonForcedRefresh.value

        XCTAssertEqual(store.snapshot, newSnapshot)
        let finalCallCount = await probe.numberOfCalls()
        XCTAssertEqual(finalCallCount, 2)
    }

    @MainActor
    func testFreshSnapshotUsesTTLAndExpiredSnapshotRefreshes() async {
        let firstSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 10)
        )
        let secondSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 20)
        )
        let probe = ScriptedHealthProbe(steps: [
            .success(firstSnapshot),
            .success(secondSnapshot)
        ])
        let clock = TestDateSource(Date(timeIntervalSince1970: 1_000))
        let store = ComputerHealthStore(
            probe: probe,
            freshnessTTL: 300,
            now: { clock.value }
        )

        await store.refresh()
        XCTAssertEqual(store.snapshot, firstSnapshot)
        XCTAssertEqual(store.lastRefreshAt, clock.value)
        let callsAfterInitialRefresh = await probe.numberOfCalls()
        XCTAssertEqual(callsAfterInitialRefresh, 1)

        clock.value = Date(timeIntervalSince1970: 1_299)
        await store.refresh()
        XCTAssertEqual(store.snapshot, firstSnapshot)
        let callsWhileFresh = await probe.numberOfCalls()
        XCTAssertEqual(callsWhileFresh, 1)

        clock.value = Date(timeIntervalSince1970: 1_301)
        await store.refresh()
        XCTAssertEqual(store.snapshot, secondSnapshot)
        XCTAssertEqual(store.lastRefreshAt, clock.value)
        let callsAfterExpiration = await probe.numberOfCalls()
        XCTAssertEqual(callsAfterExpiration, 2)
    }

    @MainActor
    func testFailureAndCancellationKeepLastSuccessfulSnapshotAndSummary() async {
        let successfulSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 400),
            capacitySevenDayDeltaBytes: -4_096,
            battery: .fixture(sampledAt: Date(timeIntervalSince1970: 400))
        )
        let probe = ScriptedHealthProbe(steps: [
            .success(successfulSnapshot),
            .typedFailure(.permissionDenied),
            .cancelled
        ])
        let clock = TestDateSource(Date(timeIntervalSince1970: 2_000))
        let store = ComputerHealthStore(
            probe: probe,
            freshnessTTL: 300,
            now: { clock.value }
        )

        await store.refresh(force: true)
        let successfulSummary = store.menuBarSummary
        let successfulRefreshAt = store.lastRefreshAt

        clock.value = Date(timeIntervalSince1970: 2_100)
        await store.refresh(force: true)
        XCTAssertEqual(store.snapshot, successfulSnapshot)
        XCTAssertEqual(store.menuBarSummary, successfulSummary)
        XCTAssertEqual(store.lastRefreshAt, successfulRefreshAt)
        XCTAssertEqual(store.error, .permissionDenied)

        clock.value = Date(timeIntervalSince1970: 2_200)
        await store.refresh(force: true)
        XCTAssertEqual(store.snapshot, successfulSnapshot)
        XCTAssertEqual(store.menuBarSummary, successfulSummary)
        XCTAssertEqual(store.lastRefreshAt, successfulRefreshAt)
        XCTAssertEqual(store.error, ComputerHealthRefreshError.cancelled)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testUnknownProbeErrorDoesNotPublishSensitiveDescription() async {
        let secret = "/Users/secret/Private Volume SERIAL-12345"
        let probe = ScriptedHealthProbe(steps: [.unknownFailure(secret)])
        let store = ComputerHealthStore(probe: probe)

        await store.refresh(force: true)

        XCTAssertEqual(store.error, .readFailed)
        XCTAssertEqual(
            Set(ComputerHealthRefreshError.allCases),
            Set([.cancelled, .timedOut, .permissionDenied, .readFailed])
        )
        let publishedDescription = String(describing: store.error)
        XCTAssertFalse(publishedDescription.contains("/Users/secret"))
        XCTAssertFalse(publishedDescription.contains("Private Volume"))
        XCTAssertFalse(publishedDescription.contains("SERIAL-12345"))
    }

    @MainActor
    func testMenuBarSummaryIsDerivedOnlyFromCachedUsableValues() async {
        let snapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 500),
            capacitySevenDayDeltaBytes: -8_192,
            battery: .fixture(sampledAt: Date(timeIntervalSince1970: 500))
        )
        let probe = ScriptedHealthProbe(steps: [.success(snapshot)])
        let store = ComputerHealthStore(probe: probe)

        XCTAssertNil(store.menuBarSummary)
        let callsBeforeSummaryRead = await probe.numberOfCalls()
        XCTAssertEqual(callsBeforeSummaryRead, 0)

        await store.refresh(force: true)

        let callsAfterRefresh = await probe.numberOfCalls()
        XCTAssertEqual(callsAfterRefresh, 1)
        XCTAssertEqual(store.menuBarSummary?.generatedAt, snapshot.generatedAt)
        XCTAssertEqual(store.menuBarSummary?.diskSMARTStatus, .verified)
        XCTAssertEqual(store.menuBarSummary?.diskRemainingLifePercent, 94)
        XCTAssertEqual(store.menuBarSummary?.diskStatusText, "Verified")
        XCTAssertEqual(store.menuBarSummary?.capacitySevenDayDeltaBytes, -8_192)
        XCTAssertEqual(store.menuBarSummary?.backupStatusText, "Protected")
        XCTAssertEqual(store.menuBarSummary?.batteryCapacityPercent, 92)
        XCTAssertEqual(store.menuBarSummary?.batteryCycleCount, 144)
        XCTAssertEqual(store.menuBarSummary?.batteryCondition, .normal)
        XCTAssertEqual(store.menuBarSummary?.batteryPowerMode, .automatic)
        XCTAssertNil(store.menuBarSummary?.lastDownloadMbps)
        XCTAssertNil(store.menuBarSummary?.lastUploadMbps)
        XCTAssertNil(store.menuBarSummary?.lastSpeedTestAt)
    }

    @MainActor
    func testMenuBarSummaryDoesNotExposeValuesMarkedUnavailable() async {
        let snapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 600),
            diskAvailability: .permissionDenied,
            capacityAvailability: .timedOut,
            capacitySevenDayDeltaBytes: 0,
            backupAvailability: .unavailable,
            battery: .fixture(
                availability: .cancelled,
                sampledAt: Date(timeIntervalSince1970: 600)
            )
        )
        let store = ComputerHealthStore(
            probe: ScriptedHealthProbe(steps: [.success(snapshot)])
        )

        await store.refresh(force: true)

        XCTAssertNil(store.menuBarSummary?.diskStatusText)
        XCTAssertNil(store.menuBarSummary?.diskSMARTStatus)
        XCTAssertNil(store.menuBarSummary?.diskRemainingLifePercent)
        XCTAssertNil(store.menuBarSummary?.capacitySevenDayDeltaBytes)
        XCTAssertNil(store.menuBarSummary?.backupStatusText)
        XCTAssertNil(store.menuBarSummary?.batteryCapacityPercent)
        XCTAssertNil(store.menuBarSummary?.batteryCycleCount)
    }

    @MainActor
    func testMenuBarSummaryTrimsTextAndHidesWhitespaceOnlyValues() async {
        let snapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 610),
            diskSummaryText: "   Verified  ",
            backupSummaryText: "\n\t "
        )
        let store = ComputerHealthStore(
            probe: ScriptedHealthProbe(steps: [.success(snapshot)])
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.menuBarSummary?.diskStatusText, "Verified")
        XCTAssertNil(store.menuBarSummary?.backupStatusText)
    }

    @MainActor
    func testDiskHealthPercentKeepsLatestValidReadingAndAcceptsUpdates() async {
        let probe = ScriptedHealthProbe(steps: [
            .success(.fixture(
                generatedAt: Date(timeIntervalSince1970: 620),
                diskRemainingLifePercent: 91
            )),
            .success(.fixture(
                generatedAt: Date(timeIntervalSince1970: 630),
                diskRemainingLifePercent: nil
            )),
            .success(.fixture(
                generatedAt: Date(timeIntervalSince1970: 640),
                diskRemainingLifePercent: 89
            )),
        ])
        let store = ComputerHealthStore(probe: probe)

        await store.refresh(force: true)
        XCTAssertEqual(store.menuBarSummary?.diskRemainingLifePercent, 91)

        await store.refresh(force: true)
        XCTAssertEqual(store.snapshot?.disk.remainingLifePercent, nil)
        XCTAssertEqual(store.menuBarSummary?.diskRemainingLifePercent, 91)

        await store.refresh(force: true)
        XCTAssertEqual(store.menuBarSummary?.diskRemainingLifePercent, 89)
    }

    @MainActor
    func testDiskHealthPercentFallsBackToPersistedHistoryAfterStoreRestart() async {
        let date = Date(timeIntervalSince1970: 650)
        let historicalSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: date,
            diskRemainingLifePercent: 87
        )
        let historyEntry = ComputerHealthHistoryEntry(
            recordedAt: date,
            evaluation: ComputerHealthScoring.evaluate(
                snapshot: historicalSnapshot,
                history: [],
                referenceDate: date
            ),
            diskRemainingLifePercent: 87
        )
        let currentSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 660),
            diskRemainingLifePercent: nil
        )
        let store = ComputerHealthStore(
            probe: ScriptedHealthProbe(steps: [.success(currentSnapshot)]),
            historyRepository: SeededHealthHistoryRepository(entries: [historyEntry])
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.snapshot?.disk.remainingLifePercent, nil)
        XCTAssertEqual(store.menuBarSummary?.diskRemainingLifePercent, 87)
    }

    @MainActor
    func testDiskHealthPercentRestoresFromHistoryWhenCurrentQueryFails() async {
        let date = Date(timeIntervalSince1970: 670)
        let historicalSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: date,
            diskRemainingLifePercent: 86
        )
        let historyEntry = ComputerHealthHistoryEntry(
            recordedAt: date,
            evaluation: ComputerHealthScoring.evaluate(
                snapshot: historicalSnapshot,
                history: [],
                referenceDate: date
            ),
            diskRemainingLifePercent: 86
        )
        let store = ComputerHealthStore(
            probe: ScriptedHealthProbe(steps: [.typedFailure(.timedOut)]),
            historyRepository: SeededHealthHistoryRepository(entries: [historyEntry])
        )

        await store.refresh(force: true)

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.error, .timedOut)
        XCTAssertEqual(store.menuBarSummary?.diskRemainingLifePercent, 86)
    }

    @MainActor
    func testMenuBarLaunchPreparationRestoresThenRefreshesOnlyOnce() async {
        let date = Date(timeIntervalSince1970: 680)
        let historicalSnapshot = ComputerHealthSnapshot.fixture(
            generatedAt: date,
            diskRemainingLifePercent: 85
        )
        let historyEntry = ComputerHealthHistoryEntry(
            recordedAt: date,
            evaluation: ComputerHealthScoring.evaluate(
                snapshot: historicalSnapshot,
                history: [],
                referenceDate: date
            ),
            diskRemainingLifePercent: 85
        )
        let probe = ScriptedHealthProbe(steps: [
            .success(.fixture(
                generatedAt: Date(timeIntervalSince1970: 690),
                diskRemainingLifePercent: 83
            ))
        ])
        let store = ComputerHealthStore(
            probe: probe,
            historyRepository: SeededHealthHistoryRepository(entries: [historyEntry])
        )

        await store.prepareMenuBarHealthOnLaunch()
        await store.prepareMenuBarHealthOnLaunch()

        XCTAssertEqual(store.menuBarSummary?.diskRemainingLifePercent, 83)
        let probeCalls = await probe.numberOfCalls()
        XCTAssertEqual(probeCalls, 1)
    }

    func testHealthAndPerformanceAreIndependentTopLevelDestinations() {
        XCTAssertTrue(ReviewFilter.allCases.contains(.healthHub))
        XCTAssertTrue(ReviewFilter.allCases.contains(.performance))
        XCTAssertEqual(ReviewFilter.careCases, [.overview, .healthHub, .performance])
        XCTAssertFalse(
            ReviewFilter.allCases.contains(where: { $0.rawValue == "networkSpeed" })
        )
        XCTAssertFalse(ReviewFilter.healthHub.isStorageFilter)
        XCTAssertFalse(ReviewFilter.performance.isStorageFilter)
        XCTAssertEqual(ReviewFilter.healthHub.sidebarDestination, .healthHub)
        XCTAssertEqual(ReviewFilter.performance.sidebarDestination, .performance)
    }

    @MainActor
    func testMenuSummaryReadNeverStartsHealthRefresh() async {
        let probe = ScriptedHealthProbe(steps: [
            .success(.fixture(generatedAt: Date(timeIntervalSince1970: 700)))
        ])
        let store = ComputerHealthStore(probe: probe)

        _ = store.menuBarSummary

        let callCount = await probe.numberOfCalls()
        XCTAssertEqual(callCount, 0)
    }

    @MainActor
    func testCompletedManualSpeedResultMergesIntoCachedMenuSummary() async {
        let snapshot = ComputerHealthSnapshot.fixture(
            generatedAt: Date(timeIntervalSince1970: 800)
        )
        let store = ComputerHealthStore(
            probe: ScriptedHealthProbe(steps: [.success(snapshot)])
        )
        await store.refresh(force: true)

        let testedAt = Date(timeIntervalSince1970: 810)
        store.recordNetworkSpeedResult(NetworkSpeedTestResult(
            downloadMbps: 512,
            uploadMbps: 48,
            responsivenessRPM: 734,
            idleLatencyMilliseconds: 12,
            loadedLatencyP50Milliseconds: nil,
            loadedLatencyP95Milliseconds: nil,
            jitterMilliseconds: nil,
            interfaceName: "en0",
            source: .nativeSystem,
            methodVersion: "native-network-quality-v1",
            durationSeconds: 20,
            transferredBytes: nil,
            completeness: 4.0 / 6.0,
            testedAt: testedAt
        ))

        XCTAssertEqual(store.menuBarSummary?.diskStatusText, "Verified")
        XCTAssertEqual(store.menuBarSummary?.lastDownloadMbps, 512)
        XCTAssertEqual(store.menuBarSummary?.lastUploadMbps, 48)
        XCTAssertEqual(store.menuBarSummary?.lastSpeedTestAt, testedAt)
    }
}

private actor LateRefreshHistoryRepository: ComputerHealthHistoryPersisting {
    private var saved: [ComputerHealthHistoryEntry] = []

    func load() async -> [ComputerHealthHistoryEntry] { [] }

    func save(_ entry: ComputerHealthHistoryEntry) async throws {
        saved.append(entry)
    }

    func savedEntries() -> [ComputerHealthHistoryEntry] { saved }
}

private actor SeededHealthHistoryRepository: ComputerHealthHistoryPersisting {
    private let entries: [ComputerHealthHistoryEntry]

    init(entries: [ComputerHealthHistoryEntry]) {
        self.entries = entries
    }

    func load() async -> [ComputerHealthHistoryEntry] { entries }
    func save(_ entry: ComputerHealthHistoryEntry) async throws {}
}

private actor LateRefreshCapacityRepository: CapacityHistoryPersisting {
    private var saved: [CapacityHistoryPoint] = []

    func save(_ point: CapacityHistoryPoint) async throws {
        saved.append(point)
    }

    func savedPoints() -> [CapacityHistoryPoint] { saved }
}

private actor SuspendedSequencedHealthProbe: ComputerHealthProbing {
    private let results: [ComputerHealthSnapshot]
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var shouldSuspend = true

    init(results: [ComputerHealthSnapshot]) {
        self.results = results
    }

    func probe() async throws -> ComputerHealthSnapshot {
        let call = callCount
        callCount += 1
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                continuations[call] = continuation
            }
        }
        return results[call]
    }

    func waitUntilStarted(_ expectedCount: Int, maximumYields: Int) async -> Bool {
        for _ in 0..<maximumYields {
            if callCount >= expectedCount { return true }
            await Task.yield()
        }
        return callCount >= expectedCount
    }

    func release(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }

    func releaseAll() {
        shouldSuspend = false
        let pendingContinuations = continuations.values
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }

    func numberOfStartedCalls() -> Int {
        callCount
    }
}

private actor ScriptedHealthProbe: ComputerHealthProbing {
    enum Step: Sendable {
        case success(ComputerHealthSnapshot)
        case typedFailure(ComputerHealthRefreshError)
        case unknownFailure(String)
        case cancelled
    }

    private var steps: [Step]
    private var callCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func probe() async throws -> ComputerHealthSnapshot {
        callCount += 1
        guard !steps.isEmpty else {
            throw SensitiveFixtureProbeError(description: "unexpected probe")
        }

        switch steps.removeFirst() {
        case let .success(snapshot):
            return snapshot
        case let .typedFailure(error):
            throw error
        case let .unknownFailure(message):
            throw SensitiveFixtureProbeError(description: message)
        case .cancelled:
            throw CancellationError()
        }
    }

    func numberOfCalls() -> Int {
        callCount
    }
}

private actor SeedThenSuspendedHealthProbe: ComputerHealthProbing {
    private let seed: ComputerHealthSnapshot
    private let suspended: ComputerHealthSnapshot
    private var callCount = 0
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspend = true

    init(seed: ComputerHealthSnapshot, suspended: ComputerHealthSnapshot) {
        self.seed = seed
        self.suspended = suspended
    }

    func probe() async throws -> ComputerHealthSnapshot {
        callCount += 1
        guard callCount > 1 else { return seed }

        if shouldSuspend {
            await withCheckedContinuation { continuation in
                suspendedContinuation = continuation
            }
        }
        return suspended
    }

    func waitUntilSuspendedCallStarts(maximumYields: Int) async -> Bool {
        for _ in 0..<maximumYields {
            if suspendedContinuation != nil { return true }
            await Task.yield()
        }
        return suspendedContinuation != nil
    }

    func releaseSuspendedCall() {
        shouldSuspend = false
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }

    func numberOfCalls() -> Int {
        callCount
    }
}

private actor RefreshCompletionRecorder {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private struct SensitiveFixtureProbeError: Error, CustomStringConvertible, Sendable {
    let description: String
}

@MainActor
private final class TestDateSource {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private extension ComputerHealthSnapshot {
    static func fixture(
        generatedAt: Date,
        diskAvailability: HealthAvailability = .available,
        capacityAvailability: HealthAvailability = .available,
        capacitySevenDayDeltaBytes: Int64? = nil,
        capacityTotalBytes: Int64? = nil,
        capacityAvailableBytes: Int64? = nil,
        capacityImportantBytes: Int64? = nil,
        backupAvailability: HealthAvailability = .available,
        diskRemainingLifePercent: Int? = 94,
        diskSummaryText: String? = "Verified",
        backupSummaryText: String? = "Protected",
        battery: BatteryHealthSnapshot? = nil
    ) -> Self {
        Self(
            generatedAt: generatedAt,
            disk: DiskHealthSnapshot(
                availability: diskAvailability,
                status: .healthy,
                smartStatus: .verified,
                isTRIMEnabled: nil,
                fileSystem: nil,
                remainingLifePercent: diskRemainingLifePercent,
                summaryText: diskSummaryText,
                checkedAt: generatedAt
            ),
            capacity: CapacityTrendSnapshot(
                availability: capacityAvailability,
                status: .healthy,
                totalBytes: capacityTotalBytes,
                availableBytes: capacityAvailableBytes,
                availableForImportantUsageBytes: capacityImportantBytes,
                sevenDayDeltaBytes: capacitySevenDayDeltaBytes,
                recordedAt: generatedAt
            ),
            backup: TimeMachineSnapshot(
                availability: backupAvailability,
                status: .healthy,
                destinationState: .configured,
                isRunning: false,
                latestLocalSnapshot: nil,
                latestCompleteBackup: generatedAt,
                completeBackupAvailability: backupAvailability,
                summaryText: backupSummaryText,
                checkedAt: generatedAt
            ),
            stability: StabilitySummary(
                availability: .available,
                status: .healthy,
                crashCount: nil,
                hangCount: nil,
                unexpectedRestartCount: nil,
                filesExamined: 0,
                windowStart: nil,
                generatedAt: generatedAt
            ),
            battery: battery
        )
    }
}

private extension BatteryHealthSnapshot {
    static func fixture(
        availability: HealthAvailability = .available,
        sampledAt: Date
    ) -> Self {
        Self(
            availability: availability,
            status: .healthy,
            currentChargePercent: 80,
            isCharging: false,
            maximumCapacityPercent: 92,
            cycleCount: 144,
            condition: .normal,
            batteryPowerMode: .automatic,
            adapterPowerMode: .automatic,
            guidance: BatteryGuidance(kind: .optimizedChargingNormal),
            sampledAt: sampledAt
        )
    }
}
