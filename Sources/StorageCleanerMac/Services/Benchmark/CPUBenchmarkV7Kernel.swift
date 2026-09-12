import Foundation

/// Deterministic CPU-only v7 measurements. Preparation, warm-up, and
/// calibration are deliberately outside the timed samples.
struct CPUBenchmarkV7Kernel: Sendable {
    static let workloadVersion = "cpu-measurement-v8"

    enum Profile: String, Codable, Sendable, CaseIterable {
        case quick
        case standard
    }

    enum Mode: String, Codable, Sendable {
        case singleCore
        case multiCore
    }

    enum WorkloadCategory: String, Codable, Sendable, CaseIterable {
        case byteTransform
        case imageConvolution
        case textTokenization
        case particleSimulation
    }

    struct Manifest: Equatable, Codable, Sendable {
        let id: String
        let category: BenchmarkV7Category
        let workloadVersion: String
        let mode: Mode
        let workloads: [WorkloadCategory]
        let unit: String
        let workerCount: Int
    }

    struct RunResult: Equatable, Sendable {
        let manifest: Manifest
        let samples: [BenchmarkV7RawSample]
        let calibrationChecksum: UInt64

        func metricResult(weight: Double = 0.5) throws -> BenchmarkV7MetricResult {
            BenchmarkV7MetricResult(
                manifest: BenchmarkV7MetricManifest(
                    id: manifest.id,
                    category: manifest.category,
                    unit: manifest.unit,
                    direction: .higherIsBetter,
                    weight: weight,
                    workloadVersion: manifest.workloadVersion
                ),
                samples: samples,
                statistics: try BenchmarkStatistics.summarize(samples.map(\.value))
            )
        }
    }

    struct Workload: Equatable, Sendable {
        let byteCount: Int
        let imageSide: Int
        let documentCount: Int
        let wordsPerDocument: Int
        let particleCount: Int
        let bytePasses: Int
        let convolutionPasses: Int
        let textPasses: Int
        let particlePasses: Int
        let particleSteps: Int

        static let quick = Self(
            byteCount: 128 * 1_024,
            imageSide: 128,
            documentCount: 24,
            wordsPerDocument: 80,
            particleCount: 4_096,
            bytePasses: 4,
            convolutionPasses: 3,
            textPasses: 3,
            particlePasses: 4,
            particleSteps: 12
        )

        static let standard = Self(
            byteCount: 1 * 1_024 * 1_024,
            imageSide: 512,
            documentCount: 128,
            wordsPerDocument: 160,
            particleCount: 131_072,
            bytePasses: 64,
            convolutionPasses: 32,
            textPasses: 24,
            particlePasses: 48,
            particleSteps: 32
        )

        static let testing = Self(
            byteCount: 4 * 1_024,
            imageSide: 32,
            documentCount: 4,
            wordsPerDocument: 12,
            particleCount: 128,
            bytePasses: 2,
            convolutionPasses: 2,
            textPasses: 2,
            particlePasses: 2,
            particleSteps: 3
        )
    }

    struct Configuration: Equatable, Sendable {
        let quick: Workload
        let standard: Workload
        let sampleCount: Int
        let maximumSampleSeconds: Double
        let maximumWorkerCount: Int

        static let standard = Self(
            quick: .quick,
            standard: .standard,
            sampleCount: 3,
            maximumSampleSeconds: 20,
            maximumWorkerCount: 64
        )

        static let testing = Self(
            quick: .testing,
            standard: .testing,
            sampleCount: 2,
            maximumSampleSeconds: 2,
            maximumWorkerCount: 4
        )

        func workload(for profile: Profile) -> Workload {
            switch profile {
            case .quick: quick
            case .standard: standard
            }
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    func measureSingle(profile: Profile) async throws -> RunResult {
        try validate(profile: profile)
        let worker = Task.detached(priority: .userInitiated) {
            let workload = configuration.workload(for: profile)
            let prepared = try PreparedWork(seed: Self.seed, workload: workload)
            let warmup = try Self.runMixed(prepared, workload: workload, deadline: nil)
            let calibration = try Self.runMixed(prepared, workload: workload, deadline: nil)
            guard warmup != 0, calibration != 0 else { throw BenchmarkKernelError.checksumMismatch }
            let samples = try (0..<configuration.sampleCount).map { _ in
                try Self.timedSample(
                    operationCount: Self.mixedOperationCount(workload),
                    maximumSeconds: configuration.maximumSampleSeconds
                ) {
                    try Self.runMixed(prepared, workload: workload, deadline: $0)
                }
            }
            guard samples.allSatisfy({ $0.checksum == calibration }) else {
                throw BenchmarkKernelError.checksumMismatch
            }
            return RunResult(
                manifest: Manifest(
                    id: "cpu.single.mixed",
                    category: .cpu,
                    workloadVersion: Self.workloadVersion,
                    mode: .singleCore,
                    workloads: WorkloadCategory.allCases,
                    unit: "Mops/s",
                    workerCount: 1
                ),
                samples: samples,
                calibrationChecksum: calibration
            )
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    func measureMulti(
        profile: Profile,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async throws -> RunResult {
        try validate(profile: profile)
        let workerCount = min(max(1, activeProcessorCount - 1), configuration.maximumWorkerCount)
        let worker = Task.detached(priority: .userInitiated) {
            let workload = configuration.workload(for: profile)
            let prepared = try (0..<workerCount).map {
                try PreparedWork(seed: Self.seed &+ UInt64($0), workload: workload)
            }
            let warmup = try await Self.runParallelParticles(
                prepared,
                workload: workload,
                maximumSeconds: configuration.maximumSampleSeconds,
                timed: false
            )
            let calibration = try await Self.runParallelParticles(
                prepared,
                workload: workload,
                maximumSeconds: configuration.maximumSampleSeconds,
                timed: false
            )
            guard warmup.checksum != 0, calibration.checksum != 0 else {
                throw BenchmarkKernelError.checksumMismatch
            }
            var samples: [BenchmarkV7RawSample] = []
            samples.reserveCapacity(configuration.sampleCount)
            for _ in 0..<configuration.sampleCount {
                let result = try await Self.runParallelParticles(
                    prepared,
                    workload: workload,
                    maximumSeconds: configuration.maximumSampleSeconds,
                    timed: true
                )
                guard result.checksum == calibration.checksum else {
                    throw BenchmarkKernelError.checksumMismatch
                }
                samples.append(result.sample)
            }
            return RunResult(
                manifest: Manifest(
                    id: "cpu.multi.particle",
                    category: .cpu,
                    workloadVersion: Self.workloadVersion,
                    mode: .multiCore,
                    workloads: [.particleSimulation],
                    unit: "Mops/s",
                    workerCount: workerCount
                ),
                samples: samples,
                calibrationChecksum: calibration.checksum
            )
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}

private extension CPUBenchmarkV7Kernel {
    static let seed: UInt64 = 0xA076_1D64_78BD_642F

    struct TimedParticleResult: Sendable {
        let sample: BenchmarkV7RawSample
        let checksum: UInt64
    }

    func validate(profile: Profile) throws {
        let workload = configuration.workload(for: profile)
        guard configuration.sampleCount > 0,
              configuration.sampleCount <= 10,
              configuration.maximumWorkerCount > 0,
              configuration.maximumWorkerCount <= 64,
              configuration.maximumSampleSeconds.isFinite,
              configuration.maximumSampleSeconds > 0,
              configuration.maximumSampleSeconds <= 60,
              workload.byteCount > 0,
              workload.byteCount <= 8 * 1_024 * 1_024,
              workload.imageSide >= 8,
              workload.imageSide <= 1_024,
              workload.documentCount > 0,
              workload.wordsPerDocument > 0,
              workload.particleCount > 0,
              workload.particleCount <= 1_000_000,
              [workload.bytePasses, workload.convolutionPasses, workload.textPasses,
               workload.particlePasses, workload.particleSteps].allSatisfy({ $0 > 0 && $0 <= 128 })
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }
    }

    static func mixedOperationCount(_ workload: Workload) -> Int {
        workload.byteCount * workload.bytePasses
            + workload.imageSide * workload.imageSide * workload.convolutionPasses
            + workload.documentCount * workload.wordsPerDocument * workload.textPasses
            + workload.particleCount * workload.particlePasses * workload.particleSteps
    }

    static func timedSample(
        operationCount: Int,
        maximumSeconds: Double,
        operation: (UInt64) throws -> UInt64
    ) throws -> BenchmarkV7RawSample {
        try Task.checkCancellation()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let checksum = try operation(startedAt)
        let elapsed = seconds(since: startedAt)
        guard elapsed.isFinite, elapsed > 0, elapsed <= maximumSeconds,
              checksum != 0
        else { throw BenchmarkKernelError.invalidMetric }
        return BenchmarkV7RawSample(
            value: Double(operationCount) / elapsed / 1_000_000,
            elapsedSeconds: elapsed,
            wallElapsedSeconds: elapsed,
            checksum: checksum
        )
    }

    static func runMixed(
        _ prepared: PreparedWork,
        workload: Workload,
        deadline: UInt64?
    ) throws -> UInt64 {
        var checksum = try byteTransform(prepared, passes: workload.bytePasses, deadline: deadline)
        checksum = mix(checksum, try imageConvolution(prepared, passes: workload.convolutionPasses, deadline: deadline))
        checksum = mix(checksum, try tokenize(prepared.documents, passes: workload.textPasses, deadline: deadline))
        return mix(checksum, try particles(prepared.particles, workload: workload, deadline: deadline))
    }

    static func runParallelParticles(
        _ prepared: [PreparedWork],
        workload: Workload,
        maximumSeconds: Double,
        timed: Bool
    ) async throws -> TimedParticleResult {
        let gate = CPUV7StartGate(expectedWorkerCount: prepared.count)
        let operationCount = workload.particleCount * workload.particlePasses * workload.particleSteps * prepared.count
        let results = try await withThrowingTaskGroup(of: (Int, UInt64, UInt64?).self) { group in
            for (index, worker) in prepared.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    let startedAt = timed ? try await gate.arriveAndWait() : nil
                    return (
                        index,
                        try particles(worker.particles, workload: workload, deadline: startedAt),
                        startedAt
                    )
                }
            }
            do {
                var completed: [(Int, UInt64, UInt64?)] = []
                for try await result in group { completed.append(result) }
                return completed.sorted { $0.0 < $1.0 }
            } catch {
                group.cancelAll()
                await gate.cancel()
                throw error
            }
        }
        let checksum = results.reduce(UInt64(0xCBF2_9CE4_8422_2325)) {
            mix($0, $1.1 ^ UInt64($1.0))
        }
        guard timed else {
            return TimedParticleResult(
                sample: BenchmarkV7RawSample(value: 1, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: checksum),
                checksum: checksum
            )
        }
        guard let startedAt = results.first?.2,
              results.allSatisfy({ $0.2 == startedAt })
        else { throw BenchmarkKernelError.invalidMetric }
        let elapsed = seconds(since: startedAt)
        guard elapsed.isFinite, elapsed > 0, elapsed <= maximumSeconds, checksum != 0 else {
            throw BenchmarkKernelError.invalidMetric
        }
        return TimedParticleResult(
            sample: BenchmarkV7RawSample(
                value: Double(operationCount) / elapsed / 1_000_000,
                elapsedSeconds: elapsed,
                wallElapsedSeconds: elapsed,
                checksum: checksum
            ),
            checksum: checksum
        )
    }

    static func byteTransform(_ prepared: PreparedWork, passes: Int, deadline: UInt64?) throws -> UInt64 {
        var checksum = UInt64(0xD6E8_FEB8_6659_FD93)
        for pass in 0..<passes {
            for index in prepared.bytes.indices {
                if index.isMultiple(of: 4_096) { try check(deadline) }
                let value = prepared.bytes[index]
                let transformed = value &+ UInt8(truncatingIfNeeded: index &+ pass) ^ 0xA7
                prepared.byteOutput[index] = transformed
                checksum = mix(checksum, UInt64(transformed))
            }
        }
        return checksum
    }

    static func imageConvolution(_ prepared: PreparedWork, passes: Int, deadline: UInt64?) throws -> UInt64 {
        let side = prepared.imageSide
        var checksum = UInt64(0x9E37_79B9_7F4A_7C15)
        for _ in 0..<passes {
            for row in 1..<(side - 1) {
                if row.isMultiple(of: 8) { try check(deadline) }
                for column in 1..<(side - 1) {
                    let index = row * side + column
                    let sum = prepared.image[index - side - 1] + prepared.image[index - side]
                        + prepared.image[index - side + 1] + prepared.image[index - 1]
                        + prepared.image[index] + prepared.image[index + 1]
                        + prepared.image[index + side - 1] + prepared.image[index + side]
                        + prepared.image[index + side + 1]
                    let value = sum / 9
                    prepared.imageOutput[index] = value
                    checksum = mix(checksum, UInt64(value.bitPattern))
                }
            }
        }
        return checksum
    }

    static func tokenize(_ documents: [String], passes: Int, deadline: UInt64?) throws -> UInt64 {
        var checksum = UInt64(0x94D0_49BB_1331_11EB)
        for _ in 0..<passes {
            for (index, document) in documents.enumerated() {
                if index.isMultiple(of: 4) { try check(deadline) }
                var tokenLength: UInt64 = 0
                for byte in document.utf8 {
                    if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) {
                        tokenLength += 1
                    } else if tokenLength > 0 {
                        checksum = mix(checksum, tokenLength)
                        tokenLength = 0
                    }
                }
                checksum = mix(checksum, tokenLength ^ UInt64(index))
            }
        }
        return checksum
    }

    static func particles(_ particles: [Particle], workload: Workload, deadline: UInt64?) throws -> UInt64 {
        var checksum = UInt64(0xBF58_476D_1CE4_E5B9)
        for pass in 0..<workload.particlePasses {
            for (index, particle) in particles.enumerated() {
                if index.isMultiple(of: 1_024) { try check(deadline) }
                var x = particle.x
                var y = particle.y
                var velocity = particle.velocity
                for step in 0..<workload.particleSteps {
                    velocity = velocity * 0.999_1 + Double((index &+ step &+ pass) & 31) * 0.000_01
                    x += velocity
                    y += x * 0.000_3 - velocity * 0.000_2
                }
                checksum = mix(checksum, x.bitPattern ^ y.bitPattern ^ velocity.bitPattern)
            }
        }
        return checksum
    }

    static func check(_ deadline: UInt64?) throws {
        try Task.checkCancellation()
        guard let deadline else { return }
        guard seconds(since: deadline) <= 60 else { throw BenchmarkKernelError.resourceLimit }
    }

    static func seconds(since startedAt: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= startedAt else { return .nan }
        return Double(now - startedAt) / 1_000_000_000
    }

    static func mix(_ state: UInt64, _ value: UInt64) -> UInt64 {
        (state ^ value &+ 0x9E37_79B9_7F4A_7C15) &* 0xBF58_476D_1CE4_E5B9
    }
}

private final class PreparedWork: @unchecked Sendable {
    let bytes: [UInt8]
    var byteOutput: [UInt8]
    let imageSide: Int
    let image: [Float]
    var imageOutput: [Float]
    let documents: [String]
    let particles: [Particle]

    init(seed: UInt64, workload: CPUBenchmarkV7Kernel.Workload) throws {
        var state = seed
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        bytes = (0..<workload.byteCount).map { _ in UInt8(truncatingIfNeeded: next()) }
        byteOutput = Array(repeating: 0, count: workload.byteCount)
        imageSide = workload.imageSide
        image = (0..<(workload.imageSide * workload.imageSide)).map { _ in
            Float(Double(next() & 0xFFFF) / 65_535)
        }
        imageOutput = Array(repeating: 0, count: image.count)
        documents = (0..<workload.documentCount).map { document in
            (0..<workload.wordsPerDocument).map { word in
                "w\(document)_\(word)_\(next() & 0xFFFF)"
            }.joined(separator: " ")
        }
        particles = (0..<workload.particleCount).map { _ in
            Particle(
                x: Double(next() & 0xFFFF) / 65_535,
                y: Double(next() & 0xFFFF) / 65_535,
                velocity: Double(next() & 0x3FFF) / 100_000
            )
        }
        try Task.checkCancellation()
    }
}

private struct Particle: Sendable {
    let x: Double
    let y: Double
    let velocity: Double
}

private actor CPUV7StartGate {
    private let expectedWorkerCount: Int
    private var arrivedWorkerCount = 0
    private var started = false
    private var cancelled = false
    private var waiters: [CheckedContinuation<UInt64, Error>] = []

    init(expectedWorkerCount: Int) { self.expectedWorkerCount = expectedWorkerCount }

    func arriveAndWait() async throws -> UInt64 {
        guard !cancelled else { throw CancellationError() }
        arrivedWorkerCount += 1
        if arrivedWorkerCount == expectedWorkerCount {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            started = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            pending.forEach { $0.resume(returning: startedAt) }
            return startedAt
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func cancel() {
        guard !started, !cancelled else { return }
        cancelled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
