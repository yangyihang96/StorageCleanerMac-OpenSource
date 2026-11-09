import SwiftUI

/// D272: one status and one action on each row (was 前往授权 and 重新检查 on every
/// row, the second wrapping onto two lines). The section offers one 重新检查.
struct SettingsPermissionRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let detail: String
    let status: String
    let statusKind: MetadataPillStatus
    let open: () -> Void
    var isGranted = false
    /// Notifications can be asked for from here, before System Settings is needed.
    var request: (title: String, isDisabled: Bool, action: () -> Void)? = nil

    var body: some View {
        SettingsRow(title: title, caption: detail) {
            HStack(spacing: 16) {
                state
                if !isGranted { actions }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .lightfieldComponentProbe("settings.access." + title)
    }

    private var state: some View {
        HStack(spacing: 6) {
            if isGranted {
                LightfieldStatusGlyph(status: .none, symbol: "checkmark.circle.fill", color: AppDesignTokens.Palette.success)
                    .accessibilityHidden(true)
            } else {
                LightfieldStatusGlyph(status: statusKind)
            }
            Text(status).font(.system(size: 13))
                .foregroundStyle(isGranted ? AppDesignTokens.Palette.success : statusKind.lightfieldColor(FeatureLightfieldPalette.resolve(scheme)))
                .fixedSize()
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        if let request {
            SettingsLinkButton(title: request.title, action: request.action)
                .disabled(request.isDisabled)
                .accessibilityLabel(title + " · " + request.title)
        }
        SettingsLinkButton(title: L10n.text("前往授权", "Open Settings"), action: open)
            .accessibilityLabel(title + " · " + L10n.text("前往授权", "Open Settings"))
    }
}
