import SwiftUI

struct AppInstallationConflictBanner: View {
    let conflict: AppInstallationConflict
    let revealCopies: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.compact) {
                Text(L10n.text("检测到两个安装副本", "Two Installed Copies Detected"))
                    .font(.headline)

                Text(
                    L10n.text(
                        "请先核对版本；确认新版后只保留一个副本，并从该副本重新固定 Dock 图标。",
                        "Compare the versions first; keep only the newer copy, then pin that copy to the Dock again."
                    )
                )
                .font(AppTypography.body)

                copyLine(conflict.canonicalCopy)
                copyLine(conflict.legacyCopy)

                Text(
                    L10n.text(
                        "当前运行：\(conflict.currentRuntimePath)",
                        "Currently running: \(conflict.currentRuntimePath)"
                    )
                )
                .font(AppTypography.monospaced)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(conflict.currentRuntimePath)
            }

            Spacer(minLength: AppDesignTokens.Spacing.medium)

            AppButton(
                title: L10n.text("在访达中显示", "Show in Finder"),
                systemImage: "folder",
                kind: .secondary,
                action: revealCopies
            )

            AppButton(
                title: L10n.text("知道了", "Got It"),
                kind: .primary,
                action: dismiss
            )
        }
        .padding(.horizontal, AppDesignTokens.Spacing.large)
        .padding(.vertical, AppDesignTokens.Spacing.small)
        .background(AppDesignTokens.Palette.secondaryBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppDesignTokens.Palette.warning.opacity(0.45))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func copyLine(_ copy: InstalledAppCopy) -> some View {
        Text("\(copy.url.path) · \(copy.versionDisplay)")
            .font(AppTypography.monospaced)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help("\(copy.url.path) · \(copy.versionDisplay)")
    }
}
