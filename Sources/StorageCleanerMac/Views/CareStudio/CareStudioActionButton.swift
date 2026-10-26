import SwiftUI

/// The round main button at the bottom of every studio page (CleanMyMac:
/// Scan → Stop with a progress ring → Run / Clean). It is the only primary
/// action on a page; review and secondary actions live in the content.
struct CareStudioActionButton: View {
    enum Progress: Equatable {
        case none
        case indeterminate
        case fraction(Double)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    let module: CareStudioModule
    let title: String
    var progress: Progress = .none
    var isProminent = true
    var accessibilityHint: String? = nil
    /// The page's whole action when the circle shows only its verb.
    var fullTitle: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(CareStudioActionButtonStyle(module: module, isHovered: isHovered,
                                                 isEnabled: isEnabled, reduceMotion: reduceMotion))
        .onHover { isHovered = $0 }
        .frame(width: CareStudioMetrics.actionDiameter + 2 * (CareStudioMetrics.actionRingGap + CareStudioMetrics.actionRingWidth),
               height: CareStudioMetrics.actionDiameter + 2 * (CareStudioMetrics.actionRingGap + CareStudioMetrics.actionRingWidth))
        .background { halo }
        .overlay { ring }
        .accessibilityLabel(fullTitle ?? title)
        .help(fullTitle ?? "")
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityValue(progressAccessibilityValue)
#if DEBUG
        .layoutProbe("careStudio.action")
#endif
    }

    private var label: some View {
        // Longer English titles ("Preparing", "Stopping") take the smaller
        // size so every title fits the 84 pt circle on one line.
        Text(title)
            .font(.system(size: title.count >= 8 ? 14 : 16, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: CareStudioMetrics.actionDiameter, height: CareStudioMetrics.actionDiameter)
            .contentShape(Circle())
    }

    /// Warm and cool light behind the button.
    private var halo: some View {
        let palette = module.palette
        return ZStack {
            Circle()
                .fill(CareStudioPalette.color(palette.halo[0], opacity: isEnabled ? 0.42 : 0.18))
                .frame(width: CareStudioMetrics.actionDiameter * 1.25)
                .offset(x: -14, y: 6)
                .blur(radius: 22)
            Circle()
                .fill(CareStudioPalette.color(palette.halo[1], opacity: isEnabled ? 0.38 : 0.16))
                .frame(width: CareStudioMetrics.actionDiameter * 1.2)
                .offset(x: 16, y: -2)
                .blur(radius: 22)
            Circle()
                .fill(CareStudioPalette.color(palette.actionGlow,
                                              opacity: CareStudioActionButtonLook.glowOpacity(isHovered: isHovered,
                                                                                              isEnabled: isEnabled)))
                .frame(width: CareStudioMetrics.actionDiameter * 1.05)
                .blur(radius: 14)
        }
        .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isHovered)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ring: some View {
        let side = CareStudioMetrics.actionDiameter + 2 * CareStudioMetrics.actionRingGap + CareStudioMetrics.actionRingWidth
        switch progress {
        case .none:
            EmptyView()
        case .fraction(let value):
            ZStack {
                Circle().stroke(CareStudioInk.hairline, lineWidth: CareStudioMetrics.actionRingWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0.02, value))))
                    .stroke(CareStudioInk.primary, style: StrokeStyle(lineWidth: CareStudioMetrics.actionRingWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: value)
            }
            .frame(width: side, height: side)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        case .indeterminate:
            CareStudioSpinningArc(diameter: side, lineWidth: CareStudioMetrics.actionRingWidth)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var progressAccessibilityValue: String {
        switch progress {
        case .none: ""
        case .indeterminate: L10n.text("进行中", "In progress")
        case .fraction(let value): "\(Int((min(1, max(0, value)) * 100).rounded()))%"
        }
    }
}

private struct CareStudioActionButtonStyle: ButtonStyle {
    let module: CareStudioModule
    let isHovered: Bool
    let isEnabled: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let palette = module.palette
        return configuration.label
            .background {
                Circle()
                    .fill(LinearGradient(
                        colors: [CareStudioPalette.color(palette.action[0]),
                                 CareStudioPalette.color(palette.action[1])],
                        startPoint: .top, endPoint: .bottom))
                    .overlay {
                        // Glass rim and top highlight.
                        Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
                        Circle()
                            .fill(LinearGradient(colors: [Color.white.opacity(0.30), .clear],
                                                 startPoint: .top, endPoint: .center))
                            .padding(3)
                    }
                    .shadow(color: CareStudioPalette.color(palette.deep, opacity: 0.45), radius: 10, y: 6)
            }
            .brightness(CareStudioActionButtonLook.brightness(isHovered: isHovered, isPressed: configuration.isPressed,
                                                              isEnabled: isEnabled))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(CareStudioActionButtonLook.scale(isPressed: configuration.isPressed, isEnabled: isEnabled,
                                                          reduceMotion: reduceMotion))
            .animation(AppMotion.resolved(.press, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isHovered)
    }
}

/// D154 batch 3P: how every round button answers the pointer (CleanMyMac's
/// main button: the glow behind it brightens on hover, the button sinks a
/// little when pressed). A disabled button does neither; under Reduce Motion
/// a press only darkens it. Was: a hover grew the button to 1.03 (disabled
/// ones too) and the glow changed at once.
enum CareStudioActionButtonLook {
    static func glowOpacity(isHovered: Bool, isEnabled: Bool) -> Double {
        isEnabled && isHovered ? 0.6 : 0.35
    }

    static func brightness(isHovered: Bool, isPressed: Bool, isEnabled: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isPressed { return -0.05 }
        return isHovered ? 0.06 : 0
    }

    static func scale(isPressed: Bool, isEnabled: Bool, reduceMotion: Bool) -> CGFloat {
        isEnabled && isPressed && !reduceMotion ? 0.95 : 1
    }
}

/// A rotating arc for work without a measurable fraction.
struct CareStudioSpinningArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let angle = reduceMotion ? 0 : (context.date.timeIntervalSinceReferenceDate * 300)
                .truncatingRemainder(dividingBy: 360)
            ZStack {
                Circle().stroke(CareStudioInk.hairline, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.24)
                    .stroke(CareStudioInk.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// A small capsule button on the gradient (CleanMyMac "Review", "Review All
/// Junk", "Start Over"). `filled` is the white "Clean" variant.
struct CareStudioPillButton: View {
    let title: String
    var systemImage: String? = nil
    var filled = false
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: compact ? 11 : 12, weight: .semibold))
                }
                Text(title).font(.system(size: compact ? 12 : 13, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, compact ? 10 : 13)
            .frame(height: compact ? 26 : 30)
            .foregroundStyle(filled ? CareStudioInk.inverse : CareStudioInk.primary)
        }
        .buttonStyle(CareStudioPillStyle(filled: filled))
    }
}

private struct CareStudioPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule(style: .continuous)
                    .fill(filled ? CareStudioInk.primary.opacity(configuration.isPressed ? 0.82 : 0.96)
                          : (configuration.isPressed ? CareStudioInk.pillFillPressed : CareStudioInk.pillFill))
                    .overlay {
                        if !filled {
                            Capsule(style: .continuous).strokeBorder(CareStudioInk.hairline, lineWidth: 1)
                        }
                    }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}
