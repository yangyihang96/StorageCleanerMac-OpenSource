import AppKit
import SwiftUI

extension SettingsView {
    var selectedMaintenanceCadence: Binding<MaintenanceReminderCadence> {
        Binding {
            MaintenanceReminderService.cadence(from: maintenanceCadenceRawValue)
        } set: { newValue in
            maintenanceCadenceRawValue = newValue.rawValue
            // D219: the reminder card reads the interval when it decides.
            NotificationCenter.default.post(name: AppLifecycleReminderPreferences.didChangeNotification, object: nil)
        }
    }

    var maintenanceReminderSection: some View {
        let cadence = MaintenanceReminderService.cadence(from: maintenanceCadenceRawValue)
        let summary = MaintenanceReminderService.summary(
            cadence: cadence,
            lastScanAt: scanHistorySummary.latestScanAt
        )

        return LightfieldSettingsSection {
            SettingsPickerRow(title: L10n.text("提醒频率", "Reminder Frequency"), selection: selectedMaintenanceCadence) {
                ForEach(MaintenanceReminderCadence.allCases) { cadence in
                    Text(cadence.title)
                        .tag(cadence)
                }
            }

            SettingsValueRow(
                title: L10n.text("状态", "Status"),
                caption: L10n.text("上次扫描", "Last Scan") + " " + reminderDateText(summary.lastScanAt)
                    + " · " + L10n.text("下次建议", "Next Due") + " " + reminderDateText(summary.nextDueAt),
                value: summary.statusTitle
            )

            if let entry = scanHistorySummary.latest, entry.smartScanHealthStatus != nil {
                ScanHistoryHealthStatusLine(entry: entry)
            }
        } header: {
            Text(L10n.text("扫描提醒", "Scan Reminder"))
        } footer: {
            Text(L10n.text("到期时，菜单栏图标下方会出现提醒；点“现在扫描”只做只读扫描，不会清理。",
                           "When a scan is due, a reminder appears under the menu-bar icon; Scan Now only runs a read-only scan and cleans nothing."))
        }
    }

    func reminderDateText(_ date: Date?) -> String {
        guard let date else {
            return L10n.text("暂无", "None")
        }
        return date.appFormatted(date: .abbreviated, time: .shortened)
    }
}
