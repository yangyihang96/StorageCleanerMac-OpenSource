import Darwin
import Foundation
import XCTest
import os
@testable import StorageCleanerMac

final class NetworkSpeedTestServiceTests: XCTestCase {
    private let testedAt = Date(timeIntervalSince1970: 1_900_000_000)

    func testServiceUsesOnlyFixedNetworkQualityCommandAndInjectedWatchdog() async throws {
        let expectedDate = testedAt
        let monotonicClock = MonotonicNanosecondSequence([
            1_000_000_000,
            3_500_000_000
        ])
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(.success(stdout: stableJSONFixture()))
        ])
        let service = NetworkSpeedTestService(
            runner: runner,
            watchdog: .milliseconds(17),
            now: { expectedDate },
            monotonicNanoseconds: { monotonicClock.next() }
        )

        let result = try await service.test()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.executablePath, "/usr/bin/networkQuality")
        XCTAssertEqual(commands.first?.arguments, ["-c", "-M", "20"])
        XCTAssertEqual(commands.first?.watchdog, .milliseconds(17))
        XCTAssertEqual(commands.first?.outputByteLimit, 1_048_576)
        XCTAssertEqual(result.testedAt, expectedDate)
        XCTAssertEqual(result.durationSeconds, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(result.source, .nativeSystem)
        XCTAssertEqual(result.methodVersion, "native-network-quality-v1")
    }

    func testNetworkQualityParsesStableJSONFieldsAndConvertsBitsToMbps() throws {
        let result = try NetworkSpeedTestService.parse(
            stableJSONFixture(),
            testedAt: testedAt
        )

        XCTAssertEqual(result.downloadMbps, 512, accuracy: 0.000_1)
        XCTAssertEqual(result.uploadMbps, 48, accuracy: 0.000_1)
        XCTAssertEqual(result.responsivenessRPM, 734)
        XCTAssertEqual(result.idleLatencyMilliseconds, 21, accuracy: 0.000_1)
        XCTAssertNil(result.loadedLatencyP50Milliseconds)
        XCTAssertNil(result.loadedLatencyP95Milliseconds)
        XCTAssertNil(result.jitterMilliseconds)
        XCTAssertEqual(result.interfaceName, "en0")
        XCTAssertEqual(result.source, .nativeSystem)
        XCTAssertEqual(result.methodVersion, "native-network-quality-v1")
        XCTAssertEqual(result.durationSeconds, 0)
        XCTAssertNil(result.transferredBytes)
        XCTAssertEqual(result.completeness, 4.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(result.testedAt, testedAt)
        XCTAssertEqual(
            Set(Mirror(reflecting: result).children.compactMap(\.label)),
            [
                "downloadMbps",
                "uploadMbps",
                "responsivenessRPM",
                "idleLatencyMilliseconds",
                "loadedLatencyP50Milliseconds",
                "loadedLatencyP95Milliseconds",
                "jitterMilliseconds",
                "interfaceName",
                "source",
                "methodVersion",
                "durationSeconds",
                "transferredBytes",
                "completeness",
                "testedAt"
            ]
        )
    }

    func testParsesFractionalResponsivenessFromMacOS26() throws {
        let data = try fixture("macos26-fractional-rpm.json")

        let result = try NetworkSpeedTestService.parse(
            data,
            testedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(
            try XCTUnwrap(result.responsivenessRPM),
            749.993347,
            accuracy: 0.000_001
        )
        XCTAssertEqual(result.transferredBytes, 15_000)
        XCTAssertEqual(result.source, .nativeSystem)
        XCTAssertEqual(result.methodVersion, "native-network-quality-v1")
        XCTAssertEqual(result.completeness, 4.0 / 6.0, accuracy: 0.000_001)
    }

    func testTransferredBytesRequireACompleteSafeNativeFieldPair() throws {
        var complete = stableObject()
        complete["downlink_bytes_transferred"] = 12_000
        complete["uplink_bytes_transferred"] = "3000"
        XCTAssertEqual(
            try NetworkSpeedTestService.parse(jsonData(complete)).transferredBytes,
            15_000
        )

        var incomplete = stableObject()
        incomplete["dl_bytes_transferred"] = 12_000
        XCTAssertNil(try NetworkSpeedTestService.parse(jsonData(incomplete)).transferredBytes)

        var fractional = stableObject()
        fractional["dl_bytes_transferred"] = 12_000.5
        fractional["ul_bytes_transferred"] = 3_000
        XCTAssertNil(try NetworkSpeedTestService.parse(jsonData(fractional)).transferredBytes)

        var overflow = stableObject()
        overflow["dl_bytes_transferred"] = String(UInt64.max)
        overflow["ul_bytes_transferred"] = "1"
        XCTAssertNil(try NetworkSpeedTestService.parse(jsonData(overflow)).transferredBytes)
    }

    func testNetworkQualityParsesPlistStringValuesWithTruthfulUnits() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "dl_throughput": "0.512 Gbps",
                "ul_throughput": "48000 Kbps",
                "responsiveness": "734 RPM",
                "base_rtt": "0.021 seconds",
                "interface_name": "en0",
                "server_url": "https://sensitive.example.test",
                "public_ip": "203.0.113.8"
            ],
            format: .xml,
            options: 0
        )

        let result = try NetworkSpeedTestService.parse(data, testedAt: testedAt)

        XCTAssertEqual(result.downloadMbps, 512, accuracy: 0.000_1)
        XCTAssertEqual(result.uploadMbps, 48, accuracy: 0.000_1)
        XCTAssertEqual(result.responsivenessRPM, 734)
        XCTAssertEqual(result.idleLatencyMilliseconds, 21, accuracy: 0.000_1)
        XCTAssertEqual(result.interfaceName, "en0")
        XCTAssertFalse(String(describing: result).contains("sensitive.example.test"))
        XCTAssertFalse(String(describing: result).contains("203.0.113.8"))
        let encoded = try JSONEncoder().encode(result)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(encodedText.contains("sensitive.example.test"))
        XCTAssertFalse(encodedText.contains("203.0.113.8"))
        XCTAssertEqual(try JSONDecoder().decode(NetworkSpeedTestResult.self, from: encoded), result)
    }

    func testCurrentUnitNamedFieldsAreAcceptedWithoutDoubleConversion() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "downlink_capacity_mbps": "512 Mbps",
            "uplink_capacity_mbps": 48,
            "responsiveness_rpm": "734",
            "idle_latency_ms": "21 ms",
            "interface_name": "en0"
        ])

        let result = try NetworkSpeedTestService.parse(data, testedAt: testedAt)

        XCTAssertEqual(result.downloadMbps, 512, accuracy: 0.000_1)
        XCTAssertEqual(result.uploadMbps, 48, accuracy: 0.000_1)
        XCTAssertEqual(result.responsivenessRPM, 734)
        XCTAssertEqual(result.idleLatencyMilliseconds, 21, accuracy: 0.000_1)
    }

    func testParserRejectsMalformedMissingNonFiniteNegativeAndHugeValues() throws {
        XCTAssertThrowsError(
            try NetworkSpeedTestService.parse(Data("not-json-or-plist".utf8), testedAt: testedAt)
        )

        XCTAssertThrowsError(
            try NetworkSpeedTestService.parse(
                stableJSONFixture(),
                testedAt: testedAt,
                durationSeconds: -.infinity
            )
        ) { error in
            XCTAssertEqual(error as? NetworkSpeedTestError, .invalidOutput)
        }

        var missing = stableObject()
        missing.removeValue(forKey: "base_rtt")
        XCTAssertThrowsError(
            try NetworkSpeedTestService.parse(jsonData(missing), testedAt: testedAt)
        )

        var nonFinite = stableObject()
        nonFinite["dl_throughput"] = Double.nan
        let nonFinitePlist = try PropertyListSerialization.data(
            fromPropertyList: nonFinite,
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(
            try NetworkSpeedTestService.parse(nonFinitePlist, testedAt: testedAt)
        )

        var negative = stableObject()
        negative["ul_throughput"] = -1
        XCTAssertThrowsError(
            try NetworkSpeedTestService.parse(jsonData(negative), testedAt: testedAt)
        )

        var huge = stableObject()
        huge["dl_throughput"] = "1e30 bps"
        XCTAssertThrowsError(
            try NetworkSpeedTestService.parse(jsonData(huge), testedAt: testedAt)
        )

        var byteUnit = stableObject()
        byteUnit["dl_throughput"] = "64 MBps"
        XCTAssertThrowsError(
            try NetworkSpeedTestService.parse(jsonData(byteUnit), testedAt: testedAt)
        )

        var addressAsInterface = stableObject()
        addressAsInterface["interface_name"] = "203.0.113.8"
        XCTAssertThrowsError(
            try NetworkSpeedTestService.parse(jsonData(addressAsInterface), testedAt: testedAt)
        )
    }

    func testServiceRejectsPerStreamAndCombinedOutputAboveOneMiB() async {
        let oversized = ScriptedNetworkQualityRunner(steps: [
            .output(.success(stdout: Data(repeating: 0x20, count: 1_048_577)))
        ])
        await assertServiceError(.outputTooLarge) {
            try await NetworkSpeedTestService(runner: oversized).test()
        }

        let combined = ScriptedNetworkQualityRunner(steps: [
            .output(NetworkQualityCommandOutput(
                terminationStatus: 0,
                standardOutput: Data(repeating: 0x20, count: 600_000),
                standardError: Data(repeating: 0x20, count: 600_000)
            ))
        ])
        await assertServiceError(.outputTooLarge) {
            try await NetworkSpeedTestService(runner: combined).test()
        }
    }

    func testSharedOutputAccumulatorNeverRetainsMoreThanOneMiB() async {
        let accumulator = NetworkQualityOutputAccumulator(limit: 1_048_576)

        accumulator.append(Data(repeating: 0x41, count: 700_000), to: .standardOutput)
        accumulator.append(Data(repeating: 0x42, count: 700_000), to: .standardError)
        let snapshot = accumulator.snapshot()

        XCTAssertTrue(snapshot.didExceedLimit)
        XCTAssertLessThanOrEqual(snapshot.standardOutput.count, 1_048_576)
        XCTAssertLessThanOrEqual(snapshot.standardError.count, 1_048_576)
        XCTAssertLessThanOrEqual(
            snapshot.standardOutput.count + snapshot.standardError.count,
            1_048_576
        )
    }

    func testDrainMonitorUsesInjectedDeadlineInsteadOfWaitingForeverForEOF() async {
        let monitor = NetworkQualityDrainMonitor()
        let recorder = DurationRecorder()

        let completedBeforeEOF = await monitor.wait(
            timeout: .milliseconds(125),
            sleep: { duration in
                await recorder.record(duration)
            }
        )

        XCTAssertFalse(completedBeforeEOF)
        let recordedDeadlines = await recorder.recordedDurations()
        XCTAssertEqual(recordedDeadlines, [.milliseconds(125)])

        await monitor.markFinished(.standardOutput)
        await monitor.markFinished(.standardError)
        let completedAfterEOF = await monitor.wait(
            timeout: .seconds(1),
            sleep: { duration in
                await recorder.record(duration)
            }
        )

        XCTAssertTrue(completedAfterEOF)
        let finalRecordedDeadlines = await recorder.recordedDurations()
        XCTAssertEqual(finalRecordedDeadlines, [.milliseconds(125)])

        let interruptedMonitor = NetworkQualityDrainMonitor()
        let completedAfterSleepFailure = await interruptedMonitor.wait(
            timeout: .seconds(1),
            sleep: { _ in throw CancellationError() }
        )
        XCTAssertFalse(completedAfterSleepFailure)
    }

    func testPipeDrainerCancellationFinishesWhilePipeWriterRemainsOpen() async throws {
        let pipe = Pipe()
        let accumulator = NetworkQualityOutputAccumulator(limit: 1_048_576)
        let completion = AsyncCompletionProbe()
        let drainTask = Task.detached {
            await NetworkQualityPipeDrainer.drain(
                pipe.fileHandleForReading,
                stream: .standardOutput,
                into: accumulator
            )
            await completion.markCompleted()
        }

        try pipe.fileHandleForWriting.write(contentsOf: Data("ready".utf8))
        let didConsumeData = await waitForCapturedOutput(
            accumulator,
            minimumByteCount: 5,
            timeout: .seconds(2)
        )
        XCTAssertTrue(didConsumeData)

        drainTask.cancel()
        let didFinish = await completion.wait(timeout: .seconds(2))
        XCTAssertTrue(didFinish, "Cancelling must not depend on the pipe writer reaching EOF")

        try? pipe.fileHandleForWriting.close()
        if didFinish {
            await drainTask.value
        }
    }

    func testVerifiedProcessControlChecksBSDIdentityBeforeEverySignalAndClassifiesResults() async {
        let expected = NetworkQualityProcessIdentity(
            processID: 4_321,
            startSeconds: 123,
            startMicroseconds: 456
        )
        let matchingReader = ScriptedNetworkQualityIdentityReader([
            expected,
            expected
        ])
        let successfulSystemCalls = ScriptedNetworkQualitySystemCalls([
            .success,
            .success
        ])
        let matchingControl = NetworkQualityVerifiedProcessControl(
            expectedIdentity: expected,
            identityReader: matchingReader,
            systemCalls: successfulSystemCalls
        )

        let interruptResult = await matchingControl.send(.interrupt)
        let terminateResult = await matchingControl.send(.terminate)
        XCTAssertEqual(interruptResult, .sent)
        XCTAssertEqual(terminateResult, .sent)
        let matchingIdentityRequests = await matchingReader.requestedProcessIDs()
        let matchingSignals = await successfulSystemCalls.recordedSignals()
        XCTAssertEqual(matchingIdentityRequests, [4_321, 4_321])
        XCTAssertEqual(matchingSignals, [SIGINT, SIGTERM])

        let exitedReader = ScriptedNetworkQualityIdentityReader([nil])
        let exitedSystemCalls = ScriptedNetworkQualitySystemCalls([
            .failure(ESRCH)
        ])
        let exitedControl = NetworkQualityVerifiedProcessControl(
            expectedIdentity: expected,
            identityReader: exitedReader,
            systemCalls: exitedSystemCalls
        )
        let exitedResult = await exitedControl.send(.kill)
        XCTAssertEqual(exitedResult, .alreadyExited)
        let exitedSignals = await exitedSystemCalls.recordedSignals()
        XCTAssertEqual(exitedSignals, [0], "A missing BSD identity may only be probed, never killed")

        let replacement = NetworkQualityProcessIdentity(
            processID: 4_321,
            startSeconds: 999,
            startMicroseconds: 1
        )
        let mismatchedReader = ScriptedNetworkQualityIdentityReader([replacement])
        let mismatchedSystemCalls = ScriptedNetworkQualitySystemCalls([])
        let mismatchedControl = NetworkQualityVerifiedProcessControl(
            expectedIdentity: expected,
            identityReader: mismatchedReader,
            systemCalls: mismatchedSystemCalls
        )
        let mismatchedResult = await mismatchedControl.send(.kill)
        XCTAssertEqual(mismatchedResult, .identityMismatch)
        let mismatchedSignals = await mismatchedSystemCalls.recordedSignals()
        XCTAssertTrue(mismatchedSignals.isEmpty)

        let failedReader = ScriptedNetworkQualityIdentityReader([expected])
        let failedSystemCalls = ScriptedNetworkQualitySystemCalls([
            .failure(EPERM)
        ])
        let failedControl = NetworkQualityVerifiedProcessControl(
            expectedIdentity: expected,
            identityReader: failedReader,
            systemCalls: failedSystemCalls
        )
        let failedResult = await failedControl.send(.kill)
        XCTAssertEqual(failedResult, .failed)
        let failedSignals = await failedSystemCalls.recordedSignals()
        XCTAssertEqual(failedSignals, [SIGKILL])
    }

    func testProcessConfigurationHardClampsProductionWatchdogAndWidensDrainDeadline() {
        let production = NetworkQualityProcessConfiguration.production

        XCTAssertEqual(production.maximumWatchdog, .seconds(25))
        XCTAssertEqual(production.drainCompletionGrace, .seconds(1))
        XCTAssertEqual(production.drainCancellationGrace, .seconds(1))
    }

    func testInjectedLauncherFailureDoesNotRegisterAProcessWithReaper() async {
        let launcher = TestNetworkQualityLauncher(mode: .failure)
        let reaper = NetworkQualityProcessReaper()
        let runner = NetworkQualityProcessRunner(
            launcher: launcher,
            reaper: reaper,
            configuration: .testing()
        )
        let probe = NetworkQualityRunProbe()
        let command = fixedCommand()

        await probe.start {
            try await runner.run(command)
        }

        let didFinish = await probe.wait(timeout: .seconds(2))
        let error = await probe.recordedError()
        let retainedCount = await reaper.retainedProcessCount()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(error, .failed)
        XCTAssertEqual(retainedCount, 0)
    }

    func testFoundationLauncherDoesNotStartProcessWhenTaskIsAlreadyCancelled() async {
        let startCounter = NetworkQualityProcessStartCounter()
        let launcher = NetworkQualityFoundationProcessLauncher(
            identityReader: ScriptedNetworkQualityIdentityReader([]),
            systemCalls: ScriptedNetworkQualitySystemCalls([]),
            startProcess: { _ in
                startCounter.recordStart()
                throw NetworkSpeedTestError.failed
            }
        )
        let command = fixedCommand()

        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await launcher.launch(
                    command,
                    operationID: UUID(),
                    terminationHandler: { _ in }
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        let reportedCancellation = await task.value
        XCTAssertTrue(reportedCancellation)
        XCTAssertEqual(startCounter.startCount(), 0)
    }

    func testInjectedProcessEOFAndTerminationBeforeRegistrationCompleteSuccessfully() async throws {
        let handle = TestNetworkQualityProcessHandle()
        try await handle.writeStandardOutput(Data("complete".utf8))
        let launcher = TestNetworkQualityLauncher(
            mode: .process(handle, terminateBeforeReturn: 0)
        )
        let reaper = NetworkQualityProcessReaper()
        let runner = NetworkQualityProcessRunner(
            launcher: launcher,
            reaper: reaper,
            configuration: .testing()
        )
        let probe = NetworkQualityRunProbe()
        let command = fixedCommand()

        await probe.start {
            try await runner.run(command)
        }

        let didFinish = await probe.wait(timeout: .seconds(2))
        let output = await probe.recordedOutput()
        let retainedCount = await reaper.retainedProcessCount()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(output?.terminationStatus, 0)
        XCTAssertEqual(output?.standardOutput, Data("complete".utf8))
        XCTAssertEqual(retainedCount, 0)
    }

    func testProductionWatchdogIsClampedBeforeInjectedSleepAndTimesOut() async {
        let recorder = DurationRecorder()
        let handle = TestNetworkQualityProcessHandle(terminateOnSignal: .interrupt)
        let launcher = TestNetworkQualityLauncher(mode: .process(handle, terminateBeforeReturn: nil))
        let reaper = NetworkQualityProcessReaper()
        let runner = NetworkQualityProcessRunner(
            launcher: launcher,
            reaper: reaper,
            configuration: .production,
            sleep: { duration in
                await recorder.record(duration)
            }
        )
        let probe = NetworkQualityRunProbe()
        let command = fixedCommand(watchdog: .seconds(90))

        await probe.start {
            try await runner.run(command)
        }

        let didFinish = await probe.wait(timeout: .seconds(2))
        let error = await probe.recordedError()
        let durations = await recorder.recordedDurations()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(error, .timedOut)
        XCTAssertTrue(durations.contains(.seconds(25)))
        XCTAssertFalse(durations.contains { $0 > .seconds(25) })
    }

    func testCancellationWinsRaceWithInjectedTerminationCallback() async {
        let handle = TestNetworkQualityProcessHandle()
        let launcher = TestNetworkQualityLauncher(mode: .process(handle, terminateBeforeReturn: nil))
        let reaper = NetworkQualityProcessReaper()
        let runner = NetworkQualityProcessRunner(
            launcher: launcher,
            reaper: reaper,
            configuration: .testing()
        )
        let probe = NetworkQualityRunProbe()
        let command = fixedCommand()

        await probe.start {
            try await runner.run(command)
        }
        guard await handle.waitUntilTerminationHandlerInstalled(timeout: .seconds(2)) else {
            XCTFail("Injected process did not launch")
            return
        }

        await probe.cancel()
        await handle.terminate(status: 0)

        let didFinish = await probe.wait(timeout: .seconds(2))
        let error = await probe.recordedError()
        let didRelease = await waitForReaper(reaper, retainedCount: 0, timeout: .seconds(2))
        XCTAssertTrue(didFinish)
        XCTAssertEqual(error, .cancelled)
        XCTAssertTrue(didRelease)
    }

    func testSignalFailureReportsToUIButReaperRetainsAndRetriesUntilTerminationCallback() async {
        let handle = TestNetworkQualityProcessHandle(
            signalResults: [.failed, .failed]
        )
        let launcher = TestNetworkQualityLauncher(mode: .process(handle, terminateBeforeReturn: nil))
        let reaper = NetworkQualityProcessReaper(
            retryInterval: .seconds(60),
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        let runner = NetworkQualityProcessRunner(
            launcher: launcher,
            reaper: reaper,
            configuration: .testing(maximumWatchdog: .milliseconds(1)),
            terminationSequence: NetworkQualityTerminationSequence(
                interruptGrace: .zero,
                terminateGrace: .zero,
                killGrace: .zero,
                reapGrace: .zero,
                sleep: { _ in }
            ),
            sleep: { _ in }
        )
        let probe = NetworkQualityRunProbe()
        let command = fixedCommand(watchdog: .seconds(90))

        await probe.start {
            try await runner.run(command)
        }

        let didFinish = await probe.wait(timeout: .seconds(2))
        let error = await probe.recordedError()
        let didSignalTwice = await handle.waitUntilSignalCount(2, timeout: .seconds(2))
        let signals = await handle.recordedSignals()
        let retainedCount = await reaper.retainedProcessCount()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(error, .terminationFailed)
        XCTAssertTrue(didSignalTwice)
        XCTAssertEqual(Array(signals.prefix(2)), [.interrupt, .kill])
        XCTAssertEqual(retainedCount, 1)

        await handle.terminate(status: SIGKILL)
        let didRelease = await waitForReaper(reaper, retainedCount: 0, timeout: .seconds(2))
        XCTAssertTrue(didRelease)
    }

    func testIdentityMismatchNeverSignalsReplacementAndReaperRetainsOriginalHandle() async {
        let handle = TestNetworkQualityProcessHandle(
            signalResults: [.identityMismatch, .identityMismatch]
        )
        let launcher = TestNetworkQualityLauncher(mode: .process(handle, terminateBeforeReturn: nil))
        let reaper = NetworkQualityProcessReaper(
            retryInterval: .seconds(60),
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        let runner = NetworkQualityProcessRunner(
            launcher: launcher,
            reaper: reaper,
            configuration: .testing(maximumWatchdog: .milliseconds(1)),
            terminationSequence: NetworkQualityTerminationSequence(
                interruptGrace: .zero,
                terminateGrace: .zero,
                killGrace: .zero,
                reapGrace: .zero,
                sleep: { _ in }
            ),
            sleep: { _ in }
        )
        let probe = NetworkQualityRunProbe()
        let command = fixedCommand(watchdog: .seconds(90))

        await probe.start {
            try await runner.run(command)
        }

        let didFinish = await probe.wait(timeout: .seconds(2))
        let error = await probe.recordedError()
        let didSignalTwice = await handle.waitUntilSignalCount(2, timeout: .seconds(2))
        let signals = await handle.recordedSignals()
        let retainedCount = await reaper.retainedProcessCount()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(error, .terminationFailed)
        XCTAssertTrue(didSignalTwice)
        XCTAssertEqual(Array(signals.prefix(2)), [.interrupt, .kill])
        XCTAssertEqual(retainedCount, 1)

        await handle.terminate(status: 0)
        let didRelease = await waitForReaper(reaper, retainedCount: 0, timeout: .seconds(2))
        XCTAssertTrue(didRelease)
    }

    func testSIGKILLReapTimeoutHandsLiveHandleToBackgroundReaper() async {
        let handle = TestNetworkQualityProcessHandle(
            signalResults: [.sent, .sent, .sent, .sent],
            presenceResults: [.running]
        )
        let launcher = TestNetworkQualityLauncher(mode: .process(handle, terminateBeforeReturn: nil))
        let reaper = NetworkQualityProcessReaper(
            retryInterval: .seconds(60),
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        let runner = NetworkQualityProcessRunner(
            launcher: launcher,
            reaper: reaper,
            configuration: .testing(maximumWatchdog: .milliseconds(1)),
            terminationSequence: NetworkQualityTerminationSequence(
                interruptGrace: .zero,
                terminateGrace: .zero,
                killGrace: .zero,
                reapGrace: .zero,
                sleep: { _ in }
            ),
            sleep: { _ in }
        )
        let command = fixedCommand(watchdog: .seconds(90))
        let probe = NetworkQualityRunProbe()

        await probe.start {
            try await runner.run(command)
        }

        let didFinish = await probe.wait(timeout: .seconds(2))
        let error = await probe.recordedError()
        let didSignalFourTimes = await handle.waitUntilSignalCount(4, timeout: .seconds(2))
        let signals = await handle.recordedSignals()
        let retainedCount = await reaper.retainedProcessCount()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(error, .terminationFailed)
        XCTAssertTrue(didSignalFourTimes)
        XCTAssertEqual(
            Array(signals.prefix(4)),
            [.interrupt, .terminate, .kill, .kill]
        )
        XCTAssertEqual(retainedCount, 1)

        await handle.terminate(status: SIGKILL)
        let didRelease = await waitForReaper(reaper, retainedCount: 0, timeout: .seconds(2))
        XCTAssertTrue(didRelease)
    }

    func testTerminationSequenceUsesInterruptThenTerminateThenKillOnlyIfStillRunning() async {
        let stubborn = RecordingNetworkQualityProcessControl()
        let sequence = NetworkQualityTerminationSequence(
            interruptGrace: .zero,
            terminateGrace: .zero,
            killGrace: .zero,
            reapGrace: .zero,
            sleep: { _ in }
        )

        let stubbornOutcome = await sequence.stop(stubborn)

        let stubbornSignals = await stubborn.recordedSignals()
        XCTAssertEqual(stubbornSignals, [.interrupt, .terminate, .kill])
        XCTAssertEqual(stubbornOutcome, .reapTimedOut)

        let cooperative = RecordingNetworkQualityProcessControl(stopAfter: .interrupt)
        let cooperativeOutcome = await sequence.stop(cooperative)
        let cooperativeSignals = await cooperative.recordedSignals()
        XCTAssertEqual(cooperativeSignals, [.interrupt])
        XCTAssertEqual(cooperativeOutcome, .reapTimedOut)
    }

    @MainActor
    func testStoreInitAndMissingConsentNeverStartTraffic() async {
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(.success(stdout: stableJSONFixture()))
        ])
        let store = NetworkSpeedTestStore(runner: runner)

        XCTAssertEqual(store.state, .idle)
        let initialStartCount = await runner.startCount()
        XCTAssertEqual(initialStartCount, 0)

        store.start(consentGranted: false)

        XCTAssertEqual(store.state, .consentRequired)
        XCTAssertNil(store.lastSuccessfulResult)
        let finalStartCount = await runner.startCount()
        XCTAssertEqual(finalStartCount, 0)
    }

    @MainActor
    func testStoreDoesNotStartTrafficWhileBenchmarkOwnsSharedHeavyWorkLease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activityStore = HeavyWorkActivityStore(coordinator: coordinator)
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(.success(stdout: stableJSONFixture()))
        ])
        let benchmarkLease = try await coordinator.acquire(owner: .benchmark)
        let store = NetworkSpeedTestStore(
            heavyWorkCoordinator: coordinator,
            heavyWorkActivityStore: activityStore,
            runner: runner
        )

        store.start(consentGranted: true)
        await store.waitUntilIdle()

        let startCount = await runner.startCount()
        let activeOwner = await coordinator.activeOwner
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(activeOwner, .benchmark)
        XCTAssertEqual(activityStore.activeOwner, .benchmark)
        XCTAssertNotNil(activityStore.conflictMessage)
        XCTAssertEqual(
            store.conflictMessage,
            HeavyWorkActivityStore.conflictMessage(activeOwner: .benchmark)
        )

        await coordinator.release(benchmarkLease)
    }

    @MainActor
    func testStoreKeepsNetworkLeaseUntilCancelledRunnerActuallyReturns() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activityStore = HeavyWorkActivityStore(coordinator: coordinator)
        let runner = SuspendedNetworkQualityRunner(
            output: .success(stdout: stableJSONFixture())
        )
        let store = NetworkSpeedTestStore(
            heavyWorkCoordinator: coordinator,
            heavyWorkActivityStore: activityStore,
            runner: runner
        )

        store.start(consentGranted: true)
        guard await runner.waitUntilStarted(timeout: .seconds(2)) else {
            return XCTFail("Network test did not start before timeout")
        }

        let ownerWhileRunning = await coordinator.activeOwner
        XCTAssertEqual(ownerWhileRunning, .networkTest)
        store.cancel()
        for _ in 0..<20 { await Task.yield() }

        let ownerWhileCancellationWaits = await coordinator.activeOwner
        XCTAssertEqual(ownerWhileCancellationWaits, .networkTest)
        XCTAssertEqual(store.state, .running)

        await runner.release()
        await store.waitUntilIdle()

        let ownerAfterExit = await coordinator.activeOwner
        XCTAssertNil(ownerAfterExit)
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertNil(activityStore.activeOwner)
    }

    @MainActor
    func testStoreQuarantinesRetainedNetworkProcessAfterLifecycleFailure() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activityStore = HeavyWorkActivityStore(coordinator: coordinator)
        let handle = TestNetworkQualityProcessHandle(
            signalResults: [.failed, .failed]
        )
        let launcher = TestNetworkQualityLauncher(
            mode: .process(handle, terminateBeforeReturn: nil)
        )
        let reaper = NetworkQualityProcessReaper(
            retryInterval: .seconds(60),
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        let runner = NetworkQualityProcessRunner(
            launcher: launcher,
            reaper: reaper,
            configuration: .testing(maximumWatchdog: .milliseconds(1)),
            terminationSequence: NetworkQualityTerminationSequence(
                interruptGrace: .zero,
                terminateGrace: .zero,
                killGrace: .zero,
                reapGrace: .zero,
                sleep: { _ in }
            ),
            sleep: { _ in }
        )
        let store = NetworkSpeedTestStore(
            heavyWorkCoordinator: coordinator,
            heavyWorkActivityStore: activityStore,
            runner: runner,
            watchdog: .milliseconds(1)
        )

        store.start(consentGranted: true)
        await store.waitUntilIdle()

        let retainedCount = await reaper.retainedProcessCount()
        let ownerWhileRetained = await coordinator.activeOwner
        XCTAssertEqual(retainedCount, 1)
        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(ownerWhileRetained, .networkTest)
        XCTAssertEqual(activityStore.activeOwner, .networkTest)
        do {
            let unexpectedLease = try await coordinator.acquire(owner: .benchmark)
            await coordinator.release(unexpectedLease)
            XCTFail("Expected retained network cleanup to block the benchmark")
        } catch let error as HeavyWorkCoordinator.Error {
            XCTAssertEqual(error, .busy(activeOwner: .networkTest))
        }

        await handle.terminate(status: SIGKILL)
        let clock = ContinuousClock()
        let releaseDeadline = clock.now.advanced(by: .seconds(2))
        while await reaper.retainedProcessCount() != 0,
              clock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let didReleaseReaper = await reaper.retainedProcessCount() == 0
        XCTAssertTrue(didReleaseReaper)
        for _ in 0..<1_000 {
            if await coordinator.activeOwner == nil,
               activityStore.activeOwner == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        let ownerAfterVerifiedExit = await coordinator.activeOwner
        XCTAssertNil(ownerAfterVerifiedExit)
        XCTAssertNil(activityStore.activeOwner)
        XCTAssertNil(activityStore.conflictMessage)
        XCTAssertNil(activityStore.navigationDestination)
        let benchmarkLease = try await coordinator.acquire(owner: .benchmark)
        await coordinator.release(benchmarkLease)
    }

    @MainActor
    func testSuccessfulResultReachesRootHealthStoreWithoutHealthViewObserver() async {
        let testedAt = testedAt
        let healthStore = ComputerHealthStore(
            probe: ScriptedNetworkBridgeHealthProbe()
        )
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(.success(stdout: stableJSONFixture()))
        ])
        let store = NetworkSpeedTestStore(
            runner: runner,
            now: { testedAt },
            onSuccessfulResult: { result in
                healthStore.recordNetworkSpeedResult(result)
            }
        )

        store.start(consentGranted: true)
        let didFinish = await waitForStoreToFinish(store, timeout: .seconds(2))

        XCTAssertTrue(didFinish)
        XCTAssertEqual(healthStore.menuBarSummary?.lastDownloadMbps, 512)
        XCTAssertEqual(healthStore.menuBarSummary?.lastUploadMbps, 48)
        XCTAssertEqual(healthStore.menuBarSummary?.lastSpeedTestAt, testedAt)
    }

    @MainActor
    func testStoreIsSingleFlightAndCancellationIsTruthful() async {
        let expectedDate = testedAt
        let runner = SuspendedNetworkQualityRunner(output: .success(stdout: stableJSONFixture()))
        let store = NetworkSpeedTestStore(runner: runner, now: { expectedDate })

        store.start(consentGranted: true)
        store.start(consentGranted: true)
        guard await runner.waitUntilStarted(timeout: .seconds(2)) else {
            XCTFail("Network test did not start before timeout")
            return
        }

        XCTAssertEqual(store.state, .running)
        let startCount = await runner.startCount()
        XCTAssertEqual(startCount, 1)

        store.cancel()
        XCTAssertEqual(store.state, .running, "Cancellation is not complete until the runner exits")

        await runner.release()
        let didFinish = await waitForStoreToFinish(store, timeout: .seconds(2))
        XCTAssertTrue(didFinish)
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertNil(store.lastSuccessfulResult)
    }

    @MainActor
    func testStoreMapsOfflineTimeoutAndFailureWithoutReplacingLastSuccess() async {
        let expectedDate = testedAt
        let rawOffline = Data(
            "The Internet connection appears to be offline; server 203.0.113.8 sensitive.example.test".utf8
        )
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(.success(stdout: stableJSONFixture())),
            .output(NetworkQualityCommandOutput(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: rawOffline
            )),
            .failure(.timedOut),
            .failure(.invalidOutput)
        ])
        let store = NetworkSpeedTestStore(runner: runner, now: { expectedDate })

        store.start(consentGranted: true)
        let successDidFinish = await waitForStoreToFinish(store, timeout: .seconds(2))
        XCTAssertTrue(successDidFinish)
        let successful = store.lastSuccessfulResult
        XCTAssertEqual(store.state, .succeeded)
        XCTAssertEqual(successful?.testedAt, expectedDate)

        store.start(consentGranted: true)
        let offlineDidFinish = await waitForStoreToFinish(store, timeout: .seconds(2))
        XCTAssertTrue(offlineDidFinish)
        XCTAssertEqual(store.state, .offline)
        XCTAssertEqual(store.lastSuccessfulResult, successful)

        store.start(consentGranted: true)
        let timeoutDidFinish = await waitForStoreToFinish(store, timeout: .seconds(2))
        XCTAssertTrue(timeoutDidFinish)
        XCTAssertEqual(store.state, .timedOut)
        XCTAssertEqual(store.lastSuccessfulResult, successful)

        store.start(consentGranted: true)
        let failureDidFinish = await waitForStoreToFinish(store, timeout: .seconds(2))
        XCTAssertTrue(failureDidFinish)
        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.lastSuccessfulResult, successful)
        XCTAssertFalse(String(describing: store.state).contains("203.0.113.8"))
        XCTAssertFalse(String(describing: store.state).contains("sensitive.example.test"))
    }

    func testOfflineFailureDoesNotExposeRawServerOrIPAddress() async {
        let secret = "203.0.113.8 sensitive.example.test"
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(NetworkQualityCommandOutput(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: Data("The Internet connection appears to be offline \(secret)".utf8)
            ))
        ])

        do {
            _ = try await NetworkSpeedTestService(runner: runner).test()
            XCTFail("Expected offline failure")
        } catch {
            XCTAssertEqual(error as? NetworkSpeedTestError, .offline)
            XCTAssertFalse(String(describing: error).contains("203.0.113.8"))
            XCTAssertFalse(String(describing: error).contains("sensitive.example.test"))
        }
    }

    func testServiceUnavailableEnvelopePrecedesOfflineTextAndExitCode() async throws {
        let output = NetworkQualityCommandOutput(
            terminationStatus: 1,
            standardOutput: try fixture("service-unavailable.json"),
            standardError: Data("The Internet connection appears to be offline".utf8)
        )
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(output),
            .output(output),
        ])

        await assertServiceError(.serviceUnavailable) {
            try await NetworkSpeedTestService(
                runner: runner,
                serviceUnavailableRetryDelay: .zero
            ).test()
        }
    }

    func testServiceUnavailableEnvelopeSupportsNestedStringCodeOnStandardError() async {
        let nestedEnvelope = jsonData([
            "error": [
                "domain": "NetworkQualityErrorDomain",
                "code": "1003"
            ]
        ])
        let output = NetworkQualityCommandOutput(
            terminationStatus: 7,
            standardOutput: Data(),
            standardError: nestedEnvelope
        )
        let runner = ScriptedNetworkQualityRunner(steps: [.output(output), .output(output)])

        await assertServiceError(.serviceUnavailable) {
            try await NetworkSpeedTestService(
                runner: runner,
                serviceUnavailableRetryDelay: .zero
            ).test()
        }
    }

    func testServiceUnavailableEnvelopeSupportsNativeErrorKeys() async {
        let envelope = jsonData([
            "error_domain": "NetworkQualityErrorDomain",
            "error_code": "1003"
        ])
        let output = NetworkQualityCommandOutput(
            terminationStatus: 1,
            standardOutput: envelope,
            standardError: Data()
        )
        let runner = ScriptedNetworkQualityRunner(steps: [.output(output), .output(output)])

        await assertServiceError(.serviceUnavailable) {
            try await NetworkSpeedTestService(
                runner: runner,
                serviceUnavailableRetryDelay: .zero
            ).test()
        }
    }

    func testServiceUnavailableRetriesOnceThenUsesSuccessfulResult() async throws {
        let unavailable = NetworkQualityCommandOutput(
            terminationStatus: 1,
            standardOutput: jsonData([
                "error_domain": "NetworkQualityErrorDomain",
                "error_code": 1003,
            ]),
            standardError: Data()
        )
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(unavailable),
            .output(.success(stdout: stableJSONFixture())),
        ])

        let result = try await NetworkSpeedTestService(
            runner: runner,
            serviceUnavailableRetryDelay: .zero
        ).test()
        let startCount = await runner.startCount()

        XCTAssertEqual(result.source, .nativeSystem)
        XCTAssertEqual(startCount, 2)
    }

    func testCode1003WithoutMatchingDomainStillUsesOfflineClassification() async {
        let unrelatedEnvelope = jsonData([
            "domain": "UnrelatedErrorDomain",
            "code": 1003
        ])
        let runner = ScriptedNetworkQualityRunner(steps: [
            .output(NetworkQualityCommandOutput(
                terminationStatus: 1,
                standardOutput: unrelatedEnvelope,
                standardError: Data("The Internet connection appears to be offline".utf8)
            ))
        ])

        await assertServiceError(.offline) {
            try await NetworkSpeedTestService(runner: runner).test()
        }
    }

    @MainActor
    func testCancelledLateSuccessCannotReplaceEarlierSuccessfulResult() async {
        let previousDate = Date(timeIntervalSince1970: testedAt.timeIntervalSince1970 - 600)
        let runner = SeedThenSuspendedNetworkQualityRunner(
            output: .success(stdout: stableJSONFixture())
        )
        let store = NetworkSpeedTestStore(runner: runner, now: { previousDate })

        store.start(consentGranted: true)
        let seedDidFinish = await waitForStoreToFinish(store, timeout: .seconds(2))
        XCTAssertTrue(seedDidFinish)
        guard let previous = store.lastSuccessfulResult else {
            XCTFail("Expected a complete seed result")
            return
        }

        store.start(consentGranted: true)
        guard await runner.waitUntilStarted(2, timeout: .seconds(2)) else {
            XCTFail("Late-result runner did not start before timeout")
            return
        }

        store.cancel()
        await runner.releaseSuspendedCall()
        let cancelDidFinish = await waitForStoreToFinish(store, timeout: .seconds(2))
        XCTAssertTrue(cancelDidFinish)

        XCTAssertEqual(store.state, .cancelled)
        XCTAssertEqual(store.lastSuccessfulResult, previous)
        XCTAssertEqual(store.lastSuccessfulResult?.testedAt, previousDate)
    }

    private func stableJSONFixture() -> Data {
        jsonData(stableObject())
    }

    private func fixture(_ name: String) throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NetworkQuality", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        return try Data(contentsOf: fixtureURL)
    }

    private func stableObject() -> [String: Any] {
        [
            "dl_throughput": 512_000_000,
            "ul_throughput": "48000000",
            "responsiveness": 734,
            "base_rtt": "21",
            "interface_name": "en0",
            "server_url": "https://ignored.example.test",
            "public_ip": "203.0.113.7"
        ]
    }

    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertServiceError(
        _ expected: NetworkSpeedTestError,
        operation: () async throws -> NetworkSpeedTestResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? NetworkSpeedTestError, expected)
        }
    }

    private func fixedCommand(
        watchdog: Duration = .seconds(25)
    ) -> NetworkQualityCommand {
        NetworkQualityCommand(
            executablePath: "/usr/bin/networkQuality",
            arguments: ["-c", "-M", "20"],
            watchdog: watchdog,
            outputByteLimit: 1_048_576
        )
    }

    private func waitForReaper(
        _ reaper: NetworkQualityProcessReaper,
        retainedCount: Int,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await reaper.retainedProcessCount() == retainedCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await reaper.retainedProcessCount() == retainedCount
    }

    private func waitForCapturedOutput(
        _ accumulator: NetworkQualityOutputAccumulator,
        minimumByteCount: Int,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = accumulator.snapshot()
            if snapshot.standardOutput.count >= minimumByteCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor
    private func waitForStoreToFinish(
        _ store: NetworkSpeedTestStore,
        timeout: Duration
    ) async -> Bool {
        let completion = AsyncCompletionProbe()
        let waitTask = Task { @MainActor in
            await store.waitUntilIdle()
            await completion.markCompleted()
        }
        let didComplete = await completion.wait(timeout: timeout)
        if didComplete {
            await waitTask.value
        } else {
            waitTask.cancel()
        }
        return didComplete
    }
}

private actor ScriptedNetworkQualityRunner: NetworkQualityRunning {
    enum Step: Sendable {
        case output(NetworkQualityCommandOutput)
        case failure(NetworkSpeedTestError)
    }

    private var steps: [Step]
    private var commands = [NetworkQualityCommand]()

    init(steps: [Step]) {
        self.steps = steps
    }

    func run(_ command: NetworkQualityCommand) async throws -> NetworkQualityCommandOutput {
        commands.append(command)
        guard !steps.isEmpty else { throw NetworkSpeedTestError.failed }
        switch steps.removeFirst() {
        case let .output(output):
            return output
        case let .failure(error):
            throw error
        }
    }

    func startCount() -> Int {
        commands.count
    }

    func recordedCommands() -> [NetworkQualityCommand] {
        commands
    }
}

private actor SuspendedNetworkQualityRunner: NetworkQualityRunning {
    private let output: NetworkQualityCommandOutput
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(output: NetworkQualityCommandOutput) {
        self.output = output
    }

    func run(_ command: NetworkQualityCommand) async throws -> NetworkQualityCommandOutput {
        calls += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return output
    }

    func waitUntilStarted(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while calls == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return calls > 0
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func startCount() -> Int {
        calls
    }
}

private actor SeedThenSuspendedNetworkQualityRunner: NetworkQualityRunning {
    private let output: NetworkQualityCommandOutput
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(output: NetworkQualityCommandOutput) {
        self.output = output
    }

    func run(_ command: NetworkQualityCommand) async throws -> NetworkQualityCommandOutput {
        calls += 1
        if calls > 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return output
    }

    func waitUntilStarted(_ expectedCount: Int, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while calls < expectedCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return calls >= expectedCount
    }

    func releaseSuspendedCall() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ScriptedNetworkQualityIdentityReader: NetworkQualityProcessIdentityReading {
    private var identities: [NetworkQualityProcessIdentity?]
    private var processIDs = [pid_t]()

    init(_ identities: [NetworkQualityProcessIdentity?]) {
        self.identities = identities
    }

    func identity(for processID: pid_t) -> NetworkQualityProcessIdentity? {
        processIDs.append(processID)
        guard !identities.isEmpty else { return nil }
        return identities.removeFirst()
    }

    func requestedProcessIDs() -> [pid_t] {
        processIDs
    }
}

private actor ScriptedNetworkQualitySystemCalls: NetworkQualityProcessSystemCalling {
    private var results: [NetworkQualityProcessSystemCallResult]
    private var signals = [Int32]()

    init(_ results: [NetworkQualityProcessSystemCallResult]) {
        self.results = results
    }

    func send(processID: pid_t, signal: Int32) -> NetworkQualityProcessSystemCallResult {
        signals.append(signal)
        guard !results.isEmpty else { return .failure(EINVAL) }
        return results.removeFirst()
    }

    func recordedSignals() -> [Int32] {
        signals
    }
}

private actor TestNetworkQualityProcessHandle: NetworkQualityProcessControlling {
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let terminateOnSignal: NetworkQualityTerminationSignal?
    private var signalResults: [NetworkQualitySignalResult]
    private var presenceResults: [NetworkQualityProcessPresence]
    private var terminationHandler: (@Sendable (Int32) -> Void)?
    private var signals = [NetworkQualityTerminationSignal]()
    private var didTerminate = false

    init(
        signalResults: [NetworkQualitySignalResult] = [],
        presenceResults: [NetworkQualityProcessPresence] = [],
        terminateOnSignal: NetworkQualityTerminationSignal? = nil
    ) {
        self.signalResults = signalResults
        self.presenceResults = presenceResults
        self.terminateOnSignal = terminateOnSignal
    }

    func installTerminationHandler(_ handler: @escaping @Sendable (Int32) -> Void) {
        terminationHandler = handler
    }

    func launchedProcess() -> NetworkQualityLaunchedProcess {
        NetworkQualityLaunchedProcess(
            handle: self,
            standardOutput: standardOutputPipe.fileHandleForReading,
            standardError: standardErrorPipe.fileHandleForReading,
            identityVerified: true
        )
    }

    func writeStandardOutput(_ data: Data) throws {
        try standardOutputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func presence() -> NetworkQualityProcessPresence {
        if !presenceResults.isEmpty {
            return presenceResults.removeFirst()
        }
        return didTerminate ? .alreadyExited : .running
    }

    func send(_ signal: NetworkQualityTerminationSignal) -> NetworkQualitySignalResult {
        signals.append(signal)
        let result = signalResults.isEmpty ? .sent : signalResults.removeFirst()
        if signal == terminateOnSignal, result == .sent {
            finishTermination(status: signal.systemValue)
        }
        return result
    }

    func terminate(status: Int32) {
        finishTermination(status: status)
    }

    func waitUntilTerminationHandlerInstalled(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while terminationHandler == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return terminationHandler != nil
    }

    func waitUntilSignalCount(_ count: Int, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while signals.count < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return signals.count >= count
    }

    func recordedSignals() -> [NetworkQualityTerminationSignal] {
        signals
    }

    private func finishTermination(status: Int32) {
        guard !didTerminate else { return }
        didTerminate = true
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()
        terminationHandler?(status)
    }
}

private actor TestNetworkQualityLauncher: NetworkQualityProcessLaunching {
    enum Mode: Sendable {
        case failure
        case process(TestNetworkQualityProcessHandle, terminateBeforeReturn: Int32?)
    }

    private let mode: Mode
    private var commands = [NetworkQualityCommand]()

    init(mode: Mode) {
        self.mode = mode
    }

    func launch(
        _ command: NetworkQualityCommand,
        operationID: UUID,
        terminationHandler: @escaping @Sendable (Int32) -> Void
    ) async throws -> NetworkQualityLaunchedProcess {
        commands.append(command)
        switch mode {
        case .failure:
            throw NetworkSpeedTestError.failed
        case let .process(handle, status):
            await handle.installTerminationHandler(terminationHandler)
            if let status {
                await handle.terminate(status: status)
            }
            return await handle.launchedProcess()
        }
    }
}

private actor NetworkQualityRunProbe {
    enum Outcome: Sendable {
        case success(NetworkQualityCommandOutput)
        case failure(NetworkSpeedTestError)
    }

    private var task: Task<Void, Never>?
    private var outcome: Outcome?

    func start(
        _ operation: @escaping @Sendable () async throws -> NetworkQualityCommandOutput
    ) {
        guard task == nil else { return }
        task = Task {
            do {
                outcome = .success(try await operation())
            } catch is NetworkSpeedTestCleanupPendingError {
                outcome = .failure(.terminationFailed)
            } catch let error as NetworkSpeedTestError {
                outcome = .failure(error)
            } catch is CancellationError {
                outcome = .failure(.cancelled)
            } catch {
                outcome = .failure(.failed)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while outcome == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return outcome != nil
    }

    func recordedError() -> NetworkSpeedTestError? {
        guard case let .failure(error) = outcome else { return nil }
        return error
    }

    func recordedOutput() -> NetworkQualityCommandOutput? {
        guard case let .success(output) = outcome else { return nil }
        return output
    }
}

private actor RecordingNetworkQualityProcessControl: NetworkQualityProcessControlling {
    private let stopAfter: NetworkQualityTerminationSignal?
    private var running = true
    private var signals = [NetworkQualityTerminationSignal]()

    init(stopAfter: NetworkQualityTerminationSignal? = nil) {
        self.stopAfter = stopAfter
    }

    func presence() -> NetworkQualityProcessPresence {
        running ? .running : .alreadyExited
    }

    func send(_ signal: NetworkQualityTerminationSignal) -> NetworkQualitySignalResult {
        guard running else { return .alreadyExited }
        signals.append(signal)
        if signal == stopAfter {
            running = false
        }
        return .sent
    }

    func recordedSignals() -> [NetworkQualityTerminationSignal] {
        signals
    }
}

private actor AsyncCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !completed, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return completed
    }
}

private final class NetworkQualityProcessStartCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func recordStart() {
        count.withLock { $0 += 1 }
    }

    func startCount() -> Int {
        count.withLock { $0 }
    }
}

private actor DurationRecorder {
    private var durations = [Duration]()

    func record(_ duration: Duration) {
        durations.append(duration)
    }

    func recordedDurations() -> [Duration] {
        durations
    }
}

private final class MonotonicNanosecondSequence: Sendable {
    private let values: OSAllocatedUnfairLock<[UInt64]>

    init(_ values: [UInt64]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    func next() -> UInt64 {
        values.withLock { values in
            guard let first = values.first else { return 0 }
            if values.count > 1 {
                values.removeFirst()
            }
            return first
        }
    }
}

private extension NetworkQualityCommandOutput {
    static func success(stdout: Data) -> Self {
        Self(
            terminationStatus: 0,
            standardOutput: stdout,
            standardError: Data()
        )
    }
}

private struct ScriptedNetworkBridgeHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        throw CancellationError()
    }
}
