import Foundation
import XCTest

@testable import StorageCleanerMac

@MainActor
final class BenchmarkV7HistoryPresentationTests: XCTestCase {
    func testPerformanceProfileFindsRelativeStrengthAndWeakness() throws {
        let profile = try XCTUnwrap(BenchmarkV7PerformanceProfile(coreScore: BenchmarkV7CoreScore(
            categoryScores: [
                .cpu: BenchmarkV7CategoryScore(ratio: 1.25, score: 7_500),
                .gpu: BenchmarkV7CategoryScore(ratio: 0.80, score: 4_800),
                .memory: BenchmarkV7CategoryScore(ratio: 1.05, score: 6_300),
                .storage: BenchmarkV7CategoryScore(ratio: 0.95, score: 5_700),
            ],
            overallScore: 6_000
        )))

        XCTAssertEqual(profile.strongest.category, .cpu)
        XCTAssertEqual(profile.weakest.category, .gpu)
        XCTAssertFalse(profile.isBalanced)
    }

    func testPerformanceProfileCallsCloseResultsBalanced() throws {
        let profile = try XCTUnwrap(BenchmarkV7PerformanceProfile(coreScore: BenchmarkV7CoreScore(
            categoryScores: [
                .cpu: BenchmarkV7CategoryScore(ratio: 1.04, score: 6_240),
                .gpu: BenchmarkV7CategoryScore(ratio: 1.00, score: 6_000),
                .memory: BenchmarkV7CategoryScore(ratio: 0.98, score: 5_880),
                .storage: BenchmarkV7CategoryScore(ratio: 1.02, score: 6_120),
            ],
            overallScore: 6_060
        )))

        XCTAssertTrue(profile.isBalanced)
    }

    func testLegacyScoresRemainExportableAndDeletableButCannotBecomeNewProtocolBest() async throws {
        let olderCurrent = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 8_400,
            categoryScore: 8_400,
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let localBest = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 9_200,
            categoryScore: 9_200,
            completedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let lowConfidence = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 99_999,
            categoryScore: 99_999,
            completedAt: Date(timeIntervalSinceReferenceDate: 250),
            confidenceRating: .low
        )
        let incompatibleManifest = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 99_999,
            categoryScore: 99_999,
            completedAt: Date(timeIntervalSinceReferenceDate: 300),
            scoringVersion: "benchmark-scoring-legacy-fixture"
        )
        let failed = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 88_888,
            categoryScore: 88_888,
            completedAt: Date(timeIntervalSinceReferenceDate: 400),
            failure: .internalFailure
        )
        let repository = InMemoryPresentationV7History(
            initial: [
                localBest,
                lowConfidence,
                incompatibleManifest,
                failed,
                olderCurrent,
            ]
        )
        let store = try makeStore(history: repository)

        await store.loadHistory()

        XCTAssertEqual(store.currentComparableOfficialV7History.count, 0)
        XCTAssertFalse(lowConfidence.isCurrentLocalBestEligible)
        XCTAssertFalse(lowConfidence.isCurrentOfficialRankingEligible)
        XCTAssertNil(store.localBestOfficialV7Result)
        XCTAssertNil(store.localBestOfficialV7ResultsByCategory[.cpu])
        XCTAssertNil(store.latestOfficialV7Result)
        XCTAssertFalse(incompatibleManifest.isCurrentComparableOfficialResult)
        XCTAssertFalse(failed.isCurrentComparableOfficialResult)

        guard let recordID = lowConfidence.recordID,
              let data = store.exportV7HistoryRecord(recordID: recordID)
        else {
            return XCTFail("Expected a JSON export for a persisted local record.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(BenchmarkV7Result.self, from: data), lowConfidence)

        let deleted = await store.deleteV7HistoryRecord(recordID: recordID)
        XCTAssertTrue(deleted)
        XCTAssertFalse(store.v7History.contains { $0.recordID == recordID })
        XCTAssertNil(store.localBestOfficialV7Result)
        XCTAssertNil(store.exportV7HistoryRecord(recordID: recordID))
    }

    func testLocalBestRejectsNonACLowPowerAndNonNominalThermalResults() async throws {
        let eligible = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 8_000,
            categoryScore: 8_000,
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let disqualified = try [
            makeCurrentResult(
                recordID: UUID(),
                overallScore: 99_999,
                categoryScore: 99_999,
                completedAt: Date(timeIntervalSinceReferenceDate: 200),
                powerSource: .battery
            ),
            makeCurrentResult(
                recordID: UUID(),
                overallScore: 99_999,
                categoryScore: 99_999,
                completedAt: Date(timeIntervalSinceReferenceDate: 300),
                lowPowerModeEnabled: true
            ),
            makeCurrentResult(
                recordID: UUID(),
                overallScore: 99_999,
                categoryScore: 99_999,
                completedAt: Date(timeIntervalSinceReferenceDate: 400),
                thermalState: .serious
            ),
        ]
        let store = try makeStore(
            history: InMemoryPresentationV7History(initial: [eligible] + disqualified)
        )

        await store.loadHistory()

        XCTAssertNil(store.localBestOfficialV7Result)
        XCTAssertNil(store.localBestOfficialV7ResultsByCategory[.cpu])
        XCTAssertTrue(disqualified.allSatisfy { !$0.isCurrentOfficialRankingEligible })
    }

    func testDeletingLastConfirmedRecordCannotRevealRevokedLateSuccess() async throws {
        let revoked = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 99_999,
            categoryScore: 99_999,
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let confirmed = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 8_000,
            categoryScore: 8_000,
            completedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let defaultsName = "BenchmarkV7RevokedDelete.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(
            [try XCTUnwrap(revoked.recordID).uuidString],
            forKey: "benchmark.v7.unconfirmedPromotionRecordIDs"
        )
        XCTAssertTrue(defaults.synchronize())

        let store = try makeStore(
            history: InMemoryPresentationV7History(initial: [confirmed, revoked]),
            revocationDefaults: defaults
        )
        await store.loadHistory()
        XCTAssertNil(store.latestOfficialV7Result)

        let deleted = await store.deleteV7HistoryRecord(
            recordID: try XCTUnwrap(confirmed.recordID)
        )
        XCTAssertTrue(deleted)
        XCTAssertTrue(store.v7History.isEmpty)
        XCTAssertNil(store.v7LatestResult)
        XCTAssertNil(store.latestOfficialV7Result)
    }

    func testOfficialAndLocalBestRejectSafetyStoppedSustainedResult() throws {
        let earlyStop = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 99_999,
            categoryScore: 99_999,
            completedAt: Date(timeIntervalSinceReferenceDate: 500),
            sustainedReachedTarget: false
        )

        XCTAssertTrue(earlyStop.sustainedResult?.isComplete == true)
        XCTAssertFalse(earlyStop.sustainedResult?.reachedTargetDuration == true)
        XCTAssertFalse(earlyStop.isCurrentOfficialResult)
        XCTAssertFalse(earlyStop.isCurrentLocalBestEligible)
        XCTAssertFalse(earlyStop.isCurrentOfficialRankingEligible)
    }

    func testLatestProjectionNeverRelabelsLegacyScoresAsTheNewProtocol() async throws {
        let current = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 9_000,
            categoryScore: 9_000,
            completedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let incompatibleNewer = try makeCurrentResult(
            recordID: UUID(),
            overallScore: 50_000,
            categoryScore: 50_000,
            completedAt: Date(timeIntervalSinceReferenceDate: 20),
            scoringVersion: "benchmark-scoring-fixture-legacy"
        )
        let store = try makeStore(
            history: InMemoryPresentationV7History(initial: [incompatibleNewer, current])
        )

        await store.loadHistory()

        XCTAssertNil(store.latestOfficialV7Result)
        XCTAssertEqual(store.currentV7ScoringVersion, MSeriesProtocol.scoring)
    }

    private func makeStore(
        history: any BenchmarkV7HistoryPersisting,
        revocationDefaults: UserDefaults = .standard
    ) throws -> MacBenchmarkStore {
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "fixture",
            verifiedBaselines: []
        )
        return MacBenchmarkStore(
            service: UnusedPresentationCoreService(),
            resultProcessor: MacBenchmarkResultProcessor(baselineCatalog: catalog),
            lifecycleCleaner: NoopPresentationLifecycleCleaner(),
            historyRepository: EmptyPresentationV6History(),
            v7HistoryRepository: history,
            v7PromotionRevocationDefaults: revocationDefaults
        )
    }

    private func makeCurrentResult(
        recordID: UUID,
        overallScore: Double,
        categoryScore: Double,
        completedAt: Date,
        scoringVersion: String? = nil,
        failure: BenchmarkV7Failure? = nil,
        confidenceRating: BenchmarkV7ConfidenceRating = .high,
        powerSource: BenchmarkPowerSource = .acPower,
        lowPowerModeEnabled: Bool = false,
        thermalState: BenchmarkThermalState = .nominal,
        sustainedReachedTarget: Bool = true
    ) throws -> BenchmarkV7Result {
        let official = OfficialBenchmarkPlan.legacyV9
        let preflight = makePreflight(
            powerSource: powerSource,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState
        )
        let currentVersions = BenchmarkV7ReferenceCatalog.versions(for: official.plan)
        let versions = BenchmarkV7VersionManifest(
            schemaVersion: currentVersions.schemaVersion,
            planVersion: currentVersions.planVersion,
            workloadVersion: currentVersions.workloadVersion,
            cpuWorkloadVersion: currentVersions.cpuWorkloadVersion,
            gpuWorkloadVersion: currentVersions.gpuWorkloadVersion,
            memoryWorkloadVersion: currentVersions.memoryWorkloadVersion,
            storageWorkloadVersion: currentVersions.storageWorkloadVersion,
            displayWorkloadVersion: currentVersions.displayWorkloadVersion,
            statisticsVersion: currentVersions.statisticsVersion,
            scoringVersion: scoringVersion ?? currentVersions.scoringVersion,
            referenceSetVersion: currentVersions.referenceSetVersion
        )
        let samples = [
            BenchmarkV7RawSample(value: 100, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 1),
            BenchmarkV7RawSample(value: 101, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 2),
            BenchmarkV7RawSample(value: 102, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 3),
        ]
        let metric = BenchmarkV7MetricResult(
            manifest: BenchmarkV7MetricManifest(
                id: "fixture.cpu",
                category: .cpu,
                unit: "Mops/s",
                direction: .higherIsBetter,
                weight: 1,
                workloadVersion: official.plan.workloadVersion
            ),
            samples: samples,
            statistics: try BenchmarkStatistics.summarize(samples.map(\.value))
        )
        let categoryScores = Dictionary(
            uniqueKeysWithValues: BenchmarkV7Category.corePerformance.map { category in
                (
                    category,
                    BenchmarkV7CategoryScore(
                        ratio: categoryScore / 6_000,
                        score: categoryScore
                    )
                )
            }
        )
        let environment = BenchmarkEnvironmentMetadata(
            architecture: .arm64,
            chipName: "Fixture Mac",
            activeProcessorCount: 8,
            physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
            powerSource: powerSource,
            thermalState: thermalState,
            operatingSystemVersion: "FixtureOS",
            appVersion: "1.9.9",
            appBuild: "999"
        )
        return BenchmarkV7Result(
            recordID: recordID,
            session: BenchmarkV7Session(
                plan: official.plan,
                categories: official.categories,
                storageTarget: preflight.storageTarget,
                startedAt: completedAt.addingTimeInterval(-60)
            ),
            preflight: preflight,
            environment: environment,
            versions: versions,
            metrics: [metric],
            coreScore: BenchmarkV7CoreScore(
                categoryScores: categoryScores,
                overallScore: overallScore
            ),
            experienceScore: BenchmarkV7ExperienceScore(
                metricRatios: ["fixture.cpu": 1],
                overallScore: overallScore
            ),
            sustainedResult: makeSustainedResult(
                environment: environment,
                completedAt: completedAt,
                reachedTarget: sustainedReachedTarget
            ),
            confidence: BenchmarkV7Confidence(
                rating: confidenceRating,
                maximumRelativeMAD: 0.01,
                reasons: []
            ),
            completedAt: completedAt,
            failure: failure
        )
    }

    private func makePreflight(
        powerSource: BenchmarkPowerSource = .acPower,
        lowPowerModeEnabled: Bool = false,
        thermalState: BenchmarkThermalState = .nominal
    ) -> BenchmarkV7PreflightReport {
        BenchmarkV7PreflightReport(
            capturedAt: Date(timeIntervalSinceReferenceDate: 1),
            powerSource: powerSource,
            batteryPercent: 100,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            backgroundLoadRatio: 0.1,
            availableMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
            storageTarget: BenchmarkV7StorageTarget(
                volumeName: "Fixture",
                fileSystem: "APFS",
                availableBytes: 64 * 1_024 * 1_024 * 1_024,
                isReadOnly: false
            ),
            displayDescription: "Fixture display",
            checks: [],
            blockedCategories: []
        )
    }

    private func makeSustainedResult(
        environment: BenchmarkEnvironmentMetadata,
        completedAt: Date,
        reachedTarget: Bool = true
    ) -> MacSustainedBenchmarkResult {
        let startedAt = completedAt.addingTimeInterval(-8)
        let preflight = BenchmarkPreflight(
            capturedAt: startedAt.addingTimeInterval(1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 100_000_000_000,
            requiredDiskBytes: 1,
            warnings: []
        )
        var windows: [MacSustainedBenchmarkWindow] = []
        for index in 0..<3 {
            windows.append(
                MacSustainedBenchmarkWindow(
                    index: index,
                    startedAtSeconds: Double(index * 2),
                    completedAtSeconds: Double(index * 2 + 1),
                    cpuMultiSample: BenchmarkComponentSample(
                        value: 100 - Double(index),
                        elapsedSeconds: 1,
                        checksum: 1
                    ),
                    gpuRasterSample: BenchmarkComponentSample(
                        value: 200 - Double(index),
                        elapsedSeconds: 1,
                        checksum: 2
                    )
                )
            )
        }
        return MacSustainedBenchmarkResult(
            profile: .standard,
            coolingMode: .systemAutomatic,
            targetDurationSeconds: 6,
            workloadDurationSeconds: reachedTarget ? 6 : 5,
            totalObservationDurationSeconds: reachedTarget ? 6 : 5,
            startedAt: startedAt,
            completedAt: completedAt,
            environment: environment,
            preflight: preflight,
            windows: windows,
            telemetry: [
                MacSustainedTelemetrySample(
                    elapsedSeconds: 0,
                    thermalState: .nominal,
                    powerSource: .acPower,
                    lowPowerModeEnabled: false,
                    chipTemperatureCelsius: 45,
                    fans: .unsupported
                ),
                MacSustainedTelemetrySample(
                    elapsedSeconds: reachedTarget ? 6 : 5,
                    thermalState: .nominal,
                    powerSource: .acPower,
                    lowPowerModeEnabled: !reachedTarget,
                    chipTemperatureCelsius: 60,
                    fans: .unsupported
                ),
            ],
            termination: reachedTarget ? .targetDurationReached : .lowPowerModeEnabled,
            cooldownReachedNominal: nil,
            failure: nil
        )
    }
}

private actor InMemoryPresentationV7History: BenchmarkV7HistoryPersisting {
    private var results: [BenchmarkV7Result]

    init(initial: [BenchmarkV7Result]) {
        results = initial
    }

    func load() async -> [BenchmarkV7Result] { results }
    func save(_ result: BenchmarkV7Result) async throws { results.append(result) }

    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            throw PresentationV7HistoryError.missingRecord
        }
        results[index] = result
    }

    func delete(recordID: UUID) async throws -> Bool {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            return false
        }
        results.remove(at: index)
        return true
    }

    func loadStatus() async -> BenchmarkV7HistoryLoadStatus { .loaded }
}

private enum PresentationV7HistoryError: Error {
    case missingRecord
}

private actor EmptyPresentationV6History: MacBenchmarkHistoryPersisting {
    func load() async -> [MacBenchmarkResult] { [] }
    func save(_ result: MacBenchmarkResult) async throws { _ = result }
    func loadStatus() async -> MacBenchmarkHistoryLoadStatus { .missing }
}

private struct UnusedPresentationCoreService: MacBenchmarkServicing {
    func run(
        profile: BenchmarkProfile,
        progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void
    ) async -> MacBenchmarkRawResult {
        _ = profile
        _ = progress
        fatalError("This test only exercises V7 history projections.")
    }
}

private struct NoopPresentationLifecycleCleaner: MacBenchmarkLifecycleCleaning {
    func cleanupOrphanedArtifactsOnLaunch() async {}
}
