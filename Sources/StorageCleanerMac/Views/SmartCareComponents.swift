import Foundation
import SwiftUI

enum SmartCareHeroMode: Equatable {
    case ready
    case scanning
    case complete(score: Int)
}

struct SmartCareHeroVisual: View {
    let mode: SmartCareHeroMode

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: statusSymbol)
                .symbolRenderingMode(.hierarchical)
                .font(AppDesignTokens.Typography.heroTitle)
                .foregroundStyle(heroTint)

            if let completedScore {
                Text("\(completedScore)")
                    .font(AppDesignTokens.Typography.heroTitle)
                    .monospacedDigit()
                    .appNumericTransition(value: completedScore)
            }

            Text(statusTitle)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)

            if mode == .scanning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(heroTint)
                    .frame(maxWidth: 160)
                    .accessibilityLabel(statusTitle)
            }
        }
        .frame(maxWidth: 180)
        .accessibilityHidden(true)
    }

    private var completedScore: Int? {
        if case .complete(let score) = mode {
            return score
        }
        return nil
    }

    private var statusSymbol: String {
        switch mode {
        case .ready:
            "waveform.path.ecg"
        case .scanning:
            "scope"
        case .complete:
            "checkmark.seal.fill"
        }
    }

    private var statusTitle: String {
        switch mode {
        case .ready:
            L10n.text("智能关怀", "Smart Care")
        case .scanning:
            L10n.text("正在分析", "Analyzing")
        case .complete:
            L10n.text("存储评分", "Storage Score")
        }
    }

    private var heroTint: Color {
        switch mode {
        case .ready:
            AppDesignTokens.Palette.primary
        case .scanning:
            AppDesignTokens.Palette.information
        case .complete:
            AppDesignTokens.Palette.success
        }
    }

}

struct SmartCareGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedProgress: CGFloat = 0

    let score: Int?
    let tint: Color
    let label: String

    private var normalizedScore: CGFloat {
        CGFloat(min(100, max(0, score ?? 0))) / 100
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: score == nil ? "waveform.path.ecg" : "checkmark.seal.fill")
                .symbolRenderingMode(.hierarchical)
                .font(AppDesignTokens.Typography.sectionTitle)
                .foregroundStyle(tint)

            if let score {
                Text("\(score)")
                    .font(AppDesignTokens.Typography.heroTitle)
                    .monospacedDigit()
                    .appNumericTransition(value: score)
            } else {
                Text("--")
                    .font(AppDesignTokens.Typography.heroTitle)
                    .foregroundStyle(.secondary)
            }

            Text(label)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)

            ProgressView(value: Double(renderedProgress), total: 1)
                .progressViewStyle(.linear)
                .tint(score == nil ? .secondary : tint)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(score.map(String.init) ?? L10n.text("尚未扫描", "Not scanned"))
        .task(id: normalizedScore) {
            guard AppMotionPolicy.shouldAnimate(reduceMotion: reduceMotion) else {
                renderedProgress = normalizedScore
                return
            }

            if renderedProgress == 0 {
                await Task.yield()
            }
            withAnimation(AppMotionTokens.progress) {
                renderedProgress = normalizedScore
            }
        }
    }
}

struct SmartCareMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: systemImage)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(AppDesignTokens.Typography.dataValue)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .appNumericTransition(value: value)

                Text(title)
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// A single, flat empty-state treatment for task pages.
///
/// The surrounding page owns scrolling and background material. Keeping this
/// view free of cards, borders and blur avoids creating a second visual shell
/// inside native macOS content surfaces.
enum AppEmptyStateDensity {
    case workspace
    case inline
}

struct AppStateIconRing: View {
    @Environment(\.colorScheme) private var colorScheme

    let systemImage: String
    var tint = AppDesignTokens.Palette.information
    var size: CGFloat = 168
    var progress: Double? = nil
    var isActive = false

    private var trackWidth: CGFloat {
        max(6, size * 0.095)
    }

    private var progressWidth: CGFloat {
        max(4, size * 0.06)
    }

    private var renderedProgress: CGFloat {
        CGFloat(min(1, max(0, progress ?? 0)))
    }

    var body: some View {
        Group {
            if progress != nil {
                ZStack {
                    Circle()
                        .fill(tint.opacity(colorScheme == .dark ? 0.10 : 0.05))
                    Circle()
                        .stroke(tint.opacity(0.10), lineWidth: trackWidth)
                    Circle()
                        .trim(from: 0, to: renderedProgress)
                        .stroke(
                            tint.gradient,
                            style: StrokeStyle(lineWidth: progressWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: size * AppDesignTokens.Icon.stateRingGlyphRatio, weight: .medium))
                        .foregroundStyle(tint)
                }
            } else if isActive {
                ProgressView()
                    .controlSize(.regular)
                    .tint(tint)
            } else {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: progress == nil ? 32 : size, height: progress == nil ? 32 : size)
        .accessibilityHidden(true)
    }
}

struct AppEmptyState<Action: View>: View {
    let title: String
    let detail: String?
    let systemImage: String
    let density: AppEmptyStateDensity
    let isLoading: Bool
    private let action: Action

    init(
        title: String,
        detail: String? = nil,
        systemImage: String,
        density: AppEmptyStateDensity = .workspace,
        isLoading: Bool = false,
        @ViewBuilder action: () -> Action
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.density = density
        self.isLoading = isLoading
        self.action = action()
    }

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.medium) {
            AppStateIconRing(systemImage: systemImage, isActive: isLoading)

            VStack(spacing: AppDesignTokens.Spacing.compact) {
                Text(title)
                    .font(AppDesignTokens.Typography.emptyStateTitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppDesignTokens.Typography.emptyStateDetail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            action
                .padding(.top, AppDesignTokens.Spacing.compact)
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
        .padding(.vertical, density == .workspace ? AppDesignTokens.Spacing.section : AppDesignTokens.Spacing.large)
        .frame(maxWidth: density == .workspace ? 420 : 520)
        .frame(
            maxWidth: .infinity,
            minHeight: density == .workspace ? 220 : 150,
            maxHeight: density == .workspace ? .infinity : nil,
            alignment: .center
        )
    }
}

extension AppEmptyState where Action == EmptyView {
    init(
        title: String,
        detail: String? = nil,
        systemImage: String,
        density: AppEmptyStateDensity = .workspace,
        isLoading: Bool = false
    ) {
        self.init(
            title: title,
            detail: detail,
            systemImage: systemImage,
            density: density,
            isLoading: isLoading
        ) {
            EmptyView()
        }
    }
}

struct AppPageHeader<Actions: View>: View {
    @Environment(\.moduleTheme) private var moduleTheme
    @Environment(\.windowLayoutMetrics) private var layout

    let title: String
    let subtitle: String?
    let systemImage: String
    var isHero = false
    @ViewBuilder let actions: Actions

    var body: some View {
        Group {
            if isHero {
                HStack(spacing: 12) {
                    titleBlock
                    Spacer(minLength: 0)
                    actionBlock
                }
            } else if layout.density == .compact {
                verticalLayout
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalLayout
                    verticalLayout
                }
            }
        }
        .padding(.vertical, AppDesignTokens.Spacing.medium)
        .frame(
            maxWidth: .infinity,
            minHeight: AppDesignTokens.Layout.modulePageHeaderMinimumHeight,
            alignment: .leading
        )
        .overlay(alignment: .bottom) {
            if !moduleTheme.isImmersive {
                Divider()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var titleBlock: some View {
        let tint = moduleTheme.isImmersive
            ? moduleTheme.accent
            : AppDesignTokens.Palette.accent
        return HStack(alignment: .center, spacing: AppDesignTokens.Spacing.large) {
            if isHero && moduleTheme.isImmersive {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: layout.isShort ? 36 : 44, weight: .medium))
                    .foregroundStyle(systemImage == ReviewFilter.updater.systemImage ? Color.cyan : tint)
                    .frame(width: layout.isShort ? 64 : GoldenLandingMetrics.headerIconSide(for: systemImage), height: layout.isShort ? 64 : GoldenLandingMetrics.headerIconSide(for: systemImage))
                    .background(
                        LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(tint.opacity(0.48), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            } else {
                AppSymbolIcon(
                    systemImage: systemImage,
                    role: .pageFeature,
                    tint: tint,
                    isDecorative: true
                )
            }

            VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textTightSpacing) {
                Text(title)
                    .font(isHero ? .system(size: layout.isShort ? 26 : GoldenLandingMetrics.headerTitleSize(for: systemImage), weight: .semibold) : AppTypography.pageTitle)
                    .foregroundStyle(
                        moduleTheme.isImmersive ? moduleTheme.primaryText : AppDesignTokens.Palette.primaryText
                    )
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppDesignTokens.Typography.pageSubtitle)
                        .foregroundStyle(
                            moduleTheme.isImmersive ? moduleTheme.secondaryText : AppDesignTokens.Palette.secondaryText
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
        }
    }

    private var actionBlock: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                actions
            }

            VStack(alignment: .trailing, spacing: AppDesignTokens.Spacing.small) {
                actions
            }
        }
        .font(AppDesignTokens.Typography.toolbar)
        .controlSize(.regular)
        .frame(
            minHeight: AppControlSizes.iconHitRegion,
            alignment: .trailing
        )
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: AppDesignTokens.Spacing.large) {
            titleBlock
            Spacer(minLength: AppDesignTokens.Spacing.medium)
            actionBlock
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            titleBlock
            actionBlock
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct TaskSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var isFocused: Bool

    let placeholder: String
    @Binding var text: String
    let tint: Color
    var focus: FocusState<Bool>.Binding? = nil

    private var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var focusBinding: FocusState<Bool>.Binding {
        focus ?? $isFocused
    }

    private var hasFocus: Bool {
        focus?.wrappedValue ?? isFocused
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(tint)

            TextField(placeholder, text: $text)
                .font(AppDesignTokens.Typography.body)
                .textFieldStyle(.plain)
                .focused(focusBinding)
                .onExitCommand {
                    guard hasQuery else { return }
                    text = ""
                }

            if hasQuery {
                AppIconButton(
                    title: L10n.text("清除搜索", "Clear Search"),
                    systemImage: "xmark.circle.fill",
                    kind: .toolbar,
                    tint: AppDesignTokens.Palette.secondaryText
                ) {
                    text = ""
                }
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, 5)
        .background(searchFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    hasFocus
                        ? Color(nsColor: .keyboardFocusIndicatorColor)
                        : Color.primary.opacity(0.08),
                    lineWidth: hasFocus ? 2 : 1
                )
        }
    }

    private var searchFill: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        return AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.060 : 0.034))
    }
}
