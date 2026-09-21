import SwiftUI

/// A presentation-only split for live workflows. Width changes the layout;
/// progress values never change its column widths or recreate a Store.
struct RuntimeActivityColumns<Content: View>: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    let module: ReviewFilter
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let showsArtwork = proxy.size.width >= 800
            let panelWidth = showsArtwork
                ? proxy.size.width * 0.70
                : proxy.size.width
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 24) {
                    content
                        .frame(width: panelWidth)
                        .fixedSize(horizontal: false, vertical: true)
#if DEBUG
                        .layoutProbe(LayoutProbeID.runtimePanel)
#endif
                    if showsArtwork {
                        FileToolLandingArtwork(
                            systemImage: module.systemImage,
                            tint: theme.accent,
                            featureGroup: theme.featureGroup,
                            workflowIsActive: true
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: layout.isShort ? 180 : 250)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
#if DEBUG
                        .layoutProbe(LayoutProbeID.runtimeArtwork)
#endif
                    }
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
#if DEBUG
            .layoutProbe(LayoutProbeID.runtimeViewport)
#endif
        }
        .padding(.vertical, 10)
    }
}

struct RuntimeActivityFooter<Actions: View>: View {
    @Environment(\.moduleTheme) private var theme
    var text = L10n.text("只读扫描 · 清理前逐项确认", "Read-only scan · Review before cleanup")
    @ViewBuilder let actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                explanation.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                actions.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                explanation
                HStack { Spacer(minLength: 0); actions }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .foregroundStyle(theme.primaryText)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: theme.accent, prominence: .quiet)
    }

    private var explanation: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(theme.accent).accessibilityHidden(true)
        }
        .font(AppDesignTokens.Typography.metadata)
        .foregroundStyle(theme.secondaryText)
    }
}
