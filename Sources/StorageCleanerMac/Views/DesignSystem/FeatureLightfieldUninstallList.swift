import SwiftUI

/// The list renderer takes values and a singular selection. Clicking a row or
/// moving with the arrow keys only selects; it never opens the preview or
/// moves anything. Application movement, ownership evidence and recovery stay
/// in the existing preview, opened by the page's primary action or the
/// context menu.
struct FeatureLightfieldUninstallList: View {
    let apps: [InstalledAppItem]
    let selectedID: String?
    let select: (InstalledAppItem) -> Void
    let review: (InstalledAppItem) -> Void
    var copyPath: ((InstalledAppItem) -> Void)? = nil
    var reveal: ((InstalledAppItem) -> Void)? = nil
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                Button { select(app) } label: {
                    LightfieldListRow(kind: .uninstall, probeID: "lightfield.uninstall.item.\(index)") {
                        HStack(spacing: 16) {
                            FeatureLightfieldCheck(selected: app.id == selectedID, module: .uninstall)
                            LightfieldAppIcon(path: app.path, size: .medium)
                                .lightfieldComponentProbe("lightfield.uninstall.item.\(index).icon")
                        }
                    } name: {
                        LightfieldApplicationName(title: app.name, version: app.versionDisplay,
                            probeID: "lightfield.uninstall.item.\(index)")
                    } detail: {
                        LightfieldPathText(path: app.path)
                            .lightfieldComponentProbe("lightfield.uninstall.item.\(index).path")
                    } trailing: {
                        Text(ByteFormat.storageString(app.sizeBytes)).font(.system(size: 15)).monospacedDigit()
                            .lineLimit(1).truncationMode(.middle).help(ByteFormat.storageString(app.sizeBytes))
                            .lightfieldComponentProbe("lightfield.value." + app.name)
                    }
                }.buttonStyle(FeatureLightfieldRowButtonStyle())
                .accessibilityLabel(app.name + " · " + app.path + " · " + ByteFormat.storageString(app.sizeBytes))
                .accessibilityValue(app.id == selectedID ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not selected"))
                .accessibilityHint(L10n.text("版本 \(app.versionDisplay) · 主按钮打开卸载预览", "Version \(app.versionDisplay) · The primary button opens the uninstall preview"))
                .contextMenu {
                    Button(L10n.text("查看卸载预览", "Review Uninstall")) { review(app) }
                    if let copyPath { Button(L10n.text("复制路径", "Copy Path")) { copyPath(app) } }
                    if let reveal { Button(L10n.text("在访达中显示", "Show in Finder")) { reveal(app) } }
                }
                .id(app.id)
                .lightfieldRowEntrance(index)
#if DEBUG
                .layoutProbe("lightfield.uninstall.row.\(index)")
#endif
            }
        }
        .focusable()
        .onMoveCommand { direction in
            guard !apps.isEmpty else { return }
            let current = apps.firstIndex { $0.id == selectedID }
            switch direction {
            case .up: select(apps[max(0, (current ?? apps.count) - 1)])
            case .down: select(apps[min(apps.count - 1, (current ?? -1) + 1)])
            default: break
            }
        }
    }
}
