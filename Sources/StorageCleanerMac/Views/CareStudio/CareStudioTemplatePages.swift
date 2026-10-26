import SwiftUI

/// D154: the D67 landing and running pages drawn as CleanMyMac 5.7.2's.
/// `FeatureLightfieldPage` and `FeatureRunningTemplate` hand every page of
/// a CleanMyMac module to these templates, so each module's landing is the
/// picture on the left with the title, the description and the page's own
/// options on the right above the round button, and each running page is
/// the floating picture, the stage and the current item above Stop. Each
/// page keeps its options, its action and its safety line; only the layout
/// changes. The classic environment (`careStudioClassicResults`) keeps the
/// D67 layout for its tests.
struct CareStudioTemplateLanding<Content: View>: View {
    @Environment(\.featureOperationHistoryAction) private var openOperationHistory
    @Environment(\.careStudioOpenRoute) private var openRoute
    let studio: CareStudioModule
    let title: String
    let subtitle: String
    let status: String
    let safety: String
    let actionTitle: String
    var actionAccessibilityLabel: String? = nil
    var actionEnabled = true
    var artwork: GeneratedArt? = nil
    var statusActionTitle = ""
    var statusActionEnabled = true
    var statusAction: (() -> Void)? = nil
    let action: () -> Void
    @ViewBuilder let content: Content
    /// The natural height of the options' scroll document, when they have one.
    @State private var optionsHeight: CGFloat = 0

    var body: some View {
        CareStudioPageFrame(module: studio, footnote: safety) {
            GeometryReader { proxy in
                let size = proxy.size
                let wide = size.width >= 760
                Group {
                    if wide {
                        HStack(alignment: .center, spacing: max(28, min(56, size.width * 0.05))) {
                            art(side: artSide(size, wide: true))
                            textColumn(compact: size.height < 430, cap: size.height * 0.6)
                                .frame(maxWidth: 460, maxHeight: size.height, alignment: .leading)
                        }
                    } else {
                        // Narrow windows stack the picture above the text; a
                        // short one leaves it out so the options keep room.
                        VStack(spacing: 14) {
                            if size.height >= 400 { art(side: artSide(size, wide: false)) }
                            textColumn(compact: true, cap: size.height * 0.6)
                                .frame(maxWidth: 460, alignment: .leading)
                        }
                        .frame(maxHeight: size.height)
                    }
                }
                .padding(.horizontal, CareStudioMetrics.pageInset)
                .frame(width: size.width, height: size.height)
            }
        } action: {
            CareStudioActionButton(module: studio, title: CareStudioActionTitle.short(actionTitle),
                                   accessibilityHint: safety, fullTitle: actionAccessibilityLabel ?? actionTitle,
                                   action: action)
                .disabled(!actionEnabled)
                .keyboardShortcut(.defaultAction)
        }
#if DEBUG
        .layoutProbe("careStudio.template.landing")
#endif
    }

    private func art(side: CGFloat) -> some View {
        CareStudioArt(module: studio, side: side, art: artwork, entrance: true)
    }

    private func textColumn(compact: Bool, cap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            Text(title)
                .font(.system(size: compact ? 30 : CareStudioMetrics.titleSize, weight: .regular))
                .foregroundStyle(CareStudioInk.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
#if DEBUG
                .layoutProbe("careStudio.template.title")
#endif
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: compact ? 14 : CareStudioMetrics.subtitleSize))
                    .foregroundStyle(CareStudioInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The page's own options (scope rows, presets); on the gradient
            // they draw as the studio's list (`careStudioSurface`). They take
            // their own height in what the text leaves, then scroll.
            CareStudioOptionsSlot(measured: optionsHeight, cap: cap) { content }
                .layoutPriority(-1)
                .onPreferenceChange(FeatureScrollFrameKey.self) { frames in
                    let natural = frames.filter { $0.key.hasSuffix(".natural") }.map(\.value.height).max() ?? 0
                    if abs(natural - optionsHeight) > 0.5 { optionsHeight = natural }
                }
#if DEBUG
                .layoutProbe("careStudio.template.options")
#endif
            HStack(spacing: 10) {
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(CareStudioInk.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(status)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let statusAction, !statusActionTitle.isEmpty {
                    CareStudioPillButton(title: statusActionTitle, compact: true, action: statusAction)
                        .disabled(!statusActionEnabled)
                }
                if let openOperationHistory {
                    CareStudioPillButton(title: L10n.text("操作记录", "Operation History"),
                                         systemImage: "clock.arrow.circlepath", compact: true, action: openOperationHistory)
                }
                // The module's other tools (My Clutter → Chat Files).
                if let openRoute {
                    ForEach(studio.relatedTools) { route in
                        CareStudioPillButton(title: route.title, systemImage: route.systemImage, compact: true) {
                            openRoute(route)
                        }
                    }
                }
            }
        }
    }

    private func artSide(_ size: CGSize, wide: Bool) -> CGFloat {
        let byHeight = size.height * (wide ? 0.6 : 0.3)
        let byWidth = wide ? size.width * 0.32 : size.width * 0.46
        return max(110, min(CareStudioMetrics.landingArtSide, byHeight, byWidth))
    }
}

/// A running page whose content is the page's own progress view (the
/// benchmark's live telemetry): the floating picture and title above it,
/// Stop below.
struct CareStudioTemplateRunning<Content: View>: View {
    let studio: CareStudioModule
    let title: String
    let safety: String
    let actionTitle: String
    var actionEnabled = true
    var artwork: GeneratedArt? = nil
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        CareStudioPageFrame(module: studio, isWorking: true, footnote: safety) {
            GeometryReader { proxy in
                // A short window drops the picture and gives the progress
                // view what the title leaves.
                let height = proxy.size.height
                let artSide = height >= 300 ? max(80, min(200, height * 0.28)) : 0
                let contentCap = max(48, min(height * 0.5, height - artSide - 80))
                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    if artSide > 0 {
                        CareStudioArt(module: studio, side: artSide, isWorking: true, art: artwork)
                    }
                    Text(title)
                        .font(.system(size: CareStudioMetrics.runningTitleSize, weight: .regular))
                        .foregroundStyle(CareStudioInk.primary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
#if DEBUG
                        .layoutProbe("careStudio.template.runningTitle")
#endif
                        .padding(.top, 12)
                    content
                        .frame(maxWidth: min(760, proxy.size.width - 48))
                        .frame(maxHeight: contentCap)
                        .padding(.top, 12)
                    Spacer(minLength: 8)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } action: {
            CareStudioActionButton(module: studio, title: CareStudioActionTitle.short(actionTitle),
                                   progress: .indeterminate, fullTitle: actionTitle, action: action)
                .disabled(!actionEnabled)
        }
#if DEBUG
        .layoutProbe("careStudio.template.running")
#endif
    }
}

/// Sizes a landing's options: a scroll document's measured natural height
/// (`measured`), or the content's own height, never more than `cap`.
private struct CareStudioOptionsSlot: Layout {
    let measured: CGFloat
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width ?? child.sizeThatFits(.unspecified).width
        let natural = measured > 0 ? measured
            : child.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: max(0, min(natural, cap, proposal.height ?? .infinity)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// CleanMyMac's round button carries one verb ("Scan", "Run"). A page's
/// longer action keeps its whole wording as the button's label for
/// VoiceOver and its help tag; the circle shows the verb.
enum CareStudioActionTitle {
    static func short(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.unicodeScalars.allSatisfy(\.isASCII) {
            guard trimmed.count > 9, let verb = trimmed.split(separator: " ").first else { return trimmed }
            return String(verb)
        }
        return trimmed.count > 4 ? String(trimmed.prefix(2)) : trimmed
    }
}

private struct CareStudioOpenRouteKey: EnvironmentKey {
    static var defaultValue: ((ReviewFilter) -> Void)? { nil }
}

extension EnvironmentValues {
    /// Opens another page of the app (set by the main window).
    var careStudioOpenRoute: ((ReviewFilter) -> Void)? {
        get { self[CareStudioOpenRouteKey.self] }
        set { self[CareStudioOpenRouteKey.self] = newValue }
    }
}

extension CareStudioModule {
    /// D154 batch 2: tools of the module that have no step of their own on
    /// its landing; the landing offers them as pills.
    var relatedTools: [ReviewFilter] {
        switch self {
        case .clutter: [.chatFiles]
        default: []
        }
    }

    /// The landing title: the module's name on a module's first page, the
    /// page's own title on the other pages of the module.
    func landingTitle(for route: ReviewFilter, given: String) -> String {
        given == route.title || given == route.sidebarTitle ? title : given
    }
}
