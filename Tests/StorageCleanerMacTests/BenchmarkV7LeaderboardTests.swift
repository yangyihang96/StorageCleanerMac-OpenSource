import Foundation
import XCTest

@testable import StorageCleanerMac

@MainActor
final class BenchmarkV7LeaderboardTests: XCTestCase {
    func testDraftAcceptsAllConfidenceRatingsAndUsesRecordID() throws {
        let recordID = UUID()
        let high = try makeResult(recordID: recordID, confidence: .high)
        let medium = try makeResult(confidence: .medium)
        let low = try makeResult(confidence: .low)
        let missing = try makeResult(confidence: nil)

        XCTAssertTrue(high.isLegacyArchiveEligible)
        XCTAssertTrue(medium.isLegacyArchiveEligible)
        XCTAssertTrue(low.isLegacyArchiveEligible)
        XCTAssertFalse(missing.isLegacyArchiveEligible)
        XCTAssertEqual(
            try BenchmarkV7LeaderboardDraft.make(
                result: high,
                installationID: UUID(),
                displayName: "Anonymous Mac ABCD"
            ).submissionID,
            recordID
        )
        XCTAssertEqual(
            try BenchmarkV7LeaderboardDraft.make(
                result: low,
                installationID: UUID(),
                displayName: "Anonymous Mac ABCD"
            ).conditions.confidence,
            BenchmarkV7ConfidenceRating.low.rawValue
        )
        for result in [missing] {
            XCTAssertThrowsError(try BenchmarkV7LeaderboardDraft.make(
                result: result,
                installationID: UUID(),
                displayName: "Anonymous Mac ABCD"
            )) { error in
                XCTAssertEqual(
                    error as? BenchmarkV7LeaderboardEligibilityError,
                    .notRankingEligible
                )
            }
        }
    }

    func testSubmissionJSONUsesStrictPrivacyWhitelistAndCurrentCoreMetrics() throws {
        let recordID = UUID()
        let installationID = UUID()
        let result = try makeResult(recordID: recordID, confidence: .high)
        let submission = try BenchmarkV7LeaderboardDraft.make(
            result: result,
            installationID: installationID,
            displayName: "Anonymous Mac A1B2"
        ).submission()
        let data = try JSONEncoder().encode(submission)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), Set([
            "submissionId", "installationId", "displayName", "computerModel",
            "processorModel", "memoryGB", "architecture", "planVersion",
            "workloadVersion", "scoringVersion", "referenceSetVersion",
            "completedAt", "appVersion", "appBuild", "conditions", "metrics",
            "proposedScore",
        ]))
        XCTAssertEqual(object["submissionId"] as? String, recordID.uuidString.lowercased())
        XCTAssertEqual(
            object["installationId"] as? String,
            installationID.uuidString.lowercased()
        )
        XCTAssertEqual(object["computerModel"] as? String, "MacBook Pro")
        XCTAssertEqual(object["processorModel"] as? String, "Apple M5 Pro")
        XCTAssertEqual(object["memoryGB"] as? Int, 16)
        XCTAssertEqual(object["architecture"] as? String, "arm64")

        let metrics = try XCTUnwrap(object["metrics"] as? [String: Double])
        XCTAssertEqual(
            Set(metrics.keys),
            Set(BenchmarkV7LeaderboardConstants.requiredCoreMetricIDs)
        )
        XCTAssertEqual(metrics.count, 21)
        let conditions = try XCTUnwrap(object["conditions"] as? [String: Any])
        XCTAssertEqual(Set(conditions.keys), Set([
            "powerSource", "lowPowerModeEnabled", "thermalState", "confidence",
            "sustainedReachedTargetDuration",
        ]))
        XCTAssertEqual(conditions["powerSource"] as? String, "acPower")
        XCTAssertEqual(conditions["lowPowerModeEnabled"] as? Bool, false)
        XCTAssertEqual(conditions["thermalState"] as? String, "nominal")
        XCTAssertEqual(conditions["confidence"] as? String, "high")
        XCTAssertEqual(conditions["sustainedReachedTargetDuration"] as? Bool, true)

        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [
            "PRIVATE_COMPUTER_NAME", "PRIVATE_MODEL_IDENTIFIER", "PRIVATE_STORAGE_MODEL",
            "PRIVATE_OS_VERSION", "systemDiskCapacityBytes", "operatingSystemVersion",
            "hardwareProfile", "computerName", "storageModel", "modelIdentifier",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), "Unexpected private field: \(forbidden)")
        }
    }

    func testIdentityProviderPersistsRandomIDAndStableAnonymousName() throws {
        let suiteName = "BenchmarkV7LeaderboardTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = DefaultBenchmarkV7LeaderboardIdentityProvider(defaults: defaults)

        let id = first.installationID()
        let name = first.anonymousDisplayName()
        let second = DefaultBenchmarkV7LeaderboardIdentityProvider(defaults: defaults)

        XCTAssertEqual(second.installationID(), id)
        XCTAssertEqual(second.anonymousDisplayName(), name)
        XCTAssertTrue(name.hasSuffix(id.uuidString.prefix(4).uppercased()))
        XCTAssertTrue(name.hasPrefix("匿名 Mac ") || name.hasPrefix("Anonymous Mac "))
        XCTAssertFalse(name.localizedCaseInsensitiveContains("computer"))
        XCTAssertNil(defaults.string(forKey: "serialNumber"))
        XCTAssertNil(defaults.string(forKey: "hardwareUUID"))
    }

    func testStoreCannotUploadOrDowngradeWhileNewProtocolServerIsUnavailable() async throws {
        let service = RecordingBenchmarkV7LeaderboardService()
        let identity = FixtureBenchmarkV7LeaderboardIdentityProvider()
        let store = BenchmarkV7LeaderboardStore(
            service: service,
            identityProvider: identity
        )
        let low = try makeResult(score: 7_000)
        let high = try makeResult(score: 9_000)

        let initialSubmitCount = await service.submitCount()
        XCTAssertEqual(initialSubmitCount, 0)
        XCTAssertEqual(store.mutationState, .idle)

        await store.submitBest([low, high])

        let finalSubmitCount = await service.submitCount()
        let submittedScore = await service.lastSubmission()?.proposedScore
        let expectedEntryID = await service.lastExpectedEntryID()
        XCTAssertEqual(finalSubmitCount, 0)
        XCTAssertNil(submittedScore)
        XCTAssertNil(expectedEntryID)
        XCTAssertEqual(store.mutationState, .failed(.incompatibleResult))
        XCTAssertNil(store.lastSubmittedEntryID)

    }

    func testUnavailableNewProtocolPreservesLegacyRemovalIdentityWithoutSubmitting() async throws {
        let persisted = BenchmarkV7LeaderboardSubmittedIdentity(
            entryID: String(repeating: "c", count: 32),
            workloadVersion: BenchmarkV7LeaderboardConstants.currentVersions.workloadVersion
        )
        let service = RecordingBenchmarkV7LeaderboardService()
        let store = BenchmarkV7LeaderboardStore(
            service: service,
            identityProvider: FixtureBenchmarkV7LeaderboardIdentityProvider(
                submitted: persisted
            )
        )

        await store.submitBest([try makeResult(score: 9_000)])

        let expectedEntryID = await service.lastExpectedEntryID()
        XCTAssertNil(expectedEntryID)
        XCTAssertEqual(store.lastSubmittedEntryID, persisted.entryID)
        XCTAssertEqual(store.mutationState, .failed(.incompatibleResult))
    }

    func testStoreLoadsEveryPageWithoutReplacingEarlierEntries() async {
        let firstEntries = (1...50).map(Self.makeEntry)
        let lastEntry = Self.makeEntry(rank: 51)
        let service = RecordingBenchmarkV7LeaderboardService(
            pages: [
                1: Self.makePage(entries: firstEntries, page: 1, total: 51),
                2: Self.makePage(entries: [lastEntry], page: 2, total: 51),
            ]
        )
        let store = BenchmarkV7LeaderboardStore(
            service: service,
            identityProvider: FixtureBenchmarkV7LeaderboardIdentityProvider()
        )

        await store.loadFirst()
        XCTAssertEqual(store.entries.count, 50)
        XCTAssertTrue(store.hasMore)

        await store.loadMore()
        XCTAssertEqual(store.entries.count, 51)
        XCTAssertEqual(store.entries.last?.rank, 51)
        XCTAssertEqual(store.total, 51)
        XCTAssertFalse(store.hasMore)
        let requestedPages = await service.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2])
    }

    func testCachedRowsSurviveForcedRefreshFailureAndFailureRemainsVisible() async {
        let service = RecordingBenchmarkV7LeaderboardService(
            pages: [
                1: Self.makePage(
                    entries: [Self.makeEntry(rank: 1)],
                    page: 1,
                    total: 1
                ),
            ]
        )
        let store = BenchmarkV7LeaderboardStore(
            service: service,
            identityProvider: FixtureBenchmarkV7LeaderboardIdentityProvider()
        )
        await store.loadFirst()
        let cachedGeneratedAt = store.generatedAt
        await service.setLeaderboardError(.transport)

        await store.loadFirst(force: true)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.generatedAt, cachedGeneratedAt)
        XCTAssertEqual(store.loadState, .failed(.offline))
    }

    func testSixtySecondCacheAvoidsSecondNetworkRequest() async {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let service = RecordingBenchmarkV7LeaderboardService(
            pages: [1: Self.makePage(entries: [], page: 1, total: 0)]
        )
        let store = BenchmarkV7LeaderboardStore(
            service: service,
            identityProvider: FixtureBenchmarkV7LeaderboardIdentityProvider(),
            now: { now }
        )

        await store.loadFirst()
        now.addTimeInterval(59)
        await store.loadFirst()
        let cachedRequests = await service.requestedPages()
        XCTAssertEqual(cachedRequests, [1])

        now.addTimeInterval(2)
        await store.loadFirst()
        let refreshedRequests = await service.requestedPages()
        XCTAssertEqual(refreshedRequests, [1, 1])
    }

    func testRemovalUsesPersistedIdentityEvenWhenEntryIsNotLoaded() async {
        let submitted = BenchmarkV7LeaderboardSubmittedIdentity(
            entryID: String(repeating: "a", count: 32),
            workloadVersion: BenchmarkV7LeaderboardConstants.currentVersions.workloadVersion
        )
        let identity = FixtureBenchmarkV7LeaderboardIdentityProvider(submitted: submitted)
        let service = RecordingBenchmarkV7LeaderboardService(
            pages: [1: Self.makePage(entries: [], page: 1, total: 0)]
        )
        let store = BenchmarkV7LeaderboardStore(
            service: service,
            identityProvider: identity
        )
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.hasSubmittedEntry)

        await store.removeMyEntry()

        let removedWorkload = await service.lastRemoval()?.workloadVersion
        XCTAssertEqual(removedWorkload, submitted.workloadVersion)
        XCTAssertEqual(store.mutationState, .removed)
        XCTAssertNil(store.lastSubmittedEntryID)
        XCTAssertNil(identity.lastSubmittedIdentity())
    }

    func testServiceRejectsWrongSchemaAndCrossOriginResponse() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let pageData = try pageJSON(entries: [Self.makeEntry(rank: 1)], page: 1, total: 1)
        let wrongSchema = try BenchmarkV7LeaderboardService(
            endpoint: endpoint,
            transport: BenchmarkV7LeaderboardTransportStub(
                data: pageData,
                status: 200,
                schema: "1",
                responseURL: endpoint.appendingPathComponent("v2/leaderboard")
            )
        )
        await assertServiceError(.invalidResponse) {
            try await wrongSchema.leaderboard(page: 1, pageSize: 50)
        }

        let crossOrigin = try BenchmarkV7LeaderboardService(
            endpoint: endpoint,
            transport: BenchmarkV7LeaderboardTransportStub(
                data: pageData,
                status: 200,
                schema: "2",
                responseURL: try XCTUnwrap(URL(string: "https://evil.example/v2/leaderboard"))
            )
        )
        await assertServiceError(.invalidResponse) {
            try await crossOrigin.leaderboard(page: 1, pageSize: 50)
        }
    }

    func testServiceAcceptsUnchangedReceiptWithRetainedHighScoreRow() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let submission = try BenchmarkV7LeaderboardDraft.make(
            result: makeResult(score: 8_000),
            installationID: UUID(),
            displayName: "Anonymous Mac ABCD"
        ).submission()
        let retainedEntry = entry(
            for: submission,
            displayName: "Anonymous Mac OLD1",
            computerModel: "Mac Studio",
            processorModel: "Apple M4 Ultra",
            memoryGB: 64,
            score: 12_000,
            completedOn: "2026-07-01"
        )
        let service = try BenchmarkV7LeaderboardService(
            endpoint: endpoint,
            transport: BenchmarkV7LeaderboardTransportStub(
                data: try receiptJSON(entry: retainedEntry, disposition: "unchanged"),
                status: 200,
                schema: "2",
                responseURL: endpoint.appendingPathComponent("v2/submissions")
            )
        )

        let recoveryReceipt = try await service.submit(submission)
        XCTAssertEqual(recoveryReceipt.data.score, 12_000)
        let knownIdentityReceipt = try await service.submit(
            submission,
            expectedEntryID: retainedEntry.id
        )
        XCTAssertEqual(knownIdentityReceipt.disposition, .unchanged)
        XCTAssertEqual(knownIdentityReceipt.data.displayName, "Anonymous Mac OLD1")
    }

    func testServiceRejectsUnchangedReceiptWithDifferentExpectedEntryID() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let submission = try BenchmarkV7LeaderboardDraft.make(
            result: makeResult(score: 8_000),
            installationID: UUID(),
            displayName: "Anonymous Mac ABCD"
        ).submission()
        let retainedEntry = entry(for: submission, score: 12_000)
        let service = try BenchmarkV7LeaderboardService(
            endpoint: endpoint,
            transport: BenchmarkV7LeaderboardTransportStub(
                data: try receiptJSON(entry: retainedEntry, disposition: "unchanged"),
                status: 200,
                schema: "2",
                responseURL: endpoint.appendingPathComponent("v2/submissions")
            )
        )

        await assertServiceError(.invalidResponse) {
            try await service.submit(
                submission,
                expectedEntryID: String(repeating: "a", count: 32)
            )
        }
    }

    func testServiceRejectsUnchangedReceiptWithInvalidIDOrWrongWorkload() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let submission = try BenchmarkV7LeaderboardDraft.make(
            result: makeResult(score: 8_000),
            installationID: UUID(),
            displayName: "Anonymous Mac ABCD"
        ).submission()
        let invalidEntries = [
            entry(for: submission, id: String(repeating: "g", count: 32)),
            entry(for: submission, workloadVersion: "benchmark-v7-wrong"),
        ]

        for invalidEntry in invalidEntries {
            let service = try BenchmarkV7LeaderboardService(
                endpoint: endpoint,
                transport: BenchmarkV7LeaderboardTransportStub(
                    data: try receiptJSON(entry: invalidEntry, disposition: "unchanged"),
                    status: 200,
                    schema: "2",
                    responseURL: endpoint.appendingPathComponent("v2/submissions")
                )
            )
            await assertServiceError(.invalidResponse) {
                try await service.submit(submission)
            }
        }
    }

    func testServiceKeepsCreatedAndUpdatedReceiptsStrictlyAlignedToSubmission() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let submission = try BenchmarkV7LeaderboardDraft.make(
            result: makeResult(score: 8_000),
            installationID: UUID(),
            displayName: "Anonymous Mac ABCD"
        ).submission()

        for (disposition, status) in [("created", 201), ("updated", 200)] {
            let mismatchService = try BenchmarkV7LeaderboardService(
                endpoint: endpoint,
                transport: BenchmarkV7LeaderboardTransportStub(
                    data: try receiptJSON(
                        entry: entry(for: submission, computerModel: "Different Mac"),
                        disposition: disposition
                    ),
                    status: status,
                    schema: "2",
                    responseURL: endpoint.appendingPathComponent("v2/submissions")
                )
            )
            await assertServiceError(.invalidResponse) {
                try await mismatchService.submit(submission)
            }
        }
    }

    func testServiceAccepts2048GBAndRejects2049GB() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let baseline = try BenchmarkV7LeaderboardDraft.make(
            result: makeResult(),
            installationID: UUID(),
            displayName: "Anonymous Mac ABCD"
        ).submission()
        let accepted = replacingMemoryGB(in: baseline, with: 2_048)
        let acceptedData = try receiptJSON(
            entry: entry(for: accepted, computerModel: accepted.computerModel),
            disposition: "created"
        )
        let service = try BenchmarkV7LeaderboardService(
            endpoint: endpoint,
            transport: BenchmarkV7LeaderboardTransportStub(
                data: acceptedData,
                status: 201,
                schema: "2",
                responseURL: endpoint.appendingPathComponent("v2/submissions")
            )
        )

        let receipt = try await service.submit(accepted)
        XCTAssertEqual(receipt.data.memoryGB, 2_048)

        let rejected = replacingMemoryGB(in: baseline, with: 2_049)
        await assertServiceError(.rejected) {
            try await service.submit(rejected)
        }
    }

    func testServiceRejectsResponsesLargerThan512KiB() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let oversized = Data(
            repeating: 0,
            count: BenchmarkV7LeaderboardConstants.maximumResponseBytes + 1
        )
        let service = try BenchmarkV7LeaderboardService(
            endpoint: endpoint,
            transport: BenchmarkV7LeaderboardTransportStub(
                data: oversized,
                status: 200,
                schema: "2",
                responseURL: endpoint.appendingPathComponent("v2/leaderboard")
            )
        )

        await assertServiceError(.responseTooLarge) {
            try await service.leaderboard(page: 1, pageSize: 50)
        }
    }

    func testServiceRejectsUnexpectedPublicEntryFields() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let validData = try pageJSON(
            entries: [Self.makeEntry(rank: 1)],
            page: 1,
            total: 1
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        var entries = try XCTUnwrap(root["data"] as? [[String: Any]])
        entries[0]["computerName"] = "Private Mac Name"
        root["data"] = entries
        let leakedData = try JSONSerialization.data(withJSONObject: root)
        let service = try BenchmarkV7LeaderboardService(
            endpoint: endpoint,
            transport: BenchmarkV7LeaderboardTransportStub(
                data: leakedData,
                status: 200,
                schema: "2",
                responseURL: endpoint.appendingPathComponent("v2/leaderboard")
            )
        )

        await assertServiceError(.invalidResponse) {
            try await service.leaderboard(page: 1, pageSize: 50)
        }
    }

    func testServiceMapsBackendSubmissionConflictCodes() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let submission = try BenchmarkV7LeaderboardDraft.make(
            result: makeResult(),
            installationID: UUID(),
            displayName: "Anonymous Mac ABCD"
        ).submission()

        for code in ["submission_id_conflict", "submission_in_progress"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "error": ["code": code],
            ])
            let service = try BenchmarkV7LeaderboardService(
                endpoint: endpoint,
                transport: BenchmarkV7LeaderboardTransportStub(
                    data: data,
                    status: 409,
                    schema: "2",
                    responseURL: endpoint.appendingPathComponent("v2/submissions")
                )
            )

            await assertServiceError(.conflict) {
                try await service.submit(submission)
            }
        }
    }

    private func assertServiceError<T>(
        _ expected: BenchmarkV7LeaderboardServiceError,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? BenchmarkV7LeaderboardServiceError, expected)
        }
    }

    private func makeResult(
        recordID: UUID? = UUID(),
        score: Double = 8_000,
        confidence: BenchmarkV7ConfidenceRating? = .high
    ) throws -> BenchmarkV7Result {
        let official = OfficialBenchmarkPlan.legacyV9
        let completedAt = Date(timeIntervalSince1970: 1_785_521_846)
        let preflight = makePreflight()
        let environment = BenchmarkEnvironmentMetadata(
            architecture: .arm64,
            chipName: "Apple M5 Pro",
            activeProcessorCount: 12,
            physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
            systemDiskCapacityBytes: 999_999_999_999,
            powerSource: .acPower,
            thermalState: .nominal,
            operatingSystemVersion: "PRIVATE_OS_VERSION",
            appVersion: "1.9.9",
            appBuild: "202608050001"
        )
        let metrics = try BenchmarkV7LeaderboardConstants.requiredCoreMetricIDs
            .enumerated().map { offset, id in
                let category: BenchmarkV7Category = if id.hasPrefix("cpu.") {
                    .cpu
                } else if id.hasPrefix("gpu.") {
                    .gpu
                } else if id.hasPrefix("memory.") {
                    .memory
                } else {
                    .storage
                }
                let values = [100 + Double(offset), 101 + Double(offset), 102 + Double(offset)]
                let samples = values.enumerated().map { index, value in
                    BenchmarkV7RawSample(
                        value: value,
                        elapsedSeconds: 1,
                        wallElapsedSeconds: 1,
                        checksum: UInt64(index + 1)
                    )
                }
                return BenchmarkV7MetricResult(
                    manifest: BenchmarkV7MetricManifest(
                        id: id,
                        category: category,
                        unit: id.contains("latency") ? "ns" : "units",
                        direction: id.contains("latency") ? .lowerIsBetter : .higherIsBetter,
                        weight: 1,
                        workloadVersion: official.plan.workloadVersion
                    ),
                    samples: samples,
                    statistics: try BenchmarkStatistics.summarize(values)
                )
            }
        let categoryScores = Dictionary(
            uniqueKeysWithValues: BenchmarkV7Category.corePerformance.map {
                ($0, BenchmarkV7CategoryScore(ratio: score / 6_000, score: score))
            }
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
            hardwareProfile: BenchmarkV7HardwareProfile(
                computerName: "PRIVATE_COMPUTER_NAME",
                computerModel: "MacBook Pro",
                modelIdentifier: "PRIVATE_MODEL_IDENTIFIER",
                gpuCoreCount: 20,
                storageModel: "PRIVATE_STORAGE_MODEL"
            ),
            versions: BenchmarkV7LeaderboardConstants.currentVersions,
            metrics: metrics,
            coreScore: BenchmarkV7CoreScore(
                categoryScores: categoryScores,
                overallScore: score
            ),
            experienceScore: BenchmarkV7ExperienceScore(
                metricRatios: ["cpu.single.mixed": 1],
                overallScore: score
            ),
            sustainedResult: makeSustainedResult(
                environment: environment,
                completedAt: completedAt
            ),
            confidence: confidence.map {
                BenchmarkV7Confidence(
                    rating: $0,
                    maximumRelativeMAD: 0.01,
                    reasons: []
                )
            },
            completedAt: completedAt,
            failure: nil
        )
    }

    private func makePreflight() -> BenchmarkV7PreflightReport {
        BenchmarkV7PreflightReport(
            capturedAt: Date(timeIntervalSinceReferenceDate: 1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            backgroundLoadRatio: 0.01,
            availableMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
            storageTarget: BenchmarkV7StorageTarget(
                volumeName: "Fixture",
                fileSystem: "APFS",
                availableBytes: 64 * 1_024 * 1_024 * 1_024,
                isReadOnly: false
            ),
            displayDescription: "Fixture",
            checks: [],
            blockedCategories: []
        )
    }

    private func makeSustainedResult(
        environment: BenchmarkEnvironmentMetadata,
        completedAt: Date
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
        let windows: [MacSustainedBenchmarkWindow] = (0..<3).map { index in
            let offset = Double(index)
            let cpuSample = BenchmarkComponentSample(
                value: 100 - offset,
                elapsedSeconds: 1,
                checksum: 1
            )
            let gpuSample = BenchmarkComponentSample(
                value: 200 - offset,
                elapsedSeconds: 1,
                checksum: 2
            )
            return MacSustainedBenchmarkWindow(
                index: index,
                startedAtSeconds: Double(index * 2),
                completedAtSeconds: Double(index * 2 + 1),
                cpuMultiSample: cpuSample,
                gpuRasterSample: gpuSample
            )
        }
        return MacSustainedBenchmarkResult(
            profile: .standard,
            coolingMode: .systemAutomatic,
            targetDurationSeconds: 6,
            workloadDurationSeconds: 6,
            totalObservationDurationSeconds: 6,
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
                    elapsedSeconds: 6,
                    thermalState: .nominal,
                    powerSource: .acPower,
                    lowPowerModeEnabled: false,
                    chipTemperatureCelsius: 55,
                    fans: .unsupported
                ),
            ],
            termination: .targetDurationReached,
            cooldownReachedNominal: nil,
            failure: nil
        )
    }

    private static func makeEntry(rank: Int) -> BenchmarkV7LeaderboardEntry {
        BenchmarkV7LeaderboardEntry(
            id: String(format: "%032x", rank),
            rank: rank,
            displayName: "Anonymous Mac \(rank)",
            computerModel: "MacBook Pro",
            processorModel: "Apple M5 Pro",
            memoryGB: 16,
            score: Double(10_000 - rank),
            workloadVersion: BenchmarkV7LeaderboardConstants.currentVersions.workloadVersion,
            completedOn: "2026-08-05",
            confidence: "high"
        )
    }

    private static func makePage(
        entries: [BenchmarkV7LeaderboardEntry],
        page: Int,
        total: Int
    ) -> BenchmarkV7LeaderboardPage {
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        return BenchmarkV7LeaderboardPage(
            data: entries,
            pagination: BenchmarkV7LeaderboardPagination(
                page: page,
                pageSize: BenchmarkV7LeaderboardConstants.pageSize,
                total: total,
                totalPages: total == 0 ? 0 : (total + 49) / 50
            ),
            meta: BenchmarkV7LeaderboardMetadata(
                generatedAt: Date(timeIntervalSinceReferenceDate: 2_000),
                planVersion: versions.planVersion,
                workloadVersion: versions.workloadVersion,
                scoringVersion: versions.scoringVersion,
                referenceSetVersion: versions.referenceSetVersion
            )
        )
    }

    private func pageJSON(
        entries: [BenchmarkV7LeaderboardEntry],
        page: Int,
        total: Int
    ) throws -> Data {
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        let rows = entries.map(entryObject)
        return try JSONSerialization.data(withJSONObject: [
            "data": rows,
            "pagination": [
                "page": page,
                "pageSize": 50,
                "total": total,
                "totalPages": total == 0 ? 0 : (total + 49) / 50,
            ],
            "meta": [
                "generatedAt": "2026-08-05T00:00:00.000Z",
                "planVersion": versions.planVersion,
                "workloadVersion": versions.workloadVersion,
                "scoringVersion": versions.scoringVersion,
                "referenceSetVersion": versions.referenceSetVersion,
            ],
        ])
    }

    private func receiptJSON(
        entry: BenchmarkV7LeaderboardEntry,
        disposition: String
    ) throws -> Data {
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        return try JSONSerialization.data(withJSONObject: [
            "data": entryObject(entry),
            "disposition": disposition,
            "meta": [
                "submittedAt": "2026-08-05T00:00:00.000Z",
                "planVersion": versions.planVersion,
                "workloadVersion": versions.workloadVersion,
                "scoringVersion": versions.scoringVersion,
                "referenceSetVersion": versions.referenceSetVersion,
            ],
        ])
    }

    private func entryObject(_ entry: BenchmarkV7LeaderboardEntry) -> [String: Any] {
        [
            "id": entry.id,
            "rank": entry.rank,
            "displayName": entry.displayName,
            "computerModel": entry.computerModel,
            "processorModel": entry.processorModel,
            "memoryGB": entry.memoryGB,
            "score": entry.score,
            "workloadVersion": entry.workloadVersion,
            "completedOn": entry.completedOn,
            "confidence": entry.confidence ?? "high",
        ]
    }

    private func entry(
        for submission: BenchmarkV7LeaderboardSubmission,
        id: String = String(repeating: "b", count: 32),
        displayName: String? = nil,
        computerModel: String? = nil,
        processorModel: String? = nil,
        memoryGB: Int? = nil,
        score: Double? = nil,
        workloadVersion: String? = nil,
        completedOn: String? = nil,
        confidence: String? = nil
    ) -> BenchmarkV7LeaderboardEntry {
        BenchmarkV7LeaderboardEntry(
            id: id,
            rank: 1,
            displayName: displayName ?? submission.displayName,
            computerModel: computerModel ?? submission.computerModel,
            processorModel: processorModel ?? submission.processorModel,
            memoryGB: memoryGB ?? submission.memoryGB,
            score: score ?? submission.proposedScore,
            workloadVersion: workloadVersion ?? submission.workloadVersion,
            completedOn: completedOn ?? BenchmarkV7LeaderboardDateCodec.completedOn(
                from: MacBenchmarkLeaderboardDateCodec.date(from: submission.completedAt)!
            ),
            confidence: confidence ?? submission.conditions.confidence
        )
    }

    private func replacingMemoryGB(
        in submission: BenchmarkV7LeaderboardSubmission,
        with memoryGB: Int
    ) -> BenchmarkV7LeaderboardSubmission {
        BenchmarkV7LeaderboardSubmission(
            submissionId: submission.submissionId,
            installationId: submission.installationId,
            displayName: submission.displayName,
            computerModel: submission.computerModel,
            processorModel: submission.processorModel,
            memoryGB: memoryGB,
            architecture: submission.architecture,
            planVersion: submission.planVersion,
            workloadVersion: submission.workloadVersion,
            scoringVersion: submission.scoringVersion,
            referenceSetVersion: submission.referenceSetVersion,
            completedAt: submission.completedAt,
            appVersion: submission.appVersion,
            appBuild: submission.appBuild,
            conditions: submission.conditions,
            metrics: submission.metrics,
            proposedScore: submission.proposedScore
        )
    }
}

@MainActor
private final class FixtureBenchmarkV7LeaderboardIdentityProvider:
    BenchmarkV7LeaderboardIdentityProviding
{
    private let id = UUID(uuidString: "123e4567-e89b-42d3-a456-426614174001")!
    private var submitted: BenchmarkV7LeaderboardSubmittedIdentity?

    init(submitted: BenchmarkV7LeaderboardSubmittedIdentity? = nil) {
        self.submitted = submitted
    }

    func installationID() -> UUID { id }
    func anonymousDisplayName() -> String { "Anonymous Mac 123E" }
    func remember(_ identity: BenchmarkV7LeaderboardSubmittedIdentity) { submitted = identity }
    func forgetSubmittedEntry() { submitted = nil }
    func lastSubmittedIdentity() -> BenchmarkV7LeaderboardSubmittedIdentity? { submitted }
}

private actor RecordingBenchmarkV7LeaderboardService: BenchmarkV7LeaderboardServicing {
    let isConfigured = true
    private var pages: [Int: BenchmarkV7LeaderboardPage]
    private var leaderboardError: BenchmarkV7LeaderboardServiceError?
    private var submissions: [BenchmarkV7LeaderboardSubmission] = []
    private var expectedEntryIDs: [String?] = []
    private var removals: [BenchmarkV7LeaderboardRemoval] = []
    private var pageRequests: [Int] = []

    init(pages: [Int: BenchmarkV7LeaderboardPage] = [:]) {
        self.pages = pages
    }

    func leaderboard(page: Int, pageSize _: Int) async throws -> BenchmarkV7LeaderboardPage {
        pageRequests.append(page)
        if let leaderboardError { throw leaderboardError }
        if let page = pages[page] { return page }
        let entries = submissions.last.map { [entry(from: $0)] } ?? []
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        return BenchmarkV7LeaderboardPage(
            data: entries,
            pagination: BenchmarkV7LeaderboardPagination(
                page: 1,
                pageSize: BenchmarkV7LeaderboardConstants.pageSize,
                total: entries.count,
                totalPages: entries.isEmpty ? 0 : 1
            ),
            meta: BenchmarkV7LeaderboardMetadata(
                generatedAt: Date(timeIntervalSinceReferenceDate: 2_000),
                planVersion: versions.planVersion,
                workloadVersion: versions.workloadVersion,
                scoringVersion: versions.scoringVersion,
                referenceSetVersion: versions.referenceSetVersion
            )
        )
    }

    func submit(
        _ submission: BenchmarkV7LeaderboardSubmission,
        expectedEntryID: String?
    ) async throws -> BenchmarkV7LeaderboardReceipt {
        submissions.append(submission)
        expectedEntryIDs.append(expectedEntryID)
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        return BenchmarkV7LeaderboardReceipt(
            data: entry(from: submission),
            disposition: .created,
            meta: BenchmarkV7LeaderboardReceiptMetadata(
                submittedAt: Date(timeIntervalSinceReferenceDate: 2_000),
                planVersion: versions.planVersion,
                workloadVersion: versions.workloadVersion,
                scoringVersion: versions.scoringVersion,
                referenceSetVersion: versions.referenceSetVersion
            )
        )
    }

    func remove(
        _ removal: BenchmarkV7LeaderboardRemoval
    ) async throws -> BenchmarkV7LeaderboardRemovalReceipt {
        removals.append(removal)
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        return BenchmarkV7LeaderboardRemovalReceipt(
            data: .init(deleted: true),
            meta: .init(
                deletedAt: Date(timeIntervalSinceReferenceDate: 2_000),
                planVersion: versions.planVersion,
                workloadVersion: versions.workloadVersion,
                scoringVersion: versions.scoringVersion,
                referenceSetVersion: versions.referenceSetVersion
            )
        )
    }

    func setLeaderboardError(_ error: BenchmarkV7LeaderboardServiceError?) {
        leaderboardError = error
    }

    func submitCount() -> Int { submissions.count }
    func lastSubmission() -> BenchmarkV7LeaderboardSubmission? { submissions.last }
    func lastExpectedEntryID() -> String? { expectedEntryIDs.last ?? nil }
    func lastRemoval() -> BenchmarkV7LeaderboardRemoval? { removals.last }
    func requestedPages() -> [Int] { pageRequests }

    private func entry(
        from submission: BenchmarkV7LeaderboardSubmission
    ) -> BenchmarkV7LeaderboardEntry {
        BenchmarkV7LeaderboardEntry(
            id: String(repeating: "c", count: 32),
            rank: 1,
            displayName: submission.displayName,
            computerModel: submission.computerModel,
            processorModel: submission.processorModel,
            memoryGB: submission.memoryGB,
            score: submission.proposedScore,
            workloadVersion: submission.workloadVersion,
            completedOn: BenchmarkV7LeaderboardDateCodec.completedOn(
                from: MacBenchmarkLeaderboardDateCodec.date(from: submission.completedAt)!
            ),
            confidence: submission.conditions.confidence
        )
    }
}

private actor BenchmarkV7LeaderboardTransportStub: MacBenchmarkLeaderboardTransporting {
    let data: Data
    let status: Int
    let schema: String
    let responseURL: URL

    init(data: Data, status: Int, schema: String, responseURL: URL) {
        self.data = data
        self.status = status
        self.schema = schema
        self.responseURL = responseURL
    }

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: status,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json; charset=utf-8",
                "X-Leaderboard-Schema": schema,
            ]
        )!
        return (data, response)
    }
}
