import AppKit
import SwiftUI

/// The reminder card. The look is this app's own, after CleanMyMac's alert.
/// D224: so is the wording — the trashed-app and Trash-size cards had taken
/// CleanMyMac's strings word for word (`TrashedApps_Issue_*`,
/// `TrashSize_Issue_*`, `Monitor_…_FreeingUp`); the D219 scan and D220
/// free-space cards were written here.
struct AppLifecycleAlertCard: View {
    @ObservedObject var center: AppLifecycleReminderCenter
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let alert = center.presentedAlert {
                header(for: alert)
                content(for: alert)
                if showsFooter {
                    Divider().opacity(0.6)
                    footer(for: alert)
                }
            }
        }
        .padding(16)
        .frame(width: AppLifecycleAlertPanelController.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        // The panel never activates the app, so it is rarely the key window;
        // its buttons keep their active look all the same.
        .environment(\.controlActiveState, .key)
    }

    /// The Empty Trash steps carry their own buttons, or none while running.
    private var showsFooter: Bool {
        switch center.emptyTrashPhase {
        case .confirming, .emptying, .finished: false
        case .idle, .freezing, .failed: true
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(for alert: AppLifecycleReminderCenter.Alert) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SonarRippleIcon(tint: tint(for: alert), active: center.emptyTrashPhase == .idle) {
                headerIcon(for: alert)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title(for: alert))
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(description(for: alert))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func headerIcon(for alert: AppLifecycleReminderCenter.Alert) -> some View {
        switch alert {
        case .trashedApplications(let apps):
            if let first = apps.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.url.path))
                    .resizable().interpolation(.high)
                    .frame(width: 36, height: 36)
            }
        case .trashSize:
            TrashCanGlyph(phase: center.emptyTrashPhase)
                .frame(width: 36, height: 36)
        case .lowDiskSpace:
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.red)
                .frame(width: 36, height: 36)
        case .scanDue:
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
        }
    }

    private func tint(for alert: AppLifecycleReminderCenter.Alert) -> Color {
        switch alert {
        case .trashedApplications, .scanDue: .accentColor
        case .trashSize: .orange
        case .lowDiskSpace: .red
        }
    }

    private func title(for alert: AppLifecycleReminderCenter.Alert) -> String {
        switch alert {
        case .trashedApplications:
            L10n.text("卸载还差一步", "Finish the Uninstall")
        case .trashSize:
            L10n.text("废纸篓占了不少空间", "The Trash Is Taking Up Space")
        case .lowDiskSpace:
            L10n.text("启动磁盘的可用空间不多了", "Your startup disk is running low on space")
        case .scanDue(let lastScanAt, _):
            Self.scanDueTitle(since: lastScanAt)
        }
    }

    /// D219: the time since the last scan, in the largest whole unit.
    static func scanDueTitle(since lastScanAt: Date, now: Date = Date()) -> String {
        let days = max(0, Int(now.timeIntervalSince(lastScanAt) / 86_400))
        switch days {
        case ..<7:
            return L10n.text("已经 \(days) 天没有扫描了", "It’s been \(days) days since your last scan")
        case ..<14:
            return L10n.text("已经一周没有扫描了", "It’s been a week since your last scan")
        case ..<30:
            return L10n.text("已经 \(days / 7) 周没有扫描了", "It’s been \(days / 7) weeks since your last scan")
        case ..<60:
            return L10n.text("已经一个月没有扫描了", "It’s been a month since your last scan")
        default:
            return L10n.text("已经 \(days / 30) 个月没有扫描了", "It’s been \(days / 30) months since your last scan")
        }
    }

    private func description(for alert: AppLifecycleReminderCenter.Alert) -> String {
        switch alert {
        case .trashedApplications:
            return L10n.text("放进废纸篓的应用还留着设置、缓存等文件，可以一并找出来移除。",
                             "Apps in the Trash still leave settings, caches and other files behind; find and remove them too.")
        case .trashSize(_, let threshold, _):
            let limit = AppLifecycleReminderPreferences.thresholdTitle(threshold)
            return L10n.text("废纸篓里的文件已超过你设的 \(limit)；清倒后才会真正腾出这些空间。",
                             "Files in the Trash are over the \(limit) you set; the space comes back once the Trash is emptied.")
        case .lowDiskSpace(_, let threshold):
            let limit = AppLifecycleReminderPreferences.thresholdTitle(threshold)
            return L10n.text("可用空间已低于您设置的 \(limit)。打开“垃圾清理”，看看哪些可以清理。",
                             "Free space is below the \(limit) you set. Open Junk Cleanup to see what can go.")
        case .scanDue:
            return L10n.text("定期扫描能及早发现新的垃圾和问题。扫描只读取，不会删除任何文件。",
                             "Regular scans catch new junk and issues early. Scanning only reads; nothing is removed.")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(for alert: AppLifecycleReminderCenter.Alert) -> some View {
        switch alert {
        case .trashedApplications(let apps):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(apps.prefix(4)) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable().interpolation(.high)
                            .frame(width: 20, height: 20)
                        Text(app.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if !app.version.isEmpty {
                            Text(app.version)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if apps.count > 4 {
                    Text(L10n.text("另有 \(apps.count - 4) 个应用", "\(apps.count - 4) more"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: apps.map(\.id))
        case .trashSize(let bytes, _, let count):
            trashSizeContent(bytes: bytes, count: count)
        case .lowDiskSpace(let space, _):
            lowDiskSpaceContent(space)
        case .scanDue(let lastScanAt, let cadence):
            VStack(alignment: .leading, spacing: 6) {
                detailRow(L10n.text("上次扫描", "Last Scan"),
                          value: lastScanAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
                detailRow(L10n.text("提醒频率", "Reminder Frequency"), value: cadence.title)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    /// D220: how full the disk is, with the free space as other pages show it.
    private func lowDiskSpaceContent(_ space: AppLifecycleReminderCenter.StartupDiskSpace) -> some View {
        let used = space.totalBytes > 0
            ? min(1, max(0, Double(space.totalBytes - space.availableBytes) / Double(space.totalBytes)))
            : 1
        let total = ByteFormat.storageString(space.totalBytes)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(space.volumeName ?? L10n.text("启动磁盘", "Startup Disk"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                (Text(L10n.text("可用 ", "")) + Text(ByteFormat.storageString(space.availableBytes)).bold()
                    + Text(L10n.text(" / 共 \(total)", " free of \(total)")))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            ProgressView(value: used)
                .progressViewStyle(.linear)
                .tint(.red)
                .accessibilityLabel(L10n.text("已用 \(Int((used * 100).rounded()))%", "\(Int((used * 100).rounded()))% used"))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func trashSizeContent(bytes: Int64, count: Int) -> some View {
        switch center.emptyTrashPhase {
        case .idle, .freezing:
            HStack(spacing: 8) {
                Text(L10n.text("废纸篓", "Trash"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                (Text(L10n.text("\(ByteFormat.count(count)) 项 · ", "\(L10n.items(count)) · ")) + Text(ByteFormat.storageString(bytes)).bold())
                    .font(.system(size: 12))
                    .monospacedDigit()
                Button {
                    center.openTrash()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("在访达中打开废纸篓", "Open the Trash in Finder"))
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .confirming(let frozen):
            EmptyTrashInlineConfirmation(center: center, frozen: frozen)
        case .emptying(let items, let total):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("正在清倒…", "Emptying…"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(L10n.text("\(ByteFormat.count(items)) 项 · \(ByteFormat.storageString(total))", "\(L10n.items(items)) · \(ByteFormat.storageString(total))"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView()
                    .progressViewStyle(.linear)
            }
        case .finished(let result):
            EmptyTrashFinishedRow(result: result)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(for alert: AppLifecycleReminderCenter.Alert) -> some View {
        switch center.emptyTrashPhase {
        case .confirming, .emptying, .finished:
            EmptyView()
        case .failed:
            HStack {
                Spacer()
                Button(L10n.text("好", "OK")) { center.acknowledgeEmptyTrashFailure() }
                    .keyboardShortcut(.defaultAction)
            }
        case .idle, .freezing:
            HStack(spacing: 10) {
                Menu {
                    ForEach(AppLifecycleIgnoreOption.menuOptions) { option in
                        Button(option.title) { center.ignore(option) }
                    }
                } label: {
                    Text(AppLifecycleIgnoreOption.ignore.title)
                } primaryAction: {
                    center.ignore(.ignore)
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help(L10n.text("忽略一周；点箭头选择其他时长", "Ignore for a week; use the arrow for other durations"))
                Spacer()
                switch alert {
                case .trashedApplications:
                    Button(L10n.text("查看残留…", "Review Leftovers…")) { center.uninstallTrashedApplications() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                case .trashSize:
                    Button(L10n.text("清倒废纸篓", "Empty Trash")) { center.requestEmptyTrash() }
                        .buttonStyle(.borderedProminent)
                        .disabled(center.emptyTrashPhase == .freezing)
                case .lowDiskSpace:
                    Button(L10n.text("打开垃圾清理", "Open Junk Cleanup")) { center.openJunkCleanup() }
                        .buttonStyle(.borderedProminent)
                        .help(L10n.text("只打开“垃圾清理”，不会自动扫描或清理", "Opens Junk Cleanup only; nothing is scanned or cleaned"))
                case .scanDue:
                    Button(L10n.text("现在扫描", "Scan Now")) { center.scanNow() }
                        .buttonStyle(.borderedProminent)
                        .help(L10n.text("打开“智能扫描”并开始只读扫描，不会清理", "Opens Smart Scan and starts a read-only scan; nothing is cleaned"))
                }
            }
            .controlSize(.regular)
        }
    }
}

/// D23 inside the card: the frozen list's count and size, and both
/// acknowledgements, before anything is deleted. Return never deletes.
private struct EmptyTrashInlineConfirmation: View {
    @ObservedObject var center: AppLifecycleReminderCenter
    let frozen: FrozenTrash
    @State private var permanent = false
    @State private var reviewed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("清倒 \(ByteFormat.count(frozen.entries.count)) 项 · \(ByteFormat.storageString(frozen.summary.totalBytes)) · 不可恢复",
                            "Empty \(L10n.items(frozen.entries.count)) · \(ByteFormat.storageString(frozen.summary.totalBytes)) · Cannot be undone"),
                  systemImage: "trash.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            Text(L10n.text("只删除现在废纸篓里的这些项目；之后放进去的会保留。其中如有早先清理移入的文件，之后也无法再从“操作记录”恢复。",
                           "Only the items in the Trash now are deleted; anything put there afterwards stays. Files an earlier cleanup moved there can no longer be restored from Operation History."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.text("我了解这些项目会被永久删除，无法恢复", "I understand these items will be permanently deleted"), isOn: $permanent)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Toggle(L10n.text("我已确认废纸篓里没有需要保留的文件", "I confirmed the Trash holds nothing I need to keep"), isOn: $reviewed)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            HStack {
                Button(L10n.text("取消", "Cancel")) { center.cancelEmptyTrash() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    center.confirmEmptyTrash(acknowledgesPermanentDeletion: permanent,
                                             acknowledgesTrashContentsReviewed: reviewed)
                } label: {
                    Label(L10n.text("永久删除", "Permanently Delete"), systemImage: "trash.slash")
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .disabled(!permanent || !reviewed)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The finished state: a check that pops in and the freed size counting up.
private struct EmptyTrashFinishedRow: View {
    let result: FrozenTrashEmptyResult
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(result.failedCount == 0 ? Color.green : Color.orange)
                .scaleEffect(appeared ? 1 : 0.3)
                .opacity(appeared ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                CountingBytesText(target: result.deletedBytes, prefix: L10n.text("已释放 ", "Freed "))
                    .font(.system(size: 13, weight: .semibold))
                if result.skippedCount + result.failedCount > 0 {
                    Text(L10n.text("\(result.skippedCount + result.failedCount) 项未删除，仍在废纸篓", "\(result.skippedCount + result.failedCount) item(s) were kept in the Trash"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { appeared = true }
        }
    }
}

/// Counts from zero to the freed size, as the completion number does in
/// CleanMyMac's cleanup screens.
private struct CountingBytesText: View {
    let target: Int64
    let prefix: String
    @State private var shown: Int64 = 0

    var body: some View {
        Text(prefix + ByteFormat.storageString(shown))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(shown)))
            .onAppear {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { shown = target; return }
                withAnimation(.easeOut(duration: 0.8)) { shown = target }
            }
    }
}

/// A trash can whose lid lifts while the Trash is emptied and that bounces
/// once when it is done.
private struct TrashCanGlyph: View {
    let phase: AppLifecycleReminderCenter.EmptyTrashPhase

    private var isEmptying: Bool {
        if case .emptying = phase { return true }
        return false
    }

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    var body: some View {
        Image(systemName: isFinished ? "trash" : "trash.fill")
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(.orange)
            .symbolEffect(.pulse, isActive: isEmptying)
            .symbolEffect(.bounce, value: isFinished)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// CleanMyMac's `AnimatedSonarView`: rings spread out from the icon a few
/// times when the card appears, to draw the eye without staying busy.
struct SonarRippleIcon<Content: View>: View {
    let tint: Color
    let active: Bool
    @ViewBuilder let content: () -> Content
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                ForEach(0..<2, id: \.self) { ring in
                    Circle()
                        .stroke(tint.opacity(0.55), lineWidth: 1.5)
                        .scaleEffect(pulse ? 1.6 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                        .animation(
                            .easeOut(duration: 1.6)
                                .repeatCount(3, autoreverses: false)
                                .delay(Double(ring) * 0.45),
                            value: pulse
                        )
                }
            }
            content()
        }
        .frame(width: 44, height: 44)
        .onAppear { pulse = true }
    }
}
