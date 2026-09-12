import Foundation
import XCTest
@testable import StorageCleanerMac

final class VideoMediaBenchmarkKernelTests: XCTestCase {
    func testStandardAndTestingConfigurationsAreFixedAndBounded() {
        let standardQuick = VideoMediaBenchmarkKernel.Configuration.standard.quick
        XCTAssertEqual(standardQuick.width, 1_920)
        XCTAssertEqual(standardQuick.height, 1_080)
        XCTAssertEqual(standardQuick.frameCount, 60)
        XCTAssertEqual(standardQuick.framesPerSecond, 60)
        XCTAssertEqual(standardQuick.averageBitRate, 12_000_000)

        let standardFull = VideoMediaBenchmarkKernel.Configuration.standard.full
        XCTAssertEqual(standardFull.width, 3_840)
        XCTAssertEqual(standardFull.height, 2_160)
        XCTAssertEqual(standardFull.frameCount, 30)
        XCTAssertLessThanOrEqual(
            standardFull.maximumEncodedBytes,
            VideoMediaBenchmarkKernel.maximumEncodedBytes
        )

        let testing = VideoMediaBenchmarkKernel.Configuration.testing.quick
        XCTAssertEqual(testing.width, 320)
        XCTAssertEqual(testing.height, 180)
        XCTAssertEqual(testing.frameCount, 8)
        XCTAssertLessThan(testing.maximumElapsedSeconds, standardQuick.maximumElapsedSeconds)
    }

    func testComputesIndependentEncodeAndDecodeMPixRatesAndSemanticSummary() async throws {
        let clock = ManualVideoMediaBenchmarkClock()
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            clock: clock,
            encodeNanoseconds: 200_000_000,
            decodeNanoseconds: 400_000_000
        )

        let result = try await VideoMediaBenchmarkKernel(
            configuration: .testing,
            clock: clock,
            driverFactory: { driver }
        ).run(profile: .quick)

        let megapixels = Double(320 * 180 * 8) / 1_000_000
        XCTAssertEqual(result.encodeSample.elapsedSeconds, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(result.decodeSample.elapsedSeconds, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(result.encodeSample.value, megapixels / 0.2, accuracy: 0.000_001)
        XCTAssertEqual(result.decodeSample.value, megapixels / 0.4, accuracy: 0.000_001)
        XCTAssertEqual(result.encodeSample.checksum, result.decodeSample.checksum)
        XCTAssertGreaterThan(result.encodeSample.checksum, 0)
        XCTAssertFalse(result.ranOnMainThread)

        let summary = result.semanticSummary
        XCTAssertEqual(summary.codec, "H.264")
        XCTAssertEqual(summary.width, 320)
        XCTAssertEqual(summary.height, 180)
        XCTAssertEqual(summary.encodedFrameCount, 8)
        XCTAssertEqual(summary.decodedFrameCount, 8)
        XCTAssertEqual(summary.presentationTimeValues, (0..<8).map(Int64.init))
        XCTAssertTrue(summary.encoderUsedHardware)
        XCTAssertTrue(summary.decoderUsedHardware)
        XCTAssertGreaterThan(summary.encodedByteCount, 0)
        XCTAssertGreaterThan(summary.decodedContentChecksum, 0)

        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            [.prepare, .warmUp, .encode, .prepareDecoder, .decode, .tearDown]
        )
    }

    func testRejectsOversizedWorkloadBeforeCreatingDriver() async {
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(recorder: recorder)
        let testing = VideoMediaBenchmarkKernel.Configuration.testing
        let configuration = VideoMediaBenchmarkKernel.Configuration(
            quick: VideoMediaBenchmarkKernel.Limits(
                width: VideoMediaBenchmarkKernel.maximumWidth + 2,
                height: 180,
                frameCount: 8,
                framesPerSecond: 30,
                averageBitRate: 1_000_000,
                maximumEncodedBytes: 4 * 1_024 * 1_024,
                maximumElapsedSeconds: 8
            ),
            full: testing.full
        )

        await XCTAssertVideoMediaThrowsError(
            try await VideoMediaBenchmarkKernel(
                configuration: configuration,
                driverFactory: { driver }
            ).run(profile: .quick)
        ) { error in
            XCTAssertEqual(error as? VideoMediaBenchmarkError, .resourceLimit)
        }
        let events = await recorder.snapshot()
        XCTAssertTrue(events.isEmpty)
    }

    func testRejectsWrongPTSAndAlwaysCleansUp() async {
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            mutation: .wrongEncodePTS
        )

        await XCTAssertVideoMediaThrowsError(
            try await VideoMediaBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run(profile: .quick)
        ) { error in
            XCTAssertEqual(
                error as? VideoMediaBenchmarkError,
                .invalidOutput(.presentationTimestamps)
            )
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
        XCTAssertEqual(events.filter { $0 == .tearDown }.count, 1)
    }

    func testRejectsWrongDecodedDimensions() async {
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            mutation: .wrongDecodeDimensions
        )

        await XCTAssertVideoMediaThrowsError(
            try await VideoMediaBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run(profile: .quick)
        ) { error in
            XCTAssertEqual(
                error as? VideoMediaBenchmarkError,
                .invalidOutput(.dimensions)
            )
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testRejectsAllBlackDecodedPixelEvidence() async {
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            mutation: .blackDecodedContent
        )

        await XCTAssertVideoMediaThrowsError(
            try await VideoMediaBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run(profile: .quick)
        ) { error in
            XCTAssertEqual(
                error as? VideoMediaBenchmarkError,
                .invalidOutput(.decodedContent)
            )
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testRejectsDecodedPixelEvidenceWithIncorrectIntegrityDigest() async {
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            mutation: .wrongContentDigest
        )

        await XCTAssertVideoMediaThrowsError(
            try await VideoMediaBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run(profile: .quick)
        ) { error in
            XCTAssertEqual(
                error as? VideoMediaBenchmarkError,
                .invalidOutput(.decodedContent)
            )
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testRejectsSemanticallyWrongDecodedPixelPatternWithValidDigest() async {
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            mutation: .wrongDecodedContent
        )

        await XCTAssertVideoMediaThrowsError(
            try await VideoMediaBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run(profile: .quick)
        ) { error in
            XCTAssertEqual(
                error as? VideoMediaBenchmarkError,
                .invalidOutput(.decodedContent)
            )
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testRejectsSoftwareFallbackAsUnsupportedHardwarePath() async {
        for mutation in [
            FakeVideoMediaMutation.softwareEncoder,
            FakeVideoMediaMutation.softwareDecoder
        ] {
            let recorder = VideoMediaEventRecorder()
            let driver = FakeVideoMediaBenchmarkDriver(
                recorder: recorder,
                mutation: mutation
            )

            await XCTAssertVideoMediaThrowsError(
                try await VideoMediaBenchmarkKernel(
                    configuration: .testing,
                    driverFactory: { driver }
                ).run(profile: .quick)
            ) { error in
                let expectedCapability: VideoMediaBenchmarkCapability = mutation == .softwareEncoder
                    ? .h264HardwareEncoder
                    : .h264HardwareDecoder
                XCTAssertEqual(
                    error as? VideoMediaBenchmarkError,
                    .unsupported(expectedCapability)
                )
            }
            let events = await recorder.snapshot()
            XCTAssertEqual(events.last, .tearDown)
        }
    }

    func testPreservesUnsupportedAndTemporarilyUnavailableErrors() async {
        let cases: [(FakeVideoMediaPhase, VideoMediaBenchmarkError)] = [
            (.encode, .unsupported(.h264HardwareEncoder)),
            (.prepareDecoder, .temporarilyUnavailable(.h264HardwareDecoder))
        ]

        for testCase in cases {
            let recorder = VideoMediaEventRecorder()
            let driver = FakeVideoMediaBenchmarkDriver(
                recorder: recorder,
                failurePhase: testCase.0,
                failure: testCase.1
            )

            await XCTAssertVideoMediaThrowsError(
                try await VideoMediaBenchmarkKernel(
                    configuration: .testing,
                    driverFactory: { driver }
                ).run(profile: .quick)
            ) { error in
                XCTAssertEqual(error as? VideoMediaBenchmarkError, testCase.1)
            }
            let events = await recorder.snapshot()
            XCTAssertEqual(events.last, .tearDown)
        }
    }

    func testWholeRunTimeoutPublishesNoMetricAndCleansUp() async {
        let clock = ManualVideoMediaBenchmarkClock()
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            clock: clock,
            encodeNanoseconds: 8_100_000_000
        )

        await XCTAssertVideoMediaThrowsError(
            try await VideoMediaBenchmarkKernel(
                configuration: .testing,
                clock: clock,
                driverFactory: { driver }
            ).run(profile: .quick)
        ) { error in
            XCTAssertEqual(
                error as? VideoMediaBenchmarkError,
                .timedOut(.h264HardwareEncoder)
            )
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
        XCTAssertFalse(events.contains(.prepareDecoder))
    }

    func testDecodeTimeoutIdentifiesHardwareDecoderCapability() async {
        let clock = ManualVideoMediaBenchmarkClock()
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            clock: clock,
            decodeNanoseconds: 8_100_000_000
        )

        await XCTAssertVideoMediaThrowsError(
            try await VideoMediaBenchmarkKernel(
                configuration: .testing,
                clock: clock,
                driverFactory: { driver }
            ).run(profile: .quick)
        ) { error in
            XCTAssertEqual(
                error as? VideoMediaBenchmarkError,
                .timedOut(.h264HardwareDecoder)
            )
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
        XCTAssertTrue(events.contains(.decode))
    }

    func testCancellationCallsDriverCancelAndWaitsForCleanup() async {
        let recorder = VideoMediaEventRecorder()
        let driver = FakeVideoMediaBenchmarkDriver(
            recorder: recorder,
            waitsForCancellation: true
        )
        let task = Task {
            try await VideoMediaBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run(profile: .quick)
        }

        await recorder.wait(until: .encode)
        task.cancel()

        await XCTAssertVideoMediaThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let events = await recorder.snapshot()
        XCTAssertTrue(events.contains(.cancel))
        XCTAssertEqual(events.last, .tearDown)
        XCTAssertEqual(events.filter { $0 == .tearDown }.count, 1)
    }

    func testSystemDriverCompletesTestingWorkloadWhenHardwareIsAvailable() async throws {
        do {
            var results: [VideoMediaBenchmarkKernel.RunResult] = []
            for _ in 0..<3 {
                results.append(
                    try await VideoMediaBenchmarkKernel(
                        configuration: .testing
                    ).run(profile: .quick)
                )
            }
            guard let result = results.first else {
                return XCTFail("Expected three hardware codec samples")
            }
            XCTAssertGreaterThan(result.encodeSample.value, 0)
            XCTAssertGreaterThan(result.decodeSample.value, 0)
            XCTAssertGreaterThan(result.encodeSample.elapsedSeconds, 0)
            XCTAssertGreaterThan(result.decodeSample.elapsedSeconds, 0)
            XCTAssertFalse(result.ranOnMainThread)
            XCTAssertTrue(result.semanticSummary.encoderUsedHardware)
            XCTAssertTrue(result.semanticSummary.decoderUsedHardware)
            XCTAssertEqual(result.semanticSummary.encodedFrameCount, 8)
            XCTAssertEqual(result.semanticSummary.decodedFrameCount, 8)
            XCTAssertGreaterThan(result.semanticSummary.decodedContentChecksum, 0)
            XCTAssertEqual(
                Set(results.map(\.semanticSummary.decodedContentChecksum)).count,
                1,
                "Quantized decoded-pixel checksum must be stable across three runs"
            )
            XCTAssertEqual(
                Set(results.map(\.semanticSummary.checksum)).count,
                1,
                "Summary checksum must include stable decoded-pixel evidence"
            )
        } catch let error as VideoMediaBenchmarkError {
            switch error {
            case .unsupported, .temporarilyUnavailable:
                throw XCTSkip("Hardware H.264 codec is unavailable in this environment: \(error)")
            default:
                throw error
            }
        }
    }
}

private enum VideoMediaEvent: Equatable, Sendable {
    case prepare
    case warmUp
    case encode
    case prepareDecoder
    case decode
    case cancel
    case tearDown
}

private actor VideoMediaEventRecorder {
    private var events: [VideoMediaEvent] = []

    func append(_ event: VideoMediaEvent) {
        events.append(event)
    }

    func snapshot() -> [VideoMediaEvent] {
        events
    }

    func wait(until event: VideoMediaEvent) async {
        while !events.contains(event) {
            await Task.yield()
        }
    }
}

private final class ManualVideoMediaBenchmarkClock: BenchmarkKernelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1

    func nowNanoseconds() -> UInt64 {
        lock.withLock { value }
    }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { value &+= nanoseconds }
    }
}

private enum FakeVideoMediaPhase: Equatable, Sendable {
    case prepare
    case warmUp
    case encode
    case prepareDecoder
    case decode
}

private enum FakeVideoMediaMutation: Equatable, Sendable {
    case none
    case wrongEncodePTS
    case wrongDecodeDimensions
    case blackDecodedContent
    case wrongDecodedContent
    case wrongContentDigest
    case softwareEncoder
    case softwareDecoder
}

private actor FakeVideoMediaBenchmarkDriver: VideoMediaBenchmarkDriving {
    private let recorder: VideoMediaEventRecorder
    private let clock: ManualVideoMediaBenchmarkClock?
    private let encodeNanoseconds: UInt64
    private let decodeNanoseconds: UInt64
    private let mutation: FakeVideoMediaMutation
    private let failurePhase: FakeVideoMediaPhase?
    private let failure: VideoMediaBenchmarkError?
    private let waitsForCancellation: Bool

    private var workload: VideoMediaBenchmarkWorkload?
    private var cancelled = false
    private var didRecordCancel = false
    private var didTearDown = false

    init(
        recorder: VideoMediaEventRecorder,
        clock: ManualVideoMediaBenchmarkClock? = nil,
        encodeNanoseconds: UInt64 = 100_000_000,
        decodeNanoseconds: UInt64 = 200_000_000,
        mutation: FakeVideoMediaMutation = .none,
        failurePhase: FakeVideoMediaPhase? = nil,
        failure: VideoMediaBenchmarkError? = nil,
        waitsForCancellation: Bool = false
    ) {
        self.recorder = recorder
        self.clock = clock
        self.encodeNanoseconds = encodeNanoseconds
        self.decodeNanoseconds = decodeNanoseconds
        self.mutation = mutation
        self.failurePhase = failurePhase
        self.failure = failure
        self.waitsForCancellation = waitsForCancellation
    }

    func prepare(workload: VideoMediaBenchmarkWorkload) async throws {
        self.workload = workload
        await recorder.append(.prepare)
        try failIfNeeded(.prepare)
    }

    func warmUp() async throws {
        await recorder.append(.warmUp)
        try failIfNeeded(.warmUp)
    }

    func encode() async throws -> VideoMediaBenchmarkEncodeEvidence {
        await recorder.append(.encode)
        try failIfNeeded(.encode)
        if waitsForCancellation {
            while !cancelled && !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        guard let workload else {
            throw VideoMediaBenchmarkError.systemFailure(-1)
        }
        clock?.advance(by: encodeNanoseconds)

        var presentationTimes = (0..<workload.frameCount).map(Int64.init)
        if mutation == .wrongEncodePTS {
            presentationTimes[0] = 99
        }
        let dimensions = Array(
            repeating: VideoMediaBenchmarkDimensions(
                width: workload.width,
                height: workload.height
            ),
            count: workload.frameCount
        )
        return VideoMediaBenchmarkEncodeEvidence(
            frameCount: workload.frameCount,
            presentationTimeValues: presentationTimes,
            frameDimensions: dimensions,
            encodedByteCount: workload.frameCount * 1_024,
            usedHardware: mutation != .softwareEncoder,
            ranOnMainThread: false
        )
    }

    func prepareDecoder() async throws {
        await recorder.append(.prepareDecoder)
        try failIfNeeded(.prepareDecoder)
    }

    func decode() async throws -> VideoMediaBenchmarkDecodeEvidence {
        await recorder.append(.decode)
        try failIfNeeded(.decode)
        guard let workload else {
            throw VideoMediaBenchmarkError.systemFailure(-1)
        }
        clock?.advance(by: decodeNanoseconds)

        var dimensions = Array(
            repeating: VideoMediaBenchmarkDimensions(
                width: workload.width,
                height: workload.height
            ),
            count: workload.frameCount
        )
        if mutation == .wrongDecodeDimensions {
            dimensions[0] = VideoMediaBenchmarkDimensions(
                width: workload.width + 2,
                height: workload.height
            )
        }
        let contentEvidence = makeFakeDecodedContentEvidence(
            workload: workload,
            mutation: mutation
        )
        return VideoMediaBenchmarkDecodeEvidence(
            frameCount: workload.frameCount,
            presentationTimeValues: (0..<workload.frameCount).map(Int64.init),
            frameDimensions: dimensions,
            frameContentEvidence: contentEvidence,
            usedHardware: mutation != .softwareDecoder,
            ranOnMainThread: false
        )
    }

    func cancel() async {
        cancelled = true
        guard !didRecordCancel else { return }
        didRecordCancel = true
        await recorder.append(.cancel)
    }

    func tearDown() async {
        guard !didTearDown else { return }
        didTearDown = true
        await recorder.append(.tearDown)
    }

    private func failIfNeeded(_ phase: FakeVideoMediaPhase) throws {
        if phase == failurePhase, let failure {
            throw failure
        }
    }

    private func makeFakeDecodedContentEvidence(
        workload: VideoMediaBenchmarkWorkload,
        mutation: FakeVideoMediaMutation
    ) -> [VideoMediaBenchmarkDecodedFrameContentEvidence] {
        let bandWidth = max(workload.width / 8, 1)
        let coordinates = [1, 3, 5, 7].flatMap { rowNumerator in
            (0..<8).compactMap { bandIndex -> (y: Int, bandIndex: Int)? in
                let y = min((workload.height * rowNumerator) / 8, workload.height - 1)
                let start = min(bandIndex * bandWidth, workload.width)
                let end = bandIndex == 7
                    ? workload.width
                    : min(start + bandWidth, workload.width)
                guard end > start else { return nil }
                return (y: y, bandIndex: bandIndex)
            }
        }

        var evidence = [VideoMediaBenchmarkDecodedFrameContentEvidence]()
        evidence.reserveCapacity(workload.frameCount)
        for frameIndex in 0..<workload.frameCount {
            let contentFrameIndex = mutation == .wrongDecodedContent
                ? frameIndex + 17
                : frameIndex
            let lumaSamples = coordinates.map { coordinate -> UInt8 in
                guard mutation != .blackDecodedContent else { return 16 }
                return UInt8(
                    16 + (
                        (
                            contentFrameIndex * 7
                                + coordinate.y * 3
                                + coordinate.bandIndex * 23
                        ) % 220
                    )
                )
            }
            let chromaSamples = coordinates.map { coordinate in
                let value: UInt8
                if mutation == .blackDecodedContent {
                    value = 128
                } else {
                    value = UInt8(
                        96 + ((contentFrameIndex * 5 + coordinate.y / 2) % 64)
                    )
                }
                return VideoMediaBenchmarkChromaProbe(cb: value, cr: value)
            }
            let validDigest = VideoMediaBenchmarkKernel.decodedContentIntegrityDigest(
                presentationTimeValue: Int64(frameIndex),
                lumaSamples: lumaSamples,
                chromaSamples: chromaSamples
            )
            evidence.append(VideoMediaBenchmarkDecodedFrameContentEvidence(
                presentationTimeValue: Int64(frameIndex),
                lumaSamples: lumaSamples,
                chromaSamples: chromaSamples,
                capturedDigest: mutation == .wrongContentDigest
                    ? validDigest ^ 0xFF
                    : validDigest
            ))
        }
        return evidence
    }
}

private func XCTAssertVideoMediaThrowsError<T>(
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
