import SwiftUI

enum AppMotionPolicy {
    static func shouldAnimate(reduceMotion: Bool, isActive: Bool = true) -> Bool {
        isActive && !reduceMotion
    }
}

enum AppMotionTokens {
    // Compatibility names for existing views. D53 maps them onto the UI 2.0
    // tokens in `AppMotion` so one curve set drives the whole window.
    private static let state = Animation.easeInOut(duration: 0.20)

    static let press = AppMotion.press
    static let hover = AppMotion.hover
    static let navigation = AppMotion.emphasized
    static let reveal = Animation.timingCurve(0.22, 0.74, 0.24, 1, duration: 0.34)
    static let stateChange = state
    static let feedback = state
    static let progress = Animation.easeInOut(duration: 0.28)
    /// Reduce Motion: a 0.2 s fade (UI-V2-SPEC §3.1). The transitions these
    /// drive are opacity-only in that mode, so nothing moves.
    static let reduced = AppMotion.reducedFade

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    static func pageTransition(reduceMotion: Bool) -> AnyTransition {
        AppMotion.pageTransition(reduceMotion: reduceMotion)
    }

    static func stateTransition(reduceMotion: Bool, edge: Edge = .top) -> AnyTransition {
        .opacity
    }

    static func listTransition(reduceMotion: Bool) -> AnyTransition {
        .opacity
    }
}

private struct AppMotionEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    let delay: TimeInterval
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : distance)
            .task {
                guard AppMotionPolicy.shouldAnimate(reduceMotion: reduceMotion), !isVisible else {
                    isVisible = true
                    return
                }

                await Task.yield()
                withAnimation(AppMotionTokens.reveal.delay(delay)) {
                    isVisible = true
                }
            }
    }
}

private struct AppNumericTransitionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : AppMotionTokens.stateChange, value: value)
    }
}

extension View {
    func appMotionEntrance(delay: TimeInterval = 0, distance: CGFloat = 8) -> some View {
        modifier(AppMotionEntranceModifier(delay: delay, distance: distance))
    }

    func appNumericTransition<Value: Equatable>(value: Value) -> some View {
        modifier(AppNumericTransitionModifier(value: value))
    }
}

struct ResponsivePlainButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private let pressedScale: CGFloat = 0.99
    private let pressedBrightness: Double = -0.045

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .brightness(configuration.isPressed ? pressedBrightness : 0)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(
                reduceMotion ? nil : AppMotionTokens.press,
                value: configuration.isPressed
            )
    }
}

private struct AppSelectableRowSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let isSelected: Bool
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(
                    cornerRadius: AppDesignTokens.Layout.rowRadius,
                    style: .continuous
                )
                .fill(rowBackground)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppDesignTokens.Layout.rowRadius,
                    style: .continuous
                )
                .strokeBorder(borderColor, lineWidth: isFocused ? 2 : 1)
            }
            .animation(
                reduceMotion ? nil : AppMotionTokens.stateChange,
                value: isSelected
            )
            .animation(
                reduceMotion ? nil : AppMotionTokens.stateChange,
                value: isFocused
            )
    }

    private var rowBackground: Color {
        guard isSelected else { return AppDesignTokens.Palette.secondaryBackground }
        if colorScheme == .light {
            return AppAppearanceColors.selectedScopeSurface
        }
        return AppAppearanceColors.selectedSurface
    }

    private var borderColor: Color {
        if isFocused {
            return AppDesignTokens.Palette.focus
        }
        if isSelected {
            if colorScheme == .light {
                return AppAppearanceColors.controlAccent.opacity(
                    colorSchemeContrast == .increased ? 0.90 : 0.55
                )
            }
            return AppAppearanceColors.controlAccent.opacity(
                colorSchemeContrast == .increased ? 0.90 : 0.70
            )
        }
        return AppDesignTokens.Palette.separator.opacity(0.55)
    }
}

extension View {
    func appSelectableRowSurface(isSelected: Bool, isFocused: Bool) -> some View {
        modifier(
            AppSelectableRowSurfaceModifier(
                isSelected: isSelected,
                isFocused: isFocused
            )
        )
    }
}
