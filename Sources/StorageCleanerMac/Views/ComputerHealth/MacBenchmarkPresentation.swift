import Foundation

struct MacBenchmarkPresentationProgress: Equatable, Sendable {
    let stage: BenchmarkStage
    let completedSampleCount: Int
    let totalSampleCount: Int
    let progress: Double
    let elapsedSeconds: Double

    init(
        stage: BenchmarkStage,
        completedSampleCount: Int = 0,
        totalSampleCount: Int = 0,
        progress: Double,
        elapsedSeconds: Double
    ) {
        self.stage = stage
        self.completedSampleCount = max(0, completedSampleCount)
        self.totalSampleCount = max(0, totalSampleCount)
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        self.elapsedSeconds = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
    }

    static func stateFallback(_ state: MacBenchmarkState) -> Self? {
        guard case let .running(stage, progress, elapsedSeconds) = state else {
            return nil
        }
        return Self(
            stage: stage,
            progress: progress,
            elapsedSeconds: elapsedSeconds
        )
    }
}

enum MacBenchmarkRawOnlyPresentationReason: Equatable, Sendable {
    case baselineUnavailable
    case baselineAmbiguous
    case unsupportedWorkloadVersion
    case invalidSampleContract
    case implausiblePerformanceRatio
    case unsupportedArchitecture
    case environmentNotComparable
    case unstableSamples
    case incompleteResult
}

struct MacBenchmarkComponentPresentation: Equatable, Sendable {
    let component: BenchmarkComponent
    let unit: BenchmarkMetricUnit
    let score: Double?
    let medianValue: Double?
    let coefficientOfVariation: Double?
    let medianAbsoluteDeviation: Double?
    let relativeMedianAbsoluteDeviation: Double?
    let confidence: BenchmarkConfidenceRating?
    let sampleCount: Int
}

enum MacBenchmarkPresentation {
    static let orderedStages: [BenchmarkStage] = [
        .preflight,
        .cpuSingle,
        .cpuMulti,
        .gpu,
        .memory,
        .diskWrite,
        .diskRead,
        .finalizing,
    ]

    static func profileTitle(_ profile: BenchmarkProfile) -> String {
        switch profile {
        case .standard:
            L10n.text("标准", "Standard")
        case .quick:
            L10n.text("旧版快速", "Legacy Quick")
        case .full:
            L10n.text("旧版完整", "Legacy Full")
        }
    }

    static func profileSystemImage(_ profile: BenchmarkProfile) -> String {
        switch profile {
        case .standard: "cube.transparent"
        case .quick: "hare"
        case .full: "tortoise"
        }
    }

    static func profileDetail(_ profile: BenchmarkProfile) -> String {
        switch profile {
        case .standard:
            L10n.text(
                "标准测试运行 3 次稳定采样，约 20–35 秒，并写入约 2.25 GB 临时数据。",
                "The standard test runs 3 stable samples in about 20–35 seconds and writes about 2.25 GB of temporary data."
            )
        case .quick:
            L10n.text(
                "旧版快速工作负载，仅用于读取历史结果。",
                "Legacy Quick workload, retained only for reading historical results."
            )
        case .full:
            L10n.text(
                "旧版完整工作负载，仅用于读取历史结果。",
                "Legacy Full workload, retained only for reading historical results."
            )
        }
    }

    static var performanceIndexTitle: String {
        L10n.text("性能指数", "Performance Index")
    }

    static var standardLeaderboardScoreTitle: String {
        L10n.text("v6 性能指数", "v6 Performance Index")
    }

    static var referenceScoreText: String {
        String(Int(MacBenchmarkScoring.referenceScore.rounded()))
    }

    static var referenceTotalScoreText: String {
        String(Int(MacBenchmarkScoring.referenceTotalScore.rounded()))
    }

    static var activeReferenceSummary: String {
        let reference = baselineChipTitle(
            MacBenchmarkProductionBaselineCatalog.activeBaselineVersion
        ) ?? L10n.text("冻结参照", "Frozen reference")
        return "\(reference) = \(referenceTotalScoreText)"
    }

    static func hardwareSummary(_ environment: BenchmarkEnvironmentMetadata) -> String {
        let chip = normalizedChipName(environment.chipName)
        let memory = physicalMemoryText(environment.physicalMemoryBytes)
        return L10n.text(
            "\(chip) · \(environment.activeProcessorCount) 核 · \(memory)",
            "\(chip) · \(environment.activeProcessorCount) cores · \(memory)"
        )
    }

    static func referenceSummary(for result: MacBenchmarkResult) -> String {
        let reference = baselineChipTitle(result.comparisonKey?.baselineVersion)
            ?? L10n.text("冻结参照", "Frozen reference")
        let referenceValue = isLegacyV2Result(result)
            ? referenceScoreText
            : referenceTotalScoreText
        return "\(reference) = \(referenceValue)"
    }

    static func resultScoreLabel(_ result: MacBenchmarkResult) -> String {
        if isLegacyV2Result(result) {
            return L10n.text("旧版性能指数", "Legacy Index")
        }
        if isBalancedCompositeResult(result) {
            return performanceIndexTitle
        }
        return L10n.text("六项总分", "Six-Component Total")
    }

    static func isLegacyV2Result(_ result: MacBenchmarkResult) -> Bool {
        guard let workloadVersion = result.rawResult?.workloadVersion else { return false }
        return MacBenchmarkScoring.usesLegacyV2WeightedIndex(
            workloadVersion: workloadVersion
        )
    }

    static func isBalancedCompositeResult(_ result: MacBenchmarkResult) -> Bool {
        guard let workloadVersion = result.rawResult?.workloadVersion else { return false }
        return MacBenchmarkScoring.usesBalancedCompositeScoring(
            workloadVersion: workloadVersion
        )
    }

    static func comparisonScope(for result: MacBenchmarkResult) -> String {
        guard result.overallScore != nil,
              result.rawResult?.environment.architecture == .arm64 else {
            return L10n.text("不满足条件时只保留原始值", "Raw metrics only when conditions do not match")
        }
        return L10n.text(
            "可跨 Apple 芯片比较 · 不是同型号排名",
            "Comparable across Apple chips · not a same-model ranking"
        )
    }

    static func stageTitle(_ stage: BenchmarkStage) -> String {
        switch stage {
        case .preflight:
            L10n.text("安全前置检查", "Safety Preflight")
        case .cpuSingle:
            L10n.text("CPU 单核", "CPU Single-Core")
        case .cpuMulti:
            L10n.text("CPU 多核", "CPU Multi-Core")
        case .gpu:
            L10n.text("Metal GPU 3D", "Metal GPU 3D")
        case .memory:
            L10n.text("内存带宽", "Memory Bandwidth")
        case .diskWrite:
            L10n.text("磁盘写入", "Disk Write")
        case .diskRead:
            L10n.text("磁盘读取", "Disk Read")
        case .finalizing:
            L10n.text("复核与清理", "Verify & Clean Up")
        }
    }

    static func stageSymbol(_ stage: BenchmarkStage) -> String {
        switch stage {
        case .preflight: "checkmark.shield"
        case .cpuSingle: "1.circle"
        case .cpuMulti: "cpu"
        case .gpu: "sparkles.rectangle.stack"
        case .memory: "memorychip"
        case .diskWrite: "square.and.arrow.down"
        case .diskRead: "square.and.arrow.up"
        case .finalizing: "checkmark.seal"
        }
    }

    static func componentTitle(
        _ component: BenchmarkComponent,
        unit: BenchmarkMetricUnit? = nil
    ) -> String {
        switch component {
        case .cpuSingle: L10n.text("CPU 单核", "CPU Single-Core")
        case .cpuMulti: L10n.text("CPU 多核", "CPU Multi-Core")
        case .gpu:
            unit == .billionOperationsPerSecond
                ? L10n.text("Metal GPU 计算", "Metal GPU Compute")
                : L10n.text("Metal GPU 3D", "Metal GPU 3D")
        case .memory: L10n.text("内存带宽", "Memory Bandwidth")
        case .diskRead: L10n.text("磁盘读取", "Disk Read")
        case .diskWrite: L10n.text("磁盘写入", "Disk Write")
        }
    }

    static func componentSymbol(_ component: BenchmarkComponent) -> String {
        switch component {
        case .cpuSingle: "1.circle.fill"
        case .cpuMulti: "cpu.fill"
        case .gpu: "sparkles.rectangle.stack.fill"
        case .memory: "memorychip.fill"
        case .diskRead: "arrow.up.forward.square.fill"
        case .diskWrite: "arrow.down.forward.square.fill"
        }
    }

    static func componentRows(_ result: MacBenchmarkResult) -> [MacBenchmarkComponentPresentation] {
        let measurements = result.rawResult?.measurementsByComponent ?? [:]
        let profile = result.rawResult?.profile
        let scores = displayScore(for: result)?.componentScores ?? [:]
        return BenchmarkComponent.allCases.map { component in
            let measurement = measurements[component]
            let statistics = measurement?.statistics
            return MacBenchmarkComponentPresentation(
                component: component,
                unit: measurement?.unit
                    ?? profile.map { component.metricUnit(for: $0) }
                    ?? component.metricUnit,
                score: scores[component],
                medianValue: finitePositive(measurement?.medianValue),
                coefficientOfVariation: finiteNonnegative(
                    measurement?.coefficientOfVariation
                ),
                medianAbsoluteDeviation: finiteNonnegative(
                    statistics?.medianAbsoluteDeviation
                ),
                relativeMedianAbsoluteDeviation: finiteNonnegative(
                    statistics?.relativeMedianAbsoluteDeviation
                ),
                confidence: statistics?.confidence,
                sampleCount: measurement?.samples.count ?? 0
            )
        }
    }

    static func displayScore(for result: MacBenchmarkResult) -> MacBenchmarkDisplayScore? {
        MacBenchmarkDisplayScoring.score(for: result)
    }

    static func nonLeaderboardTitle(
        _ reason: MacBenchmarkRawOnlyPresentationReason
    ) -> String {
        switch reason {
        case .unstableSamples:
            L10n.text(
                "本次得分已记录 · 波动较大，不参与上榜",
                "Run Score Recorded · Too Variable for the Leaderboard"
            )
        case .environmentNotComparable:
            L10n.text(
                "本次得分已记录 · 环境不满足上榜条件",
                "Run Score Recorded · Environment Not Leaderboard-Eligible"
            )
        default:
            L10n.text(
                "本次得分已记录 · 不参与上榜",
                "Run Score Recorded · Not Leaderboard-Eligible"
            )
        }
    }

    static func nonLeaderboardDetail(
        _ reason: MacBenchmarkRawOnlyPresentationReason
    ) -> String {
        switch reason {
        case .unstableSamples:
            L10n.text(
                "本次性能指数仍会显示并保留；至少一个分项的重复采样 CV 超出门限，因此排行榜只采用其他已通过稳定性门禁的最高分。",
                "This run's performance index remains visible and saved. At least one component exceeded the repeated-sample CV limit, so the leaderboard uses the highest result from another run that passed the stability gate."
            )
        case .environmentNotComparable:
            L10n.text(
                "本次性能指数仍会显示并保留；电源、温度或磁盘条件不满足可比门禁，因此排行榜只采用其他符合条件的最高分。",
                "This run's performance index remains visible and saved. Power, thermal, or disk conditions did not pass the comparison gate, so the leaderboard uses the highest eligible result from another run."
            )
        default:
            rawOnlyDetail(reason)
        }
    }

    static func capacityScoreDetail(
        for component: BenchmarkComponent,
        result: MacBenchmarkResult
    ) -> String? {
        guard let rawResult = result.rawResult,
              MacBenchmarkScoring.usesCapacityAwareScoring(
                  workloadVersion: rawResult.workloadVersion
              ) else { return nil }

        switch component {
        case .memory:
            let gibibytes = Double(rawResult.environment.physicalMemoryBytes)
                / Double(1_024 * 1_024 * 1_024)
            let capacity = "\(Int(gibibytes.rounded())) GB"
            return L10n.text(
                "\(capacity) · 权重 25%",
                "\(capacity) · 25% weight"
            )
        case .diskRead, .diskWrite:
            guard let bytes = rawResult.environment.systemDiskCapacityBytes else {
                return nil
            }
            let capacity = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: bytes),
                countStyle: .file
            )
            return L10n.text(
                "\(capacity) · 权重 10%",
                "\(capacity) · 10% weight"
            )
        case .cpuSingle, .cpuMulti, .gpu:
            return nil
        }
    }

    static func rawOnlyReason(
        for result: MacBenchmarkResult,
        explicitReason: MacBenchmarkRawOnlyPresentationReason? = nil
    ) -> MacBenchmarkRawOnlyPresentationReason? {
        guard result.overallScore == nil else { return nil }
        if let explicitReason { return explicitReason }
        guard let rawResult = result.rawResult, rawResult.isComplete else {
            return .incompleteResult
        }
        guard MacBenchmarkScoring.isSupportedWorkloadVersion(
            rawResult.workloadVersion,
            profile: rawResult.profile
        ) else {
            return .unsupportedWorkloadVersion
        }
        guard MacBenchmarkScoring.hasValidSampleContract(rawResult) else {
            return .invalidSampleContract
        }
        guard rawResult.environment.architecture == .arm64 else {
            return .unsupportedArchitecture
        }
        guard MacBenchmarkScoring.hasComparableMeasurementStability(rawResult) else {
            return .unstableSamples
        }
        guard MacBenchmarkScoring.hasComparableEnvironment(rawResult) else {
            return .environmentNotComparable
        }
        return .baselineUnavailable
    }

    static func rawOnlyTitle(_ reason: MacBenchmarkRawOnlyPresentationReason) -> String {
        switch reason {
        case .baselineUnavailable:
            L10n.text("仅保留原始值：没有匹配基线", "Raw Metrics Only: No Matching Baseline")
        case .baselineAmbiguous:
            L10n.text("仅保留原始值：基线不唯一", "Raw Metrics Only: Ambiguous Baseline")
        case .unsupportedWorkloadVersion:
            L10n.text("仅保留原始值：工作负载版本不受支持", "Raw Metrics Only: Unsupported Workload Version")
        case .invalidSampleContract:
            L10n.text("仅保留原始值：采样完整性校验失败", "Raw Metrics Only: Sample Integrity Check Failed")
        case .implausiblePerformanceRatio:
            L10n.text("仅保留原始值：性能比值超出可信范围", "Raw Metrics Only: Performance Ratio Outside Trusted Range")
        case .unsupportedArchitecture:
            L10n.text("仅保留原始值：架构暂不支持计分", "Raw Metrics Only: Architecture Not Scored")
        case .environmentNotComparable:
            L10n.text(
                "仅保留原始值：环境或测量不满足可比条件",
                "Raw Metrics Only: Environment or Measurements Not Comparable"
            )
        case .unstableSamples:
            L10n.text(
                "仅保留原始值：重复采样波动过大",
                "Raw Metrics Only: Repeated Samples Too Variable"
            )
        case .incompleteResult:
            L10n.text("本次没有完整分数", "No Complete Score for This Run")
        }
    }

    static func rawOnlyDetail(_ reason: MacBenchmarkRawOnlyPresentationReason) -> String {
        switch reason {
        case .baselineUnavailable:
            L10n.text(
                "工作负载版本或架构没有匹配到经过校验的冻结基线。原始中位数与波动率仍可查看，但不会生成猜测分数。",
                "The workload version or architecture did not match a verified frozen baseline. Raw medians and variability remain visible, but no estimated score is invented."
            )
        case .baselineAmbiguous:
            L10n.text(
                "发现多个候选基线，无法确定唯一参照。为避免误导，本次不计算分数。",
                "More than one baseline matched, so a unique reference could not be established. No score is calculated."
            )
        case .unsupportedWorkloadVersion:
            L10n.text(
                "这条记录的工作负载版本没有明确绑定评分公式。为防止未来版本误用旧算法，只展示原始值。",
                "This workload version is not explicitly bound to a scoring formula. Raw metrics are shown so a future version cannot silently reuse an older algorithm."
            )
        case .invalidSampleContract:
            L10n.text(
                "重复采样数量与该版本不一致，或同一分项包含不同 kernel checksum；这条记录不会被提升为分数。",
                "The repeated-sample count does not match this version, or a component contains mixed kernel checksums. The record is not promoted into a score."
            )
        case .implausiblePerformanceRatio:
            L10n.text(
                "至少一个分项与冻结参照的比值超出 v6 接受范围。原始值保留，但不会截断成看似正常的分数。",
                "At least one component falls outside v6's accepted ratio against the frozen reference. Raw metrics are retained instead of being clamped into a plausible-looking score."
            )
        case .unsupportedArchitecture:
            L10n.text(
                "当前处理器架构尚未提供经过校验的冻结基线；不会把不同架构强行比较。",
                "No verified frozen baseline exists for this processor architecture, so different architectures are not forced into a comparison."
            )
        case .environmentNotComparable:
            L10n.text(
                "电源、低电量模式、热状态或磁盘条件未达到同版本的可比要求。原始值保留，综合分不发布。",
                "Power, Low Power Mode, thermal state, or disk conditions did not meet the comparison rules for this version. Raw values are retained and no overall score is published."
            )
        case .unstableSamples:
            L10n.text(
                "至少一个分项的重复采样 CV 超出该版本门限。原始中位数仍会保留，但不会发布综合分；冷却设备并减少后台负载后可重跑。",
                "At least one component exceeded this version's repeated-sample CV limit. Raw medians remain available, but no overall score is published; cool the Mac, reduce background load, and rerun."
            )
        case .incompleteResult:
            L10n.text(
                "测试被取消、失败或缺少必要分项；不完整结果不会进入历史排行。",
                "The run was cancelled, failed, or missed a required component. Incomplete results never enter scored history."
            )
        }
    }

    static func failureDetail(_ failure: MacBenchmarkFailure) -> String {
        switch failure {
        case .busy:
            L10n.text(
                "另一个高负载任务正在运行。结束后再试，避免两个任务互相影响。",
                "Another heavy task is running. Try again after it finishes so the workloads do not distort each other."
            )
        case let .safetyCheck(issue):
            safetyIssueDetail(issue)
        case let .unsupported(component):
            L10n.text(
                "当前 Mac 无法运行“\(componentTitle(component))”，因此不会生成不完整分数。",
                "This Mac cannot run \(componentTitle(component)), so an incomplete score is not produced."
            )
        case let .timedOut(stage):
            L10n.text(
                "“\(stageTitle(stage))”超过安全时限，测试已经停止并进入清理。",
                "\(stageTitle(stage)) exceeded its safety timeout. The run stopped and entered cleanup."
            )
        case let .kernelFailure(component, reason):
            L10n.text(
                "“\(componentTitle(component))”未产生可信结果（\(failureReasonTitle(reason))）。",
                "\(componentTitle(component)) did not produce a trustworthy result (\(failureReasonTitle(reason)))."
            )
        case .cancelled:
            L10n.text("测试已取消，不保存不完整分数。", "The run was cancelled; no incomplete score was saved.")
        case .invalidResult:
            L10n.text(
                "结果没有通过完整性校验，因此没有发布分数。",
                "The result did not pass completeness validation, so no score was published."
            )
        }
    }

    static func safetyIssueDetail(_ issue: BenchmarkSafetyIssue) -> String {
        switch issue {
        case .thermalNotNominal:
            L10n.text("当前热状态不适合可比性能测试，请让 Mac 降温后重试。", "The current thermal state is not suitable for a comparable run. Let the Mac cool, then retry.")
        case .thermalCritical:
            L10n.text("系统报告严重热限制，性能测试已停止。", "The system reports critical thermal pressure, so the run stopped.")
        case .batteryTooLow:
            L10n.text("电量过低，请接入电源并等待状态稳定。", "Battery charge is too low. Connect power and wait for conditions to stabilize.")
        case .lowPowerModeEnabled:
            L10n.text("请关闭低电量模式后再运行可比测试。", "Turn off Low Power Mode before a comparable run.")
        case .acPowerRequired:
            L10n.text("可比性能测试要求系统明确确认已接入外部电源。", "A comparable run requires the system to verify external power.")
        case .diskReliabilityFailing:
            L10n.text("磁盘可靠性已被系统标记为需要处理，跳过写入测试。", "Disk reliability is flagged for action, so the write workload is skipped.")
        case .insufficientDiskCapacity:
            L10n.text("可用磁盘空间不足，无法安全创建临时测试文件。", "There is not enough free disk space for a safe temporary test file.")
        }
    }

    static func metricText(_ value: Double?, unit: BenchmarkMetricUnit) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        switch unit {
        case .millionOperationsPerSecond:
            return String(format: "%.1f Mops/s", value)
        case .billionOperationsPerSecond:
            return String(format: "%.1f Gops/s", value)
        case .millionTrianglesPerSecond:
            return String(format: "%.1f Mtri/s", value)
        case .decimalGigabytesPerSecond:
            return String(format: "%.2f GB/s", value)
        }
    }

    static func scoreText(_ score: Double?) -> String {
        guard let score, score.isFinite, score > 0 else { return "—" }
        return score.formatted(.number.precision(.fractionLength(0)))
    }

    static func variabilityText(_ coefficient: Double?) -> String {
        guard let coefficient, coefficient.isFinite, coefficient >= 0 else {
            return L10n.text("CV —", "CV —")
        }
        return String(format: "CV %.1f%%", coefficient * 100)
    }

    static func confidenceText(
        _ confidence: BenchmarkConfidenceRating?,
        relativeMAD: Double?
    ) -> String {
        guard let confidence,
              let relativeMAD,
              relativeMAD.isFinite,
              relativeMAD >= 0 else { return "—" }
        return String(
            format: "%@ · rMAD %.1f%%",
            confidence.rawValue,
            relativeMAD * 100
        )
    }

    static func algorithmVersionText(
        _ manifest: BenchmarkAlgorithmManifest?
    ) -> String {
        guard let manifest else { return "—" }
        let referenceVersion = manifest.referenceSetVersion
            .map(shortVersion)
            ?? "—"
        return L10n.text(
            "测量 \(shortVersion(manifest.measurementSchemaVersion)) · 工作负载 \(shortVersion(manifest.workloadVersion)) · 统计 \(shortVersion(manifest.statisticsVersion)) · 诊断 \(shortVersion(manifest.diagnosticStatisticsVersion)) · 评分 \(shortVersion(manifest.scoringVersion)) · 参考 \(referenceVersion)",
            "Measurement \(shortVersion(manifest.measurementSchemaVersion)) · workload \(shortVersion(manifest.workloadVersion)) · statistics \(shortVersion(manifest.statisticsVersion)) · diagnostics \(shortVersion(manifest.diagnosticStatisticsVersion)) · scoring \(shortVersion(manifest.scoringVersion)) · reference \(referenceVersion)"
        )
    }

    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if seconds < 60 {
            return L10n.text("\(total) 秒", "\(total) sec")
        }
        let minutes = total / 60
        let remainder = total % 60
        return L10n.text(
            "\(minutes) 分 \(remainder) 秒",
            "\(minutes) min \(remainder) sec"
        )
    }

    static func physicalMemoryText(_ bytes: UInt64) -> String {
        let safeBytes = Int64(min(bytes, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: safeBytes, countStyle: .memory)
    }

    static func capacityText(
        _ bytes: UInt64?,
        countStyle: ByteCountFormatter.CountStyle
    ) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: countStyle
        )
    }

    private static func normalizedChipName(_ value: String) -> String {
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else {
            return L10n.text("未知处理器", "Unknown processor")
        }
        return normalized
    }

    private static func shortVersion(_ value: String) -> String {
        value.split(separator: "-").last.map(String.init) ?? value
    }

    private static func baselineChipTitle(_ baselineVersion: String?) -> String? {
        guard let baselineVersion else { return nil }
        let parts = baselineVersion
            .lowercased()
            .split(separator: "-")
            .map(String.init)
        guard let generation = parts.first,
              generation.first == "m",
              generation.dropFirst().allSatisfy(\.isNumber),
              generation.count > 1 else {
            return nil
        }

        var title = generation.uppercased()
        if parts.count > 1 {
            switch parts[1] {
            case "pro": title += " Pro"
            case "max": title += " Max"
            case "ultra": title += " Ultra"
            default: break
            }
        }
        return title
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func failureReasonTitle(_ reason: BenchmarkFailureReason) -> String {
        switch reason {
        case .unavailable: L10n.text("能力不可用", "Unavailable")
        case .invalidMetric: L10n.text("指标无效", "Invalid metric")
        case .checksumMismatch: L10n.text("校验不一致", "Checksum mismatch")
        case .resourceLimit: L10n.text("资源限制", "Resource limit")
        case .systemFailure: L10n.text("系统错误", "System failure")
        }
    }
}
