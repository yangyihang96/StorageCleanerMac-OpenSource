import Foundation
import XCTest
@testable import StorageCleanerMac

final class NetworkCompatibilitySpeedTestServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CompatibilityURLProtocolState.shared.reset()
    }

    func testEphemeralConfigurationDisablesCookiesCacheAndConnectivityWaiting() {
        let configuration = NetworkCompatibilitySpeedTestService.makeConfiguration(
            protocolClasses: [CompatibilityStubURLProtocol.self]
        )

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(
            configuration.protocolClasses?.first.map(ObjectIdentifier.init),
            ObjectIdentifier(CompatibilityStubURLProtocol.self)
        )
    }

    func testSuccessfulEstimateUsesOnlyAllowlistedEndpointsAndTruthfulAggregateFields() async throws {
        let meter = TransferMeter(limitBytes: 1_024)
        let service = makeService(meter: meter)

        let result = try await service.test()

        XCTAssertEqual(result.source, .compatibilityEstimate)
        XCTAssertEqual(result.methodVersion, "compatibility-cloudflare-v1")
        XCTAssertEqual(result.interfaceName, "other")
        XCTAssertNil(result.responsivenessRPM)
        XCTAssertEqual(result.transferredBytes, 48)
        XCTAssertEqual(result.completeness, 5.0 / 6.0, accuracy: 0.000_001)
        XCTAssertGreaterThan(result.downloadMbps, 0)
        XCTAssertGreaterThan(result.uploadMbps, 0)
        XCTAssertGreaterThan(result.idleLatencyMilliseconds, 0)
        XCTAssertNotNil(result.loadedLatencyP50Milliseconds)
        XCTAssertNotNil(result.loadedLatencyP95Milliseconds)
        XCTAssertNotNil(result.jitterMilliseconds)
        XCTAssertTrue(result.durationSeconds.isFinite)

        let requests = CompatibilityURLProtocolState.shared.requests
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { request in
            guard let url = request.url else { return false }
            return url.scheme == "https"
                && url.host == "speed.cloudflare.com"
                && ["/__down", "/__up"].contains(url.path)
        })
    }

    func testMeteredApplicationPayloadNeverExceeds128MiB() async throws {
        let meter = TransferMeter()
        let service = makeService(meter: meter)

        _ = try await service.test()
        let totalPayloadBytes = await meter.totalBytes

        XCTAssertLessThanOrEqual(totalPayloadBytes, 134_217_728)
        XCTAssertEqual(totalPayloadBytes, 48)
    }

    func testTrafficBudgetDisclosureNamesApplicationPayloadAndExtraWireTraffic() {
        XCTAssertEqual(
            NetworkCompatibilitySpeedTestService.standardApplicationPayloadBytes,
            120 * 1_024 * 1_024
        )
        XCTAssertEqual(
            NetworkCompatibilitySpeedTestService.maximumApplicationPayloadBytes,
            134_217_728
        )
        let disclosure = NetworkCompatibilitySpeedTestService
            .applicationPayloadBudgetDisclosure

        XCTAssertTrue(disclosure.contains("应用层正文"))
        XCTAssertTrue(disclosure.contains("协议开销"))
        XCTAssertTrue(disclosure.contains("重传"))
        XCTAssertFalse(disclosure.contains("总流量绝不超过"))
    }

    func testLoadedLatencyDisclosureDescribesBestEffortOverlap() {
        let disclosure = NetworkCompatibilitySpeedTestService.loadedLatencyMethodDisclosure

        XCTAssertTrue(disclosure.contains("下载收到正文"))
        XCTAssertTrue(disclosure.contains("上传实际发送数据"))
        XCTAssertTrue(disclosure.contains("尽力"))
        XCTAssertTrue(disclosure.contains("不代表全程持续满载"))
    }

    func testSuccessfulTerminalValidationRejectsMissingPayloadProgressCallback() {
        XCTAssertEqual(
            CompatibilityPayloadIOAccounting.terminalError(
                observationRequired: true,
                observationRecorded: false
            ),
            .invalidMeasurement
        )
        XCTAssertNil(CompatibilityPayloadIOAccounting.terminalError(
            observationRequired: true,
            observationRecorded: true
        ))
        XCTAssertNil(CompatibilityPayloadIOAccounting.terminalError(
            observationRequired: false,
            observationRecorded: false
        ))
    }

    func testCompletedUploadWithoutProgressCallbackFailsInsteadOfHangingLoadedLatency() async {
        let service = makeService(reportsUploadProgress: false)

        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }

        XCTAssertFalse(CompatibilityURLProtocolState.shared.requests.contains {
            $0.compatibilityPhase == "loaded"
        })
    }

    func testLoadedLatencyRequestsFollowBothThroughputIOBeginnings() async throws {
        _ = try await makeService().test()
        let phases = CompatibilityURLProtocolState.shared.requests.compactMap(
            \.compatibilityPhase
        )

        let firstLoadedIndex = try XCTUnwrap(phases.firstIndex(of: "loaded"))
        let downloadIndex = try XCTUnwrap(phases.firstIndex(of: "download"))
        let uploadIndex = try XCTUnwrap(phases.firstIndex(of: "upload"))
        XCTAssertLessThan(downloadIndex, firstLoadedIndex)
        XCTAssertLessThan(uploadIndex, firstLoadedIndex)
    }

    func testLoadedLatencyDoesNotTreatResumedThroughputTasksAsPayloadIO() async throws {
        let service = makeService { request in
            switch request.compatibilityPhase {
            case "download":
                return .deferredSuccess(
                    statusCode: 200,
                    data: Data(count: request.compatibilityRequestedBytes)
                )
            case "upload":
                return .deferredSuccess(statusCode: 200, data: Data())
            default:
                return .defaultSuccess(for: request)
            }
        }
        let task = Task { try await service.test() }
        let didDeferThroughputResponses = await waitUntil {
            CompatibilityURLProtocolState.shared.deferredCount == 2
        }
        guard didDeferThroughputResponses else {
            task.cancel()
            _ = try? await task.value
            return
        }

        let phasesBeforePayloadIO = CompatibilityURLProtocolState.shared.requests.compactMap(
            \.compatibilityPhase
        )
        XCTAssertTrue(phasesBeforePayloadIO.contains("download"))
        XCTAssertTrue(phasesBeforePayloadIO.contains("upload"))
        XCTAssertFalse(
            phasesBeforePayloadIO.contains("loaded"),
            "Resuming both URLSession tasks must not open the loaded-latency gate"
        )

        CompatibilityURLProtocolState.shared.releaseDeferredResponses()
        let didStartLoadedLatency = await waitUntil {
            CompatibilityURLProtocolState.shared.requests.contains {
                $0.compatibilityPhase == "loaded"
            }
        }
        guard didStartLoadedLatency else {
            task.cancel()
            _ = try? await task.value
            return
        }
        _ = try await task.value

        let phasesAfterPayloadIO = CompatibilityURLProtocolState.shared.requests.compactMap(
            \.compatibilityPhase
        )
        XCTAssertTrue(phasesAfterPayloadIO.contains("loaded"))
    }

    func testRejectsConfigurationAboveActualMeterLimitBeforeSendingRequest() async {
        let meter = TransferMeter(limitBytes: 20)
        let service = makeService(
            meter: meter,
            parameters: .init(
                downloadBytes: 16,
                uploadBytes: 8,
                idleLatencySampleCount: 1,
                loadedLatencySampleCount: 1,
                auxiliaryResponseLimitBytes: 64
            )
        )

        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }
        let totalBytes = await meter.totalBytes

        XCTAssertEqual(totalBytes, 0)
        XCTAssertTrue(CompatibilityURLProtocolState.shared.requests.isEmpty)
    }

    func testSharedMeterRejectsConcurrentRunBeforeSecondRequest() async {
        let meter = TransferMeter(limitBytes: 2_048)
        let firstService = makeService(meter: meter) { _ in .pending }
        let secondService = makeService(meter: meter) { _ in .pending }
        let firstTask = Task { try await firstService.test() }
        await waitUntil { CompatibilityURLProtocolState.shared.pendingCount > 0 }
        let requestCountBeforeSecondRun = CompatibilityURLProtocolState.shared.requests.count

        await assertServiceError(.invalidMeasurement) {
            try await secondService.test()
        }

        XCTAssertEqual(
            CompatibilityURLProtocolState.shared.requests.count,
            requestCountBeforeSecondRun
        )
        firstTask.cancel()
        do {
            _ = try await firstTask.value
            XCTFail("Expected first run cancellation")
        } catch let error as CompatibilitySpeedTestError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSequentialRunsReportPerRunPayloadInsteadOfCumulativeMeterBytes() async throws {
        let meter = TransferMeter(limitBytes: 2_048)
        let service = makeService(meter: meter)

        let first = try await service.test()
        let second = try await service.test()
        let cumulativeBytes = await meter.totalBytes

        XCTAssertEqual(first.transferredBytes, 48)
        XCTAssertEqual(second.transferredBytes, 48)
        XCTAssertEqual(cumulativeBytes, 96)
    }

    func testStandardConfigurationCanRunTwiceWithAFreshPerRunBudget() async throws {
        let meter = TransferMeter()
        let service = makeService(meter: meter, parameters: .standard) { request in
            guard request.compatibilityPhase == "download" else {
                return .success(statusCode: 200, data: Data())
            }
            return .successInChunks(
                statusCode: 200,
                length: request.compatibilityRequestedBytes,
                chunkSize: 1_024 * 1_024
            )
        }

        let first = try await service.test()
        let second = try await service.test()
        let cumulativeBytes = await meter.totalBytes

        XCTAssertEqual(first.transferredBytes, 120 * 1_024 * 1_024)
        XCTAssertEqual(second.transferredBytes, 120 * 1_024 * 1_024)
        XCTAssertEqual(
            cumulativeBytes,
            240 * 1_024 * 1_024,
            "The diagnostic total may accumulate, but each run gets its own 128 MiB budget"
        )
    }

    func testRejectsNearCapConfigurationWhenAuxiliaryResponsesCrossHardLimit() async {
        let hardLimit = Int(TransferMeter.maximumApplicationPayloadBytes)
        let service = makeService(
            meter: TransferMeter(),
            parameters: .init(
                downloadBytes: hardLimit - 9,
                uploadBytes: 1,
                idleLatencySampleCount: 1,
                loadedLatencySampleCount: 1,
                auxiliaryResponseLimitBytes: 3
            )
        ) { _ in
            .success(statusCode: 503, data: Data())
        }

        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }
        XCTAssertTrue(CompatibilityURLProtocolState.shared.requests.isEmpty)
    }

    func testRejectsInitialEndpointOutsideHTTPSAllowlistWithoutSendingRequest() async {
        let service = makeService(
            downloadEndpoint: URL(string: "https://example.com/__down")!
        )

        await assertServiceError(.disallowedEndpoint) {
            try await service.test()
        }
        XCTAssertTrue(CompatibilityURLProtocolState.shared.requests.isEmpty)
    }

    func testRejectsInvalidParametersAsInvalidMeasurementWithoutSendingRequest() async {
        let service = makeService(parameters: .init(
            downloadBytes: 0,
            uploadBytes: 16,
            idleLatencySampleCount: 1,
            loadedLatencySampleCount: 1,
            auxiliaryResponseLimitBytes: 64
        ))

        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }
        XCTAssertTrue(CompatibilityURLProtocolState.shared.requests.isEmpty)
    }

    func testRejectsCrossHostRedirect() async {
        let service = makeRedirectService(to: URL(string: "https://example.com/__down")!)

        await assertServiceError(.disallowedRedirect) {
            try await service.test()
        }
    }

    func testRejectsCrossSchemeRedirect() async {
        let service = makeRedirectService(
            to: URL(string: "http://speed.cloudflare.com/__down")!
        )

        await assertServiceError(.disallowedRedirect) {
            try await service.test()
        }
    }

    func testRejectsChangedPathRedirect() async {
        let service = makeRedirectService(
            to: URL(string: "https://speed.cloudflare.com/other")!
        )

        await assertServiceError(.disallowedRedirect) {
            try await service.test()
        }
    }

    func testRejectsSamePathRedirectThatChangesHTTPMethod() {
        let endpoint = URL(string: "https://speed.cloudflare.com/__up")!

        XCTAssertFalse(NetworkCompatibilitySpeedTestService.isAllowedRedirect(
            from: endpoint,
            to: endpoint,
            originalMethod: "POST",
            redirectedMethod: "GET"
        ))
        XCTAssertFalse(NetworkCompatibilitySpeedTestService.isAllowedRedirect(
            from: endpoint,
            to: endpoint,
            originalMethod: "POST",
            redirectedMethod: "POST"
        ))
        let downloadEndpoint = URL(string: "https://speed.cloudflare.com/__down")!
        XCTAssertTrue(NetworkCompatibilitySpeedTestService.isAllowedRedirect(
            from: downloadEndpoint,
            to: downloadEndpoint,
            originalMethod: "GET",
            redirectedMethod: "GET"
        ))
    }

    func testUploadDelegateRedirectIsRejectedBeforeReplay() async {
        let destination = URL(string: "https://speed.cloudflare.com/__up")!
        let service = makeService { request in
            request.compatibilityPhase == "upload"
                ? .delegateRedirect(destination, method: "GET")
                : .defaultSuccess(for: request)
        }

        await assertServiceError(.disallowedRedirect) {
            try await service.test()
        }
    }

    func testHTTPFailureIsNotReportedAsAResult() async {
        let service = makeService { request in
            request.compatibilityPhase == "download"
                ? .success(statusCode: 503, data: Data())
                : .defaultSuccess(for: request)
        }

        await assertServiceError(.httpStatus(503)) {
            try await service.test()
        }
    }

    func testShortDownloadIsRejectedAsEarlyEOF() async {
        let service = makeService { request in
            guard request.compatibilityPhase == "download" else {
                return .defaultSuccess(for: request)
            }
            let requestedBytes = max(0, request.compatibilityRequestedBytes)
            return .success(statusCode: 200, data: Data(count: max(0, requestedBytes - 1)))
        }

        await assertServiceError(.earlyEOF) {
            try await service.test()
        }
    }

    func testUnknownContentLengthIsRejectedBeforeReadingBody() async {
        let service = makeService { request in
            request.compatibilityPhase == "idle"
                ? .successWithoutContentLength(statusCode: 200, data: Data())
                : .defaultSuccess(for: request)
        }

        await assertServiceError(.invalidResponse) {
            try await service.test()
        }
    }

    func testMismatchedContentLengthIsRejectedAsEarlyEOF() async {
        let service = makeService { request in
            request.compatibilityPhase == "idle"
                ? .successWithDeclaredLength(statusCode: 200, data: Data(), length: 1)
                : .defaultSuccess(for: request)
        }

        await assertServiceError(.earlyEOF) {
            try await service.test()
        }
    }

    func testOversizedSingleChunkFailsWithoutConsumingMeterBudget() async {
        let meter = TransferMeter(limitBytes: 1_024)
        let service = makeService(meter: meter) { request in
            request.compatibilityPhase == "idle"
                ? .successWithDeclaredLength(statusCode: 200, data: Data(count: 65), length: 64)
                : .defaultSuccess(for: request)
        }

        await assertServiceError(.byteLimitExceeded) {
            try await service.test()
        }
        let totalBytes = await meter.totalBytes
        XCTAssertEqual(totalBytes, 0)
    }

    func testIncompleteUploadByteCountIsRejectedAsEarlyEOF() async {
        let service = makeService(reportedUploadBytes: 15)

        await assertServiceError(.earlyEOF) {
            try await service.test()
        }
    }

    func testZeroTerminalUploadByteCountIsRejectedAsEarlyEOF() async {
        let service = makeService(reportedUploadBytes: 0)

        await assertServiceError(.earlyEOF) {
            try await service.test()
        }
    }

    func testTerminalUploadCountWinsOverPartialProgressCallback() {
        let expected = Int64(24 * 1_024 * 1_024)
        let partial = Int64(20 * 1_024 * 1_024)

        XCTAssertNil(CompatibilityUploadAccounting.progressError(
            previousBytes: 0,
            totalBytesSent: partial,
            totalBytesExpectedToSend: expected,
            expectedBytes: expected
        ))
        XCTAssertNil(CompatibilityUploadAccounting.terminalError(
            taskReportedBytes: expected,
            expectedBytes: expected
        ))
    }

    func testLegacyBodyStreamRequestProvidesOnlyTheInitialUploadStream() {
        let source = CompatibilityOneShotUploadBody(data: Data(count: 16))

        XCTAssertNotNil(source.takeStream(requestedOffset: nil))
        XCTAssertNil(
            source.takeStream(requestedOffset: nil),
            "The legacy needNewBodyStream callback must reject an upload replay"
        )
    }

    func testOffsetBodyStreamRequestCannotReplayAnIssuedUpload() {
        let source = CompatibilityOneShotUploadBody(data: Data(count: 16))

        XCTAssertNotNil(source.takeStream(requestedOffset: nil))
        XCTAssertNil(
            source.takeStream(requestedOffset: 0),
            "The offset callback must not replay even from byte zero"
        )
        XCTAssertNil(source.takeStream(requestedOffset: 8))
    }

    func testOffsetBodyStreamRequestCanSupplyInitialStreamOnlyOnce() {
        let source = CompatibilityOneShotUploadBody(data: Data(count: 16))

        XCTAssertNotNil(source.takeStream(requestedOffset: 0))
        XCTAssertNil(
            source.takeStream(requestedOffset: nil),
            "Whichever delegate callback supplies the initial stream owns the one-shot token"
        )
    }

    func testExcessUploadByteCountIsRejectedAsInvalidMeasurement() async {
        let service = makeService(reportedUploadBytes: 17)

        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }
    }

    func testCancellationStopsPendingURLSessionTasks() async {
        let service = makeService { _ in
            .pending
        }
        let task = Task { try await service.test() }
        await waitUntil { CompatibilityURLProtocolState.shared.pendingCount > 0 }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as CompatibilitySpeedTestError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertGreaterThan(
            CompatibilityURLProtocolState.shared.stopCount,
            0,
            "The service must not return before URLSession has stopped pending protocol work"
        )
    }

    func testShutdownReturnsBoundedCleanupContextWhenInvalidationCallbackNeverArrives() async {
        let invalidator = ControlledCompatibilitySessionInvalidator()
        let service = makeService(
            shutdownGraceSeconds: 0.02,
            sessionInvalidationController: invalidator
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var cleanupContext: NetworkCompatibilityCleanupContext?

        do {
            _ = try await service.test()
            XCTFail("Expected cleanup-pending failure")
        } catch let error as NetworkCompatibilitySpeedTestCleanupPendingError {
            cleanupContext = error.context
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000_000
        XCTAssertLessThan(elapsed, 1)
        XCTAssertEqual(invalidator.requestCount, 1)
        XCTAssertTrue(
            invalidator.hasPendingSession,
            "Cleanup context must keep the URLSession and delegate alive"
        )

        invalidator.releasePendingInvalidationAndPassThroughFutureRequests()
        if let cleanupContext {
            await cleanupContext.waitForVerifiedInvalidation()
        }
        XCTAssertFalse(invalidator.hasPendingSession)
    }

    @MainActor
    func testDelayedInvalidationQuarantinesRetriesUntilRealCallback() async {
        let coordinator = HeavyWorkCoordinator()
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
        ])
        let invalidator = ControlledCompatibilitySessionInvalidator()
        let service = makeService(
            shutdownGraceSeconds: 0.02,
            sessionInvalidationController: invalidator
        )
        let store = NetworkSpeedTestStore(
            heavyWorkCoordinator: coordinator,
            runner: nativeRunner,
            compatibilityService: service
        )
        store.start(consentGranted: true)
        await store.waitUntilIdle()
        XCTAssertEqual(store.state, .compatibilityAvailable)

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        let ownerDuringCleanup = await coordinator.activeOwner
        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(invalidator.requestCount, 1)
        XCTAssertEqual(ownerDuringCleanup, .networkTest)

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        let ownerWhileRetryBlocked = await coordinator.activeOwner
        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(invalidator.requestCount, 1)
        XCTAssertEqual(ownerWhileRetryBlocked, .networkTest)
        XCTAssertEqual(
            store.conflictMessage,
            HeavyWorkActivityStore.conflictMessage(activeOwner: .networkTest)
        )

        invalidator.releasePendingInvalidationAndPassThroughFutureRequests()
        var didClearQuarantine = false
        for _ in 0..<5_000 {
            if await coordinator.activeOwner == nil {
                didClearQuarantine = true
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(didClearQuarantine)

        store.startCompatibility(consentGranted: true)
        await store.waitUntilIdle()

        let ownerAfterRetry = await coordinator.activeOwner
        XCTAssertEqual(store.state, .succeeded)
        XCTAssertEqual(invalidator.requestCount, 2)
        XCTAssertNil(ownerAfterRetry)
    }

    @MainActor
    func testStoreCancellationWaitsForRealCompatibilitySessionShutdownBeforeLeaseRelease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let nativeRunner = StoreNativeRunner(steps: [
            .serviceUnavailable,
            .serviceUnavailable,
        ])
        let service = makeService { _ in .pending }
        let store = NetworkSpeedTestStore(
            heavyWorkCoordinator: coordinator,
            runner: nativeRunner,
            compatibilityService: service
        )
        store.start(consentGranted: true)
        await store.waitUntilIdle()
        XCTAssertEqual(store.state, .compatibilityAvailable)

        store.startCompatibility(consentGranted: true)
        var didStartRequest = false
        for _ in 0..<5_000 {
            if CompatibilityURLProtocolState.shared.pendingCount > 0 {
                didStartRequest = true
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(didStartRequest)
        guard didStartRequest else {
            store.cancel()
            await store.waitUntilIdle()
            return
        }
        let pendingBeforeCancellation = CompatibilityURLProtocolState.shared.pendingCount
        let ownerWhileRunning = await coordinator.activeOwner
        XCTAssertEqual(ownerWhileRunning, .networkTest)

        store.cancel()
        await store.waitUntilIdle()

        let ownerAfterCancellation = await coordinator.activeOwner
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertNil(ownerAfterCancellation)
        XCTAssertGreaterThanOrEqual(
            CompatibilityURLProtocolState.shared.stopCount,
            pendingBeforeCancellation
        )
        let benchmarkLease = try await coordinator.acquire(owner: .benchmark)
        await coordinator.release(benchmarkLease)
    }

    func testLatencyStatisticsUseP50P95AndMedianAbsoluteDeviation() throws {
        let statistics = try CompatibilityLatencyStatistics.evaluate(
            samplesMilliseconds: [10, 20, 30, 40, 50]
        )

        XCTAssertEqual(statistics.p50Milliseconds, 30, accuracy: 0.000_001)
        XCTAssertEqual(statistics.p95Milliseconds, 48, accuracy: 0.000_001)
        XCTAssertEqual(statistics.madMilliseconds, 10, accuracy: 0.000_001)
    }

    func testNonFiniteLatencyOrClockIsRejected() async throws {
        XCTAssertThrowsError(
            try CompatibilityLatencyStatistics.evaluate(samplesMilliseconds: [10, .nan])
        ) { error in
            XCTAssertEqual(error as? CompatibilitySpeedTestError, .invalidMeasurement)
        }

        let service = NetworkCompatibilitySpeedTestService(
            meter: TransferMeter(limitBytes: 1_024),
            parameters: testParameters,
            protocolClasses: [CompatibilityStubURLProtocol.self],
            monotonicSeconds: { .nan }
        )
        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }
    }

    func testEncodedResultPersistsNoProviderEndpointOrIPAddress() async throws {
        let result = try await makeService().test()

        let encoded = try JSONEncoder().encode(result)
        let text = String(decoding: encoded, as: UTF8.self).lowercased()

        XCTAssertFalse(text.contains("speed.cloudflare.com"))
        XCTAssertFalse(text.contains("/__down"))
        XCTAssertFalse(text.contains("/__up"))
        XCTAssertFalse(text.contains("endpoint"))
        XCTAssertFalse(text.contains("ip_address"))
        XCTAssertFalse(text.contains("192.168."))
        XCTAssertFalse(text.contains("兼容连接"))
    }

    func testStableInterfaceTokenCanBeInjectedWithoutLocalization() async throws {
        let result = try await makeService(interfaceName: "wifi").test()

        XCTAssertEqual(result.interfaceName, "wifi")
    }

    func testRejectsLocalizedInterfaceLabelBeforeSendingRequest() async {
        let service = makeService(interfaceName: "兼容连接")

        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }
        XCTAssertTrue(CompatibilityURLProtocolState.shared.requests.isEmpty)
    }

    func testOverflowingAuxiliaryBudgetIsRejectedBeforeSendingRequest() async {
        let service = makeService(parameters: .init(
            downloadBytes: 1,
            uploadBytes: 1,
            idleLatencySampleCount: Int.max,
            loadedLatencySampleCount: Int.max,
            auxiliaryResponseLimitBytes: Int.max
        ))

        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }
        XCTAssertTrue(CompatibilityURLProtocolState.shared.requests.isEmpty)
    }

    func testHugeLatencySampleCountIsRejectedEvenWithZeroAuxiliaryBytes() async {
        let service = makeService(parameters: .init(
            downloadBytes: 1,
            uploadBytes: 1,
            idleLatencySampleCount: Int.max,
            loadedLatencySampleCount: 1,
            auxiliaryResponseLimitBytes: 0
        ))

        await assertServiceError(.invalidMeasurement) {
            try await service.test()
        }
        XCTAssertTrue(CompatibilityURLProtocolState.shared.requests.isEmpty)
    }

    func testWorstCaseBudgetExactlyAtMeterLimitIsAccepted() async throws {
        let parameters = CompatibilitySpeedTestParameters(
            downloadBytes: 32,
            uploadBytes: 16,
            idleLatencySampleCount: 1,
            loadedLatencySampleCount: 1,
            auxiliaryResponseLimitBytes: 0
        )
        let result = try await makeService(
            meter: TransferMeter(limitBytes: 48),
            parameters: parameters
        ).test()

        XCTAssertEqual(result.transferredBytes, 48)
    }

    private var testParameters: CompatibilitySpeedTestParameters {
        .init(
            downloadBytes: 32,
            uploadBytes: 16,
            idleLatencySampleCount: 3,
            loadedLatencySampleCount: 5,
            auxiliaryResponseLimitBytes: 64
        )
    }

    private func makeService(
        meter: TransferMeter = TransferMeter(limitBytes: 1_024),
        parameters: CompatibilitySpeedTestParameters? = nil,
        downloadEndpoint: URL = URL(string: "https://speed.cloudflare.com/__down")!,
        uploadEndpoint: URL = URL(string: "https://speed.cloudflare.com/__up")!,
        interfaceName: String = "other",
        reportedUploadBytes: Int64? = nil,
        reportsUploadProgress: Bool = true,
        shutdownGraceSeconds: TimeInterval = 1,
        sessionInvalidationController: ControlledCompatibilitySessionInvalidator? = nil,
        handler: @escaping @Sendable (URLRequest) -> CompatibilityStubResponse = {
            .defaultSuccess(for: $0)
        }
    ) -> NetworkCompatibilitySpeedTestService {
        CompatibilityURLProtocolState.shared.install(handler)
        let clock = CompatibilityStepClock(step: 0.010)
        let resolvedParameters = parameters ?? testParameters
        let resolvedUploadBytes = reportedUploadBytes ?? Int64(resolvedParameters.uploadBytes)
        return NetworkCompatibilitySpeedTestService(
            meter: meter,
            parameters: resolvedParameters,
            downloadEndpoint: downloadEndpoint,
            uploadEndpoint: uploadEndpoint,
            interfaceName: interfaceName,
            protocolClasses: [CompatibilityStubURLProtocol.self],
            now: { Date(timeIntervalSince1970: 1_000) },
            monotonicSeconds: { clock.next() },
            sentByteCount: { task in
                task.originalRequest?.httpMethod == "POST"
                    ? resolvedUploadBytes
                    : task.countOfBytesSent
            },
            shutdownGraceSeconds: shutdownGraceSeconds,
            sessionInvalidator: sessionInvalidationController.map { controller in
                { @Sendable session in controller.requestInvalidation(for: session) }
            },
            uploadProgressObservationForTesting: { task in
                reportsUploadProgress && task.originalRequest?.httpMethod == "POST"
            }
        )
    }

    private func makeRedirectService(to destination: URL) -> NetworkCompatibilitySpeedTestService {
        makeService { request in
            request.compatibilityPhase == "download"
                ? .redirect(destination)
                : .defaultSuccess(for: request)
        }
    }

    private func assertServiceError(
        _ expected: CompatibilitySpeedTestError,
        operation: @escaping @Sendable () async throws -> NetworkSpeedTestResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as CompatibilitySpeedTestError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @discardableResult
    private func waitUntil(
        attempts: Int = 5_000,
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for URLProtocol state")
        return false
    }
}

private enum CompatibilityStubResponse: Sendable {
    case success(statusCode: Int, data: Data)
    case deferredSuccess(statusCode: Int, data: Data)
    case successInChunks(statusCode: Int, length: Int, chunkSize: Int)
    case successWithoutContentLength(statusCode: Int, data: Data)
    case successWithDeclaredLength(statusCode: Int, data: Data, length: Int)
    case redirect(URL)
    case delegateRedirect(URL, method: String)
    case failure(URLError.Code)
    case pending

    static func defaultSuccess(for request: URLRequest) -> Self {
        guard request.compatibilityPhase == "download" else {
            return .success(statusCode: 200, data: Data())
        }
        return .success(
            statusCode: 200,
            data: Data(count: max(0, request.compatibilityRequestedBytes))
        )
    }
}

private final class CompatibilityURLProtocolState: @unchecked Sendable {
    static let shared = CompatibilityURLProtocolState()

    private let lock = NSLock()
    private var responseHandler: (@Sendable (URLRequest) -> CompatibilityStubResponse)?
    private var recordedRequests: [URLRequest] = []
    private var recordedStops = 0
    private var recordedPending = 0
    private var deferredResponses: [@Sendable () -> Void] = []

    var requests: [URLRequest] { withLock { recordedRequests } }
    var stopCount: Int { withLock { recordedStops } }
    var pendingCount: Int { withLock { recordedPending } }
    var deferredCount: Int { withLock { deferredResponses.count } }

    func install(_ handler: @escaping @Sendable (URLRequest) -> CompatibilityStubResponse) {
        withLock { responseHandler = handler }
    }

    func reset() {
        withLock {
            responseHandler = nil
            recordedRequests = []
            recordedStops = 0
            recordedPending = 0
            deferredResponses = []
        }
    }

    func response(for request: URLRequest) -> CompatibilityStubResponse {
        let handler: (@Sendable (URLRequest) -> CompatibilityStubResponse)? = withLock {
            recordedRequests.append(request)
            return responseHandler
        }
        return handler?(request) ?? .failure(.badURL)
    }

    func markPending() {
        withLock { recordedPending += 1 }
    }

    func markStopped() {
        withLock { recordedStops += 1 }
    }

    func deferResponse(_ response: @escaping @Sendable () -> Void) {
        withLock { deferredResponses.append(response) }
    }

    func releaseDeferredResponses() {
        let responses: [@Sendable () -> Void] = withLock {
            let responses = deferredResponses
            deferredResponses = []
            return responses
        }
        responses.forEach { $0() }
    }

    @discardableResult
    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class CompatibilityStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https" || request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch CompatibilityURLProtocolState.shared.response(for: request) {
        case let .success(statusCode, data):
            let headers = ["Content-Length": String(data.count)]
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .deferredSuccess(statusCode, data):
            CompatibilityURLProtocolState.shared.deferResponse { [self] in
                sendResponse(statusCode: statusCode, data: data, headers: [
                    "Content-Length": String(data.count)
                ])
            }
        case let .successInChunks(statusCode, length, chunkSize):
            let safeLength = max(0, length)
            let safeChunkSize = max(1, chunkSize)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(safeLength)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var remaining = safeLength
            while remaining > 0 {
                let count = min(safeChunkSize, remaining)
                client?.urlProtocol(self, didLoad: Data(count: count))
                remaining -= count
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .successWithoutContentLength(statusCode, data):
            sendResponse(statusCode: statusCode, data: data, headers: [:])
        case let .successWithDeclaredLength(statusCode, data, length):
            sendResponse(
                statusCode: statusCode,
                data: data,
                headers: ["Content-Length": String(length)]
            )
        case let .redirect(destination):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .delegateRedirect(destination, method):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )!
            var redirectedRequest = URLRequest(url: destination)
            redirectedRequest.httpMethod = method
            client?.urlProtocol(
                self,
                wasRedirectedTo: redirectedRequest,
                redirectResponse: response
            )
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending:
            CompatibilityURLProtocolState.shared.markPending()
        }
    }

    private func sendResponse(
        statusCode: Int,
        data: Data,
        headers: [String: String]
    ) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        CompatibilityURLProtocolState.shared.markStopped()
    }
}

private final class CompatibilityStepClock: @unchecked Sendable {
    private let lock = NSLock()
    private let step: Double
    private var value = 0.0

    init(step: Double) {
        self.step = step
    }

    func next() -> Double {
        lock.lock()
        defer { lock.unlock() }
        value += step
        return value
    }
}

private final class ControlledCompatibilitySessionInvalidator: @unchecked Sendable {
    private let lock = NSLock()
    private weak var pendingSession: URLSession?
    private var shouldPassThrough = false
    private var recordedRequestCount = 0

    var requestCount: Int {
        withLock { recordedRequestCount }
    }

    var hasPendingSession: Bool {
        withLock { pendingSession != nil }
    }

    func requestInvalidation(for session: URLSession) {
        let passThrough: Bool = withLock {
            recordedRequestCount += 1
            if shouldPassThrough {
                return true
            }
            pendingSession = session
            return false
        }
        if passThrough {
            session.finishTasksAndInvalidate()
        }
    }

    func releasePendingInvalidationAndPassThroughFutureRequests() {
        let session: URLSession? = withLock {
            shouldPassThrough = true
            let session = pendingSession
            pendingSession = nil
            return session
        }
        session?.finishTasksAndInvalidate()
    }

    @discardableResult
    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private extension URLRequest {
    var compatibilityPhase: String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "phase" })?
            .value
    }

    var compatibilityRequestedBytes: Int {
        guard let url,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "bytes" })?
                .value,
              let bytes = Int(value) else {
            return 0
        }
        return bytes
    }
}
