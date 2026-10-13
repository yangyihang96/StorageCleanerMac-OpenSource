import SwiftUI

/// B7 composes the B2 summary in the existing bounded result viewport.
/// Short windows scroll the summary and body together; the page pins the CTA.
struct LightfieldFileResults<Content: View>: View {
    let summary: LightfieldSummary
    var minimumBodyHeight: CGFloat = 299
    var compactBodyHeight: CGFloat? = nil
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { proxy in
            let minimum = proxy.size.width < 700 ? (compactBodyHeight ?? minimumBodyHeight) : minimumBodyHeight
            if proxy.size.height < FeatureLightfield.summaryHeight + 20 + minimum {
                FeatureOptionsScrollView(probePrefix: "lightfield.files.compact", balancesContent: false,
                    usesLightfield: true, fadesResults: true) {
                    VStack(spacing: 20) {
                        summary
                        content.frame(height: minimum).lightfieldComponentProbe("lightfield.files.body")
                    }
                }
            } else {
                VStack(spacing: 20) {
                    summary
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .lightfieldComponentProbe("lightfield.files.body")
                }
            }
        }
    }
}

struct LightfieldSelectionCheck: View {
    let state: TriStateSelection
    let module: ReviewFilter
    var body: some View {
        FeatureLightfieldCheck(selected: state == .checked, module: module)
            .overlay {
                if state == .mixed {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(FeatureLightfieldPalette.accent(module), lineWidth: 1.5)
                    Rectangle().fill(FeatureLightfieldPalette.accent(module)).frame(width: 10, height: 2)
                }
            }
    }
    static func state(ids: Set<String>, selected: Set<String>) -> TriStateSelection {
        let count = ids.intersection(selected).count
        return count == 0 ? .unchecked : count == ids.count ? .checked : .mixed
    }
    static func value(_ state: TriStateSelection) -> String {
        switch state {
        case .unchecked: L10n.text("未选", "Not selected")
        case .checked: L10n.text("已选", "Selected")
        case .mixed: L10n.text("部分已选", "Partially selected")
        }
    }
}

struct LightfieldFileGroupHeader: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let title: String
    let metadata: String
    let icon: LightfieldOptionIcon
    let module: ReviewFilter
    var selection: TriStateSelection? = nil
    var selectionEnabled = true
    var onSelect: () -> Void = {}
    @Binding var expanded: Bool
    var height: CGFloat = 38
    var probeID = "lightfield.files.group"
    var body: some View {
        HStack(spacing: 16) {
            if let selection {
                Button(action: onSelect) { LightfieldSelectionCheck(state: selection, module: module) }
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(!selectionEnabled)
                    .accessibilityLabel(L10n.text("选择组：", "Select group: ") + title)
                    .accessibilityValue(LightfieldSelectionCheck.value(selection))
                    .lightfieldComponentProbe(probeID + ".select")
            }
            Button {
                withAnimation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check,
                    reduceMotion: reduceMotion || disablesAnimations)) { expanded.toggle() }
            } label: {
                HStack(spacing: 16) {
                    LightfieldOptionIconView(icon: icon).scaleEffect(24 / LightfieldOptionIcon.pointSize)
                        .frame(width: 24, height: 24)
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(metadata).font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
                        .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                    FeatureLightfieldDisclosureChevron(expanded: expanded)
                }.contentShape(Rectangle())
            }.buttonStyle(FeatureLightfieldRowButtonStyle())
                .accessibilityLabel(title).accessibilityHint(metadata)
                .accessibilityValue(expanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
            .frame(height: height).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .lightfieldComponentProbe(probeID)
    }
}

/// Six columns including a reserved action slot. Paths yield before actions.
struct LightfieldMigrationColumns: Layout {
    static func widths(_ width: CGFloat) -> (columns: [CGFloat], gap: CGFloat) {
        let compact = width < 760
        let gap: CGFloat = compact ? 8 : 16
        let date: CGFloat = compact ? 76 : 116
        let size: CGFloat = compact ? 60 : 88
        let action: CGFloat = compact ? 52 : 88
        let name = max(1, width - 20 - 24 - date - size - action - gap * 5)
        return ([20, 24, name, date, size, action], gap)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        .init(width: proposal.width ?? 878, height: FeatureLightfield.rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = Self.widths(bounds.width)
        var x = bounds.minX
        for index in subviews.indices {
            guard index < layout.columns.count else { continue }
            subviews[index].place(at: .init(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: .init(width: layout.columns[index], height: bounds.height))
            x += layout.columns[index] + layout.gap
        }
    }
}
