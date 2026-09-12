import SwiftUI

struct CleanupOperationOverlay: View {
    @ObservedObject var store: ScanStore
    let snapshot: CleanupOperationSnapshot

    private var tint: Color {
        snapshot.failedCount > 0
            ? AppDesignTokens.Palette.warning
            : AppDesignTokens.Palette.success
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: AppDesignTokens.Spacing.large) {
                statusVisual

                VStack(spacing: AppDesignTokens.Spacing.small) {
                    Text(statusTitle)
                        .font(AppDesignTokens.Typography.sheetTitle)
                        .multilineTextAlignment(.center)

                    Text(statusDetail)
                        .font(AppDesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if snapshot.isComplete {
                    completionMetrics
                    completionActions
                } else {
                    Text(
                        L10n.text(
                            "正在使用 macOS 废纸篓；完成前请保持应用打开。",
                            "Using macOS Trash; keep the app open until this finishes."
                        )
                    )
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(width: 500, alignment: .center)
            .glassPanel(
                cornerRadius: AppDesignTokens.Layout.heroRadius,
                tint: tint,
                elevated: true
            )
            .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var statusVisual: some View {
        AppStateIconRing(
            systemImage: snapshot.isComplete
                ? (snapshot.failedCount > 0 ? "exclamationmark" : "checkmark")
                : "trash",
            tint: tint,
            isActive: !snapshot.isComplete
        )
    }

    private var statusTitle: String {
        if !snapshot.isComplete {
            return L10n.text("正在移入废纸篓", "Moving to Trash")
        }
        if snapshot.failedCount > 0 {
            return L10n.text("清理已完成，部分项目未处理", "Cleanup Finished with Some Items Skipped")
        }
        return L10n.text("清理完成", "Cleanup Complete")
    }

    private var statusDetail: String {
        if !snapshot.isComplete {
            return L10n.text(
                "正在处理 \(snapshot.requestedCount) 项，共 \(ByteFormat.string(snapshot.requestedBytes))。",
                "Processing \(L10n.items(snapshot.requestedCount)), \(ByteFormat.string(snapshot.requestedBytes)) total."
            )
        }
        return L10n.text(
            "\(snapshot.movedCount) 项已移入废纸篓；清空废纸篓后才会真正释放空间。",
            "\(L10n.items(snapshot.movedCount)) moved to Trash; space is freed only after Trash is emptied."
        )
    }

    private var completionMetrics: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            completionMetric(
                title: L10n.text("已移动", "Moved"),
                value: L10n.items(snapshot.movedCount),
                systemImage: "checkmark.circle.fill"
            )
            completionMetric(
                title: L10n.text("处理容量", "Processed"),
                value: ByteFormat.string(snapshot.movedBytes),
                systemImage: "externaldrive.fill"
            )
            completionMetric(
                title: L10n.text("耗时", "Duration"),
                value: L10n.scanSeconds(snapshot.duration ?? 0),
                systemImage: "clock.fill"
            )
        }
    }

    private func completionMetric(title: String, value: String, systemImage: String) -> some View {
        VStack(spacing: AppDesignTokens.Spacing.compact) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
            Text(title)
                .font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.rowRadius,
            tint: tint,
            prominence: .quiet
        )
    }

    private var completionActions: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            if store.canRestoreLatestCleanup, snapshot.movedCount > 0 {
                Button {
                    store.dismissCleanupOperationSummary()
                    store.requestRestoreLatestCleanup()
                } label: {
                    Label(L10n.text("撤销", "Undo"), systemImage: "arrow.uturn.backward")
                }
                .appButtonChrome(.secondary)
                .controlSize(.large)
            }

            Button {
                store.dismissCleanupOperationSummary()
                store.openTrashFolder()
            } label: {
                Label(L10n.text("查看废纸篓", "Review Trash"), systemImage: "trash")
            }
            .appButtonChrome(.secondary)
            .controlSize(.large)

            Button {
                store.dismissCleanupOperationSummary()
            } label: {
                Text(L10n.text("完成", "Done"))
                    .frame(minWidth: 84)
            }
            .appButtonChrome(.primary)
            .controlSize(.large)
            .tint(tint)
            .keyboardShortcut(.defaultAction)
        }
    }
}
