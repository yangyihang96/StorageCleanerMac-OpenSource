import SwiftUI

/// The single button vocabulary used by the main window, sheets and menu-bar
/// panels. Native Button, Menu and focus behavior remain intact; this type only
/// selects the appropriate macOS emphasis and density.
enum AppButtonKind: Equatable {
    case primary
    case secondary
    case tertiary
    case destructive
    case toolbar
    case icon
    case glass
    case glassProminent
    case menu
    case disclosure
    case smallUtility
    case metric
}

private struct AppButtonChromeModifier: ViewModifier {
    let kind: AppButtonKind
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 9))
        } else {
            switch kind {
            case .primary, .glassProminent:
                content
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 9))
            case .secondary, .glass:
                content
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
            case .smallUtility:
                content
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            case .destructive:
                content
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .tint(AppDesignTokens.Palette.destructive)
            case .tertiary, .toolbar, .icon, .menu, .disclosure:
                content.buttonStyle(.borderless)
            case .metric:
                content.buttonStyle(.plain)
            }
        }
    }
}

extension View {
    func appButtonChrome(
        _ kind: AppButtonKind,
        isSelected: Bool = false
    ) -> some View {
        modifier(AppButtonChromeModifier(kind: kind, isSelected: isSelected))
    }
}

private struct AdaptiveAppButtonLabel: View {
    let title: String
    let systemImage: String?
    let kind: AppButtonKind
    let isLoading: Bool
    let allowsIconOnlyFallback: Bool

    @ViewBuilder
    var body: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .font(AppDesignTokens.Typography.button)
        } else if let systemImage {
            if allowsIconOnlyFallback {
                ViewThatFits(in: .horizontal) {
                    fullLabel(systemImage: systemImage)
                    titleOnlyLabel

                    Label(title, systemImage: systemImage)
                        .labelStyle(.iconOnly)
                }
                .font(AppDesignTokens.Typography.button)
            } else {
                ViewThatFits(in: .horizontal) {
                    fullLabel(systemImage: systemImage)
                    titleOnlyLabel
                    wrappedTitleLabel
                }
                .font(AppDesignTokens.Typography.button)
            }
        } else {
            wrappedTitleLabel
                .font(AppDesignTokens.Typography.button)
        }
    }

    private func fullLabel(systemImage: String) -> some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            actionIcon(systemImage: systemImage)

            Text(title)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func actionIcon(systemImage: String) -> some View {
        switch kind {
        case .primary, .glassProminent:
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(
                    AppDesignTokens.Palette.onAccent.opacity(0.16),
                    in: Circle()
                )
                .accessibilityHidden(true)
        case .secondary, .glass, .destructive:
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
        case .tertiary, .toolbar, .icon, .menu, .disclosure, .smallUtility, .metric:
            Image(systemName: systemImage)
                .accessibilityHidden(true)
        }
    }

    private var titleOnlyLabel: some View {
        Text(title)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var wrappedTitleLabel: some View {
        Text(title)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AppButton: View {
    @Environment(\.moduleTheme) private var moduleTheme

    let title: String
    var systemImage: String? = nil
    var kind: AppButtonKind = .secondary
    var tint: Color? = nil
    var controlSize: ControlSize = .regular
    var fillsWidth = false
    var isLoading = false
    var isDisabled = false
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(role: buttonRole, action: action) {
            AdaptiveAppButtonLabel(
                title: title,
                systemImage: systemImage,
                kind: kind,
                isLoading: isLoading,
                allowsIconOnlyFallback: allowsIconOnlyFallback
            )
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .appButtonChrome(kind)
        .controlSize(controlSize)
        .frame(minHeight: AppControlSizes.minimumControlHeight)
        .tint(resolvedTint)
        .disabled(isDisabled || isLoading)
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(
            isLoading ? L10n.text("正在处理", "In progress") : ""
        )
    }

    private var buttonRole: ButtonRole? {
        kind == .destructive ? .destructive : nil
    }

    private var resolvedTint: Color? {
        if let tint { return tint }
        switch kind {
        case .primary, .glassProminent:
            return moduleTheme.featureGroup == .settings
                ? AppDesignTokens.Palette.accent
                : moduleTheme.actionFill
        case .destructive:
            return AppDesignTokens.Palette.destructive
        default:
            return nil
        }
    }

    private var allowsIconOnlyFallback: Bool {
        switch kind {
        case .toolbar, .icon, .smallUtility:
            true
        default:
            false
        }
    }
}

/// Icon-only actions always require a spoken title and tooltip. The glyph stays
/// compact while the shared interaction region preserves a reliable pointer
/// target and native keyboard focus ring.
struct AppIconButton: View {
    let title: String
    let systemImage: String
    var kind: AppButtonKind = .icon
    var tint: Color? = nil
    var controlSize: ControlSize = .small
    var isSelected = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(role: buttonRole, action: action) {
            AppSymbolIcon(
                systemImage: systemImage,
                role: .toolbar,
                tint: tint ?? AppDesignTokens.Palette.secondaryText
            )
        }
        .appButtonChrome(kind, isSelected: isSelected)
        .controlSize(controlSize)
        .frame(
            minWidth: AppControlSizes.iconHitRegion,
            minHeight: AppControlSizes.iconHitRegion
        )
        .contentShape(Rectangle())
        .tint(tint)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var buttonRole: ButtonRole? {
        kind == .destructive ? .destructive : nil
    }
}

struct AppSelectionButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var showsTitle = true
    var controlSize: ControlSize = .small
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if showsTitle {
                AdaptiveAppButtonLabel(
                    title: title,
                    systemImage: systemImage,
                    kind: .toolbar,
                    isLoading: false,
                    allowsIconOnlyFallback: false
                )
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
            } else {
                AppSymbolIcon(
                    systemImage: systemImage,
                    role: .panelNavigation,
                    tint: isSelected
                        ? AppDesignTokens.Palette.onAccent
                        : AppDesignTokens.Palette.secondaryText
                )
            }
        }
        .appButtonChrome(isSelected ? .primary : .toolbar, isSelected: isSelected)
        .controlSize(controlSize)
        .frame(
            minWidth: showsTitle ? nil : AppControlSizes.iconHitRegion,
            minHeight: showsTitle ? nil : AppControlSizes.iconHitRegion
        )
        .contentShape(Rectangle())
        .tint(isSelected ? AppDesignTokens.Palette.accent : nil)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(
            isSelected ? L10n.text("已选择", "Selected") : ""
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AppFilterButton: View {
    @Environment(\.windowLayoutMetrics) private var layout

    let title: String
    let systemImage: String
    let count: Int
    let isSelected: Bool
    let minimumWidth: CGFloat?
    let action: () -> Void

    init(
        title: String,
        systemImage: String,
        count: Int,
        isSelected: Bool,
        minimumWidth: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.isSelected = isSelected
        self.minimumWidth = minimumWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                countedLabel(showsIcon: true, wrapsTitle: false)
                countedLabel(showsIcon: false, wrapsTitle: false)
                countedLabel(showsIcon: false, wrapsTitle: true)
            }
            .font(AppDesignTokens.Typography.secondary)
            .frame(minWidth: layout.density == .compact ? nil : minimumWidth)
        }
        .appButtonChrome(.glass, isSelected: isSelected)
        .controlSize(.regular)
        .tint(isSelected ? AppDesignTokens.Palette.accent : nil)
        .accessibilityLabel(L10n.text("\(title)，\(count) 项", "\(title), \(count) items"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func countedLabel(showsIcon: Bool, wrapsTitle: Bool) -> some View {
        HStack(spacing: AppDesignTokens.Spacing.compact) {
            if showsIcon {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }

            Text(title)
                .lineLimit(wrapsTitle ? nil : 1)
                .fixedSize(horizontal: !wrapsTitle, vertical: true)

            Text("(\(count))")
                .monospacedDigit()
                .appNumericTransition(value: count)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: !wrapsTitle, vertical: true)
    }
}

struct AppMenuButton<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            AdaptiveAppButtonLabel(
                title: title,
                systemImage: systemImage,
                kind: .menu,
                isLoading: false,
                allowsIconOnlyFallback: true
            )
        }
        .appButtonChrome(.menu)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct AppDisclosureButton: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            AdaptiveAppButtonLabel(
                title: title,
                systemImage: isExpanded ? "chevron.down" : "chevron.right",
                kind: .disclosure,
                isLoading: false,
                allowsIconOnlyFallback: false
            )
        }
        .appButtonChrome(.disclosure)
        .accessibilityLabel(title)
        .accessibilityValue(
            isExpanded ? L10n.text("已展开", "Expanded") : L10n.text("已收起", "Collapsed")
        )
    }
}

#if DEBUG
private struct AppControlsPreview: View {
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            AppButton(title: "开始扫描", systemImage: "play.fill", kind: .primary) {}
            AppButton(title: "取消", kind: .secondary) {}
            AppButton(title: "删除项目", systemImage: "trash", kind: .destructive) {}
            AppIconButton(title: "刷新", systemImage: "arrow.clockwise") {}
            AppDisclosureButton(title: "显示详情", isExpanded: $isExpanded)
        }
        .padding()
        .frame(width: 280)
    }
}

struct AppControls_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AppControlsPreview()
                .preferredColorScheme(.light)
            AppControlsPreview()
                .preferredColorScheme(.dark)
        }
    }
}
#endif
