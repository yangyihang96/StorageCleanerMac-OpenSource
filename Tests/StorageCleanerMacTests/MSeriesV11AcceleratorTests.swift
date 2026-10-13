import Foundation
import XCTest
@testable import StorageCleanerMac

/// Every workload in this class is a substitute. No Metal/VT/Core ML dispatch.
final class MSeriesV11AcceleratorTests: XCTestCase {
    func testCapabilityMatrixKeepsNullConflictAndHardwareAbsenceDistinct() {
        let rows: [(Bool?, Bool?, String, String?, Bool)] = [
            (nil, nil, "unknown", "runtimeCapabilityUnverified", true),
            (nil, false, "unknown", "systemUnavailable", false),
            (nil, true, "available", "catalogUnverified", true),
            (false, nil, "unsupported", "noHardwareUnit", false),
            (false, false, "unsupported", "noHardwareUnit", false),
            (false, true, "unknown", "capabilityConflict", true),
            (true, nil, "unknown", "runtimeCapabilityUnverified", true),
            (true, false, "unknown", "capabilityConflict", false),
            (true, true, "available", nil, true)
        ]
        for (catalog, runtime, state, reason, canRun) in rows {
            let gate = MSeriesV11AcceleratorGate.resolve(.init(
                catalogSupported: catalog, runtimeSupported: runtime
            ))
            XCTAssertEqual(gate.availability, state)
            XCTAssertEqual(gate.reasonCode, reason)
            XCTAssertEqual(gate.canRun, canRun)
            XCTAssertFalse(gate.canClaimDedicatedHardware, "No UsingHardware evidence yet")
        }
        XCTAssertTrue(MSeriesV11AcceleratorGate.resolve(.init(
            catalogSupported: true, runtimeSupported: true, hardwarePathConfirmed: true
        )).canClaimDedicatedHardware)
        XCTAssertFalse(MSeriesV11AcceleratorGate.resolve(.init(
            catalogSupported: true, runtimeSupported: true, hardwarePathConfirmed: false
        )).canRun)
    }

    func testMetalFamilyEvidenceRecognizesM5AndDoesNotGuessFutureFamily() {
        XCTAssertEqual(MSeriesV11RayTracingSupport.runtime(
            supportsRaytracing: true, supportedFamilies: ["apple10"]
        ), true)
        XCTAssertEqual(MSeriesV11RayTracingSupport.runtime(
            supportsRaytracing: true, supportedFamilies: ["apple9"]
        ), true)
        XCTAssertNil(MSeriesV11RayTracingSupport.runtime(
            supportsRaytracing: true, supportedFamilies: ["apple11"]
        ))
        XCTAssertNil(MSeriesV11RayTracingSupport.runtime(
            supportsRaytracing: true, supportedFamilies: ["apple7"]
        ), "API support alone is not evidence of dedicated RT hardware")
        XCTAssertEqual(MSeriesV11RayTracingSupport.runtime(
            supportsRaytracing: false, supportedFamilies: ["apple10"]
        ), false)
        XCTAssertNil(MSeriesV11RayTracingSupport.runtime(supportsRaytracing: nil, supportedFamilies: []))
    }

    func testAV1AndANEGatesCannotBeBypassedWithCapabilityBooleans() async {
        let runner = V11AcceleratorSubstitute()
        let collector = MSeriesV11Accelerators(runner: runner)
        let caps = Dictionary(uniqueKeysWithValues: MSeriesV11AcceleratorID.allCases.map {
            ($0, MSeriesV11AcceleratorCapability(
                catalogSupported: true, runtimeSupported: true, hardwarePathConfirmed: true
            ))
        })
        let av1 = await collector.measure(.av1, capabilities: caps)
        let ane = await collector.measure(.smallModel, capabilities: caps)
        XCTAssertEqual(av1.first?.availability, "notImplemented")
        XCTAssertEqual(av1.first?.reasonCode, "av1FixtureMissing")
        let absentAV1 = await collector.measure(.av1, capabilities: [.av1Decode: .init(catalogSupported: false, runtimeSupported: false)])
        XCTAssertEqual(absentAV1.first?.availability, "unsupported")
        XCTAssertEqual(absentAV1.first?.reasonCode, "noHardwareUnit")
        XCTAssertEqual(ane.count, 3)
        XCTAssertTrue(ane.allSatisfy { $0.availability == "notImplemented" && $0.reasonCode == "aneAllocationUnverified" })
        XCTAssertTrue((av1 + ane).allSatisfy { $0.result().metric == nil && $0.result().allocationEvidence == nil })
        let calls = await runner.events
        XCTAssertTrue(calls.isEmpty)
    }

    func testPairedGateDoesNotLabelSupportedDecoderAsAbsentWhenEncoderCannotRun() async {
        let runner = V11AcceleratorSubstitute()
        let results = await MSeriesV11Accelerators(runner: runner).measure(.media(.proRes422), capabilities: [
            .proResEncode: .init(catalogSupported: false, runtimeSupported: false),
            .proResDecode: .init(catalogSupported: true, runtimeSupported: true)
        ])
        XCTAssertEqual(results[0].availability, "unsupported")
        XCTAssertEqual(results[1].availability, "unknown")
        XCTAssertEqual(results[1].reasonCode, "pairedFixtureDependencyUnavailable")
        let events = await runner.events
        XCTAssertTrue(events.isEmpty)
    }

    func testMediaCollectsThreePairsAndOnlyOneWarmupWithHardwareEvidence() async {
        for codec in VideoMediaBenchmarkV11Codec.allCases {
            let runner = V11AcceleratorSubstitute()
            let unit = MSeriesV11AcceleratorUnit.media(codec)
            let caps = Dictionary(uniqueKeysWithValues: unit.ids.map {
                ($0, MSeriesV11AcceleratorCapability(catalogSupported: true, runtimeSupported: true))
            })
            let results = await MSeriesV11Accelerators(runner: runner).measure(unit, capabilities: caps)
            XCTAssertEqual(results.map(\.id), unit.ids)
            XCTAssertTrue(results.allSatisfy { $0.samples.count == 3 && $0.canClaimDedicatedHardware })
            XCTAssertTrue(results.allSatisfy { $0.availability == "available" && $0.passesCV })
            XCTAssertEqual(results.first?.allocationEvidenceKind, "runtimeReadback")
            let calls = await runner.events
            XCTAssertEqual(calls, ["\(codec.rawValue):true", "\(codec.rawValue):false", "\(codec.rawValue):false"])
        }
    }

    func testUnknownCatalogRemainsRawOnlyAfterRuntimeReadback() async {
        let runner = V11AcceleratorSubstitute()
        let results = await MSeriesV11Accelerators(runner: runner).measure(.media(.hevc), capabilities: [:])
        XCTAssertTrue(results.allSatisfy { $0.samples.count == 3 && $0.availability == "available" })
        XCTAssertTrue(results.allSatisfy { $0.reasonCode == "catalogUnverified" && !$0.canClaimDedicatedHardware })
        XCTAssertEqual(results[0].result().metric?.samples.count, 3)
    }

    func testConflictingCatalogKeepsRuntimeValuesWithoutHardwareClaim() async {
        let runner = V11AcceleratorSubstitute()
        let caps: [MSeriesV11AcceleratorID: MSeriesV11AcceleratorCapability] = [
            .h264Encode: .init(catalogSupported: false, runtimeSupported: true),
            .h264Decode: .init(catalogSupported: false, runtimeSupported: true)
        ]
        let results = await MSeriesV11Accelerators(runner: runner).measure(.media(.h264), capabilities: caps)
        XCTAssertTrue(results.allSatisfy { $0.reasonCode == "capabilityConflict" && $0.samples.count == 3 })
        XCTAssertTrue(results.allSatisfy { !$0.canClaimDedicatedHardware })
    }

    func testCodecSubstitutionAndSoftwareHardwareReadbackFailBehaviorally() async {
        for mutation in [V11AcceleratorSubstitute.Mutation.wrongCodec, .softwarePath, .wrongFixture, .zeroChecksum] {
            let runner = V11AcceleratorSubstitute(mutation: mutation)
            let results = await MSeriesV11Accelerators(runner: runner).measure(.media(.hevc), capabilities: [:])
            XCTAssertTrue(results.allSatisfy { $0.samples.isEmpty && !$0.canClaimDedicatedHardware })
            XCTAssertTrue(results.allSatisfy { $0.availability != "unsupported" })
            XCTAssertEqual(results[0].reasonCode, mutation == .softwarePath ? "hardwarePathUnverified" : "invalidOutput")
            let events = await runner.events
            XCTAssertEqual(events.count, 1)
        }
    }

    func testResourceFailurePreservesPartialSamplesAndIsNotNoHardware() async {
        let runner = V11AcceleratorSubstitute(failAt: 2, failure: .resource)
        let results = await MSeriesV11Accelerators(runner: runner).measure(.media(.proRes422), capabilities: [:])
        XCTAssertTrue(results.allSatisfy { $0.availability == "insufficientResources" && $0.reasonCode == "resourceLimit" })
        XCTAssertTrue(results.allSatisfy { $0.samples.count == 1 && $0.result().metric?.samples.count == 1 })
        let events = await runner.events
        XCTAssertEqual(events.count, 2)
    }

    func testRuntimeSessionUnavailabilityIsConflictOrUnknownNeverAbsent() async {
        for declared in [true, nil] as [Bool?] {
            let runner = V11AcceleratorSubstitute(failAt: 1, failure: .runtimeUnavailable)
            let results = await MSeriesV11Accelerators(runner: runner).measure(.media(.hevc), capabilities: [
                .hevcEncode: .init(catalogSupported: declared), .hevcDecode: .init(catalogSupported: declared)
            ])
            XCTAssertTrue(results.allSatisfy { $0.availability == "unknown" && $0.samples.isEmpty })
            XCTAssertEqual(results[0].reasonCode, declared == true ? "capabilityConflict" : "systemUnavailable")
        }
    }

    func testSharedEncodedBudgetRejectsBeforeWorkloadDispatch() async {
        let runner = V11AcceleratorSubstitute()
        let results = await MSeriesV11Accelerators(runner: runner).measure(
            .media(.proRes422), capabilities: [:], maximumEncodedBytes: 0
        )
        XCTAssertEqual(results[0].reasonCode, "encodedBufferBudget")
        XCTAssertEqual(results[0].availability, "insufficientResources")
        let events = await runner.events
        XCTAssertTrue(events.isEmpty)
    }

    func testV11CVEndpointsUseTenPercentEncodeFivePercentDecodeAndTensor() async {
        let runner = V11AcceleratorSubstitute(values: [90, 100, 110], decodeValues: [95, 100, 105])
        let results = await MSeriesV11Accelerators(runner: runner).measure(.media(.h264), capabilities: [:])
        XCTAssertEqual(results[0].sampleCV!, 0.10, accuracy: 1e-12)
        XCTAssertEqual(results[1].sampleCV!, 0.05, accuracy: 1e-12)
        XCTAssertTrue(results.allSatisfy(\.passesCV))
        let unstable = await MSeriesV11Accelerators(runner: V11AcceleratorSubstitute(values: [100, 100, 130])).measure(
            .tensorFP16, capabilities: [:]
        )
        XCTAssertEqual(unstable[0].samples.count, 3)
        XCTAssertEqual(unstable[0].reasonCode, "cvExceeded")
        XCTAssertFalse(unstable[0].passesCV)
        XCTAssertEqual(MSeriesV11AcceleratorID.tensorFP16.cvLimit, 0.05)
        XCTAssertEqual(MSeriesV11AcceleratorID.rayTracingBuild.cvLimit, 0.10)
    }

    func testRayTracingSharesOneWarmupAndTensorStaysMPSMetal() async {
        let runner = V11AcceleratorSubstitute()
        let collector = MSeriesV11Accelerators(runner: runner)
        let ray = await collector.measure(.rayTracing, capabilities: [:])
        let tensor = await collector.measure(.tensorFP16, capabilities: [:])
        XCTAssertEqual(ray.map(\.id), [.rayTracingBuild, .rayTracingTraversal])
        XCTAssertTrue(ray.allSatisfy { $0.samples.count == 3 && $0.allocationEvidenceKind == "metalHardwareFamily" })
        XCTAssertEqual(tensor[0].allocationEvidenceKind, "mpsMetal")
        XCTAssertEqual(tensor[0].result().metric?.contract.timing, "gpu-timeline")
        let events = await runner.events
        XCTAssertEqual(events, ["ray:true", "ray:false", "ray:false", "tensor", "tensor", "tensor"])
    }

    func testSampleDeadlineStopsNextDispatchWithoutAcceptingLateSample() async {
        let clock = V11AcceleratorTestClock()
        let runner = V11AcceleratorSubstitute(clock: clock, elapsedNs: 21_000_000_000)
        let results = await MSeriesV11Accelerators(runner: runner, clock: clock).measure(.rayTracing, capabilities: [:])
        XCTAssertTrue(results.allSatisfy { $0.availability == "failed" && $0.reasonCode == "timedOut" && $0.samples.isEmpty })
        let calls = await runner.events
        XCTAssertEqual(calls.count, 1)
    }

    func testThermalProtectionStopsBeforeDispatch() async {
        let runner = V11AcceleratorSubstitute()
        let results = await MSeriesV11Accelerators(runner: runner, checkEnvironment: {
            throw MSeriesV11AcceleratorError.thermalProtection
        }).measure(.tensorFP16, capabilities: [:])
        XCTAssertEqual(results[0].reasonCode, "thermal-protection")
        let calls = await runner.events
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancellationAwaitsSubstituteDrainAndDoesNotSubmitSecondSample() async {
        let runner = V11AcceleratorSubstitute(suspend: true)
        let task = Task { await MSeriesV11Accelerators(runner: runner).measure(.media(.h264), capabilities: [:]) }
        await runner.waitForEntry()
        task.cancel()
        let results = await task.value
        let drained = await runner.drained
        let events = await runner.events
        XCTAssertTrue(drained)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(results.allSatisfy { $0.availability == "cancelled" && $0.samples.isEmpty })
    }

    func testV11MediaKernelUsesFixedFixtureAndInjectedDriverWithoutRepeatedWarmup() async throws {
        for codec in VideoMediaBenchmarkV11Codec.allCases {
            let clock = V11AcceleratorTestClock()
            let driver = V11MediaDriverSubstitute(clock: clock)
            let result = try await VideoMediaBenchmarkKernel(clock: clock).runV11(
                codec: codec, warmUp: false, v11DriverFactory: { driver }
            )
            let workload = await driver.workload
            XCTAssertEqual(workload?.width, 1_920)
            XCTAssertEqual(workload?.height, 1_080)
            XCTAssertEqual(workload?.frameCount, 60)
            XCTAssertEqual(workload?.averageBitRate, codec == .proRes422 ? 0 : 12_000_000)
            XCTAssertEqual(result.semanticSummary.codec, codec.name)
            XCTAssertTrue(result.semanticSummary.encoderUsedHardware && result.semanticSummary.decoderUsedHardware)
            let calls = await driver.events
            XCTAssertEqual(calls, ["prepare", "encode", "prepareDecoder", "decode", "tearDown"])
            XCTAssertEqual(result.encodeSample.value, 1_920 * 1_080 * 60 / 1e6 / 0.1, accuracy: 1e-6)
        }
    }
}

private final class V11AcceleratorTestClock: BenchmarkKernelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    func nowNanoseconds() -> UInt64 { lock.withLock { value } }
    func advance(_ amount: UInt64) { lock.withLock { value += amount } }
}

private actor V11AcceleratorSubstitute: MSeriesV11AcceleratorWorkloadRunning {
    enum Mutation: Equatable { case none, wrongCodec, softwarePath, wrongFixture, zeroChecksum }
    enum Failure { case resource, runtimeUnavailable }
    let mutation: Mutation
    let values: [Double]
    let decodeValues: [Double]
    let failAt: Int?
    let failure: Failure
    let clock: V11AcceleratorTestClock?
    let elapsedNs: UInt64
    let suspend: Bool
    var events: [String] = []
    var drained = false
    private var entryWaiter: CheckedContinuation<Void, Never>?

    init(
        mutation: Mutation = .none, values: [Double] = [100, 100, 100],
        decodeValues: [Double] = [100, 100, 100], failAt: Int? = nil,
        failure: Failure = .resource, clock: V11AcceleratorTestClock? = nil,
        elapsedNs: UInt64 = 1_000_000_000, suspend: Bool = false
    ) {
        self.mutation = mutation; self.values = values; self.decodeValues = decodeValues
        self.failAt = failAt; self.failure = failure; self.clock = clock
        self.elapsedNs = elapsedNs; self.suspend = suspend
    }

    func waitForEntry() async {
        if !events.isEmpty { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    private func enter(_ event: String) async throws {
        events.append(event)
        entryWaiter?.resume(); entryWaiter = nil
        defer { drained = true }
        if suspend { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        clock?.advance(elapsedNs)
        if failAt == events.count {
            switch failure {
            case .resource: throw BenchmarkKernelError.resourceLimit
            case .runtimeUnavailable: throw VideoMediaBenchmarkError.unsupported(.h264HardwareEncoder)
            }
        }
    }

    private func sample(_ value: Double) -> BenchmarkComponentSample {
        .init(value: value, elapsedSeconds: 0.1, checksum: mutation == .zeroChecksum ? 0 : 17)
    }

    func runV11MediaSample(
        codec: VideoMediaBenchmarkV11Codec, warmUp: Bool, maximumEncodedBytes: Int
    ) async throws -> VideoMediaBenchmarkKernel.RunResult {
        try await enter("\(codec.rawValue):\(warmUp)")
        let index = (events.count - 1) % 3
        return .init(
            encodeSample: sample(values[index]), decodeSample: sample(decodeValues[index]),
            semanticSummary: .init(
                codec: mutation == .wrongCodec ? "H.264" : codec.name,
                width: mutation == .wrongFixture ? 640 : 1_920, height: 1_080,
                frameCount: 60, framesPerSecond: 60, encodedFrameCount: 60, decodedFrameCount: 60,
                presentationTimeValues: (0..<60).map(Int64.init), encodedByteCount: 1_024,
                encoderUsedHardware: mutation != .softwarePath, decoderUsedHardware: true,
                decodedContentChecksum: 19, checksum: 17
            ), ranOnMainThread: false
        )
    }

    func runV11RayTracingSample(warmUp: Bool) async throws -> MetalRayTracingBenchmarkKernel.RunResult {
        try await enter("ray:\(warmUp)")
        return .init(buildSample: sample(100), traversalSample: sample(100),
                     triangleCount: 131_072, rayCount: 262_144, traversalPassCount: 64,
                     hitCount: 1_000, hardwareFamily: .apple10, ranOnMainThread: false)
    }

    func runV11TensorSample() async throws -> BenchmarkComponentSample {
        try await enter("tensor")
        return sample(values[(events.count - 1) % 3])
    }
}

private actor V11MediaDriverSubstitute: VideoMediaBenchmarkDriving {
    let clock: V11AcceleratorTestClock
    var workload: VideoMediaBenchmarkWorkload?
    var events: [String] = []
    init(clock: V11AcceleratorTestClock) { self.clock = clock }
    func prepare(workload: VideoMediaBenchmarkWorkload) { self.workload = workload; events.append("prepare") }
    func warmUp() { events.append("warmUp") }
    func encode() throws -> VideoMediaBenchmarkEncodeEvidence {
        events.append("encode"); clock.advance(100_000_000)
        let w = try XCTUnwrap(workload)
        return .init(frameCount: w.frameCount, presentationTimeValues: (0..<w.frameCount).map(Int64.init),
                     frameDimensions: Array(repeating: .init(width: w.width, height: w.height), count: w.frameCount),
                     encodedByteCount: 1_024, usedHardware: true, ranOnMainThread: false)
    }
    func prepareDecoder() { events.append("prepareDecoder") }
    func decode() throws -> VideoMediaBenchmarkDecodeEvidence {
        events.append("decode"); clock.advance(200_000_000)
        let w = try XCTUnwrap(workload)
        let content = (0..<w.frameCount).map { frame -> VideoMediaBenchmarkDecodedFrameContentEvidence in
            let luma = [1, 3, 5, 7].flatMap { numerator in
                (0..<8).map { band in UInt8(16 + ((frame * 7 + (w.height * numerator / 8) * 3 + band * 23) % 220)) }
            }
            let chroma = [1, 3, 5, 7].flatMap { numerator in
                (0..<8).map { _ in
                    let value = UInt8(96 + ((frame * 5 + (w.height * numerator / 8) / 2) % 64))
                    return VideoMediaBenchmarkChromaProbe(cb: value, cr: value)
                }
            }
            return .init(presentationTimeValue: Int64(frame), lumaSamples: luma, chromaSamples: chroma,
                         capturedDigest: VideoMediaBenchmarkKernel.decodedContentIntegrityDigest(
                            presentationTimeValue: Int64(frame), lumaSamples: luma, chromaSamples: chroma
                         ))
        }
        return .init(frameCount: w.frameCount, presentationTimeValues: (0..<w.frameCount).map(Int64.init),
                     frameDimensions: Array(repeating: .init(width: w.width, height: w.height), count: w.frameCount),
                     frameContentEvidence: content, usedHardware: true, ranOnMainThread: false)
    }
    func cancel() { events.append("cancel") }
    func tearDown() { events.append("tearDown") }
}
