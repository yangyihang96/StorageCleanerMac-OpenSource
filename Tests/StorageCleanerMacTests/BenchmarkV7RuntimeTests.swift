import Foundation
import XCTest

@testable import StorageCleanerMac

final class BenchmarkV7RuntimeTests: XCTestCase {
    func testWorkloadExecutionRejectsAReversedWallClockInterval() {
        let record = BenchmarkV7WorkloadExecutionRecord(
            category: .cpu,
            workloadID: "cpu.single.mixed",
            repetition: 1,
            startedAt: Date(timeIntervalSinceReferenceDate: 2),
            endedAt: Date(timeIntervalSinceReferenceDate: 1),
            elapsedSeconds: 1,
            status: .completed,
            failureReason: nil
        )

        XCTAssertFalse(record.isValid)
    }

    func testStateGraphRejectsIllegalSkip() {
        let state = BenchmarkV7State.idle
        XCTAssertFalse(
            state.canTransition(to: .phase(.running, sessionID: UUID()))
        )
    }

    func testStateProgressIsFiniteAndBounded() {
        let sessionID = UUID()

        XCTAssertEqual(
            BenchmarkV7State.phase(.running, sessionID: sessionID, progress: -0.5).progress,
            0
        )
        XCTAssertEqual(
            BenchmarkV7State.phase(.running, sessionID: sessionID, progress: 1.5).progress,
            1
        )
        XCTAssertEqual(
            BenchmarkV7State.phase(.running, sessionID: sessionID, progress: 0.25).progress,
            0.25
        )
        XCTAssertNil(
            BenchmarkV7State.phase(.running, sessionID: sessionID, progress: .nan).progress
        )
    }

    func testQuickCoordinatorKeepsAllRawSamplesAndDoesNotInventScore() async throws {
        let core = ScriptedCoreService(result: Self.completeRawResult())
        let coordinator = BenchmarkV7Coordinator(
            coreService: core,
            preflightService: ScriptedPreflight(report: Self.preflight())
        )
        let recorder = StateRecorder()
        let result = await coordinator.run(plan: .quick) { state in
            await recorder.append(state)
        }

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.coreScore)
        XCTAssertEqual(result.metrics.count, 6)
        XCTAssertEqual(result.metrics.first?.samples.count, 9)
        let runCount = await core.runCount()
        let states = await recorder.states()
        XCTAssertEqual(runCount, 3)
        XCTAssertTrue(states.contains { $0.phase == .completed })
    }

    func testFullStandardCompletionRequiresFinitePositiveScoresButCustomStaysRawOnly() throws {
        let official = OfficialBenchmarkPlan.legacyV9
        let metric = try Self.metric()
        let validCore = BenchmarkV7CoreScore(categoryScores: [:], overallScore: 6_000)
        let validExperience = BenchmarkV7ExperienceScore(
            metricRatios: [:],
            overallScore: 6_000
        )
        let invalidScores: [(BenchmarkV7CoreScore?, BenchmarkV7ExperienceScore?)] = [
            (nil, validExperience),
            (validCore, nil),
            (BenchmarkV7CoreScore(categoryScores: [:], overallScore: .nan), validExperience),
            (validCore, BenchmarkV7ExperienceScore(metricRatios: [:], overallScore: .infinity)),
            (validCore, BenchmarkV7ExperienceScore(metricRatios: [:], overallScore: 0)),
            (BenchmarkV7CoreScore(categoryScores: [:], overallScore: -1), validExperience),
        ]

        for (coreScore, experienceScore) in invalidScores {
            let result = BenchmarkV7Result(
                session: BenchmarkV7Session(
                    plan: official.plan,
                    categories: official.categories,
                    storageTarget: Self.preflight().storageTarget
                ),
                preflight: Self.preflight(),
                versions: Self.versions(for: official.plan),
                metrics: [metric],
                coreScore: coreScore,
                experienceScore: experienceScore,
                completedAt: Date(timeIntervalSinceReferenceDate: 2),
                failure: nil
            )

            XCTAssertFalse(result.isComplete)
        }

        let customPlan = BenchmarkV7Plan.custom(categories: [.cpu])
        let rawOnly = BenchmarkV7Result(
            session: BenchmarkV7Session(
                plan: customPlan,
                storageTarget: Self.preflight().storageTarget
            ),
            preflight: Self.preflight(),
            versions: Self.versions(for: customPlan),
            metrics: [metric],
            coreScore: nil,
            completedAt: Date(timeIntervalSinceReferenceDate: 2),
            failure: nil
        )
        XCTAssertTrue(rawOnly.isComplete)
    }

    func testBlockedPreflightDoesNotStartCoreServiceWithoutForce() async {
        var blocked = Self.preflight()
        blocked = BenchmarkV7PreflightReport(
            capturedAt: blocked.capturedAt,
            powerSource: blocked.powerSource,
            batteryPercent: blocked.batteryPercent,
            lowPowerModeEnabled: blocked.lowPowerModeEnabled,
            thermalState: .serious,
            backgroundLoadRatio: blocked.backgroundLoadRatio,
            availableMemoryBytes: blocked.availableMemoryBytes,
            storageTarget: blocked.storageTarget,
            displayDescription: blocked.displayDescription,
            checks: [BenchmarkV7PreflightCheck(
                issue: .thermalSerious,
                severity: .blocked,
                detail: "fixture"
            )],
            blockedCategories: BenchmarkV7Category.corePerformance
        )
        let core = ScriptedCoreService(result: Self.completeRawResult())
        let coordinator = BenchmarkV7Coordinator(
            coreService: core,
            preflightService: ScriptedPreflight(report: blocked)
        )

        let result = await coordinator.run(plan: .quick)
        let failure = result.failure
        let runCount = await core.runCount()
        XCTAssertEqual(failure, .preflightBlocked)
        XCTAssertEqual(runCount, 0)
    }

    func testForcedPreflightContinuationCannotBypassUnsafeThermalState() async {
        for (thermalState, issue) in [
            (BenchmarkThermalState.serious, BenchmarkV7PreflightIssue.thermalSerious),
            (.critical, .thermalCritical),
        ] {
            let baseline = Self.preflight()
            let blocked = BenchmarkV7PreflightReport(
                capturedAt: baseline.capturedAt,
                powerSource: baseline.powerSource,
                batteryPercent: baseline.batteryPercent,
                lowPowerModeEnabled: baseline.lowPowerModeEnabled,
                thermalState: thermalState,
                backgroundLoadRatio: baseline.backgroundLoadRatio,
                availableMemoryBytes: baseline.availableMemoryBytes,
                storageTarget: baseline.storageTarget,
                displayDescription: baseline.displayDescription,
                checks: [BenchmarkV7PreflightCheck(
                    issue: issue,
                    severity: .blocked,
                    detail: "fixture"
                )],
                blockedCategories: BenchmarkV7Category.allCases
            )
            let core = ScriptedCoreService(result: Self.completeRawResult())
            let coordinator = BenchmarkV7Coordinator(
                coreService: core,
                preflightService: ScriptedPreflight(report: blocked)
            )

            let result = await coordinator.run(
                plan: .quick,
                forcePreflightContinuation: true
            )

            XCTAssertEqual(result.failure, .preflightBlocked)
            let runCount = await core.runCount()
            XCTAssertEqual(runCount, 0)
        }
    }

    func testHistoryPersistsIncompleteCancellationWithoutOverwritingValidData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("history.json")
        let repository = BenchmarkV7HistoryRepository(storageURL: file)
        var cancelled = BenchmarkV7Result(
            session: BenchmarkV7Session(
                plan: .quick,
                storageTarget: Self.preflight().storageTarget
            ),
            preflight: Self.preflight(),
            versions: Self.versions(for: .quick),
            metrics: [],
            coreScore: nil,
            completedAt: nil,
            failure: .cancelled
        )
        XCTAssertTrue(cancelled.isPersistable)
        try await repository.save(cancelled)
        let stored = await repository.load()
        XCTAssertEqual(stored, [cancelled])
        cancelled = BenchmarkV7Result(
            session: cancelled.session,
            preflight: cancelled.preflight,
            versions: cancelled.versions,
            metrics: [],
            coreScore: nil,
            completedAt: nil,
            failure: .internalFailure
        )
        try await repository.save(cancelled)
        let loaded = await repository.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.compactMap(\.recordID)).count, 2)
    }

    func testHistoryNeverSilentlyDropsOlderCompatibleRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("history.json")
        let repository = BenchmarkV7HistoryRepository(storageURL: file)
        let preflight = Self.preflight()
        let versions = Self.versions(for: .quick)
        var sessionIDs: [UUID] = []

        for _ in 0..<13 {
            let sessionID = UUID()
            sessionIDs.append(sessionID)
            let result = BenchmarkV7Result(
                session: BenchmarkV7Session(
                    id: sessionID,
                    plan: .quick,
                    storageTarget: preflight.storageTarget
                ),
                preflight: preflight,
                versions: versions,
                metrics: [],
                coreScore: nil,
                completedAt: nil,
                failure: .cancelled
            )
            try await repository.save(result)
        }

        let stored = await repository.load()
        XCTAssertEqual(stored.count, sessionIDs.count)
        XCTAssertEqual(Set(stored.map(\.session.id)), Set(sessionIDs))
    }

    func testHistoryJSONRoundTripAndDeletePreservesFailureRecordSemantics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let repository = BenchmarkV7HistoryRepository(storageURL: file)
        let sessionID = UUID()
        let deletedID = UUID()
        let retainedID = UUID()
        let deleted = Self.historyResult(
            recordID: deletedID,
            sessionID: sessionID,
            failure: .cancelled
        )
        let retained = Self.historyResult(
            recordID: retainedID,
            sessionID: sessionID,
            failure: .internalFailure
        )

        try await repository.save(deleted)
        try await repository.save(retained)
        let decoded = try JSONDecoder().decode(
            [BenchmarkV7Result].self,
            from: Data(contentsOf: file)
        )
        XCTAssertEqual(Set(decoded.compactMap(\.recordID)), Set([deletedID, retainedID]))

        let didDelete = try await repository.delete(recordID: deletedID)
        XCTAssertTrue(didDelete)

        let stored = await repository.load()
        XCTAssertEqual(stored, [retained])
        XCTAssertEqual(stored.first?.session.id, sessionID)
        XCTAssertEqual(stored.first?.failure, .internalFailure)
        XCTAssertNil(stored.first?.completedAt)
        XCTAssertTrue(stored.first?.metrics.isEmpty == true)
        XCTAssertTrue(stored.first?.isPersistable == true)
        XCTAssertFalse(stored.first?.isComplete == true)
    }

    func testHistoryAtomicReplaceFailurePreservesOriginalFileBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let repository = BenchmarkV7HistoryRepository(storageURL: file)
        let sessionID = UUID()
        let originalID = UUID()
        let original = Self.historyResult(
            recordID: originalID,
            sessionID: sessionID,
            failure: .internalFailure
        )
        let replacement = Self.historyResult(
            recordID: UUID(),
            sessionID: sessionID,
            failure: .cancelled
        )
        try await repository.save(original)
        let bytesBefore = try Data(contentsOf: file)

        let failingRepository = BenchmarkV7HistoryRepository(
            storageURL: file,
            dataWriter: { _, _ in throw HistoryWriterFixtureError.rejected }
        )
        do {
            try await failingRepository.replace(recordID: originalID, with: replacement)
            XCTFail("Expected the injected atomic writer failure.")
        } catch {
            let status = await failingRepository.loadStatus()
            XCTAssertEqual(status, .failed)
        }

        XCTAssertEqual(try Data(contentsOf: file), bytesBefore)
        let stored = await repository.load()
        XCTAssertEqual(stored, [original])
    }

    func testPartialFailureRoundTripsAndEarlyV7JSONRemainsDecodable() throws {
        let failureRecord = BenchmarkV7WorkloadFailureRecord(
            category: .gpu,
            workloadID: "gpu.compute.fp16",
            reason: "Fixture invalid metric."
        )
        let execution = BenchmarkV7WorkloadExecutionRecord(
            category: .gpu,
            workloadID: failureRecord.workloadID,
            repetition: 1,
            startedAt: Date(timeIntervalSinceReferenceDate: 1),
            endedAt: Date(timeIntervalSinceReferenceDate: 2),
            elapsedSeconds: 1,
            status: .failed,
            failureReason: failureRecord.reason
        )
        let result = BenchmarkV7Result(
            session: BenchmarkV7Session(
                plan: .quick,
                storageTarget: Self.preflight().storageTarget
            ),
            preflight: Self.preflight(),
            versions: Self.versions(for: .quick),
            metrics: [try Self.metric()],
            coreScore: nil,
            workloadFailure: failureRecord,
            workloadExecutions: [execution],
            completedAt: nil,
            failure: .validationFailed(failureRecord.reason)
        )

        XCTAssertEqual(result.completionStatus, .partiallyCompleted)
        XCTAssertTrue(result.isPartiallyCompleted)
        let encoded = try JSONEncoder().encode(result)
        let roundTrip = try JSONDecoder().decode(BenchmarkV7Result.self, from: encoded)
        XCTAssertEqual(roundTrip, result)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "completionStatus")
        legacyObject.removeValue(forKey: "workloadFailure")
        legacyObject.removeValue(forKey: "workloadExecutions")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(BenchmarkV7Result.self, from: legacyData)

        XCTAssertNil(legacy.completionStatus)
        XCTAssertNil(legacy.workloadFailure)
        XCTAssertNil(legacy.workloadExecutions)
        XCTAssertEqual(legacy.resolvedCompletionStatus, .partiallyCompleted)
        XCTAssertTrue(legacy.isPartiallyCompleted)
    }

    func testHistoryDeleteMissingRecordReturnsFalseWithoutChangingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let repository = BenchmarkV7HistoryRepository(storageURL: file)
        let result = Self.historyResult(
            recordID: UUID(),
            sessionID: UUID(),
            failure: .cancelled
        )

        try await repository.save(result)
        let before = try Data(contentsOf: file)

        let didDelete = try await repository.delete(recordID: UUID())
        XCTAssertFalse(didDelete)

        XCTAssertEqual(try Data(contentsOf: file), before)
        let stored = await repository.load()
        XCTAssertEqual(stored, [result])
    }

    private static func preflight() -> BenchmarkV7PreflightReport {
        BenchmarkV7PreflightReport(
            capturedAt: Date(timeIntervalSinceReferenceDate: 1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            backgroundLoadRatio: 0.1,
            availableMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
            storageTarget: BenchmarkV7StorageTarget(
                volumeName: "Fixture",
                fileSystem: "APFS",
                availableBytes: 16 * 1_024 * 1_024 * 1_024,
                isReadOnly: false
            ),
            displayDescription: "Fixture display",
            checks: [],
            blockedCategories: []
        )
    }

    private static func versions(for plan: BenchmarkV7Plan) -> BenchmarkV7VersionManifest {
        BenchmarkV7VersionManifest(
            planVersion: plan.planVersion,
            workloadVersion: plan.workloadVersion,
            statisticsVersion: "benchmark-statistics-v7",
            scoringVersion: "benchmark-scoring-v7",
            referenceSetVersion: "unavailable-v7"
        )
    }

    private static func historyResult(
        recordID: UUID,
        sessionID: UUID,
        failure: BenchmarkV7Failure
    ) -> BenchmarkV7Result {
        BenchmarkV7Result(
            recordID: recordID,
            session: BenchmarkV7Session(
                id: sessionID,
                plan: .quick,
                storageTarget: preflight().storageTarget
            ),
            preflight: preflight(),
            versions: versions(for: .quick),
            metrics: [],
            coreScore: nil,
            completedAt: nil,
            failure: failure
        )
    }

    private static func metric() throws -> BenchmarkV7MetricResult {
        let samples = [BenchmarkV7RawSample(
            value: 42,
            elapsedSeconds: 1,
            wallElapsedSeconds: 1,
            checksum: 42
        )]
        return BenchmarkV7MetricResult(
            manifest: BenchmarkV7MetricManifest(
                id: "fixture.cpu",
                category: .cpu,
                unit: "Mops/s",
                direction: .higherIsBetter,
                weight: 1,
                workloadVersion: "fixture"
            ),
            samples: samples,
            statistics: try BenchmarkStatistics.summarize(samples.map(\.value))
        )
    }

    private static func completeRawResult() -> MacBenchmarkRawResult {
        let started = Date(timeIntervalSinceReferenceDate: 1)
        let finished = Date(timeIntervalSinceReferenceDate: 2)
        let preflight = BenchmarkPreflight(
            capturedAt: started,
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 16 * 1_024 * 1_024 * 1_024,
            requiredDiskBytes: 1,
            warnings: []
        )
        let samples = [
            BenchmarkComponentSample(value: 100, elapsedSeconds: 1, checksum: 42),
            BenchmarkComponentSample(value: 101, elapsedSeconds: 1, checksum: 42),
            BenchmarkComponentSample(value: 102, elapsedSeconds: 1, checksum: 42),
        ]
        let measurements = BenchmarkComponent.allCases.map { component in
            BenchmarkComponentMeasurement(
                component: component,
                unit: component.metricUnit(for: .standard),
                samples: samples
            )
        }
        return MacBenchmarkRawResult(
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v6",
            startedAt: started,
            completedAt: finished,
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: "Fixture",
                activeProcessorCount: 8,
                physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "Fixture",
                appVersion: "1",
                appBuild: "1"
            ),
            preflight: preflight,
            postflight: BenchmarkPostflight(
                capturedAt: finished,
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 16 * 1_024 * 1_024 * 1_024,
                requiredDiskBytes: 1,
                warnings: []
            ),
            capabilitySet: .all,
            measurements: measurements,
            failure: nil
        )
    }
}

private enum HistoryWriterFixtureError: Error {
    case rejected
}

private actor ScriptedCoreService: MacBenchmarkServicing {
    private let result: MacBenchmarkRawResult
    private var count = 0

    init(result: MacBenchmarkRawResult) {
        self.result = result
    }

    func run(
        profile: BenchmarkProfile,
        progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void
    ) async -> MacBenchmarkRawResult {
        count += 1
        await progress(MacBenchmarkProgress(
            stage: .cpuSingle,
            completedSampleCount: 1,
            totalSampleCount: 18,
            progress: 0.1,
            elapsedSeconds: 1
        ))
        return result
    }

    func runCount() -> Int { count }
}

private struct ScriptedPreflight: BenchmarkV7Preflighting {
    let report: BenchmarkV7PreflightReport

    func capture(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL
    ) async -> BenchmarkV7PreflightReport {
        report
    }
}

private actor StateRecorder {
    private var recorded: [BenchmarkV7State] = []

    func append(_ state: BenchmarkV7State) {
        recorded.append(state)
    }

    func states() -> [BenchmarkV7State] { recorded }
}
