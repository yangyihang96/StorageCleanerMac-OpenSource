import SwiftUI

/// Presentation only. A feature supplies its existing state and measurements;
/// this layer never advances a task or estimates missing progress.
enum RuntimeWorkflowState: Equatable {
    case running, paused, stopping, completed, cancelled, attention, failed

    var isActive: Bool { self == .running || self == .stopping }
    var title: String {
        switch self {
        case .running: L10n.text("进行中", "In Progress")
        case .paused: L10n.text("已暂停", "Paused")
        case .stopping: L10n.text("正在停止", "Stopping")
        case .completed: L10n.text("已完成", "Completed")
        case .cancelled: L10n.text("已取消", "Cancelled")
        case .attention: L10n.text("需要处理", "Needs Attention")
        case .failed: L10n.text("未完成", "Not Completed")
        }
    }
    var symbol: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath"
        case .paused: "pause.fill"
        case .stopping: "stop.fill"
        case .completed: "checkmark"
        case .cancelled: "stop.fill"
        case .attention: "exclamationmark"
        case .failed: "xmark"
        }
    }
    func tint(accent: Color) -> Color {
        switch self {
        case .completed: AppDesignTokens.Palette.success
        case .attention, .paused: AppDesignTokens.Palette.warning
        case .failed: AppDesignTokens.Palette.destructive
        case .cancelled: .secondary
        case .running, .stopping: accent
        }
    }

    static func measuredFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}

struct RuntimeWorkflowMetric: Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

struct RuntimeInlineStatus: View {
    @Environment(\.moduleTheme) private var theme
    var state: RuntimeWorkflowState = .running
    let title: String
    init(state: RuntimeWorkflowState = .running, title: String, detail: String? = nil) {
        self.state = state
        self.title = title
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if state.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.symbol).font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 24, height: 24)
            .foregroundStyle(state.tint(accent: theme.actionFill))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppDesignTokens.Typography.compactLabelEmphasis)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(theme.primaryText)
        .background(state.tint(accent: theme.actionFill).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: AppDesignTokens.Layout.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: AppDesignTokens.Layout.rowRadius)
            .strokeBorder(state.tint(accent: theme.actionFill).opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct RuntimeActivityCard<Details: View>: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    let title: String
    var subtitle: String? = nil
    var state: RuntimeWorkflowState = .running
    var fraction: Double? = nil
    var metrics: [RuntimeWorkflowMetric] = []
    var currentItem: String? = nil
    @ViewBuilder let details: Details

    /// D53 §3.2.3: a ring that sweeps with the measured progress, the stage
    /// title cross-fading, numbers rolling, and a bouncing check when done.
    var body: some View {
        let measured = RuntimeWorkflowState.measuredFraction(fraction)
        let tint = state.tint(accent: theme.isImmersive ? theme.pigment.brightColor : theme.actionFill)
        ContentPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 18) {
                    progressRing(measured: measured, tint: tint)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 22, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .id(title)
                            .transition(.opacity)

                    }
                    .animation(AppMotion.resolved(.standard, reduceMotion: reduceMotion), value: title)
                    .animation(AppMotion.resolved(.standard, reduceMotion: reduceMotion), value: subtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let measured {
                    HStack(spacing: 12) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(tint.opacity(0.14))
                                Capsule()
                                    .fill(LinearGradient(colors: theme.isImmersive ? theme.pigment.gradientStops : [tint, tint],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, proxy.size.width * measured))
                                    .shadow(color: tint.opacity(surfaces.isNight ? 0.45 : 0), radius: 4)
                                    .animation(AppMotion.resolved(.data, reduceMotion: reduceMotion), value: measured)
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int(measured * 100))%")
                            .font(AppDesignTokens.TypeScale.bodyEmphasis)
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                            .appDataTransition(value: Int(measured * 100))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("进度", "Progress"))
                    .accessibilityValue("\(Int(measured * 100))%")
                }
                if !metrics.isEmpty {
                    Rectangle().fill(surfaces.divider).frame(height: 1).accessibilityHidden(true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(metrics) { metric in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.title).font(AppDesignTokens.TypeScale.caption)
                                    .foregroundStyle(surfaces.textSecondary)
                                Text(metric.value).font(AppDesignTokens.TypeScale.metricCard)
                                    .lineLimit(1)
                                    .help(metric.value)
                                    .appDataTransition(value: metric.value)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                details
                if let currentItem, !currentItem.isEmpty {
                    Rectangle().fill(surfaces.divider).frame(height: 1).accessibilityHidden(true)
                    Text(currentItem).lineLimit(1).truncationMode(.middle)
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(surfaces.textSecondary)
                    .help(currentItem)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .accessibilityLabel(L10n.text("当前对象", "Current Item"))
                    .accessibilityValue(currentItem)
#if DEBUG
                    .layoutProbe(LayoutProbeID.runtimeLocation)
#endif
                }
            }
            .padding(20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(surfaces.textPrimary)
        .accessibilityElement(children: .contain)
    }

    private func progressRing(measured: Double?, tint: Color) -> some View {
        let colors = theme.isImmersive
            ? [theme.pigment.lightStop, theme.pigment.brightColor]
            : [tint, tint]
        return ZStack {
            if state == .completed {
                MetricRing(fraction: 1, colors: [AppDesignTokens.Palette.success, AppDesignTokens.Palette.success], lineWidth: 7)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppDesignTokens.Palette.success)
                    .symbolEffect(.bounce, value: !reduceMotion && state == .completed)
            } else if state.isActive, measured == nil {
                MetricRing(fraction: 0.001, colors: colors, lineWidth: 7)
                ProgressView().controlSize(.regular).tint(tint)
            } else {
                MetricRing(fraction: measured ?? 0, colors: colors, lineWidth: 7)
                Image(systemName: state.symbol)
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
            }
        }
        .frame(width: 68, height: 68)
        .accessibilityHidden(true)
    }
}

struct LegacyFeatureRuntimePage<Details: View, Actions: View>: View {
    let module: ReviewFilter
    let title: String
    var subtitle: String? = nil
    var state: RuntimeWorkflowState = .running
    var fraction: Double? = nil
    var metrics: [RuntimeWorkflowMetric] = []
    var currentItem: String? = nil
    var trustText = L10n.text("只读扫描 · 清理前逐项确认", "Read-only scan · Review before cleanup")
    @ViewBuilder let details: Details
    @ViewBuilder let actions: Actions

    var body: some View {
        SmartScanPageShell(fitsVisibleHeight: true) {
            AppPageHeader(title: module.sidebarTitle,
                          systemImage: module.systemImage, isHero: true) { EmptyView() }
        } content: {
            RuntimeActivityColumns(module: module) {
                RuntimeActivityCard(title: title, subtitle: subtitle, state: state,
                    fraction: fraction, metrics: metrics, currentItem: currentItem) { details }
            }
        } footer: {
            RuntimeActivityFooter(text: trustText) { actions }
        }
    }
}
