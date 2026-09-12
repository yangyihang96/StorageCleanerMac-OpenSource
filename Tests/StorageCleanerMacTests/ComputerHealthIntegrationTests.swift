import XCTest
@testable import StorageCleanerMac

final class ComputerHealthIntegrationTests: XCTestCase {
    @MainActor
    func testBatterySettingsGuidanceMarksVerifiedOnlyAfterConfirmedChange() async {
        let verifier = ScriptedBatterySettingsVerifier(
            beginResults: [.opened],
            verificationResults: [.unchanged, .changed]
        )
        let store = ComputerHealthStore(
            probe: StaticComputerHealthProbe(snapshot: .integrationFixture()),
            batterySettingsVerifier: verifier
        )

        XCTAssertEqual(store.batterySettingsAdjustmentState, .idle)
        XCTAssertEqual(verifier.beginCallCount, 0)
        XCTAssertEqual(verifier.verificationCallCount, 0)

        await store.beginBatterySettingsAdjustment()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .awaitingVerification)

        await store.verifyBatterySettingsAfterReturn()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .unchanged)

        await store.verifyBatterySettingsAfterReturn()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .verified)
        XCTAssertEqual(verifier.beginCallCount, 1)
        XCTAssertEqual(verifier.verificationCallCount, 2)
    }

    @MainActor
    func testExplicitHealthRefreshVerifiesPendingBatterySettingsBeforeProbe() async {
        let verifier = ScriptedBatterySettingsVerifier(
            beginResults: [.opened],
            verificationResults: [.changed]
        )
        let probe = CountingComputerHealthProbe(snapshot: .integrationFixture())
        let store = ComputerHealthStore(
            probe: probe,
            batterySettingsVerifier: verifier
        )

        await store.beginBatterySettingsAdjustment()
        await store.refresh(force: true)

        XCTAssertEqual(store.batterySettingsAdjustmentState, .verified)
        XCTAssertEqual(verifier.verificationCallCount, 1)
        let probeCallCount = await probe.callCount()
        XCTAssertEqual(probeCallCount, 1)
    }

    @MainActor
    func testExpiredAndUnverifiableSettingsSessionsRequireANewBaseline() async {
        let verifier = ScriptedBatterySettingsVerifier(
            beginResults: [.opened, .opened, .opened],
            verificationResults: [.expired, .unverifiable]
        )
        let store = ComputerHealthStore(
            probe: StaticComputerHealthProbe(snapshot: .integrationFixture()),
            batterySettingsVerifier: verifier
        )

        await store.beginBatterySettingsAdjustment()
        await store.verifyBatterySettingsAfterReturn()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .expired)

        await store.beginBatterySettingsAdjustment()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .awaitingVerification)
        await store.verifyBatterySettingsAfterReturn()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .unverifiable)

        await store.beginBatterySettingsAdjustment()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .awaitingVerification)
        XCTAssertEqual(verifier.beginCallCount, 3)
    }

    @MainActor
    func testUnchangedSessionCanReopenSettingsAndEstablishANewBaseline() async {
        let verifier = ScriptedBatterySettingsVerifier(
            beginResults: [.opened, .opened],
            verificationResults: [.unchanged, .changed]
        )
        let store = ComputerHealthStore(
            probe: StaticComputerHealthProbe(snapshot: .integrationFixture()),
            batterySettingsVerifier: verifier
        )

        await store.beginBatterySettingsAdjustment()
        await store.verifyBatterySettingsAfterReturn()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .unchanged)

        await store.beginBatterySettingsAdjustment()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .awaitingVerification)
        await store.verifyBatterySettingsAfterReturn()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .verified)
        XCTAssertEqual(verifier.beginCallCount, 2)
    }

    @MainActor
    func testUnverifiedGuidanceOpenNeverCreatesAVerifiedSession() async {
        let verifier = ScriptedBatterySettingsVerifier(
            beginResults: [.baselineUnavailable],
            verificationResults: [.changed],
            unverifiedOpenResults: [true]
        )
        let store = ComputerHealthStore(
            probe: StaticComputerHealthProbe(snapshot: .integrationFixture()),
            batterySettingsVerifier: verifier
        )

        await store.beginBatterySettingsAdjustment()
        XCTAssertEqual(store.batterySettingsAdjustmentState, .unverifiable)

        store.openBatterySettingsWithoutVerification()
        XCTAssertEqual(verifier.unverifiedOpenCallCount, 1)
        XCTAssertEqual(store.batterySettingsAdjustmentState, .unverifiable)

        await store.verifyBatterySettingsAfterReturn()
        XCTAssertEqual(verifier.verificationCallCount, 0)
        XCTAssertNotEqual(store.batterySettingsAdjustmentState, .verified)
    }

    func testActionRequiredAggregationOmitsHealthyAndAttentionOnlyCards() {
        let snapshot = ComputerHealthSnapshot.integrationFixture(
            diskStatus: .actionRequired,
            capacityStatus: .attention,
            batteryStatus: .actionRequired
        )

        XCTAssertEqual(snapshot.actionRequiredIssues, [.disk, .battery])
    }

    func testHealthViewSurfacesActionableHardwareAndFreshnessDetails() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealthView.swift"))
        let presentationSource = try String(contentsOf: projectRoot.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthDashboardPresentation.swift"
        ))

        XCTAssertTrue(source.contains("actionRequiredIssues"))
        XCTAssertTrue(source.contains("snapshot.isSolidState"))
        XCTAssertTrue(source.contains("snapshot.isInternal"))
        XCTAssertTrue(source.contains("snapshot.currentChargePercent"))
        XCTAssertTrue(source.contains("snapshot.isCharging"))
        XCTAssertTrue(source.contains("snapshot.powerSource"))
        XCTAssertTrue(source.contains("snapshot.remainingTimeMinutes"))
        XCTAssertTrue(source.contains("result.interfaceName"))
        XCTAssertTrue(source.contains("updatedAt:"))
        XCTAssertTrue(source.contains("beginBatterySettingsAdjustment"))
        XCTAssertTrue(source.contains("case .battery:\n            batteryAction()"))
        XCTAssertTrue(presentationSource.contains("验证电池设置"))
        XCTAssertTrue(presentationSource.contains("重新验证设置"))
        XCTAssertTrue(presentationSource.contains("重新打开电池设置"))
        XCTAssertTrue(source.contains("重试读取电源模式"))
        XCTAssertTrue(source.contains("打开电池设置（无法自动核验）"))
        XCTAssertTrue(source.contains("openBatterySettingsWithoutVerification"))
    }

    @MainActor
    func testRefreshPublishesOneCoherentDashboardGenerationAndPersistsAfterAcceptance() async {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let previousHistory = dashboardHistory(endingAt: now, excludingCurrentDay: true)
        let healthHistory = RecordingComputerHealthHistoryRepository(previousHistory)
        let capacityHistory = RecordingCapacityHistoryRepository()
        let snapshot = ComputerHealthSnapshot.dashboardFixture(date: now)
        let store = ComputerHealthStore(
            probe: StaticComputerHealthProbe(snapshot: snapshot),
            freshnessTTL: 0,
            now: { now },
            historyRepository: healthHistory,
            capacityHistoryRepository: capacityHistory,
            thermalReadinessProvider: { .ready }
        )

        await store.refresh(force: true)

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNotNil(store.evaluation?.score)
        XCTAssertGreaterThan(store.evaluation?.confidence.value ?? 0, 0)
        XCTAssertEqual(store.history.first?.recordedAt, now)
        XCTAssertEqual(store.storageForecast?.sampleCount, 16)
        XCTAssertEqual(store.batteryTrend?.sampleCount, 16)
        XCTAssertEqual(store.thermalReadiness, .ready)
        let savedHealth = await healthHistory.savedEntries()
        let savedCapacity = await capacityHistory.savedPoints()
        XCTAssertEqual(savedHealth.count, 1)
        XCTAssertEqual(savedHealth.first?.recordedAt, now)
        XCTAssertEqual(savedCapacity.count, 1)
        XCTAssertEqual(savedCapacity.first?.availableForImportantUsageBytes, 120 * 1_073_741_824)
    }

    @MainActor
    func testSuccessfulDataInsufficientRefreshPersistsEvidenceWithoutCapacityBytes() async {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let healthHistory = RecordingComputerHealthHistoryRepository()
        let capacityHistory = RecordingCapacityHistoryRepository()
        let snapshot = ComputerHealthSnapshot.dataInsufficientFixture(date: now)
        let store = ComputerHealthStore(
            probe: StaticComputerHealthProbe(snapshot: snapshot),
            freshnessTTL: 0,
            now: { now },
            historyRepository: healthHistory,
            capacityHistoryRepository: capacityHistory
        )

        await store.refresh(force: true)

        XCTAssertNil(store.evaluation?.score)
        XCTAssertEqual(store.evaluation?.status, .dataInsufficient)
        let savedHealth = await healthHistory.savedEntries()
        let savedCapacity = await capacityHistory.savedPoints()
        XCTAssertEqual(savedHealth.count, 1)
        XCTAssertNil(savedHealth.first?.totalBytes)
        XCTAssertNil(savedHealth.first?.availableForImportantUsageBytes)
        XCTAssertTrue(savedCapacity.isEmpty)
    }

    @MainActor
    func testDataInsufficientOverallScoreStillPersistsValidCapacityEvidence() async {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let healthHistory = RecordingComputerHealthHistoryRepository()
        let capacityHistory = RecordingCapacityHistoryRepository()
        let snapshot = ComputerHealthSnapshot.dataInsufficientWithValidCapacityFixture(date: now)
        let store = ComputerHealthStore(
            probe: StaticComputerHealthProbe(snapshot: snapshot),
            freshnessTTL: 0,
            now: { now },
            historyRepository: healthHistory,
            capacityHistoryRepository: capacityHistory
        )

        await store.refresh(force: true)

        XCTAssertNil(store.evaluation?.score)
        XCTAssertEqual(store.evaluation?.status, .dataInsufficient)
        let savedHealth = await healthHistory.savedEntries()
        let savedCapacity = await capacityHistory.savedPoints()
        XCTAssertEqual(savedHealth.first?.totalBytes, 512 * 1_073_741_824)
        XCTAssertEqual(
            savedHealth.first?.availableForImportantUsageBytes,
            120 * 1_073_741_824
        )
        XCTAssertEqual(savedCapacity.count, 1)
        XCTAssertEqual(savedCapacity.first?.availableForImportantUsageBytes, 120 * 1_073_741_824)
    }

    @MainActor
    func testNetworkEnvironmentUpdateDoesNotMutateCoreHealthEvaluation() async {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let store = ComputerHealthStore(
            probe: StaticComputerHealthProbe(snapshot: .dashboardFixture(date: now)),
            freshnessTTL: 0,
            now: { now }
        )
        await store.refresh(force: true)
        let evaluationBeforeNetwork = store.evaluation

        store.recordNetworkSpeedResult(NetworkSpeedTestResult(
            downloadMbps: 500,
            uploadMbps: 50,
            responsivenessRPM: 700,
            idleLatencyMilliseconds: 12,
            loadedLatencyP50Milliseconds: 30,
            loadedLatencyP95Milliseconds: 40,
            jitterMilliseconds: 3,
            interfaceName: "en0",
            source: .nativeSystem,
            methodVersion: "native-network-quality-v1",
            durationSeconds: 10,
            transferredBytes: nil,
            completeness: 1,
            testedAt: now
        ))

        XCTAssertEqual(store.evaluation, evaluationBeforeNetwork)
        XCTAssertEqual(store.menuBarSummary?.lastDownloadMbps, 500)
    }
}

@MainActor
private final class ScriptedBatterySettingsVerifier: BatterySettingsVerifying {
    private var beginResults: [BatterySettingsBeginResult]
    private var verificationResults: [BatterySettingsVerificationResult]
    private var unverifiedOpenResults: [Bool]
    private(set) var beginCallCount = 0
    private(set) var verificationCallCount = 0
    private(set) var unverifiedOpenCallCount = 0

    init(
        beginResults: [BatterySettingsBeginResult],
        verificationResults: [BatterySettingsVerificationResult],
        unverifiedOpenResults: [Bool] = []
    ) {
        self.beginResults = beginResults
        self.verificationResults = verificationResults
        self.unverifiedOpenResults = unverifiedOpenResults
    }

    func beginAdjustment() async -> BatterySettingsBeginResult {
        beginCallCount += 1
        return beginResults.isEmpty ? .baselineUnavailable : beginResults.removeFirst()
    }

    func verifyAfterSettingsChange() async -> BatterySettingsVerificationResult {
        verificationCallCount += 1
        return verificationResults.isEmpty ? .unverifiable : verificationResults.removeFirst()
    }

    func openSettingsWithoutVerification() -> Bool {
        unverifiedOpenCallCount += 1
        return unverifiedOpenResults.isEmpty ? false : unverifiedOpenResults.removeFirst()
    }

    func cancelVerification() {}
}

private struct StaticComputerHealthProbe: ComputerHealthProbing {
    let snapshot: ComputerHealthSnapshot

    func probe() async throws -> ComputerHealthSnapshot { snapshot }
}

private actor CountingComputerHealthProbe: ComputerHealthProbing {
    private let snapshot: ComputerHealthSnapshot
    private var calls = 0

    init(snapshot: ComputerHealthSnapshot) {
        self.snapshot = snapshot
    }

    func probe() async throws -> ComputerHealthSnapshot {
        calls += 1
        return snapshot
    }

    func callCount() -> Int { calls }
}

private actor RecordingComputerHealthHistoryRepository: ComputerHealthHistoryPersisting {
    private var entries: [ComputerHealthHistoryEntry]
    private var saved: [ComputerHealthHistoryEntry] = []

    init(_ entries: [ComputerHealthHistoryEntry] = []) {
        self.entries = entries
    }

    func load() async -> [ComputerHealthHistoryEntry] { entries }

    func save(_ entry: ComputerHealthHistoryEntry) async throws {
        saved.append(entry)
        entries.insert(entry, at: 0)
    }

    func savedEntries() -> [ComputerHealthHistoryEntry] { saved }
}

private actor RecordingCapacityHistoryRepository: CapacityHistoryPersisting {
    private var saved: [CapacityHistoryPoint] = []

    func save(_ point: CapacityHistoryPoint) async throws {
        saved.append(point)
    }

    func savedPoints() -> [CapacityHistoryPoint] { saved }
}

private func dashboardHistory(
    endingAt now: Date,
    excludingCurrentDay: Bool
) -> [ComputerHealthHistoryEntry] {
    let gib = Int64(1_073_741_824)
    let firstIndex = excludingCurrentDay ? 1 : 0
    return (firstIndex..<16).map { index in
        let date = now.addingTimeInterval(Double(-index * 5) * 86_400)
        let score = 90.0
        let evaluation = ComputerHealthEvaluation(
            score: score,
            status: .healthy,
            coverage: 1,
            confidence: .init(value: 90, level: .high, modelVersion: "health-confidence-v1"),
            components: [],
            evaluatedAt: date
        )
        return ComputerHealthHistoryEntry(
            recordedAt: date,
            evaluation: evaluation,
            totalBytes: 512 * gib,
            availableForImportantUsageBytes: (120 + Int64(index * 5)) * gib,
            maximumCapacityPercent: 92 + Int((Double(index) * 4 / 15).rounded()),
            batteryCycleCount: 250 - index * 10,
            latestVerifiedCompleteBackupAt: date
        )
    }
}

private extension ComputerHealthSnapshot {
    static func integrationFixture(
        diskStatus: HealthStatus = .healthy,
        capacityStatus: HealthStatus = .healthy,
        batteryStatus: HealthStatus = .healthy
    ) -> Self {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        return Self(
            generatedAt: date,
            disk: DiskHealthSnapshot(
                availability: .available,
                status: diskStatus,
                smartStatus: diskStatus == .actionRequired ? .failing : .verified,
                isTRIMEnabled: true,
                fileSystem: "APFS",
                isSolidState: true,
                isInternal: true,
                summaryText: "Disk",
                checkedAt: date
            ),
            capacity: CapacityTrendSnapshot(
                availability: .available,
                status: capacityStatus,
                totalBytes: 1_000,
                availableBytes: 400,
                availableForImportantUsageBytes: 500,
                sevenDayDeltaBytes: 0,
                recordedAt: date
            ),
            backup: TimeMachineSnapshot(
                availability: .available,
                status: .healthy,
                destinationState: .configured,
                isRunning: false,
                latestLocalSnapshot: date,
                latestCompleteBackup: date,
                completeBackupAvailability: .available,
                summaryText: "Backup",
                checkedAt: date
            ),
            stability: StabilitySummary(
                availability: .available,
                status: .healthy,
                crashCount: 0,
                hangCount: 0,
                unexpectedRestartCount: 0,
                filesExamined: 0,
                windowStart: date,
                generatedAt: date
            ),
            battery: BatteryHealthSnapshot(
                availability: .available,
                status: batteryStatus,
                currentChargePercent: 75,
                isCharging: true,
                maximumCapacityPercent: 96,
                cycleCount: 88,
                condition: batteryStatus == .actionRequired ? .serviceRecommended : .normal,
                batteryPowerMode: .automatic,
                adapterPowerMode: .automatic,
                guidance: BatteryGuidance(kind: .none),
                sampledAt: date
            )
        )
    }

    static func dashboardFixture(date: Date) -> Self {
        let gib = Int64(1_073_741_824)
        return Self(
            generatedAt: date,
            disk: DiskHealthSnapshot(
                availability: .available,
                status: .healthy,
                smartStatus: .verified,
                isTRIMEnabled: true,
                fileSystem: "APFS",
                isSolidState: true,
                isInternal: true,
                summaryText: "Disk",
                checkedAt: date
            ),
            capacity: CapacityTrendSnapshot(
                availability: .available,
                status: .healthy,
                totalBytes: 512 * gib,
                availableBytes: 110 * gib,
                availableForImportantUsageBytes: 120 * gib,
                sevenDayDeltaBytes: -6 * gib,
                thirtyDayDeltaBytes: -30 * gib,
                recordedAt: date
            ),
            backup: TimeMachineSnapshot(
                availability: .available,
                status: .healthy,
                destinationState: .configured,
                isRunning: false,
                latestLocalSnapshot: date,
                latestCompleteBackup: date,
                completeBackupAvailability: .available,
                summaryText: "Backup",
                checkedAt: date
            ),
            stability: StabilitySummary(
                availability: .available,
                status: .healthy,
                crashCount: 0,
                hangCount: 0,
                unexpectedRestartCount: 0,
                events: [],
                filesExamined: 0,
                windowStart: date.addingTimeInterval(-30 * 86_400),
                generatedAt: date
            ),
            batteryEvidence: .present(BatteryHealthSnapshot(
                availability: .available,
                status: .healthy,
                currentChargePercent: 75,
                isCharging: true,
                maximumCapacityPercent: 92,
                cycleCount: 250,
                condition: .normal,
                batteryPowerMode: .automatic,
                adapterPowerMode: .automatic,
                guidance: BatteryGuidance(kind: .none),
                sampledAt: date
            ))
        )
    }

    static func dataInsufficientFixture(date: Date) -> Self {
        Self(
            generatedAt: date,
            disk: DiskHealthSnapshot(
                availability: .unavailable,
                status: .unavailable,
                smartStatus: .unavailable,
                isTRIMEnabled: nil,
                fileSystem: nil,
                isSolidState: nil,
                isInternal: nil,
                summaryText: nil,
                checkedAt: date
            ),
            capacity: CapacityTrendSnapshot(
                availability: .unavailable,
                status: .unavailable,
                totalBytes: nil,
                availableBytes: nil,
                availableForImportantUsageBytes: nil,
                sevenDayDeltaBytes: nil,
                recordedAt: date
            ),
            backup: TimeMachineSnapshot(
                availability: .unavailable,
                status: .unavailable,
                destinationState: .unreachable,
                isRunning: nil,
                latestLocalSnapshot: nil,
                latestCompleteBackup: nil,
                completeBackupAvailability: .unavailable,
                summaryText: nil,
                checkedAt: date
            ),
            stability: StabilitySummary(
                availability: .unavailable,
                status: .unavailable,
                crashCount: nil,
                hangCount: nil,
                unexpectedRestartCount: nil,
                filesExamined: 0,
                windowStart: nil,
                generatedAt: date
            ),
            batteryEvidence: .failed(reason: .unavailable, checkedAt: date)
        )
    }

    static func dataInsufficientWithValidCapacityFixture(date: Date) -> Self {
        let unavailable = dataInsufficientFixture(date: date)
        return Self(
            generatedAt: unavailable.generatedAt,
            disk: unavailable.disk,
            capacity: dashboardFixture(date: date).capacity,
            backup: unavailable.backup,
            stability: unavailable.stability,
            batteryEvidence: unavailable.batteryEvidence
        )
    }
}
