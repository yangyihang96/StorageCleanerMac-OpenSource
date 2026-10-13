import SwiftUI

/// A presentation-only split for live workflows. Width changes the layout;
/// progress values never change its column widths or recreate a Store.
struct RuntimeActivityColumns<Content: View>: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    let module: ReviewFilter
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let showsArtwork = proxy.size.width >= 800
            let isLarge = pageLayout?.usesLargeComposition ?? false
            let panelWidth = showsArtwork
                ? proxy.size.width * (isLarge ? 0.56 : 0.62)
                : proxy.size.width
            let artworkSide = min(isLarge ? 520 : 400, proxy.size.width - panelWidth - 24,
                                  max(180, proxy.size.height - 20))
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 24) {
                    content
                        .frame(width: panelWidth)
                        .fixedSize(horizontal: false, vertical: true)
#if DEBUG
                        .layoutProbe(LayoutProbeID.runtimePanel)
#endif
                    if showsArtwork {
                        artwork
                            .frame(width: artworkSide, height: artworkSide)
                            .frame(maxWidth: .infinity)
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

    @ViewBuilder
    private var artwork: some View {
        if theme.featureGroup == .smartScan {
            // §3.2.3: the sweep turns
            // only while the scan runs.
            OrbitLandingArtwork.smartScan(isActive: true)
        } else {
            // The same drawing as the module's initial page (D58), with the
            // sweep turning while the work runs.
            OrbitLandingArtwork.module(
                systemImage: module.systemImage,
                isActive: true
            )
        }
    }
}

struct RuntimeActivityFooter<Actions: View>: View {
    @Environment(\.moduleTheme) private var theme
    @AppSurfaces private var surfaces
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
        .foregroundStyle(surfaces.textPrimary)
        .overlay(alignment: .top) {
            Rectangle().fill(surfaces.divider).frame(height: 0.5).accessibilityHidden(true)
        }
    }

    private var explanation: some View {
        Text(text).lineLimit(1)
        .font(AppDesignTokens.TypeScale.secondary)
        .foregroundStyle(surfaces.textSecondary)
    }
}
