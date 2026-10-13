import SwiftUI

/// B2 list primitive extended for application identity columns. Values and
/// callbacks are supplied by the page; no inventory or operation lives here.
struct LightfieldApplicationColumns: Layout {
    enum Kind: Equatable { case uninstall, updater }
    let kind: Kind
    var rowHeight = FeatureLightfield.rowHeight

    func widths(for width: CGFloat) -> [CGFloat] {
        let leading: CGFloat = kind == .uninstall ? 60 : 24
        let available = max(0, width - leading - 48 - 6)
        if kind == .uninstall {
            let number = min(width < 520 ? 72 : 96, available * 0.3)
            let remaining = max(0, available - number)
            return [leading, remaining * 1.2 / 3.2, remaining * 2 / 3.2, number]
        }
        let status = min(146, available * 0.28)
        let versions = min(274, available * 0.53)
        return [leading, max(0, available - status - versions), versions, status]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 520, height: rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (index, width) in widths(for: bounds.width).enumerated() where index < subviews.count {
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + 16
        }
    }
}

struct LightfieldListRow<Leading: View, Name: View, Detail: View, Trailing: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.featureLightfieldReportsRowTops) private var reportsRowTops
    let kind: LightfieldApplicationColumns.Kind
    let probeID: String
    @ViewBuilder let leading: Leading
    @ViewBuilder let name: Name
    @ViewBuilder let detail: Detail
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        LightfieldApplicationColumns(kind: kind) {
            leading.frame(maxWidth: .infinity, alignment: .leading).clipped()
                .lightfieldComponentProbe(probeID + ".leading")
            name.frame(maxWidth: .infinity, alignment: .leading).clipped()
                .lightfieldComponentProbe(probeID + ".nameColumn")
            detail.frame(maxWidth: .infinity, alignment: .leading).clipped()
                .lightfieldComponentProbe(probeID + ".detailColumn")
            trailing.frame(maxWidth: .infinity, alignment: .trailing).clipped()
                .lightfieldComponentProbe(probeID + ".trailingColumn")
        }
        .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
        .frame(height: FeatureLightfield.rowHeight).contentShape(Rectangle())
        .background(hovering ? FeatureLightfieldPalette.resolve(scheme).hoverColor : .clear)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .onHover { hovering = $0 }
        .background {
            if reportsRowTops {
                GeometryReader { row in
                    Color.clear.preference(key: FeatureLightfieldRowTopKey.self,
                        value: [row.frame(in: .named(FeatureLightfield.resultsDocumentSpace)).minY])
                }
            }
        }
        .lightfieldComponentProbe(probeID)
    }
}

struct LightfieldApplicationName: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var version: String? = nil
    let probeID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail).help(title)
                .lightfieldComponentProbe(probeID + ".name")
            if let version {
                Text(version).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                    .lineLimit(1).truncationMode(.middle).help(version)
                    .lightfieldComponentProbe(probeID + ".version")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Headers share the row's columns, so resizing cannot move the path/version
/// heading into another column. They have no interactive or decorative glyphs.
struct LightfieldApplicationListHeader: View {
    @Environment(\.colorScheme) private var scheme
    let kind: LightfieldApplicationColumns.Kind
    private var probeID: String { "lightfield." + (kind == .uninstall ? "uninstall" : "updater") + ".header" }
    var body: some View {
        LightfieldApplicationColumns(kind: kind, rowHeight: 28) {
            Color.clear.lightfieldComponentProbe(probeID + ".leading")
            Text(kind == .uninstall ? L10n.text("应用 / 版本", "App / Version") : L10n.text("有更新的应用", "Apps with Updates"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lightfieldComponentProbe(probeID + ".nameColumn")
            Text(kind == .uninstall ? L10n.text("应用路径", "Application Path") : L10n.text("当前 → 新版本", "Current → New Version"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lightfieldComponentProbe(probeID + ".detailColumn")
            Text(kind == .uninstall ? L10n.text("可审阅大小", "Size to Review") : L10n.text("处理方式", "Handling"))
                .frame(maxWidth: .infinity, alignment: kind == .uninstall ? .trailing : .leading)
                .lightfieldComponentProbe(probeID + ".trailingColumn")
        }
        .font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
        .lineLimit(1).truncationMode(.tail)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .accessibilityHidden(true)
        .lightfieldComponentProbe(probeID)
    }
}
