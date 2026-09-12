import SwiftUI

enum AppMotionPolicy {
    static func shouldAnimate(reduceMotion: Bool, isActive: Bool = true) -> Bool {
        isActive && !reduceMotion
    }
}

enum AppMotionTokens {
    // Keep motion quiet and predictable across the app. Controls use the
    // short interaction curve; navigation and state changes share one system-
    // like ease rather than introducing page-specific springs or bounce.
    private static let interaction = Animation.easeOut(duration: 0.15)
    private static let state = Animation.easeInOut(duration: 0.20)
    private static let page = Animation.easeInOut(duration: 0.22)

    static let press = interaction
    static let hover = interaction
    static let navigation = page
    static let reveal = Animation.timingCurve(0.22, 0.74, 0.24, 1, duration: 0.34)
    static let stateChange = state
    static let feedback = state
    static let progress = Animation.easeInOut(duration: 0.28)
    static let reduced = Animation.easeOut(duration: 0.12)

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    static func pageTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: AppPageTransitionModifier(
                    opacity: 0,
                    verticalOffset: 8
                ),
                identity: AppPageTransitionModifier(
                    opacity: 1,
                    verticalOffset: 0
                )
            ),
            removal: .modifier(
                active: AppPageTransitionModifier(
                    opacity: 0,
                    verticalOffset: -4
                ),
                identity: AppPageTransitionModifier(
                    opacity: 1,
                    verticalOffset: 0
                )
            )
        )
    }

    static func stateTransition(reduceMotion: Bool, edge: Edge = .top) -> AnyTransition {
        .opacity
    }

    static func listTransition(reduceMotion: Bool) -> AnyTransition {
        .opacity
    }
}

private struct AppPageTransitionModifier: ViewModifier {
    let opacity: Double
    let verticalOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: verticalOffset)
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
        let opacity = colorSchemeContrast == .increased
            ? (colorScheme == .dark ? 0.38 : 0.24)
            : (colorScheme == .dark ? 0.28 : 0.16)
        return AppDesignTokens.Palette.selection.opacity(opacity)
    }

    private var borderColor: Color {
        if isFocused {
            return AppDesignTokens.Palette.focus
        }
        if isSelected {
            return AppDesignTokens.Palette.selection.opacity(0.70)
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
