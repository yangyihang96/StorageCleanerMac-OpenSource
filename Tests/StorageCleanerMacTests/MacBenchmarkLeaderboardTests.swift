import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkLeaderboardTests: XCTestCase {
    func testUploadDraftUsesCurrentFrozenV6ResultAndExcludesHardwareIdentifiers() throws {
        let result = makeScoredResult()
        let installationID = try XCTUnwrap(
            UUID(uuidString: "123e4567-e89b-42d3-a456-426614174001")
        )
        let draft = try MacBenchmarkLeaderboardUploadDraft.make(
            result: result,
            installationID: installationID,
            defaultDisplayName: "  工作室\nMac  ",
            now: fixtureNow
        )
        let submission = try draft.submission(displayName: draft.defaultDisplayName)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(submission))
                as? [String: Any]
        )
        let metricsObject = try XCTUnwrap(object["metrics"] as? [String: Any])
        let stabilityObject = try XCTUnwrap(
            metricsObject["stability"] as? [String: Any]
        )

        XCTAssertEqual(submission.displayName, "工作室 Mac")
        XCTAssertEqual(submission.processorModel, "Apple M5 Pro")
        XCTAssertEqual(submission.profile, .standard)
        XCTAssertEqual(
            submission.workloadVersion,
            MacBenchmarkLeaderboardConstants.standardWorkloadVersion
        )
        XCTAssertEqual(
            submission.baselineVersion,
            MacBenchmarkLeaderboardConstants.activeBaselineVersion
        )
        XCTAssertEqual(submission.proposedScore, 6_000, accuracy: 0.000_001)
        XCTAssertEqual(submission.metrics.cpuSingle, 100)
        XCTAssertEqual(submission.metrics.physicalMemoryBytes, 51_539_607_552)
        XCTAssertEqual(submission.metrics.systemDiskCapacityBytes, 994_610_155_520)
        XCTAssertEqual(submission.metrics.stability?.cpuSingle.sampleCount, 3)
        XCTAssertEqual(
            try XCTUnwrap(
                submission.metrics.stability?.cpuSingle.coefficientOfVariation
            ),
            0.01,
            accuracy: 0.000_000_1
        )
        for component in [
            "cpuSingle", "cpuMulti", "gpu", "memory", "diskRead", "diskWrite",
        ] {
            let evidence = try XCTUnwrap(
                stabilityObject[component] as? [String: Any]
            )
            XCTAssertEqual(evidence["sampleCount"] as? Int, 3)
            XCTAssertEqual(
                try XCTUnwrap(evidence["coefficientOfVariation"] as? Double),
                0.01,
                accuracy: 0.000_000_1
            )
        }
        XCTAssertNil(object["serialNumber"])
        XCTAssertNil(object["hardwareUUID"])
        XCTAssertNil(object["macAddress"])
        XCTAssertNil(object["ipAddress"])
        XCTAssertNil(object["accountName"])
    }

    func testUploadDraftRejectsMismatchedAndStaleResults() throws {
        let result = makeScoredResult()
        let raw = try XCTUnwrap(result.rawResult)
        let wrongKey = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "m5-pro-2026-07-v1",
            profile: raw.profile,
            architecture: .arm64,
            capabilitySet: .all
        )
        let mismatched = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: wrongKey,
            matchedBaselineKey: wrongKey,
            componentScores: result.componentScores,
            proposedOverallScore: 6_000
        )
        XCTAssertThrowsError(try MacBenchmarkLeaderboardUploadDraft.make(
            result: mismatched,
            installationID: UUID(),
            defaultDisplayName: "测试 Mac",
            now: fixtureNow
        )) { error in
            XCTAssertEqual(
                error as? MacBenchmarkLeaderboardEligibilityError,
                .comparisonKeyMismatch
            )
        }

        XCTAssertThrowsError(try MacBenchmarkLeaderboardUploadDraft.make(
            result: result,
            installationID: UUID(),
            defaultDisplayName: "测试 Mac",
            now: fixtureNow.addingTimeInterval(31 * 24 * 60 * 60)
        )) { error in
            XCTAssertEqual(
                error as? MacBenchmarkLeaderboardEligibilityError,
                .resultTooOld
            )
        }
    }

    func testFrozenV6ResultCanCreateAutomaticUploadDraftAfterActivation() throws {
        let frozenV6 = makeScoredResult(
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            baselineVersion: "m5-pro-2026-07-v6"
        )

        let draft = try MacBenchmarkLeaderboardUploadDraft.make(
            result: frozenV6,
            installationID: UUID(),
            defaultDisplayName: "测试 Mac",
            now: fixtureNow
        )

        XCTAssertEqual(draft.workloadVersion, MacBenchmarkLeaderboardConstants.standardWorkloadVersion)
        XCTAssertEqual(draft.baselineVersion, MacBenchmarkLeaderboardConstants.activeBaselineVersion)
        XCTAssertEqual(draft.defaultDisplayName, "测试 Mac")
    }

    func testUploadDraftRejectsLegacyProfilesOutsideThePublicV6Contract() throws {
        for profile in BenchmarkProfile.legacyCases {
            let result = makeScoredResult(
                workloadVersion: MacBenchmarkLeaderboardConstants.workloadVersion(
                    for: profile
                ),
                baselineVersion: MacBenchmarkLeaderboardConstants.baselineVersion(
                    for: profile
                ),
                profile: profile,
                appVersion: "1.6.1",
                systemDiskCapacityBytes: nil
            )
            XCTAssertThrowsError(try MacBenchmarkLeaderboardUploadDraft.make(
                result: result,
                installationID: UUID(),
                defaultDisplayName: "Legacy Mac",
                now: fixtureNow
            )) { error in
                XCTAssertEqual(
                    error as? MacBenchmarkLeaderboardEligibilityError,
                    .comparisonKeyMismatch
                )
            }
        }
    }

    func testPublicNameNormalizationIsBoundedAndRemovesControls() {
        let normalized = MacBenchmarkLeaderboardText.normalized(
            "  我的\nMac\u{0000}  " + String(repeating: "机", count: 80)
        )
        XCTAssertTrue(MacBenchmarkLeaderboardText.isValid(normalized))
        XCTAssertLessThanOrEqual(normalized.count, 40)
        XCTAssertLessThanOrEqual(normalized.utf8.count, 120)
        XCTAssertFalse(normalized.unicodeScalars.contains("\u{0000}"))
    }

    func testLeaderboardUISourceUsesAdaptiveCapacityFieldsAndSharedScoreColumns() throws {
        let source = try sourceText(
            "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkLeaderboardSection.swift"
        )

        XCTAssertTrue(source.contains("private enum TableLayout"))
        XCTAssertTrue(source.contains("TableLayout.rankWidth"))
        XCTAssertTrue(source.contains("TableLayout.scoreWidth"))
        XCTAssertTrue(source.contains("LazyVGrid("))
        XCTAssertTrue(source.contains("GridItem(.adaptive(minimum: 150)"))
        XCTAssertTrue(source.contains("entry.processorModel"))
        XCTAssertTrue(source.contains("entry.physicalMemoryBytes"))
        XCTAssertTrue(source.contains("entry.systemDiskCapacityBytes"))
        XCTAssertTrue(source.contains("MacBenchmarkPresentation.standardLeaderboardScoreTitle"))
        XCTAssertTrue(source.contains("fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(source.contains(".lineLimit(1)"))
        XCTAssertFalse(source.contains("width: 190"))
        XCTAssertFalse(source.contains("width: 80"))
        XCTAssertFalse(source.contains("width: 125"))
        XCTAssertFalse(source.contains("L10n.text(\"模式\", \"Profile\")"))
    }

    func testV7LeaderboardSectionDoesNotLabelLowConfidenceEntries() throws {
        let source = try sourceText(
            "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift"
        )

        XCTAssertFalse(source.contains("低置信度"))
        XCTAssertFalse(source.contains("Low confidence"))
        XCTAssertFalse(source.contains("entry.confidence == \"low\""))
    }

    func testServiceDecodesOnlyMatchingLeaderboardContract() async throws {
        let response = """
        {
          "data": [{
            "id": "a35101d3a7a72240ea765e2d6030bab7",
            "rank": 1,
            "displayName": "测试 Mac",
            "processorModel": "Apple M5 Pro",
            "score": 6000,
            "profile": "standard",
            "workloadVersion": "mac-benchmark-standard-v6",
            "physicalMemoryBytes": 51539607552,
            "systemDiskCapacityBytes": 994610155520,
            "completedAt": "2026-07-17T03:55:00.000Z"
          }],
          "pagination": {"page": 1, "pageSize": 50, "total": 1, "totalPages": 1},
          "meta": {
            "baselineVersion": "m5-pro-2026-07-v6",
            "profile": "standard",
            "workloadVersion": "mac-benchmark-standard-v6",
            "generatedAt": "2026-07-17T03:56:00.000Z"
          }
        }
        """
        let transport = LeaderboardTransportStub(
            data: Data(response.utf8),
            status: 200
        )
        let service = try MacBenchmarkLeaderboardService(
            endpoint: try XCTUnwrap(URL(string: "https://leaderboard.example")),
            transport: transport
        )

        let page = try await service.leaderboard(profile: .standard)
        XCTAssertEqual(page.data.map(\.displayName), ["测试 Mac"])
        XCTAssertEqual(page.data.first?.processorModel, "Apple M5 Pro")
        XCTAssertEqual(page.data.first?.score, 6_000)
        XCTAssertEqual(page.data.first?.physicalMemoryBytes, 51_539_607_552)
        XCTAssertEqual(page.data.first?.systemDiskCapacityBytes, 994_610_155_520)
        XCTAssertEqual(
            page.data.first?.completedAt,
            MacBenchmarkLeaderboardDateCodec.date(
                from: "2026-07-17T03:55:00.000Z"
            )
        )
        XCTAssertEqual(page.pagination.total, 1)
        let request = await transport.lastRequest()
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(
            request?.url?.query,
            "profile=standard&workloadVersion=mac-benchmark-standard-v6&page=1&pageSize=50"
        )
    }

    func testServiceRejectsV6LeaderboardEntryWithoutCapacityFields() async throws {
        let response = """
        {
          "data": [{
            "id": "a35101d3a7a72240ea765e2d6030bab7",
            "rank": 1,
            "displayName": "测试 Mac",
            "processorModel": "Apple M5 Pro",
            "score": 6000,
            "profile": "standard",
            "workloadVersion": "mac-benchmark-standard-v6",
            "completedAt": "2026-07-17T03:55:00.000Z"
          }],
          "pagination": {"page": 1, "pageSize": 50, "total": 1, "totalPages": 1},
          "meta": {
            "baselineVersion": "m5-pro-2026-07-v6",
            "profile": "standard",
            "workloadVersion": "mac-benchmark-standard-v6",
            "generatedAt": "2026-07-17T03:56:00.000Z"
          }
        }
        """
        let service = try MacBenchmarkLeaderboardService(
            endpoint: try XCTUnwrap(URL(string: "https://leaderboard.example")),
            transport: LeaderboardTransportStub(
                data: Data(response.utf8),
                status: 200
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await service.leaderboard(profile: .standard),
            equals: MacBenchmarkLeaderboardServiceError.invalidResponse
        )
    }

    func testServiceRejectsLegacyProfilesBeforeNetworkAccess() async throws {
        for profile in BenchmarkProfile.legacyCases {
            let transport = LeaderboardTransportStub(
                data: Data("{}".utf8),
                status: 200
            )
            let service = try MacBenchmarkLeaderboardService(
                endpoint: try XCTUnwrap(URL(string: "https://leaderboard.example")),
                transport: transport
            )

            await XCTAssertThrowsErrorAsync(
                try await service.leaderboard(profile: profile),
                equals: MacBenchmarkLeaderboardServiceError.rejected
            )
            let request = await transport.lastRequest()
            XCTAssertNil(request)
        }
    }

    func testServiceValidatesCapacityFieldsInSubmissionReceipt() async throws {
        let submission = try makeSubmission()
        let response = """
        {
          "data": {
            "id": "a35101d3a7a72240ea765e2d6030bab7",
            "rank": 1,
            "displayName": "测试 Mac",
            "processorModel": "Apple M5 Pro",
            "score": 6000,
            "profile": "standard",
            "workloadVersion": "mac-benchmark-standard-v6",
            "physicalMemoryBytes": 51539607552,
            "systemDiskCapacityBytes": 994610155520,
            "completedAt": "\(submission.completedAt)"
          },
          "disposition": "created"
        }
        """
        let service = try MacBenchmarkLeaderboardService(
            endpoint: try XCTUnwrap(URL(string: "https://leaderboard.example")),
            transport: LeaderboardTransportStub(
                data: Data(response.utf8),
                status: 201
            )
        )

        let receipt = try await service.submit(submission)

        XCTAssertEqual(receipt.data.physicalMemoryBytes, 51_539_607_552)
        XCTAssertEqual(receipt.data.systemDiskCapacityBytes, 994_610_155_520)
    }

    func testServiceRejectsWrongSchemaAndMapsRateLimit() async throws {
        let wrongSchema = LeaderboardTransportStub(
            data: Data("{}".utf8),
            status: 200,
            schema: "2"
        )
        let endpoint = try XCTUnwrap(URL(string: "https://leaderboard.example"))
        let invalidService = try MacBenchmarkLeaderboardService(
            endpoint: endpoint,
            transport: wrongSchema
        )
        await XCTAssertThrowsErrorAsync(
            try await invalidService.leaderboard(profile: .standard),
            equals: MacBenchmarkLeaderboardServiceError.invalidResponse
        )

        let limited = LeaderboardTransportStub(
            data: Data(#"{"error":{"code":"rate_limited","message":"later"}}"#.utf8),
            status: 429
        )
        let limitedService = try MacBenchmarkLeaderboardService(
            endpoint: endpoint,
            transport: limited
        )
        let submission = try makeSubmission()
        await XCTAssertThrowsErrorAsync(
            try await limitedService.submit(submission),
            equals: MacBenchmarkLeaderboardServiceError.rateLimited
        )
    }

    func testServiceRemovalUsesPrivateInstallationIDAndValidatesReceipt() async throws {
        let transport = LeaderboardTransportStub(
            data: Data(#"{"data":{"deleted":true}}"#.utf8),
            status: 200
        )
        let service = try MacBenchmarkLeaderboardService(
            endpoint: try XCTUnwrap(URL(string: "https://leaderboard.example")),
            transport: transport
        )
        let removal = MacBenchmarkLeaderboardRemoval(
            installationId: "123e4567-e89b-42d3-a456-426614174001",
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v4"
        )

        let receipt = try await service.remove(removal)
        XCTAssertTrue(receipt.data.deleted)
        let request = await transport.lastRequest()
        XCTAssertEqual(request?.httpMethod, "DELETE")
        let body = try XCTUnwrap(request?.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["installationId"] as? String, removal.installationId)
        XCTAssertNil(object["displayName"])
        XCTAssertNil(object["processorModel"])
    }

    func testServiceRemovalRejectsUnconfirmedReceipt() async throws {
        let transport = LeaderboardTransportStub(
            data: Data(#"{"data":{"deleted":false}}"#.utf8),
            status: 200
        )
        let service = try MacBenchmarkLeaderboardService(
            endpoint: try XCTUnwrap(URL(string: "https://leaderboard.example")),
            transport: transport
        )
        let removal = MacBenchmarkLeaderboardRemoval(
            installationId: "123e4567-e89b-42d3-a456-426614174001",
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v4"
        )

        await XCTAssertThrowsErrorAsync(
            try await service.remove(removal),
            equals: MacBenchmarkLeaderboardServiceError.removalNotConfirmed
        )
    }

    @MainActor
    func testStoreIgnoresStaleProfileResponse() async throws {
        let service = DelayedLeaderboardService()
        let identity = FixtureLeaderboardIdentityProvider()
        let store = MacBenchmarkLeaderboardStore(
            service: service,
            identityProvider: identity
        )

        let quick = Task { await store.load(profile: .quick, force: true) }
        try await Task.sleep(for: .milliseconds(10))
        let full = Task { await store.load(profile: .full, force: true) }
        await full.value
        await quick.value

        XCTAssertEqual(store.loadedProfile, .full)
        XCTAssertEqual(store.entries.map(\.profile), [.full])
        XCTAssertEqual(store.entries.map(\.displayName), ["Full Mac"])
    }

    @MainActor
    func testStoreDoesNotDescribeLeaderboardLoadRejectionAsScoreRejection() async {
        let store = MacBenchmarkLeaderboardStore(
            service: FailingLeaderboardService(error: .rejected),
            identityProvider: FixtureLeaderboardIdentityProvider()
        )

        await store.load(profile: .standard, force: true)

        XCTAssertEqual(store.loadState, .failed(.unavailable))
        XCTAssertNotEqual(
            MacBenchmarkLeaderboardFailure.unavailable.message,
            MacBenchmarkLeaderboardFailure.rejected.message
        )
    }

    @MainActor
    func testAutomaticUploadUsesSuggestedComputerNameAndRefreshesLeaderboard() async {
        let service = RecordingAutomaticLeaderboardService()
        let store = MacBenchmarkLeaderboardStore(
            service: service,
            identityProvider: FixtureLeaderboardIdentityProvider()
        )

        await store.submitBestAutomatically([makeScoredResult(now: Date())])

        let submission = await service.lastSubmission()
        XCTAssertEqual(submission?.displayName, "Fixture Mac")
        XCTAssertEqual(submission?.processorModel, "Apple M5 Pro")
        XCTAssertEqual(submission?.metrics.physicalMemoryBytes, 51_539_607_552)
        XCTAssertEqual(
            submission?.metrics.systemDiskCapacityBytes,
            994_610_155_520
        )
        XCTAssertEqual(store.entries.map(\.displayName), ["Fixture Mac"])
        XCTAssertEqual(store.entries.first?.physicalMemoryBytes, 51_539_607_552)
        XCTAssertEqual(
            store.entries.first?.systemDiskCapacityBytes,
            994_610_155_520
        )
        XCTAssertEqual(store.totalEntryCount, 1)
        guard case .succeeded = store.uploadState else {
            return XCTFail("有效成绩应自动上传并刷新排行榜")
        }
    }

    @MainActor
    func testAutomaticUploadUsesHighestEligibleHistoryResult() async {
        let service = RecordingAutomaticLeaderboardService()
        let store = MacBenchmarkLeaderboardStore(
            service: service,
            identityProvider: FixtureLeaderboardIdentityProvider()
        )
        let now = Date()

        await store.submitBestAutomatically([
            makeScoredResult(score: 5_800, now: now),
            makeScoredResult(score: 6_400, now: now),
            makeScoredResult(score: 6_100, now: now),
        ])

        let submission = await service.lastSubmission()
        XCTAssertEqual(submission?.proposedScore, 6_400)
    }

    @MainActor
    func testIdentityProviderPersistsRandomInstallationIDWithoutHardwareData() throws {
        let suiteName = "MacBenchmarkLeaderboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = DefaultMacBenchmarkLeaderboardIdentityProvider(defaults: defaults)

        let first = provider.installationID()
        let second = provider.installationID()
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            defaults.string(forKey: "benchmarkLeaderboard.installationID.v1"),
            first.uuidString.lowercased()
        )
        XCTAssertNil(defaults.string(forKey: "serialNumber"))
        XCTAssertNil(defaults.string(forKey: "hardwareUUID"))
    }

    @MainActor
    func testIdentityProviderUsesCurrentComputerNameBeforeSavedDisplayName() throws {
        let suiteName = "MacBenchmarkLeaderboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "旧电脑名称",
            forKey: "benchmarkLeaderboard.displayName.v1"
        )
        let provider = DefaultMacBenchmarkLeaderboardIdentityProvider(
            defaults: defaults,
            computerNameProvider: { "工作室 Mac" },
            hostNameProvider: { "Host Fallback" }
        )

        XCTAssertEqual(provider.suggestedDisplayName(), "工作室 Mac")
    }
}

private extension MacBenchmarkLeaderboardTests {
    var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    var fixtureNow: Date {
        Date(timeIntervalSince1970: 1_752_727_200)
    }

    func makeSubmission() throws -> MacBenchmarkLeaderboardSubmission {
        let draft = try MacBenchmarkLeaderboardUploadDraft.make(
            result: makeScoredResult(),
            installationID: try XCTUnwrap(
                UUID(uuidString: "123e4567-e89b-42d3-a456-426614174001")
            ),
            defaultDisplayName: "测试 Mac",
            now: fixtureNow
        )
        return try draft.submission(displayName: draft.defaultDisplayName)
    }

    func makeScoredResult(
        workloadVersion: String = MacBenchmarkLeaderboardConstants.standardWorkloadVersion,
        baselineVersion: String = MacBenchmarkLeaderboardConstants.activeBaselineVersion,
        profile: BenchmarkProfile = .standard,
        appVersion: String = MacBenchmarkLeaderboardConstants.minimumSourceAppVersion,
        systemDiskCapacityBytes: UInt64? = 994_610_155_520,
        score: Double = 6_000,
        now: Date? = nil
    ) -> MacBenchmarkResult {
        let resultNow = now ?? fixtureNow
        let startedAt = resultNow.addingTimeInterval(-60)
        let completedAt = resultNow.addingTimeInterval(-10)
        let components = BenchmarkComponent.allCases.map { component in
            BenchmarkComponentMeasurement(
                component: component,
                unit: component.metricUnit(for: profile),
                samples: [99, 100, 101].enumerated().map { index, value in
                    BenchmarkComponentSample(
                        value: Double(value),
                        elapsedSeconds: 1 + Double(index) * 0.1,
                        checksum: UInt64(index + 1)
                    )
                }
            )
        }
        let raw = MacBenchmarkRawResult(
            profile: profile,
            workloadVersion: workloadVersion,
            startedAt: startedAt,
            completedAt: completedAt,
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: "Apple M5 Pro",
                activeProcessorCount: 18,
                physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024,
                systemDiskCapacityBytes: systemDiskCapacityBytes,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS 26.5",
                appVersion: appVersion,
                appBuild: "202607172016"
            ),
            preflight: BenchmarkPreflight(
                capturedAt: startedAt.addingTimeInterval(1),
                powerSource: .acPower,
                batteryPercent: 100,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 1_000_000,
                warnings: []
            ),
            postflight: BenchmarkPostflight(
                capturedAt: completedAt.addingTimeInterval(-1),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 1_000_000,
                warnings: []
            ),
            capabilitySet: .all,
            measurements: components,
            failure: nil
        )
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: baselineVersion,
            profile: profile,
            architecture: .arm64,
            capabilitySet: .all
        )
        let scores = Dictionary(uniqueKeysWithValues: BenchmarkComponent.allCases.map {
            ($0, score / Double(BenchmarkComponent.allCases.count))
        })
        return MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: scores,
            proposedOverallScore: score
        )
    }
}

private actor LeaderboardTransportStub: MacBenchmarkLeaderboardTransporting {
    private let data: Data
    private let status: Int
    private let schema: String
    private var request: URLRequest?

    init(data: Data, status: Int, schema: String = "1") {
        self.data = data
        self.status = status
        self.schema = schema
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json; charset=utf-8",
                "X-Leaderboard-Schema": schema,
            ]
        )!
        return (data, response)
    }

    func lastRequest() -> URLRequest? { request }
}

private actor DelayedLeaderboardService: MacBenchmarkLeaderboardServicing {
    nonisolated let isConfigured = true

    func leaderboard(profile: BenchmarkProfile) async throws -> MacBenchmarkLeaderboardPage {
        if profile == .quick {
            try await Task.sleep(for: .milliseconds(80))
        }
        let workload = MacBenchmarkLeaderboardConstants.workloadVersion(for: profile)
        let entry = MacBenchmarkLeaderboardEntry(
            id: profile == .quick
                ? "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                : "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            rank: 1,
            displayName: profile == .quick ? "Quick Mac" : "Full Mac",
            processorModel: "Apple M5 Pro",
            score: 6_000,
            profile: profile,
            workloadVersion: workload,
            completedAt: Date(timeIntervalSince1970: 1_752_727_190)
        )
        return MacBenchmarkLeaderboardPage(
            data: [entry],
            pagination: MacBenchmarkLeaderboardPagination(
                page: 1,
                pageSize: 50,
                total: 1,
                totalPages: 1
            ),
            meta: MacBenchmarkLeaderboardMetadata(
                baselineVersion: MacBenchmarkLeaderboardConstants.baselineVersion(
                    for: profile
                ),
                profile: profile,
                workloadVersion: workload,
                generatedAt: Date()
            )
        )
    }

    func submit(
        _: MacBenchmarkLeaderboardSubmission
    ) async throws -> MacBenchmarkLeaderboardSubmissionReceipt {
        throw MacBenchmarkLeaderboardServiceError.unavailable
    }

    func remove(_: MacBenchmarkLeaderboardRemoval) async throws
        -> MacBenchmarkLeaderboardRemovalReceipt
    {
        throw MacBenchmarkLeaderboardServiceError.unavailable
    }
}

private actor RecordingAutomaticLeaderboardService:
    MacBenchmarkLeaderboardServicing
{
    nonisolated let isConfigured = true
    private var submission: MacBenchmarkLeaderboardSubmission?

    func leaderboard(profile: BenchmarkProfile) async throws
        -> MacBenchmarkLeaderboardPage
    {
        let entry = try XCTUnwrap(submission).entry
        return MacBenchmarkLeaderboardPage(
            data: [entry],
            pagination: MacBenchmarkLeaderboardPagination(
                page: 1,
                pageSize: 50,
                total: 1,
                totalPages: 1
            ),
            meta: MacBenchmarkLeaderboardMetadata(
                baselineVersion: entry.workloadVersion
                    == MacBenchmarkLeaderboardConstants.standardWorkloadVersion
                    ? MacBenchmarkLeaderboardConstants.activeBaselineVersion
                    : "",
                profile: profile,
                workloadVersion: entry.workloadVersion,
                generatedAt: entry.completedAt
            )
        )
    }

    func submit(_ value: MacBenchmarkLeaderboardSubmission) async throws
        -> MacBenchmarkLeaderboardSubmissionReceipt
    {
        submission = value
        return MacBenchmarkLeaderboardSubmissionReceipt(
            data: value.entry,
            disposition: "created"
        )
    }

    func remove(_: MacBenchmarkLeaderboardRemoval) async throws
        -> MacBenchmarkLeaderboardRemovalReceipt
    {
        throw MacBenchmarkLeaderboardServiceError.unavailable
    }

    func lastSubmission() -> MacBenchmarkLeaderboardSubmission? { submission }
}

private extension MacBenchmarkLeaderboardSubmission {
    var entry: MacBenchmarkLeaderboardEntry {
        MacBenchmarkLeaderboardEntry(
            id: "cccccccccccccccccccccccccccccccc",
            rank: 1,
            displayName: displayName,
            processorModel: processorModel,
            score: proposedScore,
            profile: profile,
            workloadVersion: workloadVersion,
            physicalMemoryBytes: metrics.physicalMemoryBytes,
            systemDiskCapacityBytes: metrics.systemDiskCapacityBytes,
            completedAt: MacBenchmarkLeaderboardDateCodec.date(from: completedAt)
                ?? .distantPast
        )
    }
}

private struct FailingLeaderboardService: MacBenchmarkLeaderboardServicing {
    let error: MacBenchmarkLeaderboardServiceError
    let isConfigured = true

    func leaderboard(profile _: BenchmarkProfile) async throws
        -> MacBenchmarkLeaderboardPage
    {
        throw error
    }

    func submit(_: MacBenchmarkLeaderboardSubmission) async throws
        -> MacBenchmarkLeaderboardSubmissionReceipt
    {
        throw error
    }

    func remove(_: MacBenchmarkLeaderboardRemoval) async throws
        -> MacBenchmarkLeaderboardRemovalReceipt
    {
        throw error
    }
}

@MainActor
private final class FixtureLeaderboardIdentityProvider:
    MacBenchmarkLeaderboardIdentityProviding
{
    func installationID() -> UUID {
        UUID(uuidString: "123e4567-e89b-42d3-a456-426614174001")!
    }

    func suggestedDisplayName() -> String { "Fixture Mac" }
    func remember(displayName _: String, entryID _: String) {}
    func forgetSubmittedEntry() {}
    func lastSubmittedEntryID() -> String? { nil }
}

private func XCTAssertThrowsErrorAsync<T: Sendable, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
