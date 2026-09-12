import Foundation

/// A deliberately small, controlled reference set. It is not a percentile or
/// a crowd ranking: values came from one documented Release calibration on the
/// current local M5 Pro after the v9 protocol completed successfully.
enum BenchmarkV7ReferenceCatalog {
    static let referenceSetVersion = "local-m5-pro-controlled-v9-r1"
    static let sourceDescription = "Controlled local Apple M5 Pro Release calibration on 2026-08-01; one completed standard v9 session, fixed fixtures, AC power, nominal thermal state. It is a local reference only, not a ranking or percentile dataset."
    static let createdAt = Date(timeIntervalSince1970: 1_785_521_846)

    static func versions(for plan: BenchmarkV7Plan) -> BenchmarkV7VersionManifest {
        let isStandard = plan.kind == .standard
        return BenchmarkV7VersionManifest(
            planVersion: plan.planVersion,
            workloadVersion: plan.workloadVersion,
            cpuWorkloadVersion: CPUBenchmarkV7Kernel.workloadVersion,
            gpuWorkloadVersion: plan.kind == .standard
                ? "gpu-graphics-2560x1440-v7|gpu-compute-fp16-2048-v7"
                : "gpu-graphics-1920x1080-v7|gpu-compute-fp16-1024-v7",
            memoryWorkloadVersion: plan.kind == .standard
                ? "memory-512m-v7"
                : "memory-128m-v7",
            storageWorkloadVersion: StorageRandomAccessBenchmarkV7.workloadVersion,
            displayWorkloadVersion: DisplayCadenceKernel.workloadVersion,
            statisticsVersion: "benchmark-statistics-v7",
            scoringVersion: isStandard ? "benchmark-scoring-v9" : "benchmark-scoring-v7",
            referenceSetVersion: isStandard ? referenceSetVersion : "unavailable-v7"
        )
    }

    static func scoringManifest(
        for plan: BenchmarkV7Plan
    ) -> BenchmarkV7ScoringManifest? {
        guard plan.kind == .standard else { return nil }
        return BenchmarkV7ScoringManifest(
            versions: versions(for: plan),
            displayBaseline: 6_000,
            coreCategoryWeights: [
                .init(category: .cpu, weight: 0.35),
                .init(category: .gpu, weight: 0.25),
                .init(category: .memory, weight: 0.20),
                .init(category: .storage, weight: 0.20),
            ],
            metrics: coreMetrics
        )
    }

    static func experienceManifest(
        for plan: BenchmarkV7Plan
    ) -> BenchmarkV7ExperienceScoringManifest? {
        guard plan.kind == .standard else { return nil }
        return BenchmarkV7ExperienceScoringManifest(
            versions: versions(for: plan),
            displayBaseline: 6_000,
            metrics: experienceMetrics
        )
    }

    static let referenceSet = BenchmarkV7ReferenceSet(
        version: referenceSetVersion,
        supportedWorkloadVersions: [BenchmarkV7Plan.standard.workloadVersion],
        createdAt: createdAt,
        sourceDescription: sourceDescription,
        metrics: Dictionary(uniqueKeysWithValues: referenceMetrics.map { ($0.id, $0) })
    )

    private static let coreMetrics: [BenchmarkV7MetricManifest] = [
        metric("cpu.single.mixed", .cpu, "Mops/s", .higherIsBetter, 0.5),
        metric("cpu.multi.particle", .cpu, "Mops/s", .higherIsBetter, 0.5),
        metric("gpu.graphics.offscreen", .gpu, "Mtri/s", .higherIsBetter, 0.5),
        metric("gpu.compute.fp16", .gpu, "TFLOPS", .higherIsBetter, 0.5),
        metric("memory.copy.bandwidth", .memory, "GB/s", .higherIsBetter, 0.33),
        metric("memory.triad.bandwidth", .memory, "GB/s", .higherIsBetter, 0.33),
        metric("memory.pointer-chase.latency", .memory, "ns", .lowerIsBetter, 0.34),
        metric("storage.sequential.read", .storage, "GB/s", .higherIsBetter, 0.10),
        metric("storage.sequential.write", .storage, "GB/s", .higherIsBetter, 0.10),
        metric("storage.random.read.qd1.iops", .storage, "IOPS", .higherIsBetter, 0.10),
        metric("storage.random.read.qd1.latency.p50.ns", .storage, "ns", .lowerIsBetter, 0.05),
        metric("storage.random.read.qd1.latency.p95.ns", .storage, "ns", .lowerIsBetter, 0.05),
        metric("storage.random.read.qd16.iops", .storage, "IOPS", .higherIsBetter, 0.10),
        metric("storage.random.read.qd16.latency.p50.ns", .storage, "ns", .lowerIsBetter, 0.05),
        metric("storage.random.read.qd16.latency.p95.ns", .storage, "ns", .lowerIsBetter, 0.05),
        metric("storage.random.write.qd1.iops", .storage, "IOPS", .higherIsBetter, 0.10),
        metric("storage.random.write.qd1.latency.p50.ns", .storage, "ns", .lowerIsBetter, 0.05),
        metric("storage.random.write.qd1.latency.p95.ns", .storage, "ns", .lowerIsBetter, 0.05),
        metric("storage.random.write.qd16.iops", .storage, "IOPS", .higherIsBetter, 0.10),
        metric("storage.random.write.qd16.latency.p50.ns", .storage, "ns", .lowerIsBetter, 0.05),
        metric("storage.random.write.qd16.latency.p95.ns", .storage, "ns", .lowerIsBetter, 0.05),
    ]

    private static let referenceMetrics: [BenchmarkV7ReferenceMetric] = [
        reference("cpu.single.mixed", 608.1329522317399, "Mops/s", .higherIsBetter),
        reference("cpu.multi.particle", 18260.298333995146, "Mops/s", .higherIsBetter),
        reference("gpu.graphics.offscreen", 2086.749841859349, "Mtri/s", .higherIsBetter),
        reference("gpu.compute.fp16", 30.786266568177105, "TFLOPS", .higherIsBetter),
        reference("memory.copy.bandwidth", 127.63647239227342, "GB/s", .higherIsBetter),
        reference("memory.triad.bandwidth", 118.85707538634516, "GB/s", .higherIsBetter),
        reference("memory.pointer-chase.latency", 106.66351515054703, "ns", .lowerIsBetter),
        reference("storage.sequential.read", 0.18881157289488334, "GB/s", .higherIsBetter),
        reference("storage.sequential.write", 6.719252765593533, "GB/s", .higherIsBetter),
        reference("storage.random.read.qd1.iops", 11582.830066295159, "IOPS", .higherIsBetter),
        reference("storage.random.read.qd1.latency.p50.ns", 80333, "ns", .lowerIsBetter),
        reference("storage.random.read.qd1.latency.p95.ns", 115166, "ns", .lowerIsBetter),
        reference("storage.random.read.qd16.iops", 120595.28464634847, "IOPS", .higherIsBetter),
        reference("storage.random.read.qd16.latency.p50.ns", 125729.5, "ns", .lowerIsBetter),
        reference("storage.random.read.qd16.latency.p95.ns", 188333, "ns", .lowerIsBetter),
        reference("storage.random.write.qd1.iops", 9421.382455536668, "IOPS", .higherIsBetter),
        reference("storage.random.write.qd1.latency.p50.ns", 89041, "ns", .lowerIsBetter),
        reference("storage.random.write.qd1.latency.p95.ns", 128666, "ns", .lowerIsBetter),
        reference("storage.random.write.qd16.iops", 34716.918145612006, "IOPS", .higherIsBetter),
        reference("storage.random.write.qd16.latency.p50.ns", 236146, "ns", .lowerIsBetter),
        reference("storage.random.write.qd16.latency.p95.ns", 1464208, "ns", .lowerIsBetter),
        reference("display.cadence.p95.ms", 10.288047916666667, "ms", .lowerIsBetter),
    ]

    private static let experienceMetrics: [BenchmarkV7MetricManifest] = [
        metric("cpu.single.mixed", .cpu, "Mops/s", .higherIsBetter, 0.30),
        metric("memory.pointer-chase.latency", .memory, "ns", .lowerIsBetter, 0.20),
        metric("storage.random.read.qd1.latency.p95.ns", .storage, "ns", .lowerIsBetter, 0.15),
        metric("storage.random.write.qd1.latency.p95.ns", .storage, "ns", .lowerIsBetter, 0.15),
        metric("display.cadence.p95.ms", .display, "ms", .lowerIsBetter, 0.20),
    ]

    private static func metric(
        _ id: String,
        _ category: BenchmarkV7Category,
        _ unit: String,
        _ direction: BenchmarkV7MetricDirection,
        _ weight: Double
    ) -> BenchmarkV7MetricManifest {
        BenchmarkV7MetricManifest(
            id: id,
            category: category,
            unit: unit,
            direction: direction,
            weight: weight,
            workloadVersion: BenchmarkV7Plan.standard.workloadVersion
        )
    }

    private static func reference(
        _ id: String,
        _ value: Double,
        _ unit: String,
        _ direction: BenchmarkV7MetricDirection
    ) -> BenchmarkV7ReferenceMetric {
        BenchmarkV7ReferenceMetric(
            id: id,
            value: value,
            unit: unit,
            direction: direction,
            sourceDescription: sourceDescription,
            sampleCount: 1,
            validationStatus: .controlledLocal
        )
    }
}
