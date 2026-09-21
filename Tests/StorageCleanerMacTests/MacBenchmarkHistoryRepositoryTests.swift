import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkHistoryRepositoryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacBenchmarkHistoryRepositoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        storageURL = temporaryDirectory.appendingPathComponent("history.json")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testRoundTripKeepsNewestSuccessfulRunsPerProfile() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<(MacBenchmarkHistoryRepository.maximumResultsPerProfile + 3) {
            try await repository.save(
                makeResult(
                    profile: .quick,
                    startedAt: base.addingTimeInterval(Double(index * 10))
                )
            )
        }
        try await repository.save(
            makeResult(profile: .full, startedAt: base.addingTimeInterval(1_000))
        )

        let loaded = await repository.load()
        let quick = loaded.filter { $0.rawResult?.profile == .quick }
        let full = loaded.filter { $0.rawResult?.profile == .full }

        XCTAssertEqual(quick.count, MacBenchmarkHistoryRepository.maximumResultsPerProfile)
        XCTAssertEqual(full.count, 1)
        XCTAssertEqual(
            loaded.compactMap { $0.rawResult?.completedAt },
            loaded.compactMap { $0.rawResult?.completedAt }.sorted(by: >)
        )
        XCTAssertEqual(quick.first?.rawResult?.startedAt, base.addingTimeInterval(140))
    }

    func testMissingHistoryIsEmptyAndFirstSaveCreatesIt() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        let missingHistory = await repository.load()
        XCTAssertTrue(missingHistory.isEmpty)
        let missingStatus = await repository.loadStatus()
        XCTAssertEqual(missingStatus, .missing)

        let valid = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await repository.save(valid)

        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        let persistedHistory = await repository.load()
        XCTAssertEqual(persistedHistory, [valid])
        let loadedStatus = await repository.loadStatus()
        XCTAssertEqual(loadedStatus, .loaded)
    }

    func testSavingSameRunReplacesDuplicateInsteadOfGrowingHistory() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let result = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await repository.save(result)
        try await repository.save(result)

        let loaded = await repository.load()
        XCTAssertEqual(loaded.count, 1)
    }

    func testSameStartTimeWithDifferentRawEvidenceKeepsDistinctSessions()
        async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeResult(
            profile: .quick,
            startedAt: startedAt,
            sampleBias: 0
        )
        let second = makeResult(
            profile: .quick,
            startedAt: startedAt,
            sampleBias: 10
        )

        XCTAssertNotEqual(
            first.rawResult.flatMap(BenchmarkSessionIdentity.stableID),
            second.rawResult.flatMap(BenchmarkSessionIdentity.stableID)
        )
        try await repository.save(first)
        try await repository.save(second)

        let loaded = await repository.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(
            Set(loaded.compactMap(\.rawResult).compactMap(
                BenchmarkSessionIdentity.stableID
            )).count,
            2
        )
    }

    func testFutureDatedResultsAreRejectedOnSaveAndIgnoredOnLoad() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let future = makeResult(
            profile: .quick,
            startedAt: Date().addingTimeInterval(
                MacBenchmarkHistoryRepository.maximumFutureClockSkew + 60
            )
        )

        do {
            try await repository.save(future)
            XCTFail("未来时间的跑分不得进入历史")
        } catch {
            XCTAssertEqual(error as? MacBenchmarkHistoryRepositoryError, .invalidResult)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode([future]).write(to: storageURL, options: .atomic)
        let loaded = await repository.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testIncompleteOrFailedResultIsRejectedWithoutReplacingHistory() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let valid = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await repository.save(valid)
        let bytesBeforeRejectedSave = try Data(contentsOf: storageURL)

        do {
            try await repository.save(.incomplete(completed: [.cpuSingle: 100]))
            XCTFail("不完整跑分不应进入历史")
        } catch {
            XCTAssertEqual(error as? MacBenchmarkHistoryRepositoryError, .invalidResult)
        }

        let loaded = await repository.load()
        XCTAssertEqual(loaded, [valid])
        XCTAssertEqual(try Data(contentsOf: storageURL), bytesBeforeRejectedSave)
    }

    func testPartialComponentScoresAreRejectedInsteadOfBecomingMisleadingHistory() async {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let complete = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            includeScore: true
        )
        let partial = MacBenchmarkResult(
            rawResult: complete.rawResult!,
            comparisonKey: complete.comparisonKey!,
            matchedBaselineKey: nil,
            componentScores: [.cpuSingle: 1_000],
            proposedOverallScore: nil
        )

        do {
            try await repository.save(partial)
            XCTFail("部分分项分数不应伪装成可比较历史")
        } catch {
            XCTAssertEqual(error as? MacBenchmarkHistoryRepositoryError, .invalidResult)
        }
        let loaded = await repository.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testDirectlyConstructedScoreWithNonComparablePostflightIsRejected() async {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let complete = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            includeScore: true
        )
        let raw = complete.rawResult!
        let hotRaw = MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: raw.completedAt,
            environment: raw.environment,
            preflight: raw.preflight,
            postflight: BenchmarkPostflight(
                capturedAt: raw.postflight!.capturedAt,
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .serious
            ),
            capabilitySet: raw.capabilitySet,
            measurements: raw.measurements,
            failure: nil
        )
        let forged = MacBenchmarkResult(
            rawResult: hotRaw,
            comparisonKey: complete.comparisonKey,
            matchedBaselineKey: complete.matchedBaselineKey,
            componentScores: complete.componentScores,
            proposedOverallScore: complete.overallScore
        )

        do {
            try await repository.save(forged)
            XCTFail("结束时高温的直接构造分数不得进入历史")
        } catch {
            XCTAssertEqual(error as? MacBenchmarkHistoryRepositoryError, .invalidResult)
        }
        let history = await repository.load()
        XCTAssertTrue(history.isEmpty)
    }

    func testRawOnlySuccessfulResultCanBeSavedWithoutInventingScore() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let rawOnly = makeResult(
            profile: .full,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            includeScore: false
        )

        try await repository.save(rawOnly)
        let history = await repository.load()
        let loaded = try XCTUnwrap(history.first)

        XCTAssertTrue(loaded.isComplete)
        XCTAssertNil(loaded.overallScore)
        XCTAssertTrue(loaded.componentScores.isEmpty)
    }

    func testProductionArchivePreservesTrustedV3AndV4ScoresAcrossV6Save() async throws {
        let archiveProcessors = MacBenchmarkProductionBaselineCatalog
            .trustedHistoryResultProcessors()
        XCTAssertEqual(archiveProcessors.count, 2)

        let v3Raw = try XCTUnwrap(makeResult(
            profile: .quick,
            workloadVersion: "mac-benchmark-quick-v3",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ).rawResult)
        let v4Raw = try XCTUnwrap(makeResult(
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v4",
            startedAt: Date(timeIntervalSince1970: 1_700_000_100)
        ).rawResult)
        let trustedV3 = try archivedScoredResult(
            for: v3Raw,
            processors: archiveProcessors
        )
        let trustedV4 = try archivedScoredResult(
            for: v4Raw,
            processors: archiveProcessors
        )
        XCTAssertEqual(trustedV3.comparisonKey?.baselineVersion, "m5-pro-2026-07-v3")
        XCTAssertEqual(trustedV4.comparisonKey?.baselineVersion, "m5-pro-2026-07-v4")

        let activeProcessor = MacBenchmarkResultProcessor(
            baselineCatalog: MacBenchmarkProductionBaselineCatalog.runtimeCatalog()
        )
        XCTAssertEqual(
            try activeProcessor.process(v3Raw).rawOnlyReason,
            .verifiedBaselineUnavailable
        )
        XCTAssertEqual(
            try activeProcessor.process(v4Raw).rawOnlyReason,
            .verifiedBaselineUnavailable
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode([trustedV3, trustedV4]).write(
            to: storageURL,
            options: .atomic
        )
        let repository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            trustedResultProcessors: archiveProcessors
        )
        let initiallyLoaded = await repository.load()
        XCTAssertEqual(
            Set(initiallyLoaded.compactMap { $0.comparisonKey?.baselineVersion }),
            Set(["m5-pro-2026-07-v3", "m5-pro-2026-07-v4"])
        )
        XCTAssertTrue(initiallyLoaded.allSatisfy { $0.overallScore != nil })

        let rawOnlyV6 = makeResult(
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            startedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try await repository.save(rawOnlyV6)

        let loadedAfterV6Save = await repository.load()
        XCTAssertEqual(loadedAfterV6Save.count, 3)
        XCTAssertEqual(
            Set(loadedAfterV6Save.compactMap { $0.comparisonKey?.baselineVersion }),
            Set(["m5-pro-2026-07-v3", "m5-pro-2026-07-v4"])
        )
        XCTAssertEqual(
            loadedAfterV6Save.first {
                $0.rawResult?.workloadVersion
                    == MacBenchmarkScoring.balancedCompositeWorkloadVersion
            }?.overallScore,
            nil
        )
        XCTAssertEqual(
            loadedAfterV6Save.first {
                $0.rawResult?.workloadVersion == "mac-benchmark-standard-v4"
            }?.overallScore,
            trustedV4.overallScore
        )

        let reloadedRepository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            trustedResultProcessors: archiveProcessors
        )
        let reloadedHistory = await reloadedRepository.load()
        XCTAssertEqual(reloadedHistory, loadedAfterV6Save)
    }

    func testPerWorkloadLimitPreventsNewV6RunsFromEvictingV4History() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let count = MacBenchmarkHistoryRepository.maximumResultsPerProfile + 3

        for index in 0..<count {
            try await repository.save(makeResult(
                profile: .standard,
                workloadVersion: "mac-benchmark-standard-v4",
                startedAt: base.addingTimeInterval(Double(index))
            ))
        }
        for index in 0..<count {
            try await repository.save(makeResult(
                profile: .standard,
                workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
                startedAt: base.addingTimeInterval(Double(1_000 + index))
            ))
        }

        let history = await repository.load()
        XCTAssertEqual(history.count, MacBenchmarkHistoryRepository.maximumResultsPerProfile * 2)
        XCTAssertEqual(
            history.filter {
                $0.rawResult?.workloadVersion == "mac-benchmark-standard-v4"
            }.count,
            MacBenchmarkHistoryRepository.maximumResultsPerProfile
        )
        XCTAssertEqual(
            history.filter {
                $0.rawResult?.workloadVersion
                    == MacBenchmarkScoring.balancedCompositeWorkloadVersion
            }.count,
            MacBenchmarkHistoryRepository.maximumResultsPerProfile
        )
    }

    func testScoredResultMustRecomputeExactlyAgainstTrustedBaseline() async throws {
        let scored = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            includeScore: true
        )
        let processor = try makeTrustedProcessor(for: XCTUnwrap(scored.rawResult))
        let repository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            trustedResultProcessor: processor
        )

        try await repository.save(scored)
        let initiallyLoaded = await repository.load()
        XCTAssertEqual(initiallyLoaded, [scored])

        let forged = MacBenchmarkResult(
            rawResult: try XCTUnwrap(scored.rawResult),
            comparisonKey: scored.comparisonKey,
            matchedBaselineKey: scored.matchedBaselineKey,
            componentScores: Dictionary(
                uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, 1_234.0) }
            ),
            proposedOverallScore: 1_234
        )
        do {
            try await repository.save(forged)
            XCTFail("篡改后的分数不得进入历史")
        } catch {
            XCTAssertEqual(error as? MacBenchmarkHistoryRepositoryError, .invalidResult)
        }
        let loadedAfterForgery = await repository.load()
        XCTAssertEqual(loadedAfterForgery, [scored])
    }

    func testScoreToleranceCanonicalizesTinyDriftAndRejectsEveryTamperedValueAndKey() async throws {
        let scored = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            includeScore: true
        )
        let raw = try XCTUnwrap(scored.rawResult)
        let repository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            trustedResultProcessor: try makeTrustedProcessor(for: raw)
        )
        let tinyDrift = MacBenchmarkHistoryRepository
            .trustedScoreAbsoluteTolerance / 2
        var nearScores = scored.componentScores
        nearScores[.cpuSingle] = try XCTUnwrap(nearScores[.cpuSingle]) + tinyDrift
        let near = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: scored.comparisonKey,
            matchedBaselineKey: scored.matchedBaselineKey,
            componentScores: nearScores,
            proposedOverallScore: try XCTUnwrap(scored.overallScore) + tinyDrift
        )

        try await repository.save(near)
        let canonicalHistory = await repository.load()
        XCTAssertEqual(canonicalHistory, [scored], "容差内也只落盘重算后的标准值")
        let trustedBytes = try Data(contentsOf: storageURL)

        for component in BenchmarkComponent.allCases {
            var forgedScores = scored.componentScores
            forgedScores[component] = try XCTUnwrap(forgedScores[component]) + 0.000_001
            let forged = MacBenchmarkResult(
                rawResult: raw,
                comparisonKey: scored.comparisonKey,
                matchedBaselineKey: scored.matchedBaselineKey,
                componentScores: forgedScores,
                proposedOverallScore: scored.overallScore
            )
            await assertRejectedSave(forged, repository: repository)
            XCTAssertEqual(try Data(contentsOf: storageURL), trustedBytes)
        }

        let forgedOverall = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: scored.comparisonKey,
            matchedBaselineKey: scored.matchedBaselineKey,
            componentScores: scored.componentScores,
            proposedOverallScore: try XCTUnwrap(scored.overallScore) + 0.000_001
        )
        await assertRejectedSave(forgedOverall, repository: repository)

        var wrongKey = try XCTUnwrap(scored.comparisonKey)
        wrongKey.baselineVersion = "forged-baseline"
        let forgedComparisonKey = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: wrongKey,
            matchedBaselineKey: wrongKey,
            componentScores: scored.componentScores,
            proposedOverallScore: scored.overallScore
        )
        await assertRejectedSave(forgedComparisonKey, repository: repository)

        let forgedMatchedKey = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: scored.comparisonKey,
            matchedBaselineKey: wrongKey,
            componentScores: scored.componentScores,
            proposedOverallScore: scored.overallScore
        )
        await assertRejectedSave(forgedMatchedKey, repository: repository)
        XCTAssertEqual(try Data(contentsOf: storageURL), trustedBytes)
    }

    func testLegalJSONWithForgedScoreOrKeysKeepsRawMeasurementsAsRawOnly() async throws {
        let scored = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            includeScore: true
        )
        let raw = try XCTUnwrap(scored.rawResult)
        let repository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            trustedResultProcessor: try makeTrustedProcessor(for: raw)
        )
        var wrongKey = try XCTUnwrap(scored.comparisonKey)
        wrongKey.baselineVersion = "forged-baseline"
        var forgedComponentScores = scored.componentScores
        forgedComponentScores[.gpu] = 4_999
        let variants = [
            MacBenchmarkResult(
                rawResult: raw,
                comparisonKey: scored.comparisonKey,
                matchedBaselineKey: scored.matchedBaselineKey,
                componentScores: forgedComponentScores,
                proposedOverallScore: scored.overallScore
            ),
            MacBenchmarkResult(
                rawResult: raw,
                comparisonKey: scored.comparisonKey,
                matchedBaselineKey: scored.matchedBaselineKey,
                componentScores: scored.componentScores,
                proposedOverallScore: 4_999
            ),
            MacBenchmarkResult(
                rawResult: raw,
                comparisonKey: wrongKey,
                matchedBaselineKey: wrongKey,
                componentScores: scored.componentScores,
                proposedOverallScore: scored.overallScore
            ),
            MacBenchmarkResult(
                rawResult: raw,
                comparisonKey: scored.comparisonKey,
                matchedBaselineKey: wrongKey,
                componentScores: scored.componentScores,
                proposedOverallScore: scored.overallScore
            ),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for forged in variants {
            try encoder.encode([forged]).write(to: storageURL, options: .atomic)
            let history = await repository.load()
            let loaded = try XCTUnwrap(history.first)
            XCTAssertEqual(loaded.rawResult, raw)
            XCTAssertEqual(loaded.rawResult?.measurements, raw.measurements)
            XCTAssertTrue(loaded.componentScores.isEmpty)
            XCTAssertNil(loaded.overallScore)
            XCTAssertNil(loaded.comparisonKey)
            XCTAssertNil(loaded.matchedBaselineKey)
        }

        try encoder.encode([scored]).write(to: storageURL, options: .atomic)
        let untrustedRepository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let historyWithoutCatalog = await untrustedRepository.load()
        let loadedWithoutCatalog = try XCTUnwrap(historyWithoutCatalog.first)
        XCTAssertEqual(loadedWithoutCatalog.rawResult, raw)
        XCTAssertTrue(loadedWithoutCatalog.componentScores.isEmpty)
        XCTAssertNil(loadedWithoutCatalog.overallScore)
    }

    func testTwoRepositoryInstancesDoNotLoseConcurrentRuns() async throws {
        // This batch verifies atomicity across repository instances. Allow its
        // 24 queued writes to finish under load; dedicated tests below verify
        // the short lock deadline, cancellation, and failure recovery.
        let first = MacBenchmarkHistoryRepository(storageURL: storageURL, fileLockTimeout: .seconds(5))
        let second = MacBenchmarkHistoryRepository(storageURL: storageURL, fileLockTimeout: .seconds(5))
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<MacBenchmarkHistoryRepository.maximumResultsPerProfile {
                let quick = makeResult(
                    profile: .quick,
                    startedAt: base.addingTimeInterval(Double(index))
                )
                let full = makeResult(
                    profile: .full,
                    startedAt: base.addingTimeInterval(Double(1_000 + index))
                )
                group.addTask { try await first.save(quick) }
                group.addTask { try await second.save(full) }
            }
            try await group.waitForAll()
        }

        let history = await first.load()
        XCTAssertEqual(
            history.filter { $0.rawResult?.profile == .quick }.count,
            MacBenchmarkHistoryRepository.maximumResultsPerProfile
        )
        XCTAssertEqual(
            history.filter { $0.rawResult?.profile == .full }.count,
            MacBenchmarkHistoryRepository.maximumResultsPerProfile
        )
    }

    func testHeldAdvisoryLockTimesOutWithoutChangingHistoryThenRecovers() async throws {
        let repository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            fileLockTimeout: .milliseconds(80),
            fileLockRetryInterval: .milliseconds(3)
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.save(makeResult(profile: .quick, startedAt: base))
        let originalBytes = try Data(contentsOf: storageURL)

        var descriptor = try acquireRealSidecarLock()
        defer {
            if descriptor >= 0 { releaseRealSidecarLock(descriptor) }
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            try await repository.save(
                makeResult(profile: .full, startedAt: base.addingTimeInterval(100))
            )
            XCTFail("已被真实 advisory lock 占用时不应写入")
        } catch {
            XCTAssertEqual(
                error as? MacBenchmarkHistoryRepositoryError,
                .fileLockTimedOut
            )
        }
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(try Data(contentsOf: storageURL), originalBytes)

        releaseRealSidecarLock(descriptor)
        descriptor = -1
        try await repository.save(
            makeResult(profile: .full, startedAt: base.addingTimeInterval(100))
        )
        let recoveredHistory = await repository.load()
        XCTAssertEqual(recoveredHistory.count, 2)
    }

    func testCancellationWhileWaitingForRealLockReleasesProcessGate() async throws {
        let repository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            fileLockTimeout: .seconds(5),
            fileLockRetryInterval: .milliseconds(3)
        )
        var descriptor = try acquireRealSidecarLock()
        defer {
            if descriptor >= 0 { releaseRealSidecarLock(descriptor) }
        }
        let result = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let task = Task { try await repository.save(result) }
        try await Task.sleep(for: .milliseconds(25))
        task.cancel()
        do {
            try await task.value
            XCTFail("取消后的锁等待必须尽快结束")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        releaseRealSidecarLock(descriptor)
        descriptor = -1
        try await repository.save(result)
        let recoveredHistory = await repository.load()
        XCTAssertEqual(recoveredHistory.count, 1)
    }

    func testSecondRepositoryProcessGateUsesSameDeadlineAndCannotHang() async throws {
        let slowRepository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            fileLockTimeout: .seconds(2),
            fileLockRetryInterval: .milliseconds(3)
        )
        let fastRepository = MacBenchmarkHistoryRepository(
            storageURL: storageURL,
            fileLockTimeout: .milliseconds(70),
            fileLockRetryInterval: .milliseconds(3)
        )
        var descriptor = try acquireRealSidecarLock()
        defer {
            if descriptor >= 0 { releaseRealSidecarLock(descriptor) }
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstResult = makeResult(profile: .quick, startedAt: base)
        let firstTask = Task {
            try await slowRepository.save(firstResult)
        }
        try await Task.sleep(for: .milliseconds(20))

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            try await fastRepository.save(
                makeResult(
                    profile: .full,
                    startedAt: base.addingTimeInterval(100)
                )
            )
            XCTFail("进程内 gate 被占用时也必须超时")
        } catch {
            XCTAssertEqual(
                error as? MacBenchmarkHistoryRepositoryError,
                .fileLockTimedOut
            )
        }
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))

        firstTask.cancel()
        do {
            try await firstTask.value
            XCTFail("首个等待任务取消后不应继续持有 gate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        releaseRealSidecarLock(descriptor)
        descriptor = -1
        try await fastRepository.save(
            makeResult(profile: .full, startedAt: base.addingTimeInterval(100))
        )
    }

    func testHistoryAndSidecarUsePrivatePermissions() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        try await repository.save(
            makeResult(
                profile: .quick,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        for url in [storageURL!, storageURL.appendingPathExtension("lock")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600, url.lastPathComponent)
        }
    }

    func testSymlinkedSidecarAndHistoryAreNeverFollowed() async throws {
        let victim = temporaryDirectory.appendingPathComponent("victim.json")
        let victimBytes = Data("private-victim".utf8)
        try victimBytes.write(to: victim)
        let lockURL = storageURL.appendingPathExtension("lock")
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: victim
        )
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let result = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        do {
            try await repository.save(result)
            XCTFail("sidecar 符号链接必须被 O_NOFOLLOW 拒绝")
        } catch {
            XCTAssertNotNil(error as? MacBenchmarkHistoryRepositoryError)
        }
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))

        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(
            at: storageURL,
            withDestinationURL: victim
        )
        let symlinkedHistory = await repository.load()
        XCTAssertTrue(symlinkedHistory.isEmpty)
        do {
            try await repository.save(result)
            XCTFail("历史文件符号链接不得被读取或替换")
        } catch {
            XCTAssertEqual(
                error as? MacBenchmarkHistoryRepositoryError,
                .historyFileUnreadable
            )
        }
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
        var status = stat()
        XCTAssertEqual(lstat(storageURL.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK)
    }

    func testSymlinkedStorageDirectoryIsRejectedBeforeCreatingFiles() async throws {
        let realDirectory = temporaryDirectory.appendingPathComponent(
            "real-history",
            isDirectory: true
        )
        let linkedDirectory = temporaryDirectory.appendingPathComponent(
            "linked-history",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )
        let linkedStorage = linkedDirectory.appendingPathComponent("history.json")
        let repository = MacBenchmarkHistoryRepository(storageURL: linkedStorage)

        do {
            try await repository.save(
                makeResult(
                    profile: .quick,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
            XCTFail("存储目录本身为符号链接时必须拒绝")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: realDirectory.path))
                .isEmpty
        )
    }

    func testCorruptJSONFallsBackToEmptyButNextSavePreservesOriginalBytes() async throws {
        let corruptBytes = Data("not-json".utf8)
        try corruptBytes.write(to: storageURL)
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        let corruptHistory = await repository.load()
        XCTAssertTrue(corruptHistory.isEmpty)
        let corruptStatus = await repository.loadStatus()
        XCTAssertEqual(
            corruptStatus,
            .failed(.historyFileCorrupt)
        )

        let valid = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        do {
            try await repository.save(valid)
            XCTFail("损坏的历史不得被新跑分静默覆盖")
        } catch {
            XCTAssertEqual(
                error as? MacBenchmarkHistoryRepositoryError,
                .historyFileCorrupt
            )
        }

        XCTAssertEqual(try Data(contentsOf: storageURL), corruptBytes)
    }

    func testTruncatedHistoryFallsBackToEmptyButNextSavePreservesOriginalBytes()
        async throws
    {
        let valid = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try JSONEncoder().encode([valid])
        let truncatedBytes = Data(encoded.dropLast())
        try truncatedBytes.write(to: storageURL)
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)

        let truncatedHistory = await repository.load()
        XCTAssertTrue(truncatedHistory.isEmpty)
        do {
            try await repository.save(valid)
            XCTFail("截断的历史不得被新跑分静默覆盖")
        } catch {
            XCTAssertEqual(
                error as? MacBenchmarkHistoryRepositoryError,
                .historyFileCorrupt
            )
        }

        XCTAssertEqual(try Data(contentsOf: storageURL), truncatedBytes)
    }

    func testOversizedHistoryFallsBackToEmptyButNextSavePreservesOriginalBytes()
        async throws
    {
        let oversizedBytes = Data(
            repeating: 0x5A,
            count: Int(MacBenchmarkHistoryRepository.maximumFileBytes) + 1
        )
        try oversizedBytes.write(to: storageURL)
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)

        let oversizedHistory = await repository.load()
        XCTAssertTrue(oversizedHistory.isEmpty)
        let valid = makeResult(
            profile: .quick,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        do {
            try await repository.save(valid)
            XCTFail("超限的历史不得被新跑分静默覆盖")
        } catch {
            XCTAssertEqual(
                error as? MacBenchmarkHistoryRepositoryError,
                .historyFileTooLarge
            )
        }

        XCTAssertEqual(try Data(contentsOf: storageURL), oversizedBytes)
    }

    func testPersistedReportContainsNoDeviceUniqueOrPathFields() async throws {
        let repository = MacBenchmarkHistoryRepository(storageURL: storageURL)
        try await repository.save(
            makeResult(
                profile: .quick,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        let json = try XCTUnwrap(
            String(data: Data(contentsOf: storageURL), encoding: .utf8)
        ).lowercased()
        for forbiddenKey in [
            "username", "serialnumber", "hardwareuuid", "udid", "ipaddress",
            "filepath", "homepath"
        ] {
            XCTAssertFalse(json.contains(forbiddenKey), "历史不得包含字段：\(forbiddenKey)")
        }
    }

    private func assertRejectedSave(
        _ result: MacBenchmarkResult,
        repository: MacBenchmarkHistoryRepository,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await repository.save(result)
            XCTFail("篡改后的 scored result 不得进入历史", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? MacBenchmarkHistoryRepositoryError,
                .invalidResult,
                file: file,
                line: line
            )
        }
    }

    private func acquireRealSidecarLock() throws -> Int32 {
        let lockURL = storageURL.appendingPathExtension("lock")
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return descriptor
    }

    private func releaseRealSidecarLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    private func makeResult(
        profile: BenchmarkProfile,
        workloadVersion: String? = nil,
        startedAt: Date,
        includeScore: Bool = false,
        sampleBias: Double = 0
    ) -> MacBenchmarkResult {
        let resolvedWorkloadVersion: String
        if let workloadVersion {
            resolvedWorkloadVersion = workloadVersion
        } else {
            resolvedWorkloadVersion = switch profile {
            case .standard: "mac-benchmark-standard-v4"
            case .quick: "mac-benchmark-quick-v3"
            case .full: "mac-benchmark-full-v3"
            }
        }
        let sampleCount = profile == .full ? 5 : 3
        let measurements = BenchmarkComponent.allCases.map { component in
            BenchmarkComponentMeasurement(
                component: component,
                unit: component.metricUnit(for: profile),
                samples: (0..<sampleCount).map { index in
                    BenchmarkComponentSample(
                        value: [100.0, 101.0, 99.0][index % 3] + sampleBias,
                        elapsedSeconds: 1,
                        checksum: 42
                    )
                }
            )
        }
        let preflight = BenchmarkPreflight(
            capturedAt: startedAt,
            powerSource: .acPower,
            batteryPercent: 80,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 100_000_000_000,
            requiredDiskBytes: 3_000_000_000,
            warnings: []
        )
        let environment = BenchmarkEnvironmentMetadata(
            architecture: .arm64,
            chipName: "Apple Test",
            activeProcessorCount: 10,
            physicalMemoryBytes: 16_000_000_000,
            powerSource: .acPower,
            thermalState: .nominal,
            operatingSystemVersion: "26.0",
            appVersion: "1.5.0",
            appBuild: "1"
        )
        let raw = MacBenchmarkRawResult(
            profile: profile,
            workloadVersion: resolvedWorkloadVersion,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(5),
            environment: environment,
            preflight: preflight,
            postflight: BenchmarkPostflight(
                capturedAt: startedAt.addingTimeInterval(4.9),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 3_000_000_000,
                warnings: []
            ),
            capabilitySet: .all,
            measurements: measurements,
            failure: nil
        )
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "baseline-v1",
            profile: profile,
            architecture: .arm64,
            capabilitySet: .all
        )
        let scores = includeScore
            ? Dictionary(uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, 1_000.0) })
            : [:]
        return MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: includeScore ? key : nil,
            matchedBaselineKey: includeScore ? key : nil,
            componentScores: scores,
            proposedOverallScore: includeScore ? MacBenchmarkScoring.referenceTotalScore : nil
        )
    }

    private func archivedScoredResult(
        for raw: MacBenchmarkRawResult,
        processors: [MacBenchmarkResultProcessor]
    ) throws -> MacBenchmarkResult {
        var diagnostics: [String] = []
        let matches = processors.enumerated().compactMap {
            index, processor -> MacBenchmarkResult? in
            do {
                let processed = try processor.process(raw)
                guard processed.rawOnlyReason == nil else {
                    diagnostics.append("processor[\(index)]=\(processed.rawOnlyReason!)")
                    return nil
                }
                return processed.result
            } catch {
                diagnostics.append("processor[\(index)]=\(error)")
                return nil
            }
        }
        XCTAssertEqual(matches.count, 1, diagnostics.joined(separator: "; "))
        return try XCTUnwrap(matches.first)
    }

    private func makeTrustedProcessor(
        for raw: MacBenchmarkRawResult
    ) throws -> MacBenchmarkResultProcessor {
        let metrics = Dictionary(
            uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, 100.0) }
        )
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "baseline-v1",
            profile: raw.profile,
            architecture: raw.environment.architecture,
            capabilitySet: raw.capabilitySet
        )
        let frozenAt = Date(timeIntervalSince1970: 1_700_000_500)
        let report = MacBenchmarkCalibrationReport(
            schemaVersion: MacBenchmarkCalibrationReport.currentSchemaVersion,
            key: key,
            referenceMetrics: metrics,
            referenceHardware: "Apple Test reference",
            frozenAt: frozenAt,
            sourceRunSHA256s: [
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-a".utf8)),
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-b".utf8)),
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-c".utf8)),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reportData = try encoder.encode(report)
        let verified = try VerifiedMacBenchmarkBaseline(
            baseline: MacBenchmarkBaseline(
                comparisonKey: key,
                referenceMetrics: metrics,
                reportSHA256: MacBenchmarkBaselineVerification.sha256Hex(reportData),
                referenceHardware: report.referenceHardware,
                frozenAt: frozenAt
            ),
            calibrationReport: reportData
        )
        return MacBenchmarkResultProcessor(
            baselineCatalog: try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: "baseline-v1",
                verifiedBaselines: [verified]
            )
        )
    }
}
