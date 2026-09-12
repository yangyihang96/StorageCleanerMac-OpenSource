import SwiftUI

struct CleanupPlanConfirmationSheet: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore
    let plan: CleanPlan
    let preflight: CleanPreflightReport
    @State private var showsDetails = false
    @State private var acknowledgesReviewedItems = false
    @State private var acknowledgesProtectedIdentity = false
    @State private var acknowledgesProtectedTrashMove = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                Image(systemName: confirmationSystemImage)
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(confirmationTint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(
                        "清理 \(plan.items.count) 个项目？",
                        "Clean \(plan.items.count) Item(s)?"
                    ))
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .monospacedDigit()
                    Text(dispositionSummary)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: AppDesignTokens.Spacing.medium) {
                compactMetric(L10n.items(plan.items.count), L10n.text("项目", "Items"))
                Divider().frame(height: 28)
                compactMetric(
                    ByteFormat.string(plan.estimatedMovableBytes),
                    plan.disposition == .trash
                        ? L10n.text("将移入废纸篓", "Move to Trash")
                        : L10n.text("将移入隔离区", "Move to Quarantine")
                )
                Divider().frame(height: 28)
                compactMetric(L10n.items(preflight.readyCount), L10n.text("检查通过", "Ready"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if plan.disposition == .trash {
                Label(
                    L10n.text(
                        "清空废纸篓后最多可释放 \(ByteFormat.string(plan.estimatedMovableBytes))；当前立即释放取决于废纸篓和文件系统状态。",
                        "Up to \(ByteFormat.string(plan.estimatedMovableBytes)) may be released after Trash is emptied; immediate release depends on Trash and file-system state."
                    ),
                    systemImage: "trash"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            }

            Label(preflightSummary, systemImage: preflight.isConfirmable ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(preflight.isConfirmable ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning)

            if plan.scanWasPartial || preflight.skippedCount > 0 {
                Label(
                    L10n.text(
                        "\(preflight.skippedCount) 项受限，不会执行。",
                        "\(preflight.skippedCount) item(s) are limited and will not run."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.warning)
            }

            if !plan.reviewItems.isEmpty {
                reviewedItemsConfirmation
            }

            if !plan.protectedItems.isEmpty {
                protectedItemsConfirmation
            }

            DisclosureGroup(L10n.text("查看详情", "Show Details"), isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    Label(
                        L10n.text("计划已冻结；确认后仍会逐项重新校验身份和路径。", "The plan is frozen; identity and path are rechecked per item after confirmation."),
                        systemImage: "lock.fill"
                    )
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)

                    ForEach(Array(plan.items.prefix(3))) { item in
                        let itemStatus = status(for: item)
                        HStack(spacing: AppDesignTokens.Spacing.small) {
                            Image(systemName: itemStatus.isReady ? "checkmark.circle.fill" : "minus.circle.fill")
                                .foregroundStyle(itemStatus.isReady ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning)
                                .accessibilityHidden(true)
                            Text(item.sourceURL.lastPathComponent)
                                .font(AppDesignTokens.Typography.metadata)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(ByteFormat.string(item.estimatedSizeBytes))
                                    .monospacedDigit()
                                Text(itemStatus.detail)
                                    .foregroundStyle(itemStatus.isReady
                                        ? AppDesignTokens.Palette.success
                                        : AppDesignTokens.Palette.warning)
                            }
                            .font(AppDesignTokens.Typography.metadata)
                        }
                        .help(itemStatus.detail)
                    }
                    if plan.items.count > 3 {
                        Text(L10n.text("另有 \(plan.items.count - 3) 项遵循同一冻结计划。", "\(plan.items.count - 3) more item(s) follow this frozen plan."))
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, AppDesignTokens.Spacing.small)
            }
            .font(AppDesignTokens.Typography.metadata)

            Divider()
            HStack {
                Button(L10n.text("取消", "Cancel")) {
                    store.cancelV2CleanupConfirmation()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    store.confirmV2Cleanup(
                        reviewRiskAcknowledged: plan.reviewItems.isEmpty || acknowledgesReviewedItems,
                        protectedRiskAcknowledged: plan.protectedItems.isEmpty
                            || acknowledgesProtectedIdentity,
                        protectedTrashMoveAcknowledged: plan.protectedItems.isEmpty
                            || acknowledgesProtectedTrashMove
                    )
                } label: {
                    Label(confirmTitle, systemImage: dispositionSystemImage)
                }
                .appButtonChrome(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !preflight.isConfirmable
                        || (!plan.reviewItems.isEmpty && !acknowledgesReviewedItems)
                        || (!plan.protectedItems.isEmpty
                            && (!acknowledgesProtectedIdentity
                                || !acknowledgesProtectedTrashMove))
                )
            }
        }
        .padding(20)
        .frame(width: plan.reviewItems.isEmpty && plan.protectedItems.isEmpty ? 416 : 480)
        .background(ModuleBackground(theme: theme))
        .foregroundStyle(theme.primaryText)
        .clipShape(RoundedRectangle(cornerRadius: AppDesignTokens.Layout.heroRadius, style: .continuous))
    }

    private var reviewedItemsConfirmation: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(
                L10n.text(
                    "黄色项目需要额外确认",
                    "Yellow items need extra confirmation"
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            .foregroundStyle(AppDesignTokens.Palette.warning)

            Text(L10n.text(
                "已手动选择 \(plan.reviewItems.count) 项（\(ByteFormat.string(plan.reviewItemBytes))）。这些内容可能包含个人文件或应用状态；请确认已核对内容、归属和备份。",
                "You manually selected \(plan.reviewItems.count) item(s) (\(ByteFormat.string(plan.reviewItemBytes))). They may contain personal files or app state; confirm content, ownership, and backups."
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    ForEach(plan.reviewItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: AppDesignTokens.Spacing.small) {
                                Text(item.sourceURL.lastPathComponent)
                                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(ByteFormat.string(item.estimatedSizeBytes))
                                    .font(AppDesignTokens.Typography.metadata)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Text(item.sourceURL.path)
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(CleanupRuleCopy.text(for: item.reasonCode))
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .help(item.sourceURL.path)
                    }
                }
            }
            .frame(height: min(CGFloat(plan.reviewItems.count) * 66, 190))

            Toggle(isOn: $acknowledgesReviewedItems) {
                Text(L10n.text(
                    "我已核对以上黄色项目，并确认只将其移入废纸篓",
                    "I reviewed these yellow items and confirm moving them only to Trash"
                ))
                .font(AppDesignTokens.Typography.metadata)
            }
            .toggleStyle(.checkbox)
            .accessibilityHint(L10n.text(
                "勾选后才可确认清理黄色项目",
                "Required before confirming cleanup of yellow items"
            ))
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.rowRadius,
            tint: AppDesignTokens.Palette.warning,
            prominence: .quiet
        )
    }

    private var protectedItemsConfirmation: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(
                L10n.text("红色高风险项目需要双重确认", "Red high-risk items need two confirmations"),
                systemImage: "exclamationmark.octagon.fill"
            )
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            .foregroundStyle(AppDesignTokens.Palette.destructive)

            Text(L10n.text(
                "已手动选择 \(plan.protectedItems.count) 个红色项目（\(ByteFormat.string(plan.protectedItemBytes))）。其中可能包含近期开发产物或应用；请确认当前任务不再使用，重复应用还必须保留一个可用副本。",
                "You manually selected \(plan.protectedItems.count) red item(s) (\(ByteFormat.string(plan.protectedItemBytes))). These may be recent developer artifacts or apps; confirm no current task uses them, and retain a usable copy of duplicate apps."
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    ForEach(plan.protectedItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: AppDesignTokens.Spacing.small) {
                                Text(item.sourceURL.lastPathComponent)
                                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(ByteFormat.string(item.estimatedSizeBytes))
                                    .font(AppDesignTokens.Typography.metadata)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Text(item.sourceURL.path)
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .help(item.sourceURL.path)
                    }
                }
            }
            .frame(height: min(CGFloat(plan.protectedItems.count) * 52, 156))

            Toggle(isOn: $acknowledgesProtectedIdentity) {
                Text(L10n.text(
                    "我已核对项目用途、最近活动和必要备份；重复应用已确认保留副本可用",
                    "I checked each item's purpose, recent activity, and required backups; duplicate apps retain a usable copy"
                ))
                .font(AppDesignTokens.Typography.metadata)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $acknowledgesProtectedTrashMove) {
                Text(L10n.text(
                    "我已退出相关应用或开发工具，并确认只将这些明确选择的项目移入废纸篓",
                    "I quit related apps or developer tools and confirm moving only these explicitly selected items to Trash"
                ))
                .font(AppDesignTokens.Typography.metadata)
            }
            .toggleStyle(.checkbox)
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.rowRadius,
            tint: AppDesignTokens.Palette.destructive,
            prominence: .quiet
        )
    }

    private func compactMetric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
            Text(title)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
        }
    }

    private var dispositionSystemImage: String {
        plan.disposition == .trash ? "trash" : "shippingbox"
    }

    private var confirmationSystemImage: String {
        if !plan.protectedItems.isEmpty { return "exclamationmark.octagon.fill" }
        return plan.reviewItems.isEmpty ? "lock.shield.fill" : "exclamationmark.shield.fill"
    }

    private var confirmationTint: Color {
        if !plan.protectedItems.isEmpty { return AppDesignTokens.Palette.destructive }
        return plan.reviewItems.isEmpty
            ? AppDesignTokens.Palette.success
            : AppDesignTokens.Palette.warning
    }

    private var dispositionDetail: String {
        plan.disposition == .trash
            ? L10n.text("通过 macOS 移入废纸篓", "Move to Trash through macOS")
            : L10n.text("移入 App 专用隔离区", "Move to the app's quarantine")
    }

    private var dispositionSummary: String {
        plan.disposition == .trash
            ? L10n.text("选中项目将移入废纸篓，可在需要时恢复。", "Selected items move to Trash and can be recovered if needed.")
            : L10n.text("选中项目将移入隔离区，可在需要时恢复。", "Selected items move to quarantine and can be recovered if needed.")
    }

    private var preflightSummary: String {
        if preflight.isConfirmable {
            return L10n.text("安全检查已通过", "Safety check passed")
        }
        return L10n.text("安全检查尚未通过", "Safety check is not ready")
    }

    private var confirmTitle: String {
        plan.disposition == .trash
            ? L10n.text("确认移入废纸篓", "Confirm Move to Trash")
            : L10n.text("确认移入隔离区", "Confirm Quarantine")
    }

    private func status(for item: CleanPlanItem) -> (isReady: Bool, detail: String) {
        guard let status = preflight.items.first(where: { $0.planItemID == item.id })?.status else {
            return (false, L10n.text("未完成检查", "Not checked"))
        }
        switch status {
        case .ready:
            return (true, L10n.text("身份和路径检查通过", "Identity and path checks passed"))
        case let .skipped(reason):
            return (false, CleanSkipReasonPresentation.title(reason))
        }
    }
}

/// The state host presents this in place of the results page while the frozen
/// plan is executing or being verified. It reads only executor snapshots and
/// exposes cancellation only when its caller says cancellation is supported.
struct SmartScanCleanupProgressPage: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore

    let progress: CleanupExecutionProgress?
    var isPreflight = false
    var isVerifying = false
    var isCancelling = false
    var onCancel: (() -> Void)?

    private var progressFraction: Double? {
        guard let progress, progress.totalItemCount > 0 else { return nil }
        return min(1, max(0, Double(progress.processedItemCount) / Double(progress.totalItemCount)))
    }

    private var title: String {
        if isCancelling {
            return L10n.text("正在安全停止", "Stopping Safely")
        }
        if isPreflight {
            return L10n.text("正在执行安全检查", "Running Safety Checks")
        }
        if isVerifying {
            return L10n.text("正在验证结果", "Verifying Results")
        }
        if progress == nil {
            return L10n.text("正在准备清理", "Preparing Cleanup")
        }
        return L10n.text("正在安全清理", "Cleaning Safely")
    }

    private var detail: String {
        if isCancelling {
            return L10n.text("当前项目会在安全边界完成后停止。", "The current item stops at a safe boundary.")
        }
        if isPreflight {
            return L10n.text(
                "正在冻结计划并重新校验身份、路径和目标位置。",
                "Freezing the plan and revalidating identity, paths, and destination."
            )
        }
        if isVerifying {
            return L10n.text("正在核对已移动项目和执行回执。", "Checking moved items and execution receipts.")
        }
        guard let progress else {
            return L10n.text("正在冻结计划并进行安全检查。", "Freezing the plan and running safety checks.")
        }
        return L10n.text(
            "已处理 \(progress.processedItemCount) / \(progress.totalItemCount) 项；已移动 \(progress.movedItemCount)，跳过 \(progress.skippedItemCount)，失败 \(progress.failedItemCount)。",
            "Processed \(progress.processedItemCount) of \(progress.totalItemCount); \(progress.movedItemCount) moved, \(progress.skippedItemCount) skipped, \(progress.failedItemCount) failed."
        )
    }

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            AppStateIconRing(
                systemImage: isVerifying ? "checkmark.shield.fill" : "trash.fill",
                tint: theme.actionFill,
                size: 144,
                progress: progressFraction,
                isActive: progressFraction == nil && !isCancelling
            )

            VStack(spacing: AppDesignTokens.Spacing.small) {
                Text(title)
                    .font(AppDesignTokens.Typography.heroTitle)
                Text(detail)
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .frame(maxWidth: 440)
            }

            CleanupExecutionStageList(
                hasStartedMoving: progress != nil,
                isVerifying: isVerifying,
                isCancelling: isCancelling
            )

            if let onCancel {
                Button(isCancelling
                    ? L10n.text("正在停止", "Stopping")
                    : L10n.text("安全取消", "Cancel Safely"),
                    action: onCancel)
                    .appButtonChrome(.secondary)
                    .disabled(isCancelling)
            }
        }
        .padding(AppDesignTokens.Layout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A complete safe-cleanup report page. The prominent number is the moved
/// size, never the permanently released size; those values remain separate in
/// the details disclosure.
struct SmartScanCleanupCompletedPage: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore

    let report: CleanReport
    var onDone: (() -> Void)?
    @State private var showsDetails = false

    private var didMoveToTrash: Bool { report.disposition == .trash }

    private var title: String {
        switch report.outcome {
        case .completed:
            return didMoveToTrash
                ? L10n.text("已移入废纸篓", "Moved to Trash")
                : L10n.text("已安全隔离", "Safely Quarantined")
        case .partiallyCompleted:
            return L10n.text("安全清理部分完成", "Safe Cleanup Partially Complete")
        case .cancelled:
            return L10n.text("安全清理已取消", "Safe Cleanup Cancelled")
        case .failed:
            return L10n.text("安全清理未完成", "Safe Cleanup Not Completed")
        }
    }

    private var summary: String {
        guard report.outcome == .completed else {
            return L10n.text(
                "已移动 \(report.summary.movedItemCount) 项，跳过 \(report.summary.skippedItemCount) 项，失败 \(report.summary.failedItemCount) 项。",
                "\(report.summary.movedItemCount) moved, \(report.summary.skippedItemCount) skipped, \(report.summary.failedItemCount) failed."
            )
        }
        return didMoveToTrash
            ? L10n.text(
                "文件仍可恢复；清空废纸篓后最多可释放这些空间。",
                "Items remain restorable; empty Trash to reclaim up to this amount."
            )
            : L10n.text("项目已移至隔离区，可在需要时恢复。", "Items moved to quarantine and can be restored if needed.")
    }

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            AppStateIconRing(
                systemImage: report.outcome == .completed ? "checkmark" : "exclamationmark",
                tint: report.outcome == .completed ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning,
                size: 144,
                progress: 1
            )

            VStack(spacing: AppDesignTokens.Spacing.small) {
                Text(title)
                    .font(AppDesignTokens.Typography.heroTitle)
                Text(ByteFormat.string(report.summary.movedToRecoverableLocationBytes))
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(didMoveToTrash
                    ? L10n.text("已移入废纸篓的容量", "Capacity Moved to Trash")
                    : L10n.text("已移入隔离区的容量", "Capacity Moved to Quarantine"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            DisclosureGroup(L10n.text("清理详情", "Cleanup Details"), isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    CleanupReportDetailRow(
                        title: L10n.text("已移动体积", "Moved Size"),
                        value: ByteFormat.string(report.summary.movedToRecoverableLocationBytes)
                    )
                    CleanupReportDetailRow(
                        title: L10n.text("清空废纸篓后最多可释放", "Reclaimable After Emptying Trash"),
                        value: report.summary.reclaimableAfterEmptyingTrashBytes.map {
                            ByteFormat.string($0)
                        } ?? L10n.text("不适用", "Not Applicable")
                    )
                    CleanupReportDetailRow(
                        title: L10n.text("永久释放", "Permanently Freed"),
                        value: ByteFormat.string(report.summary.permanentlyFreedBytes)
                    )
                    CleanupReportDetailRow(
                        title: L10n.text("可用空间变化", "Available Space Change"),
                        value: availableSpaceDeltaText(report.summary.availableSpaceDeltaBytes)
                    )
                    CleanupReportDetailRow(
                        title: L10n.text("可恢复", "Restorable"),
                        value: L10n.items(report.restorableReceipts.count)
                    )
                    if report.summary.skippedItemCount > 0 || report.summary.failedItemCount > 0 {
                        CleanupReportDetailRow(
                            title: L10n.text("跳过 / 失败", "Skipped / Failed"),
                            value: "\(report.summary.skippedItemCount) / \(report.summary.failedItemCount)"
                        )
                    }
                }
                .padding(.top, AppDesignTokens.Spacing.small)
            }
            .font(AppDesignTokens.Typography.metadata)
            .padding(AppDesignTokens.Layout.compactPadding)
            .frame(maxWidth: 430, alignment: .leading)
            .glassPanel(
                cornerRadius: AppDesignTokens.Layout.cardRadius,
                tint: theme.actionFill,
                prominence: .quiet
            )

            HStack(spacing: AppDesignTokens.Spacing.small) {
                if !report.restorableReceipts.isEmpty,
                   store.cleanupRecoveryReport == nil {
                    Button {
                        store.requestRestoreLatestV2Cleanup()
                    } label: {
                        Label(L10n.text("恢复", "Restore"), systemImage: "arrow.uturn.backward")
                    }
                    .appButtonChrome(.secondary)
                    .disabled(store.isRestoringV2Cleanup)
                }

                Button {
                    store.openLatestV2CleanupLocation()
                } label: {
                    Label(L10n.text("查看位置", "Show Location"), systemImage: "folder")
                }
                .appButtonChrome(.secondary)

                Button(L10n.text("完成", "Done")) {
                    (onDone ?? store.dismissV2CleanupReport)()
                }
                .appButtonChrome(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isRestoringV2Cleanup)
            }
        }
        .padding(AppDesignTokens.Layout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func availableSpaceDeltaText(_ bytes: Int64?) -> String {
        guard let bytes else { return L10n.text("无法测量", "Unavailable") }
        if bytes > 0 { return "+\(ByteFormat.string(bytes))" }
        if bytes < 0 {
            let magnitude = bytes == .min ? Int64.max : -bytes
            return "−\(ByteFormat.string(magnitude))"
        }
        return ByteFormat.string(bytes)
    }
}

private struct CleanupExecutionStageList: View {
    let hasStartedMoving: Bool
    let isVerifying: Bool
    let isCancelling: Bool

    var body: some View {
        VStack(spacing: 0) {
            CleanupExecutionStageRow(
                title: L10n.text("准备清理", "Prepare Cleanup"),
                isComplete: hasStartedMoving || isVerifying,
                isCurrent: !hasStartedMoving && !isVerifying && !isCancelling
            )
            Divider()
            CleanupExecutionStageRow(
                title: L10n.text("移动项目", "Move Items"),
                isComplete: isVerifying,
                isCurrent: hasStartedMoving && !isVerifying && !isCancelling
            )
            Divider()
            CleanupExecutionStageRow(
                title: L10n.text("验证结果", "Verify Results"),
                isComplete: false,
                isCurrent: isVerifying
            )
            Divider()
            CleanupExecutionStageRow(
                title: L10n.text("整理报告", "Prepare Report"),
                isComplete: false,
                isCurrent: false
            )
        }
        .frame(maxWidth: 390)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.diagnostic,
            prominence: .quiet
        )
    }
}

private struct CleanupExecutionStageRow: View {
    let title: String
    let isComplete: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppDesignTokens.Palette.success)
            } else if isCurrent {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            Text(title)
                .font(AppDesignTokens.Typography.metadata)
            Spacer()
        }
        .padding(.horizontal, AppDesignTokens.Layout.compactPadding)
        .padding(.vertical, 7)
    }
}

private struct CleanupReportDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }
}

struct CleanupV2OperationOverlay: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore
    let progress: CleanupExecutionProgress?
    let report: CleanReport?

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: AppDesignTokens.Spacing.large) {
                if let report {
                    reportContent(report)
                } else if let progress {
                    progressContent(progress)
                }
            }
            .padding(30)
            .frame(width: 560)
            .glassPanel(
                cornerRadius: AppDesignTokens.Layout.heroRadius,
                tint: report?.outcome == .completed
                    ? AppDesignTokens.Palette.success
                    : theme.actionFill,
                elevated: true
            )
            .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progressContent(_ progress: CleanupExecutionProgress) -> some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            AppStateIconRing(
                systemImage: "trash",
                progress: progress.totalItemCount > 0
                    ? Double(progress.processedItemCount) / Double(progress.totalItemCount)
                    : nil,
                isActive: true
            )
            Text(progressTitle)
                .font(AppDesignTokens.Typography.sheetTitle)
            Text(L10n.text(
                "已处理 \(progress.processedItemCount) / \(progress.totalItemCount) 项；成功 \(progress.movedItemCount)，跳过 \(progress.skippedItemCount)，失败 \(progress.failedItemCount)。",
                "Processed \(progress.processedItemCount) of \(progress.totalItemCount); \(progress.movedItemCount) moved, \(progress.skippedItemCount) skipped, \(progress.failedItemCount) failed."
            ))
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Button(L10n.text("安全取消", "Cancel Safely")) {
                store.cancelV2CleanupExecution()
            }
            .appButtonChrome(.secondary)
        }
    }

    private func reportContent(_ report: CleanReport) -> some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            AppStateIconRing(
                systemImage: report.outcome == .completed
                    ? "checkmark.shield.fill"
                    : "exclamationmark.shield.fill",
                tint: report.outcome == .completed
                    ? AppDesignTokens.Palette.success
                    : AppDesignTokens.Palette.warning
            )

            Text(reportTitle(report))
                .font(AppDesignTokens.Typography.sheetTitle)
            Text(L10n.text(
                "已移动 \(report.summary.movedItemCount) 项，跳过 \(report.summary.skippedItemCount) 项，失败 \(report.summary.failedItemCount) 项，未处理 \(report.summary.notProcessedItemCount) 项。",
                "\(report.summary.movedItemCount) moved, \(report.summary.skippedItemCount) skipped, \(report.summary.failedItemCount) failed, \(report.summary.notProcessedItemCount) not processed."
            ))
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(.secondary)

            HStack(spacing: AppDesignTokens.Spacing.medium) {
                reportMetric(
                    title: L10n.text("已移动体积", "Moved Size"),
                    value: ByteFormat.string(report.summary.movedToRecoverableLocationBytes)
                )
                reportMetric(
                    title: L10n.text("永久释放", "Permanently Freed"),
                    value: ByteFormat.string(report.summary.permanentlyFreedBytes)
                )
                reportMetric(
                    title: L10n.text("可用空间变化", "Available Space Change"),
                    value: availableSpaceDeltaText(report.summary.availableSpaceDeltaBytes)
                )
                reportMetric(
                    title: L10n.text("可恢复", "Restorable"),
                    value: L10n.items(report.restorableReceipts.count)
                )
            }

            if report.disposition == .trash {
                let reclaimableText = report.summary.reclaimableAfterEmptyingTrashBytes
                    .map(ByteFormat.string) ?? L10n.text("未知", "Unknown")
                Label(
                    L10n.text(
                        "清空废纸篓后预计可回收 \(reclaimableText)",
                        "Estimated reclaimable after emptying Trash: \(reclaimableText)"
                    ),
                    systemImage: "trash"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            }

            if report.summary.unverifiedMoveCount > 0 {
                Label(
                    L10n.text(
                        "\(report.summary.unverifiedMoveCount) 项已移动但无法验证新位置身份，因此不提供自动恢复。",
                        "\(report.summary.unverifiedMoveCount) moved item(s) could not be identity-verified at the destination, so automatic restore is unavailable."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.warning)
            }

            let issueItems = report.items.filter {
                if case .moved = $0.outcome { return false }
                return true
            }
            if !issueItems.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(issueItems) { item in
                            HStack(spacing: AppDesignTokens.Spacing.small) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(AppDesignTokens.Palette.warning)
                                    .accessibilityHidden(true)
                                Text(URL(fileURLWithPath: item.sourcePath).lastPathComponent)
                                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Text(reportIssueDetail(item.outcome))
                                    .font(AppDesignTokens.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 7)
                            if item.id != issueItems.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
                .padding(.horizontal, 12)
                .glassPanel(
                    cornerRadius: AppDesignTokens.Layout.rowRadius,
                    tint: AppDesignTokens.Palette.warning,
                    prominence: .quiet
                )
            }

            if let recovery = store.cleanupRecoveryReport {
                Label(
                    L10n.text(
                        "恢复完成：成功 \(recovery.restoredCount) 项，其余项目因冲突、缺失或身份变化保持原状。",
                        "Restore finished: \(recovery.restoredCount) item(s) restored; conflicts, missing items, or identity changes were left untouched."
                    ),
                    systemImage: "arrow.uturn.backward.circle.fill"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: AppDesignTokens.Spacing.small) {
                if !report.restorableReceipts.isEmpty,
                   store.cleanupRecoveryReport == nil {
                    Button {
                        store.requestRestoreLatestV2Cleanup()
                    } label: {
                        Label(L10n.text("恢复", "Restore"), systemImage: "arrow.uturn.backward")
                    }
                    .appButtonChrome(.secondary)
                    .disabled(store.isRestoringV2Cleanup)
                }
                Button {
                    store.openLatestV2CleanupLocation()
                } label: {
                    Label(L10n.text("查看位置", "Show Location"), systemImage: "folder")
                }
                .appButtonChrome(.secondary)
                Button(L10n.text("完成", "Done")) {
                    store.dismissV2CleanupReport()
                }
                .appButtonChrome(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isRestoringV2Cleanup)
            }
        }
    }

    private func reportMetric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
            Text(title)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.rowRadius,
            tint: theme.actionFill,
            prominence: .quiet
        )
    }

    private func availableSpaceDeltaText(_ bytes: Int64?) -> String {
        guard let bytes else {
            return L10n.text("无法测量", "Unavailable")
        }
        if bytes > 0 {
            return "+\(ByteFormat.string(bytes))"
        }
        if bytes < 0 {
            let magnitude = bytes == .min ? Int64.max : -bytes
            return "−\(ByteFormat.string(magnitude))"
        }
        return ByteFormat.string(bytes)
    }

    private func reportIssueDetail(_ outcome: CleanItemOutcome) -> String {
        switch outcome {
        case .moved:
            return L10n.text("已移动", "Moved")
        case let .skipped(reason):
            return CleanSkipReasonPresentation.title(reason)
        case let .failed(failure):
            return failureTitle(failure)
        case .notProcessed:
            return L10n.text("取消后未处理", "Not processed after cancellation")
        }
    }

    private func failureTitle(_ failure: CleanFailure) -> String {
        if let detailCode = failure.detailCode {
            switch detailCode {
            case "permission-denied":
                return L10n.text("权限不足", "Permission denied")
            case "volume-or-item-unavailable":
                return L10n.text("卷或项目不可用", "Volume or item unavailable")
            case "cross-volume":
                return L10n.text("隔离区不允许跨卷移动", "Quarantine cannot move across volumes")
            case "invalid-lease":
                return L10n.text("执行租约已失效", "Execution lease expired")
            default:
                break
            }
        }
        switch failure.code {
        case .trashMoveRejected:
            return L10n.text("系统拒绝移入废纸篓", "Trash move rejected")
        case .trashMoveFailed:
            return L10n.text("移入废纸篓失败", "Trash move failed")
        case .quarantineMoveFailed:
            return L10n.text("移入隔离区失败", "Quarantine move failed")
        case .metadataReadFailed:
            return L10n.text("无法读取文件信息", "Could not read file metadata")
        case .planIntegrityFailed:
            return L10n.text("计划完整性检查失败", "Plan integrity check failed")
        case .featureDisabled:
            return L10n.text("安全清理未启用", "Safe cleanup is disabled")
        case .coordinatorBusy:
            return L10n.text("其他任务正在运行", "Another task is running")
        case .unexpected:
            return L10n.text("发生未知错误", "An unexpected error occurred")
        }
    }

    private var progressTitle: String {
        if case .cancellingExecution = store.cleanupWorkflowState {
            return L10n.text("正在安全停止", "Stopping Safely")
        }
        return L10n.text("正在执行冻结计划", "Executing Frozen Plan")
    }

    private func reportTitle(_ report: CleanReport) -> String {
        switch report.outcome {
        case .completed:
            L10n.text("安全清理完成", "Safe Cleanup Complete")
        case .partiallyCompleted:
            L10n.text("安全清理部分完成", "Safe Cleanup Partially Complete")
        case .cancelled:
            L10n.text("安全清理已取消", "Safe Cleanup Cancelled")
        case .failed:
            L10n.text("安全清理未完成", "Safe Cleanup Failed")
        }
    }
}

enum CleanSkipReasonPresentation {
    static func title(_ reason: CleanSkipReason) -> String {
        switch reason {
        case .preflightNotApproved: L10n.text("未通过本次执行前检查", "Not approved by this preflight")
        case .itemMissing: L10n.text("项目已不存在", "Item no longer exists")
        case .identityChanged: L10n.text("文件身份已变化", "File identity changed")
        case .entryKindChanged: L10n.text("文件类型已变化", "Entry type changed")
        case .pathOutsideAllowedRoot: L10n.text("路径超出允许范围", "Path left the allowed root")
        case .symbolicLinkDetected: L10n.text("检测到符号链接替换", "Symbolic-link replacement detected")
        case .volumeChanged: L10n.text("卷身份已变化", "Volume identity changed")
        case .volumeUnavailable: L10n.text("卷已断开或不可用", "Volume disconnected or unavailable")
        case .volumeReadOnly: L10n.text("卷已变为只读", "Volume became read-only")
        case .permissionChanged: L10n.text("权限已变化", "Permission changed")
        case .excludedByUser: L10n.text("当前已被排除", "Currently excluded")
        case .cloudStateChanged: L10n.text("云文件状态已变化", "Cloud state changed")
        case .relatedAppStillRunning: L10n.text("相关应用仍在运行", "Related app is still running")
        case .rulesChanged: L10n.text("清理规则已变化", "Cleanup rules changed")
        case .measurementIncomplete:
            L10n.text("容量测量不完整，未执行", "Measurement is incomplete; item was not run")
        case .duplicateEvidenceInvalid:
            L10n.text("重复文件证据无效，请重新扫描", "Duplicate evidence is invalid; scan again")
        case .duplicateRetainedCopyChanged:
            L10n.text("计划保留的副本已变化或不可读取", "A retained copy changed or is unreadable")
        case .duplicateContentChanged:
            L10n.text("文件内容已变化，不再确认相同", "File content changed and is no longer confirmed identical")
        case .candidateBecameActive:
            L10n.text("开发文件在扫描后发生变化，请重新扫描", "Developer files changed after the scan; scan again")
        }
    }
}
