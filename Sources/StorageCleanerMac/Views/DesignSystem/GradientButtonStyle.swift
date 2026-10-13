import SwiftUI

/// UI-V2-SPEC 1.5 buttons. The fill is drawn by the style itself, so a
/// button keeps its colors whether or not its window is active.
///
/// - primary: the module gradient, white label;
/// - destructive: the red gradient (quit, move to Trash, clean — N19, D49);
/// - secondary: module color at 14% with a module-colored label;
/// - ghost: no fill until hovered.
///
/// Hover brightens by 6%, press scales to 0.97. Disabled filled buttons drop
/// their color and fade (UI-V2-SPEC 1.5 asks for 40%; 55% keeps the label
/// legible on the neutral fill).
struct GradientButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        case primary
        case destructive
        case secondary
        case ghost
    }

    enum Size: Equatable, Sendable {
        /// 32 pt.
        case small
        /// 40 pt.
        case medium
        /// 52 pt, for the page's main action.
        case large
        /// 56 pt, the landing action in large windows.
        case hero

        var height: CGFloat {
            switch self {
            case .small: 32
            case .medium: 40
            case .large: FeaturePageTokens.primaryHeight
            case .hero: 56
            }
        }

        var cornerRadius: CGFloat {
            self == .large || self == .hero ? FeaturePageTokens.primaryCorner : AppDesignTokens.Corner.button
        }

        var font: Font {
            switch self {
            case .small: AppDesignTokens.TypeScale.secondaryEmphasis
            case .medium: AppDesignTokens.TypeScale.buttonRegular
            case .large: FeaturePageTokens.primaryFont
            case .hero: AppDesignTokens.TypeScale.buttonHero
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: 12
            case .medium: 16
            case .large, .hero: FeaturePageTokens.primaryHorizontalPadding
            }
        }
    }

    var kind: Kind = .primary
    var size: Size = .medium
    /// `nil` uses the page's module pigment.
    var pigment: ModulePigment?
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        GradientButtonBody(
            configuration: configuration,
            kind: kind,
            size: size,
            pigment: pigment,
            fillsWidth: fillsWidth
        )
    }
}

private struct GradientButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.moduleTheme) private var moduleTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    @State private var isHovered = false

    let configuration: ButtonStyle.Configuration
    let kind: GradientButtonStyle.Kind
    let size: GradientButtonStyle.Size
    let pigment: ModulePigment?
    let fillsWidth: Bool

    private var resolvedPigment: ModulePigment {
        if kind == .destructive { return .danger }
        if let pigment { return pigment }
        return moduleTheme.isImmersive ? moduleTheme.pigment : .neutral
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .labelStyle(.titleOnly)
            .font(size.font)
            .foregroundStyle(isEnabled ? foreground : surfaces.textSecondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: size.height)
            .background { background(shape: shape) }
            .overlay { rim(shape: shape) }
            .contentShape(shape)
            .brightness(isHovered && isEnabled ? 0.06 : 0)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(AppMotion.resolved(.press, reduceMotion: reduceMotion), value: pressed)
            .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .destructive: .white
        case .secondary: secondaryInk
        case .ghost: surfaces.textPrimary
        }
    }

    /// Module text on the 14% wash: the bright pigment at night, the deeper
    /// gradient stop in daylight (>= 4.5:1 on the morning-mist canvas).
    private var secondaryInk: Color {
        surfaces.isNight ? resolvedPigment.brightColor : resolvedPigment.darkStop
    }

    @ViewBuilder
    private func background(shape: RoundedRectangle) -> some View {
        if !isEnabled, kind == .primary || kind == .destructive {
            // Disabled filled buttons lose their color entirely, so an
            // unavailable action never reads as a muted live one (review 6).
            shape.fill(surfaces.isNight ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        } else {
            filledBackground(shape: shape)
        }
    }

    @ViewBuilder
    private func filledBackground(shape: RoundedRectangle) -> some View {
        switch kind {
        case .primary, .destructive:
            ZStack {
                shape.fill(LinearGradient(colors: resolvedPigment.gradientStops,
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0)],
                                          startPoint: .top, endPoint: .center))
            }
            .shadow(color: surfaces.isNight ? resolvedPigment.brightColor.opacity(isEnabled ? 0.28 : 0) : .black.opacity(0.10),
                    radius: size == .large ? 14 : 8, y: surfaces.isNight ? 0 : 2)
        case .secondary:
            shape.fill(resolvedPigment.brightColor.opacity(surfaces.isNight ? 0.16 : 0.14))
        case .ghost:
            shape.fill(isHovered && isEnabled ? surfaces.hover : .clear)
        }
    }

    @ViewBuilder
    private func rim(shape: RoundedRectangle) -> some View {
        if !isEnabled, kind == .primary || kind == .destructive {
            shape.strokeBorder(surfaces.divider, lineWidth: 1)
        } else {
            liveRim(shape: shape)
        }
    }

    @ViewBuilder
    private func liveRim(shape: RoundedRectangle) -> some View {
        switch kind {
        case .primary, .destructive:
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        case .secondary:
            shape.strokeBorder(resolvedPigment.brightColor.opacity(0.28), lineWidth: 1)
        case .ghost:
            EmptyView()
        }
    }
}

/// D64: primary labels contain centered text only. Compatibility inputs let
/// terminal consumers migrate without preserving a decorative glyph subtree.
struct PrimaryActionLabel: View {
    let title: String
    var isCompact = false
    init(title: String, systemImage: String = "", isLoading: Bool = false,
         usesSmartScanEmblem: Bool = false, isCompact: Bool = false) {
        self.title = title
        self.isCompact = isCompact
    }
    var body: some View {
        Text(title)
            .font(isCompact ? AppDesignTokens.TypeScale.buttonRegular : FeaturePageTokens.primaryFont)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
