import AppKit
import SwiftUI

enum GlassPanelProminence {
    case quiet
    case regular
    case prominent
}

private struct ScrollSafeGlassKey: EnvironmentKey {
    static let defaultValue = false
}

private struct GlassSurfaceDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var scrollSafeGlass: Bool {
        get { self[ScrollSafeGlassKey.self] }
        set { self[ScrollSafeGlassKey.self] = newValue }
    }
}

private extension EnvironmentValues {
    var glassSurfaceDepth: Int {
        get { self[GlassSurfaceDepthKey.self] }
        set { self[GlassSurfaceDepthKey.self] = newValue }
    }
}

private struct GlassPanelModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.glassSurfaceDepth) private var glassSurfaceDepth
    @Environment(\.moduleTheme) private var moduleTheme

    let cornerRadius: CGFloat
    let tint: Color?
    let elevated: Bool
    let prominence: GlassPanelProminence
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let preparedContent = content.environment(\.glassSurfaceDepth, glassSurfaceDepth + 1)

        if glassSurfaceDepth > 0 {
            preparedContent
        } else {
            // Content cards, tables and editors stay opaque and legible. The
            // only true material carrier is the floating popover chrome below.
            decorated(
                preparedContent
                    .background(
                        (tint ?? .clear).opacity(tintOpacity),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .background(
                        panelBackground,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    ),
                showsBorder: true
            )
        }
    }

    private func decorated<Panel: View>(
        _ panel: Panel,
        showsBorder: Bool
    ) -> some View {
        panel
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                }
            }
            .shadow(
                color: AppDesignTokens.Elevation.contentShadow(
                    elevated: elevated,
                    colorScheme: colorScheme,
                    opacityInDark: 0.10,
                    opacityInLight: 0.035
                ),
                radius: elevated ? 5 : 0,
                y: elevated ? 1 : 0
            )
    }

    private var tintOpacity: Double {
        guard colorSchemeContrast != .increased else { return 0 }
        return switch prominence {
        case .quiet: 0.035
        case .regular: 0.055
        case .prominent: 0.075
        }
    }

    private var borderColor: Color {
        let base = colorSchemeContrast == .increased
            ? (moduleTheme.isImmersive ? AppAppearanceColors.ink : Color.primary)
            : (tint ?? moduleTheme.accent)
        return base.opacity(borderOpacity)
    }

    private var panelBackground: Color {
        guard moduleTheme.isImmersive else {
            return Color(nsColor: .controlBackgroundColor)
        }
        return moduleTheme.panelFill(
            for: colorScheme,
            reduceTransparency: reduceTransparency
        )
    }

    private var borderOpacity: Double {
        if colorSchemeContrast == .increased {
            return colorScheme == .dark ? 0.34 : 0.20
        }
        return switch prominence {
        case .quiet:
            colorScheme == .dark ? 0.14 : 0.075
        case .regular:
            colorScheme == .dark ? 0.19 : 0.095
        case .prominent:
            colorScheme == .dark ? 0.24 : 0.12
        }
    }
}

private struct GlassCapsuleModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.glassSurfaceDepth) private var glassSurfaceDepth
    @Environment(\.moduleTheme) private var moduleTheme

    let tint: Color?
    let elevated: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let preparedContent = content.environment(\.glassSurfaceDepth, glassSurfaceDepth + 1)

        if glassSurfaceDepth > 0 {
            preparedContent
        } else {
            decorated(
                preparedContent
                    .background(
                        (tint ?? .clear).opacity(colorSchemeContrast == .increased ? 0 : 0.045),
                        in: Capsule(style: .continuous)
                    )
                    .background(
                        capsuleBackground,
                        in: Capsule(style: .continuous)
                    ),
                showsBorder: true
            )
        }
    }

    private func decorated<CapsuleContent: View>(
        _ capsule: CapsuleContent,
        showsBorder: Bool
    ) -> some View {
        capsule
            .overlay {
                if showsBorder {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            (tint ?? Color.primary).opacity(
                                colorSchemeContrast == .increased
                                    ? (colorScheme == .dark ? 0.34 : 0.20)
                                    : (colorScheme == .dark ? 0.16 : 0.08)
                            ),
                            lineWidth: 1
                        )
                }
            }
            .shadow(
                color: AppDesignTokens.Elevation.contentShadow(
                    elevated: elevated,
                    colorScheme: colorScheme,
                    opacityInDark: 0.14,
                    opacityInLight: 0.045
                ),
                radius: elevated ? 6 : 0,
                y: elevated ? 2 : 0
            )
    }

    private var capsuleBackground: Color {
        guard moduleTheme.isImmersive else {
            return Color(nsColor: .controlBackgroundColor)
        }
        return moduleTheme.panelFill(
            for: colorScheme,
            reduceTransparency: reduceTransparency
        )
    }
}

private struct AppGlassSegmentedControlModifier: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .pickerStyle(.segmented)
            .tint(tint)
    }
}

private struct GlassEffectGroupModifier: ViewModifier {
    let spacing: CGFloat?

    func body(content: Content) -> some View {
        content
    }
}

struct GlassAppBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}

private struct ChartTooltipSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(
                        cornerRadius: AppDesignTokens.Layout.rowRadius,
                        style: .continuous
                    )
                    .fill(AppDesignTokens.Palette.secondaryBackground)
                } else {
                    RoundedRectangle(
                        cornerRadius: AppDesignTokens.Layout.rowRadius,
                        style: .continuous
                    )
                    .fill(.regularMaterial)
                }
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppDesignTokens.Layout.rowRadius,
                    style: .continuous
                )
                    .strokeBorder(AppDesignTokens.Palette.separator, lineWidth: 1)
            }
            .shadow(color: AppDesignTokens.Elevation.floatingShadow, radius: 5, y: 2)
    }
}

private struct AdaptivePopoverChromeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.panelBackgroundTint) private var panelBackgroundTint

    let cornerRadii: RectangleCornerRadii

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    panelShape
                        .fill(AppDesignTokens.Palette.contentBackground)
                    if let panelBackgroundTint {
                        panelShape
                            .fill(panelBackgroundTint)
                    }
                    panelShape
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                }
            }
            .clipShape(panelShape)
    }

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
    }

    private var borderColor: Color {
        colorSchemeContrast == .increased
            ? AppDesignTokens.Palette.primaryText
            : AppDesignTokens.Palette.separator
    }

    private var borderWidth: CGFloat {
        colorSchemeContrast == .increased || reduceTransparency ? 1 : 0.5
    }
}

struct GlassVisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassthroughVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
    }
}

private final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct WindowGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        // Compatibility shim while the call site moves fully to the native
        // SwiftUI scene and toolbar configuration. Intentionally avoid
        // mutating NSWindow so macOS can restore its chrome, size and position.
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

final class PassthroughWindowConfigurationView: NSView {
    private var configuration: (NSWindow) -> Void
    private var configurationIsScheduled = false

    init(configuration: @escaping (NSWindow) -> Void) {
        self.configuration = configuration
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateConfiguration(_ configuration: @escaping (NSWindow) -> Void) {
        self.configuration = configuration
        scheduleConfiguration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    private func scheduleConfiguration() {
        guard window != nil, !configurationIsScheduled else { return }
        configurationIsScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configurationIsScheduled = false
            guard let window = self.window else { return }
            self.configuration(window)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension View {
    func glassPanel(
        cornerRadius: CGFloat = 8,
        tint: Color? = nil,
        elevated: Bool = false,
        prominence: GlassPanelProminence = .regular,
        interactive: Bool = false
    ) -> some View {
        modifier(
            GlassPanelModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                elevated: elevated,
                prominence: prominence,
                interactive: interactive
            )
        )
    }

    func glassCapsule(tint: Color? = nil, elevated: Bool = false) -> some View {
        modifier(GlassCapsuleModifier(tint: tint, elevated: elevated))
    }

    /// Supplies exactly one visible carrier for the app's transparent
    /// borderless menu-bar panel, with a material fallback on macOS 14–15.
    func adaptivePopoverChrome(cornerRadius: CGFloat = 12) -> some View {
        adaptivePopoverChrome(
            cornerRadii: RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        )
    }

    func adaptivePopoverChrome(cornerRadii: RectangleCornerRadii) -> some View {
        modifier(AdaptivePopoverChromeModifier(cornerRadii: cornerRadii))
    }

    /// A single shared material surface for transient chart hover content.
    /// It remains flat when Reduce Transparency is enabled.
    func appChartTooltipSurface() -> some View {
        modifier(ChartTooltipSurfaceModifier())
    }

    /// Keeps segmented choices visually attached to the same glass language as
    /// cards and action buttons while retaining the native Picker behavior.
    func appGlassSegmentedControl(tint: Color = .accentColor) -> some View {
        modifier(AppGlassSegmentedControlModifier(tint: tint))
    }

    /// Groups nearby glass surfaces so macOS can render their material and
    /// transitions as one coherent family.
    func glassEffectGroup(spacing: CGFloat? = nil) -> some View {
        modifier(GlassEffectGroupModifier(spacing: spacing))
    }
}
