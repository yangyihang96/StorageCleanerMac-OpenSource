import SwiftUI

/// D64: title and responsive actions only. Both phases use the same title
/// font; action-only controls remain reachable when the row reflows.
struct PageHero<Actions: View>: View {
    @AppSurfaces private var surfaces
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    var form: PageLayout.HeroForm
    @ViewBuilder let actions: Actions

    // Compatibility labels let concurrent consumers migrate without keeping
    // a stored subtitle, header image, or generated mark.
    init(title: String, subtitle: String? = nil, systemImage: String = "",
         form: PageLayout.HeroForm, art: GeneratedArt? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.form = form
        self.actions = actions()
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }

    var body: some View {
        Group {
            if hasActions {
                ViewThatFits(in: .horizontal) {
                    row(iconOnlyActions: false)
                    row(iconOnlyActions: true)
                    VStack(alignment: .leading, spacing: AppDesignTokens.Grid.x1) {
                        titleBlock(wrapsTitle: true)
                        actionBlock(iconOnly: true)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                titleBlock(wrapsTitle: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, form == .compact ? 10 : AppDesignTokens.Grid.x1_5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(AppMotion.layout(reduceMotion: reduceMotion), value: form)
        .accessibilityElement(children: .contain)
    }

    private func row(iconOnlyActions: Bool) -> some View {
        HStack(alignment: .center, spacing: AppDesignTokens.Grid.x2) {
            titleBlock(wrapsTitle: false)
            Spacer(minLength: AppDesignTokens.Grid.x1_5)
            actionBlock(iconOnly: iconOnlyActions)
                .layoutPriority(1)
        }
    }

    private func titleBlock(wrapsTitle: Bool) -> some View {
        Text(title)
            .font(titleFont)
            .foregroundStyle(surfaces.textPrimary)
            .fixedSize(horizontal: !wrapsTitle, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .layoutPriority(1)
#if DEBUG
            .layoutProbe("pageHeader.title")
            .layoutProbe("pageHeader.titleBlock")
#endif
    }

    private func actionBlock(iconOnly: Bool) -> some View {
        HStack(spacing: AppDesignTokens.Grid.x1) {
            if iconOnly {
                actions.labelStyle(.iconOnly)
            } else {
                actions
            }
        }
        .font(AppDesignTokens.TypeScale.buttonRegular)
        .appButtonChrome(.toolbar)
        .controlSize(.regular)
        .frame(minHeight: AppControlSizes.iconHitRegion, alignment: .trailing)
#if DEBUG
        .layoutProbe("pageHeader.actions")
#endif
    }

    private var titleFont: Font {
        switch form {
        case .prominent: AppDesignTokens.TypeScale.pageTitleProminent
        case .full: AppDesignTokens.TypeScale.pageTitle
        case .regular: AppDesignTokens.TypeScale.pageTitleRegular
        case .compact: AppDesignTokens.TypeScale.pageTitleCompact
        }
    }
}

extension PageLayout.HeroForm {
    /// D64: a title line plus the shared vertical header padding.
    var titleHeaderHeight: CGFloat {
        switch self {
        case .prominent: 60
        case .full: 58
        case .regular: 54
        case .compact: 44
        }
    }


}

extension PageLayout {
    /// A stand-in for views hosted without `AdaptivePageViewport` (tests,
    /// previews): the older metrics only know compact/regular density and
    /// the viewport height.
    static func approximated(from metrics: WindowLayoutMetrics) -> PageLayout {
        let height = metrics.viewportHeight
        return PageLayout(
            width: metrics.density == .compact ? .regular : .wide,
            height: height < PageLayout.heightThresholds[0] ? .short
                : (height < PageLayout.heightThresholds[1] ? .regular : .tall),
            allowsFullHeaderHeight: height >= PageLayout.fullHeaderMinimumHeight,
            size: CGSize(width: metrics.density == .compact ? 760 : 1_084, height: height)
        )
    }
}
