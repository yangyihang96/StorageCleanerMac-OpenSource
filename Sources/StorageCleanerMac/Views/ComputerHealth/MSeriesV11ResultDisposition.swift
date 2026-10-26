import Foundation

extension MSeriesV11PagePresentation {
    struct ResultDisposition: Equatable {
        let measuredCoreCount: Int
        let measurementCompleted: Bool
        let savedLocally: Bool
        let saveFailed: Bool
        let historyFull: Bool
        let failure: BenchmarkV7Failure?
        let elapsedSeconds: Double?

        init(result: BenchmarkV7Result, history: [BenchmarkV7Result], saveState: MSeriesV11SaveState? = nil) {
            measuredCoreCount = result.mSeries?.metrics.filter {
                MSeriesProtocol.coreIDs.contains($0.id) && $0.availability == .available && $0.isValid
            }.count ?? 0
            measurementCompleted = result.mSeriesV11?.state == "completed"
            failure = result.failure
            elapsedSeconds = result.mSeriesV11?.elapsedSeconds
            let localState = saveState.flatMap { $0.matches(result) ? $0.state : nil }
            // Retain fallback support for an older in-memory persistenceFailed
            // result; new runs keep the stop failure and local save state apart.
            saveFailed = localState == .failed || result.failure == .persistenceFailed
            historyFull = localState == .failed && saveState?.historyFull == true
            savedLocally = !saveFailed && result.recordID != nil && history.contains {
                $0.recordID == result.recordID && $0.session.id == result.session.id
                    && $0.failure == result.failure
                    && $0.mSeriesV11?.rawPayloadSHA256 == result.mSeriesV11?.rawPayloadSHA256
            }
        }
        var storageText: String {
            if saveFailed { return L10n.text("保存失败 · 仅当前会话可查看", "Save failed · Available only in this session") }
            return savedLocally ? L10n.text("结果保存在本机", "Saved locally") : L10n.text("保存未确认", "Save not confirmed")
        }
        var saveFailureText: String? {
            guard saveFailed else { return nil }
            if historyFull {
                let limit = BenchmarkV7HistoryRepository.maximumRecordCount
                return L10n.text(
                    "本机跑分历史已满（最多 \(ByteFormat.count(limit)) 条），本次结果未保存，仅当前应用会话可查看。删除不需要的旧记录后，新的结果才能保存。",
                    "Local benchmark history is full (\(ByteFormat.count(limit)) records). This result was not saved and is available only in this app session. Delete records you no longer need to save new results.")
            }
            return L10n.text("测量结果未能安全保存；仅当前应用会话可查看。", "Measurements were not safely saved; available only in the current app session.")
        }
        var terminationText: String? {
            guard let failure, failure != .persistenceFailed else { return nil }
            switch failure {
            case .cancelled: return L10n.text("测试已取消 · 保留已完成测量", "Test cancelled · Completed measurements retained")
            case .timedOut: return Self.reasonText("timeout")
            case .restartRequired: return L10n.text("任务未确认停止 · 需重启应用", "Termination unconfirmed · Restart required")
            case let .validationFailed(reason), let .invalidMeasurement(reason): return Self.reasonText(reason)
            case .preflightBlocked: return L10n.text("预检未通过", "Preflight blocked")
            case .unsupportedCategory: return L10n.text("测试项目不受支持", "Unsupported test category")
            case .alreadyRunning: return L10n.text("已有测试在运行", "A test is already running")
            case .internalFailure: return L10n.text("测试异常终止", "Test terminated unexpectedly")
            case .persistenceFailed: return nil
            }
        }
        static func reasonText(_ code: String) -> String {
            switch code {
            case "cancelled": return L10n.text("测试已取消 · 保留已完成测量", "Test cancelled · Completed measurements retained")
            case "thermalProtection", "thermal-protection": return L10n.text("温度过高 · 测试已停止以保护设备", "High temperature · Test stopped to protect the device")
            case "timeout", "core-timeout", "core-item-timeout": return L10n.text("测试超时 · 保留已完成测量", "Test timed out · Completed measurements retained")
            case "warmupTimeout": return L10n.text("预热超时 · 测试已停止", "Warm-up timed out · Test stopped")
            case "clockInvalid": return L10n.text("计时证据无效 · 测试已停止", "Invalid timing evidence · Test stopped")
            case "invalidBatch": return L10n.text("测量证据无效 · 测试已停止", "Invalid measurement evidence · Test stopped")
            case "metadataBudget": return L10n.text("测量记录超出写入预算 · 测试已停止", "Measurement record exceeded the write budget · Test stopped")
            case "evidenceBudgetForecast": return L10n.text("预计测量记录超出写入预算 · 测试已停止", "Expected measurement record exceeds the write budget · Test stopped")
            case "coreIncomplete", "partial-v11-result": return L10n.text("测量未全部完成 · 保留已完成测量", "Measurements incomplete · Completed measurements retained")
            case "native-arm64-required": return L10n.text("需要原生 Apple 芯片环境 · 测试已停止", "Native Apple silicon environment required · Test stopped")
            default: return L10n.text("测量未通过校验 · 测试已停止", "Measurement validation failed · Test stopped")
            }
        }
        var completionText: String {
            let measurement = measurementCompleted ? L10n.text("测量完成", "Measurements complete") : L10n.text("部分测量", "Partial measurements")
            let termination = failure == .cancelled ? L10n.text(" · 已取消", " · Cancelled") : failure != nil && failure != .persistenceFailed ? L10n.text(" · 已中止", " · Stopped") : ""
            let storage = saveFailed ? L10n.text(" · 保存失败", " · Save failed") : ""
            return "\(ByteFormat.count(measuredCoreCount))/18 " + measurement + termination + storage + " · " + duration(elapsedSeconds)
        }
    }

    /// Both summary and history consume this same per-score state and reason.
    struct ScoreDisplay: Identifiable {
        let id: String
        let metric: LightfieldMetric
        let reason: String?
        var historyMetric: LightfieldMetric {
            let joined = LightfieldMetric(id: metric.id, label: metric.label, value: metric.valuePrefix + metric.value,
                status: metric.status, caption: reason ?? metric.caption)
            return joined
        }
        init(id: String, result: MSeriesV11Result) {
            self.id = id
            let parts = scoreParts(id, result: result)
            let label = id == "chip" ? L10n.text("芯片性能分", "Chip performance score") : id == "system" ? L10n.text("整机分", "System score") : L10n.text("能效分", "Efficiency score")
            reason = scoreReason(id, result: result)
            metric = .init(id: id, label: label, value: parts.value,
                status: scoreRestricted(id, result: result) ? .unknown : nil,
                caption: id == "efficiency" && !hasMeasuredEfficiency(result) ? "" : referenceCaption(result), valuePrefix: parts.prefix)
        }
    }
    static func historyScores(_ record: BenchmarkV7Result, current: BenchmarkV7Result?) -> [ScoreDisplay] {
        guard let envelope = record.mSeriesV11,
              current.map({ ($0.session.id == record.session.id && $0.recordID == record.recordID)
                  || scoreComparable($0, record) }) == true else { return [] }
        return ["chip", "system", "efficiency"].map { ScoreDisplay(id: $0, result: envelope) }
    }

    static func scoreRestricted(_ id: String, result: MSeriesV11Result) -> Bool {
        result.scores?.labels[id]?.status == .restricted
    }
    static func scoreReason(_ id: String, result: MSeriesV11Result) -> String? {
        guard let label = result.scores?.labels[id], label.status == .restricted else { return nil }
        let reasons = label.reasonCodes.map { code in
            switch code {
            case "batteryPower": L10n.text("电池供电", "Battery power")
            case "thermalFair": L10n.text("温度需关注", "Thermal fair")
            case "lowPower": L10n.text("省电模式", "Low Power Mode")
            case "powerChanged": L10n.text("电源状态变化", "Power source changed")
            case "backgroundLoadHigh": L10n.text("后台负载较高", "High background load")
            case "powerModeRestricted": L10n.text("电源模式受限", "Power mode restricted")
            case "environmentUnknown", "thermalUnknown", "powerUnknown": L10n.text("环境未核实", "Environment unverified")
            default: code
            }
        }
        return L10n.text("受限：", "Restricted: ") + (reasons.isEmpty ? L10n.text("环境未核实", "Environment unverified") : reasons.joined(separator: " · "))
    }

    static func metricEligibility(_ metric: MSeriesMeasurement, in result: BenchmarkV7Result) -> MSeriesComparabilityLabel {
        guard let core = result.mSeries, core.metrics.contains(metric), metric.isValid,
              core.metrics.filter({ $0.id == metric.id }).count == 1 else {
            return MSeriesScoringV11.label(bad: ["invalidSamples"])
        }
        // Compare this item's evidence. A different item's invalid timing must
        // not disqualify an otherwise valid row; the fixed Core contract stays
        // subject to the same production validator used by scoring inputs.
        let scopedCore = MSeriesResult(sessionID: core.sessionID, schema: core.schema, plan: core.plan,
            workload: core.workload, fixture: core.fixture, implementation: core.implementation,
            statisticsVersion: core.statisticsVersion, scoringVersion: core.scoringVersion,
            referenceVersion: core.referenceVersion, contractHash: core.contractHash, hardware: core.hardware,
            coreEnvironment: core.coreEnvironment, metrics: [metric], extensions: [], cancelled: core.cancelled,
            globalFailure: core.globalFailure, writtenBytes: core.writtenBytes,
            startedAt: core.startedAt, completedAt: core.completedAt)
        guard let input = MSeriesScoringV11.inputs(core: scopedCore, envelope: result.mSeriesV11).first(where: { $0.id == metric.id }) else {
            return MSeriesScoringV11.label(bad: ["missingV11Inputs"])
        }
        return MSeriesScoringV11.evidenceLabel(input, extensionHash: result.mSeriesV11?.extensionContractHash ?? "",
            mode: result.mSeriesV11?.mode ?? "standard")
    }
}
