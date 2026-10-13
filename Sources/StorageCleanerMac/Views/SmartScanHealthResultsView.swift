import SwiftUI

/// Actual selected health evidence, never a synthetic score or a cleanup action.
struct SmartScanHealthResultsView: View {
    @AppSurfaces private var surfaces
    let snapshot: ComputerHealthSnapshot?
    var status: SmartScanHealthStatus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SmartScanScope.health.title).font(AppDesignTokens.TypeScale.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            if let snapshot {
                // One row system with the security rows below (D67 lightfield
                // status rows); values are the measured evidence only.
                VStack(spacing: 0) {
                    FeatureLightfieldHairline()
                    FeatureLightfieldStatusRow(title: L10n.text("磁盘 SMART", "Disk SMART"),
                        detail: snapshot.disk.remainingLifePercent.map { L10n.text("介质寿命估算 \($0)%", "Media Life Estimate \($0)%") } ?? "SMART",
                        value: smartStatus(snapshot.disk.smartStatus), status: smartTone(snapshot.disk.smartStatus))
                    FeatureLightfieldStatusRow(title: L10n.text("可用容量", "Free Space"),
                        detail: (snapshot.disk.availableBytes ?? snapshot.capacity.availableBytes).map { ByteFormat.string($0) } ?? unavailable,
                        value: ComputerHealthCheckState(status: snapshot.capacity.status).title,
                        status: HealthRecentChangesView.status(for: .init(status: snapshot.capacity.status)))
                    if case .notPresent = snapshot.batteryEvidence {
                        FeatureLightfieldStatusRow(title: L10n.text("电池", "Battery"),
                            detail: L10n.text("无内置电池", "No internal battery"),
                            value: ComputerHealthCheckState.notApplicable.title, status: .unknown)
                    } else {
                        FeatureLightfieldStatusRow(title: L10n.text("电池", "Battery"),
                            detail: batteryDetail(snapshot.battery),
                            value: snapshot.battery.map { ComputerHealthCheckState(status: $0.status).title } ?? unavailable,
                            status: snapshot.battery.map { HealthRecentChangesView.status(for: .init(status: $0.status)) } ?? .unknown)
                    }
                    HealthSecurityChecksView(snapshot: snapshot.security)
                }
                HealthRecentChangesView(events: snapshot.recentChanges, readFailed: snapshot.changeLogReadFailed,
                    journalReset: snapshot.changeLogWasReset)
                Text(snapshot.generatedAt.formatted(date: .abbreviated, time: .standard))
                    .font(AppDesignTokens.TypeScale.caption).foregroundStyle(surfaces.textSecondary)
            } else {
                Text(status?.title ?? unavailable).foregroundStyle(surfaces.textSecondary)
            }
        }
        .foregroundStyle(surfaces.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
#if DEBUG
        .layoutProbe("smartScan.healthResult")
#endif
    }
    private var unavailable: String { L10n.text("信息不可用", "Information unavailable") }
    private func batteryDetail(_ battery: BatteryHealthSnapshot?) -> String {
        let capacity = battery?.maximumCapacityPercent.map { L10n.text("最大容量 \($0)%", "Maximum Capacity \($0)%") }
        let cycles = battery?.cycleCount.map { L10n.text("循环 \($0) 次", "\($0) Cycles") }
        let parts = [capacity, cycles].compactMap { $0 }
        return parts.isEmpty ? unavailable : parts.joined(separator: " · ")
    }
    private func smartTone(_ value: DiskSMARTStatus) -> FeatureLightfieldStatus {
        switch value {
        case .verified: .normal
        case .failing: .warning
        case .unsupported, .unavailable: .unknown
        }
    }
    private func smartStatus(_ value: DiskSMARTStatus) -> String {
        switch value {
        case .verified: L10n.text("已验证", "Verified")
        case .failing: L10n.text("故障警告", "Failure warning")
        case .unsupported: L10n.text("设备不支持", "Unsupported by device")
        case .unavailable: unavailable
        }
    }
}
