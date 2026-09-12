import Foundation
import XCTest
@testable import StorageCleanerMac

final class NetworkSpeedTestResultRepositoryTests: XCTestCase {
    private var rootURL: URL!
    private var storageURL: URL!
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NetworkSpeedTestResultRepositoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        storageURL = rootURL.appendingPathComponent("last-result.json")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testRoundTripPreservesOnlyTheCompleteAggregateResult() async throws {
        let repository = makeRepository()
        let result = makeResult(testedAt: referenceDate.addingTimeInterval(-60))

        try await repository.save(result)

        let loaded = await repository.load()
        XCTAssertEqual(loaded, result)
        let storedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
        )
        XCTAssertNil(storedObject["server"])
        XCTAssertNil(storedObject["serverAddress"])
        XCTAssertNil(storedObject["ip"])
    }

    func testOlderCompletionCannotReplaceANewerSavedResult() async throws {
        let repository = makeRepository()
        let older = makeResult(testedAt: referenceDate.addingTimeInterval(-120))
        let newer = makeResult(testedAt: referenceDate.addingTimeInterval(-30), downloadMbps: 900)

        try await repository.save(newer)
        try await repository.save(older)

        let loaded = await repository.load()
        XCTAssertEqual(loaded, newer)
    }

    func testInvalidOrFutureResultsAreRejectedBeforeWriting() async {
        let repository = makeRepository()
        let invalid = makeResult(downloadMbps: .infinity)
        let future = makeResult(
            testedAt: referenceDate.addingTimeInterval(
                NetworkSpeedTestResultRepository.futureDateTolerance + 1
            )
        )

        do {
            try await repository.save(invalid)
            XCTFail("Expected an invalid numeric result to be rejected")
        } catch let error as NetworkSpeedTestResultRepositoryError {
            XCTAssertEqual(error, .invalidResult)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await repository.save(future)
            XCTFail("Expected a far-future result to be rejected")
        } catch let error as NetworkSpeedTestResultRepositoryError {
            XCTAssertEqual(error, .invalidResult)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func testCorruptOversizedAndSymlinkStorageLoadsAsNoResult() async throws {
        let repository = makeRepository()

        try Data("not-json".utf8).write(to: storageURL)
        let corruptResult = await repository.load()
        XCTAssertNil(corruptResult)

        try Data(
            repeating: 0,
            count: NetworkSpeedTestResultRepository.maximumFileBytes + 1
        ).write(to: storageURL)
        let oversizedResult = await repository.load()
        XCTAssertNil(oversizedResult)

        try FileManager.default.removeItem(at: storageURL)
        let target = rootURL.appendingPathComponent("target.json")
        try JSONEncoder().encode(makeResult()).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: storageURL,
            withDestinationURL: target
        )
        let symlinkResult = await repository.load()
        XCTAssertNil(symlinkResult)

        do {
            try await repository.save(makeResult(downloadMbps: 999))
            XCTFail("Expected a symbolic-link destination to be rejected")
        } catch let error as NetworkSpeedTestResultRepositoryError {
            XCTAssertEqual(error, .invalidStorage)
        }
        let untouchedTarget = try JSONDecoder().decode(
            NetworkSpeedTestResult.self,
            from: Data(contentsOf: target)
        )
        XCTAssertEqual(untouchedTarget.downloadMbps, 512)
    }

    private func makeRepository() -> NetworkSpeedTestResultRepository {
        NetworkSpeedTestResultRepository(
            storageURL: storageURL,
            now: { [referenceDate] in referenceDate }
        )
    }

    private func makeResult(
        testedAt: Date? = nil,
        downloadMbps: Double = 512
    ) -> NetworkSpeedTestResult {
        NetworkSpeedTestResult(
            downloadMbps: downloadMbps,
            uploadMbps: 48,
            responsivenessRPM: 900,
            idleLatencyMilliseconds: 12,
            loadedLatencyP50Milliseconds: nil,
            loadedLatencyP95Milliseconds: nil,
            jitterMilliseconds: nil,
            interfaceName: "en0",
            source: .nativeSystem,
            methodVersion: NetworkSpeedTestService.nativeMethodVersion,
            durationSeconds: 10,
            transferredBytes: 64_000_000,
            completeness: NetworkSpeedTestService.nativeCompleteness,
            testedAt: testedAt ?? referenceDate.addingTimeInterval(-60)
        )
    }
}

final class NetworkSpeedTestPersistenceTests: XCTestCase {
    private let testedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testRestorePublishesTheSavedResultToTheHealthBridge() async {
        let expected = makeResult(downloadMbps: 700)
        let repository = RecordingNetworkSpeedTestResultRepository(initial: expected)
        var bridgedResult: NetworkSpeedTestResult?
        let store = NetworkSpeedTestStore(
            resultRepository: repository,
            onSuccessfulResult: { bridgedResult = $0 }
        )

        await store.restoreLastSuccessfulResult()
        await store.restoreLastSuccessfulResult()

        XCTAssertEqual(store.state, .succeeded)
        XCTAssertEqual(store.lastSuccessfulResult, expected)
        XCTAssertEqual(bridgedResult, expected)
        let loadCount = await repository.loadCount()
        XCTAssertEqual(loadCount, 1)
    }

    @MainActor
    func testSuccessfulRunPersistsTheCompleteResult() async throws {
        let repository = RecordingNetworkSpeedTestResultRepository()
        let runner = PersistentResultNetworkQualityRunner(
            output: NetworkQualityCommandOutput(
                terminationStatus: 0,
                standardOutput: Data(
                    """
                    {"dl_throughput":512000000,"ul_throughput":48000000,"responsiveness":900,"base_rtt":12,"interface_name":"en0"}
                    """.utf8
                ),
                standardError: Data()
            )
        )
        let store = NetworkSpeedTestStore(
            runner: runner,
            now: { [testedAt] in testedAt },
            resultRepository: repository
        )

        store.start(consentGranted: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await repository.savedResult() == nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        let saved = await repository.savedResult()
        XCTAssertEqual(saved, store.lastSuccessfulResult)
        XCTAssertEqual(saved?.testedAt, testedAt)
        XCTAssertEqual(store.state, .succeeded)
    }

    private func makeResult(downloadMbps: Double) -> NetworkSpeedTestResult {
        NetworkSpeedTestResult(
            downloadMbps: downloadMbps,
            uploadMbps: 48,
            responsivenessRPM: 900,
            idleLatencyMilliseconds: 12,
            loadedLatencyP50Milliseconds: nil,
            loadedLatencyP95Milliseconds: nil,
            jitterMilliseconds: nil,
            interfaceName: "en0",
            source: .nativeSystem,
            methodVersion: NetworkSpeedTestService.nativeMethodVersion,
            durationSeconds: 10,
            transferredBytes: 64_000_000,
            completeness: NetworkSpeedTestService.nativeCompleteness,
            testedAt: testedAt
        )
    }
}

private actor RecordingNetworkSpeedTestResultRepository: NetworkSpeedTestResultPersisting {
    private var stored: NetworkSpeedTestResult?
    private var loads = 0

    init(initial: NetworkSpeedTestResult? = nil) {
        stored = initial
    }

    func load() async -> NetworkSpeedTestResult? {
        loads += 1
        return stored
    }

    func save(_ result: NetworkSpeedTestResult) async throws {
        stored = result
    }

    func savedResult() -> NetworkSpeedTestResult? { stored }

    func loadCount() -> Int { loads }
}

private actor PersistentResultNetworkQualityRunner: NetworkQualityRunning {
    private let output: NetworkQualityCommandOutput

    init(output: NetworkQualityCommandOutput) {
        self.output = output
    }

    func run(_ command: NetworkQualityCommand) async throws -> NetworkQualityCommandOutput {
        output
    }
}
