import Foundation

/// A read-only adapter. It does not activate references, reinterpret old schemas,
/// or persist derived values. The runner/scorer remain the measurement owners.
enum MSeriesV11PagePresentation {
    static var unread: String { L10n.text("未读取", "Not read") }
    static var calibration: String { L10n.text("待校准", "Awaiting calibration") }
    static var helperRequired: String { L10n.text("需要系统助手", "System Helper required") }
    static var community: String { L10n.text("暂不可提交（服务端未上线）", "Submission unavailable (server not live)") }

    static func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return unread }
        if abs(value) >= 1_000_000_000 { return String(format: "%.3g", value) }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }
    static func duration(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return unread }
        let seconds = Int(min(value, 86_400).rounded(.down))
        return L10n.text("\(seconds / 60) 分 \(seconds % 60) 秒", "\(seconds / 60)m \(seconds % 60)s")
    }
    static func unit(_ value: String) -> String {
        switch value {
        case "fixed-fixtures/s", "fixtures/s": L10n.text("固定负载/秒", "fixed workloads/s")
        case "fixed-fixtures/J", "fixtures/J": L10n.text("固定负载/焦", "fixed workloads/J")
        case "ns/access": L10n.text("纳秒/次", "ns/access")
        case "Mtri/s": L10n.text("百万三角形/秒", "Mtri/s")
        case "Mtri/J": L10n.text("百万三角形/焦", "Mtri/J")
        case "IOPS": L10n.text("次/秒", "IOPS")
        case "frames/s": L10n.text("帧/秒", "frames/s")
        default: value
        }
    }
    static func itemTitle(_ id: String) -> String {
        let zh = MSeriesRunItemTitles.chineseTitle(for: id)
        let names: [String: String] = [
            "integer": "Integer", "floating": "Floating point", "compression": "Compression", "image": "Image processing",
            "gpu.graphics.offscreen": "GPU · Offscreen graphics", "gpu.compute.fp32": "GPU · FP32", "gpu.compute.fp16": "GPU · FP16",
            "memory.copy": "Memory · Copy", "memory.triad": "Memory · Triad", "memory.pointerChase": "Memory · Pointer chase",
            "storage.seqRead": "Storage · Sequential read", "storage.seqWrite": "Storage · Sequential write",
            "storage.randomReadQD1": "Storage · 4K random read", "storage.randomWriteQD1": "Storage · 4K random write",
            "power.cpu.single": "CPU efficiency · Single thread", "power.cpu.performanceCores": "CPU efficiency · Highest performance core count",
            "power.cpu.allCores": "CPU efficiency · All cores", "power.gpu.peak": "GPU peak and efficiency",
            "sustained.cpu.allCores": "Sustained · CPU all cores", "sustained.gpu": "Sustained · GPU",
            "pressure.cpu.allCores": "Pressure · CPU all cores", "pressure.gpu": "Pressure · GPU",
            "preflight": "Environment preflight", "finalizing": "Saving · Local history", "cancelling": "Stopping test",
            "accelerators": "Independent accelerators", "core": "Core measurements", "media.h264.encode": "Media · H.264 encode", "media.h264.decode": "Media · H.264 decode",
            "media.hevc.encode": "Media · HEVC encode", "media.hevc.decode": "Media · HEVC decode",
            "media.prores.encode": "Media · ProRes encode", "media.prores.decode": "Media · ProRes decode",
            "media.av1.decode": "Media · AV1 decode", "gpu.rayTracing": "GPU · Ray tracing",
            "gpu.tensorFP16": "GPU · FP16 tensor", "ane.smallModel": "Neural Engine · Small model",
            "gpu.hardwareRayTracing.build": "GPU ray tracing · Structure build",
            "gpu.hardwareRayTracing.traversal": "GPU ray tracing · Traversal",
            "gpu.tensor.fp16": "GPU matrix compute · FP16", "ai.smallModel.cpu": "Neural model · CPU",
            "ai.smallModel.aneCandidate": "Neural model · Neural Engine candidate",
            "ai.smallModel.accelerationRatio": "Neural model · Acceleration ratio"]
        if id.hasPrefix("cpu.single.") || id.hasPrefix("cpu.multi.") {
            let en = (id.hasPrefix("cpu.single.") ? "CPU single thread · " : "CPU multi thread · ")
                + (names[String(id.split(separator: ".").last ?? "")] ?? "Measurement")
            return L10n.text(zh, en)
        }
        return L10n.text(zh, names[id] ?? "Extension test · Name pending")
    }

    static func measuredEfficiencyPoint(_ point: MSeriesV11EfficiencyPoint, in result: MSeriesV11Result) -> Bool {
        point.timestampQuality == "helperMeasured" && point.meanPowerW.map { $0.isFinite && $0 > 0 } == true
            && point.efficiency?.availability == "available"
            // The scored alignment validator is deliberately CPU 10 s / 5 requests.
            // GPU 30 s / 15 requests is verified by rebuilding its own raw windows.
            && (point.id == "power.gpu.peak" || point.efficiency?.powerAlignment?.validates(point.efficiency?.samples ?? []) == true)
            && validatesPowerPoint(point, in: result)
    }
    private static func validatesPowerPoint(_ point: MSeriesV11EfficiencyPoint, in result: MSeriesV11Result) -> Bool {
        let gpu = point.id == "power.gpu.peak"
        guard MSeriesV11Windows.contiguous(point.windows, count: 3, duration: gpu ? 30 : 10, gpu: gpu) else { return false }
        let batches = result.workloadBatches.filter { $0.stageID == point.id }
        guard MSeriesV11Windows.validBatches(batches, id: point.id) else { return false }
        let rebuilt = MSeriesV11Windows.efficiencyPoint(id: point.id, workers: point.resolvedWorkers ?? 0,
            coreType: point.coreType ?? "unknown", windows: point.windows, batches: batches,
            telemetry: result.telemetry, extensionHash: result.extensionContractHash)
        return rebuilt.efficiency?.samples == point.efficiency?.samples && rebuilt.efficiency?.powerAlignment == point.efficiency?.powerAlignment
            && rebuilt.efficiency != nil && rebuilt.meanPowerW == point.meanPowerW && rebuilt.observedSeconds == point.observedSeconds
    }
    static func hasMeasuredEfficiency(_ result: MSeriesV11Result) -> Bool {
        result.efficiencyPoints.contains { point in
            point.id == "power.cpu.allCores" && measuredEfficiencyPoint(point, in: result)
        }
    }
    static func reference(_ result: MSeriesV11Result) -> MSeriesReferenceIdentity {
        result.scores?.referenceIdentity ?? result.referenceIdentity ?? .unavailable
    }
    static func referenceCaption(_ result: MSeriesV11Result) -> String {
        let identity = reference(result)
        switch identity.referenceStatus {
        case .final: return L10n.text("相对 Apple M1＝1000", "Relative to Apple M1 = 1000")
        case .provisional:
            let name = identity.provisionalAgainst ?? unread
            return L10n.text("相对 \(name) 参考机＝1000", "Relative to \(name) reference = 1000")
        case .unavailable: return L10n.text("相对 Apple M1＝1000 · 参考未就绪", "Apple M1 = 1000 · Reference unavailable")
        }
    }
    static func score(_ id: String, result: MSeriesV11Result) -> String {
        if id == "efficiency", !hasMeasuredEfficiency(result) { return helperRequired }
        guard reference(result).referenceStatus != .unavailable,
              result.mode == "standard", let value = result.scores?.componentScores[id], value.isFinite, value > 0,
              result.scores?.labels[id]?.status != .incomparable else { return calibration }
        let prefix = reference(result).referenceStatus == .provisional ? L10n.text("暂定 ", "Provisional ") : ""
        return prefix + number(value, digits: 0)
    }
    static func scoreParts(_ id: String, result: MSeriesV11Result) -> (prefix: String, value: String) {
        let full = score(id, result: result)
        let prefix = L10n.text("暂定 ", "Provisional ")
        return full.hasPrefix(prefix) ? (prefix, String(full.dropFirst(prefix.count))) : ("", full)
    }
    static func ratio(_ id: String, result: MSeriesV11Result) -> Double? {
        guard reference(result).referenceStatus != .unavailable, result.mode == "standard",
              result.scores?.labels[id]?.status != .incomparable,
              let score = result.scores?.componentScores[id], score.isFinite, score > 0 else { return nil }
        return score / 1000
    }
    static func referenceExplanation(_ result: MSeriesV11Result) -> String {
        if reference(result).referenceStatus == .provisional {
            let name = reference(result).provisionalAgainst ?? unread
            return L10n.text("暂定基准＝\(name) 受控采集，取得 M1 数据后自动重算", "Provisional reference: controlled \(name) runs; recalculated after M1 data is available")
        }
        if reference(result).referenceStatus == .unavailable {
            return L10n.text("参考尚未就绪 · 保留原始测量值", "Reference unavailable · Raw measurements retained")
        }
        return referenceCaption(result)
    }

    static func rawComparable(_ a: BenchmarkV7Result, _ b: BenchmarkV7Result) -> Bool {
        guard a.session.id != b.session.id, let lhs = a.mSeries, let rhs = b.mSeries else { return false }
        return lhs.contractHash == rhs.contractHash && lhs.workload == rhs.workload
            && lhs.fixture == rhs.fixture && lhs.statisticsVersion == rhs.statisticsVersion
    }
    static func scoreComparable(_ a: BenchmarkV7Result, _ b: BenchmarkV7Result) -> Bool {
        guard let lhs = a.mSeriesV11, let rhs = b.mSeriesV11,
              lhs.schema == rhs.schema, lhs.mode == rhs.mode, lhs.mode == "standard",
              lhs.coreContractHash == rhs.coreContractHash, lhs.extensionContractHash == rhs.extensionContractHash,
              lhs.scoringContractHash == rhs.scoringContractHash,
              reference(lhs) == reference(rhs), reference(lhs).referenceStatus != .unavailable else { return false }
        return ["chip", "system", "efficiency"].allSatisfy { id in
            lhs.scores?.labels[id]?.status == .comparable && rhs.scores?.labels[id]?.status == .comparable
        }
    }
    static func previousCore(for result: BenchmarkV7Result, history: [BenchmarkV7Result]) -> BenchmarkV7Result? {
        history.filter { rawComparable(result, $0) && ($0.completedAt ?? .distantFuture) < (result.completedAt ?? .distantPast) }
            .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }
    struct Comparison: Equatable {
        let percent: Double
        let improved: Bool
    }
    static func comparison(_ metric: MSeriesMeasurement, previous: MSeriesMeasurement?,
                           currentResult: BenchmarkV7Result? = nil, previousResult: BenchmarkV7Result? = nil) -> Comparison? {
        guard let currentResult, let previousResult, rawComparable(currentResult, previousResult),
              metricEligibility(metric, in: currentResult).status == .comparable,
              let previous, metricEligibility(previous, in: previousResult).status == .comparable,
              metric.id == previous.id, metric.unit == previous.unit,
              metric.availability == .available, previous.availability == .available,
              let value = metric.statistics?.median, let old = previous.statistics?.median,
              value.isFinite, old.isFinite, value > 0, old > 0 else { return nil }
        let change = value / old - 1
        return Comparison(percent: change * 100, improved: metric.id == "memory.pointerChase" ? change < 0 : change > 0)
    }
    static func availability(_ status: String, reason: String? = nil) -> String {
        switch status {
        case "available": L10n.text("可用", "Available")
        case "unsupported": L10n.text("无此单元", "No such unit")
        case "unknown": reason == "systemUnavailable" ? L10n.text("当前不可用", "Currently unavailable") : L10n.text("未知", "Unknown")
        case "notImplemented": L10n.text("阶段 2 · 尚未实现", "Phase 2 · Not implemented")
        case "cancelled": L10n.text("已取消", "Cancelled")
        default: L10n.text("当前不可用", "Currently unavailable")
        }
    }

    static func chipLine(_ identity: AppleSiliconIdentity?, catalog: AppleSiliconCatalogLoader.Loaded) -> String {
        guard let evidence = identity?.identificationEvidence else { return unread }
        let topology = evidence.perfLevels.map { level in
            let name: String = switch level.name?.lowercased() {
            case "super": L10n.text("超级", "super")
            case "performance": L10n.text("性能", "performance")
            case "efficiency": L10n.text("能效", "efficiency")
            default: unread
            }
            return (level.physicalCores.map(String.init) ?? unread) + " " + name
        }.joined(separator: "＋")
        let gpu = evidence.profilerGPUCores.map { "GPU \($0) " + L10n.text("核", "cores") } ?? "GPU " + unread
        let memory = evidence.physicalMemoryBytes.map { number(Double($0) / 1_073_741_824, digits: 0) + " GB" } ?? unread
        let cooling = catalogMatches(identity, catalog) ? catalog.catalog?.chips.first { $0.id == identity?.chipID }?.typicalMacs
            .first { $0.model == evidence.modelIdentifier }?.cooling : nil
        let coolingText = cooling == "active" ? L10n.text("主动散热", "Active cooling") :
            cooling == "passive" ? L10n.text("无风扇", "Fanless") : L10n.text("散热：未读取", "Cooling: not read")
        return [evidence.brandString ?? unread, topology.isEmpty ? unread : topology, gpu, memory, coolingText].joined(separator: " · ")
    }
    static func catalogMatches(_ identity: AppleSiliconIdentity?, _ loaded: AppleSiliconCatalogLoader.Loaded) -> Bool {
        identity?.catalogVersion != nil && identity?.catalogVersion == loaded.catalog?.catalogVersion
            && identity?.catalogSHA256 == loaded.sha256 && loaded.catalog != nil
    }

    struct RatioLayout {
        let availableWidth: CGFloat
        var count: Int { availableWidth >= 740 ? 4 : 2 }
        let gap: CGFloat = 24
        // Flexible grid columns round separately in AppKit. Whole-point
        // columns keep the last cell inside the measured content width.
        var columnWidth: CGFloat { floor(max(0, availableWidth - gap * CGFloat(count - 1)) / CGFloat(count)) }
        var fittedWidth: CGFloat { columnWidth * CGFloat(count) + gap * CGFloat(count - 1) }
    }

    struct ResultLayout {
        let width: CGFloat
        let height: CGFloat
        var summaryHeight: CGFloat { width >= 740 ? 76 : 150 }
        var pinsSummary: Bool { height - summaryHeight - 24 >= 96 }
    }

    struct Run: Equatable {
        let state: BenchmarkV7State
        let weightedFraction: Double?
        let elapsedSeconds: Double?
        var knownCoreCount: Int? = nil
        var mode: String = "standard"
        var displayedFraction: Double? {
            guard let weightedFraction, weightedFraction.isFinite else { return nil }
            return min(state.phase == .completed ? 1 : 0.99, max(0, weightedFraction))
        }
        var completedCoreCount: Int {
            if mode == "pressure10m" { return 0 }
            if let knownCoreCount { return min(18, max(0, knownCoreCount)) }
            // Persistence may contain a cancelled partial Core; it proves no count.
            if let index = MSeriesProtocol.coreIDs.firstIndex(of: state.workloadID ?? "") { return index }
            return ["power.cpu.single", "power.cpu.performanceCores", "power.cpu.allCores", "power.gpu.peak",
                    "sustained.cpu.allCores", "sustained.gpu", "accelerators"].contains(state.workloadID ?? "") ? 18 : 0
        }
        var canCancel: Bool { state.phase != .persisting && state.phase != .cancelling && state.phase.isActive }
        var title: String {
            switch state.phase {
            case .cancelling: return L10n.text("正在停止测试 · 等待任务完成", "Stopping test · Waiting for tasks")
            case .persisting: return itemTitle("finalizing")
            case .preflighting: return itemTitle("preflight")
            default: return L10n.text("正在测试 · ", "Testing · ") + itemTitle(state.workloadID ?? "core")
            }
        }
        var position: String {
            if mode == "pressure10m" { return L10n.text("独立压力观察 · 不计分", "Independent pressure observation · Unscored") }
            if state.phase == .persisting { return L10n.text("保存阶段 · 核心 \(completedCoreCount)/18", "Saving · Core \(completedCoreCount)/18") }
            if state.phase == .cancelling { return L10n.text("核心已完成 \(completedCoreCount)/18", "Core completed \(completedCoreCount)/18") }
            if MSeriesProtocol.coreIDs.contains(state.workloadID ?? "") {
                return L10n.text("核心第 \(completedCoreCount + 1) / 18 项", "Core \(completedCoreCount + 1) / 18")
            }
            return L10n.text("扩展阶段 · 核心 \(completedCoreCount)/18", "Extension stage · Core \(completedCoreCount)/18")
        }
    }
}

struct MSeriesV11Selection: Equatable {
    var pressure = false
    var accelerators = false
    var mode: String { pressure ? "pressure10m" : "standard" }
    var units: [MSeriesV11AcceleratorUnit] {
        accelerators ? [.media(.h264), .media(.hevc), .media(.proRes422), .rayTracing, .tensorFP16, .av1] : []
    }
    var estimatedSeconds: ClosedRange<Double> {
        let plan = MSeriesV11Protocol.plan(mode: mode)
        let extra = units.reduce(0) { $0 + $1.collectionDeadlineSeconds }
        return (Double(plan.expectedMinimumDurationSeconds) + extra)...(Double(plan.expectedMaximumDurationSeconds) + extra)
    }
}
