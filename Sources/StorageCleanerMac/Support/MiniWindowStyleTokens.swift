import SwiftUI

/// Shared geometry for every surface presented by the menu-bar mini window.
/// Values are expressed in points; one physical-pixel decoration uses the
/// SwiftUI display scale at the drawing site.
enum MiniWindowStyleTokens {
    // D118: iStat Menus 7.30's combined menu (`configureMenubar` 301 pt,
    // measured 2x capture): 8 pt around the cards, 7 pt between them, and the
    // six level-one cards at 120, 112, 42, 100, 88 and 40 pt.
    static let overviewSize = CGSize(width: 301, height: 553)
    // D119: iStat's module menus (`setWidth:` in each `loadItems`): CPU 272,
    // memory 270 and power 240; disks, network and sensors keep the 301 pt
    // default, and so does our cleanup page. Was 312, and 264 for power.
    static let detailWidth: CGFloat = 301
    static let processorDetailWidth: CGFloat = 272
    static let memoryDetailWidth: CGFloat = 270
    static let powerDetailWidth: CGFloat = 240
    // D121: iStat's history submenu (`loadWithClass:` sets 391): one graph
    // card of 375 × 200 (`itemWithConfig:` 516 × 200 squeezed to the menu)
    // 8 pt inside the window, so the window is 216 tall. The plot is 8 pt in
    // from the card's sides: 359 pt, 120 bars of 2 pt with 1 pt gaps. Was a
    // 380 pt shell with a 2 pt chart inset.
    static let historyWidth: CGFloat = 391
    static let compactHistoryWidth: CGFloat = historyWidth
    static let historyCardHeight: CGFloat = 200
    static let historyHeight: CGFloat = historyCardHeight + 2 * contentInset
    // The card's title row, then from 25 the plot block: the chart plus our
    // axis row (start / gap legend / scale / now) directly below it, ending
    // 8 pt above the card's bottom; iStat's single graph height H − 33 = 167.
    // Was 154 below a free-standing header.
    static let historyPlotTop: CGFloat = 25
    static let historyPlotHeight: CGFloat = historyCardHeight - historyPlotTop - contentInset
    static let historyAxisRowHeight: CGFloat = 14
    static let historyChartHeight = historyPlotHeight - historyAxisRowHeight
    static let historyChartInset: CGFloat = contentInset
    static let historyContentHeight = historyHeight - 2 * contentInset
    // D118: the level-one panel's top is 2 pt below the menu bar and its left
    // edge 2 pt left of the status item (iStat `updateFrame`).
    static let anchorGap: CGFloat = 2
    static let statusItemLeadingOverhang: CGFloat = 2
    static let cascadeGap: CGFloat = 0

    // D118: iStat's scroller corner (16) and card corner (8).
    static let outerCornerRadius: CGFloat = 16
    static let outerCornerExtent = continuousCornerExtent(radius: outerCornerRadius)

    /// Read the platform shape's curve extent instead of treating a continuous
    /// corner as a quarter circle or hard-coding a private Bezier coefficient.
    static func continuousCornerExtent(radius: CGFloat) -> CGFloat {
        guard radius.isFinite, radius > 0 else { return 0 }
        let side = radius * 4
        var extent = radius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.path(in: CGRect(x: 0, y: 0, width: side, height: side)).forEach { element in
            let endpoint: CGPoint
            switch element {
            case let .curve(to: point, control1: _, control2: _): endpoint = point
            case let .quadCurve(to: point, control: _): endpoint = point
            default: return
            }
            if abs(endpoint.x) < 0.001 || abs(endpoint.x - side) < 0.001 {
                extent = max(extent, min(endpoint.y, side - endpoint.y))
            }
            if abs(endpoint.y) < 0.001 || abs(endpoint.y - side) < 0.001 {
                extent = max(extent, min(endpoint.x, side - endpoint.x))
            }
        }
        return extent
    }
    static let cardCornerRadius: CGFloat = 8
    static let controlCornerRadius: CGFloat = 6
    // iStat density: one equal inset on all four shell edges, with a smaller
    // repeated gap between sibling cards (7 pt on the measured capture).
    static let contentInset: CGFloat = 8
    static let cardSpacing: CGFloat = 7
    static let cardHorizontalInset: CGFloat = 8
    static let cardVerticalInset: CGFloat = 6
    static let rowSpacing: CGFloat = 4
    static let inlineSpacing: CGFloat = 6
    // Gap between side-by-side value columns inside a card.
    static let columnSpacing: CGFloat = 8
    // SF Symbols retain their own aspect ratio inside equal, centered slots.
    // Keep label and process geometry shared across modules and previews.
    static let moduleIconGlyphSize: CGFloat = 12
    static let moduleIconSlotSize: CGFloat = 16
    static let moduleIconSpacing: CGFloat = 6
    static let processIconSize: CGFloat = 16
    static let disclosureGlyphSize: CGFloat = 9
    static let disclosureIconSlotSize: CGFloat = 12
    static let statusGlyphSize: CGFloat = 11
    static let statusIconSlotSize: CGFloat = 14
    static let dataRowHeight: CGFloat = 16
    static let controlRowHeight: CGFloat = 24
    static let lightShellShadowOpacity: Double = 0.08
    static let darkShellShadowOpacity: Double = 0.44
    static let lightShellShadowRadius: CGFloat = 10
    static let darkShellShadowRadius: CGFloat = 16
    static let shellShadowYOffset: CGFloat = 4

    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 1
    static let barPitch = barWidth + barSpacing
    static let panelBackgroundTintOpacity: Double = 0.18
    static let lightMaterialNeutralTintOpacity: Double = 0.94
    // Daylight preserves the former graphite panel. Night uses a neutral black
    // surface; attached levels share the same fill at their seams.
    static let graphiteShellColor = MonitorPalette.graphiteShell
    static let darkShellColor = MonitorPalette.blackShell
    static let darkShellTopColor = darkShellColor
    static let darkShellBottomColor = darkShellColor

    static func shellColor(for visualMode: MiniWindowVisualMode) -> Color {
        visualMode == .graphite ? graphiteShellColor : darkShellColor
    }

    static let detailRevealDelay = HoverIntentPolicy.menuBar.initialOpenDelay
    static let historyRevealDelay = HoverIntentPolicy.menuBar.switchDelay
    static let dismissDelay = HoverIntentPolicy.menuBar.ordinaryCloseDelay
}

enum MiniWindowPixel {
    static func onePhysicalPixel(displayScale: CGFloat) -> CGFloat {
        1 / max(1, displayScale)
    }

    static func aligned(_ value: CGFloat, displayScale: CGFloat) -> CGFloat {
        (value * max(1, displayScale)).rounded() / max(1, displayScale)
    }

    static func snappedLength(_ value: CGFloat, displayScale: CGFloat) -> CGFloat {
        max(0, aligned(value, displayScale: displayScale))
    }

    /// Places a stroke so both of its physical-pixel edges land on pixel
    /// boundaries, including odd-pixel hairlines on Retina displays.
    static func strokeCenter(
        _ value: CGFloat,
        lineWidth: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        let width = snappedLength(lineWidth, displayScale: displayScale)
        let edge = aligned(value - width / 2, displayScale: displayScale)
        return edge + width / 2
    }
}

/// Normalized spans of the four shell borders that should remain visible.
///
/// Attached mini-window levels share an edge. The geometry layer gives one
/// level ownership of that shared span, so the shell can retain a single
/// physical-pixel separator while preserving any unshared part of the edge.
struct MiniWindowBorderEdges: Equatable {
    var top: [ClosedRange<CGFloat>]
    var leading: [ClosedRange<CGFloat>]
    var bottom: [ClosedRange<CGFloat>]
    var trailing: [ClosedRange<CGFloat>]

    init(
        top: [ClosedRange<CGFloat>] = [0 ... 1],
        leading: [ClosedRange<CGFloat>] = [0 ... 1],
        bottom: [ClosedRange<CGFloat>] = [0 ... 1],
        trailing: [ClosedRange<CGFloat>] = [0 ... 1]
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    static let all = MiniWindowBorderEdges()

    func mask(
        in size: CGSize,
        cornerRadii: RectangleCornerRadii,
        lineWidth: CGFloat
    ) -> Path {
        guard size.width > 0, size.height > 0 else { return Path() }

        let thickness = max(lineWidth * 2, 0.5)
        var path = Path()

        func point(_ value: CGFloat, length: CGFloat) -> CGFloat {
            min(max(value, 0), 1) * length
        }

        for span in top {
            let lower = point(span.lowerBound, length: size.width)
            let upper = point(span.upperBound, length: size.width)
            guard upper > lower else { continue }
            path.addRect(CGRect(x: lower, y: 0, width: upper - lower, height: thickness))
        }
        for span in bottom {
            let lower = point(span.lowerBound, length: size.width)
            let upper = point(span.upperBound, length: size.width)
            guard upper > lower else { continue }
            path.addRect(
                CGRect(
                    x: lower,
                    y: max(0, size.height - thickness),
                    width: upper - lower,
                    height: thickness
                )
            )
        }
        for span in leading {
            let lower = point(span.lowerBound, length: size.height)
            let upper = point(span.upperBound, length: size.height)
            guard upper > lower else { continue }
            path.addRect(CGRect(x: 0, y: lower, width: thickness, height: upper - lower))
        }
        for span in trailing {
            let lower = point(span.lowerBound, length: size.height)
            let upper = point(span.upperBound, length: size.height)
            guard upper > lower else { continue }
            path.addRect(
                CGRect(
                    x: max(0, size.width - thickness),
                    y: lower,
                    width: thickness,
                    height: upper - lower
                )
            )
        }

        // The thin edge masks above retain straight segments. Add each corner
        // only when both bordering edges own it, preserving the outer curve
        // without leaking a suppressed attached edge back into view.
        let tolerance: CGFloat = 0.0001
        func includesStart(_ spans: [ClosedRange<CGFloat>]) -> Bool {
            spans.contains { $0.lowerBound <= tolerance }
        }
        func includesEnd(_ spans: [ClosedRange<CGFloat>]) -> Bool {
            spans.contains { $0.upperBound >= 1 - tolerance }
        }
        func addCorner(_ x: CGFloat, _ y: CGFloat, radius: CGFloat) {
            let extent = (radius == MiniWindowStyleTokens.outerCornerRadius
                ? MiniWindowStyleTokens.outerCornerExtent
                : MiniWindowStyleTokens.continuousCornerExtent(radius: radius)) + thickness
            path.addRect(
                CGRect(
                    x: x,
                    y: y,
                    width: min(size.width, extent),
                    height: min(size.height, extent)
                )
            )
        }

        if includesStart(top), includesStart(leading) {
            addCorner(0, 0, radius: cornerRadii.topLeading)
        }
        if includesEnd(top), includesStart(trailing) {
            addCorner(
                max(0, size.width - cornerRadii.topTrailing - thickness),
                0,
                radius: cornerRadii.topTrailing
            )
        }
        if includesStart(bottom), includesEnd(leading) {
            addCorner(
                0,
                max(0, size.height - cornerRadii.bottomLeading - thickness),
                radius: cornerRadii.bottomLeading
            )
        }
        if includesEnd(bottom), includesEnd(trailing) {
            addCorner(
                max(0, size.width - cornerRadii.bottomTrailing - thickness),
                max(0, size.height - cornerRadii.bottomTrailing - thickness),
                radius: cornerRadii.bottomTrailing
            )
        }

        return path
    }
}

struct MetricPanelShell<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.panelBackgroundTint) private var panelBackgroundTint
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode

    let cornerRadii: RectangleCornerRadii
    let borderEdges: MiniWindowBorderEdges
    let showsShadow: Bool
    @ViewBuilder let content: Content

    init(
        cornerRadii: RectangleCornerRadii = .init(
            topLeading: MiniWindowStyleTokens.outerCornerRadius,
            bottomLeading: MiniWindowStyleTokens.outerCornerRadius,
            bottomTrailing: MiniWindowStyleTokens.outerCornerRadius,
            topTrailing: MiniWindowStyleTokens.outerCornerRadius
        ),
        borderEdges: MiniWindowBorderEdges = .all,
        showsShadow: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadii = cornerRadii
        self.borderEdges = borderEdges
        self.showsShadow = showsShadow
        self.content = content()
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
        content
            .background {
                if let panelChromePalette {
                    // D135: a transparent theme shows the menu material
                    // behind its clear surface (the system makes the material
                    // opaque under Reduce Transparency, as for iStat).
                    if let appearance = panelChromePalette.menuMaterialAppearance {
                        IStatMenuMaterialBackdrop(appearanceName: appearance)
                            .clipShape(shape)
                    }
                    shape.fill(panelChromePalette.shell)
                } else if colorScheme == .dark {
                    shape
                        .fill(MiniWindowStyleTokens.shellColor(for: visualMode))
                        .overlay {
                            if let panelBackgroundTint {
                                shape.fill(panelBackgroundTint)
                            }
                        }
                } else if reduceTransparency {
                    shape.fill(opaqueSurface)
                } else {
                    shape
                        .fill(.regularMaterial)
                        .overlay {
                            ZStack {
                                if colorScheme == .light {
                                    shape.fill(
                                        AppAppearanceColors.secondarySurface.opacity(
                                            MiniWindowStyleTokens.lightMaterialNeutralTintOpacity
                                        )
                                    )
                                }
                                if let panelBackgroundTint {
                                    shape.fill(panelBackgroundTint)
                                }
                            }
                        }
                }
            }
            .clipShape(shape)
            .overlay {
                GeometryReader { proxy in
                    let lineWidth = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
                    shape
                        .strokeBorder(borderColor, lineWidth: lineWidth)
                        .mask(
                            borderEdges.mask(
                                in: proxy.size,
                                cornerRadii: cornerRadii,
                                lineWidth: lineWidth
                            ).fill(Color.white)
                        )
                }
                .allowsHitTesting(false)
            }
            .modifier(MetricPanelShellShadow(isShown: showsShadow, opacity: shellShadowOpacity, radius: shellShadowRadius))
    }

    private var opaqueSurface: Color {
        if let panelChromePalette { return panelChromePalette.shell }
        return colorScheme == .light ? AppAppearanceColors.secondarySurface : MiniWindowStyleTokens.shellColor(for: visualMode)
    }

    private var shellShadowOpacity: Double {
        colorScheme == .dark
            ? MiniWindowStyleTokens.darkShellShadowOpacity
            : MiniWindowStyleTokens.lightShellShadowOpacity
    }

    private var shellShadowRadius: CGFloat {
        colorScheme == .dark
            ? MiniWindowStyleTokens.darkShellShadowRadius
            : MiniWindowStyleTokens.lightShellShadowRadius
    }

    private var borderColor: Color {
        if let panelChromePalette {
            return colorSchemeContrast == .increased ? panelChromePalette.text : panelChromePalette.border
        }
        return colorSchemeContrast == .increased
            ? AppDesignTokens.Palette.primaryText.opacity(0.8)
            : colorScheme == .dark
                ? (visualMode == .black ? MonitorPalette.blackBorder : MonitorPalette.graphiteBorder)
                : AppAppearanceColors.border
    }
}

/// D135: a shell with its own shadow (the Settings previews) casts one shadow
/// for the whole panel, as the attached panel does around its levels; per
/// layer, every card and line of text shadowed the surface under it.
private struct MetricPanelShellShadow: ViewModifier {
    let isShown: Bool
    let opacity: Double
    let radius: CGFloat

    func body(content: Content) -> some View {
        if isShown {
            content
                .compositingGroup()
                .shadow(color: .black.opacity(opacity), radius: radius, y: MiniWindowStyleTokens.shellShadowYOffset)
        } else {
            content
        }
    }
}

private struct MiniWindowPageProvidesInsetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var miniWindowPageProvidesInset: Bool {
        get { self[MiniWindowPageProvidesInsetKey.self] }
        set { self[MiniWindowPageProvidesInsetKey.self] = newValue }
    }
}

enum MiniWindowTooltipStyle {
    /// A themed card with a hairline border and a shadow (fan curve editor).
    case panel
    /// D121: iStat's history tooltip: a dark box with corner 8 in every
    /// theme, no border or shadow.
    case history

    static let historyCornerRadius: CGFloat = 8
    static let historyFillOpacity = 0.86
}

private struct MiniWindowTooltipChrome: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let style: MiniWindowTooltipStyle

    func body(content: Content) -> some View {
        switch style {
        case .panel:
            let shape = RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous)
            content
                .background(shape.fill(panelChromePalette?.card ?? AppAppearanceColors.tooltip))
                // D135: a theme's card may be translucent or absent; it sits
                // on the theme's opaque surface (drawn behind it).
                .background {
                    if let opaqueSurface = panelChromePalette?.opaqueSurface {
                        shape.fill(opaqueSurface)
                    }
                }
                .overlay {
                    shape
                        .strokeBorder(panelChromePalette?.border ?? AppAppearanceColors.ink.opacity(0.16), lineWidth: MiniWindowPixel.onePhysicalPixel(displayScale: displayScale))
                        .allowsHitTesting(false)
                }
                // D135: one shadow for the whole tooltip; per layer, the
                // translucent card's own shadow darkened the surface under it.
                .compositingGroup()
                .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
        case .history:
            content
                .background(
                    RoundedRectangle(cornerRadius: MiniWindowTooltipStyle.historyCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(reduceTransparency ? 1 : MiniWindowTooltipStyle.historyFillOpacity))
                )
        }
    }
}

extension View {
    func miniWindowTooltipChrome(_ style: MiniWindowTooltipStyle = .panel) -> some View {
        modifier(MiniWindowTooltipChrome(style: style))
    }
}
