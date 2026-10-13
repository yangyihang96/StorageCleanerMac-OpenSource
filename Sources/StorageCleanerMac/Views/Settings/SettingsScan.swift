import AppKit
import ServiceManagement
import SwiftUI

extension SettingsView {
    var selectedMaintenanceCadence: Binding<MaintenanceReminderCadence> {
        Binding {
            MaintenanceReminderService.cadence(from: maintenanceCadenceRawValue)
        } set: { newValue in
            maintenanceCadenceRawValue = newValue.rawValue
        }
    }

    var maintenanceReminderSection: some View {
        let cadence = MaintenanceReminderService.cadence(from: maintenanceCadenceRawValue)
        let summary = MaintenanceReminderService.summary(
            cadence: cadence,
            lastScanAt: scanHistorySummary.latestScanAt
        )

        return Section {
            Picker(L10n.text("提醒频率", "Reminder Frequency"), selection: selectedMaintenanceCadence) {
                ForEach(MaintenanceReminderCadence.allCases) { cadence in
                    Text(cadence.title)
                        .tag(cadence)
                }
            }
            .pickerStyle(.menu)

            LabeledContent(L10n.text("状态", "Status"), value: summary.statusTitle)
            LabeledContent(L10n.text("上次扫描", "Last Scan"), value: reminderDateText(summary.lastScanAt))
            LabeledContent(L10n.text("下次建议", "Next Due"), value: reminderDateText(summary.nextDueAt))
            if let entry = scanHistorySummary.latest {
                ScanHistoryHealthStatusLine(entry: entry)
            }
        } header: {
            Text(L10n.text("扫描提醒", "Scan Reminder"))
        }
    }

    var exclusionSection: some View {
        LightfieldSettingsSection {
            LabeledContent(L10n.text("已排除", "Excluded"), value: L10n.items(excludedPaths.count))
            LabeledContent(
                L10n.text("适用范围", "Applies To"),
                value: L10n.text("智能扫描与重复文件", "Smart Scan & Duplicates")
            )

            if let exclusionNotice {
                SettingsNoticeView(notice: exclusionNotice)
            }

            if excludedPaths.isEmpty {
                Text(L10n.text("暂无排除项", "No Exclusions"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(excludedPaths, id: \.self) { path in
                    ExclusionPathRow(path: path) {
                        removeExclusion(path)
                    }
                    .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
                }
            }

            exclusionActionButtons
                .animation(
                    AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                    value: excludedPaths
                )
        } header: {
            exclusionTitle
        }
    }

    var exclusionTitle: some View {
        Text(L10n.text("扫描排除", "Scan Exclusions"))
    }

    var exclusionActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                addExclusion()
            } label: {
                Text(L10n.text("添加排除项", "Add Exclusion"))
            }
            .disabled(exclusionPanelCoordinator.isPresenting)

            if !excludedPaths.isEmpty {
                Button {
                    copyExclusions()
                } label: {
                    Text(L10n.text("复制清单", "Copy List"))
                }
            }

            if !excludedPaths.isEmpty {
                Button(role: .destructive) {
                    clearExclusions()
                } label: {
                    Text(L10n.text("移除全部排除项", "Remove All Exclusions"))
                }
            }
        }
    }

    func addExclusion() {
        guard !exclusionPanelCoordinator.isPresenting else { return }

        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要排除的项目", "Choose Items to Exclude")
        panel.prompt = L10n.text("加入排除项", "Exclude")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        let completion: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            applyExclusions(panel.urls)
        }

        exclusionPanelCoordinator.present(
            panel,
            attachedTo: AppOpenPanelCoordinator.preferredHostWindow(),
            completion: completion
        )
    }

    func applyExclusions(_ urls: [URL]) {
        var addedCount = 0
        var rejectedCount = 0
        var duplicateCount = 0

        for url in urls {
            if !ScanExclusionService.canExclude(url.path) {
                rejectedCount += 1
            } else if ScanExclusionService.add(url.path) {
                addedCount += 1
            } else {
                duplicateCount += 1
            }
        }
        excludedPaths = ScanExclusionService.excludedPaths()
        exclusionNotice = noticeForExclusionResult(
            addedCount: addedCount,
            rejectedCount: rejectedCount,
            duplicateCount: duplicateCount
        )
    }

    func copyExclusions() {
        guard !excludedPaths.isEmpty else {
            exclusionNotice = SettingsNotice(
                text: L10n.text("当前没有可复制的扫描排除项。", "There are no scan exclusions to copy."),
                systemImage: "info.circle.fill",
                tint: AppDesignTokens.Palette.information,
                severity: .information
            )
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ScanExclusionService.markdown(for: excludedPaths), forType: .string)
        exclusionNotice = SettingsNotice(
            text: L10n.text("扫描排除项清单已复制。", "Scan exclusion list copied."),
            systemImage: "doc.on.doc.fill",
            tint: AppDesignTokens.Palette.success,
            severity: .success
        )
    }

    func removeExclusion(_ path: String) {
        ScanExclusionService.remove(path)
        excludedPaths = ScanExclusionService.excludedPaths()
        exclusionNotice = SettingsNotice(
            text: L10n.text("已从扫描排除项移除“\(ScanExclusionService.displayName(for: path))”。", "Removed \"\(ScanExclusionService.displayName(for: path))\" from scan exclusions."),
            systemImage: "minus.circle.fill",
            tint: AppDesignTokens.Palette.warning,
            severity: .success
        )
    }

    func clearExclusions() {
        ScanExclusionService.clear()
        excludedPaths = ScanExclusionService.excludedPaths()
        exclusionNotice = SettingsNotice(
            text: L10n.text("已清空扫描排除项。", "Cleared scan exclusions."),
            systemImage: "trash.fill",
            tint: AppDesignTokens.Palette.destructive,
            severity: .success
        )
    }

    func noticeForExclusionResult(
        addedCount: Int,
        rejectedCount: Int,
        duplicateCount: Int
    ) -> SettingsNotice? {
        if addedCount > 0 {
            return SettingsNotice(
                text: L10n.text(
                    "已添加 \(addedCount) 个排除项。",
                    "Added \(addedCount) exclusions."
                ),
                systemImage: "checkmark.circle.fill",
                tint: AppDesignTokens.Palette.success,
                severity: .success
            )
        }

        if rejectedCount > 0 {
            return SettingsNotice(
                text: L10n.text(
                    "未添加：只能排除个人目录或 /Applications 下的项目，系统根目录会被保护。",
                    "Not added: exclusions are limited to your home folder or /Applications; system root paths are protected."
                ),
                systemImage: "lock.shield.fill",
                tint: AppDesignTokens.Palette.destructive,
                severity: .locked
            )
        }

        if duplicateCount > 0 {
            return SettingsNotice(
                text: L10n.text("这些项目已经在排除列表中。", "These items are already excluded."),
                systemImage: "info.circle.fill",
                tint: AppDesignTokens.Palette.information,
                severity: .information
            )
        }

        return nil
    }

    func reminderDateText(_ date: Date?) -> String {
        guard let date else {
            return L10n.text("暂无", "None")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
