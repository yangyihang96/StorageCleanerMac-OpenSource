import Foundation
@testable import StorageCleanerMac

enum ComputerHealthSecurityFixture {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    static func snapshot(offset: TimeInterval = 0, securityState: SystemProtectionState? = .enabled,
        smart: DiskSMARTStatus = .verified, availableBytes: Int64 = 200 * 1_073_741_824,
        securityEvidence: String? = nil, changes: [ComputerHealthChangeEvent] = [],
        stabilityStatus: HealthStatus = .healthy, backupStatus: HealthStatus = .healthy,
        capacityStatus: HealthStatus = .healthy,
        batteryEvidence: BatteryHealthEvidence? = nil
    ) -> ComputerHealthSnapshot {
        let now = date.addingTimeInterval(offset)
        return ComputerHealthSnapshot(generatedAt: now,
            disk: DiskHealthSnapshot(availability: .available, status: smart == .failing ? .actionRequired : .healthy,
                smartStatus: smart, isTRIMEnabled: nil, fileSystem: "APFS",
                summaryText: "private-volume-and-path-must-not-be-persisted", checkedAt: now),
            capacity: CapacityTrendSnapshot(availability: .available, status: capacityStatus,
                totalBytes: 512 * 1_073_741_824, availableBytes: availableBytes,
                availableForImportantUsageBytes: availableBytes, sevenDayDeltaBytes: nil, recordedAt: now),
            backup: TimeMachineSnapshot(availability: .available, status: backupStatus, destinationState: .configured,
                isRunning: false, latestLocalSnapshot: nil, latestCompleteBackup: now,
                completeBackupAvailability: .available, summaryText: "private-backup-name", checkedAt: now),
            stability: StabilitySummary(availability: .available, status: stabilityStatus,
                crashCount: 0, hangCount: 0, panicCount: 0, unexpectedRestartCount: 0,
                filesExamined: 0, windowStart: now, generatedAt: now),
            batteryEvidence: batteryEvidence ?? .notPresent(checkedAt: now),
            security: securityState.map { state in SystemProtectionSnapshot(
                findings: SystemProtectionCheck.healthChecks.map {
                    SystemProtectionFinding(check: $0, state: state, evidenceSummary: securityEvidence)
                }, checkedAt: now) }, recentChanges: changes)
    }
}
