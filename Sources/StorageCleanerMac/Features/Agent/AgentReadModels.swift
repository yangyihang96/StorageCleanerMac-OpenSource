import AgentGatewayCore
import AgentShared
import Foundation

/// D266, field by field: what an AI may read of each App type. Values are
/// copied by name and models are never encoded whole, so a field added to a
/// model later stays out until someone decides otherwise. Every item is
/// referred to by a token. `AgentResultGuard` is the last check, not the rule.
enum AgentReadModels {
    /// D266: mail attachments, chat files and recent items give their category,
    /// count and size, never a name or a path.
    static func isPrivateRule(_ rule: String) -> Bool {
        ["mail.", "chat-files.", "privacy."].contains { rule.hasPrefix($0) }
    }

    // MARK: Module results

    static func junkItem(_ candidate: ScanCandidate, tokens: AgentItemTokens) -> AgentJSONValue {
        var fields: [String: AgentJSONValue] = [
            "id": .string(tokens.token(for: candidate.id.rawValue.uuidString, module: "junk")),
            "category": .string(candidate.categoryTitle),
            "subcategory": .string(candidate.subcategoryTitle),
            "size_bytes": .integer(candidate.estimatedSizeBytes),
            "risk": .string(candidate.risk.rawValue),
            "recommendation": .string(candidate.recommendation.level.rawValue),
            "preselected": .bool(candidate.isPreselectedByDefault),
            "selectable": .bool(candidate.isSelectable),
            "requires_review": .bool(candidate.requiresExplicitReview),
            "owner_running": .bool(candidate.isOwnerRunning),
            "required_closed_bundle_ids": .array(candidate.requiredClosedBundleIDs.map(AgentJSONValue.string))
        ]
        if isPrivateRule(candidate.ruleID) {
            fields["private"] = true
        } else {
            fields["name"] = .string(candidate.sourceURL.lastPathComponent)
            fields["path"] = .string(candidate.sourceURL.path)
            fields["reason"] = .string(candidate.reason)
        }
        return .object(fields)
    }

    static func startupItem(_ item: StartupItemsDomain.Item, tokens: AgentItemTokens) -> AgentJSONValue {
        let state = item.state
        return [
            "id": .string(tokens.token(for: item.id, module: "startup_items")),
            "name": .string(item.name),
            "kind": .string(item.kind.rawValue),
            "scope": .string(item.scope.rawValue),
            "registration": .string(state.registration.rawValue),
            "authorization": .string(state.authorization.rawValue),
            "enablement": .string(state.enablement.rawValue),
            "load": .string(state.load.rawValue),
            "process": .string(processName(state.process)),
            "management": .string(state.management.rawValue),
            "application_name": json(item.attribution?.applicationName),
            "developer_name": json(item.attribution?.developerName),
            "component_count": json(item.components.count),
            "needs_attention": .bool(item.needsAttention),
            "attention_reason": json(item.attentionReasonText)
        ]
    }

    /// No process number: it says nothing the state does not.
    private static func processName(_ state: StartupItemsDomain.ProcessState) -> String {
        switch state {
        case .running: "running"
        case .stopped: "stopped"
        case .waiting: "waiting"
        case .failed: "failed"
        case .unknown: "unknown"
        }
    }

    static func installedApp(_ app: InstalledAppItem, tokens: AgentItemTokens) -> AgentJSONValue {
        [
            "id": .string(tokens.token(for: app.id, module: "installed_apps")),
            "name": .string(app.name),
            "bundle_id": bundleID(app.bundleIdentifier),
            "version": .string(app.version),
            "build": .string(app.build),
            "category": .string(app.category),
            "developer_name": .string(app.developerName),
            "size_bytes": .integer(app.sizeBytes),
            "source": .string(app.source),
            "modified_at": json(app.modifiedAt),
            "last_used_at": json(app.lastUsedAt),
            "status": .string(app.status.rawValue),
            "related_path_count": json(app.relatedPaths.count)
        ]
    }

    /// The store keeps every app it looked at; these are the ones with an update.
    static func offersUpdate(_ app: AppUpdateItem) -> Bool {
        app.effectiveVersionCheckState == .updateAvailable
    }

    static func appUpdate(_ app: AppUpdateItem, tokens: AgentItemTokens) -> AgentJSONValue {
        [
            "id": .string(tokens.token(for: app.id, module: "app_updates")),
            "name": .string(app.displayName),
            "bundle_id": bundleID(app.bundleIdentifier),
            "installed_version": .string(app.installedVersion.preferred),
            "available_version": json(app.availableVersion?.preferred),
            "status": .string(app.updateStatus.rawValue),
            "source": .string(app.installationSource.rawValue),
            "provider": .string(app.updateProvider.rawValue),
            "requires_quit": .bool(app.requiresApplicationQuit),
            "requires_administrator": .bool(app.requiresAdministratorAuthorization),
            "is_running": .bool(app.isRunning),
            "download_size_bytes": json(app.downloadSize),
            "release_date": json(app.releaseDate)
        ]
    }

    static func moduleSummary(_ module: String, status: AgentResultStatus, updatedAt: Date?, count: Int, bytes: Int64?) -> AgentJSONValue {
        ["module": .string(module), "status": .string(status.rawValue), "updated_at": json(updatedAt),
         "item_count": json(count), "total_bytes": json(bytes)]
    }

    // MARK: Operation records

    private static func recordCounts(_ summary: CleanReportSummary) -> [String: AgentJSONValue] {
        [
            "requested_count": json(summary.requestedItemCount),
            "moved_count": json(summary.movedItemCount),
            "skipped_count": json(summary.skippedItemCount),
            "failed_count": json(summary.failedItemCount),
            "not_processed_count": json(summary.notProcessedItemCount),
            "deleted_count": json(summary.deletedItemCount),
            "planned_bytes": .integer(summary.plannedBytes),
            "moved_bytes": .integer(summary.movedToRecoverableLocationBytes),
            "freed_bytes": .integer(summary.permanentlyFreedBytes)
        ]
    }

    static func operationRecordSummary(_ index: CleanupReportIndex) -> AgentJSONValue {
        let isPrivate = isPrivateRule(index.rulesVersion)
        var fields = recordCounts(index.summary)
        fields["id"] = .string(index.id.uuidString)
        fields["kind"] = .string(index.rulesVersion)
        fields["time"] = json(index.orderingDate)
        fields["outcome"] = .string(index.outcome.rawValue)
        fields["state"] = json(index.presentation?.state.rawValue)
        fields["recoverable_count"] = json(index.recoverableCount)
        fields["needs_verification"] = .bool(index.needsVerification)
        // `subject` names the first item.
        if isPrivate { fields["private"] = true } else { fields["subject"] = json(index.subject) }
        return .object(fields)
    }

    static let recordItemLimit = 200

    static func operationRecord(_ report: CleanReport) -> AgentJSONValue {
        let index = CleanupReportIndex(report: report, orderingDate: report.completedAt)
        var fields = recordCounts(report.summary)
        fields["id"] = .string(report.planID.rawValue.uuidString)
        fields["kind"] = .string(report.rulesVersion)
        fields["started_at"] = json(report.startedAt)
        fields["completed_at"] = json(report.completedAt)
        fields["outcome"] = .string(report.outcome.rawValue)
        fields["state"] = json(index.presentation?.state.rawValue)
        fields["disposition"] = .string(report.disposition.rawValue)
        fields["scan_was_partial"] = .bool(report.scanWasPartial)
        fields["recoverable_count"] = json(index.recoverableCount)
        fields["needs_verification"] = .bool(index.needsVerification)
        fields["item_count"] = json(report.items.count)
        fields["items"] = .array(report.items.prefix(recordItemLimit).map { recordItem($0, of: report) })
        return .object(fields)
    }

    private static func recordItem(_ item: CleanReportItem, of report: CleanReport) -> AgentJSONValue {
        var fields: [String: AgentJSONValue] = ["estimated_bytes": .integer(item.estimatedBytes)]
        if isPrivateRule(item.ruleID) || isPrivateRule(report.rulesVersion) {
            fields["private"] = true
        } else {
            fields["path"] = .string(item.sourcePath)
        }
        switch item.outcome {
        case .moved(let receipt):
            fields["result"] = "moved"
            fields["can_restore"] = .bool(receipt.isRestorable && !report.recoveryBlocksRetry(of: receipt.originalPath))
        case .skipped(let reason):
            fields["result"] = "skipped"
            fields["detail"] = .string(reason.rawValue)
        case .failed(let failure):
            fields["result"] = "failed"
            fields["detail"] = .string(failure.code.rawValue)
        case .notProcessed:
            fields["result"] = "not_processed"
        case .deleted:
            fields["result"] = "deleted"
        }
        return .object(fields)
    }

    static func hardwareOperation(_ record: HardwareOperationRecord) -> AgentJSONValue {
        var targets: AgentJSONValue = .null
        if let rpm = record.targetRPMByFan {
            targets = .object(Dictionary(uniqueKeysWithValues: rpm.map { (String($0.key), json($0.value)) }))
        }
        return [
            "id": .string(record.id.uuidString),
            "time": json(record.recordedAt),
            "operation": .string(record.operation.rawValue),
            "outcome": .string(record.outcome.rawValue),
            "target_rpm_by_fan": targets,
            "automatic_fan_numbers": record.automaticFanIDs.map { .array($0.map { json($0) }) } ?? .null,
            "power_setting": json(record.powerSetting),
            "power_value": json(record.powerValue),
            "power_source": json(record.powerSource),
            "mac_mini_mode": json(record.macMiniMode?.rawValue),
            "error_code": json(record.errorCode),
            "automatic_restore_reason": json(record.automaticRestoreReason?.rawValue)
        ]
    }

    // MARK: History

    static func scanHistory(_ entry: ScanHistoryEntry) -> AgentJSONValue {
        [
            "date": json(entry.date),
            "scan_seconds": json(entry.scanSeconds),
            "score": json(entry.score),
            "disk_used_bytes": .integer(entry.diskUsedBytes),
            "disk_free_bytes": .integer(entry.diskFreeBytes),
            "green_bytes": .integer(entry.greenBytes),
            "yellow_bytes": .integer(entry.yellowBytes),
            "red_bytes": .integer(entry.redBytes),
            "item_count": json(entry.itemCount),
            "green_count": json(entry.greenCount),
            "yellow_count": json(entry.yellowCount),
            "red_count": json(entry.redCount),
            "denied_count": json(entry.deniedCount),
            "scan_was_limited": json(entry.scanWasLimited)
        ]
    }

    static func capacityHistory(_ point: CapacityHistoryPoint) -> AgentJSONValue {
        [
            "recorded_at": json(point.recordedAt),
            "total_bytes": .integer(point.totalBytes),
            "available_bytes": .integer(point.availableBytes),
            "available_for_important_usage_bytes": json(point.availableForImportantUsageBytes)
        ]
    }

    // MARK: Overview, live status, health

    private static func capacity(_ capacity: StorageCapacitySnapshot?) -> AgentJSONValue {
        guard let capacity else { return .null }
        return ["total_bytes": .integer(capacity.totalBytes), "available_bytes": .integer(capacity.availableBytes),
                "available_for_important_usage_bytes": json(capacity.availableForImportantUsageBytes)]
    }

    /// No process list (D266): a snapshot's `pressureSummary` and processes stay out.
    private static func memory(_ memory: MemorySnapshot?) -> AgentJSONValue {
        guard let memory else { return .null }
        return [
            "physical_bytes": .integer(memory.physicalBytes),
            "used_bytes": .integer(memory.usedBytes),
            "wired_bytes": .integer(memory.wiredBytes),
            "compressed_bytes": .integer(memory.compressedBytes),
            "swap_used_bytes": .integer(memory.swapUsedBytes),
            "pressure_free_percent": json(memory.pressureFreePercentage),
            "sampled_at": json(memory.generatedAt)
        ]
    }

    static func overview(_ state: AgentOverviewState, identity: AgentAppIdentity, context: AgentCallContext,
                         modules: [AgentJSONValue], now: Date) -> AgentJSONValue {
        var health: AgentJSONValue = .null
        if let evaluation = state.health {
            health = ["score": json(rounded: evaluation.score), "status": .string(evaluation.status.rawValue),
                      "confidence": .string(evaluation.confidence.level.rawValue), "evaluated_at": json(evaluation.evaluatedAt)]
        }
        return [
            "app": ["name": .string(identity.name), "version": .string(identity.version), "build": .string(identity.build),
                    "channel": .string(identity.channel), "mode": .string(state.isMenuBarOnly ? "menu_bar_only" : "main_window")],
            "client": ["name": .string(context.client.displayName), "permission": .string(context.decision.rawValue)],
            "disk": capacity(state.capacity),
            "memory": memory(state.memory),
            "health": health,
            "modules": .array(modules),
            "data_time": json(now)
        ]
    }

    static func liveStatus(_ state: AgentLiveState) -> AgentJSONValue {
        var fields: [String: AgentJSONValue] = [
            "data_time": json(state.snapshot?.generatedAt),
            "cpu": nil, "gpu": nil, "network": nil, "thermal": nil, "fans": [],
            "memory": memory(state.memory),
            "disk": capacity(state.capacity),
            "battery": nil
        ]
        if let battery = state.battery {
            fields["battery"] = ["charge_percent": json(battery.chargePercent), "is_charging": json(battery.isCharging),
                                 "power_source": json(battery.powerSource?.rawValue), "minutes_remaining": json(battery.minutesRemaining),
                                 "sampled_at": json(battery.sampledAt)]
        }
        guard let snapshot = state.snapshot else { return .object(fields) }
        // The numbers the panel's history reads from the same snapshot.
        let reading = MenuBarTelemetryPoint(snapshot: snapshot)
        fields["cpu"] = [
            "total_percent": json(reading.cpuTotal), "user_percent": json(reading.cpuUser), "system_percent": json(reading.cpuSystem),
            "load_average_1m": json(snapshot.loadAverage?.oneMinute), "load_average_5m": json(snapshot.loadAverage?.fiveMinutes),
            "load_average_15m": json(snapshot.loadAverage?.fifteenMinutes), "core_count": json(snapshot.cpuCoreUsagePercent?.count)
        ]
        if reading.gpu != nil || snapshot.gpuMemoryUsedBytes != nil {
            fields["gpu"] = ["usage_percent": json(reading.gpu), "memory_used_bytes": json(snapshot.gpuMemoryUsedBytes),
                             "sampled_at": json(snapshot.gpuReadingDate)]
        }
        if let throughput = snapshot.networkThroughput {
            fields["network"] = ["download_bytes_per_second": .integer(throughput.downBytesPerSecond),
                                 "upload_bytes_per_second": .integer(throughput.upBytesPerSecond)]
        }
        fields["thermal"] = [
            "state": .string(snapshot.thermalState.rawValue),
            "chip_celsius": json(reading.chipTemperature),
            "zones": .array((snapshot.temperatureReadings ?? []).map { ["zone": .string($0.zone.rawValue), "celsius": json($0.celsius)] }),
            "sampled_at": json(snapshot.sensorReadingDate)
        ]
        fields["fans"] = .array((snapshot.fanReadings ?? []).map { fan in
            ["number": json(fan.index), "actual_rpm": json(fan.actualRPM), "minimum_rpm": json(fan.minimumRPM),
             "maximum_rpm": json(fan.maximumRPM), "target_rpm": json(fan.targetRPM)]
        })
        return .object(fields)
    }

    static func health(_ state: AgentHealthState) -> AgentJSONValue {
        var fields: [String: AgentJSONValue] = ["issues": [], "score": nil, "battery": nil, "disk": nil]
        if let evaluation = state.evaluation {
            fields["score"] = json(rounded: evaluation.score)
            fields["status"] = .string(evaluation.status.rawValue)
            fields["coverage"] = json(evaluation.coverage, places: 2)
            fields["confidence"] = .string(evaluation.confidence.level.rawValue)
            fields["factors"] = .array(evaluation.components.map { component in
                ["factor": .string(component.factor.rawValue), "availability": .string(component.availability.rawValue),
                 "score": json(rounded: component.score), "evaluated_at": json(component.evaluatedAt)]
            })
        }
        if let time = state.evaluation?.evaluatedAt ?? state.snapshot?.generatedAt { fields["data_time"] = json(time) }
        if let snapshot = state.snapshot {
            // The statuses only: each part's summary text can name a volume or a backup disk.
            let parts: [(String, String, HealthStatus?)] = [
                ("disk", "磁盘", snapshot.disk.status), ("capacity", "磁盘空间", snapshot.capacity.status),
                ("backup", "备份", snapshot.backup.status), ("stability", "系统稳定性", snapshot.stability.status),
                ("battery", "电池", snapshot.battery?.status)
            ]
            fields["issues"] = .array(parts.compactMap { factor, title, status -> AgentJSONValue? in
                switch status {
                case .actionRequired: ["factor": .string(factor), "severity": "actionRequired", "title": .string(title + "需要处理")]
                case .attention: ["factor": .string(factor), "severity": "attention", "title": .string(title + "需要留意")]
                default: nil
                }
            })
            fields["disk"] = [
                "smart_status": .string(snapshot.disk.smartStatus.rawValue),
                "remaining_life_percent": json(snapshot.disk.remainingLifePercent),
                "total_bytes": json(snapshot.capacity.totalBytes),
                "available_bytes": json(snapshot.capacity.availableBytes),
                "seven_day_delta_bytes": json(snapshot.capacity.sevenDayDeltaBytes),
                "thirty_day_delta_bytes": json(snapshot.capacity.thirtyDayDeltaBytes),
                "days_until_pressure": json(state.storageForecast?.daysUntilPressure)
            ]
            if let battery = snapshot.battery {
                fields["battery"] = [
                    "maximum_capacity_percent": json(battery.maximumCapacityPercent),
                    "cycle_count": json(battery.cycleCount),
                    "condition": json(battery.condition?.rawValue),
                    "wear_trend": json(state.batteryTrend?.classification.rawValue),
                    "loss_per_90_days": json(state.batteryTrend?.lossPer90Days)
                ]
            }
        }
        return .object(fields)
    }

    // MARK: Values

    /// An app without a proper identifier must not cost the whole page: the
    /// guard refuses any ID that holds a path.
    private static func bundleID(_ value: String) -> AgentJSONValue {
        value.isEmpty || value.contains("/") ? .null : .string(value)
    }

    private static func json(_ value: String?) -> AgentJSONValue { value.map(AgentJSONValue.string) ?? .null }
    private static func json(_ value: Int?) -> AgentJSONValue { value.map { .integer(Int64($0)) } ?? .null }
    private static func json(_ value: Int64?) -> AgentJSONValue { value.map(AgentJSONValue.integer) ?? .null }
    private static func json(_ value: Bool?) -> AgentJSONValue { value.map(AgentJSONValue.bool) ?? .null }

    /// JSON has no NaN or infinity: a reading that is not a number is no reading.
    private static func json(_ value: Double?, places: Int = 1) -> AgentJSONValue {
        guard let value, value.isFinite else { return .null }
        let scale = pow(10, Double(places))
        return .number((value * scale).rounded() / scale)
    }

    private static func json(rounded value: Double?) -> AgentJSONValue {
        guard let value, value.isFinite, abs(value) < 1e15 else { return .null }
        return .integer(Int64(value.rounded()))
    }

    private static func json(_ value: Date?) -> AgentJSONValue {
        guard let value, value.timeIntervalSinceReferenceDate.isFinite else { return .null }
        return .string(value.ISO8601Format())
    }
}
