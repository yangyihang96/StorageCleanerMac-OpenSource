import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkIOTests: XCTestCase {
    func testSystemMetalDriverCompletesTestingWorkloadWhenAvailable() async throws {
        do {
            let result = try await MetalBenchmarkKernel(configuration: .testing)
                .run(profile: .quick)
            XCTAssertGreaterThan(result.sample.value, 0)
            XCTAssertGreaterThan(result.sample.checksum, 0)
            XCTAssertFalse(result.ranOnMainThread)
        } catch BenchmarkKernelError.unavailable {
            throw XCTSkip("Metal is unavailable in this environment")
        }
    }

    func testSystemMetal3DDriverCompletesDeterministicRenderWhenAvailable() async throws {
        do {
            let result = try await Metal3DBenchmarkKernel(configuration: .testing).run()
            XCTAssertGreaterThan(result.sample.value, 0)
            XCTAssertGreaterThan(result.sample.checksum, 0)
            XCTAssertEqual(result.triangleCount, 256 * 3 * 12)
            XCTAssertEqual(result.resolution.width, 320)
            XCTAssertEqual(result.resolution.height, 180)
            XCTAssertFalse(result.ranOnMainThread)
        } catch BenchmarkKernelError.unavailable {
            throw XCTSkip("Metal is unavailable in this environment")
        }
    }

    func testSystemMetal3DStandardWorkloadWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RELEASE_BENCHMARK_VALIDATION"] == "1"
        else {
            throw XCTSkip("Only run during explicit optimized benchmark validation")
        }
        do {
            let result = try await Metal3DBenchmarkKernel().run()
            XCTAssertGreaterThan(result.sample.value, 0)
            XCTAssertGreaterThan(result.sample.elapsedSeconds, 0.05)
            XCTAssertLessThanOrEqual(
                result.sample.elapsedSeconds,
                Metal3DBenchmarkKernel.maximumElapsedSeconds
            )
            XCTAssertEqual(result.triangleCount, 262_144 * 600 * 12)
            XCTAssertFalse(result.ranOnMainThread)
        } catch BenchmarkKernelError.unavailable {
            throw XCTSkip("Metal is unavailable in this environment")
        }
    }

    func testMetal3DUsesGPUTimeAndAlwaysTearsDown() async throws {
        let recorder = BenchmarkEventRecorder()
        let driver = FakeMetal3DBenchmarkDriver(recorder: recorder, gpuElapsedSeconds: 0.25)
        let kernel = Metal3DBenchmarkKernel(
            configuration: .testing,
            driverFactory: { driver }
        )

        let result = try await kernel.run()

        XCTAssertEqual(result.sample.elapsedSeconds, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(result.triangleCount, 256 * 3 * 12)
        XCTAssertEqual(result.sample.value, 0.036_864, accuracy: 0.000_001)
        XCTAssertEqual(result.sample.checksum, FakeMetal3DBenchmarkDriver.validChecksum)
        let events = await recorder.snapshot()
        XCTAssertEqual(events, [.prepare, .warmUp, .execute, .validate, .tearDown])
    }

    func testSystemRunnerRoutesStandardGPUToMetal3DInsteadOfLegacyCompute() async throws {
        let legacyRecorder = BenchmarkEventRecorder()
        let renderRecorder = BenchmarkEventRecorder()
        let legacyClock = ManualBenchmarkKernelClock()
        let legacyDriver = FakeMetalBenchmarkDriver(
            clock: legacyClock,
            recorder: legacyRecorder
        )
        let renderDriver = FakeMetal3DBenchmarkDriver(
            recorder: renderRecorder,
            gpuElapsedSeconds: 0.25
        )
        let runner = SystemMacBenchmarkWorkloadRunner(
            metalKernel: MetalBenchmarkKernel(
                configuration: .testing,
                clock: legacyClock,
                driverFactory: { legacyDriver }
            ),
            metal3DKernel: Metal3DBenchmarkKernel(
                configuration: .testing,
                driverFactory: { renderDriver }
            )
        )

        let sample = try await runner.runGPU(profile: .standard)
        let legacyEvents = await legacyRecorder.snapshot()
        let renderEvents = await renderRecorder.snapshot()

        XCTAssertEqual(sample.checksum, FakeMetal3DBenchmarkDriver.validChecksum)
        XCTAssertTrue(legacyEvents.isEmpty)
        XCTAssertEqual(
            renderEvents,
            [.prepare, .warmUp, .execute, .validate, .tearDown]
        )
    }

    func testSystemDiskDriverUsesAndRemovesExclusiveTemporaryFile() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("BenchmarkTemporary", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: temporary
        )

        let result = try await kernel.run(profile: .quick)

        XCTAssertGreaterThan(result.writeSample.value, 0)
        XCTAssertGreaterThan(result.readSample.value, 0)
        XCTAssertEqual(result.writeSample.checksum, result.readSample.checksum)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMetalExcludesPreparationWarmupAndValidationFromTimedMetric() async throws {
        let clock = ManualBenchmarkKernelClock()
        let recorder = BenchmarkEventRecorder()
        let driver = FakeMetalBenchmarkDriver(
            clock: clock,
            recorder: recorder,
            prepareNanoseconds: 200_000_000,
            warmupNanoseconds: 300_000_000,
            executeNanoseconds: 500_000_000,
            validationNanoseconds: 400_000_000
        )
        let kernel = MetalBenchmarkKernel(
            configuration: .testing,
            clock: clock,
            driverFactory: { driver }
        )

        let result = try await kernel.run(profile: .quick)

        XCTAssertEqual(result.sample.elapsedSeconds, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.operationCount, 32_768 * 8 * 8 * 1)
        XCTAssertEqual(result.sample.checksum, FakeMetalBenchmarkDriver.validChecksum)
        XCTAssertFalse(result.ranOnMainThread)
        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            [.prepare, .warmUp, .execute, .validate, .tearDown]
        )
    }

    func testMetalCommandFailurePublishesNoMetricAndTearsDown() async {
        let clock = ManualBenchmarkKernelClock()
        let recorder = BenchmarkEventRecorder()
        let driver = FakeMetalBenchmarkDriver(
            clock: clock,
            recorder: recorder,
            executeError: BenchmarkKernelError.systemFailure
        )
        let kernel = MetalBenchmarkKernel(
            configuration: .testing,
            clock: clock,
            driverFactory: { driver }
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .systemFailure)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            [.prepare, .warmUp, .execute, .tearDown]
        )
    }

    func testMetalChecksumMismatchFailsAndTearsDown() async {
        let clock = ManualBenchmarkKernelClock()
        let recorder = BenchmarkEventRecorder()
        let driver = FakeMetalBenchmarkDriver(
            clock: clock,
            recorder: recorder,
            validationError: BenchmarkKernelError.checksumMismatch
        )
        let kernel = MetalBenchmarkKernel(
            configuration: .testing,
            clock: clock,
            driverFactory: { driver }
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .checksumMismatch)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testMetalCancellationWaitsForDriverCleanup() async {
        let clock = ManualBenchmarkKernelClock()
        let recorder = BenchmarkEventRecorder()
        let driver = FakeMetalBenchmarkDriver(
            clock: clock,
            recorder: recorder,
            waitsForCancellation: true
        )
        let kernel = MetalBenchmarkKernel(
            configuration: .testing,
            clock: clock,
            driverFactory: { driver }
        )
        let task = Task { try await kernel.run(profile: .quick) }

        await recorder.wait(until: .execute)
        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testMetalCancellationDuringTearDownCannotPublishSuccess() async {
        let clock = ManualBenchmarkKernelClock()
        let recorder = BenchmarkEventRecorder()
        let tearDownGate = BenchmarkAsyncGate()
        let driver = FakeMetalBenchmarkDriver(
            clock: clock,
            recorder: recorder,
            tearDownGate: tearDownGate
        )
        let kernel = MetalBenchmarkKernel(
            configuration: .testing,
            clock: clock,
            driverFactory: { driver }
        )
        let task = Task { try await kernel.run(profile: .quick) }

        await recorder.wait(until: .tearDown)
        task.cancel()
        await tearDownGate.open()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testMetalCPUReferenceMatchesShaderForZeroInput() {
        XCTAssertEqual(
            metalBenchmarkReferenceMix(0),
            1_013_904_223
        )
    }

    func testMetalCPUReferenceValidationChecksCancellationDuringScanning() {
        let baseSeed: UInt32 = 0xA341_316C
        let rounds = 1
        var state = baseSeed
        let values = (0..<8_192).map { index in
            var shifted = state &+ UInt32(truncatingIfNeeded: index)
            shifted ^= shifted << 13
            shifted ^= shifted >> 17
            shifted ^= shifted << 5
            state = shifted
            var expected = state
            for _ in 0..<rounds {
                expected = metalBenchmarkReferenceMix(expected)
            }
            return expected
        }
        var cancellationCheckCount = 0

        XCTAssertThrowsError(try values.withUnsafeBufferPointer { buffer in
                try metalBenchmarkValidatedChecksum(
                    values: buffer.baseAddress!,
                    workload: MetalBenchmarkWorkload(
                        elementCount: values.count,
                        roundsPerElement: rounds,
                        operationsPerRound: MetalBenchmarkKernel.operationsPerRound,
                        dispatchPassCount: 1
                    ),
                    baseSeed: baseSeed,
                    checksumSeed: 0xCBF2_9CE4_8422_2325,
                    cancellationCheck: {
                        cancellationCheckCount += 1
                        if cancellationCheckCount == 2 {
                            throw CancellationError()
                        }
                    }
                )
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationCheckCount, 2)
    }

    func testMetalValidationSamplesBoundedPositionsAndHashesEveryOutput() throws {
        let baseSeed: UInt32 = 0xA341_316C
        let rounds = 4
        let elementCount = MetalBenchmarkKernel.maximumValidationSampleCount * 4
        var state = baseSeed
        var values = (0..<elementCount).map { index in
            var shifted = state &+ UInt32(truncatingIfNeeded: index)
            shifted ^= shifted << 13
            shifted ^= shifted >> 17
            shifted ^= shifted << 5
            state = shifted
            var expected = state
            for _ in 0..<rounds {
                expected = metalBenchmarkReferenceMix(expected)
            }
            return expected
        }
        let workload = MetalBenchmarkWorkload(
            elementCount: values.count,
            roundsPerElement: rounds,
            operationsPerRound: MetalBenchmarkKernel.operationsPerRound,
            dispatchPassCount: 1
        )
        let checksumSeed: UInt64 = 0xCBF2_9CE4_8422_2325

        let originalChecksum = try values.withUnsafeBufferPointer { buffer in
            try metalBenchmarkValidatedChecksum(
                values: buffer.baseAddress!,
                workload: workload,
                baseSeed: baseSeed,
                checksumSeed: checksumSeed
            )
        }

        values[1] ^= 1
        let unsampledMutationChecksum = try values.withUnsafeBufferPointer { buffer in
            try metalBenchmarkValidatedChecksum(
                values: buffer.baseAddress!,
                workload: workload,
                baseSeed: baseSeed,
                checksumSeed: checksumSeed
            )
        }
        XCTAssertNotEqual(unsampledMutationChecksum, originalChecksum)

        values[1] ^= 1
        values[4] ^= 1
        XCTAssertThrowsError(try values.withUnsafeBufferPointer { buffer in
            try metalBenchmarkValidatedChecksum(
                values: buffer.baseAddress!,
                workload: workload,
                baseSeed: baseSeed,
                checksumSeed: checksumSeed
            )
        }) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .checksumMismatch)
        }
    }

    func testMetalRejectsExecutionPastWholeRunLimitAfterCleanup() async {
        let clock = ManualBenchmarkKernelClock()
        let recorder = BenchmarkEventRecorder()
        let driver = FakeMetalBenchmarkDriver(
            clock: clock,
            recorder: recorder,
            executeNanoseconds: 3_000_000_000
        )
        let kernel = MetalBenchmarkKernel(
            configuration: .testing,
            clock: clock,
            driverFactory: { driver }
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testStandardDiskProfilesUseBoundedPrivateFileSizes() {
        let quick = DiskBenchmarkKernel.Configuration.standard.limits(for: .quick)
        let full = DiskBenchmarkKernel.Configuration.standard.limits(for: .full)

        XCTAssertEqual(quick.fileBytes, 256 * 1_024 * 1_024)
        XCTAssertEqual(full.fileBytes, 768 * 1_024 * 1_024)
        XCTAssertEqual(quick.writePassCount, 3)
        XCTAssertEqual(full.writePassCount, 3)
        XCTAssertEqual(
            DiskBenchmarkKernel.requiredCapacity(forFileBytes: quick.fileBytes),
            Int64(quick.fileBytes * 2) + 2 * 1_024 * 1_024 * 1_024
        )
        XCTAssertEqual(
            DiskBenchmarkKernel.requiredCapacity(forFileBytes: full.fileBytes),
            Int64(full.fileBytes * 2) + 2 * 1_024 * 1_024 * 1_024
        )
    }

    func testStandardMetalProfilesUseStabilizedBoundedWorkloads() {
        let quick = MetalBenchmarkKernel.Configuration.standard.limits(for: .quick)
        let full = MetalBenchmarkKernel.Configuration.standard.limits(for: .full)

        XCTAssertEqual(quick.elementCount, 524_288)
        XCTAssertEqual(full.elementCount, 2_097_152)
        XCTAssertEqual(quick.roundsPerElement, 128)
        XCTAssertEqual(full.roundsPerElement, 256)
        XCTAssertEqual(quick.dispatchPassCount, 1_024)
        XCTAssertEqual(full.dispatchPassCount, 512)
        XCTAssertLessThanOrEqual(
            quick.roundsPerElement,
            MetalBenchmarkKernel.maximumRoundsPerElement
        )
        XCTAssertLessThanOrEqual(
            quick.dispatchPassCount,
            MetalBenchmarkKernel.maximumDispatchPassCount
        )
        XCTAssertLessThanOrEqual(
            full.dispatchPassCount,
            MetalBenchmarkKernel.maximumDispatchPassCount
        )
        XCTAssertLessThanOrEqual(
            full.roundsPerElement,
            MetalBenchmarkKernel.maximumRoundsPerElement
        )
    }

    func testDiskSynchronizesBeforeReadAndAlwaysRemovesPrivateFile() async throws {
        let clock = ManualBenchmarkKernelClock(stepNanoseconds: 10_000_000)
        let recorder = BenchmarkEventRecorder()
        let manager = FakeDiskBenchmarkFileManager(
            recorder: recorder,
            availableCapacity: Int64.max
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
            clock: clock,
            fileManager: manager
        )

        let result = try await kernel.run(profile: .quick)
        let events = await recorder.snapshot()

        XCTAssertGreaterThan(result.writeSample.value, 0)
        XCTAssertGreaterThan(result.readSample.value, 0)
        XCTAssertEqual(result.writeSample.checksum, result.readSample.checksum)
        XCTAssertFalse(result.ranOnMainThread)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .synchronize)),
                          try XCTUnwrap(events.firstIndex(of: .read)))
        XCTAssertEqual(events.suffix(2), [.close, .remove])
        let createdURLs = await manager.createdURLs
        let removedURLs = await manager.removedURLs
        XCTAssertEqual(createdURLs.count, 1)
        XCTAssertEqual(removedURLs, createdURLs)
        XCTAssertTrue(createdURLs[0].lastPathComponent.hasPrefix("benchmark-"))
        XCTAssertTrue(createdURLs[0].lastPathComponent.hasSuffix(".tmp"))
    }

    func testDiskWritePassesFlushEachOverwrittenPass() async throws {
        let recorder = BenchmarkEventRecorder()
        let manager = FakeDiskBenchmarkFileManager(
            recorder: recorder,
            availableCapacity: Int64.max
        )
        let limits = DiskBenchmarkKernel.Limits(
            fileBytes: 16 * 1_024,
            blockBytes: 4 * 1_024,
            writePassCount: 2,
            maximumElapsedSeconds: 2
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .init(quick: limits, full: limits),
            rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
            fileManager: manager
        )

        _ = try await kernel.run(profile: .quick)
        let events = await recorder.snapshot()

        XCTAssertEqual(events.filter { $0 == .write }.count, 8)
        XCTAssertEqual(events.filter { $0 == .rewind }.count, 2)
        let synchronizeIndices = events.indices.filter {
            events[$0] == .synchronize
        }
        XCTAssertEqual(synchronizeIndices.count, 2)
        XCTAssertLessThan(
            try XCTUnwrap(events.firstIndex(of: .write)),
            synchronizeIndices[0]
        )
        XCTAssertLessThan(
            synchronizeIndices[0],
            try XCTUnwrap(events.lastIndex(of: .write))
        )
        XCTAssertLessThan(
            try XCTUnwrap(events.lastIndex(of: .write)),
            synchronizeIndices[1]
        )
    }

    func testDiskWriteMetricIncludesMandatoryDurabilityFlush() async throws {
        let clock = ManualBenchmarkKernelClock(stepNanoseconds: 1)
        let manager = FakeDiskBenchmarkFileManager(
            recorder: BenchmarkEventRecorder(),
            availableCapacity: Int64.max,
            clock: clock,
            synchronizeNanoseconds: 500_000_000,
            readNanoseconds: 100_000_000
        )
        let limits = DiskBenchmarkKernel.Limits(
            fileBytes: 4 * 1_024,
            blockBytes: 4 * 1_024,
            writePassCount: 1,
            maximumElapsedSeconds: 2
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .init(quick: limits, full: limits),
            rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
            clock: clock,
            fileManager: manager
        )

        let result = try await kernel.run(profile: .quick)

        XCTAssertGreaterThanOrEqual(result.writeSample.elapsedSeconds, 0.5)
        XCTAssertLessThan(result.writeSample.elapsedSeconds, 0.51)
        XCTAssertGreaterThanOrEqual(result.readSample.elapsedSeconds, 0.1)
    }

    func testDiskChecksumMismatchStillClosesAndRemovesFile() async {
        let recorder = BenchmarkEventRecorder()
        let manager = FakeDiskBenchmarkFileManager(
            recorder: recorder,
            availableCapacity: Int64.max,
            corruptRead: true
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
            fileManager: manager
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .checksumMismatch)
        }
        let events = await recorder.snapshot()
        let removedURLs = await manager.removedURLs
        let createdURLs = await manager.createdURLs
        XCTAssertEqual(events.suffix(2), [.close, .remove])
        XCTAssertEqual(removedURLs, createdURLs)
    }

    func testDiskFailureAndCancellationBothRemoveFile() async {
        for failure in [FakeDiskFailure.write, .synchronize, .read, .cancelDuringWrite] {
            let recorder = BenchmarkEventRecorder()
            let manager = FakeDiskBenchmarkFileManager(
                recorder: recorder,
                availableCapacity: Int64.max,
                failure: failure
            )
            let kernel = DiskBenchmarkKernel(
                configuration: .testing,
                rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
                fileManager: manager
            )

            await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick))
            let events = await recorder.snapshot()
            let removedURLs = await manager.removedURLs
            let createdURLs = await manager.createdURLs
            XCTAssertEqual(events.suffix(2), [.close, .remove])
            XCTAssertEqual(removedURLs, createdURLs)
        }
    }

    func testDiskCapacityGateRunsBeforeCreatingAFile() async {
        let manager = FakeDiskBenchmarkFileManager(
            recorder: BenchmarkEventRecorder(),
            availableCapacity: 1
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
            fileManager: manager
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
        }
        let createdURLs = await manager.createdURLs
        let removedURLs = await manager.removedURLs
        XCTAssertTrue(createdURLs.isEmpty)
        XCTAssertTrue(removedURLs.isEmpty)
    }

    func testDiskTimeoutAfterCreationStillRemovesFile() async {
        let clock = ManualBenchmarkKernelClock(stepNanoseconds: 500_000_000)
        let recorder = BenchmarkEventRecorder()
        let manager = FakeDiskBenchmarkFileManager(
            recorder: recorder,
            availableCapacity: Int64.max
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
            clock: clock,
            fileManager: manager
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.suffix(2), [.close, .remove])
    }

    func testDiskCancellationDuringRemovalCannotPublishSuccess() async {
        let recorder = BenchmarkEventRecorder()
        let removalGate = BenchmarkAsyncGate()
        let manager = FakeDiskBenchmarkFileManager(
            recorder: recorder,
            availableCapacity: Int64.max,
            removalGate: removalGate
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
            fileManager: manager
        )
        let task = Task { try await kernel.run(profile: .quick) }

        await recorder.wait(until: .remove)
        task.cancel()
        await removalGate.open()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testDiskAccumulatesPartialReadsUntilTheExpectedBlockIsComplete() async throws {
        let recorder = BenchmarkEventRecorder()
        let manager = FakeDiskBenchmarkFileManager(
            recorder: recorder,
            availableCapacity: Int64.max,
            maximumReadChunkBytes: 1_024
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: URL(fileURLWithPath: "/private/fake/BenchmarkTemporary"),
            fileManager: manager
        )

        let result = try await kernel.run(profile: .quick)

        XCTAssertGreaterThan(result.readSample.value, 0)
        let events = await recorder.snapshot()
        XCTAssertGreaterThan(events.filter { $0 == .read }.count, 8)
    }

    func testSystemDiskManagerRejectsFinalDirectorySymlinkBeforeChangingTarget() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = temporary.appendingPathComponent("target", isDirectory: true)
        let root = temporary.appendingPathComponent("BenchmarkTemporary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let originalPermissions = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
                as? NSNumber)?.intValue
        )
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: root
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick))

        let finalPermissions = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
                as? NSNumber)?.intValue
        )
        XCTAssertEqual(finalPermissions, originalPermissions)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty
        )
    }

    func testSystemDiskManagerRejectsSymlinkInParentPathWithoutCreatingOutsideRoot() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        let alias = temporary.appendingPathComponent("alias", isDirectory: true)
        let root = alias.appendingPathComponent("BenchmarkTemporary", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: root
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("BenchmarkTemporary").path
            )
        )
    }

    func testSystemDiskManagerRejectsNonBenchmarkApplicationSupportRoot() async throws {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        let forbiddenParent = applicationSupport.appendingPathComponent(
            "StorageCleanerMacTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = forbiddenParent.appendingPathComponent(
            "BenchmarkTemporary",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: forbiddenParent) }
        let kernel = DiskBenchmarkKernel(
            configuration: .testing,
            rootDirectory: root
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick))

        XCTAssertFalse(FileManager.default.fileExists(atPath: forbiddenParent.path))
    }

    func testOrphanCleanupPropagatesCancellationBeforeDeletingRemainingCandidates() async {
        let recorder = BenchmarkEventRecorder()
        let removalGate = BenchmarkAsyncGate()
        let root = URL(fileURLWithPath: "/private/fake/BenchmarkTemporary")
        let oldDate = Date(timeIntervalSince1970: 1)
        let candidates = (0..<3).map { index in
            DiskBenchmarkOrphanCandidate(
                url: root.appendingPathComponent("benchmark-\(index).tmp"),
                modificationDate: oldDate,
                isRegularFile: true,
                isSymbolicLink: false
            )
        }
        let manager = FakeDiskBenchmarkFileManager(
            recorder: recorder,
            availableCapacity: Int64.max,
            removalGate: removalGate,
            orphanCandidates: candidates
        )
        let kernel = DiskBenchmarkKernel(
            rootDirectory: root,
            fileManager: manager
        )
        let task = Task {
            try await kernel.cleanupOrphans(
                olderThan: 10,
                now: Date(timeIntervalSince1970: 100)
            )
        }

        await recorder.wait(until: .remove)
        task.cancel()
        await removalGate.open()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let removedURLs = await manager.removedURLs
        XCTAssertEqual(removedURLs.count, 1)
    }

    func testStartupOrphanCleanupOnlyRemovesOldRegularBenchmarkFilesInRoot() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temporary.appendingPathComponent("BenchmarkTemporary", isDirectory: true)
        let sibling = temporary.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let old = root.appendingPathComponent("benchmark-old.tmp")
        let young = root.appendingPathComponent("benchmark-young.tmp")
        let unrelated = root.appendingPathComponent("notes.txt")
        let outside = sibling.appendingPathComponent("benchmark-outside.tmp")
        let symlink = root.appendingPathComponent("benchmark-link.tmp")
        for url in [old, young, unrelated, outside] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([1])))
        }
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let now = Date(timeIntervalSince1970: 10_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3_600)],
            ofItemAtPath: old.path
        )

        let kernel = DiskBenchmarkKernel(rootDirectory: root)
        let removed = try await kernel.cleanupOrphans(
            olderThan: 600,
            now: now
        )

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: young.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: symlink.path))
    }
}

private enum BenchmarkEvent: Equatable, Sendable {
    case prepare
    case warmUp
    case execute
    case validate
    case tearDown
    case createDirectory
    case capacity
    case create
    case disableCache
    case write
    case synchronize
    case rewind
    case read
    case close
    case remove
}

private actor BenchmarkEventRecorder {
    private var events: [BenchmarkEvent] = []

    func append(_ event: BenchmarkEvent) {
        events.append(event)
    }

    func snapshot() -> [BenchmarkEvent] {
        events
    }

    func wait(until event: BenchmarkEvent) async {
        while !events.contains(event) {
            await Task.yield()
        }
    }
}

private actor BenchmarkAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class ManualBenchmarkKernelClock: BenchmarkKernelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    private let stepNanoseconds: UInt64

    init(stepNanoseconds: UInt64 = 0) {
        self.stepNanoseconds = stepNanoseconds
    }

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value &+= stepNanoseconds
        return current
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}

private actor FakeMetal3DBenchmarkDriver: Metal3DBenchmarkDriving {
    static let validChecksum: UInt64 = 0x3D00_C0DE_F00D_BAAD

    private let recorder: BenchmarkEventRecorder
    private let gpuElapsedSeconds: Double

    init(recorder: BenchmarkEventRecorder, gpuElapsedSeconds: Double) {
        self.recorder = recorder
        self.gpuElapsedSeconds = gpuElapsedSeconds
    }

    func prepare(workload: Metal3DBenchmarkWorkload) async throws {
        await recorder.append(.prepare)
        XCTAssertEqual(workload.trianglesPerInstance, 12)
        XCTAssertGreaterThan(workload.instanceCount, 0)
        XCTAssertGreaterThan(workload.frameCount, 0)
    }

    func warmUp() async throws {
        await recorder.append(.warmUp)
    }

    func execute() async throws -> Metal3DBenchmarkExecution {
        await recorder.append(.execute)
        return Metal3DBenchmarkExecution(
            gpuElapsedSeconds: gpuElapsedSeconds,
            ranOnMainThread: benchmarkKernelIsMainThread()
        )
    }

    func validate() async throws -> UInt64 {
        await recorder.append(.validate)
        return Self.validChecksum
    }

    func tearDown() async {
        await recorder.append(.tearDown)
    }
}

private actor FakeMetalBenchmarkDriver: MetalBenchmarkDriving {
    static let validChecksum: UInt64 = 0xC0FF_EE00_D15C_A11A

    private let clock: ManualBenchmarkKernelClock
    private let recorder: BenchmarkEventRecorder
    private let prepareNanoseconds: UInt64
    private let warmupNanoseconds: UInt64
    private let executeNanoseconds: UInt64
    private let validationNanoseconds: UInt64
    private let executeError: Error?
    private let validationError: Error?
    private let waitsForCancellation: Bool
    private let tearDownGate: BenchmarkAsyncGate?

    init(
        clock: ManualBenchmarkKernelClock,
        recorder: BenchmarkEventRecorder,
        prepareNanoseconds: UInt64 = 0,
        warmupNanoseconds: UInt64 = 0,
        executeNanoseconds: UInt64 = 100_000_000,
        validationNanoseconds: UInt64 = 0,
        executeError: Error? = nil,
        validationError: Error? = nil,
        waitsForCancellation: Bool = false,
        tearDownGate: BenchmarkAsyncGate? = nil
    ) {
        self.clock = clock
        self.recorder = recorder
        self.prepareNanoseconds = prepareNanoseconds
        self.warmupNanoseconds = warmupNanoseconds
        self.executeNanoseconds = executeNanoseconds
        self.validationNanoseconds = validationNanoseconds
        self.executeError = executeError
        self.validationError = validationError
        self.waitsForCancellation = waitsForCancellation
        self.tearDownGate = tearDownGate
    }

    func prepare(workload: MetalBenchmarkWorkload) async throws {
        await recorder.append(.prepare)
        XCTAssertGreaterThan(workload.elementCount, 0)
        clock.advance(by: prepareNanoseconds)
    }

    func warmUp() async throws {
        await recorder.append(.warmUp)
        clock.advance(by: warmupNanoseconds)
    }

    func execute() async throws -> Bool {
        await recorder.append(.execute)
        if waitsForCancellation {
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        if let executeError { throw executeError }
        clock.advance(by: executeNanoseconds)
        return benchmarkKernelIsMainThread()
    }

    func validate() async throws -> UInt64 {
        await recorder.append(.validate)
        if let validationError { throw validationError }
        clock.advance(by: validationNanoseconds)
        return Self.validChecksum
    }

    func tearDown() async {
        await recorder.append(.tearDown)
        await tearDownGate?.wait()
    }
}

private enum FakeDiskFailure: Sendable {
    case write
    case synchronize
    case read
    case cancelDuringWrite
}

private actor FakeDiskBenchmarkFileManager: DiskBenchmarkFileManaging {
    private let recorder: BenchmarkEventRecorder
    private let availableCapacityValue: Int64
    private let corruptRead: Bool
    private let failure: FakeDiskFailure?
    private let removalGate: BenchmarkAsyncGate?
    private let maximumReadChunkBytes: Int?
    private let orphanCandidateValues: [DiskBenchmarkOrphanCandidate]
    private let clock: ManualBenchmarkKernelClock?
    private let synchronizeNanoseconds: UInt64
    private let readNanoseconds: UInt64
    private(set) var createdURLs: [URL] = []
    private(set) var removedURLs: [URL] = []

    init(
        recorder: BenchmarkEventRecorder,
        availableCapacity: Int64,
        corruptRead: Bool = false,
        failure: FakeDiskFailure? = nil,
        removalGate: BenchmarkAsyncGate? = nil,
        maximumReadChunkBytes: Int? = nil,
        orphanCandidates: [DiskBenchmarkOrphanCandidate] = [],
        clock: ManualBenchmarkKernelClock? = nil,
        synchronizeNanoseconds: UInt64 = 0,
        readNanoseconds: UInt64 = 0
    ) {
        self.recorder = recorder
        availableCapacityValue = availableCapacity
        self.corruptRead = corruptRead
        self.failure = failure
        self.removalGate = removalGate
        self.maximumReadChunkBytes = maximumReadChunkBytes
        orphanCandidateValues = orphanCandidates
        self.clock = clock
        self.synchronizeNanoseconds = synchronizeNanoseconds
        self.readNanoseconds = readNanoseconds
    }

    func prepareDirectory(_ url: URL) async throws {
        await recorder.append(.createDirectory)
    }

    func availableCapacity(at url: URL) async throws -> Int64 {
        await recorder.append(.capacity)
        return availableCapacityValue
    }

    func createExclusiveFile(at url: URL) async throws -> any DiskBenchmarkFileSession {
        await recorder.append(.create)
        createdURLs.append(url)
        return FakeDiskBenchmarkFileSession(
            recorder: recorder,
            corruptRead: corruptRead,
            failure: failure,
            maximumReadChunkBytes: maximumReadChunkBytes,
            clock: clock,
            synchronizeNanoseconds: synchronizeNanoseconds,
            readNanoseconds: readNanoseconds
        )
    }

    func removeFile(at url: URL) async {
        await recorder.append(.remove)
        removedURLs.append(url)
        await removalGate?.wait()
    }

    func orphanCandidates(in directory: URL) async throws -> [DiskBenchmarkOrphanCandidate] {
        orphanCandidateValues
    }
}

private actor FakeDiskBenchmarkFileSession: DiskBenchmarkFileSession {
    private let recorder: BenchmarkEventRecorder
    private let corruptRead: Bool
    private let failure: FakeDiskFailure?
    private let maximumReadChunkBytes: Int?
    private let clock: ManualBenchmarkKernelClock?
    private let synchronizeNanoseconds: UInt64
    private let readNanoseconds: UInt64
    private var storage = Data()
    private var readOffset = 0

    init(
        recorder: BenchmarkEventRecorder,
        corruptRead: Bool,
        failure: FakeDiskFailure?,
        maximumReadChunkBytes: Int?,
        clock: ManualBenchmarkKernelClock?,
        synchronizeNanoseconds: UInt64,
        readNanoseconds: UInt64
    ) {
        self.recorder = recorder
        self.corruptRead = corruptRead
        self.failure = failure
        self.maximumReadChunkBytes = maximumReadChunkBytes
        self.clock = clock
        self.synchronizeNanoseconds = synchronizeNanoseconds
        self.readNanoseconds = readNanoseconds
    }

    func disableCache() async throws {
        await recorder.append(.disableCache)
    }

    func write(_ data: Data) async throws {
        await recorder.append(.write)
        if failure == .cancelDuringWrite { throw CancellationError() }
        if failure == .write { throw BenchmarkKernelError.systemFailure }
        storage.append(data)
    }

    func synchronize() async throws {
        await recorder.append(.synchronize)
        if failure == .synchronize { throw BenchmarkKernelError.systemFailure }
        clock?.advance(by: synchronizeNanoseconds)
    }

    func rewind() async throws {
        await recorder.append(.rewind)
        readOffset = 0
    }

    func read(upToCount count: Int) async throws -> Data {
        await recorder.append(.read)
        if failure == .read { throw BenchmarkKernelError.systemFailure }
        clock?.advance(by: readNanoseconds)
        guard readOffset < storage.count else { return Data() }
        let requestedCount = min(count, maximumReadChunkBytes ?? count)
        let end = min(readOffset + requestedCount, storage.count)
        var result = storage.subdata(in: readOffset..<end)
        readOffset = end
        if corruptRead, !result.isEmpty {
            result[0] ^= 0xFF
        }
        return result
    }

    func close() async {
        await recorder.append(.close)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
