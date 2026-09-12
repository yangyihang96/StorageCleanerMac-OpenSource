import Foundation

enum HealthStatus: String, Codable, Equatable, Sendable {
    case healthy
    case attention
    case actionRequired
    case unavailable
}

enum HealthAvailability: String, Codable, Equatable, Sendable {
    case available
    case partial
    case permissionDenied
    case timedOut
    case cancelled
    case unavailable

    func normalizedStatus(_ proposedStatus: HealthStatus) -> HealthStatus {
        switch self {
        case .available:
            switch proposedStatus {
            case .healthy, .attention, .actionRequired:
                proposedStatus
            case .unavailable:
                .attention
            }
        case .partial:
            switch proposedStatus {
            case .healthy, .unavailable:
                .attention
            case .attention, .actionRequired:
                proposedStatus
            }
        case .permissionDenied, .timedOut, .cancelled, .unavailable:
            .unavailable
        }
    }

    var hasUsableData: Bool {
        switch self {
        case .available, .partial:
            true
        case .permissionDenied, .timedOut, .cancelled, .unavailable:
            false
        }
    }
}

enum DiskSMARTStatus: String, Codable, Equatable, Sendable {
    case verified
    case failing
    case unsupported
    case unavailable
}

struct DiskHealthSnapshot: Codable, Equatable, Sendable {
    let availability: HealthAvailability
    let status: HealthStatus
    let smartStatus: DiskSMARTStatus
    let isTRIMEnabled: Bool?
    let fileSystem: String?
    let isSolidState: Bool?
    let isInternal: Bool?
    let isFileVaultEnabled: Bool?
    let totalBytes: Int64?
    let availableBytes: Int64?
    let remainingLifePercent: Int?
    let temperatureCelsius: Double?
    let summaryText: String?
    let checkedAt: Date

    private enum CodingKeys: String, CodingKey {
        case availability
        case status
        case smartStatus
        case isTRIMEnabled
        case fileSystem
        case isSolidState
        case isInternal
        case isFileVaultEnabled
        case totalBytes
        case availableBytes
        case remainingLifePercent
        case temperatureCelsius
        case summaryText
        case checkedAt
    }

    init(
        availability: HealthAvailability,
        status: HealthStatus,
        smartStatus: DiskSMARTStatus,
        isTRIMEnabled: Bool?,
        fileSystem: String?,
        isSolidState: Bool? = nil,
        isInternal: Bool? = nil,
        isFileVaultEnabled: Bool? = nil,
        totalBytes: Int64? = nil,
        availableBytes: Int64? = nil,
        remainingLifePercent: Int? = nil,
        temperatureCelsius: Double? = nil,
        summaryText: String?,
        checkedAt: Date
    ) {
        self.availability = availability
        self.status = availability.normalizedStatus(status)
        self.smartStatus = smartStatus
        self.isTRIMEnabled = isTRIMEnabled
        self.fileSystem = fileSystem
        self.isSolidState = isSolidState
        self.isInternal = isInternal
        self.isFileVaultEnabled = isFileVaultEnabled
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.remainingLifePercent = remainingLifePercent
        self.temperatureCelsius = temperatureCelsius
        self.summaryText = summaryText
        self.checkedAt = checkedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            availability: try container.decode(HealthAvailability.self, forKey: .availability),
            status: try container.decode(HealthStatus.self, forKey: .status),
            smartStatus: try container.decode(DiskSMARTStatus.self, forKey: .smartStatus),
            isTRIMEnabled: try container.decodeIfPresent(Bool.self, forKey: .isTRIMEnabled),
            fileSystem: try container.decodeIfPresent(String.self, forKey: .fileSystem),
            isSolidState: try container.decodeIfPresent(Bool.self, forKey: .isSolidState),
            isInternal: try container.decodeIfPresent(Bool.self, forKey: .isInternal),
            isFileVaultEnabled: try container.decodeIfPresent(Bool.self, forKey: .isFileVaultEnabled),
            totalBytes: try container.decodeIfPresent(Int64.self, forKey: .totalBytes),
            availableBytes: try container.decodeIfPresent(Int64.self, forKey: .availableBytes),
            remainingLifePercent: try container.decodeIfPresent(
                Int.self,
                forKey: .remainingLifePercent
            ),
            temperatureCelsius: try container.decodeIfPresent(
                Double.self,
                forKey: .temperatureCelsius
            ),
            summaryText: try container.decodeIfPresent(String.self, forKey: .summaryText),
            checkedAt: try container.decode(Date.self, forKey: .checkedAt)
        )
    }
}

struct CapacityTrendSnapshot: Codable, Equatable, Sendable {
    let availability: HealthAvailability
    let status: HealthStatus
    let totalBytes: Int64?
    let availableBytes: Int64?
    let availableForImportantUsageBytes: Int64?
    let sevenDayDeltaBytes: Int64?
    let thirtyDayDeltaBytes: Int64?
    let recordedAt: Date

    private enum CodingKeys: String, CodingKey {
        case availability
        case status
        case totalBytes
        case availableBytes
        case availableForImportantUsageBytes
        case sevenDayDeltaBytes
        case thirtyDayDeltaBytes
        case recordedAt
    }

    init(
        availability: HealthAvailability,
        status: HealthStatus,
        totalBytes: Int64?,
        availableBytes: Int64?,
        availableForImportantUsageBytes: Int64?,
        sevenDayDeltaBytes: Int64?,
        thirtyDayDeltaBytes: Int64? = nil,
        recordedAt: Date
    ) {
        self.availability = availability
        self.status = availability.normalizedStatus(status)
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.sevenDayDeltaBytes = sevenDayDeltaBytes
        self.thirtyDayDeltaBytes = thirtyDayDeltaBytes
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            availability: try container.decode(HealthAvailability.self, forKey: .availability),
            status: try container.decode(HealthStatus.self, forKey: .status),
            totalBytes: try container.decodeIfPresent(Int64.self, forKey: .totalBytes),
            availableBytes: try container.decodeIfPresent(Int64.self, forKey: .availableBytes),
            availableForImportantUsageBytes: try container.decodeIfPresent(
                Int64.self,
                forKey: .availableForImportantUsageBytes
            ),
            sevenDayDeltaBytes: try container.decodeIfPresent(Int64.self, forKey: .sevenDayDeltaBytes),
            thirtyDayDeltaBytes: try container.decodeIfPresent(Int64.self, forKey: .thirtyDayDeltaBytes),
            recordedAt: try container.decode(Date.self, forKey: .recordedAt)
        )
    }
}

enum TimeMachineDestinationState: String, Codable, Equatable, Sendable {
    case unconfigured
    case configured
    case unreachable
    case permissionDenied
    case timedOut
    case unavailable
}

struct TimeMachineSnapshot: Codable, Equatable, Sendable {
    let availability: HealthAvailability
    let status: HealthStatus
    let destinationState: TimeMachineDestinationState
    let isRunning: Bool?
    let latestLocalSnapshot: Date?
    let latestCompleteBackup: Date?
    let completeBackupAvailability: HealthAvailability
    let summaryText: String?
    let checkedAt: Date

    private enum CodingKeys: String, CodingKey {
        case availability
        case status
        case destinationState
        case isRunning
        case latestLocalSnapshot
        case latestCompleteBackup
        case completeBackupAvailability
        case summaryText
        case checkedAt
    }

    init(
        availability: HealthAvailability,
        status: HealthStatus,
        destinationState: TimeMachineDestinationState,
        isRunning: Bool?,
        latestLocalSnapshot: Date?,
        latestCompleteBackup: Date?,
        completeBackupAvailability: HealthAvailability,
        summaryText: String?,
        checkedAt: Date
    ) {
        self.availability = availability
        self.status = availability.normalizedStatus(status)
        self.destinationState = destinationState
        self.isRunning = isRunning
        self.latestLocalSnapshot = latestLocalSnapshot
        self.latestCompleteBackup = latestCompleteBackup
        self.completeBackupAvailability = completeBackupAvailability
        self.summaryText = summaryText
        self.checkedAt = checkedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            availability: try container.decode(HealthAvailability.self, forKey: .availability),
            status: try container.decode(HealthStatus.self, forKey: .status),
            destinationState: try container.decode(
                TimeMachineDestinationState.self,
                forKey: .destinationState
            ),
            isRunning: try container.decodeIfPresent(Bool.self, forKey: .isRunning),
            latestLocalSnapshot: try container.decodeIfPresent(Date.self, forKey: .latestLocalSnapshot),
            latestCompleteBackup: try container.decodeIfPresent(Date.self, forKey: .latestCompleteBackup),
            completeBackupAvailability: try container.decode(
                HealthAvailability.self,
                forKey: .completeBackupAvailability
            ),
            summaryText: try container.decodeIfPresent(String.self, forKey: .summaryText),
            checkedAt: try container.decode(Date.self, forKey: .checkedAt)
        )
    }
}

enum StabilityEventType: String, Codable, Equatable, Sendable {
    case crash
    case hang
    case spin
    case panic
    case unexpectedRestart
}

struct StabilityEvent: Codable, Equatable, Sendable {
    let type: StabilityEventType
    let occurredAt: Date
}

struct StabilitySummary: Codable, Equatable, Sendable {
    let availability: HealthAvailability
    let status: HealthStatus
    let crashCount: Int?
    let hangCount: Int?
    let spinCount: Int?
    let panicCount: Int?
    let unexpectedRestartCount: Int?
    let events: [StabilityEvent]
    let filesExamined: Int
    let windowStart: Date?
    let generatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case availability
        case status
        case crashCount
        case hangCount
        case spinCount
        case panicCount
        case unexpectedRestartCount
        case events
        case filesExamined
        case windowStart
        case generatedAt
    }

    init(
        availability: HealthAvailability,
        status: HealthStatus,
        crashCount: Int?,
        hangCount: Int?,
        spinCount: Int? = nil,
        panicCount: Int? = nil,
        unexpectedRestartCount: Int?,
        events: [StabilityEvent] = [],
        filesExamined: Int,
        windowStart: Date?,
        generatedAt: Date
    ) {
        self.availability = availability
        self.status = availability.normalizedStatus(status)
        self.crashCount = crashCount
        self.hangCount = hangCount
        self.spinCount = spinCount
        self.panicCount = panicCount
        self.unexpectedRestartCount = unexpectedRestartCount
        self.events = events
        self.filesExamined = filesExamined
        self.windowStart = windowStart
        self.generatedAt = generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            availability: try container.decode(HealthAvailability.self, forKey: .availability),
            status: try container.decode(HealthStatus.self, forKey: .status),
            crashCount: try container.decodeIfPresent(Int.self, forKey: .crashCount),
            hangCount: try container.decodeIfPresent(Int.self, forKey: .hangCount),
            spinCount: try container.decodeIfPresent(Int.self, forKey: .spinCount),
            panicCount: try container.decodeIfPresent(Int.self, forKey: .panicCount),
            unexpectedRestartCount: try container.decodeIfPresent(
                Int.self,
                forKey: .unexpectedRestartCount
            ),
            events: try container.decodeIfPresent([StabilityEvent].self, forKey: .events) ?? [],
            filesExamined: try container.decode(Int.self, forKey: .filesExamined),
            windowStart: try container.decodeIfPresent(Date.self, forKey: .windowStart),
            generatedAt: try container.decode(Date.self, forKey: .generatedAt)
        )
    }
}

enum BatteryCondition: String, Codable, Equatable, Sendable {
    case normal
    case serviceRecommended
    case unknown
}

enum BatteryPowerMode: String, Codable, Equatable, Hashable, Sendable {
    case lowPower
    case automatic
    case highPower
}

enum BatteryGuidanceKind: String, Codable, Equatable, Sendable {
    case optimizedChargingNormal
    case considerLowPower
    case automaticRecommended
    case serviceRecommended
    case none
}

struct BatteryGuidance: Codable, Equatable, Sendable {
    let kind: BatteryGuidanceKind
    let detail: String?

    init(kind: BatteryGuidanceKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

struct BatteryHealthSnapshot: Codable, Equatable, Sendable {
    let availability: HealthAvailability
    let status: HealthStatus
    let currentChargePercent: Int?
    let isCharging: Bool?
    let powerSource: BatteryPowerSource?
    let remainingTimeMinutes: Int?
    let maximumCapacityPercent: Int?
    let cycleCount: Int?
    let condition: BatteryCondition?
    let batteryPowerMode: BatteryPowerMode?
    let adapterPowerMode: BatteryPowerMode?
    let guidance: BatteryGuidance
    let sampledAt: Date

    private enum CodingKeys: String, CodingKey {
        case availability
        case status
        case currentChargePercent
        case isCharging
        case powerSource
        case remainingTimeMinutes
        case maximumCapacityPercent
        case cycleCount
        case condition
        case batteryPowerMode
        case adapterPowerMode
        case guidance
        case sampledAt
    }

    init(
        availability: HealthAvailability,
        status: HealthStatus,
        currentChargePercent: Int?,
        isCharging: Bool?,
        powerSource: BatteryPowerSource? = nil,
        remainingTimeMinutes: Int? = nil,
        maximumCapacityPercent: Int?,
        cycleCount: Int?,
        condition: BatteryCondition?,
        batteryPowerMode: BatteryPowerMode?,
        adapterPowerMode: BatteryPowerMode?,
        guidance: BatteryGuidance,
        sampledAt: Date
    ) {
        self.availability = availability
        self.status = availability.normalizedStatus(status)
        self.currentChargePercent = currentChargePercent
        self.isCharging = isCharging
        self.powerSource = powerSource
        self.remainingTimeMinutes = remainingTimeMinutes
        self.maximumCapacityPercent = maximumCapacityPercent
        self.cycleCount = cycleCount
        self.condition = condition
        self.batteryPowerMode = batteryPowerMode
        self.adapterPowerMode = adapterPowerMode
        self.guidance = guidance
        self.sampledAt = sampledAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            availability: try container.decode(HealthAvailability.self, forKey: .availability),
            status: try container.decode(HealthStatus.self, forKey: .status),
            currentChargePercent: try container.decodeIfPresent(Int.self, forKey: .currentChargePercent),
            isCharging: try container.decodeIfPresent(Bool.self, forKey: .isCharging),
            powerSource: try container.decodeIfPresent(BatteryPowerSource.self, forKey: .powerSource),
            remainingTimeMinutes: try container.decodeIfPresent(
                Int.self,
                forKey: .remainingTimeMinutes
            ),
            maximumCapacityPercent: try container.decodeIfPresent(
                Int.self,
                forKey: .maximumCapacityPercent
            ),
            cycleCount: try container.decodeIfPresent(Int.self, forKey: .cycleCount),
            condition: try container.decodeIfPresent(BatteryCondition.self, forKey: .condition),
            batteryPowerMode: try container.decodeIfPresent(
                BatteryPowerMode.self,
                forKey: .batteryPowerMode
            ),
            adapterPowerMode: try container.decodeIfPresent(
                BatteryPowerMode.self,
                forKey: .adapterPowerMode
            ),
            guidance: try container.decode(BatteryGuidance.self, forKey: .guidance),
            sampledAt: try container.decode(Date.self, forKey: .sampledAt)
        )
    }
}

enum BatteryHealthProbeFailureReason: String, Codable, Equatable, Sendable {
    case permissionDenied
    case timedOut
    case cancelled
    case unavailable
    case readFailed
}

enum BatteryHealthEvidence: Codable, Equatable, Sendable {
    case present(BatteryHealthSnapshot)
    case notPresent(checkedAt: Date)
    case failed(reason: BatteryHealthProbeFailureReason, checkedAt: Date)

    var snapshot: BatteryHealthSnapshot? {
        guard case let .present(snapshot) = self else { return nil }
        return snapshot
    }

    var checkedAt: Date {
        switch self {
        case let .present(snapshot):
            snapshot.sampledAt
        case let .notPresent(checkedAt), let .failed(_, checkedAt):
            checkedAt
        }
    }
}

struct ComputerHealthSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let disk: DiskHealthSnapshot
    let capacity: CapacityTrendSnapshot
    let backup: TimeMachineSnapshot
    let stability: StabilitySummary
    let batteryEvidence: BatteryHealthEvidence

    var battery: BatteryHealthSnapshot? { batteryEvidence.snapshot }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case disk
        case capacity
        case backup
        case stability
        case battery
        case batteryEvidence
    }

    init(
        generatedAt: Date,
        disk: DiskHealthSnapshot,
        capacity: CapacityTrendSnapshot,
        backup: TimeMachineSnapshot,
        stability: StabilitySummary,
        battery: BatteryHealthSnapshot?
    ) {
        self.init(
            generatedAt: generatedAt,
            disk: disk,
            capacity: capacity,
            backup: backup,
            stability: stability,
            batteryEvidence: battery.map(BatteryHealthEvidence.present)
                ?? .failed(reason: .unavailable, checkedAt: generatedAt)
        )
    }

    init(
        generatedAt: Date,
        disk: DiskHealthSnapshot,
        capacity: CapacityTrendSnapshot,
        backup: TimeMachineSnapshot,
        stability: StabilitySummary,
        batteryEvidence: BatteryHealthEvidence
    ) {
        self.generatedAt = generatedAt
        self.disk = disk
        self.capacity = capacity
        self.backup = backup
        self.stability = stability
        self.batteryEvidence = batteryEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        let evidence: BatteryHealthEvidence
        if let decoded = try container.decodeIfPresent(
            BatteryHealthEvidence.self,
            forKey: .batteryEvidence
        ) {
            evidence = decoded
        } else {
            let snapshot = try container.decodeIfPresent(BatteryHealthSnapshot.self, forKey: .battery)
            evidence = snapshot.map(BatteryHealthEvidence.present)
                ?? .failed(reason: .unavailable, checkedAt: generatedAt)
        }

        self.init(
            generatedAt: generatedAt,
            disk: try container.decode(DiskHealthSnapshot.self, forKey: .disk),
            capacity: try container.decode(CapacityTrendSnapshot.self, forKey: .capacity),
            backup: try container.decode(TimeMachineSnapshot.self, forKey: .backup),
            stability: try container.decode(StabilitySummary.self, forKey: .stability),
            batteryEvidence: evidence
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(disk, forKey: .disk)
        try container.encode(capacity, forKey: .capacity)
        try container.encode(backup, forKey: .backup)
        try container.encode(stability, forKey: .stability)

        switch batteryEvidence {
        case let .present(snapshot):
            // Keep the established on-disk shape for present batteries so older
            // builds can still decode a snapshot written by this version.
            try container.encode(snapshot, forKey: .battery)
        case .notPresent, .failed:
            try container.encode(batteryEvidence, forKey: .batteryEvidence)
        }
    }
}

enum ComputerHealthIssue: String, Codable, Equatable, Sendable {
    case disk
    case capacity
    case backup
    case stability
    case battery
}

extension ComputerHealthSnapshot {
    var actionRequiredIssues: [ComputerHealthIssue] {
        var issues = [ComputerHealthIssue]()
        if disk.status == .actionRequired { issues.append(.disk) }
        if capacity.status == .actionRequired { issues.append(.capacity) }
        if backup.status == .actionRequired { issues.append(.backup) }
        if stability.status == .actionRequired { issues.append(.stability) }
        if battery?.status == .actionRequired { issues.append(.battery) }
        return issues
    }
}

struct MenuBarHealthSummary: Codable, Equatable, Sendable {
    let generatedAt: Date
    let diskSMARTStatus: DiskSMARTStatus?
    let diskRemainingLifePercent: Int?
    let diskStatusText: String?
    let capacitySevenDayDeltaBytes: Int64?
    let backupStatusText: String?
    let batteryCapacityPercent: Int?
    let batteryCycleCount: Int?
    let batteryCondition: BatteryCondition?
    let batteryPowerMode: BatteryPowerMode?
    let lastDownloadMbps: Double?
    let lastUploadMbps: Double?
    let lastSpeedTestAt: Date?

    init(
        generatedAt: Date,
        diskSMARTStatus: DiskSMARTStatus? = nil,
        diskRemainingLifePercent: Int? = nil,
        diskStatusText: String? = nil,
        capacitySevenDayDeltaBytes: Int64? = nil,
        backupStatusText: String? = nil,
        batteryCapacityPercent: Int? = nil,
        batteryCycleCount: Int? = nil,
        batteryCondition: BatteryCondition? = nil,
        batteryPowerMode: BatteryPowerMode? = nil,
        lastDownloadMbps: Double? = nil,
        lastUploadMbps: Double? = nil,
        lastSpeedTestAt: Date? = nil
    ) {
        self.generatedAt = generatedAt
        self.diskSMARTStatus = diskSMARTStatus
        self.diskRemainingLifePercent = diskRemainingLifePercent.flatMap {
            (0...100).contains($0) ? $0 : nil
        }
        self.diskStatusText = diskStatusText
        self.capacitySevenDayDeltaBytes = capacitySevenDayDeltaBytes
        self.backupStatusText = backupStatusText
        self.batteryCapacityPercent = batteryCapacityPercent
        self.batteryCycleCount = batteryCycleCount
        self.batteryCondition = batteryCondition
        self.batteryPowerMode = batteryPowerMode
        self.lastDownloadMbps = lastDownloadMbps
        self.lastUploadMbps = lastUploadMbps
        self.lastSpeedTestAt = lastSpeedTestAt
    }

    init(snapshot: ComputerHealthSnapshot) {
        let diskIsUsable = snapshot.disk.availability.hasUsableData
            && snapshot.disk.status != .unavailable
        let capacityIsUsable = snapshot.capacity.availability.hasUsableData
            && snapshot.capacity.status != .unavailable
        let backupIsUsable = snapshot.backup.availability.hasUsableData
            && snapshot.backup.status != .unavailable
        let battery = snapshot.battery.flatMap { battery in
            battery.availability.hasUsableData && battery.status != .unavailable
                ? battery
                : nil
        }

        self.init(
            generatedAt: snapshot.generatedAt,
            diskSMARTStatus: diskIsUsable && snapshot.disk.smartStatus != .unavailable
                ? snapshot.disk.smartStatus
                : nil,
            diskRemainingLifePercent: diskIsUsable
                ? snapshot.disk.remainingLifePercent
                : nil,
            diskStatusText: diskIsUsable
                ? Self.normalizedSummaryText(snapshot.disk.summaryText)
                : nil,
            capacitySevenDayDeltaBytes: capacityIsUsable
                ? snapshot.capacity.sevenDayDeltaBytes
                : nil,
            backupStatusText: backupIsUsable
                ? Self.normalizedSummaryText(snapshot.backup.summaryText)
                : nil,
            batteryCapacityPercent: battery?.maximumCapacityPercent,
            batteryCycleCount: battery?.cycleCount,
            batteryCondition: battery?.condition,
            batteryPowerMode: battery?.batteryPowerMode
        )
    }

    func includingNetworkResult(
        downloadMbps: Double,
        uploadMbps: Double,
        testedAt: Date
    ) -> MenuBarHealthSummary {
        MenuBarHealthSummary(
            generatedAt: max(generatedAt, testedAt),
            diskSMARTStatus: diskSMARTStatus,
            diskRemainingLifePercent: diskRemainingLifePercent,
            diskStatusText: diskStatusText,
            capacitySevenDayDeltaBytes: capacitySevenDayDeltaBytes,
            backupStatusText: backupStatusText,
            batteryCapacityPercent: batteryCapacityPercent,
            batteryCycleCount: batteryCycleCount,
            batteryCondition: batteryCondition,
            batteryPowerMode: batteryPowerMode,
            lastDownloadMbps: downloadMbps.isFinite && downloadMbps >= 0 ? downloadMbps : nil,
            lastUploadMbps: uploadMbps.isFinite && uploadMbps >= 0 ? uploadMbps : nil,
            lastSpeedTestAt: testedAt
        )
    }

    func retainingDiskHealth(
        from previous: MenuBarHealthSummary?,
        fallbackRemainingLifePercent: Int? = nil
    ) -> MenuBarHealthSummary {
        guard diskRemainingLifePercent == nil,
              let previousPercent = previous?.diskRemainingLifePercent
                ?? fallbackRemainingLifePercent else { return self }
        return MenuBarHealthSummary(
            generatedAt: generatedAt,
            diskSMARTStatus: diskSMARTStatus ?? previous?.diskSMARTStatus,
            diskRemainingLifePercent: previousPercent,
            diskStatusText: diskStatusText ?? previous?.diskStatusText,
            capacitySevenDayDeltaBytes: capacitySevenDayDeltaBytes,
            backupStatusText: backupStatusText,
            batteryCapacityPercent: batteryCapacityPercent,
            batteryCycleCount: batteryCycleCount,
            batteryCondition: batteryCondition,
            batteryPowerMode: batteryPowerMode,
            lastDownloadMbps: lastDownloadMbps,
            lastUploadMbps: lastUploadMbps,
            lastSpeedTestAt: lastSpeedTestAt
        )
    }

    private static func normalizedSummaryText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ComputerHealthRefreshError: String, CaseIterable, Codable, Error, Equatable, Hashable, Sendable {
    case cancelled
    case timedOut
    case permissionDenied
    case readFailed
}
