import Foundation
import XCTest
@testable import StorageCleanerMac

final class NetworkSpeedTestStoreCompatibilityTests: XCTestCase {
    @MainActor
    func testCompatibilityCannotStartBeforeNativeServiceReportsUnavailable() async {
        let nativeRunner = StoreNativeRunner(steps: [])
        let compatibility = StoreCompatibilityRunner(steps: [
            .result(compatibilityResult())
        ])
        let store = NetworkSpeedTestStore(
            runner: nativeRunner,
            compatibilityService: compatibility
        )

        store.startCompatibility(consentGranted: true)

        let compatibilityStarts = await compatibility.startCount()
        let nativeStarts = await nativeRunner.startCount()
        XCTAssertEqual(store.state, .idle)
        XCTAssertFalse(store.isCompatibilityAvailable)
        XCTAssertEqual(compatibilityStarts, 0)
        XCTAssertEqual(nativeStarts, 0)
    }

    @MainActor
    func testNativeUnavailableOnlyOffersCompatibilityAndNeverStartsItAutomatically() async {
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
        ])
        let compatibility = StoreCompatibilityRunner(steps: [
            .result(compatibilityResult())
        ])
        let store = NetworkSpeedTestStore(
            runner: nativeRunner,
            compatibilityService: compatibility
        )

        store.start(consentGranted: true)
        await store.waitUntilIdle()

        let nativeStarts = await nativeRunner.startCount()
        let compatibilityStarts = await compatibility.startCount()
        XCTAssertEqual(store.state, .compatibilityAvailable)
        XCTAssertTrue(store.isCompatibilityAvailable)
        XCTAssertNil(store.lastSuccessfulResult)
        XCTAssertEqual(nativeStarts, 2)
        XCTAssertEqual(compatibilityStarts, 0)
    }

    @MainActor
    func testCompatibilityNeedsSeparateConsentBeforePublishingItsEstimate() async {
        let result = compatibilityResult()
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
        ])
        let compatibility = StoreCompatibilityRunner(steps: [.result(result)])
        var publishedResult: NetworkSpeedTestResult?
        let store = NetworkSpeedTestStore(
            runner: nativeRunner,
            compatibilityService: compatibility,
            onSuccessfulResult: { publishedResult = $0 }
        )
        store.start(consentGranted: true)
        await store.waitUntilIdle()

        store.startCompatibility(consentGranted: false)

        let startsBeforeConsent = await compatibility.startCount()
        XCTAssertEqual(store.state, .compatibilityConsentRequired)
        XCTAssertEqual(startsBeforeConsent, 0)

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        let startsAfterConsent = await compatibility.startCount()
        XCTAssertEqual(store.state, .succeeded)
        XCTAssertTrue(store.isCompatibilityAvailable)
        XCTAssertEqual(store.lastSuccessfulResult, result)
        XCTAssertEqual(store.lastSuccessfulResult?.source, .compatibilityEstimate)
        XCTAssertEqual(publishedResult, result)
        XCTAssertEqual(startsAfterConsent, 1)
    }

    @MainActor
    func testCompatibilityUsesSharedHeavyWorkLeaseAndCanRetryAfterConflict() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activityStore = HeavyWorkActivityStore(coordinator: coordinator)
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
        ])
        let compatibility = StoreCompatibilityRunner(steps: [
            .result(compatibilityResult())
        ])
        let store = NetworkSpeedTestStore(
            heavyWorkCoordinator: coordinator,
            heavyWorkActivityStore: activityStore,
            runner: nativeRunner,
            compatibilityService: compatibility
        )
        store.start(consentGranted: true)
        await store.waitUntilIdle()
        let benchmarkLease = try await coordinator.acquire(owner: .benchmark)

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        let startsWhileBlocked = await compatibility.startCount()
        let ownerWhileBlocked = await coordinator.activeOwner
        XCTAssertEqual(store.state, .failed)
        XCTAssertTrue(store.isCompatibilityAvailable)
        XCTAssertEqual(startsWhileBlocked, 0)
        XCTAssertEqual(ownerWhileBlocked, .benchmark)
        XCTAssertEqual(
            store.conflictMessage,
            HeavyWorkActivityStore.conflictMessage(activeOwner: .benchmark)
        )

        await coordinator.release(benchmarkLease)
        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        let startsAfterRetry = await compatibility.startCount()
        let ownerAfterRetry = await coordinator.activeOwner
        XCTAssertEqual(store.state, .succeeded)
        XCTAssertEqual(startsAfterRetry, 1)
        XCTAssertNil(ownerAfterRetry)
    }

    @MainActor
    func testCompatibilityCancellationReleasesLeaseAndSupportsRetry() async {
        let coordinator = HeavyWorkCoordinator()
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
        ])
        let compatibility = CancellationThenSuccessCompatibilityRunner(
            result: compatibilityResult()
        )
        let store = NetworkSpeedTestStore(
            heavyWorkCoordinator: coordinator,
            runner: nativeRunner,
            compatibilityService: compatibility
        )
        store.start(consentGranted: true)
        await store.waitUntilIdle()

        store.startCompatibility(consentGranted: true)
        let didStart = await compatibility.waitUntilStarted(timeout: .seconds(2))
        let ownerWhileRunning = await coordinator.activeOwner
        XCTAssertTrue(didStart)
        XCTAssertEqual(ownerWhileRunning, .networkTest)

        store.cancel()
        await store.waitUntilIdle()

        let ownerAfterCancellation = await coordinator.activeOwner
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertTrue(store.isCompatibilityAvailable)
        XCTAssertNil(ownerAfterCancellation)

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        let startsAfterRetry = await compatibility.startCount()
        let ownerAfterRetry = await coordinator.activeOwner
        XCTAssertEqual(store.state, .succeeded)
        XCTAssertEqual(store.lastSuccessfulResult?.source, .compatibilityEstimate)
        XCTAssertEqual(startsAfterRetry, 2)
        XCTAssertNil(ownerAfterRetry)
    }

    @MainActor
    func testCompatibilityFailureKeepsFallbackUnlockedForExplicitRetry() async {
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
        ])
        let compatibility = StoreCompatibilityRunner(steps: [
            .failure(.transportFailed),
            .result(compatibilityResult())
        ])
        let store = NetworkSpeedTestStore(
            runner: nativeRunner,
            compatibilityService: compatibility
        )
        store.start(consentGranted: true)
        await store.waitUntilIdle()

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .failed)
        XCTAssertTrue(store.isCompatibilityAvailable)

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        let compatibilityStarts = await compatibility.startCount()
        XCTAssertEqual(store.state, .succeeded)
        XCTAssertTrue(store.isCompatibilityAvailable)
        XCTAssertEqual(compatibilityStarts, 2)
    }

    @MainActor
    func testSuccessfulNativeRetryLocksCompatibilityFallbackAgain() async {
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
            .success
        ])
        let compatibility = StoreCompatibilityRunner(steps: [
            .result(compatibilityResult())
        ])
        let store = NetworkSpeedTestStore(
            runner: nativeRunner,
            compatibilityService: compatibility
        )
        store.start(consentGranted: true)
        await store.waitUntilIdle()
        XCTAssertTrue(store.isCompatibilityAvailable)

        store.start(consentGranted: true)
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .succeeded)
        XCTAssertEqual(store.lastSuccessfulResult?.source, .nativeSystem)
        XCTAssertFalse(store.isCompatibilityAvailable)

        store.startCompatibility(consentGranted: true)
        let compatibilityStarts = await compatibility.startCount()
        XCTAssertEqual(compatibilityStarts, 0)
        XCTAssertEqual(store.state, .succeeded)
    }

    @MainActor
    func testFailedCompatibilityRunPublishesNoPartialResultOrSensitiveDetails() async {
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
        ])
        let compatibility = StoreCompatibilityRunner(steps: [
            .failure(.transportFailed)
        ])
        var publishedResults: [NetworkSpeedTestResult] = []
        let store = NetworkSpeedTestStore(
            runner: nativeRunner,
            compatibilityService: compatibility,
            onSuccessfulResult: { publishedResults.append($0) }
        )
        store.start(consentGranted: true)
        await store.waitUntilIdle()

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .failed)
        XCTAssertTrue(store.isCompatibilityAvailable)
        XCTAssertNil(store.lastSuccessfulResult)
        XCTAssertTrue(publishedResults.isEmpty)
        XCTAssertFalse(String(describing: store.state).contains("speed.cloudflare.com"))
    }

    private func compatibilityResult() -> NetworkSpeedTestResult {
        NetworkSpeedTestResult(
            downloadMbps: 320,
            uploadMbps: 42,
            responsivenessRPM: nil,
            idleLatencyMilliseconds: 18,
            loadedLatencyP50Milliseconds: 45,
            loadedLatencyP95Milliseconds: 72,
            jitterMilliseconds: 4,
            interfaceName: "wifi",
            source: .compatibilityEstimate,
            methodVersion: NetworkCompatibilitySpeedTestService.methodVersion,
            durationSeconds: 12,
            transferredBytes: 64 * 1_024 * 1_024,
            completeness: NetworkCompatibilitySpeedTestService.resultCompleteness,
            testedAt: Date(timeIntervalSince1970: 1_752_643_200)
        )
    }
}

actor StoreNativeRunner: NetworkQualityRunning {
    enum Step: Sendable {
        case serviceUnavailable
        case success
    }

    private var steps: [Step]
    private var starts = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func run(_ command: NetworkQualityCommand) async throws -> NetworkQualityCommandOutput {
        starts += 1
        guard !steps.isEmpty else { throw NetworkSpeedTestError.failed }
        switch steps.removeFirst() {
        case .serviceUnavailable:
            return NetworkQualityCommandOutput(
                terminationStatus: 1,
                standardOutput: Data(
                    #"{"error_domain":"NetworkQualityErrorDomain","error_code":1003}"#.utf8
                ),
                standardError: Data()
            )
        case .success:
            return NetworkQualityCommandOutput(
                terminationStatus: 0,
                standardOutput: Data(
                    #"{"dl_throughput":512000000,"ul_throughput":48000000,"responsiveness":734,"base_rtt":21,"interface_name":"en0"}"#.utf8
                ),
                standardError: Data()
            )
        }
    }

    func startCount() -> Int { starts }
}

private actor StoreCompatibilityRunner: NetworkCompatibilitySpeedTesting {
    enum Step: Sendable {
        case result(NetworkSpeedTestResult)
        case failure(CompatibilitySpeedTestError)
    }

    private var steps: [Step]
    private var starts = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func test() async throws -> NetworkSpeedTestResult {
        starts += 1
        guard !steps.isEmpty else { throw CompatibilitySpeedTestError.transportFailed }
        switch steps.removeFirst() {
        case let .result(result):
            return result
        case let .failure(error):
            throw error
        }
    }

    func startCount() -> Int { starts }
}

private actor CancellationThenSuccessCompatibilityRunner: NetworkCompatibilitySpeedTesting {
    private let result: NetworkSpeedTestResult
    private var starts = 0

    init(result: NetworkSpeedTestResult) {
        self.result = result
    }

    func test() async throws -> NetworkSpeedTestResult {
        starts += 1
        if starts == 1 {
            try await Task.sleep(for: .seconds(60))
        }
        return result
    }

    func startCount() -> Int { starts }

    func waitUntilStarted(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while starts == 0, clock.now < deadline {
            await Task.yield()
        }
        return starts > 0
    }
}
