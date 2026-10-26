import AppKit
import SwiftUI

/// CleanMyMac `ApplicationsTerminator`: “Some applications should be quit.”
/// with Quit / Force Quit / Ignore per app, Quit All and Ignore and Continue.
struct ApplicationTerminatorSheet: View {
    @ObservedObject var model: ApplicationsManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "xmark.app")
                    .font(.system(size: 30))
                    .foregroundStyle(FeatureLightfieldPalette.accent(.uninstall))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("一些应用程序应该退出。", "Some applications should be quit."))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.text("请退出以下应用程序，以清理所有与之相关的项目：",
                                   "Please quit the following applications to clean all of their related items:"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(model.runningApplications) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable().interpolation(.high).frame(width: 26, height: 26)
                        Text(app.title).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        switch app.state {
                        case .running:
                            Button(L10n.text("忽略", "Ignore")) { model.ignoreRunning(app.id) }
                            Button(L10n.text("关闭", "Quit")) { model.quit(app.id, force: false) }
                        case .quitting:
                            ProgressView().controlSize(.small)
                        case .quit:
                            Label(L10n.text("已退出", "Quit"), systemImage: "checkmark.circle.fill").foregroundStyle(AppDesignTokens.Palette.success)
                        case .cannotQuit:
                            Text(L10n.text("无法退出", "Can't be quit")).foregroundStyle(.secondary)
                            Button(L10n.text("强制退出", "Force Quit")) { model.quit(app.id, force: true) }
                            Button(L10n.text("忽略", "Ignore")) { model.ignoreRunning(app.id) }
                        case .ignored:
                            Text(L10n.text("已忽略", "Ignored")).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 8)
                    .animation(.easeInOut(duration: 0.2), value: app.state)
                    Divider()
                }
            }
            HStack {
                Button(L10n.text("取消", "Cancel")) { model.cancelTermination() }
                    .keyboardShortcut(.cancelAction)
                    .appButtonChrome(.secondary)
                Spacer()
                Button(L10n.text("忽略并继续", "Ignore and Continue")) { model.ignoreAllAndContinue() }
                    .appButtonChrome(.secondary)
                Button(L10n.text("全部退出", "Quit All")) { model.quitAll() }
                    .keyboardShortcut(.defaultAction)
                    .appButtonChrome(.primary)
            }
            Text(L10n.text("忽略的应用不会被移除，它的项目保留原处。", "An ignored app is not removed; its items stay where they are."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// “Uninstalling applications...” / “Removing leftovers...”.
struct ApplicationsRemovalProgressView: View {
    let current: String
    let index: Int
    let total: Int
    let leftovers: Bool
    @State private var spin = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(FeatureLightfieldPalette.accent(.uninstall).opacity(0.18), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: total > 0 ? CGFloat(index) / CGFloat(total) : 0)
                    .stroke(FeatureLightfieldPalette.accent(.uninstall), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: index)
                Image(systemName: leftovers ? "sparkles" : "trash")
                    .font(.system(size: 26))
                    .foregroundStyle(FeatureLightfieldPalette.accent(.uninstall))
                    .symbolEffect(.pulse, isActive: true)
            }
            .frame(width: 84, height: 84)
            Text(leftovers ? L10n.text("正在删除残留文件...", "Removing leftovers...")
                           : L10n.text("正在卸载应用程序...", "Uninstalling applications..."))
                .font(.system(size: 16, weight: .semibold))
            Text(L10n.text("\(index + 1) / \(total) · \(current)", "\(index + 1) of \(total) · \(current)"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// CleanMyMac's completion screen: “Job done!” / “Cleanup complete!” or
/// “Removal failed...”, with Manage More Items and the log.
struct ApplicationsCompletionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ApplicationsManagerModel
    let showLog: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: model.completionSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 54))
                .foregroundStyle(model.completionSucceeded ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning)
                .scaleEffect(appeared ? 1 : 0.4)
                .opacity(appeared ? 1 : 0)
            Text(model.completionTitle)
                .font(.system(size: 22, weight: .bold))
            Text(model.completionDescription)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button(L10n.text("应用程序日志", "Applications Log"), action: showLog)
                    .appButtonChrome(.secondary)
                Button(L10n.text("管理更多项目", "Manage More Items")) { model.returnToBrowsing() }
                    .appButtonChrome(.primary)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let animation = FeatureLightfieldMotion.checkAnimation(reduceMotion: reduceMotion) {
                withAnimation(animation) { appeared = true }
            } else {
                appeared = true
            }
            if model.completionSucceeded, model.outcomes.contains(where: { $0.removedCount > 0 }) {
                AppLifecycleSounds.playEmptyTrash()
            }
        }
    }
}

/// CleanMyMac “Applications Log”: what moved, what stayed and why.
struct ApplicationsLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let outcomes: [ApplicationRemovalOutcome]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("应用程序日志", "Applications Log")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L10n.text("拷贝", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button(L10n.text("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(outcomes) { outcome in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outcome.title).font(.system(size: 13, weight: .semibold))
                            ForEach(outcome.log) { line in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: symbol(line.status)).foregroundStyle(color(line.status))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(line.path).font(.system(size: 11)).textSelection(.enabled)
                                        if let note = note(line.status) {
                                            Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: 620, height: 440)
    }

    private var text: String {
        outcomes.map { outcome in
            ([outcome.title] + outcome.log.map { line in
                "  " + line.path + (note(line.status).map { " — " + $0 } ?? "")
            }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func symbol(_ status: ApplicationRemovalOutcome.LogLine.Status) -> String {
        switch status {
        case .removed: "checkmark.circle.fill"
        case .kept: "minus.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func color(_ status: ApplicationRemovalOutcome.LogLine.Status) -> Color {
        switch status {
        case .removed: AppDesignTokens.Palette.success
        case .kept: .secondary
        case .failed: AppDesignTokens.Palette.warning
        }
    }

    private func note(_ status: ApplicationRemovalOutcome.LogLine.Status) -> String? {
        switch status {
        case .removed: nil
        case .kept(let reason), .failed(let reason): reason
        }
    }
}
