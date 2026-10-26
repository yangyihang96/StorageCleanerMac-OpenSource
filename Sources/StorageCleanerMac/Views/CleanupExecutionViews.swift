import SwiftUI

/// The binding ContentView presents the confirmation sheet with; tests use
/// the same one. It reads the store's single test, so the sheet also opens
/// when nothing passed the check (P1-1, round 3).
@MainActor
enum CleanupPlanConfirmationPresentation {
    static func binding(for store: ScanStore) -> Binding<Bool> {
        Binding {
            store.isV2CleanupConfirmationPresented
        } set: { isPresented in
            if !isPresented {
                store.cancelV2CleanupConfirmation()
            }
        }
    }
}

/// D101 G13: the summary of an unusually large run.
enum CleanPlanScaleAlertPresentation {
    static func summary(_ alert: CleanPlanScaleAlert) -> String {
        var sentences = [L10n.text(
            "这次将处理 \(alert.itemCount.formatted()) 项，共 \(ByteFormat.storageString(alert.bytes))。",
            "This run handles \(alert.itemCount.formatted()) item(s), \(ByteFormat.storageString(alert.bytes)) in all."
        )]
        if alert.exceedsItemCount {
            sentences.append(L10n.text(
                "项目数超过单次 \(CleanPlanScaleAlert.itemCountLimit.formatted()) 项的提醒线。",
                "That is more than \(CleanPlanScaleAlert.itemCountLimit.formatted()) items, the mark for one run."
            ))
        }
        for share in alert.largeVolumeShares {
            sentences.append(L10n.text(
                "其中 \(ByteFormat.storageString(share.plannedBytes)) 在同一块磁盘上，超过这块磁盘已用空间（\(ByteFormat.storageString(share.usedBytes))）的一半。",
                "\(ByteFormat.storageString(share.plannedBytes)) of it is on one disk, more than half of that disk's used space (\(ByteFormat.storageString(share.usedBytes)))."
            ))
        }
        return sentences.joined(separator: L10n.text("", " "))
    }
}

struct CleanupPlanConfirmationSheet: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore
    let plan: CleanPlan
    let preflight: CleanPreflightReport
    @State private var showsDetails = false
    @State private var acknowledgesReviewedItems = false
    @State private var acknowledgesProtectedIdentity = false
    @State private var acknowledgesProtectedTrashMove = false
    @State private var acknowledgesPermanentDeletion = false
    @State private var acknowledgesTrashContentsReviewed = false
    /// D101 G13: the summary the user checked; a different one is unchecked.
    @State private var acknowledgedScaleAlert: CleanPlanScaleAlert?

    var body: some View {
        // P2-11: built once per body refresh (it queries running apps and walks the plan).
        let facts = confirmationFacts
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                Image(systemName: confirmationSystemImage)
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(confirmationTint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(facts.cleanupPlanTitle(
                        planHasMoves: !plan.trashMoveItems.isEmpty,
                        planHasPermanentDeletion: !plan.permanentDeletionItems.isEmpty
                    ))
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .monospacedDigit()
                    Text(dispositionSummary(facts))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: AppDesignTokens.Spacing.medium) {
                // D93 P1-1/P2-1/P2-12: the same item set and bytes as the title and the six
                // fields below — all planned items, then only the ones that will run.
                compactMetric(L10n.items(facts.itemCount), L10n.text("项目", "Items"))
                Divider().frame(height: 28)
                compactMetric(
                    ByteFormat.storageString(facts.trashBytes + facts.quarantineBytes),
                    plan.disposition == .trash
                        ? L10n.text("将移入废纸篓", "Move to Trash")
                        : L10n.text("将移入隔离区", "Move to Quarantine")
                )
                if !plan.permanentDeletionItems.isEmpty {
                    Divider().frame(height: 28)
                    compactMetric(
                        ByteFormat.storageString(facts.permanentDeletionBytes),
                        L10n.text("将永久删除", "Delete Permanently")
                    )
                }
                Divider().frame(height: 28)
                compactMetric(L10n.items(facts.readyCount), L10n.text("将执行", "Will Run"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // D93: the six fixed fields every cleanup confirmation lists.
            OperationConfirmationFactsView(facts: facts)

            if plan.disposition == .trash,
               let trashNote = facts.cleanupTrashReleaseNote(planHasTrashMoves: !plan.trashMoveItems.isEmpty) {
                Label(trashNote, systemImage: "trash")
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            }

            Label(preflightSummary, systemImage: preflight.isConfirmable ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(preflight.isConfirmable ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning)

            // D179: only when something is skipped (was also any partial
            // scan, which then read "0 项受限，不会执行。").
            if preflight.skippedCount > 0 {
                Label(
                    L10n.text(
                        "\(ByteFormat.count(preflight.skippedCount)) 项受限，不会执行。",
                        "\(ByteFormat.count(preflight.skippedCount)) item(s) are limited and will not run."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.warning)
            }

            if let scaleAlert = preflight.scaleAlert {
                scaleConfirmation(scaleAlert)
            }

            if !plan.reviewItems.isEmpty {
                reviewedItemsConfirmation
            }

            if !plan.protectedMoveItems.isEmpty {
                protectedItemsConfirmation
            }

            // D23: emptying the Trash is shown and confirmed on its own.
            if !plan.permanentDeletionItems.isEmpty {
                permanentDeletionConfirmation
            }

            if !skippedItems.isEmpty {
                skippedItemsSection
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
                                Text(ByteFormat.storageString(item.estimatedSizeBytes))
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
                        protectedRiskAcknowledged: protectedRiskAcknowledged,
                        protectedTrashMoveAcknowledged: protectedTrashMoveAcknowledged,
                        permanentDeletionAcknowledged: permanentDeletionAcknowledged,
                        scaleAcknowledged: acknowledgedScaleAlert
                    )
                } label: {
                    Label(confirmTitle, systemImage: dispositionSystemImage)
                }
                .appButtonChrome(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !preflight.isConfirmable
                        || isBusy
                        || (!plan.reviewItems.isEmpty && !acknowledgesReviewedItems)
                        || !protectedRiskAcknowledged
                        || !protectedTrashMoveAcknowledged
                        || !permanentDeletionAcknowledged
                        || !scaleAcknowledged
                )
            }
        }
        .padding(20)
        .confirmationDialog(
            L10n.text("正常退出这些应用？", "Quit These Apps Normally?"),
            isPresented: Binding(
                get: { store.cleanupOwnerQuitRequest?.isFromConfirmation == true },
                set: { if !$0 { store.cancelQuitCleanupOwners() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("正常退出并清理", "Quit Normally and Clean")) {
                store.quitOwnersAndRecheckCleanup()
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelQuitCleanupOwners()
            }
        } message: {
            Text(CleanupOwnerQuitPresentation.message(for: store.cleanupOwnerQuitRequest))
        }
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
                "已手动选择 \(ByteFormat.count(plan.reviewItems.count)) 项（\(ByteFormat.storageString(plan.reviewItemBytes))）。这些内容可能包含个人文件或应用状态；请确认已核对内容、归属和备份。",
                "You manually selected \(ByteFormat.count(plan.reviewItems.count)) item(s) (\(ByteFormat.storageString(plan.reviewItemBytes))). They may contain personal files or app state; confirm content, ownership, and backups."
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
                                Text(ByteFormat.storageString(item.estimatedSizeBytes))
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
            .frame(height: min(CGFloat(plan.reviewItems.count) * 66, sectionListHeightLimit(190)))

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
                "已手动选择 \(ByteFormat.count(plan.protectedMoveItems.count)) 个红色项目（\(ByteFormat.storageString(plan.protectedMoveItemBytes))）。其中可能包含近期开发产物或重复的应用副本；请确认当前任务不再使用。重复应用整组勾选时已自动保留一份，保留的副本不在下面的列表中。",
                "You manually selected \(ByteFormat.count(plan.protectedMoveItems.count)) red item(s) (\(ByteFormat.storageString(plan.protectedMoveItemBytes))). These may be recent developer artifacts or duplicate app copies; confirm no current task uses them. When a whole duplicate-app group was checked, one copy was kept automatically and is not listed below."
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    ForEach(plan.protectedMoveItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: AppDesignTokens.Spacing.small) {
                                Text(item.sourceURL.lastPathComponent)
                                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(ByteFormat.storageString(item.estimatedSizeBytes))
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
            .frame(height: min(CGFloat(plan.protectedMoveItems.count) * 52, sectionListHeightLimit(156)))

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

    /// D23: permanent deletion has its own section and its own two
    /// confirmations, separate from items that only move to Trash.
    private var permanentDeletionConfirmation: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(
                L10n.text("清空废纸篓 · 不可恢复", "Empty Trash · Cannot Be Undone"),
                systemImage: "trash.slash.fill"
            )
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            .foregroundStyle(AppDesignTokens.Palette.destructive)

            Text(L10n.text(
                "将永久删除扫描时废纸篓里的 \(ByteFormat.count(plan.permanentDeletionItems.count)) 项（\(ByteFormat.storageString(plan.permanentDeletionBytes))），删除后无法从废纸篓恢复；其中如有早先清理移入的文件，之后也无法再从“操作记录”恢复。扫描后放入废纸篓的项目，包括本次移入的文件，不会被删除。",
                "This permanently deletes the \(ByteFormat.count(plan.permanentDeletionItems.count)) item(s) that were in the Trash during the scan (\(ByteFormat.storageString(plan.permanentDeletionBytes))). They cannot be restored from the Trash afterwards, and files an earlier cleanup moved there can no longer be restored from Operation History. Items put in the Trash after the scan, including this cleanup's files, are not deleted."
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(plan.permanentDeletionItems.prefix(5))) { item in
                    HStack(spacing: AppDesignTokens.Spacing.small) {
                        Text(item.sourceURL.lastPathComponent)
                            .font(AppDesignTokens.Typography.metadata)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(ByteFormat.storageString(item.estimatedSizeBytes))
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .help(item.sourceURL.path)
                }
                if plan.permanentDeletionItems.count > 5 {
                    Text(L10n.text(
                        "另有 \(plan.permanentDeletionItems.count - 5) 项",
                        "\(plan.permanentDeletionItems.count - 5) more item(s)"
                    ))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $acknowledgesPermanentDeletion) {
                Text(L10n.text(
                    "我了解这些项目会被永久删除，无法恢复",
                    "I understand these items will be permanently deleted and cannot be restored"
                ))
                .font(AppDesignTokens.Typography.metadata)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $acknowledgesTrashContentsReviewed) {
                Text(Self.trashContentsAcknowledgement(for: plan))
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

    /// The store requires both red confirmations for red items that move to
    /// Trash, and (A2) its own two confirmations for emptying the Trash.
    private var protectedRiskAcknowledged: Bool {
        plan.protectedMoveItems.isEmpty || acknowledgesProtectedIdentity
    }

    private var protectedTrashMoveAcknowledged: Bool {
        plan.protectedMoveItems.isEmpty || acknowledgesProtectedTrashMove
    }

    nonisolated static func trashContentsAcknowledgement(for plan: CleanPlan) -> String {
        if plan.permanentDeletionItems.contains(where: { $0.ruleID == "trash.icloud-drive" }) {
            return L10n.text("我已确认没有需要保留的文件；会从你所有设备上的 iCloud 云盘永久删除，不能撤销",
                      "I confirmed there is nothing to keep; this permanently deletes from iCloud Drive on all your devices and cannot be undone")
        }
        return L10n.text("我已确认废纸篓里没有需要保留的文件", "I confirmed the Trash holds nothing I need to keep")
    }

    private var permanentDeletionAcknowledged: Bool {
        Self.permanentDeletionAcknowledged(for: plan, deletion: acknowledgesPermanentDeletion,
                                          contentsReviewed: acknowledgesTrashContentsReviewed)
    }

    nonisolated static func permanentDeletionAcknowledged(
        for plan: CleanPlan, deletion: Bool, contentsReviewed: Bool
    ) -> Bool {
        plan.permanentDeletionItems.isEmpty || (deletion && contentsReviewed)
    }

    private var scaleAcknowledged: Bool {
        preflight.scaleAlert == nil || acknowledgedScaleAlert == preflight.scaleAlert
    }

    /// D101 G13: an unusually large run shows its size and largest kinds and
    /// asks once more. Not a block; a normal run never shows it.
    private func scaleConfirmation(_ alert: CleanPlanScaleAlert) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(
                L10n.text("本次清理规模异常，需要再确认一次", "This cleanup is unusually large; confirm once more"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            .foregroundStyle(AppDesignTokens.Palette.warning)

            Text(CleanPlanScaleAlertPresentation.summary(alert))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(alert.largestRules, id: \.ruleID) { rule in
                    HStack(spacing: AppDesignTokens.Spacing.small) {
                        Text(rule.title)
                            .font(AppDesignTokens.Typography.metadata)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(L10n.items(rule.itemCount)) · \(ByteFormat.storageString(rule.bytes))")
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { acknowledgedScaleAlert == alert },
                set: { acknowledgedScaleAlert = $0 ? alert : nil }
            )) {
                Text(L10n.text(
                    "我已核对本次清理的数量、大小和最大的几类，确认没有误选",
                    "I checked this cleanup's item count, size and largest kinds, and nothing was selected by mistake"
                ))
                .font(AppDesignTokens.Typography.metadata)
            }
            .toggleStyle(.checkbox)
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.rowRadius,
            tint: AppDesignTokens.Palette.warning,
            prominence: .quiet
        )
    }

    /// A2: items that did not pass the check, each with its reason.
    private var skippedItems: [(item: CleanPlanItem, reason: CleanSkipReason)] {
        let reasons = Dictionary(uniqueKeysWithValues: preflight.items.compactMap { item -> (UUID, CleanSkipReason)? in
            guard case let .skipped(reason) = item.status else { return nil }
            return (item.planItemID, reason)
        })
        return plan.items.compactMap { item in reasons[item.id].map { (item, $0) } }
    }

    private var hasItemsWaitingForRunningApps: Bool {
        skippedItems.contains { $0.reason == .relatedAppStillRunning }
    }

    /// Round 3 (P2-1): which of those apps can be asked to quit.
    private var waitingOwnerOptions: CleanupOwnerQuitService.Options {
        hasItemsWaitingForRunningApps ? store.pendingCleanupOwnerQuitOptions : .init()
    }

    private var isBusy: Bool {
        store.isRecheckingCleanup || store.isQuittingCleanupOwners
    }

    /// A2: every item that did not pass, with its reason; running apps can be
    /// asked to quit normally from here.
    private var skippedItemsSection: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(
                preflight.isConfirmable
                    ? L10n.text("以下项目未通过检查，不会执行", "These items did not pass the check and will not run")
                    : L10n.text("所有项目都未通过检查，暂不能执行", "No item passed the check, so nothing can run yet"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            .foregroundStyle(AppDesignTokens.Palette.warning)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(skippedItems, id: \.item.id) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
                            Text(entry.item.sourceURL.lastPathComponent)
                                .font(AppDesignTokens.Typography.metadata)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(CleanSkipReasonPresentation.title(entry.reason))
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(AppDesignTokens.Palette.warning)
                                .multilineTextAlignment(.trailing)
                        }
                        .help(entry.item.sourceURL.path)
                    }
                }
            }
            .frame(height: min(CGFloat(skippedItems.count) * 22, sectionListHeightLimit(132)))

            let ownerOptions = waitingOwnerOptions
            if !ownerOptions.quittable.isEmpty {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Button(L10n.text("正常退出并清理", "Quit Normally and Clean")) {
                        store.requestQuitCleanupOwnersForPendingPlan()
                    }
                    .appButtonChrome(.secondary)
                    .disabled(isBusy)
                    Text(L10n.text(
                        "先列出将退出的应用并请你确认；只发送正常退出请求，不强制结束。",
                        "Lists the apps first for your confirmation; only a normal quit request is sent, never a force quit."
                    ))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !ownerOptions.manual.isEmpty {
                Label(
                    CleanupOwnerQuitPresentation.manualQuitText(for: ownerOptions.manual),
                    systemImage: "hand.raised"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            if isBusy {
                ProgressView(store.isQuittingCleanupOwners
                    ? L10n.text("正在等待应用退出…", "Waiting for the apps to quit…")
                    : L10n.text("正在重新检查…", "Checking again…"))
                    .controlSize(.small)
                    .font(AppDesignTokens.Typography.metadata)
            }
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.rowRadius,
            tint: AppDesignTokens.Palette.warning,
            prominence: .quiet
        )
    }

    /// D93: action, items, space (D84 local usage), apps to quit, recovery
    /// and permission coverage for this frozen plan.
    private var confirmationFacts: OperationConfirmationFacts {
        .cleanupPlan(
            plan,
            preflight: preflight,
            surface: .inferred(for: plan, session: store.cleanupScanSession),
            appsToQuit: OperationQuitNotice.appNames(store.pendingCleanupOwnerQuitOptions),
            permission: .from(store.scanReadinessSummary)
        )
    }

    /// Keeps the sheet within a window when several confirmation sections show.
    private func sectionListHeightLimit(_ single: CGFloat) -> CGFloat {
        let sections = [
            !plan.reviewItems.isEmpty,
            !plan.protectedMoveItems.isEmpty,
            !plan.permanentDeletionItems.isEmpty,
        ].filter { $0 }.count
        return sections > 1 ? min(single, 104) : single
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

    private func dispositionSummary(_ facts: OperationConfirmationFacts) -> String {
        if plan.trashMoveItems.isEmpty {
            return L10n.text(
                "废纸篓中扫描时已有的项目将被永久删除，无法恢复。",
                "Items that were in the Trash during the scan will be permanently deleted and cannot be recovered."
            )
        }
        // D93 P2-12: when no move will run, the subtitle must not promise one.
        let moveAction: OperationActionKind = plan.disposition == .trash ? .moveToTrash : .moveToQuarantine
        guard facts.actions.contains(moveAction) else {
            return L10n.text("选中的移动项目都不会执行，本次不会移动任何项目。",
                             "None of the selected moves will run; nothing will be moved this time.")
        }
        let moves = plan.disposition == .trash
            ? L10n.text("选中项目将移入废纸篓，可在需要时恢复。", "Selected items move to Trash and can be recovered if needed.")
            : L10n.text("选中项目将移入隔离区，可在需要时恢复。", "Selected items move to quarantine and can be recovered if needed.")
        guard !plan.permanentDeletionItems.isEmpty else { return moves }
        return moves + L10n.text(
            "清空废纸篓的部分不可恢复。",
            " Emptying the Trash cannot be undone."
        )
    }

    private var preflightSummary: String {
        if preflight.isConfirmable {
            return L10n.text("安全检查已通过", "Safety check passed")
        }
        return L10n.text("安全检查尚未通过", "Safety check is not ready")
    }

    private var confirmTitle: String {
        if !plan.permanentDeletionItems.isEmpty {
            return plan.trashMoveItems.isEmpty
                ? L10n.text("确认永久清空", "Confirm Permanent Deletion")
                : L10n.text("确认清理并清空废纸篓", "Confirm Cleanup and Empty Trash")
        }
        return plan.disposition == .trash
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
        let processed = L10n.text(
            "已处理 \(ByteFormat.count(progress.processedItemCount)) / \(ByteFormat.count(progress.totalItemCount)) 项；已移动 \(ByteFormat.count(progress.movedItemCount))，跳过 \(ByteFormat.count(progress.skippedItemCount))，失败 \(ByteFormat.count(progress.failedItemCount))。",
            "Processed \(ByteFormat.count(progress.processedItemCount)) of \(ByteFormat.count(progress.totalItemCount)); \(ByteFormat.count(progress.movedItemCount)) moved, \(ByteFormat.count(progress.skippedItemCount)) skipped, \(ByteFormat.count(progress.failedItemCount)) failed."
        )
        guard progress.deletedItemCount > 0 else { return processed }
        return processed + L10n.text(
            "已从废纸篓永久删除 \(ByteFormat.count(progress.deletedItemCount)) 项。",
            " \(ByteFormat.count(progress.deletedItemCount)) permanently deleted from Trash."
        )
    }

    /// Tests of the D70 running page set `careStudioClassicResults`.
    @Environment(\.careStudioClassicResults) private var usesClassicPage

    var body: some View {
        if usesClassicPage {
            classicPage
        } else {
            studioPage
        }
    }

    private var classicPage: some View {
        LegacyFeatureRuntimePage(
            module: .green, title: title, subtitle: detail,
            state: isCancelling ? .stopping : .running,
            fraction: progressFraction,
            metrics: progress.map { [
                RuntimeWorkflowMetric(title: L10n.text("已移动", "Moved"), value: String($0.movedItemCount)),
                RuntimeWorkflowMetric(title: L10n.text("已跳过", "Skipped"), value: String($0.skippedItemCount)),
                RuntimeWorkflowMetric(title: L10n.text("未完成", "Not Completed"), value: String($0.failedItemCount))
            ] } ?? [],
            trustText: L10n.text("仅处理已确认项目 · 移至废纸篓后验证", "Confirmed items only · Verify after moving to Trash")
        ) {
            CleanupExecutionStageList(hasStartedMoving: progress != nil,
                isVerifying: isVerifying, isCancelling: isCancelling)
        } actions: {
            if let onCancel {
                Button(isCancelling ? L10n.text("正在停止", "Stopping") : L10n.text("安全取消", "Cancel Safely"), action: onCancel)
                    .appButtonChrome(.secondary).disabled(isCancelling)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// D141: the CleanMyMac running page — the picture working, the count,
    /// and Stop ringed by the progress; the four stages stay listed below.
    private var studioPage: some View {
        CareStudioCleaningPage(
            module: CareStudioModule.junkFlow(route: store.scanPresentationRoute),
            title: title, detail: detail, progress: progress,
            planItems: store.pendingCleanPlan.flatMap { plan in
                progress == nil || progress?.planID == plan.id ? plan.items : nil
            } ?? [],
            isCancelling: isCancelling, onCancel: onCancel
        ) {
            CleanupExecutionStageList(hasStartedMoving: progress != nil,
                isVerifying: isVerifying, isCancelling: isCancelling, onStudio: true)
        }
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
    /// D168: Smart Care's Run lists its other cards' results above the report.
    var otherResults: [String] = []
    @State private var showsDetails = false

    private var didMoveToTrash: Bool { report.disposition == .trash }

    private var result: OperationResultPresentation { OperationResultPresentation(report: report) }
    /// D214: the run never started; the page says why and offers only Back.
    private var refusal: CleanFailure? { report.startRefusal }
    private var title: String { result.title }
    private var summary: String { refusal.map(CleanStartRefusalPresentation.message) ?? result.summary }
    private var outcomeState: RuntimeWorkflowState {
        switch result.state {
        case .completed, .restored: .completed
        case .failed, .recoveryFailed: .failed
        case .cancelled, .retained: .cancelled
        default: .attention
        }
    }

    private var deletedItemCount: Int { report.summary.deletedItemCount ?? 0 }

    private var metrics: [RuntimeWorkflowMetric] {
        if refusal != nil {
            return [.init(title: L10n.text("未执行", "Not Run"), value: ByteFormat.count(report.summary.notProcessedItemCount))]
        }
        var metrics: [RuntimeWorkflowMetric] = [
            .init(title: L10n.text("原操作移走体积", "Originally Moved Size"),
                  value: ByteFormat.storageString(report.summary.movedToRecoverableLocationBytes)),
            .init(title: L10n.text("已移动", "Moved"), value: String(report.summary.movedItemCount)),
            .init(title: L10n.text("跳过 / 失败", "Skipped / Failed"),
                  value: "\(ByteFormat.count(report.summary.skippedItemCount)) / \(ByteFormat.count(report.summary.failedItemCount))")
        ]
        if deletedItemCount > 0 {
            metrics.insert(.init(
                title: L10n.text("永久删除", "Permanently Deleted"),
                value: ByteFormat.storageString(report.summary.permanentlyFreedBytes)
            ), at: 2)
        }
        return metrics
    }

    private var trustText: String {
        if refusal != nil { return CleanStartRefusalPresentation.nothingMoved }
        if result.restoredCount > 0 {
            return L10n.text("移动体积保留为历史记录，已恢复项目不计为可回收空间。", "Moved size is historical; restored items are not reclaimable space.")
        }
        if report.summary.movedItemCount == 0 {
            return deletedItemCount > 0
                ? L10n.text("废纸篓中的项目已永久删除，无法恢复", "Trash items were permanently deleted and cannot be restored")
                : L10n.text("未移动任何文件", "No files were moved")
        }
        if deletedItemCount > 0 {
            return L10n.text("移入的文件可从废纸篓恢复 · 已清空的废纸篓项目无法恢复", "Moved files can be restored from Trash · Emptied Trash items cannot")
        }
        return didMoveToTrash
            ? L10n.text("文件可从废纸篓恢复 · 清空后才会释放空间", "Restore files from Trash · Space is reclaimed when Trash is emptied")
            : L10n.text("文件已安全隔离，可恢复", "Quarantined files can be restored")
    }

    /// Tests of the D70 report page set `careStudioClassicResults`.
    @Environment(\.careStudioClassicResults) private var usesClassicPage

    /// D141: the CleanMyMac finished page — success picture, title, the
    /// moved size (D93: never called freed), then the tally, the issues and
    /// the details; Done is the round button. The D70 page stays as the
    /// classic view; both show the same report content.
    var body: some View {
        if usesClassicPage {
            classicPage
        } else {
            studioPage
        }
    }

    @ViewBuilder
    private var reportContent: some View {
        if !otherResults.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(otherResults, id: \.self) { Text($0) }
            }
            .font(AppDesignTokens.Typography.body)
            .frame(maxWidth: 430, alignment: .leading)
#if DEBUG
            .layoutProbe("smartCare.run.otherResults")
#endif
        }
        if refusal == nil {
            outcomeContent
        }
    }

    /// The tally, the issues and the details of a run that started.
    @ViewBuilder
    private var outcomeContent: some View {
        if report.persistenceFailure != nil {
            Text(L10n.text("部分回执尚未保存；已发生的移动仍列在下方，请保留本次结果。", "Some receipts could not be saved. Completed moves remain listed below; keep this result."))
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .accessibilityLabel(L10n.text("回执保存失败", "Receipt saving failed"))
        }
        // D93: completed / skipped / failed / needs verification, and
        // space moved to Trash is never called freed.
        // The receipt warning is already shown above; not repeated (P2-7).
        OperationCompletionTallyView(tally: OperationCompletionTally(report: report), showsEntryDetails: false,
                                     showsReceiptNote: false)
            .frame(maxWidth: 430, alignment: .leading)
        // Every skipped or failed item with its reason, so nothing is
        // silently left behind after a cleanup.
        CleanupReportIssueList(report: report)
            .frame(maxWidth: 430, alignment: .leading)
        DisclosureGroup(L10n.text("清理详情", "Cleanup Details"), isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                CleanupReportDetailRow(
                    title: L10n.text("原操作移走体积", "Originally Moved Size"),
                    value: ByteFormat.storageString(report.summary.movedToRecoverableLocationBytes)
                )
                CleanupReportDetailRow(
                    title: L10n.text("原回执预计可回收", "Original Estimated Reclaimable"),
                    value: report.summary.reclaimableAfterEmptyingTrashBytes.map {
                        ByteFormat.storageString($0)
                    } ?? L10n.text("不适用", "Not Applicable")
                )
                CleanupReportDetailRow(
                    title: L10n.text("永久释放", "Permanently Freed"),
                    value: ByteFormat.storageString(report.summary.permanentlyFreedBytes)
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
                        value: "\(ByteFormat.count(report.summary.skippedItemCount)) / \(ByteFormat.count(report.summary.failedItemCount))"
                    )
                }
            }
            .padding(.top, AppDesignTokens.Spacing.small)
        }
        .font(AppDesignTokens.Typography.metadata)
        .padding(AppDesignTokens.Layout.compactPadding)
        .frame(maxWidth: 430, alignment: .leading)
        .modifier(CareStudioAwarePanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: theme.actionFill))
    }

    private var studioPage: some View {
        CareStudioCleanupCompletedLayout(
            module: CareStudioModule.junkFlow(route: store.scanPresentationRoute),
            title: title, summary: summary,
            movedBytes: report.summary.movedToRecoverableLocationBytes,
            note: trustText,
            onDone: { (onDone ?? store.dismissV2CleanupReport)() },
            doneEnabled: !store.isRestoringV2Cleanup,
            showsSuccess: refusal == nil,
            doneTitle: refusal == nil ? L10n.text("完成", "Done") : L10n.text("返回", "Back"),
            showsContent: refusal == nil || !otherResults.isEmpty
        ) {
            reportContent
        } actions: {
            if refusal == nil {
                if !report.restorableReceipts.isEmpty,
                   store.cleanupRecoveryReport == nil {
                    CareStudioPillButton(title: L10n.text("恢复", "Restore"),
                                         systemImage: "arrow.uturn.backward") {
                        store.requestRestoreLatestV2Cleanup()
                    }
                    .disabled(store.isRestoringV2Cleanup)
                }

                if report.summary.movedItemCount > 0 {
                    CareStudioPillButton(title: L10n.text("查看位置", "Show Location"), systemImage: "folder") {
                        store.openLatestV2CleanupLocation()
                    }
                }

                // "完成" (the round button) returns to the rows this scan
                // still lists; a fresh scan is this separate action (live
                // test 2026-10-06).
                CareStudioPillButton(title: L10n.text("重新扫描", "Scan Again"), systemImage: "arrow.clockwise") {
                    store.rescanAfterV2Cleanup()
                }
                .disabled(store.isRestoringV2Cleanup || store.isPreparingScan)
            }
            }
    }

    private var classicPage: some View {
        LegacyFeatureRuntimePage(
            module: .green, title: title, subtitle: summary, state: outcomeState,
            metrics: metrics,
            trustText: trustText
        ) {
            reportContent
        } actions: {
            if refusal != nil {
                Button(L10n.text("返回", "Back")) {
                    (onDone ?? store.dismissV2CleanupReport)()
                }
                .appButtonChrome(.primary)
            } else {
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

                if report.summary.movedItemCount > 0 {
                Button {
                    store.openLatestV2CleanupLocation()
                } label: {
                    Label(L10n.text("查看位置", "Show Location"), systemImage: "folder")
                }
                .appButtonChrome(.secondary)
                }

                // "完成" returns to the rows this scan still lists; a fresh
                // scan is this separate action (live test 2026-10-06).
                Button {
                    store.rescanAfterV2Cleanup()
                } label: {
                    Label(L10n.text("重新扫描", "Scan Again"), systemImage: "arrow.clockwise")
                }
                .appButtonChrome(.secondary)
                .disabled(store.isRestoringV2Cleanup || store.isPreparingScan)

                Button(L10n.text("完成", "Done")) {
                    (onDone ?? store.dismissV2CleanupReport)()
                }
                .appButtonChrome(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isRestoringV2Cleanup)
            }
            }
    }

    private func availableSpaceDeltaText(_ bytes: Int64?) -> String {
        guard let bytes else { return L10n.text("无法测量", "Unavailable") }
        if bytes > 0 { return "+\(ByteFormat.storageString(bytes))" }
        if bytes < 0 {
            let magnitude = bytes == .min ? Int64.max : -bytes
            return "−\(ByteFormat.storageString(magnitude))"
        }
        return ByteFormat.storageString(bytes)
    }
}

private struct CleanupExecutionStageList: View {
    let hasStartedMoving: Bool
    let isVerifying: Bool
    let isCancelling: Bool
    /// D141: on a studio gradient the four stages are the same chips as the
    /// scan categories instead of a glass panel.
    var onStudio = false

    private var studioStages: [CareStudioLiveCategory] {
        func state(complete: Bool, current: Bool) -> CareStudioLiveCategory.State {
            complete ? .found : (current ? .working : .pending)
        }
        return [
            CareStudioLiveCategory(id: "prepare", title: L10n.text("准备清理", "Prepare Cleanup"), systemImage: "",
                state: state(complete: hasStartedMoving || isVerifying,
                             current: !hasStartedMoving && !isVerifying && !isCancelling), bytes: 0),
            CareStudioLiveCategory(id: "move", title: L10n.text("移动项目", "Move Items"), systemImage: "",
                state: state(complete: isVerifying, current: hasStartedMoving && !isVerifying && !isCancelling),
                bytes: 0),
            CareStudioLiveCategory(id: "verify", title: L10n.text("验证结果", "Verify Results"), systemImage: "",
                state: state(complete: false, current: isVerifying), bytes: 0),
            CareStudioLiveCategory(id: "report", title: L10n.text("整理报告", "Prepare Report"), systemImage: "",
                state: .pending, bytes: 0)
        ]
    }

    var body: some View {
        if onStudio {
            CareStudioCategoryStrip(categories: studioStages)
                .frame(maxWidth: 560)
        } else {
            panel
        }
    }

    private var panel: some View {
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
                "已处理 \(ByteFormat.count(progress.processedItemCount)) / \(ByteFormat.count(progress.totalItemCount)) 项；成功 \(ByteFormat.count(progress.movedItemCount))，跳过 \(ByteFormat.count(progress.skippedItemCount))，失败 \(ByteFormat.count(progress.failedItemCount))。",
                "Processed \(ByteFormat.count(progress.processedItemCount)) of \(ByteFormat.count(progress.totalItemCount)); \(ByteFormat.count(progress.movedItemCount)) moved, \(ByteFormat.count(progress.skippedItemCount)) skipped, \(ByteFormat.count(progress.failedItemCount)) failed."
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
        let current = OperationResultPresentation(report: report)
        return VStack(spacing: AppDesignTokens.Spacing.large) {
            AppStateIconRing(
                systemImage: current.systemImage,
                tint: [.completed, .restored].contains(current.state)
                    ? AppDesignTokens.Palette.success
                    : AppDesignTokens.Palette.warning
            )

            Text(reportTitle(report))
                .font(AppDesignTokens.Typography.sheetTitle)
            Text(OperationResultPresentation(report: report).summary)
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(.secondary)

            OperationCompletionTallyView(tally: OperationCompletionTally(report: report), showsEntryDetails: false)

            HStack(spacing: AppDesignTokens.Spacing.medium) {
                reportMetric(
                    title: L10n.text("原操作移走体积", "Originally Moved Size"),
                    value: ByteFormat.storageString(report.summary.movedToRecoverableLocationBytes)
                )
                reportMetric(
                    title: L10n.text("永久释放", "Permanently Freed"),
                    value: ByteFormat.storageString(report.summary.permanentlyFreedBytes)
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

            if report.disposition == .trash && (report.recoveryAttempts ?? []).isEmpty {
                let reclaimableText = report.summary.reclaimableAfterEmptyingTrashBytes
                    .map { ByteFormat.storageString($0) } ?? L10n.text("未知", "Unknown")
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
                        "\(ByteFormat.count(report.summary.unverifiedMoveCount)) 项已移动但无法验证新位置身份，因此不提供自动恢复。",
                        "\(ByteFormat.count(report.summary.unverifiedMoveCount)) moved item(s) could not be identity-verified at the destination, so automatic restore is unavailable."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.warning)
            }

            CleanupReportIssueList(report: report)

            if let recovery = store.cleanupRecoveryReport {
                Label(
                    recovery.resultMessage,
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
            return "+\(ByteFormat.storageString(bytes))"
        }
        if bytes < 0 {
            let magnitude = bytes == .min ? Int64.max : -bytes
            return "−\(ByteFormat.storageString(magnitude))"
        }
        return ByteFormat.storageString(bytes)
    }

    private var progressTitle: String {
        if case .cancellingExecution = store.cleanupWorkflowState {
            return L10n.text("正在安全停止", "Stopping Safely")
        }
        return L10n.text("正在执行冻结计划", "Executing Frozen Plan")
    }

    private func reportTitle(_ report: CleanReport) -> String {
        OperationResultPresentation(report: report).title
    }
}

/// D52 的保守跳过属于仍在使用，实际失败及其他未执行原因保留原分组。
enum CleanupReportIssueGroup: CaseIterable, Hashable {
    case stillInUse, notCompleted

    static func group(for outcome: CleanItemOutcome) -> Self? {
        switch outcome {
        case .moved, .deleted: nil
        case let .skipped(reason):
            CleanSkipReasonPresentation.isStillInUse(reason) ? .stillInUse : .notCompleted
        case .failed, .notProcessed: .notCompleted
        }
    }

    var title: String {
        switch self {
        case .stillInUse: L10n.text("仍在使用，已跳过", "Skipped: still in use")
        case .notCompleted: L10n.text("未完成的项目", "Items Not Completed")
        }
    }

    var systemImage: String { self == .stillInUse ? "minus.circle" : "exclamationmark.circle" }
    var tint: Color { self == .stillInUse ? .secondary : AppDesignTokens.Palette.warning }
}

/// 完成页保留原跳过或失败原因；清理浮层的视图实现尚未接入产品流程。
struct CleanupReportIssueList: View {
    let report: CleanReport

    var body: some View {
        ForEach(CleanupReportIssueGroup.allCases, id: \.self) { group in
            let items = report.items.filter { CleanupReportIssueGroup.group(for: $0.outcome) == group }
            if !items.isEmpty { issueGroup(group, items: items) }
        }
    }

    private func issueGroup(_ group: CleanupReportIssueGroup, items: [CleanReportItem]) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(L10n.text(
                "\(group.title)（\(ByteFormat.count(items.count))）",
                "\(group.title) (\(ByteFormat.count(items.count)))"
            ))
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
                            Image(systemName: group.systemImage)
                                .foregroundStyle(group.tint)
                                .accessibilityHidden(true)
                            Text(URL(fileURLWithPath: item.sourcePath).lastPathComponent)
                                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.sourcePath)
                            Spacer(minLength: AppDesignTokens.Spacing.small)
                            Text(Self.detail(item.outcome))
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .combine)
                        if item.id != items.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(CareStudioAwarePanel(cornerRadius: AppDesignTokens.Layout.rowRadius, tint: group.tint))
    }

    static func detail(_ outcome: CleanItemOutcome) -> String {
        switch outcome {
        case .moved:
            return L10n.text("已移动", "Moved")
        case .deleted:
            return L10n.text("已永久删除", "Permanently deleted")
        case let .skipped(reason):
            // Review r3 P2-5: under “Skipped: still in use” the row gives only
            // the cause, so “skipped” is not said twice.
            return CleanSkipReasonPresentation.isStillInUse(reason)
                ? CleanSkipReasonPresentation.stillInUseCause(reason)
                : CleanSkipReasonPresentation.title(reason)
        case let .failed(failure):
            return CleanFailurePresentation.title(failure)
        case .notProcessed:
            return L10n.text("取消后未处理", "Not processed after cancellation")
        }
    }
}

/// Localized failure text shared by the cleanup report and Operation History;
/// raw failure codes are never shown as a status.
enum CleanFailurePresentation {
    static func title(_ failure: CleanFailure) -> String {
        if let detailCode = failure.detailCode {
            switch detailCode {
            case "cancelled":
                return L10n.text("已取消", "Cancelled")
            case "item-still-present":
                return L10n.text("删除后项目仍在，未完成", "The item is still present after deletion")
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
        case .persistenceFailed:
            return L10n.text("回执保存失败，已停止后续操作", "Receipt saving failed; further operations stopped")
        case .moveOutcomeUnknown:
            return L10n.text("移动结果待核实，禁止自动重试", "Move outcome needs verification; automatic retry blocked")
        case .deletionOutcomeUnknown:
            return L10n.text("永久删除未完成，部分内容可能已删除", "Permanent deletion did not finish; some content may be gone")
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
}

enum CleanSkipReasonPresentation {
    static func isStillInUse(_ reason: CleanSkipReason) -> Bool {
        reason == .candidateBecameActive || reason == .relatedAppStillRunning
    }

    /// The cause alone, for rows already grouped under “Skipped: still in use”.
    static func stillInUseCause(_ reason: CleanSkipReason) -> String {
        reason == .candidateBecameActive
            ? L10n.text("扫描后有新写入或变化，如需清理请重新扫描", "Written or changed after the scan; scan again to clean it")
            : title(reason)
    }

    static func recordLabel(_ reason: CleanSkipReason) -> String {
        if isStillInUse(reason) {
            let detail = reason == .candidateBecameActive
                ? L10n.text("扫描后有新写入或变化", "Written or changed after the scan")
                : title(reason)
            return CleanupReportIssueGroup.stillInUse.title + " · " + detail
        }
        return L10n.text("已跳过：", "Skipped: ") + title(reason)
    }

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
        case .contentCloudOnly: FileContentReadError.cloudOnly.localizedDescription
        case .contentDownloading: FileContentReadError.downloading.localizedDescription
        case .contentReadTimedOut: FileContentReadError.timedOut.localizedDescription
        case .contentReadUnavailable:
            L10n.text("无法安全读取文件，已跳过；请稍后重试。", "The file could not be read safely and was skipped. Try again later.")
        case .contentReadCancelled: L10n.text("已取消读取，未处理原件。", "Reading was cancelled; the original was not handled.")
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
            // Developer files (D22) and, since the D47 supplement, rows whose
            // app could not be identified share this recheck.
            L10n.text("扫描后仍有新写入或变化，可能正在使用；已跳过，如需清理请重新扫描",
                      "Written or changed after the scan and may be in use; skipped. Scan again to clean it")
        case .changedSinceAnalysis:
            L10n.text("分析后已修改或替换，请重新分析", "Changed or replaced after the analysis; analyze again")
        case .containsMountPoint:
            L10n.text("含挂载点", "Holds a mount point")
        }
    }
}

/// A2: the confirmation text that names the apps before they are asked to quit.
enum CleanupOwnerQuitPresentation {
    /// Round 3 (P2-2): every running instance that will be asked to quit; an
    /// app open more than once shows how many instances.
    static func message(for request: CleanupOwnerQuitRequest?) -> String {
        let names = names(request?.owners ?? [])
        let seconds = Int(CleanupOwnerQuitService.waitSeconds)
        return L10n.text(
            "将请求以下应用正常退出：\(names)。应用可能会提示保存未保存的内容；不会强制结束。退出后会重新检查这些项目，最长等待 \(seconds) 秒。",
            "These apps will be asked to quit normally: \(names). They may ask you to save unsaved work; nothing is force-quit. The items are checked again after they quit, waiting up to \(seconds) seconds."
        )
    }

    /// Round 3 (P2-1): owners that run but cannot be asked to quit.
    static func manualQuitText(for owners: [CleanupOwnerQuitService.RunningOwner]) -> String {
        let names = names(owners)
        return L10n.text("需手动退出：\(names)", "Quit manually: \(names)")
    }

    /// Names in order, each once; an app open more than once shows a count.
    static func names(_ owners: [CleanupOwnerQuitService.RunningOwner]) -> String {
        var order = [String]()
        var counts = [String: Int]()
        for owner in owners {
            if counts[owner.displayName] == nil { order.append(owner.displayName) }
            counts[owner.displayName, default: 0] += 1
        }
        return order.map { name in
            let count = counts[name] ?? 1
            return count > 1
                ? L10n.text("\(name)（\(ByteFormat.count(count)) 个实例）", "\(name) (\(ByteFormat.count(count)) instances)")
                : name
        }
        .joined(separator: L10n.text("、", ", "))
    }
}
