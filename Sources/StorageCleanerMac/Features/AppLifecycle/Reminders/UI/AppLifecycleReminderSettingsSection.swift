import SwiftUI

/// CleanMyMac Settings → Notifications: “Offer to uninstall applications
/// correctly” and “Notify if Trash size exceeds”, plus resetting what the
/// reminders were told to ignore. D211: that reset names the
/// reminders, not the Ignore List (D207), which it never touches. D220 adds
/// the free-space warning and its threshold. D224: the rows say it in this
/// app's words (they had CleanMyMac's sentences word for word).
struct AppLifecycleReminderSettingsSection: View {
    @ObservedObject private var center = AppLifecycleReminderCenter.shared
    @State private var snapshot = AppLifecycleReminderPreferences.snapshot()
    @State private var ignoredCount = AppLifecycleReminderCenter.shared.ignoreList.activeRecords().count
    @State private var confirmsReset = false

    var body: some View {
        LightfieldSettingsSection {
            SettingsToggleRow(
                title: L10n.text("应用放进废纸篓时，提醒清理它的残留",
                                 "Remind me to remove an app's leftovers when it goes to the Trash"),
                caption: L10n.text("把应用拖进废纸篓后，菜单栏会提醒你找出它留下的设置和缓存等文件，一起移除。",
                                   "After you drag an app to the Trash, a reminder in the menu bar helps you find its settings, caches and other files and remove them too."),
                isOn: binding(\.offersCorrectUninstall))
            thresholdRow(title: L10n.text("废纸篓超过这个大小时提醒", "Remind when the Trash grows past"),
                         caption: trashCaption,
                         captionColor: center.measurement?.isReadable == false ? .orange : nil,
                         isOn: binding(\.notifiesTrashSize),
                         selection: binding(\.trashSizeThresholdBytes),
                         choices: thresholdChoices)
            thresholdRow(title: L10n.text("可用空间不足这个值时提醒", "Remind when free space drops below"),
                         caption: spaceCaption,
                         captionColor: center.startupDiskSpace.map { $0.availableBytes < snapshot.lowDiskSpaceThresholdBytes } == true ? .orange : nil,
                         isOn: binding(\.notifiesLowDiskSpace),
                         selection: binding(\.lowDiskSpaceThresholdBytes),
                         choices: spaceThresholdChoices)
            SettingsRow(title: L10n.text("已忽略的提醒：\(ByteFormat.count(ignoredCount)) 项", "Ignored reminders: \(ByteFormat.count(ignoredCount))")) {
                if ignoredCount > 0 {
                    SettingsLinkButton(title: L10n.text("重置已忽略的提醒", "Reset Ignored Reminders")) { confirmsReset = true }
                }
            }
        } header: {
            Text(L10n.text("应用、废纸篓与磁盘提醒", "App, Trash and Disk Reminders"))
        } footer: {
            Text(L10n.text("提醒出现在菜单栏图标下方；全屏、使用摄像头、打开小窗或正在使用本应用时会稍后再出现。",
                           "Reminders appear under the menu-bar icon; they wait while a full-screen app, a camera, the mini window or this app is in use."))
        }
        .confirmationDialog(
            L10n.text("确定要重置已忽略的提醒吗？", "Reset ignored reminders?"),
            isPresented: $confirmsReset
        ) {
            Button(L10n.text("重置已忽略的提醒", "Reset Ignored Reminders"), role: .destructive) {
                center.ignoreList.reset()
                center.releaseHandledReminders()
                ignoredCount = 0
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("之前选择忽略的卸载、废纸篓、磁盘空间和扫描提醒会重新出现；忽略列表里的项目不受影响。",
                           "Uninstall, Trash, disk space and scan reminders you ignored earlier will appear again. Items on the Ignore List are not affected."))
        }
        .onAppear {
            snapshot = AppLifecycleReminderPreferences.snapshot()
            ignoredCount = center.ignoreList.activeRecords().count
        }
    }

    private func thresholdRow(title: String, caption: String?, captionColor: Color?, isOn: Binding<Bool>,
                              selection: Binding<Int64>, choices: [Int64]) -> some View {
        SettingsRow(title: title, caption: caption, captionColor: captionColor) {
            HStack(spacing: 12) {
                Picker(title, selection: selection) {
                    ForEach(choices, id: \.self) { bytes in
                        Text(AppLifecycleReminderPreferences.thresholdTitle(bytes)).tag(bytes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .featureLightfieldMenuTint()
                .fixedSize()
                .disabled(!isOn.wrappedValue)
                SettingsSwitch(title: title, isOn: isOn)
            }
        }
    }

    private var trashCaption: String? {
        guard let measurement = center.measurement else { return nil }
        return L10n.text("废纸篓当前大小", "Trash Now") + " " + (measurement.isReadable
            ? "\(L10n.items(measurement.itemCount)) · \(ByteFormat.storageString(measurement.totalBytes))"
            : L10n.text("需要“完全磁盘访问权限”才能读取", "Needs Full Disk Access to read"))
    }

    private var spaceCaption: String? {
        center.startupDiskSpace.map {
            L10n.text("启动磁盘当前可用", "Startup Disk Free Now") + " " + ByteFormat.storageString($0.availableBytes)
        }
    }

    private var thresholdChoices: [Int64] {
        var choices = AppLifecycleReminderPreferences.trashSizeThresholdChoices
        if !choices.contains(snapshot.trashSizeThresholdBytes) {
            choices.append(snapshot.trashSizeThresholdBytes)
            choices.sort()
        }
        return choices
    }

    private var spaceThresholdChoices: [Int64] {
        var choices = AppLifecycleReminderPreferences.lowDiskSpaceThresholdChoices
        if !choices.contains(snapshot.lowDiskSpaceThresholdBytes) {
            choices.append(snapshot.lowDiskSpaceThresholdBytes)
            choices.sort()
        }
        return choices
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppLifecycleReminderPreferencesSnapshot, Value>) -> Binding<Value> {
        Binding {
            snapshot[keyPath: keyPath]
        } set: { newValue in
            snapshot[keyPath: keyPath] = newValue
            AppLifecycleReminderPreferences.set(snapshot)
        }
    }
}
