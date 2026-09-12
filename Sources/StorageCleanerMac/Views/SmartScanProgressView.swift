import Foundation
import SwiftUI

struct SmartScanReadyStage: View {
    let title: String
    let detail: String?
    let systemImage: String
    let actionTitle: String
    let actionSystemImage: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            AppStateIconRing(systemImage: systemImage, isActive: isLoading)

            VStack(spacing: AppDesignTokens.Spacing.small) {
                Text(title)
                    .font(AppDesignTokens.Typography.heroTitle)
                    .multilineTextAlignment(.center)

                if let detail {
                    Text(detail)
                        .font(AppDesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            AppButton(
                title: actionTitle,
                systemImage: actionSystemImage,
                kind: .primary,
                tint: AppDesignTokens.Palette.steadyChrome,
                controlSize: .large,
                isDisabled: isLoading,
                action: action
            )
            .frame(minWidth: 200, minHeight: 44)

            Label {
                Text(L10n.text("只读扫描 · 清理前逐项确认", "Read-only scan · Review before cleanup"))
            } icon: {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppDesignTokens.Palette.success)
            }
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 640, minHeight: 430)
        .accessibilityElement(children: .contain)
    }
}

struct ScanProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore
    let module: ReviewFilter
    @State private var isPresented = false

    init(store: ScanStore, module: ReviewFilter = .overview) {
        self.store = store
        self.module = module
    }

    private var progress: DiskScanProgress {
        store.mainScanProgress ?? .starting(mode: .fallback)
    }

    private var isSmartScan: Bool {
        module == .overview
    }

    private var isFinalizing: Bool {
        store.scanPresentationState == .finalizing
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppDesignTokens.Spacing.large) {
                AppPageHeader(
                    title: module.title,
                    subtitle: isSmartScan
                        ? L10n.text(
                            "正在分析缓存、临时文件与存储占用",
                            "Analyzing caches, temporary files, and storage usage"
                        )
                        : module.pageSubtitle,
                    systemImage: module.systemImage
                ) {
                    MetadataPill(
                        text: L10n.text("只读扫描", "Read-only"),
                        systemImage: "checkmark.shield.fill",
                        tint: AppDesignTokens.Palette.success
                    )
                }

                if isSmartScan {
                    SmartScanProgressDashboard(progress: progress, isFinalizing: isFinalizing)
                } else {
                    ModuleScanProgressHero(progress: progress, isFinalizing: isFinalizing)
                }

                scanControls
            }
            .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
            .padding(.top, AppDesignTokens.Layout.pagePadding)
            .padding(.bottom, AppDesignTokens.Layout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .opacity(reduceMotion || isPresented ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.14),
            value: progress
        )
        .task {
            guard !reduceMotion else { return }
            await Task.yield()
            withAnimation(.easeOut(duration: 0.14)) {
                isPresented = true
            }
        }
    }

    private var scanControls: some View {
        VStack(spacing: AppDesignTokens.Spacing.small) {
            Text(
                L10n.text(
                    "扫描结果仅登记候选，不会自动删除任何文件。",
                    "Scan results only index candidates; no files are deleted automatically."
                )
            )
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)

            if store.canCancelMainScan || store.isCancellingMainScan {
                AppButton(
                    title: store.isCancellingMainScan
                        ? L10n.text("正在停止扫描", "Stopping Scan")
                        : L10n.text("取消扫描", "Cancel Scan"),
                    systemImage: "xmark.circle",
                    isLoading: store.isCancellingMainScan,
                    isDisabled: !store.canCancelMainScan
                ) {
                    store.cancelMainScan()
                }
            }
        }
        .padding(.bottom, AppDesignTokens.Spacing.small)
    }

}

/// The scan-only surface is intentionally data-only: its three metrics and
/// stage rows are all rendered from the scanner's latest published snapshot.
/// State hosts can reuse it without creating a second scanner or history.
struct SmartScanProgressDashboard: View {
    let progress: DiskScanProgress
    var isFinalizing = false

    private var progressFraction: CGFloat {
        CGFloat(min(1, max(0, progress.fractionCompleted)))
    }

    private var progressText: String {
        progress.progressKind == .determinate
            ? "\(Int((progressFraction * 100).rounded()))%"
            : L10n.text("准备中", "Preparing")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                SmartScanMetric(
                    value: progressText,
                    title: L10n.text("进度", "Progress")
                )
                SmartScanMetric(
                    value: L10n.items(progress.discoveredItemCount),
                    title: L10n.text("已发现项目", "Items found")
                )
                SmartScanMetric(
                    value: ByteFormat.string(progress.discoveredBytes),
                    title: L10n.text("发现大小", "Size found")
                )
            }

            SmartScanThinProgressBar(
                progressKind: progress.progressKind,
                fraction: progressFraction
            )

            ScanProgressStageList(progress: progress, isFinalizing: isFinalizing)
                .frame(maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fullBleedSection()
    }
}

/// Full-page Smart Scan progress presentation for the authoritative flow
/// host.  It owns no scan state and never manufactures progress; callers pass
/// the throttled scanner snapshot and real cancellation capability.
struct SmartScanScanningPage: View {
    @Environment(\.moduleTheme) private var theme

    let progress: DiskScanProgress
    var isFinalizing = false
    var canCancel = false
    var isCancelling = false
    var onCancel: (() -> Void)?

    var body: some View {
        SmartScanPageShell {
            AppPageHeader(
                title: L10n.text("智能扫描", "Smart Scan"),
                subtitle: L10n.text(
                    "检查可清理垃圾与需要人工判断的文件",
                    "Checking cleanup candidates and files that need review"
                ),
                systemImage: "magnifyingglass"
            ) {
                headerActions
            }
        } content: {
            SmartScanProgressDashboard(progress: progress, isFinalizing: isFinalizing)
                .padding(.top, AppDesignTokens.Spacing.small)
        } footer: {
            Text(L10n.text(
                "只读扫描 · 结果仅登记候选，不会自动删除文件",
                "Read-only · Results only index candidates and never delete files automatically"
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        Text(L10n.text("只读扫描", "Read-only"))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(AppDesignTokens.Palette.success)
            .accessibilityLabel(L10n.text("只读扫描", "Read-only scan"))
        if canCancel || isCancelling, let onCancel {
            Button {
                onCancel()
            } label: {
                Label(
                    isCancelling
                        ? L10n.text("正在停止", "Stopping")
                        : L10n.text("取消", "Cancel"),
                    systemImage: "xmark.circle"
                )
            }
            .appButtonChrome(.secondary)
            .disabled(!canCancel)
            .accessibilityLabel(isCancelling
                ? L10n.text("正在停止扫描", "Stopping Scan")
                : L10n.text("取消扫描", "Cancel Scan"))
        }
    }
}

private struct SmartScanMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)

            Text(title)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct SmartScanThinProgressBar: View {
    @Environment(\.moduleTheme) private var theme

    let progressKind: ScanProgressKind
    let fraction: CGFloat

    var body: some View {
        Group {
            if progressKind == .determinate {
                ProgressView(value: Double(fraction), total: 1)
                    .progressViewStyle(.linear)
                    .tint(theme.scanProgressColor)
                    .accessibilityValue("\(Int((fraction * 100).rounded()))%")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(theme.scanProgressColor)
                    .accessibilityValue(L10n.text("准备中", "Preparing"))
            }
        }
        .frame(height: 3)
        .accessibilityLabel(L10n.text("扫描进度", "Scan progress"))
    }
}

private struct ScanProgressStageList: View {
    let progress: DiskScanProgress
    var isFinalizing = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(progress.groups.enumerated()), id: \.element.id) { index, group in
                    ScanProgressGroupRow(group: group)
                    if index < progress.groups.count - 1 {
                        Divider().padding(.leading, 42)
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.success,
            prominence: .quiet
        )
    }
}

private struct ModuleScanProgressHero: View {
    let progress: DiskScanProgress
    var isFinalizing = false

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            ModuleScanProgressRing(progress: progress)

            VStack(spacing: AppDesignTokens.Spacing.compact) {
                Text(isFinalizing
                    ? L10n.text("正在整理结果", "Organizing Results")
                    : progress.currentGroupTitle)
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .fixedSize(horizontal: false, vertical: true)

                if isFinalizing {
                    Text(L10n.text(
                        "扫描已完成，正在生成可审核的结果。",
                        "The scan finished; preparing reviewable results."
                    ))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                } else if let currentPath = progress.currentPath {
                    Text(currentPath)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .monospaced()
                } else {
                    Text(L10n.text(
                        "已发现 \(L10n.items(progress.discoveredItemCount)) · \(ByteFormat.string(progress.discoveredBytes))",
                        "\(L10n.items(progress.discoveredItemCount)) · \(ByteFormat.string(progress.discoveredBytes)) found"
                    ))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: 360)
        .fullBleedSection()
    }
}

struct SmartScanResultRing: View {
    let candidateBytes: Int64
    let recommendedBytes: Int64
    let candidateCount: Int

    private var recommendedFraction: CGFloat {
        guard candidateBytes > 0 else { return 0 }
        return CGFloat(min(1, max(0, Double(recommendedBytes) / Double(candidateBytes))))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppDesignTokens.Palette.information.opacity(0.05))

            Circle()
                .stroke(AppDesignTokens.Palette.information.opacity(0.16), lineWidth: 15)

            Circle()
                .trim(from: 0, to: recommendedFraction)
                .stroke(
                    AppDesignTokens.Palette.success.gradient,
                    style: StrokeStyle(lineWidth: 13, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: AppDesignTokens.Palette.success.opacity(0.30), radius: 5)

            VStack(spacing: AppDesignTokens.Spacing.compact) {
                Text(L10n.text("已发现候选", "Candidates Found"))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)

                Text(ByteFormat.string(candidateBytes))
                    .font(AppDesignTokens.Typography.heroTitle)
                    .monospacedDigit()

                Text(L10n.items(candidateCount))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("扫描结果", "Scan result"))
        .accessibilityValue(
            L10n.text(
                "发现 \(ByteFormat.string(candidateBytes))，建议选择 \(ByteFormat.string(recommendedBytes))",
                "\(ByteFormat.string(candidateBytes)) found, \(ByteFormat.string(recommendedBytes)) recommended"
            )
        )
    }
}

private struct ModuleScanProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.moduleTheme) private var theme

    let progress: DiskScanProgress

    private var progressFraction: CGFloat {
        guard progress.totalGroupCount > 0 else { return 0 }
        return CGFloat(min(
            1,
            max(0, Double(progress.completedGroupCount) / Double(progress.totalGroupCount))
        ))
    }

    private var percentText: String {
        progress.progressKind == .determinate
            ? "\(Int((progressFraction * 100).rounded()))%"
            : L10n.text("正在扫描", "Scanning")
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 6)

            if progress.progressKind == .determinate {
                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(
                        theme.scanProgressColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.14),
                        value: progressFraction
                    )
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.scanProgressColor)
            }

            VStack(spacing: AppDesignTokens.Spacing.compact) {
                Text(percentText)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
        }
        .frame(width: 124, height: 124)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("扫描进度", "Scan progress"))
        .accessibilityValue(
            L10n.text(
                "已完成 \(progress.completedGroupCount) 类，共 \(progress.totalGroupCount) 类；发现 \(ByteFormat.string(progress.discoveredBytes))，\(L10n.items(progress.discoveredItemCount))",
                "\(progress.completedGroupCount) of \(progress.totalGroupCount) categories complete; \(ByteFormat.string(progress.discoveredBytes)), \(L10n.items(progress.discoveredItemCount)) found"
            )
        )
    }
}


private struct ScanProgressGroupRow: View {
    let group: DiskScanProgress.GroupSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                stateIcon
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                Text(group.title)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusTint)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }

            if group.state == .scanning, let currentPath = group.currentPath {
                Text(currentPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospaced()
                    .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, group.state == .scanning && group.currentPath != nil ? 6 : 4)
        .frame(minHeight: group.state == .scanning && group.currentPath != nil ? 44 : 34)
        .background(
            group.state == .scanning
                ? statusTint.opacity(0.08)
                : Color.clear
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateIcon: some View {
        if group.state == .scanning {
            ProgressView()
                .controlSize(.small)
                .tint(statusTint)
        } else {
            Image(systemName: stateSystemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusTint)
        }
    }

    private var stateSystemImage: String {
        switch group.state {
        case .pending: "circle"
        case .scanning: "circle.dotted"
        case .clean, .found: "checkmark.circle.fill"
        case .skipped: "minus.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch group.state {
        case .pending: AppDesignTokens.Palette.secondaryText
        case .scanning: AppDesignTokens.Palette.information
        case .clean: AppDesignTokens.Palette.success
        case .found: CleanupRiskPresentation.tint(group.risk)
        case .skipped: AppDesignTokens.Palette.warning
        case .failed: AppDesignTokens.Palette.destructive
        }
    }

    private var statusText: String {
        switch group.state {
        case .pending: L10n.text("等待", "Pending")
        case .scanning: L10n.text("扫描中", "Scanning")
        case .clean: L10n.text("干净", "Clean")
        case .found:
            L10n.text(
                "\(group.itemCount) 项 · \(ByteFormat.string(group.bytes))",
                "\(group.itemCount) · \(ByteFormat.string(group.bytes))"
            )
        case .skipped: L10n.text("已跳过", "Skipped")
        case .failed: L10n.text("读取失败", "Failed")
        }
    }
}

#if DEBUG
/// UI-only fixtures for repeatable screenshots and motion review. They never
/// touch `ScanStore`, scanner services, cleanup plans, or release builds.
enum DebugScanPresentationScenario: String, CaseIterable {
    // Existing launch names stay stable so saved screenshot commands continue to work.
    case preparing
    case determinate
    case indeterminate
    case multiStage
    case stageCompleted
    case stageSkipped
    case stageFailed
    case cancelled
    case fast
    case long
    case completed
    case cleanupCompleted
    case emptyResults
    case largeResults

    // Fixed end-to-end fixtures. They remain presentation-only and never create
    // a ScanStore session, CleanPlan, or filesystem operation.
    case idle
    case stale
    case smallResults
    case partialSelection
    case allSelected
    case preflightPassed
    case preflightWarning
    case cleaning
    case singleItemComplete
    case partialFailure
    case recoverableCompletion

    enum PresentationKind {
        case idle
        case scanning
        case results
        case preflight
        case cleaning
        case terminal
    }

    static func scenario(named name: String) -> Self? {
        if let scenario = Self(rawValue: name) {
            return scenario
        }

        return switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "not-scanned", "unscanned":
            .idle
        case "last-scan-expired", "stale-results":
            .stale
        case "slow-scan":
            .long
        case "fast-scan":
            .fast
        case "no-results":
            .emptyResults
        case "small-results":
            .smallResults
        case "large-results":
            .largeResults
        case "partial-selection":
            .partialSelection
        case "all-selected":
            .allSelected
        case "preflight-success":
            .preflightPassed
        case "preflight-warning":
            .preflightWarning
        case "single-item-fast-complete":
            .singleItemComplete
        case "partial-failure":
            .partialFailure
        case "recoverable-completion":
            .recoverableCompletion
        default:
            nil
        }
    }

    static var launchScenario: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--debug-scan-demo"),
              arguments.indices.contains(index + 1) else { return nil }
        return scenario(named: arguments[index + 1])
    }

    static var launchPercentOverride: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--debug-scan-progress"),
              arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]) else { return nil }
        return min(100, max(0, value))
    }

    var isResult: Bool {
        switch self {
        case .emptyResults, .smallResults, .largeResults, .partialSelection, .allSelected:
            true
        default:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .cancelled, .fast, .completed, .cleanupCompleted,
             .singleItemComplete, .partialFailure, .recoverableCompletion:
            true
        default:
            false
        }
    }

    var presentationKind: PresentationKind {
        switch self {
        case .idle, .stale:
            .idle
        case .preflightPassed, .preflightWarning:
            .preflight
        case .cleaning:
            .cleaning
        default:
            isResult ? .results : (isTerminal ? .terminal : .scanning)
        }
    }

    var isPreflightWarning: Bool {
        self == .preflightWarning
    }

    var terminalTitle: String {
        switch self {
        case .cancelled:
            L10n.text("扫描已取消", "Scan Cancelled")
        case .fast, .completed:
            L10n.text("扫描完成", "Scan Complete")
        case .cleanupCompleted:
            L10n.text("安全清理完成", "Safe Cleanup Complete")
        case .singleItemComplete:
            L10n.text("已安全处理 1 项", "1 Item Safely Processed")
        case .partialFailure:
            L10n.text("部分项目未处理", "Some Items Were Not Processed")
        case .recoverableCompletion:
            L10n.text("清理完成，可恢复", "Cleanup Complete and Recoverable")
        default:
            ""
        }
    }

    var terminalDetail: String {
        switch self {
        case .cancelled:
            L10n.text("已停止本次只读扫描，尚未执行任何清理。", "This read-only scan was stopped; no cleanup was performed.")
        case .fast:
            L10n.text("0.24 秒内完成；结果以真实扫描结束时的数据为准。", "Completed in 0.24 seconds; production results use data from the actual scan.")
        case .completed:
            L10n.text("已完成结果整理。", "Finished organizing results.")
        case .cleanupCompleted:
            L10n.text("已完成冻结计划；恢复能力和执行回执保持不变。", "The frozen plan completed; recovery and receipts remain unchanged.")
        case .singleItemComplete:
            L10n.text("1 个项目已移入废纸篓；可用空间由 macOS 后续回收。", "One item was moved to Trash; macOS reclaims available space separately.")
        case .partialFailure:
            L10n.text("3 项已移入废纸篓，1 项因重新校验未通过而保留。", "Three items were moved to Trash; one was retained after revalidation failed.")
        case .recoverableCompletion:
            L10n.text("项目已移入废纸篓；在废纸篓清空前仍可恢复。", "Items were moved to Trash and remain recoverable until Trash is emptied.")
        default:
            ""
        }
    }

    var terminalImage: String {
        switch self {
        case .cancelled:
            "xmark.circle.fill"
        case .partialFailure:
            "exclamationmark.triangle.fill"
        case .cleanupCompleted:
            "checkmark.shield.fill"
        default:
            "checkmark.circle.fill"
        }
    }

    var terminalTint: Color {
        switch self {
        case .cancelled, .partialFailure:
            AppDesignTokens.Palette.warning
        default:
            AppDesignTokens.Palette.success
        }
    }

    var resultTitle: String {
        switch self {
        case .emptyResults:
            L10n.text("未发现可清理项目", "No Cleanup Candidates Found")
        case .smallResults:
            L10n.text("发现少量候选项目", "Small Result Set Found")
        case .partialSelection, .allSelected:
            L10n.text("扫描结果已就绪", "Scan Results Ready")
        default:
            L10n.text("扫描完成", "Scan Complete")
        }
    }

    var resultDetail: String {
        switch self {
        case .emptyResults:
            L10n.text("本次扫描没有登记候选项目。", "This scan did not register any candidate items.")
        case .smallResults:
            L10n.text("发现 2 项候选，共 1.1 MB；仍需逐项确认。", "Two candidates total 1.1 MB and still require item-by-item review.")
        case .largeResults:
            L10n.text("已发现 1,248 项候选，共 120 GB；仍需逐项确认后才能安全清理。", "1,248 candidates total 120 GB and still require item-by-item review before safe cleanup.")
        case .partialSelection:
            L10n.text("仅选择了经过复核的安全候选项目。", "Only reviewed safe candidates are selected.")
        case .allSelected:
            L10n.text("全部候选均为可复核的安全项目。", "All candidates are reviewed safe items.")
        default:
            L10n.text("固定展示数据，不会创建清理计划。", "Fixed presentation data; no cleanup plan is created.")
        }
    }

    var resultMetric: String {
        switch self {
        case .emptyResults:
            L10n.items(0)
        case .smallResults:
            "1.1 MB"
        case .largeResults:
            "120 GB"
        case .partialSelection, .allSelected:
            "42.6 GB"
        default:
            "12.8 GB"
        }
    }

    var resultCandidateCount: Int {
        switch self {
        case .emptyResults:
            0
        case .smallResults:
            2
        case .largeResults:
            1_248
        case .partialSelection, .allSelected:
            8
        default:
            0
        }
    }

    var resultByteCount: Int64 {
        switch self {
        case .smallResults:
            1_100_000
        case .largeResults:
            120_000_000_000
        case .partialSelection, .allSelected:
            42_600_000_000
        default:
            0
        }
    }

    var selectionSummary: String? {
        switch self {
        case .partialSelection:
            L10n.text("已选择 3 / 8 项", "3 of 8 items selected")
        case .allSelected:
            L10n.text("已选择 8 / 8 项", "8 of 8 items selected")
        default:
            nil
        }
    }

    var idleTitle: String {
        self == .stale
            ? L10n.text("上次扫描结果已过期", "Previous Scan Results Expired")
            : L10n.text("尚未开始扫描", "No Scan Has Run Yet")
    }

    var idleDetail: String {
        self == .stale
            ? L10n.text("上次结果不会用于清理；请重新执行只读扫描。", "Previous results are never used for cleanup; run a new read-only scan.")
            : L10n.text("开始扫描前不会读取、移动或删除任何文件。", "No files are read, moved, or deleted before a scan starts.")
    }

    var preflightTitle: String {
        isPreflightWarning
            ? L10n.text("清理前检查发现需确认项目", "Preflight Needs Review")
            : L10n.text("清理前检查已通过", "Preflight Passed")
    }

    var preflightDetail: String {
        isPreflightWarning
            ? L10n.text("1 项路径状态发生变化，已从本次清理中保留。", "One path changed and is retained from this cleanup.")
            : L10n.text("身份、路径和目标位置均已重新校验。", "Identity, path, and destination were revalidated.")
    }

    var progress: DiskScanProgress {
        progress(percentOverride: nil)
    }

    func progress(percentOverride: Int?) -> DiskScanProgress {
        let total: Int
        let completed: Int
        let phase: CleanupScanPhase
        let currentTitle: String
        let currentPath: String?
        let foundCount: Int
        let foundBytes: Int64

        switch self {
        case .idle, .stale:
            total = 8
            completed = 0
            phase = .preparing
            currentTitle = idleTitle
            currentPath = nil
            foundCount = 0
            foundBytes = 0
        case .preparing:
            total = 8
            completed = 0
            phase = .preparing
            currentTitle = L10n.text("正在准备扫描范围", "Preparing Scan Scope")
            currentPath = nil
            foundCount = 0
            foundBytes = 0
        case .indeterminate:
            total = 8
            completed = 0
            phase = .preparing
            currentTitle = L10n.text("正在读取受保护目录", "Reading Protected Directories")
            currentPath = "/Users/demo/Library/Caches"
            foundCount = 12
            foundBytes = 42_000_000
        case .determinate:
            total = 100
            completed = percentOverride ?? Self.launchPercentOverride ?? 42
            phase = .enumerating
            currentTitle = L10n.text("正在扫描应用缓存", "Scanning App Caches")
            currentPath = "/Users/demo/Library/Caches/com.example.app"
            foundCount = 128
            foundBytes = 2_400_000_000
        case .multiStage:
            total = 8
            completed = 3
            phase = .enumerating
            currentTitle = L10n.text("正在扫描浏览器数据", "Scanning Browser Data")
            currentPath = "/Users/demo/Library/Application Support"
            foundCount = 86
            foundBytes = 1_180_000_000
        case .stageCompleted:
            total = 8
            completed = 4
            phase = .enumerating
            currentTitle = L10n.text("正在扫描开发缓存", "Scanning Developer Caches")
            currentPath = "/Users/demo/Library/Developer"
            foundCount = 94
            foundBytes = 1_430_000_000
        case .stageSkipped:
            total = 8
            completed = 4
            phase = .enumerating
            currentTitle = L10n.text("正在扫描日志", "Scanning Logs")
            currentPath = "/Users/demo/Library/Logs"
            foundCount = 94
            foundBytes = 1_430_000_000
        case .stageFailed:
            total = 8
            completed = 4
            phase = .enumerating
            currentTitle = L10n.text("继续扫描剩余项目", "Continuing Remaining Stages")
            currentPath = "/Users/demo/Library/Application Support"
            foundCount = 96
            foundBytes = 1_440_000_000
        case .long:
            total = 8
            completed = 5
            phase = .enumerating
            currentTitle = L10n.text("正在扫描大型文件", "Scanning Large Files")
            currentPath = "/Users/demo/Documents"
            foundCount = 214
            foundBytes = 4_800_000_000
        case .smallResults, .largeResults, .partialSelection, .allSelected:
            total = 8
            completed = 8
            phase = .finalizing
            currentTitle = L10n.text("正在整理结果", "Organizing Results")
            currentPath = nil
            foundCount = resultCandidateCount
            foundBytes = resultByteCount
        case .preflightPassed, .preflightWarning, .cleaning,
             .singleItemComplete, .partialFailure, .recoverableCompletion:
            total = 8
            completed = 8
            phase = .finalizing
            currentTitle = L10n.text("固定展示状态", "Fixed Presentation State")
            currentPath = nil
            foundCount = 0
            foundBytes = 0
        default:
            total = 8
            completed = 8
            phase = .finalizing
            currentTitle = L10n.text("正在整理结果", "Organizing Results")
            currentPath = nil
            foundCount = 0
            foundBytes = 0
        }

        return DiskScanProgress(cleanupProgress: CleanupScanProgress(
            phase: phase,
            currentRuleTitle: currentTitle,
            currentPath: currentPath,
            completedRuleCount: completed,
            totalRuleCount: total,
            discoveredItemCount: foundCount,
            discoveredBytes: foundBytes,
            groups: completedGroups
        ))
    }

    var stageNotice: (image: String, tint: Color, text: String)? {
        switch self {
        case .stageCompleted:
            (
                "checkmark.circle.fill",
                AppDesignTokens.Palette.success,
                L10n.text("浏览器缓存已完成", "Browser cache stage completed")
            )
        case .stageSkipped:
            (
                "minus.circle.fill",
                AppDesignTokens.Palette.warning,
                L10n.text("系统日志已跳过：当前权限不可用", "System logs skipped: permission is unavailable")
            )
        case .stageFailed:
            (
                "exclamationmark.circle.fill",
                AppDesignTokens.Palette.warning,
                L10n.text("下载缓存无法读取；其余阶段继续扫描", "Downloads cache could not be read; remaining stages continue")
            )
        case .long:
            (
                "clock",
                AppDesignTokens.Palette.information,
                L10n.text("已扫描 31 秒", "31 seconds elapsed")
            )
        default:
            nil
        }
    }

    private var completedGroups: [CleanupScanProgress.GroupSummary] {
        switch self {
        case .preparing, .indeterminate:
            []
        default:
            [
                .init(id: "user-cache", title: L10n.text("用户缓存", "User Caches"), itemCount: 32, bytes: 680_000_000),
                .init(id: "browser", title: L10n.text("浏览器数据", "Browser Data"), itemCount: 41, bytes: 510_000_000),
                .init(id: "logs", title: L10n.text("日志文件", "Log Files"), itemCount: 21, bytes: 240_000_000)
            ]
        }
    }
}

struct DebugScanPresentationView: View {
    @Environment(\.moduleTheme) private var theme

    let scenario: DebugScanPresentationScenario
    let module: ReviewFilter
    @State private var animatedProgressPercent: Int?

    private var progress: DiskScanProgress {
        scenario.progress(percentOverride: animatedProgressPercent)
    }
    private var isSmartScan: Bool { module == .overview }

    var body: some View {
        ScrollView {
            VStack(spacing: AppDesignTokens.Spacing.large) {
                AppPageHeader(
                    title: module.title,
                    subtitle: L10n.text("Debug 固定扫描展示数据，不会读取或修改任何文件。", "Debug fixture data only; no files are read or changed."),
                    systemImage: module.systemImage
                ) {
                    MetadataPill(
                        text: "DEBUG · \(scenario.rawValue)",
                        systemImage: "ladybug.fill",
                        tint: theme.actionFill
                    )
                }

                presentationContent
            }
            .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
            .padding(.top, AppDesignTokens.Layout.pagePadding)
            .padding(.bottom, AppDesignTokens.Layout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .task(id: scenario) {
            guard scenario == .determinate,
                  DebugScanPresentationScenario.launchPercentOverride == nil else { return }
            animatedProgressPercent = 0
            for value in stride(from: 5, through: 100, by: 5) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.14)) {
                    animatedProgressPercent = value
                }
            }
        }
    }

    @ViewBuilder
    private var presentationContent: some View {
        switch scenario.presentationKind {
        case .idle:
            DebugScanIdlePanel(scenario: scenario)
        case .results:
            DebugScanResultPanel(scenario: scenario)
        case .preflight:
            DebugScanPreflightPanel(scenario: scenario)
        case .cleaning:
            DebugScanCleaningPanel()
        case .terminal:
            DebugScanTerminalPanel(scenario: scenario)
        case .scanning:
            if isSmartScan {
                SmartScanProgressDashboard(progress: progress)
            } else {
                ModuleScanProgressHero(progress: progress)
            }

            if let notice = scenario.stageNotice {
                Label(notice.text, systemImage: notice.image)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(notice.tint)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassPanel(
                        cornerRadius: AppDesignTokens.Layout.rowRadius,
                        tint: notice.tint,
                        prominence: .quiet
                    )
            }
        }
    }
}

private struct DebugScanIdlePanel: View {
    let scenario: DebugScanPresentationScenario

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            Image(systemName: scenario == .stale ? "clock.badge.exclamationmark" : "magnifyingglass")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(AppDesignTokens.Palette.information)
                .accessibilityHidden(true)
            Text(scenario.idleTitle)
                .font(AppDesignTokens.Typography.heroTitle)
            Text(scenario.idleDetail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label(
                L10n.text("Debug 固定状态：不会调用扫描服务。", "Debug fixture: no scanner is called."),
                systemImage: "ladybug.fill"
            )
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 340)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.heroRadius, tint: AppDesignTokens.Palette.information, elevated: true)
    }
}

private struct DebugScanPreflightPanel: View {
    let scenario: DebugScanPresentationScenario

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            Label(
                scenario.preflightTitle,
                systemImage: scenario.isPreflightWarning ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
            )
            .font(AppDesignTokens.Typography.sectionTitle)
            .foregroundStyle(scenario.isPreflightWarning ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.success)

            Text(scenario.preflightDetail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)

            Divider()

            Label(
                L10n.text("固定演示；不会创建或执行清理计划。", "Fixed demo; no cleanup plan is created or executed."),
                systemImage: "ladybug.fill"
            )
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.heroRadius,
            tint: scenario.isPreflightWarning ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.success,
            elevated: true
        )
    }
}

private struct DebugScanCleaningPanel: View {
    private let fraction = 0.57

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            ProgressView(value: fraction)
                .tint(AppDesignTokens.Palette.information)
                .accessibilityLabel(L10n.text("演示清理进度", "Demo cleanup progress"))
                .accessibilityValue("57%")
            Text(L10n.text("正在安全处理", "Safely Processing"))
                .font(AppDesignTokens.Typography.heroTitle)
            Text(L10n.text("第 4 / 7 项 · 固定演示数据，不会移动或删除文件。", "Item 4 of 7 · fixed demo data; no files are moved or deleted."))
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 340)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.heroRadius, tint: AppDesignTokens.Palette.information, elevated: true)
    }
}

private struct DebugScanTerminalPanel: View {
    let scenario: DebugScanPresentationScenario

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            Image(systemName: scenario.terminalImage)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(scenario.terminalTint)
                .accessibilityHidden(true)
            Text(scenario.terminalTitle)
                .font(AppDesignTokens.Typography.heroTitle)
            Text(scenario.terminalDetail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 340)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.heroRadius, tint: scenario.terminalTint, elevated: true)
    }
}

private struct DebugScanResultPanel: View {
    let scenario: DebugScanPresentationScenario

    private var tint: Color {
        scenario == .emptyResults ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.information
    }

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            Image(systemName: scenario == .emptyResults ? "checkmark.shield.fill" : "externaldrive.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(scenario == .emptyResults ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.information)
                .accessibilityHidden(true)
            Text(scenario.resultTitle)
                .font(AppDesignTokens.Typography.heroTitle)
            Text(scenario.resultMetric)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let selectionSummary = scenario.selectionSummary {
                Label(selectionSummary, systemImage: "checkmark.square.fill")
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(AppDesignTokens.Palette.success)
            }
            Text(scenario.resultDetail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 340)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.heroRadius,
            tint: tint,
            elevated: true
        )
    }
}
#endif
