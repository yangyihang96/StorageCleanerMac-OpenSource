import SwiftUI

// MARK: - CapsuleSegmentedControl (UI-V2-SPEC 1.5, §3.2)

/// A capsule segmented control whose module-colored selection slides
/// between options (Reduce Motion: lands at once). VoiceOver and keyboard
/// users get the native segmented picker through the accessibility
/// representation. When the labels no longer fit, it becomes a menu.
struct CapsuleSegmentedControl<Value: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.moduleTheme) private var moduleTheme
    @AppSurfaces private var surfaces
    @Namespace private var namespace

    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var label: String
    var pigment: ModulePigment?
    var isOptionDisabled: (Value) -> Bool = { _ in false }
    var optionHelp: (Value) -> String? = { _ in nil }

    private var resolvedPigment: ModulePigment {
        pigment ?? (moduleTheme.isImmersive ? moduleTheme.pigment : .neutral)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            capsules
            menuFallback
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option).disabled(isOptionDisabled(option))
                }
                if !options.contains(selection) {
                    Text(title(selection)).tag(selection)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var capsules: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(surfaces.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(surfaces.divider, lineWidth: 1))
        .fixedSize()
    }

    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection
        return Button {
            withAnimation(AppMotion.selection(reduceMotion: reduceMotion)) {
                selection = option
            }
        } label: {
            Text(title(option))
                .font(isSelected ? AppDesignTokens.TypeScale.bodyEmphasis : AppDesignTokens.TypeScale.body)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: 28)
                .foregroundStyle(isSelected ? Color.white : surfaces.textSecondary)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: resolvedPigment.gradientStops,
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Capsule(style: .continuous)
                                .strokeBorder(.white.opacity(0.22), lineWidth: 1))
                            .matchedGeometryEffect(id: "capsule.selection", in: namespace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SelectionControlButtonStyle())
        .disabled(isOptionDisabled(option))
        .help(optionHelp(option) ?? title(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var menuFallback: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(title(option))
                    }
                }
                .disabled(isOptionDisabled(option))
                .help(optionHelp(option) ?? title(option))
            }
        } label: {
            Text(title(selection))
                .font(AppDesignTokens.TypeScale.bodyEmphasis)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(Capsule(style: .continuous).fill(surfaces.inset))
        .help(label)
    }
}

// MARK: - AnimatedCheckbox (UI-V2-SPEC 1.5, §3.2.4)

enum CheckboxMark: Equatable {
    case off
    case on
    case mixed
}

/// The box itself: module color (or red for destructive groups), scales and
/// draws its check when it turns on (Reduce Motion: appears at once).
struct AnimatedCheckmarkBox: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.moduleTheme) private var moduleTheme
    @Environment(\.isEnabled) private var isEnabled
    @AppSurfaces private var surfaces

    let mark: CheckboxMark
    var tint: Color?
    var side: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
        let fillColor = tint ?? (moduleTheme.isImmersive ? moduleTheme.pigment.lightStop : AppAppearanceColors.controlFill)
        let isOn = mark != .off
        ZStack {
            shape.fill(isOn ? fillColor : Color.clear)
            shape.strokeBorder(isOn ? Color.white.opacity(0.22) : surfaces.textTertiary.opacity(0.9), lineWidth: 1.2)
            CheckmarkGlyph(isMixed: mark == .mixed)
                .trim(from: 0, to: isOn ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.6, side * 0.12), lineCap: .round, lineJoin: .round))
                .padding(side * 0.22)
        }
        .frame(width: side, height: side)
        .scaleEffect(isOn && !reduceMotion ? 1 : (reduceMotion ? 1 : 0.94))
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : AppMotion.press, value: mark)
        .accessibilityHidden(true)
    }
}

private struct CheckmarkGlyph: Shape {
    let isMixed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isMixed {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.02))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08))
        }
        return path
    }
}

/// A Toggle style with the animated box. The accessibility representation
/// is the native checkbox, so VoiceOver reads and presses it as before.
struct AnimatedCheckboxToggleStyle: ToggleStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: AppDesignTokens.Grid.x1) {
                AnimatedCheckmarkBox(mark: configuration.isOn ? .on : .off, tint: tint)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SelectionControlButtonStyle())
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .toggleStyle(.checkbox)
        }
    }
}

/// The press feedback shared by the selection controls above: they draw
/// their own selected state, so the style only dims the label while it is
/// pressed (the shared button family's press cue, without a fill).
struct SelectionControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
