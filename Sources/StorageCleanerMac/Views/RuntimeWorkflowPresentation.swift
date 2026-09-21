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
    var detail: String? = nil

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
            .foregroundStyle(state.tint(accent: theme.accent))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppDesignTokens.Typography.compactLabelEmphasis)
                if let detail, !detail.isEmpty {
                    Text(detail).font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(theme.primaryText)
        .background(state.tint(accent: theme.accent).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: AppDesignTokens.Layout.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: AppDesignTokens.Layout.rowRadius)
            .strokeBorder(state.tint(accent: theme.accent).opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct RuntimeActivityCard<Details: View>: View {
    @Environment(\.moduleTheme) private var theme
    let title: String
    var subtitle: String? = nil
    var state: RuntimeWorkflowState = .running
    var fraction: Double? = nil
    var metrics: [RuntimeWorkflowMetric] = []
    var currentItem: String? = nil
    @ViewBuilder let details: Details

    var body: some View {
        let measured = RuntimeWorkflowState.measuredFraction(fraction)
        let tint = state.tint(accent: theme.accent)
        ContentPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        Circle().fill(tint.opacity(0.12))
                        if state.isActive && measured == nil {
                            ProgressView().controlSize(.regular).tint(tint)
                        } else {
                            Image(systemName: state.symbol)
                                .font(.system(size: 24, weight: .medium)).foregroundStyle(tint)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.title).font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(tint)
                        Text(title).font(.system(size: 23, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(AppDesignTokens.Typography.secondary)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let measured {
                    HStack(spacing: 12) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(tint.opacity(0.14))
                                Capsule().fill(tint).frame(width: proxy.size.width * measured)
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int(measured * 100))%")
                            .font(AppDesignTokens.Typography.compactLabelEmphasis)
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("进度", "Progress"))
                    .accessibilityValue("\(Int(measured * 100))%")
                }
                if !metrics.isEmpty {
                    Divider()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(metrics) { metric in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(metric.title).font(AppDesignTokens.Typography.metadata)
                                    .foregroundStyle(theme.secondaryText)
                                Text(metric.value).font(.system(size: 21, weight: .semibold))
                                    .monospacedDigit().lineLimit(1)
                                    .help(metric.value)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                details
                if let currentItem, !currentItem.isEmpty {
                    Divider()
                    Label {
                        Text(currentItem).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder").accessibilityHidden(true)
                    }
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(theme.secondaryText)
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
        .foregroundStyle(theme.primaryText)
        .accessibilityElement(children: .contain)
    }
}

struct FeatureRuntimePage<Details: View, Actions: View>: View {
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
            AppPageHeader(title: module.sidebarTitle, subtitle: module.pageSubtitle,
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
