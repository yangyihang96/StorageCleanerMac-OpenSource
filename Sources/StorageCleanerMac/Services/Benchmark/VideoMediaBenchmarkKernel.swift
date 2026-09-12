@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
@preconcurrency import VideoToolbox
import Foundation

enum VideoMediaBenchmarkCapability: Equatable, Sendable {
    case h264HardwareEncoder
    case h264HardwareDecoder
}

enum VideoMediaBenchmarkValidationFailure: Equatable, Sendable {
    case frameCount
    case presentationTimestamps
    case dimensions
    case hardwarePath
    case encodedPayload
    case decodedContent
}

enum VideoMediaBenchmarkError: Error, Equatable, Sendable {
    case unsupported(VideoMediaBenchmarkCapability)
    case temporarilyUnavailable(VideoMediaBenchmarkCapability)
    case invalidConfiguration
    case resourceLimit
    case timedOut(VideoMediaBenchmarkCapability)
    case invalidMetric
    case invalidOutput(VideoMediaBenchmarkValidationFailure)
    case systemFailure(OSStatus)
}

struct VideoMediaBenchmarkDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct VideoMediaBenchmarkWorkload: Equatable, Sendable {
    let width: Int
    let height: Int
    let frameCount: Int
    let framesPerSecond: Int
    let averageBitRate: Int
    let maximumEncodedBytes: Int
}

struct VideoMediaBenchmarkEncodeEvidence: Equatable, Sendable {
    let frameCount: Int
    let presentationTimeValues: [Int64]
    let frameDimensions: [VideoMediaBenchmarkDimensions]
    let encodedByteCount: Int
    let usedHardware: Bool
    let ranOnMainThread: Bool
}

struct VideoMediaBenchmarkChromaProbe: Equatable, Sendable {
    let cb: UInt8
    let cr: UInt8
}

/// A bounded set of pixels copied from one decoded frame while VideoToolbox owns it.
/// Coordinates are fixed by the benchmark protocol and are intentionally not stored.
struct VideoMediaBenchmarkDecodedFrameContentEvidence: Equatable, Sendable {
    let presentationTimeValue: Int64
    let lumaSamples: [UInt8]
    let chromaSamples: [VideoMediaBenchmarkChromaProbe]
    /// Exact integrity digest of the retained evidence, recomputed before validation.
    let capturedDigest: UInt64
}

struct VideoMediaBenchmarkDecodeEvidence: Equatable, Sendable {
    let frameCount: Int
    let presentationTimeValues: [Int64]
    let frameDimensions: [VideoMediaBenchmarkDimensions]
    let frameContentEvidence: [VideoMediaBenchmarkDecodedFrameContentEvidence]
    let usedHardware: Bool
    let ranOnMainThread: Bool
}

struct VideoMediaBenchmarkSemanticSummary: Equatable, Sendable {
    let codec: String
    let width: Int
    let height: Int
    let frameCount: Int
    let framesPerSecond: Int
    let encodedFrameCount: Int
    let decodedFrameCount: Int
    let presentationTimeValues: [Int64]
    let encodedByteCount: Int
    let encoderUsedHardware: Bool
    let decoderUsedHardware: Bool
    /// Stable, error-tolerant digest derived from the actual decoded pixels.
    let decodedContentChecksum: UInt64
    /// Stable workload plus decoded-content digest. It excludes compressed bytes.
    let checksum: UInt64
}

protocol VideoMediaBenchmarkDriving: Sendable {
    /// Generates and retains every deterministic input frame outside the timed phases.
    func prepare(workload: VideoMediaBenchmarkWorkload) async throws
    func warmUp() async throws
    /// Completes only after every asynchronous encoder callback has finished.
    func encode() async throws -> VideoMediaBenchmarkEncodeEvidence
    /// Creates and verifies the hardware decoder outside the decode timing window.
    func prepareDecoder() async throws
    /// Completes only after every asynchronous decoder callback has finished.
    func decode() async throws -> VideoMediaBenchmarkDecodeEvidence
    func cancel() async
    func tearDown() async
}

struct VideoMediaBenchmarkKernel: Sendable {
    static let maximumWidth = 3_840
    static let maximumHeight = 2_160
    static let maximumFrameCount = 120
    static let maximumFramesPerSecond = 120
    static let maximumAverageBitRate = 100_000_000
    static let maximumEncodedBytes = 128 * 1_024 * 1_024
    static let maximumInputBytes = 512 * 1_024 * 1_024
    static let maximumQuickElapsedSeconds = 20.0
    static let maximumFullElapsedSeconds = 45.0

    struct Limits: Equatable, Sendable {
        let width: Int
        let height: Int
        let frameCount: Int
        let framesPerSecond: Int
        let averageBitRate: Int
        let maximumEncodedBytes: Int
        let maximumElapsedSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        let quick: Limits
        let full: Limits

        static let standard = Self(
            quick: Limits(
                width: 1_920,
                height: 1_080,
                frameCount: 60,
                framesPerSecond: 60,
                averageBitRate: 12_000_000,
                maximumEncodedBytes: 32 * 1_024 * 1_024,
                maximumElapsedSeconds: 15
            ),
            full: Limits(
                width: 3_840,
                height: 2_160,
                frameCount: 30,
                framesPerSecond: 60,
                averageBitRate: 32_000_000,
                maximumEncodedBytes: 96 * 1_024 * 1_024,
                maximumElapsedSeconds: 35
            )
        )

        static let testing = Self(
            quick: Limits(
                width: 320,
                height: 180,
                frameCount: 8,
                framesPerSecond: 30,
                averageBitRate: 1_000_000,
                maximumEncodedBytes: 4 * 1_024 * 1_024,
                maximumElapsedSeconds: 8
            ),
            full: Limits(
                width: 640,
                height: 360,
                frameCount: 12,
                framesPerSecond: 30,
                averageBitRate: 2_000_000,
                maximumEncodedBytes: 8 * 1_024 * 1_024,
                maximumElapsedSeconds: 10
            )
        )

        func limits(for profile: BenchmarkProfile) -> Limits {
            switch profile {
            case .standard, .quick: quick
            case .full: full
            }
        }
    }

    struct RunResult: Equatable, Sendable {
        /// Effective input megapixels per second submitted to the hardware encoder.
        let encodeSample: BenchmarkComponentSample
        /// Effective output megapixels per second completed by the hardware decoder.
        let decodeSample: BenchmarkComponentSample
        let semanticSummary: VideoMediaBenchmarkSemanticSummary
        let ranOnMainThread: Bool
    }

    let configuration: Configuration
    private let clock: any BenchmarkKernelClock
    private let driverFactory: @Sendable () -> any VideoMediaBenchmarkDriving

    init(
        configuration: Configuration = .standard,
        clock: any BenchmarkKernelClock = SystemBenchmarkKernelClock(),
        driverFactory: @escaping @Sendable () -> any VideoMediaBenchmarkDriving = {
            SystemVideoMediaBenchmarkDriver()
        }
    ) {
        self.configuration = configuration
        self.clock = clock
        self.driverFactory = driverFactory
    }

    func run(profile: BenchmarkProfile = .standard) async throws -> RunResult {
        try Task.checkCancellation()
        let limits = configuration.limits(for: profile)
        try Self.validate(limits, profile: profile)

        let driver = driverFactory()
        let clock = clock
        let worker = Task.detached(priority: .userInitiated) {
            try await Self.runDetached(limits: limits, clock: clock, driver: driver)
        }

        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
            _ = Task.detached(priority: .userInitiated) {
                await driver.cancel()
            }
        }
    }
}

private extension VideoMediaBenchmarkKernel {
    static func validate(_ limits: Limits, profile: BenchmarkProfile) throws {
        guard limits.width > 0,
              limits.height > 0,
              limits.width.isMultiple(of: 2),
              limits.height.isMultiple(of: 2),
              limits.frameCount > 0,
              limits.framesPerSecond > 0,
              limits.averageBitRate > 0,
              limits.maximumEncodedBytes > 0,
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0
        else {
            throw VideoMediaBenchmarkError.invalidConfiguration
        }

        let maximumElapsedSeconds: Double
        switch profile {
        case .standard, .quick:
            maximumElapsedSeconds = maximumQuickElapsedSeconds
        case .full:
            maximumElapsedSeconds = maximumFullElapsedSeconds
        }

        guard limits.width <= maximumWidth,
              limits.height <= maximumHeight,
              limits.frameCount <= maximumFrameCount,
              limits.framesPerSecond <= maximumFramesPerSecond,
              limits.averageBitRate <= maximumAverageBitRate,
              limits.maximumEncodedBytes <= maximumEncodedBytes,
              limits.maximumElapsedSeconds <= maximumElapsedSeconds
        else {
            throw VideoMediaBenchmarkError.resourceLimit
        }

        let (pixelsPerFrame, pixelOverflow) = limits.width.multipliedReportingOverflow(
            by: limits.height
        )
        let (threeBytesPerFrame, byteOverflow) = pixelsPerFrame.multipliedReportingOverflow(by: 3)
        let bytesPerFrame = threeBytesPerFrame / 2
        let (inputBytes, inputOverflow) = bytesPerFrame.multipliedReportingOverflow(
            by: limits.frameCount
        )
        let (_, pixelCountOverflow) = UInt64(pixelsPerFrame).multipliedReportingOverflow(
            by: UInt64(limits.frameCount)
        )

        guard !pixelOverflow,
              !byteOverflow,
              !inputOverflow,
              !pixelCountOverflow,
              inputBytes <= maximumInputBytes
        else {
            throw VideoMediaBenchmarkError.resourceLimit
        }
    }

    static func runDetached(
        limits: Limits,
        clock: any BenchmarkKernelClock,
        driver: any VideoMediaBenchmarkDriving
    ) async throws -> RunResult {
        let safetyStartedAt = clock.nowNanoseconds()
        let workload = VideoMediaBenchmarkWorkload(
            width: limits.width,
            height: limits.height,
            frameCount: limits.frameCount,
            framesPerSecond: limits.framesPerSecond,
            averageBitRate: limits.averageBitRate,
            maximumEncodedBytes: limits.maximumEncodedBytes
        )

        do {
            try Task.checkCancellation()
            _ = try await performWithinRemainingTime(
                driver: driver,
                clock: clock,
                safetyStartedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds,
                capability: .h264HardwareEncoder
            ) {
                try await driver.prepare(workload: workload)
                return true
            }

            _ = try await performWithinRemainingTime(
                driver: driver,
                clock: clock,
                safetyStartedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds,
                capability: .h264HardwareEncoder
            ) {
                try await driver.warmUp()
                return true
            }

            let encodeStartedAt = clock.nowNanoseconds()
            let encodeEvidence = try await performWithinRemainingTime(
                driver: driver,
                clock: clock,
                safetyStartedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds,
                capability: .h264HardwareEncoder
            ) {
                try await driver.encode()
            }
            let encodeFinishedAt = clock.nowNanoseconds()
            try checkSafetyBoundary(
                clock: clock,
                safetyStartedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds,
                capability: .h264HardwareEncoder,
                sampledAt: encodeFinishedAt
            )

            _ = try await performWithinRemainingTime(
                driver: driver,
                clock: clock,
                safetyStartedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds,
                capability: .h264HardwareDecoder
            ) {
                try await driver.prepareDecoder()
                return true
            }

            let decodeStartedAt = clock.nowNanoseconds()
            let decodeEvidence = try await performWithinRemainingTime(
                driver: driver,
                clock: clock,
                safetyStartedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds,
                capability: .h264HardwareDecoder
            ) {
                try await driver.decode()
            }
            let decodeFinishedAt = clock.nowNanoseconds()
            try checkSafetyBoundary(
                clock: clock,
                safetyStartedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds,
                capability: .h264HardwareDecoder,
                sampledAt: decodeFinishedAt
            )

            let summary = try semanticSummary(
                workload: workload,
                encodeEvidence: encodeEvidence,
                decodeEvidence: decodeEvidence
            )
            try Task.checkCancellation()

            let encodeElapsedSeconds = try seconds(
                from: encodeStartedAt,
                to: encodeFinishedAt
            )
            let decodeElapsedSeconds = try seconds(
                from: decodeStartedAt,
                to: decodeFinishedAt
            )
            let megapixels = try megapixels(for: workload)
            let encodeThroughput = megapixels / encodeElapsedSeconds
            let decodeThroughput = megapixels / decodeElapsedSeconds
            guard encodeThroughput.isFinite,
                  encodeThroughput > 0,
                  decodeThroughput.isFinite,
                  decodeThroughput > 0
            else {
                throw VideoMediaBenchmarkError.invalidMetric
            }

            await driver.tearDown()
            return RunResult(
                encodeSample: BenchmarkComponentSample(
                    value: encodeThroughput,
                    elapsedSeconds: encodeElapsedSeconds,
                    checksum: summary.checksum
                ),
                decodeSample: BenchmarkComponentSample(
                    value: decodeThroughput,
                    elapsedSeconds: decodeElapsedSeconds,
                    checksum: summary.checksum
                ),
                semanticSummary: summary,
                ranOnMainThread: encodeEvidence.ranOnMainThread
                    || decodeEvidence.ranOnMainThread
            )
        } catch {
            let wasCancelled = error is CancellationError || Task.isCancelled
            if wasCancelled {
                await driver.cancel()
            }
            await driver.tearDown()
            if wasCancelled { throw CancellationError() }
            if let mediaError = error as? VideoMediaBenchmarkError { throw mediaError }
            throw VideoMediaBenchmarkError.systemFailure(-1)
        }
    }

    static func performWithinRemainingTime<T: Sendable>(
        driver: any VideoMediaBenchmarkDriving,
        clock: any BenchmarkKernelClock,
        safetyStartedAt: UInt64,
        maximumElapsedSeconds: Double,
        capability: VideoMediaBenchmarkCapability,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let remainingSeconds = try remainingSeconds(
            clock: clock,
            safetyStartedAt: safetyStartedAt,
            maximumElapsedSeconds: maximumElapsedSeconds,
            capability: capability
        )

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(remainingSeconds))
                await driver.cancel()
                throw VideoMediaBenchmarkError.timedOut(capability)
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw VideoMediaBenchmarkError.systemFailure(-1)
            }
            return first
        }
    }

    static func remainingSeconds(
        clock: any BenchmarkKernelClock,
        safetyStartedAt: UInt64,
        maximumElapsedSeconds: Double,
        capability: VideoMediaBenchmarkCapability
    ) throws -> Double {
        let sampledAt = clock.nowNanoseconds()
        guard sampledAt >= safetyStartedAt else {
            throw VideoMediaBenchmarkError.invalidMetric
        }
        let elapsed = Double(sampledAt - safetyStartedAt) / 1_000_000_000
        let remaining = maximumElapsedSeconds - elapsed
        guard remaining.isFinite, remaining > 0 else {
            throw VideoMediaBenchmarkError.timedOut(capability)
        }
        return remaining
    }

    static func checkSafetyBoundary(
        clock: any BenchmarkKernelClock,
        safetyStartedAt: UInt64,
        maximumElapsedSeconds: Double,
        capability: VideoMediaBenchmarkCapability,
        sampledAt: UInt64? = nil
    ) throws {
        let sampledAt = sampledAt ?? clock.nowNanoseconds()
        guard sampledAt >= safetyStartedAt else {
            throw VideoMediaBenchmarkError.invalidMetric
        }
        let elapsed = Double(sampledAt - safetyStartedAt) / 1_000_000_000
        guard elapsed.isFinite, elapsed <= maximumElapsedSeconds else {
            throw VideoMediaBenchmarkError.timedOut(capability)
        }
    }

    static func seconds(from startedAt: UInt64, to finishedAt: UInt64) throws -> Double {
        guard finishedAt > startedAt else {
            throw VideoMediaBenchmarkError.invalidMetric
        }
        let elapsed = Double(finishedAt - startedAt) / 1_000_000_000
        guard elapsed.isFinite, elapsed > 0 else {
            throw VideoMediaBenchmarkError.invalidMetric
        }
        return elapsed
    }

    static func megapixels(for workload: VideoMediaBenchmarkWorkload) throws -> Double {
        let (pixelsPerFrame, firstOverflow) = UInt64(workload.width)
            .multipliedReportingOverflow(by: UInt64(workload.height))
        let (pixelCount, secondOverflow) = pixelsPerFrame
            .multipliedReportingOverflow(by: UInt64(workload.frameCount))
        guard !firstOverflow, !secondOverflow else {
            throw VideoMediaBenchmarkError.invalidMetric
        }
        let result = Double(pixelCount) / 1_000_000
        guard result.isFinite, result > 0 else {
            throw VideoMediaBenchmarkError.invalidMetric
        }
        return result
    }

    static func semanticSummary(
        workload: VideoMediaBenchmarkWorkload,
        encodeEvidence: VideoMediaBenchmarkEncodeEvidence,
        decodeEvidence: VideoMediaBenchmarkDecodeEvidence
    ) throws -> VideoMediaBenchmarkSemanticSummary {
        guard encodeEvidence.usedHardware else {
            throw VideoMediaBenchmarkError.unsupported(.h264HardwareEncoder)
        }
        guard decodeEvidence.usedHardware else {
            throw VideoMediaBenchmarkError.unsupported(.h264HardwareDecoder)
        }

        guard encodeEvidence.frameCount == workload.frameCount,
              decodeEvidence.frameCount == workload.frameCount,
              encodeEvidence.presentationTimeValues.count == workload.frameCount,
              decodeEvidence.presentationTimeValues.count == workload.frameCount,
              encodeEvidence.frameDimensions.count == workload.frameCount,
              decodeEvidence.frameDimensions.count == workload.frameCount
        else {
            throw VideoMediaBenchmarkError.invalidOutput(.frameCount)
        }

        let expectedPresentationTimes = (0..<workload.frameCount).map(Int64.init)
        guard encodeEvidence.presentationTimeValues == expectedPresentationTimes,
              decodeEvidence.presentationTimeValues == expectedPresentationTimes
        else {
            throw VideoMediaBenchmarkError.invalidOutput(.presentationTimestamps)
        }

        let expectedDimensions = VideoMediaBenchmarkDimensions(
            width: workload.width,
            height: workload.height
        )
        guard encodeEvidence.frameDimensions.allSatisfy({ $0 == expectedDimensions }),
              decodeEvidence.frameDimensions.allSatisfy({ $0 == expectedDimensions })
        else {
            throw VideoMediaBenchmarkError.invalidOutput(.dimensions)
        }

        guard encodeEvidence.encodedByteCount > 0,
              encodeEvidence.encodedByteCount <= workload.maximumEncodedBytes
        else {
            throw VideoMediaBenchmarkError.invalidOutput(.encodedPayload)
        }

        let decodedContentChecksum = try validatedDecodedContentChecksum(
            workload: workload,
            evidence: decodeEvidence.frameContentEvidence
        )
        let contractChecksum = semanticChecksum(for: workload)

        return VideoMediaBenchmarkSemanticSummary(
            codec: "H.264",
            width: workload.width,
            height: workload.height,
            frameCount: workload.frameCount,
            framesPerSecond: workload.framesPerSecond,
            encodedFrameCount: encodeEvidence.frameCount,
            decodedFrameCount: decodeEvidence.frameCount,
            presentationTimeValues: expectedPresentationTimes,
            encodedByteCount: encodeEvidence.encodedByteCount,
            encoderUsedHardware: true,
            decoderUsedHardware: true,
            decodedContentChecksum: decodedContentChecksum,
            checksum: combinedChecksum(
                contractChecksum: contractChecksum,
                decodedContentChecksum: decodedContentChecksum
            )
        )
    }

    static func validatedDecodedContentChecksum(
        workload: VideoMediaBenchmarkWorkload,
        evidence: [VideoMediaBenchmarkDecodedFrameContentEvidence]
    ) throws -> UInt64 {
        guard evidence.count == workload.frameCount else {
            throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
        }

        let coordinates = contentProbeCoordinates(
            width: workload.width,
            height: workload.height
        )
        guard !coordinates.isEmpty else {
            throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
        }

        var robustChecksum: UInt64 = 1_469_598_103_934_665_603
        for byte in "video-media-benchmark/decoded-content/v1".utf8 {
            mix(byte: byte, into: &robustChecksum)
        }

        for (frameIndex, frameEvidence) in evidence.enumerated() {
            guard frameEvidence.presentationTimeValue == Int64(frameIndex),
                  frameEvidence.lumaSamples.count == coordinates.count,
                  frameEvidence.chromaSamples.count == coordinates.count,
                  frameEvidence.capturedDigest == decodedContentIntegrityDigest(
                      presentationTimeValue: frameEvidence.presentationTimeValue,
                      lumaSamples: frameEvidence.lumaSamples,
                      chromaSamples: frameEvidence.chromaSamples
                  )
            else {
                throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
            }

            var lumaAbsoluteError = 0
            var chromaAbsoluteError = 0
            var lumaWithinTolerance = 0
            var chromaWithinTolerance = 0
            var minimumLuma = UInt8.max
            var maximumLuma = UInt8.min

            mix(value: UInt64(frameIndex), into: &robustChecksum)
            for probeIndex in coordinates.indices {
                let coordinate = coordinates[probeIndex]
                let expectedLuma = expectedLumaValue(
                    frameIndex: frameIndex,
                    rowIndex: coordinate.y,
                    bandIndex: coordinate.bandIndex
                )
                let expectedChroma = expectedChromaValue(
                    frameIndex: frameIndex,
                    chromaRowIndex: coordinate.y / 2
                )
                let actualLuma = frameEvidence.lumaSamples[probeIndex]
                let actualChroma = frameEvidence.chromaSamples[probeIndex]

                minimumLuma = min(minimumLuma, actualLuma)
                maximumLuma = max(maximumLuma, actualLuma)

                let lumaError = abs(Int(actualLuma) - Int(expectedLuma))
                let cbError = abs(Int(actualChroma.cb) - Int(expectedChroma))
                let crError = abs(Int(actualChroma.cr) - Int(expectedChroma))
                lumaAbsoluteError += lumaError
                chromaAbsoluteError += cbError + crError
                if lumaError <= 44 { lumaWithinTolerance += 1 }
                if cbError <= 34 { chromaWithinTolerance += 1 }
                if crError <= 34 { chromaWithinTolerance += 1 }

                mix(
                    byte: robustResidualBucket(
                        actual: actualLuma,
                        expected: expectedLuma
                    ),
                    into: &robustChecksum
                )
                mix(
                    byte: robustResidualBucket(
                        actual: actualChroma.cb,
                        expected: expectedChroma
                    ),
                    into: &robustChecksum
                )
                mix(
                    byte: robustResidualBucket(
                        actual: actualChroma.cr,
                        expected: expectedChroma
                    ),
                    into: &robustChecksum
                )
            }

            let lumaCount = coordinates.count
            let chromaCount = coordinates.count * 2
            let lumaMeanAbsoluteError = Double(lumaAbsoluteError) / Double(lumaCount)
            let chromaMeanAbsoluteError = Double(chromaAbsoluteError) / Double(chromaCount)
            let lumaRange = Int(maximumLuma) - Int(minimumLuma)

            // H.264 is lossy, so validation uses bounded aggregate error instead of
            // byte equality. The spread gate independently rejects black/flat frames.
            guard lumaRange >= 40,
                  lumaWithinTolerance * 4 >= lumaCount * 3,
                  chromaWithinTolerance * 4 >= chromaCount * 3,
                  lumaMeanAbsoluteError <= 24,
                  chromaMeanAbsoluteError <= 20
            else {
                throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
            }
        }
        return robustChecksum
    }

    static func contentProbeCoordinates(
        width: Int,
        height: Int
    ) -> [(x: Int, y: Int, bandIndex: Int)] {
        guard width > 0, height > 0 else { return [] }
        let bandWidth = max(width / 8, 1)
        let rowNumerators = [1, 3, 5, 7]
        var result: [(x: Int, y: Int, bandIndex: Int)] = []
        result.reserveCapacity(32)

        for rowNumerator in rowNumerators {
            let y = min((height * rowNumerator) / 8, height - 1)
            for bandIndex in 0..<8 {
                let start = min(bandIndex * bandWidth, width)
                let end = bandIndex == 7
                    ? width
                    : min(start + bandWidth, width)
                guard end > start else { continue }
                result.append((
                    x: start + ((end - start) / 2),
                    y: y,
                    bandIndex: bandIndex
                ))
            }
        }
        return result
    }

    static func expectedLumaValue(
        frameIndex: Int,
        rowIndex: Int,
        bandIndex: Int
    ) -> UInt8 {
        UInt8(16 + ((frameIndex * 7 + rowIndex * 3 + bandIndex * 23) % 220))
    }

    static func expectedChromaValue(
        frameIndex: Int,
        chromaRowIndex: Int
    ) -> UInt8 {
        UInt8(96 + ((frameIndex * 5 + chromaRowIndex) % 64))
    }

    static func robustResidualBucket(actual: UInt8, expected: UInt8) -> UInt8 {
        let delta = Int(actual) - Int(expected)
        return switch delta {
        case ..<(-64): 0
        case -64..<(-32): 1
        case -32..<(-16): 2
        case -16...16: 3
        case 17...32: 4
        case 33...64: 5
        default: 6
        }
    }

    static func combinedChecksum(
        contractChecksum: UInt64,
        decodedContentChecksum: UInt64
    ) -> UInt64 {
        var checksum = contractChecksum
        mix(value: decodedContentChecksum, into: &checksum)
        return checksum
    }

    static func semanticChecksum(for workload: VideoMediaBenchmarkWorkload) -> UInt64 {
        var checksum: UInt64 = 1_469_598_103_934_665_603
        func mix(byte: UInt8) {
            Self.mix(byte: byte, into: &checksum)
        }
        func mix(value: UInt64) {
            Self.mix(value: value, into: &checksum)
        }

        for byte in "video-media-benchmark/h264-hardware/v1".utf8 {
            mix(byte: byte)
        }
        mix(value: UInt64(workload.width))
        mix(value: UInt64(workload.height))
        mix(value: UInt64(workload.frameCount))
        mix(value: UInt64(workload.framesPerSecond))
        mix(value: UInt64(workload.averageBitRate))
        mix(value: UInt64(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        mix(value: 0) // Frame reordering is disabled.
        return checksum
    }

    static func mix(byte: UInt8, into checksum: inout UInt64) {
        checksum ^= UInt64(byte)
        checksum &*= 1_099_511_628_211
    }

    static func mix(value: UInt64, into checksum: inout UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            mix(
                byte: UInt8(truncatingIfNeeded: value >> UInt64(shift)),
                into: &checksum
            )
        }
    }
}

extension VideoMediaBenchmarkKernel {
    /// Exact digest used only to prove the bounded callback evidence was not altered.
    /// The public semantic checksum uses a separate lossy-error-tolerant digest.
    static func decodedContentIntegrityDigest(
        presentationTimeValue: Int64,
        lumaSamples: [UInt8],
        chromaSamples: [VideoMediaBenchmarkChromaProbe]
    ) -> UInt64 {
        var checksum: UInt64 = 1_469_598_103_934_665_603
        for byte in "video-media-benchmark/captured-evidence/v1".utf8 {
            mix(byte: byte, into: &checksum)
        }
        mix(value: UInt64(bitPattern: presentationTimeValue), into: &checksum)
        mix(value: UInt64(lumaSamples.count), into: &checksum)
        for value in lumaSamples {
            mix(byte: value, into: &checksum)
        }
        mix(value: UInt64(chromaSamples.count), into: &checksum)
        for value in chromaSamples {
            mix(byte: value.cb, into: &checksum)
            mix(byte: value.cr, into: &checksum)
        }
        return checksum
    }
}

private final class SystemVideoMediaBenchmarkDriver: VideoMediaBenchmarkDriving, @unchecked Sendable {
    private struct State {
        var workload: VideoMediaBenchmarkWorkload?
        var inputFrames: [CVPixelBuffer] = []
        var encodedFrames: [EncodedFrame] = []
        var encoderSession: VTCompressionSession?
        var decoderSession: VTDecompressionSession?
        var encoderUsedHardware = false
        var decoderUsedHardware = false
        var cancelled = false
    }

    struct EncodedFrame {
        let sampleBuffer: CMSampleBuffer
        let presentationTimeValue: Int64
        let dimensions: VideoMediaBenchmarkDimensions
        let byteCount: Int
    }

    private let lock = NSLock()
    private var state = State()

    func prepare(workload: VideoMediaBenchmarkWorkload) async throws {
        try checkCancellation()
        let inputFrames = try Self.makeInputFrames(workload: workload) {
            try self.checkCancellation()
        }
        try checkCancellation()

        let encoderSession = try Self.makeEncoderSession(workload: workload)
        let retained = lock.withLock {
            guard !state.cancelled else { return false }
            state.workload = workload
            state.inputFrames = inputFrames
            state.encoderSession = encoderSession
            return true
        }
        guard retained else {
            VTCompressionSessionInvalidate(encoderSession)
            throw CancellationError()
        }
    }

    func warmUp() async throws {
        try checkCancellation()
        guard let encoderSession = lock.withLock({ state.encoderSession }) else {
            throw VideoMediaBenchmarkError.systemFailure(kVTInvalidSessionErr)
        }

        let status = VTCompressionSessionPrepareToEncodeFrames(encoderSession)
        try Self.throwIfFailed(status, capability: .h264HardwareEncoder)
        let usedHardware = try Self.hardwareProperty(
            session: encoderSession,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            capability: .h264HardwareEncoder
        )
        guard usedHardware else {
            throw VideoMediaBenchmarkError.unsupported(.h264HardwareEncoder)
        }
        lock.withLock { state.encoderUsedHardware = true }
        try checkCancellation()
    }

    func encode() async throws -> VideoMediaBenchmarkEncodeEvidence {
        try checkCancellation()
        guard let resources = lock.withLock({ () -> (
            VideoMediaBenchmarkWorkload,
            [CVPixelBuffer],
            VTCompressionSession,
            Bool
        )? in
            guard let workload = state.workload,
                  let encoderSession = state.encoderSession
            else { return nil }
            return (workload, state.inputFrames, encoderSession, state.encoderUsedHardware)
        }) else {
            throw VideoMediaBenchmarkError.systemFailure(kVTInvalidSessionErr)
        }
        let (workload, inputFrames, encoderSession, usedHardware) = resources
        defer { retireEncoderSession(encoderSession) }

        let collector = EncodedFrameCollector(framesPerSecond: workload.framesPerSecond)
        let duration = CMTime(value: 1, timescale: CMTimeScale(workload.framesPerSecond))
        let ranOnMainThread = benchmarkKernelIsMainThread()

        for (index, inputFrame) in inputFrames.enumerated() {
            try checkCancellation()
            let presentationTime = CMTime(
                value: CMTimeValue(index),
                timescale: CMTimeScale(workload.framesPerSecond)
            )
            let status = VTCompressionSessionEncodeFrame(
                encoderSession,
                imageBuffer: inputFrame,
                presentationTimeStamp: presentationTime,
                duration: duration,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { callbackStatus, infoFlags, sampleBuffer in
                collector.record(
                    status: callbackStatus,
                    infoFlags: infoFlags,
                    sampleBuffer: sampleBuffer
                )
            }
            try Self.throwIfFailed(status, capability: .h264HardwareEncoder)
        }

        let completionStatus = VTCompressionSessionCompleteFrames(
            encoderSession,
            untilPresentationTimeStamp: .invalid
        )
        try checkCancellation()
        try Self.throwIfFailed(completionStatus, capability: .h264HardwareEncoder)

        let snapshot = collector.snapshot()
        if let error = snapshot.error { throw error }
        guard !snapshot.droppedFrame else {
            throw VideoMediaBenchmarkError.invalidOutput(.frameCount)
        }

        let frames = snapshot.frames.sorted {
            $0.presentationTimeValue < $1.presentationTimeValue
        }
        var encodedByteCount = 0
        for frame in frames {
            let (nextCount, overflow) = encodedByteCount.addingReportingOverflow(frame.byteCount)
            guard !overflow, nextCount <= workload.maximumEncodedBytes else {
                throw VideoMediaBenchmarkError.resourceLimit
            }
            encodedByteCount = nextCount
        }

        lock.withLock { state.encodedFrames = frames }
        return VideoMediaBenchmarkEncodeEvidence(
            frameCount: frames.count,
            presentationTimeValues: frames.map(\.presentationTimeValue),
            frameDimensions: frames.map(\.dimensions),
            encodedByteCount: encodedByteCount,
            usedHardware: usedHardware,
            ranOnMainThread: ranOnMainThread
        )
    }

    func prepareDecoder() async throws {
        try checkCancellation()
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) else {
            throw VideoMediaBenchmarkError.unsupported(.h264HardwareDecoder)
        }
        guard let resources = lock.withLock({ () -> (
            VideoMediaBenchmarkWorkload,
            [EncodedFrame]
        )? in
            guard let workload = state.workload, !state.encodedFrames.isEmpty else {
                return nil
            }
            return (workload, state.encodedFrames)
        }),
        let formatDescription = CMSampleBufferGetFormatDescription(
            resources.1[0].sampleBuffer
        ) else {
            throw VideoMediaBenchmarkError.invalidOutput(.encodedPayload)
        }

        let workload = resources.0
        let decoderSpecification = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true
        ] as CFDictionary
        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: workload.width,
            kCVPixelBufferHeightKey as String: workload.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ] as CFDictionary

        var decoderSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            decompressionSessionOut: &decoderSession
        )
        try Self.throwIfFailed(status, capability: .h264HardwareDecoder)
        guard let decoderSession else {
            throw VideoMediaBenchmarkError.temporarilyUnavailable(.h264HardwareDecoder)
        }

        let usedHardware: Bool
        do {
            usedHardware = try Self.hardwareProperty(
                session: decoderSession,
                key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                capability: .h264HardwareDecoder
            )
        } catch {
            VTDecompressionSessionInvalidate(decoderSession)
            throw error
        }
        guard usedHardware else {
            VTDecompressionSessionInvalidate(decoderSession)
            throw VideoMediaBenchmarkError.unsupported(.h264HardwareDecoder)
        }

        let retained = lock.withLock {
            guard !state.cancelled else { return false }
            state.decoderSession = decoderSession
            state.decoderUsedHardware = true
            return true
        }
        guard retained else {
            VTDecompressionSessionInvalidate(decoderSession)
            throw CancellationError()
        }
    }

    func decode() async throws -> VideoMediaBenchmarkDecodeEvidence {
        try checkCancellation()
        guard let resources = lock.withLock({ () -> (
            VideoMediaBenchmarkWorkload,
            [EncodedFrame],
            VTDecompressionSession,
            Bool
        )? in
            guard let workload = state.workload,
                  let decoderSession = state.decoderSession
            else { return nil }
            return (
                workload,
                state.encodedFrames,
                decoderSession,
                state.decoderUsedHardware
            )
        }) else {
            throw VideoMediaBenchmarkError.systemFailure(kVTInvalidSessionErr)
        }
        let (workload, encodedFrames, decoderSession, usedHardware) = resources
        defer { retireDecoderSession(decoderSession) }

        let collector = DecodedFrameCollector(framesPerSecond: workload.framesPerSecond)
        let ranOnMainThread = benchmarkKernelIsMainThread()
        let asynchronousFlag = VTDecodeFrameFlags(rawValue: 1 << 0)

        for encodedFrame in encodedFrames {
            try checkCancellation()
            let status = VTDecompressionSessionDecodeFrame(
                decoderSession,
                sampleBuffer: encodedFrame.sampleBuffer,
                flags: asynchronousFlag,
                infoFlagsOut: nil
            ) { callbackStatus, infoFlags, imageBuffer, presentationTime, _ in
                collector.record(
                    status: callbackStatus,
                    infoFlags: infoFlags,
                    imageBuffer: imageBuffer,
                    presentationTime: presentationTime
                )
            }
            try Self.throwIfFailed(status, capability: .h264HardwareDecoder)
        }

        let finishStatus = VTDecompressionSessionFinishDelayedFrames(decoderSession)
        try Self.throwIfFailed(finishStatus, capability: .h264HardwareDecoder)
        let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(decoderSession)
        try checkCancellation()
        try Self.throwIfFailed(waitStatus, capability: .h264HardwareDecoder)

        let snapshot = collector.snapshot()
        if let error = snapshot.error { throw error }
        guard !snapshot.droppedFrame else {
            throw VideoMediaBenchmarkError.invalidOutput(.frameCount)
        }
        let frames = snapshot.frames.sorted {
            $0.presentationTimeValue < $1.presentationTimeValue
        }
        return VideoMediaBenchmarkDecodeEvidence(
            frameCount: frames.count,
            presentationTimeValues: frames.map(\.presentationTimeValue),
            frameDimensions: frames.map(\.dimensions),
            frameContentEvidence: frames.map(\.contentEvidence),
            usedHardware: usedHardware,
            ranOnMainThread: ranOnMainThread
        )
    }

    func cancel() async {
        let sessions = lock.withLock { () -> (
            VTCompressionSession?,
            VTDecompressionSession?
        ) in
            state.cancelled = true
            let sessions = (state.encoderSession, state.decoderSession)
            state.encoderSession = nil
            state.decoderSession = nil
            return sessions
        }
        if let encoderSession = sessions.0 {
            VTCompressionSessionInvalidate(encoderSession)
        }
        if let decoderSession = sessions.1 {
            VTDecompressionSessionInvalidate(decoderSession)
        }
    }

    func tearDown() async {
        let resources = lock.withLock { () -> (
            VTCompressionSession?,
            VTDecompressionSession?
        ) in
            state.cancelled = true
            let sessions = (state.encoderSession, state.decoderSession)
            state.encoderSession = nil
            state.decoderSession = nil
            state.inputFrames.removeAll(keepingCapacity: false)
            state.encodedFrames.removeAll(keepingCapacity: false)
            state.workload = nil
            state.encoderUsedHardware = false
            state.decoderUsedHardware = false
            return sessions
        }
        if let encoderSession = resources.0 {
            VTCompressionSessionInvalidate(encoderSession)
        }
        if let decoderSession = resources.1 {
            VTDecompressionSessionInvalidate(decoderSession)
        }
    }
}

private extension SystemVideoMediaBenchmarkDriver {
    struct EncodedFrameSnapshot {
        let frames: [EncodedFrame]
        let error: VideoMediaBenchmarkError?
        let droppedFrame: Bool
    }

    struct DecodedFrame: Sendable {
        let presentationTimeValue: Int64
        let dimensions: VideoMediaBenchmarkDimensions
        let contentEvidence: VideoMediaBenchmarkDecodedFrameContentEvidence
    }

    struct DecodedFrameSnapshot: Sendable {
        let frames: [DecodedFrame]
        let error: VideoMediaBenchmarkError?
        let droppedFrame: Bool
    }

    final class EncodedFrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let framesPerSecond: Int
        private var frames: [EncodedFrame] = []
        private var error: VideoMediaBenchmarkError?
        private var droppedFrame = false

        init(framesPerSecond: Int) {
            self.framesPerSecond = framesPerSecond
        }

        func record(
            status: OSStatus,
            infoFlags: VTEncodeInfoFlags,
            sampleBuffer: CMSampleBuffer?
        ) {
            lock.withLock {
                guard error == nil else { return }
                guard status == noErr else {
                    error = SystemVideoMediaBenchmarkDriver.mediaError(
                        status: status,
                        capability: .h264HardwareEncoder
                    )
                    return
                }
                guard !infoFlags.contains(.frameDropped),
                      let sampleBuffer,
                      CMSampleBufferDataIsReady(sampleBuffer),
                      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let presentationValue = SystemVideoMediaBenchmarkDriver.presentationTimeValue(
                          CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                          framesPerSecond: framesPerSecond
                      )
                else {
                    droppedFrame = true
                    return
                }

                let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
                frames.append(
                    EncodedFrame(
                        sampleBuffer: sampleBuffer,
                        presentationTimeValue: presentationValue,
                        dimensions: VideoMediaBenchmarkDimensions(
                            width: Int(dimensions.width),
                            height: Int(dimensions.height)
                        ),
                        byteCount: CMSampleBufferGetTotalSampleSize(sampleBuffer)
                    )
                )
            }
        }

        func snapshot() -> EncodedFrameSnapshot {
            lock.withLock {
                EncodedFrameSnapshot(
                    frames: frames,
                    error: error,
                    droppedFrame: droppedFrame
                )
            }
        }
    }

    final class DecodedFrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let framesPerSecond: Int
        private var frames: [DecodedFrame] = []
        private var error: VideoMediaBenchmarkError?
        private var droppedFrame = false

        init(framesPerSecond: Int) {
            self.framesPerSecond = framesPerSecond
        }

        func record(
            status: OSStatus,
            infoFlags: VTDecodeInfoFlags,
            imageBuffer: CVImageBuffer?,
            presentationTime: CMTime
        ) {
            guard status == noErr else {
                lock.withLock {
                    guard error == nil else { return }
                    error = SystemVideoMediaBenchmarkDriver.mediaError(
                        status: status,
                        capability: .h264HardwareDecoder
                    )
                }
                return
            }
            guard !infoFlags.contains(.frameDropped),
                  let imageBuffer,
                  let presentationValue = SystemVideoMediaBenchmarkDriver.presentationTimeValue(
                      presentationTime,
                      framesPerSecond: framesPerSecond
                  )
            else {
                lock.withLock { droppedFrame = true }
                return
            }

            let contentEvidence: VideoMediaBenchmarkDecodedFrameContentEvidence
            do {
                contentEvidence = try SystemVideoMediaBenchmarkDriver.captureContentEvidence(
                    pixelBuffer: imageBuffer,
                    presentationTimeValue: presentationValue
                )
            } catch let mediaError as VideoMediaBenchmarkError {
                lock.withLock {
                    if error == nil { error = mediaError }
                }
                return
            } catch {
                lock.withLock {
                    if self.error == nil {
                        self.error = .invalidOutput(.decodedContent)
                    }
                }
                return
            }

            lock.withLock {
                guard error == nil else { return }
                frames.append(
                    DecodedFrame(
                        presentationTimeValue: presentationValue,
                        dimensions: VideoMediaBenchmarkDimensions(
                            width: CVPixelBufferGetWidth(imageBuffer),
                            height: CVPixelBufferGetHeight(imageBuffer)
                        ),
                        contentEvidence: contentEvidence
                    )
                )
            }
        }

        func snapshot() -> DecodedFrameSnapshot {
            lock.withLock {
                DecodedFrameSnapshot(
                    frames: frames,
                    error: error,
                    droppedFrame: droppedFrame
                )
            }
        }
    }

    static func makeInputFrames(
        workload: VideoMediaBenchmarkWorkload,
        checkCancellation: () throws -> Void
    ) throws -> [CVPixelBuffer] {
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: workload.width,
            kCVPixelBufferHeightKey as String: workload.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ] as CFDictionary

        var frames: [CVPixelBuffer] = []
        frames.reserveCapacity(workload.frameCount)
        for frameIndex in 0..<workload.frameCount {
            try checkCancellation()
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                workload.width,
                workload.height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                if status == kCVReturnAllocationFailed {
                    throw VideoMediaBenchmarkError.resourceLimit
                }
                throw VideoMediaBenchmarkError.systemFailure(status)
            }
            try fill(
                pixelBuffer: pixelBuffer,
                frameIndex: frameIndex,
                checkCancellation: checkCancellation
            )
            frames.append(pixelBuffer)
        }
        return frames
    }

    static func captureContentEvidence(
        pixelBuffer: CVPixelBuffer,
        presentationTimeValue: Int64
    ) throws -> VideoMediaBenchmarkDecodedFrameContentEvidence {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2
        else {
            throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard width > 0,
              height > 0,
              lumaStride >= width,
              chromaStride >= width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) >= height,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) >= height / 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
        }

        let coordinates = VideoMediaBenchmarkKernel.contentProbeCoordinates(
            width: width,
            height: height
        )
        guard !coordinates.isEmpty else {
            throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
        }

        var lumaSamples: [UInt8] = []
        var chromaSamples: [VideoMediaBenchmarkChromaProbe] = []
        lumaSamples.reserveCapacity(coordinates.count)
        chromaSamples.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            guard coordinate.x >= 0,
                  coordinate.x < width,
                  coordinate.y >= 0,
                  coordinate.y < height
            else {
                throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
            }
            let lumaOffset = coordinate.y * lumaStride + coordinate.x
            lumaSamples.append(lumaBase.load(fromByteOffset: lumaOffset, as: UInt8.self))

            let chromaX = min((coordinate.x / 2) * 2, max(width - 2, 0))
            let chromaY = min(coordinate.y / 2, max((height / 2) - 1, 0))
            let chromaOffset = chromaY * chromaStride + chromaX
            guard chromaX + 1 < chromaStride else {
                throw VideoMediaBenchmarkError.invalidOutput(.decodedContent)
            }
            chromaSamples.append(
                VideoMediaBenchmarkChromaProbe(
                    cb: chromaBase.load(fromByteOffset: chromaOffset, as: UInt8.self),
                    cr: chromaBase.load(fromByteOffset: chromaOffset + 1, as: UInt8.self)
                )
            )
        }

        let capturedDigest = VideoMediaBenchmarkKernel.decodedContentIntegrityDigest(
            presentationTimeValue: presentationTimeValue,
            lumaSamples: lumaSamples,
            chromaSamples: chromaSamples
        )
        return VideoMediaBenchmarkDecodedFrameContentEvidence(
            presentationTimeValue: presentationTimeValue,
            lumaSamples: lumaSamples,
            chromaSamples: chromaSamples,
            capturedDigest: capturedDigest
        )
    }

    static func fill(
        pixelBuffer: CVPixelBuffer,
        frameIndex: Int,
        checkCancellation: () throws -> Void
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw VideoMediaBenchmarkError.systemFailure(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            throw VideoMediaBenchmarkError.invalidOutput(.dimensions)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let bandWidth = max(width / 8, 1)

        for rowIndex in 0..<height {
            if rowIndex.isMultiple(of: 64) { try checkCancellation() }
            let row = lumaBase.advanced(by: rowIndex * lumaStride)
            for bandIndex in 0..<8 {
                let start = min(bandIndex * bandWidth, width)
                let end = bandIndex == 7 ? width : min(start + bandWidth, width)
                let value = 16 + ((frameIndex * 7 + rowIndex * 3 + bandIndex * 23) % 220)
                memset(row.advanced(by: start), Int32(value), max(end - start, 0))
            }
        }

        for rowIndex in 0..<(height / 2) {
            if rowIndex.isMultiple(of: 64) { try checkCancellation() }
            let row = chromaBase.advanced(by: rowIndex * chromaStride)
            let value = 96 + ((frameIndex * 5 + rowIndex) % 64)
            memset(row, Int32(value), width)
        }
    }

    static func makeEncoderSession(
        workload: VideoMediaBenchmarkWorkload
    ) throws -> VTCompressionSession {
        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary
        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: workload.width,
            kCVPixelBufferHeightKey as String: workload.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ] as CFDictionary

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(workload.width),
            height: Int32(workload.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        try throwIfFailed(status, capability: .h264HardwareEncoder)
        guard let session else {
            throw VideoMediaBenchmarkError.temporarilyUnavailable(.h264HardwareEncoder)
        }

        do {
            try setProperty(
                session: session,
                key: kVTCompressionPropertyKey_RealTime,
                value: kCFBooleanFalse,
                capability: .h264HardwareEncoder
            )
            try setProperty(
                session: session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse,
                capability: .h264HardwareEncoder
            )
            try setProperty(
                session: session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_Main_AutoLevel,
                capability: .h264HardwareEncoder
            )
            try setProperty(
                session: session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: workload.framesPerSecond),
                capability: .h264HardwareEncoder
            )
            try setProperty(
                session: session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: workload.averageBitRate),
                capability: .h264HardwareEncoder
            )
            try setProperty(
                session: session,
                key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: workload.frameCount),
                capability: .h264HardwareEncoder
            )
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }
        return session
    }

    static func setProperty(
        session: VTSession,
        key: CFString,
        value: CFTypeRef,
        capability: VideoMediaBenchmarkCapability
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        try throwIfFailed(status, capability: capability)
    }

    static func hardwareProperty(
        session: VTSession,
        key: CFString,
        capability: VideoMediaBenchmarkCapability
    ) throws -> Bool {
        let value = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        let status = VTSessionCopyProperty(
            session,
            key: key,
            allocator: nil,
            valueOut: UnsafeMutableRawPointer(value)
        )
        try throwIfFailed(status, capability: capability)
        guard let result = value.pointee as? Bool else {
            throw VideoMediaBenchmarkError.systemFailure(kVTPropertyNotSupportedErr)
        }
        return result
    }

    static func throwIfFailed(
        _ status: OSStatus,
        capability: VideoMediaBenchmarkCapability
    ) throws {
        guard status != noErr else { return }
        throw mediaError(status: status, capability: capability)
    }

    static func mediaError(
        status: OSStatus,
        capability: VideoMediaBenchmarkCapability
    ) -> VideoMediaBenchmarkError {
        switch status {
        case kVTCouldNotFindVideoEncoderErr:
            return .unsupported(.h264HardwareEncoder)
        case kVTCouldNotFindVideoDecoderErr:
            return .unsupported(.h264HardwareDecoder)
        case kVTVideoDecoderUnsupportedDataFormatErr:
            // The suite decodes the H.264 stream produced moments earlier by
            // its verified hardware encoder. Reject an incompatible payload as
            // invalid evidence instead of mislabelling the machine unsupported.
            return .invalidOutput(.encodedPayload)
        case kVTVideoEncoderNotAvailableNowErr:
            return .temporarilyUnavailable(.h264HardwareEncoder)
        case kVTVideoDecoderNotAvailableNowErr:
            return .temporarilyUnavailable(.h264HardwareDecoder)
        case kVTCouldNotCreateInstanceErr, kVTAllocationFailedErr:
            return .temporarilyUnavailable(capability)
        default:
            return .systemFailure(status)
        }
    }

    static func presentationTimeValue(
        _ time: CMTime,
        framesPerSecond: Int
    ) -> Int64? {
        guard time.isValid, time.isNumeric else { return nil }
        let scaled = CMTimeConvertScale(
            time,
            timescale: CMTimeScale(framesPerSecond),
            method: .default
        )
        guard CMTimeCompare(time, scaled) == 0 else { return nil }
        return scaled.value
    }

    func checkCancellation() throws {
        if Task.isCancelled || lock.withLock({ state.cancelled }) {
            throw CancellationError()
        }
    }

    func retireEncoderSession(_ session: VTCompressionSession) {
        let ownsSession = lock.withLock {
            guard state.encoderSession != nil else { return false }
            state.encoderSession = nil
            return true
        }
        if ownsSession {
            VTCompressionSessionInvalidate(session)
        }
    }

    func retireDecoderSession(_ session: VTDecompressionSession) {
        let ownsSession = lock.withLock {
            guard state.decoderSession != nil else { return false }
            state.decoderSession = nil
            return true
        }
        if ownsSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
