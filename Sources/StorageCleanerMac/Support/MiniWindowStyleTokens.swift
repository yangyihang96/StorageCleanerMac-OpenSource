import SwiftUI

/// Shared geometry for every surface presented by the menu-bar mini window.
/// Values are expressed in points; one physical-pixel decoration uses the
/// SwiftUI display scale at the drawing site.
enum MiniWindowStyleTokens {
    static let overviewSize = CGSize(width: 304, height: 544)
    // The CPU detail keeps a fixed nine-column core grid. Its page and card
    // insets need this width so the first and last rings do not touch the shell.
    static let detailWidth: CGFloat = 312
    // Power uses two 96-point rings and needs less horizontal breathing room
    // than the CPU grid. Keeping this distinct avoids widening every detail page.
    static let powerDetailWidth: CGFloat = 264
    // A 380-point history shell leaves a 360-point plot after the shared
    // 8-point content inset and 2-point chart inset: 120 × 3-point slots.
    static let historyWidth: CGFloat = 380
    static let compactHistoryWidth: CGFloat = 380
    static let anchorGap: CGFloat = 0
    static let cascadeGap: CGFloat = 0

    static let outerCornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 10
    static let controlCornerRadius: CGFloat = 6
    // iStat-like density: one equal inset on all four shell edges, with a
    // smaller repeated gap between sibling cards.
    static let contentInset: CGFloat = 8
    static let cardSpacing: CGFloat = 5
    static let cardHorizontalInset: CGFloat = 8
    static let cardVerticalInset: CGFloat = 6
    static let rowSpacing: CGFloat = 4
    static let inlineSpacing: CGFloat = 6
    static let dataRowHeight: CGFloat = 16
    static let controlRowHeight: CGFloat = 24
    static let lightShellShadowOpacity: Double = 0.24
    static let darkShellShadowOpacity: Double = 0.44
    static let lightShellShadowRadius: CGFloat = 14
    static let darkShellShadowRadius: CGFloat = 16
    static let shellShadowYOffset: CGFloat = 4

    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 1
    static let barPitch = barWidth + barSpacing
    static let panelBackgroundTintOpacity: Double = 0.18
    static let lightMaterialNeutralTintOpacity: Double = 0.18
    static let darkShellTopColor = Color(red: 0.035, green: 0.060, blue: 0.085)
    static let darkShellBottomColor = Color(red: 0.010, green: 0.020, blue: 0.032)

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
            let extent = max(radius, 0) + thickness
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
                if colorScheme == .dark {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    MiniWindowStyleTokens.darkShellTopColor,
                                    MiniWindowStyleTokens.darkShellBottomColor,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
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
                                        Color.white.opacity(
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
            .shadow(
                color: .black.opacity(showsShadow ? shellShadowOpacity : 0),
                radius: showsShadow ? shellShadowRadius : 0,
                y: showsShadow ? MiniWindowStyleTokens.shellShadowYOffset : 0
            )
    }

    private var opaqueSurface: Color {
        Color(nsColor: .windowBackgroundColor)
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
        colorSchemeContrast == .increased
            ? AppDesignTokens.Palette.primaryText.opacity(0.8)
            : colorScheme == .dark
                ? Color.white.opacity(0.10)
                : Color.black.opacity(0.14)
    }
}

private struct MiniWindowTooltipChrome: ViewModifier {
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous)
        content
            .background(shape.fill(AppAppearanceColors.tooltip))
            .overlay {
                shape
                    .strokeBorder(AppAppearanceColors.ink.opacity(0.16), lineWidth: MiniWindowPixel.onePhysicalPixel(displayScale: displayScale))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
    }
}

extension View {
    func miniWindowTooltipChrome() -> some View {
        modifier(MiniWindowTooltipChrome())
    }
}
