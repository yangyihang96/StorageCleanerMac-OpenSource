import SwiftUI

// MARK: - IconTile (UI-V2-SPEC 1.5)

/// A module-gradient tile with a white SF Symbol and a highlight along its top
/// edge. Sizes: 22 (sidebar), 32 (list rows), 52 / 64 (page headers).
struct IconTile: View {
    enum Glyph {
        case symbol(String)
        /// The native Smart Scan mark (reference 012).
        case smartScanEmblem
    }

    enum Shape {
        /// Corner radius 28% of the side (§1.4).
        case roundedSquare
        /// The round scope icons of reference 012.
        case circle
    }

    @Environment(\.moduleTheme) private var moduleTheme
    @Environment(\.colorScheme) private var colorScheme

    let glyph: Glyph
    var side: CGFloat
    /// `nil` uses the page's module pigment.
    var pigment: ModulePigment?
    /// Header tiles glow softly at night.
    var glows = false
    /// Drawn on a selected (gradient) row: a light rim keeps the edge.
    var isOnSelection = false
    var shape: Shape = .roundedSquare

    init(systemImage: String, side: CGFloat, pigment: ModulePigment? = nil,
         glows: Bool = false, isOnSelection: Bool = false, shape: Shape = .roundedSquare) {
        glyph = systemImage == ReviewFilter.overview.systemImage ? .smartScanEmblem : .symbol(systemImage)
        self.side = side
        self.pigment = pigment
        self.glows = glows
        self.isOnSelection = isOnSelection
        self.shape = shape
    }

    init(glyph: Glyph, side: CGFloat, pigment: ModulePigment? = nil, glows: Bool = false,
         shape: Shape = .roundedSquare) {
        self.glyph = glyph
        self.side = side
        self.pigment = pigment
        self.glows = glows
        self.shape = shape
    }

    private var resolvedPigment: ModulePigment {
        pigment ?? (moduleTheme.isImmersive ? moduleTheme.pigment : .neutral)
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: self.shape == .circle ? side / 2 : AppDesignTokens.Corner.tile(side: side),
            style: .continuous
        )
        let pigment = resolvedPigment
        ZStack {
            shape.fill(LinearGradient(colors: pigment.gradientStops,
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            // The highlight is brightest at the top edge and fades by mid-tile.
            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)],
                                      startPoint: .top, endPoint: .center))
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(isOnSelection ? 0.55 : 0.32), .white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: side >= 40 ? 1 : 0.75
            )
            glyphView
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: side * 0.03, y: side * 0.02)
        }
        .frame(width: side, height: side)
        .shadow(
            color: glows && colorScheme == .dark ? pigment.brightColor.opacity(0.35) : .clear,
            radius: side * 0.32
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .symbol(let name):
            AppSymbolGlyph(systemImage: name, size: (side * 0.52).rounded(), weight: .semibold)
        case .smartScanEmblem:
            SmartScanEmblem()
                .frame(width: side * 0.62, height: side * 0.62)
        }
    }
}

// MARK: - SurfaceCard (UI-V2-SPEC 1.5, 1.1)

enum SurfaceLevel {
    /// Cards on the canvas.
    case card
    /// Floating or emphasised cards (action bars, popovers).
    case elevated
    /// The third layer inside a card. Nothing nests deeper (§1.4).
    case inset
}

/// Card background: fill, a 1 pt edge that is lighter at the top, and the
/// daylight shadow. Reduced transparency makes the fill opaque; increased
/// contrast darkens the edge (§1.1).
struct SurfaceBackground: View {
    @AppSurfaces private var surfaces
    var level: SurfaceLevel = .card
    var cornerRadius: CGFloat = AppDesignTokens.Corner.card
    /// A faint wash of a semantic or module color (5%).
    var tint: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(fill)
            .overlay {
                if let tint {
                    shape.fill(tint.opacity(surfaces.isNight ? 0.07 : 0.05))
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [surfaces.strokeTop, surfaces.strokeBottom],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .shadow(
                color: level == .inset ? .clear : surfaces.shadow,
                radius: surfaces.spec.shadowRadius,
                y: surfaces.spec.shadowY
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch level {
        case .card: surfaces.card
        case .elevated: surfaces.cardElevated
        case .inset: surfaces.inset
        }
    }
}

struct SurfaceCard<Content: View>: View {
    @Environment(\.pageLayout) private var pageLayout
    var level: SurfaceLevel = .card
    /// `nil` uses the page's card padding (12 / 16 / 20).
    var padding: CGFloat?
    var cornerRadius: CGFloat = AppDesignTokens.Corner.card
    var tint: Color?
    /// Clickable cards float 2 pt on hover (§3.2.6).
    var liftsOnHover = false
    var isIntegrated = false
    @ViewBuilder let content: Content

    var body: some View {
        let card = content
            .padding(padding ?? pageLayout?.cardPadding ?? AppDesignTokens.Grid.x2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                if !isIntegrated { SurfaceBackground(level: level, cornerRadius: cornerRadius, tint: tint) }
            }
        if liftsOnHover {
            card.appHoverLift(cornerRadius: cornerRadius)
        } else {
            card
        }
    }
}

extension View {
    func surfaceBackground(
        _ level: SurfaceLevel = .card,
        cornerRadius: CGFloat = AppDesignTokens.Corner.card,
        tint: Color? = nil
    ) -> some View {
        background {
            SurfaceBackground(level: level, cornerRadius: cornerRadius, tint: tint)
        }
    }
}

// MARK: - Module glow canvas (UI-V2-SPEC 1.1)

/// Page canvas with the module glow: a radial light at the top-trailing
/// corner (about 60% of the page width) and a faint answer at the
/// bottom-leading corner. Static; it only animates when the module changes.
struct ModuleGlowCanvas: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    let theme: ModuleTheme

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let glow = theme.isImmersive ? theme.glowColor : Color.clear
            ZStack {
                LinearGradient(colors: [surfaces.canvasTop, surfaces.canvasBottom],
                               startPoint: .top, endPoint: .bottom)
                // Review 4: a larger top-trailing glow and a weak second one
                // at the bottom-leading corner, so even pure black has depth.
                RadialGradient(
                    colors: [glow.opacity(surfaces.glowOpacity), glow.opacity(surfaces.glowOpacity * 0.35), glow.opacity(0)],
                    center: UnitPoint(x: 0.94, y: -0.06),
                    startRadius: 0,
                    endRadius: width * 0.86
                )
                RadialGradient(
                    colors: [glow.opacity(surfaces.glowOpacity * 0.5), glow.opacity(0)],
                    center: UnitPoint(x: -0.02, y: 1.06),
                    startRadius: 0,
                    endRadius: width * 0.50
                )

            }
            .animation(AppMotion.resolved(.emphasized, reduceMotion: reduceMotion), value: theme.identifier + "\(theme.pigment.bright)")
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - StatusFooter (UI-V2-SPEC 1.5)

/// The page's status strip: "尚未扫描 | 只读扫描 · 清理前逐项确认". The status
/// line shares the canvas; only failure or warning symbols remain.
struct StatusFooter: View {
    @Environment(\.moduleTheme) private var theme
    @AppSurfaces private var surfaces

    let status: ScanStatusPresentation
    var trustText: String = ""
    /// One short line for short windows (§2.2).
    var isCompact = false
    var isIntegrated = false

    var body: some View {
        Group {
            if isCompact {
                HStack(spacing: AppDesignTokens.Grid.x1_5) {
                    statusLabel(font: AppDesignTokens.TypeScale.secondaryEmphasis)
                    if !trustText.isEmpty {
                        trustLabel(font: AppDesignTokens.TypeScale.secondary)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .padding(.horizontal, AppDesignTokens.Grid.x1_5)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: AppDesignTokens.Grid.x2) {
                    statusLabel(font: AppDesignTokens.TypeScale.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !trustText.isEmpty {
                        Rectangle()
                            .fill(surfaces.divider)
                            .frame(width: 1, height: 26)
                            .accessibilityHidden(true)
                        trustLabel(font: AppDesignTokens.TypeScale.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, AppDesignTokens.Grid.x2_5)
                .padding(.vertical, AppDesignTokens.Grid.x1_5)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }
        }
        .background {
            if !isIntegrated {
                SurfaceBackground(level: .card, cornerRadius: isCompact ? AppDesignTokens.Corner.inset : AppDesignTokens.Corner.card)
            }
        }
        .overlay(alignment: .top) {
            if isIntegrated { Rectangle().fill(surfaces.divider).frame(height: 0.5).accessibilityHidden(true) }
        }
        .help(trustText.isEmpty ? status.title : "\(status.title) · \(trustText)")
        .accessibilityElement(children: .combine)
    }

    private func statusLabel(font: Font) -> some View {
        HStack(spacing: AppDesignTokens.Grid.x1) {
            if isWarning {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(statusTint).accessibilityHidden(true)
            }
            Text(status.title).font(font)
                .foregroundStyle(status == .neverScanned || isIdle ? surfaces.textPrimary : statusTint)
                .lineLimit(1)
        }
    }

    private func trustLabel(font: Font) -> some View {
        Text(trustText).font(font).foregroundStyle(surfaces.textSecondary).lineLimit(1)
    }

    private var isWarning: Bool {
        switch status {
        case .failed, .expired: true
        default: false
        }
    }

    private var isIdle: Bool {
        if case .idle = status { return true }
        return false
    }

    private var statusTint: Color {
        switch status {
        case .completed: AppDesignTokens.Palette.success
        case .failed, .expired: AppDesignTokens.Palette.warning
        case .scanning, .neverScanned, .idle: theme.isImmersive ? theme.accent : AppDesignTokens.Palette.accent
        }
    }
}

// MARK: - SkeletonBlock (UI-V2-SPEC 1.5, §3.2.8)

/// A loading placeholder with one sweeping sheen per 1.2 s. The sweep only
/// runs while the block is on screen and stops under Reduce Motion.
struct SkeletonBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    @State private var phase: CGFloat = -1

    var width: CGFloat?
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(surfaces.isNight ? Color.white.opacity(0.07) : Color.black.opacity(0.06))
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, (surfaces.isNight ? Color.white : Color.white).opacity(surfaces.isNight ? 0.10 : 0.55), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: phase * proxy.size.width * 1.6)
                }
                .clipShape(shape)
                .opacity(reduceMotion ? 0 : 1)
            }
            .frame(width: width, height: height)
            .onAppear {
                guard !reduceMotion else { return }
                phase = -1
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .onDisappear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { phase = -1 }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Section title (UI-V2-SPEC 1.3)

struct SurfaceSectionTitle<Trailing: View>: View {
    @AppSurfaces private var surfaces
    let title: String
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: AppDesignTokens.Grid.x1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(surfaces.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(AppDesignTokens.TypeScale.sectionTitle)
                .foregroundStyle(surfaces.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: AppDesignTokens.Grid.x1)
            trailing
        }
    }
}

extension SurfaceSectionTitle where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = EmptyView()
    }
}

// MARK: - Scroll edge under a fixed header

/// Content scrolling under a fixed page header fades out over the top
/// `height` points instead of showing through the header (macOS 26's soft
/// scroll edge effect is turned off for that edge, so nothing ghosts).
private struct ScrollTopFadeModifier: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.scrollEdgeEffectHidden(true, for: .top)
            } else {
                content
            }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                Rectangle().fill(.black)
            }
        }
    }
}

/// The same alpha fade as the fixed-header edge, at the bottom of a
/// constrained list. The hint is laid out separately, so it cannot cover rows.
private struct ScrollBottomFadeModifier: ViewModifier {
    let height: CGFloat
    let isVisible: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isVisible {
            content.mask {
                VStack(spacing: 0) {
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: height)
                }
            }
        } else { content }
    }
}

/// Reports whether a scroll view has moved away from its top (macOS 15 and
/// later; earlier systems report `false`).
private struct ScrollOffsetReporter: ViewModifier {
    @Binding var isScrolled: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 4
            } action: { _, scrolled in
                if isScrolled != scrolled { isScrolled = scrolled }
            }
        } else {
            content
        }
    }
}

/// The hairline under a fixed header, shown once the content has scrolled.
struct FixedHeaderDivider: View {
    @AppSurfaces private var surfaces
    let isVisible: Bool

    var body: some View {
        Rectangle()
            .fill(surfaces.divider)
            .frame(height: 1)
            .opacity(isVisible ? 1 : 0)
            .animation(AppMotion.hover, value: isVisible)
            .accessibilityHidden(true)
    }
}

extension View {
    func scrollTopFade(height: CGFloat = 14) -> some View {
        modifier(ScrollTopFadeModifier(height: height))
    }

    func scrollBottomFade(height: CGFloat = 14, when isVisible: Bool) -> some View {
        modifier(ScrollBottomFadeModifier(height: height, isVisible: isVisible))
    }

    func reportsScrollOffset(_ isScrolled: Binding<Bool>) -> some View {
        modifier(ScrollOffsetReporter(isScrolled: isScrolled))
    }
}

// MARK: - List row hover (§3.2.6)

/// List rows only highlight their background on hover; they never move.
private struct ListRowHoverModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    @State private var isHovered = false
    var isSelected = false
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: AppDesignTokens.Corner.row, style: .continuous)
                    .fill(fill)
                    .accessibilityHidden(true)
            }
            .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isHovered)
            .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isSelected)
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if isSelected { return (tint ?? .accentColor).opacity(surfaces.isNight ? 0.10 : 0.07) }
        return isHovered ? surfaces.hover : .clear
    }
}

extension View {
    func listRowHover(isSelected: Bool = false, tint: Color? = nil) -> some View {
        modifier(ListRowHoverModifier(isSelected: isSelected, tint: tint))
    }
}
