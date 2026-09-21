import CryptoKit
import Darwin
import Foundation
import Metal
import IOKit.ps

/// Independent protocol. No v7/v9 score or synthetic reference is accepted here.
enum MSeriesProtocol {
    static var temporaryRoot: URL {
        AppDataDirectories.applicationSupportRoot.appendingPathComponent("BenchmarkTemporary", isDirectory: true)
    }
    static let schema = "mseries-result-v10-draft2"
    static let plan = "mseries-core18-v10-draft2"
    static let workload = "mseries-fixed-kernels-v1"
    static let fixture = "procedural-mit-seed-619a27de-v1"
    static let implementation = "native-c-metal-posix-v1"
    static let statistics = "median-mad-all-samples-v1"
    static let scoring = "weighted-geomean-20-20-25-20-15-draft1"
    static let reference = "unavailable-raw-only"
    static let samples = 3
    static let maximumWrittenBytes: UInt64 = 512 * 1024 * 1024
    static let contract = "CPU:integer262144u64;float128x128f32;LZFSE1MiB;gaussian512x512u8;memory:32MiB-copy-triad,16MiB-chase;GPU:1024x1024-rgba8,262144x256-fp32-fp16;storage:64MiB-seq,1024x4KiB-QD1;warmup1;samples3;disk:F_NOCACHE+fsync-write;seed619a27de"
    static var contractHash: String { SHA256.hash(data: Data(contract.utf8)).map { String(format: "%02x", $0) }.joined() }
    static var officialPlan: BenchmarkV7Plan {
        BenchmarkV7Plan(kind: .standard, planVersion: plan, workloadVersion: workload,
            expectedMinimumDurationSeconds: 15, expectedMaximumDurationSeconds: 180,
            categories: BenchmarkV7Category.corePerformance)
    }
    static var versions: BenchmarkV7VersionManifest {
        BenchmarkV7VersionManifest(schemaVersion: schema, planVersion: plan, workloadVersion: workload,
            cpuWorkloadVersion: implementation, gpuWorkloadVersion: implementation,
            memoryWorkloadVersion: implementation, storageWorkloadVersion: implementation,
            displayWorkloadVersion: "extension-not-implemented", statisticsVersion: statistics,
            scoringVersion: scoring, referenceSetVersion: reference)
    }
    static let coreIDs = ["cpu.single", "cpu.multi"].flatMap { group in
        ["integer", "floating", "compression", "image"].map { group + "." + $0 }
    } + ["gpu.graphics.offscreen", "gpu.compute.fp32", "gpu.compute.fp16",
         "memory.copy", "memory.triad", "memory.pointerChase",
         "storage.seqRead", "storage.seqWrite", "storage.randomReadQD1", "storage.randomWriteQD1"]
}

enum MSeriesAvailability: String, Codable, Sendable {
    case available, unknown, unsupported, insufficientResources, failed, notImplemented, cancelled
}

struct MSeriesMeasurement: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let unit: String
    let availability: MSeriesAvailability
    let reason: String?
    let samples: [BenchmarkV7RawSample]
    /// Repeated workload samples, never individual I/O latencies.
    let statistics: BenchmarkStatisticsSummary?
    let repetitions: Int
    let workers: Int
    /// Raw per-operation timing remains separate from repeat statistics.
    var ioLatencyNanoseconds: [[UInt64]]? = nil
    var isValid: Bool {
        !id.isEmpty && workers > 0 && repetitions > 0 &&
        (availability == .available
            ? samples.count == MSeriesProtocol.samples && samples.allSatisfy(\.isValid)
                && statistics?.sampleCount == samples.count
                && (try? BenchmarkStatistics.summarize(samples.map(\.value))) == statistics
            : samples.isEmpty && statistics == nil && reason?.isEmpty == false)
    }
}

struct MSeriesHardware: Codable, Equatable, Sendable {
    struct CoreLevel: Codable, Equatable, Sendable { let index: Int; let logicalCores: Int? }
    let nativeARM64: Bool
    let releaseBuild: Bool
    let translated: Bool?
    let logicalCores: Int
    let coreLevels: [CoreLevel]
    let physicalMemoryBytes: UInt64
    let metalDevice: String?
    let recommendedMetalWorkingSetBytes: UInt64?
    let sharedBudgetBytes: UInt64
    let osVersion: String

    static func capture() -> Self {
        #if arch(arm64)
        let arm64 = true
        #else
        let arm64 = false
        #endif
        #if STORAGE_CLEANER_RELEASE_BUILD
        let releaseBuild = true
        #else
        let releaseBuild = false
        #endif
        let device = MTLCreateSystemDefaultDevice()
        let count = integer("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let levels = integer("hw.nperflevels") ?? 0
        let memory = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        let live = status == KERN_SUCCESS
            ? (UInt64(vm.free_count) + UInt64(vm.inactive_count) / 2) * UInt64(getpagesize()) : 0
        return Self(nativeARM64: arm64, releaseBuild: releaseBuild, translated: integer("sysctl.proc_translated").map { $0 != 0 },
            logicalCores: count,
            coreLevels: levels > 0 && levels <= count ? (0..<levels).map {
                CoreLevel(index: $0, logicalCores: integer("hw.perflevel\($0).logicalcpu"))
            } : [], physicalMemoryBytes: memory, metalDevice: device?.name,
            recommendedMetalWorkingSetBytes: device?.recommendedMaxWorkingSetSize,
            sharedBudgetBytes: min(memory / 5, live / 2, 2 * 1024 * 1024 * 1024),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }
    private static func integer(_ name: String) -> Int? {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

struct MSeriesEnvironmentPoint: Codable, Equatable, Sendable {
    let capturedAt: Date
    let thermalState: Int
    let lowPower: Bool
    let powerSource: String
    static func capture() -> Self {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? } ?? "Unknown"
        return Self(capturedAt: Date(), thermalState: ProcessInfo.processInfo.thermalState.rawValue,
             lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, powerSource: source)
    }
}

struct MSeriesResult: Codable, Equatable, Sendable {
    let sessionID: UUID
    let schema: String
    let plan: String
    let workload: String
    let fixture: String
    let implementation: String
    let statisticsVersion: String
    let scoringVersion: String
    let referenceVersion: String
    let contractHash: String
    let hardware: MSeriesHardware
    let coreEnvironment: [MSeriesEnvironmentPoint]
    let metrics: [MSeriesMeasurement]
    let extensions: [MSeriesMeasurement]
    let cancelled: Bool
    let globalFailure: String?
    let writtenBytes: UInt64
    let startedAt: Date
    let completedAt: Date
    var extensionsVersion: String? = nil
    var extensionEnvironment: [MSeriesEnvironmentPoint]? = nil
    var isCompleteCore: Bool {
        !cancelled && globalFailure == nil && Set(metrics.map(\.id)) == Set(MSeriesProtocol.coreIDs)
            && metrics.allSatisfy { $0.availability == .available && $0.isValid }
    }
    var isValid: Bool {
        schema == MSeriesProtocol.schema && plan == MSeriesProtocol.plan
            && workload == MSeriesProtocol.workload && fixture == MSeriesProtocol.fixture
            && implementation == MSeriesProtocol.implementation
            && statisticsVersion == MSeriesProtocol.statistics && scoringVersion == MSeriesProtocol.scoring
            && referenceVersion == MSeriesProtocol.reference && contractHash == MSeriesProtocol.contractHash
            && metrics.allSatisfy(\.isValid) && Set(metrics.map(\.id)).count == metrics.count
            && Set(metrics.map(\.id)).isSubset(of: Set(MSeriesProtocol.coreIDs))
            && extensions.allSatisfy(\.isValid) && writtenBytes <= MSeriesProtocol.maximumWrittenBytes
            && completedAt >= startedAt
    }
    // Production intentionally has no reference and no total until calibration.
    var overallIndex: Double? { nil }
}

enum MSeriesKernelError: Error { case allocation, invalidOutput, invalidTiming, resourceBudget, cancelled, thermalProtection, io, unsafePath }

final class MSeriesCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    func cancel() { lock.withLock { requested = true } }
    var isCancelled: Bool { lock.withLock { requested } }
    func check() throws {
        if isCancelled { throw CancellationError() }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            throw MSeriesKernelError.thermalProtection
        }
    }
}
