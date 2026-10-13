import SwiftUI

struct SettingsPermissionRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let detail: String
    let status: String
    let statusKind: MetadataPillStatus
    let open: () -> Void
    let refresh: () -> Void
    var isChecking = false
    var isGranted = false

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title).frame(width: 116, alignment: .leading)
                Text(detail).foregroundStyle(palette.fg2).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                state.frame(width: 194, alignment: .leading)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                Text(detail).font(.system(size: 13)).foregroundStyle(palette.fg2)
                state
                HStack(spacing: 12) { actions }
            }.padding(.vertical, 12)
        }
        .font(.system(size: 15))
        .frame(maxWidth: .infinity, minHeight: FeatureLightfield.rowHeight, alignment: .leading)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .lightfieldComponentProbe("settings.access." + title)
    }

    private var state: some View {
        HStack(spacing: 8) {
            if isGranted {
                FeatureLightfieldCheck(selected: true, module: .green).accessibilityHidden(true)
            } else {
                LightfieldStatusGlyph(status: statusKind)
            }
            Text(status).font(.system(size: 13))
                .foregroundStyle(isGranted ? FeatureLightfieldPalette.accent(.green) : statusKind.lightfieldColor(FeatureLightfieldPalette.resolve(scheme)))
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        Button(L10n.text("前往授权", "Open Settings"), action: open)
            .frame(width: 64).buttonStyle(FeatureLightfieldRowButtonStyle())
            .accessibilityLabel(title + " · " + L10n.text("前往授权", "Open Settings"))
        Button(L10n.text("重新检查", "Check Again"), action: refresh)
            .frame(width: 56).buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isChecking)
            .accessibilityLabel(title + " · " + L10n.text("重新检查", "Check Again"))
    }
}
